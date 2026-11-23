# frozen_string_literal: true

require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'puppet_x', 'couchbase', 'client'))
require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'puppet_x', 'couchbase', 'settings'))

Puppet::Type.newtype(:couchbase_settings) do
  @doc = <<-DOC
    @summary Manages one group of cluster-wide Couchbase settings.

    The title names the group; `settings` holds the fields to manage, named
    as in the Couchbase REST API. Only the fields given are compared and
    changed; all others keep their current values. Fields a version or
    edition doesn't have are reported as errors.

    | Group | Web console | REST endpoint |
    |---|---|---|
    | `auto_failover` | Node Availability | /settings/autoFailover |
    | `auto_reprovision` | For Ephemeral Buckets | /settings/autoReprovision |
    | `rebalance` | Advanced Rebalance Settings | /settings/rebalance |
    | `retry_rebalance` | Retry rebalance (Enterprise) | /settings/retryRebalance |
    | `data` | Advanced Data Settings: threads | /pools/default/settings/memcached/global |
    | `resource_management` | Advanced Data Settings: disk usage (8.0+) | /settings/resourceManagement |
    | `query` | Advanced Query Settings | /settings/querySettings |
    | `query_curl_access` | Advanced Query Settings: CURL() access | /settings/querySettings/curlWhitelist |
    | `index` | Index Storage Mode, Advanced Index Settings | /settings/indexes |
    | `xdcr` | XDCR Maximum Processes and other XDCR defaults | /settings/replications |

    @example Auto-failover after 60 seconds, including on disk errors
      couchbase_settings { 'auto_failover':
        settings => {
          'enabled'                  => true,
          'timeout'                  => 60,
          'failoverOnDataDiskIssues' => { 'enabled' => true, 'timePeriod' => 120 },
        },
      }

    @example XDCR maximum processes
      couchbase_settings { 'xdcr':
        settings => { 'goMaxProcs' => 8 },
      }
  DOC

  newparam(:name, namevar: true) do
    desc "The settings group: #{PuppetX::Couchbase::Settings.names.join(', ')}."
    validate do |value|
      names = PuppetX::Couchbase::Settings.names
      raise ArgumentError, "Unknown settings group '#{value}'; use one of #{names.join(', ')}" unless names.include?(value.to_s)
    end
  end

  newproperty(:settings) do
    desc 'Fields to manage, named as in the REST API. Nested hashes are used for nested fields ' \
         "(e.g. auto_failover's `failoverOnDataDiskIssues`)."

    validate do |value|
      raise ArgumentError, 'settings must be a hash' unless value.is_a?(Hash)
      raise ArgumentError, 'settings must not be empty' if value.empty?
    end

    munge { |value| PuppetX::Couchbase::Settings.stringify(value) }

    def insync?(is)
      return false unless is.is_a?(Hash)

      PuppetX::Couchbase::Settings.diff(resource[:name], should, is).empty?
    end

    # Name only the managed fields that change: "timeout 120 => 45".
    def change_to_s(current, desired)
      changes = PuppetX::Couchbase::Settings.diff(resource[:name], desired, current || {})
      return 'settings changed' if changes.empty?

      changes.map { |field, (from, to)| "#{field} #{from.nil? ? '(unset)' : from.inspect} => #{to.inspect}" }.join(', ')
    rescue StandardError
      'settings changed'
    end
  end

  autorequire(:couchbase_cluster) { catalog.resources.select { |r| r.type == :couchbase_cluster }.map(&:title) }
  autorequire(:file) { [PuppetX::Couchbase::Client.config_path] }
  autorequire(:service) { ['couchbase-server'] }
end
