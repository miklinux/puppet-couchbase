# frozen_string_literal: true

module PuppetX
  module Couchbase
    # Cluster-wide settings managed by couchbase_settings: one group per REST
    # endpoint. Desired values are hashes keyed by the REST field names, so
    # every field a Couchbase version supports can be set; only the keys given
    # are compared and changed, everything else is left alone.
    module Settings
      # path:     GET/POST endpoint.
      # encoding: :form (default) or :json (the whole object is posted).
      # nested:   how nested hashes become form fields: :brackets
      #           (a[b]=1) or :dots (a.b=1).
      # read_as:  REST field reported under another name on GET.
      # sparse:   the server reports only fields that were set, so a missing
      #           field means "not set yet", not "unsupported".
      # same:     values the server reports differently but means the same.
      # switch:   field that turns the feature on and off. While the desired
      #           value is false, Couchbase ignores the other fields, so only
      #           the switch is compared.
      # carry:    fields every POST must include; taken from the current
      #           settings when not set. A Hash maps a field to the switch
      #           state it is needed in.
      # write_only: fields that are sent but never reported back, so they
      #           are not compared.
      GROUPS = {
        'auto_failover' => {
          path: '/settings/autoFailover', nested: :brackets, switch: 'enabled',
          carry: { 'enabled' => :always, 'timeout' => :enabled },
          # maxCount is not reported while disableMaxCount is true.
          hides: { 'disableMaxCount' => ['maxCount'] },
        },
        'auto_reprovision' => {
          path: '/settings/autoReprovision', switch: 'enabled',
          read_as: { 'maxNodes' => 'max_nodes' },
          carry: { 'enabled' => :always, 'maxNodes' => :enabled },
        },
        'rebalance' => { path: '/settings/rebalance' },
        'retry_rebalance' => { path: '/settings/retryRebalance', switch: 'enabled' },
        'data' => {
          path: '/pools/default/settings/memcached/global', sparse: true,
          same: { 'default' => 'balanced' },
        },
        'resource_management' => { path: '/settings/resourceManagement', nested: :dots },
        'query' => { path: '/settings/querySettings' },
        'query_curl_access' => { path: '/settings/querySettings/curlWhitelist', encoding: :json },
        'index' => { path: '/settings/indexes' },
        'xdcr' => { path: '/settings/replications' },
      }.freeze

      # Not couchbase_settings groups, but compared the same way.
      INTERNAL = {
        # /settings/replications/<id> of one XDCR replication.
        'xdcr_replication' => { write_only: ['filterSkipRestream'] },
      }.freeze

      # Answers meaning "this server has no such settings": an older version
      # (404), Community Edition, or a deployment profile without them.
      UNSUPPORTED_RE = /enterprise edition|not allowed in this config profile|not found/i

      module_function

      def group(name)
        GROUPS.fetch(name.to_s) do
          INTERNAL.fetch(name.to_s) { raise ArgumentError, "Unknown settings group '#{name}'; use one of #{GROUPS.keys.join(', ')}" }
        end
      end

      def names
        GROUPS.keys
      end

      # Fields of `desired` that differ from `current`, as
      # { field => [current, desired] }; nested fields use "a/b" paths.
      # Raises if a field is not reported at all (unsupported by the server).
      def diff(name, desired, current)
        g = group(name)
        out = {}
        compared(g, desired).each do |key, want|
          have_key = (g[:read_as] || {}).fetch(key, key)
          if want.is_a?(Hash)
            sub = current[have_key]
            raise missing(name, key) unless sub.is_a?(Hash)

            want.each do |k, v|
              raise missing(name, "#{key}/#{k}") unless sub.key?(k.to_s)

              out["#{key}/#{k}"] = [sub[k.to_s], v] unless same?(g, v, sub[k.to_s])
            end
          elsif current.key?(have_key)
            out[key] = [current[have_key], want] unless same?(g, want, current[have_key])
          elsif g[:sparse]
            out[key] = [nil, want]
          else
            raise missing(name, key)
          end
        end
        out
      end

      # The desired fields that matter given the switch and hides rules.
      def compared(g, desired)
        desired = stringify(desired).reject { |k, _| (g[:write_only] || []).include?(k) }
        return desired.slice(g[:switch]) if g[:switch] && desired.key?(g[:switch]) && !truthy?(desired[g[:switch]])

        (g[:hides] || {}).each do |flag, hidden|
          desired = desired.reject { |k, _| hidden.include?(k) } if truthy?(desired[flag])
        end
        desired
      end

      # Request body for applying `desired` on top of `current`.
      def payload(name, desired, current)
        g = group(name)
        want = compared(g, desired)
        stringify(desired).each { |k, v| want[k] = v if (g[:write_only] || []).include?(k) }
        if g[:encoding] == :json
          return current.reject { |k, _| k == 'count' }.merge(want)
        end

        enabled = want.key?(g[:switch]) ? truthy?(want[g[:switch]]) : truthy?(current[g[:switch]])
        (g[:carry] || {}).each do |key, needed_when|
          next if want.key?(key)
          next if needed_when == :enabled && !enabled

          have = current[(g[:read_as] || {}).fetch(key, key)]
          want[key] = have unless have.nil?
        end
        flatten(want, g[:nested] || :brackets)
      end

      def flatten(hash, style)
        hash.each_with_object({}) do |(k, v), out|
          if v.is_a?(Hash)
            v.each { |sk, sv| out[style == :dots ? "#{k}.#{sk}" : "#{k}[#{sk}]"] = scalar(sv) }
          else
            out[k] = scalar(v)
          end
        end
      end

      def scalar(value)
        value.is_a?(Array) ? value.join(',') : value.to_s
      end

      def same?(g, want, have)
        a = normalize(want)
        b = normalize(have)
        return true if a == b

        alias_of = g[:same] || {}
        alias_of[a] == b || alias_of[b] == a
      end

      # Compares across types: Puppet/Hiera may give "true" or "120" where
      # the server reports true or 120.
      def normalize(value)
        case value
        when Array then value.map { |v| normalize(v) }.sort
        when Hash then value.to_h { |k, v| [k.to_s, normalize(v)] }
        when Float then value == value.to_i ? value.to_i.to_s : value.to_s
        else value.to_s
        end
      end

      def truthy?(value)
        value == true || value.to_s == 'true'
      end

      def stringify(hash)
        hash.to_h { |k, v| [k.to_s, v.is_a?(Hash) ? stringify(v) : v] }
      end

      def missing(name, key)
        Puppet::Error.new("couchbase_settings[#{name}]: this Couchbase server does not report '#{key}'; " \
                          'it is not a setting of this version or edition (check the name against the REST API)')
      end
    end
  end
end
