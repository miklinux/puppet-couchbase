# frozen_string_literal: true

require 'json'
require 'uri'
require 'net/http'

module PuppetX
  module Couchbase
    # Base error for everything raised by the Couchbase client.
    class Error < StandardError; end

    # The REST API answered with an unexpected HTTP status.
    class HTTPError < Error
      attr_reader :code, :body, :http_method, :path

      def initialize(http_method, path, code, body)
        @http_method = http_method
        @path = path
        @code = code.to_i
        @body = body
        super("Couchbase REST #{http_method} #{path} failed with HTTP #{code}: #{body.to_s.strip[0, 1024]}")
      end
    end

    # The REST API could not be reached at all (refused, unreachable, ...).
    class ConnectionError < Error; end

    # Request body to send as JSON rather than as form fields.
    JSONBody = Struct.new(:object)

    # Small REST client for the Couchbase cluster management API (port 8091).
    #
    # Talks to the local node, by default http://127.0.0.1:8091.
    #
    # Connection settings and admin credentials are read from a JSON file
    # (see .config_path) written by the `couchbase::config` class.
    class Client
      DEFAULT_CONFIG_PATH = '/etc/couchbase/puppet.json'
      DEFAULT_URL = 'http://127.0.0.1:8091'

      # Errors that mean "nothing is listening (yet)" - always safe to retry,
      # because the request never reached Couchbase.
      UNREACHABLE_ERRORS = [
        Errno::ENOENT, Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL, Errno::EHOSTUNREACH,
        Net::OpenTimeout
      ].freeze

      # Errors seen while ns_server is still starting.
      # Only retried while waiting for the node to become ready.
      STARTUP_ERRORS = (UNREACHABLE_ERRORS + [
        Errno::ECONNRESET, Errno::EPIPE, EOFError, IOError, Net::ReadTimeout
      ]).freeze

      attr_reader :url, :username, :password, :timeout

      class << self
        def config_path
          ENV['PUPPET_COUCHBASE_CONFIG'] || DEFAULT_CONFIG_PATH
        end

        # Shared instance; re-read whenever the config file changes so that a
        # long-running agent picks up rotated credentials.
        def instance
          path = config_path
          stamp = File.exist?(path) ? [path, File.mtime(path), File.size(path)] : nil
          if @instance.nil? || stamp.nil? || stamp != @instance_stamp
            @instance = from_config(path)
            @instance_stamp = stamp
          end
          @instance
        end

        def reset!
          @instance = nil
          @instance_stamp = nil
        end

        def from_config(path = config_path)
          unless File.readable?(path)
            raise Error, "Couchbase client configuration #{path} does not exist or is not readable. " \
                         'Declare the couchbase class (or write the file yourself) before managing couchbase_* resources.'
          end
          cfg = JSON.parse(File.read(path))
          new(url: cfg['url'] || DEFAULT_URL,
              username: cfg['username'],
              password: cfg['password'],
              timeout: cfg['timeout'] || 180)
        rescue JSON::ParserError => e
          raise Error, "Cannot parse Couchbase client configuration #{path}: #{e.message}"
        end
      end

      def initialize(url: DEFAULT_URL, username: nil, password: nil, timeout: 180)
        @url = URI.parse(url.to_s.empty? ? DEFAULT_URL : url)
        raise Error, "Invalid Couchbase URL '#{url}'" unless %w[http https].include?(@url.scheme) && @url.host
        @username = username
        @password = password
        @timeout = timeout.to_i
        @ready = false
      end

      def endpoint
        @url.to_s
      end

      # ---- high level helpers ------------------------------------------------

      # true once the node has been provisioned (cluster-init done).
      # An unprovisioned node answers an anonymous GET /pools with 200 and an
      # empty pool list; once provisioned it demands authentication (401).
      def initialized?
        res = request(:get, '/pools', ok: [200, 401], auth: false)
        return true if res.code.to_i == 401

        !Array(parse(res)['pools']).empty?
      end

      # One-shot look at a node, without waiting for it:
      # :unreachable, :uninitialized or :initialized.
      def probe
        res = perform(:get, '/pools', nil, nil)
        case res.code.to_i
        when 200 then Array(parse(res)['pools']).empty? ? :uninitialized : :initialized
        when 401 then :initialized
        else :unreachable
        end
      rescue *STARTUP_ERRORS, SocketError, Errno::ETIMEDOUT
        :unreachable
      end

      # ---- rebalance -----------------------------------------------------------

      def rebalance_running?
        get('/pools/default/rebalanceProgress')['status'] == 'running'
      end

      def wait_for_rebalance(timeout = 3600)
        deadline = monotonic + timeout
        while rebalance_running?
          raise Error, "Rebalance still running after #{timeout}s" if monotonic > deadline

          Puppet.debug('Waiting for the running rebalance to finish') if defined?(Puppet)
          sleep 3
        end
      end

      # Rebalances every node of the cluster in (nobody is ejected) and waits
      # for the result. Retries when another node starts a rebalance first.
      def rebalance(timeout = 3600)
        6.times do
          wait_for_rebalance(timeout)
          nodes = get('/pools/default')['nodes']
          return if nodes.all? { |n| n['clusterMembership'] == 'active' }

          res = request(:post, '/controller/rebalance',
                        params: { 'knownNodes' => nodes.map { |n| n['otpNode'] }.join(','), 'ejectedNodes' => '' },
                        ok: [200, 400, 503])
          # 503: a rebalance is already running (started by another node).
          # 400 {"mismatch":1}: a node was added since we read the list.
          if res.code.to_i == 400
            raise HTTPError.new('POST', '/controller/rebalance', res.code, res.body) unless res.body.to_s.include?('mismatch')

            Puppet.debug('Rebalance node list changed meanwhile, retrying') if defined?(Puppet)
          end
          sleep 3 unless res.code.to_i == 200
          wait_for_rebalance(timeout)
        end
        pending = get('/pools/default')['nodes'].reject { |n| n['clusterMembership'] == 'active' }
        return if pending.empty?

        raise Error, "Rebalance did not activate #{pending.map { |n| n['hostname'] }.join(', ')}; " \
                     'check the Couchbase logs (GET /logs) for the reason'
      end

      # Checks a set of credentials without raising.
      def valid_credentials?(user, password)
        res = raw_request(:get, '/whoami', credentials: [user, password])
        return true if res.code.to_i == 200
        return false if [401, 403].include?(res.code.to_i)

        raise HTTPError.new('GET', '/whoami', res.code, res.body)
      end

      # Blocks until the REST API answers (or the timeout expires).
      def wait_until_ready
        return if @ready

        deadline = monotonic + @timeout
        last_error = nil
        loop do
          begin
            res = perform(:get, '/pools', nil, nil)
            # 401 = provisioned node asking for credentials: it is up.
            if [200, 401].include?(res.code.to_i)
              @ready = true
              return
            end
            last_error = "HTTP #{res.code}"
          rescue *STARTUP_ERRORS => e
            last_error = "#{e.class}: #{e.message}"
          end
          if monotonic > deadline
            raise ConnectionError, "Couchbase REST API at #{endpoint} not ready after #{@timeout}s (#{last_error})"
          end

          Puppet.debug("Waiting for Couchbase REST API at #{endpoint}: #{last_error}") if defined?(Puppet)
          sleep 2
        end
      end

      # Marks the API as possibly restarting (e.g. right after cluster-init).
      def reset_ready!
        @ready = false
      end

      # ---- verbs --------------------------------------------------------------

      def get(path, ok: [200], auth: true)
        parse(request(:get, path, ok: ok, auth: auth))
      end

      def post(path, params = {}, ok: [200, 202], auth: true)
        parse(request(:post, path, params: params, ok: ok, auth: auth))
      end

      # POSTs `object` as a JSON document instead of form fields.
      def post_json(path, object, ok: [200, 202])
        parse(request(:post, path, params: JSONBody.new(object), ok: ok))
      end

      def put(path, params = {}, ok: [200, 202], auth: true)
        parse(request(:put, path, params: params, ok: ok, auth: auth))
      end

      def delete(path, ok: [200, 202, 204], auth: true)
        parse(request(:delete, path, ok: ok, auth: auth))
      end

      # Returns nil instead of raising when the resource does not exist.
      def get_or_nil(path)
        res = request(:get, path, ok: [200, 404])
        return nil if res.code.to_i == 404

        parse(res)
      end

      # GETs are retried on 5xx: right after provisioning or bucket creation
      # ns_server briefly answers 500 "Unexpected server error".
      def request(method, path, params: nil, ok: [200], auth: true)
        deadline = monotonic + [@timeout, 60].min
        res = nil
        loop do
          res = raw_request(method, path, params: params, credentials: auth ? [@username, @password] : nil)
          break unless method == :get && res.code.to_i >= 500 && !ok.include?(res.code.to_i) && monotonic < deadline

          Puppet.debug("Couchbase GET #{path} returned HTTP #{res.code}, retrying") if defined?(Puppet)
          sleep 2
        end
        return res if ok.include?(res.code.to_i)

        if res.code.to_i == 401 && auth
          raise HTTPError.new(method.to_s.upcase, path, res.code,
                              "authentication failed for '#{@username}' - check the admin credentials in #{self.class.config_path}")
        end
        raise HTTPError.new(method.to_s.upcase, path, res.code, res.body)
      end

      def raw_request(method, path, params: nil, credentials: nil)
        wait_until_ready
        deadline = monotonic + @timeout
        begin
          perform(method, path, params, credentials)
        rescue *UNREACHABLE_ERRORS => e
          raise ConnectionError, "Cannot reach Couchbase at #{endpoint}: #{e.class}: #{e.message}" if monotonic > deadline

          sleep 2
          retry
        end
      end

      private

      def perform(method, path, params, credentials)
        req = build_request(method, path, params)
        req.basic_auth(credentials[0].to_s, credentials[1].to_s) if credentials && credentials[0]
        connection.start { |http| http.request(req) }
      end

      def build_request(method, path, params)
        klass = {
          get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put, delete: Net::HTTP::Delete
        }.fetch(method)
        req = klass.new(@url.path.chomp('/') + path)
        req['Accept'] = 'application/json'
        if params.is_a?(JSONBody)
          req['Content-Type'] = 'application/json'
          req.body = JSON.generate(params.object)
        elsif params && !%i[get delete].include?(method)
          req['Content-Type'] = 'application/x-www-form-urlencoded'
          req.body = encode_form(params)
        end
        req
      end

      def encode_form(params)
        URI.encode_www_form(params.reject { |_k, v| v.nil? }.map { |k, v| [k.to_s, v.to_s] })
      end

      def connection
        http = Net::HTTP.new(@url.host, @url.port, nil) # nil: ignore http_proxy
        http.use_ssl = (@url.scheme == 'https')
        http.open_timeout = 5
        http.read_timeout = 120
        http
      end

      def parse(res)
        body = res.body.to_s
        return {} if body.strip.empty?

        # Some servers repeat keys (Community 7.0 lists couch_docs_data_size
        # twice in /pools/default), which json >= 3.0 rejects by default.
        # Older json versions ignore the option and keep the last value.
        JSON.parse(body, allow_duplicate_key: true)
      rescue JSON::ParserError
        body
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
