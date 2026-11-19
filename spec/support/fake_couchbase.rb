# frozen_string_literal: true

require 'socket'
require 'json'
require 'uri'
require 'base64'

# Minimal in-memory imitation of the Couchbase cluster REST API, served over
# HTTP on 127.0.0.1. Implements just enough of /pools, /clusterInit, buckets and
# RBAC users/groups to exercise the providers end to end.
#
#   ruby spec/support/fake_couchbase.rb [port]   (default 8091)
class FakeCouchbase
  attr_reader :state

  # Port 0 picks a free port; read it back with #port after #listen.
  def initialize(port = 8091)
    @port = port
    @state = { initialized: false, admin: nil, pool: {}, buckets: {}, users: {}, groups: {}, nodes: [],
               rebalancing: false }
    @mutex = Mutex.new
  end

  def listen
    @server = TCPServer.new('127.0.0.1', @port)
    self
  end

  def port
    @server.addr[1]
  end

  def run
    listen unless @server
    loop do
      client = @server.accept
      Thread.new(client) { |c| handle(c) }
    end
  end

  def handle(conn)
    request_line = conn.gets or return
    method, target, = request_line.split(' ')
    headers = {}
    while (line = conn.gets) && line != "\r\n"
      k, v = line.split(':', 2)
      headers[k.strip.downcase] = v.strip
    end
    body = headers['content-length'] ? conn.read(headers['content-length'].to_i) : ''
    params = URI.decode_www_form(body.to_s).to_h
    path = URI.decode_www_form_component(target.split('?').first)
    status, payload = @mutex.synchronize { route(method, path, params, auth(headers)) }
    data = payload.is_a?(String) ? payload : JSON.generate(payload)
    warn "#{method} #{path} #{params.reject { |k, _| k == 'password' }.inspect} -> #{status}" if ENV['FAKE_CB_DEBUG']
    conn.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\nContent-Length: #{data.bytesize}\r\nConnection: close\r\n\r\n#{data}")
  ensure
    conn.close
  end

  def auth(headers)
    h = headers['authorization'].to_s
    return nil unless h.start_with?('Basic ')

    Base64.decode64(h.sub('Basic ', '')).split(':', 2)
  end

  def admin?(creds)
    @state[:initialized] && creds == @state[:admin]
  end

  def role_objects(str, origin)
    str.to_s.split(',').map do |r|
      m = /\A([a-z_]+)(?:\[([^\]]*)\])?\z/.match(r.strip) or raise "bad role #{r}"
      obj = { 'role' => m[1] }
      if m[2]
        b, s, c = m[2].split(':')
        obj['bucket_name'] = b
        # The real server expands bucket-level data roles to scope/collection *.
        if s || m[1].start_with?('data_')
          obj['scope_name'] = s || '*'
          obj['collection_name'] = c || '*'
        end
      end
      obj['origins'] = [origin] if origin
      obj
    end
  end

  # Number of upcoming GET /pools/default calls answered with HTTP 500, to
  # mimic ns_server right after provisioning.
  attr_accessor :flaky_pool_gets

  def route(method, path, params, creds)
    if method == 'GET' && path == '/pools/default' && @flaky_pool_gets.to_i.positive?
      @flaky_pool_gets -= 1
      return [500, ['Unexpected server error, request logged.']]
    end

    case [method, path]
    in ['GET', '/pools']
      # Like the real server: anonymous access is refused once provisioned.
      return [401, ''] if @state[:initialized] && !admin?(creds)

      [200, { 'pools' => @state[:initialized] ? [{ 'name' => 'default' }] : [], 'isAdminCreds' => admin?(creds) }]
    in ['POST', '/clusterInit']
      return [400, { 'errors' => ['already initialized'] }] if @state[:initialized]

      @state[:initialized] = true
      @state[:admin] = [params['username'], params['password']]
      @state[:pool] = params.slice('clusterName', 'memoryQuota', 'indexMemoryQuota', 'ftsMemoryQuota', 'eventingMemoryQuota', 'cbasMemoryQuota')
      @state[:nodes] = [{ 'hostname' => "#{params['hostname']}:8091", 'otpNode' => "ns_1@#{params['hostname']}",
                          'clusterMembership' => 'active', 'thisNode' => true, 'services' => params['services'].to_s.split(',') }]
      [200, {}]
    else
      return [401, ''] unless admin?(creds) || (path == '/whoami' && creds)

      authed(method, path, params, creds)
    end
  end

  def authed(method, path, params, creds)
    case [method, path]
    in ['GET', '/whoami']
      return [200, { 'id' => creds[0] }] if admin?(creds)

      u = @state[:users]["local/#{creds[0]}"]
      u && u[:password] == creds[1] ? [200, { 'id' => creds[0] }] : [401, '']
    in ['GET', '/pools/default']
      [200, @state[:pool].transform_values { |v| v =~ /\A\d+\z/ ? v.to_i : v }.merge('nodes' => @state[:nodes])]
    in ['GET', '/pools/default/rebalanceProgress']
      [200, { 'status' => @state[:rebalancing] ? 'running' : 'none' }]
    in ['POST', '/controller/addNode']
      @state[:nodes] << { 'hostname' => "#{params['hostname']}:8091", 'otpNode' => "ns_1@#{params['hostname']}",
                          'clusterMembership' => 'inactiveAdded', 'thisNode' => false,
                          'services' => params['services'].to_s.split(',') }
      [200, { 'otpNode' => "ns_1@#{params['hostname']}" }]
    in ['POST', '/controller/rebalance']
      known = params['knownNodes'].to_s.split(',')
      return [400, { 'mismatch' => 1 }] unless known.sort == @state[:nodes].map { |n| n['otpNode'] }.sort

      @state[:nodes].each { |n| n['clusterMembership'] = 'active' }
      [200, '']
    in ['POST', '/pools/default']
      @state[:pool].merge!(params)
      [200, {}]
    in ['GET', '/pools/default/buckets']
      [200, @state[:buckets].values]
    in ['POST', '/pools/default/buckets']
      name = params['name']
      return [400, { 'errors' => { 'name' => 'Bucket with given name already exists' } }] if @state[:buckets].key?(name)

      @state[:buckets][name] = bucket_json(name, params, {})
      [202, '']
    in ['POST', %r{\A/pools/default/buckets/([^/]+)\z}]
      name = Regexp.last_match(1)
      return [404, 'Requested resource not found.'] unless @state[:buckets].key?(name)

      @state[:buckets][name] = bucket_json(name, params, @state[:buckets][name])
      [200, '']
    in ['DELETE', %r{\A/pools/default/buckets/([^/]+)\z}]
      @state[:buckets].delete(Regexp.last_match(1)) ? [200, ''] : [404, '']
    in ['GET', '/settings/rbac/users']
      [200, @state[:users].values.map { |u| user_json(u) }]
    in ['GET', %r{\A/settings/rbac/users/(local|external)/([^/]+)\z}]
      u = @state[:users]["#{Regexp.last_match(1)}/#{Regexp.last_match(2)}"]
      u ? [200, user_json(u)] : [404, '"Unknown user."']
    in ['PUT', %r{\A/settings/rbac/users/(local|external)/([^/]+)\z}]
      key = "#{Regexp.last_match(1)}/#{Regexp.last_match(2)}"
      existing = @state[:users][key]
      return [400, { 'errors' => { 'password' => 'required' } }] if existing.nil? && Regexp.last_match(1) == 'local' && params['password'].nil?

      @state[:users][key] = {
        id: Regexp.last_match(2), domain: Regexp.last_match(1), name: params['name'].to_s,
        roles: params['roles'].to_s, groups: params['groups'].to_s.split(',').reject(&:empty?),
        password: params['password'] || existing&.dig(:password)
      }
      [200, '']
    in ['DELETE', %r{\A/settings/rbac/users/(local|external)/([^/]+)\z}]
      @state[:users].delete("#{Regexp.last_match(1)}/#{Regexp.last_match(2)}") ? [200, ''] : [404, '']
    in ['GET', '/settings/rbac/groups']
      [200, @state[:groups].values.map { |g| group_json(g) }]
    in ['GET', %r{\A/settings/rbac/groups/([^/]+)\z}]
      g = @state[:groups][Regexp.last_match(1)]
      g ? [200, group_json(g)] : [404, '"Unknown group."']
    in ['PUT', %r{\A/settings/rbac/groups/([^/]+)\z}]
      id = Regexp.last_match(1)
      @state[:groups][id] = { id: id, description: params['description'].to_s, roles: params['roles'].to_s,
                              ldap_group_ref: params['ldap_group_ref'] }
      [200, '']
    in ['DELETE', %r{\A/settings/rbac/groups/([^/]+)\z}]
      @state[:groups].delete(Regexp.last_match(1)) ? [200, ''] : [404, '']
    else
      [404, '"Not found."']
    end
  end

  def bucket_json(name, params, old)
    b = old.dup
    b['name'] = name
    b['bucketType'] ||= params['bucketType'] == 'couchbase' ? 'membase' : params['bucketType']
    b['quota'] = { 'rawRAM' => params['ramQuotaMB'].to_i * 1024 * 1024 } if params['ramQuotaMB']
    b['replicaNumber'] = params['replicaNumber'].to_i if params['replicaNumber']
    b['replicaNumber'] ||= 1 unless b['bucketType'] == 'memcached'
    b['evictionPolicy'] = params['evictionPolicy'] if params['evictionPolicy']
    b['evictionPolicy'] ||= b['bucketType'] == 'ephemeral' ? 'noEviction' : 'valueOnly'
    b['durabilityMinLevel'] = params['durabilityMinLevel'] if params['durabilityMinLevel']
    b['durabilityMinLevel'] ||= 'none'
    b['compressionMode'] = params['compressionMode'] if params['compressionMode']
    b['compressionMode'] ||= 'passive'
    b['maxTTL'] = params['maxTTL'].to_i if params['maxTTL']
    b['maxTTL'] ||= 0
    if params.key?('flushEnabled')
      b['controllers'] = params['flushEnabled'] == '1' ? { 'flush' => "/pools/default/buckets/#{name}/controller/doFlush" } : {}
    end
    b['controllers'] ||= {}
    b
  end

  def user_json(u)
    roles = role_objects(u[:roles], { 'type' => 'user' })
    u[:groups].each do |gid|
      g = @state[:groups][gid] or next
      roles += role_objects(g[:roles], { 'type' => 'group', 'name' => gid })
    end
    { 'id' => u[:id], 'domain' => u[:domain], 'name' => u[:name], 'roles' => roles, 'groups' => u[:groups] }
  end

  def group_json(g)
    { 'id' => g[:id], 'description' => g[:description], 'roles' => role_objects(g[:roles], nil),
      'ldap_group_ref' => g[:ldap_group_ref] }.compact
  end
end

if $PROGRAM_NAME == __FILE__
  FakeCouchbase.new((ARGV[0] || 8091).to_i).run
end
