# frozen_string_literal: true

require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'puppet_x', 'couchbase', 'client'))

Puppet::Type.newtype(:couchbase_cluster) do
  @doc = <<-DOC
    @summary Makes the local node part of a Couchbase cluster and manages
      cluster-wide settings (name and per-service memory quotas).

    Single node: the node initialises a new cluster.

    N nodes: declare the same `cluster_nodes` list on every node and set
    `hostname` to this node's own address (as listed / reachable by the
    others). When the local node is not provisioned yet:

    * if any other listed node is already part of a cluster, this node is
      added to that cluster (with its own `services`) and, with
      `auto_rebalance`, a rebalance is run and awaited;
    * otherwise, only the first node of `cluster_nodes` (the bootstrap node)
      initialises a new cluster; the others fail and join on a later run.

    The admin credentials are taken from the client configuration written by
    the `couchbase` class, so they are not repeated here.

    @example Single node
      couchbase_cluster { 'production':
        services           => ['kv', 'n1ql', 'index'],
        data_ramsize       => 4096,
        index_ramsize      => 1024,
        index_storage_mode => 'plasma',
      }

    @example Three nodes (same code on every node, hostname differs)
      couchbase_cluster { 'production':
        hostname      => $facts['networking']['fqdn'],
        cluster_nodes => ['cb1.example.com', 'cb2.example.com', 'cb3.example.com'],
        services      => ['kv', 'n1ql', 'index'],
        data_ramsize  => 4096,
        index_ramsize => 1024,
      }
  DOC

  ensurable do
    desc 'Only `present` (initialised) is supported; a cluster cannot be un-initialised through the REST API.'
    newvalue(:present) { provider.create }
    defaultto :present
  end

  newparam(:name, namevar: true) do
    desc 'Resource title; also the default for cluster_name.'
  end

  newproperty(:cluster_name) do
    desc 'The cluster name shown in the UI. Defaults to the resource title.'
    defaultto { @resource[:name] }
  end

  newparam(:hostname) do
    desc 'Address this node registers itself with; other nodes must reach it there. ' \
         'Defaults to 127.0.0.1, which only works for a single node.'
    defaultto '127.0.0.1'
  end

  newparam(:cluster_nodes) do
    desc 'Addresses of the cluster members (same list on every node). The first one bootstraps the cluster. ' \
         'Empty (default) means a single-node cluster.'
    defaultto []
    munge { |value| Array(value).map { |v| v.to_s.strip }.reject(&:empty?) }
  end

  newparam(:port) do
    desc 'REST port of the other cluster members.'
    defaultto 8091
    munge(&:to_i)
  end

  newparam(:auto_rebalance, boolean: true) do
    desc 'Rebalance after this node joined (or when it is found added but not rebalanced in) and wait for it.'
    newvalues(:true, :false)
    defaultto :true
  end

  newparam(:rebalance_timeout) do
    desc 'Seconds to wait for a rebalance to finish.'
    defaultto 3600
    munge(&:to_i)
  end

  newproperty(:membership) do
    desc 'Membership of this node, read-only except that `active` is enforced by rebalancing when ' \
         'auto_rebalance is on. Reported values: active, inactiveAdded, inactiveFailed.'
    newvalues(:active, :inactiveAdded, :inactiveFailed)
    defaultto { @resource[:auto_rebalance].to_s == 'true' ? :active : nil }
  end

  newparam(:services) do
    desc 'Services to run on this node (only used at initialisation): kv, n1ql, index, fts, eventing, cbas, backup.'
    defaultto ['kv']
    validate do |value|
      allowed = %w[kv n1ql index fts eventing cbas backup]
      Array(value).each do |svc|
        raise ArgumentError, "Unknown service '#{svc}', expected one of #{allowed.join(', ')}" unless allowed.include?(svc.to_s)
      end
    end
    munge { |value| Array(value).map(&:to_s).uniq }
  end

  newparam(:index_storage_mode) do
    desc 'Index storage mode, only used at initialisation (plasma, memory_optimized or forestdb for Community Edition).'
    newvalues(:plasma, :memory_optimized, :forestdb)
  end

  newparam(:data_path) do
    desc 'Data directory, only used at initialisation.'
  end

  newparam(:index_path) do
    desc 'Index directory, only used at initialisation.'
  end

  newparam(:send_stats, boolean: true) do
    desc 'Whether to send anonymous usage statistics to Couchbase (only used at initialisation).'
    newvalues(:true, :false)
    defaultto :false
  end

  {
    data_ramsize: 'Data service memory quota in MB.',
    index_ramsize: 'Index service memory quota in MB.',
    fts_ramsize: 'Search service memory quota in MB.',
    eventing_ramsize: 'Eventing service memory quota in MB.',
    analytics_ramsize: 'Analytics service memory quota in MB.',
  }.each do |prop, doc|
    newproperty(prop) do
      desc doc
      validate do |value|
        raise ArgumentError, "#{prop} must be a positive integer, got '#{value}'" unless value.to_s =~ /\A\d+\z/ && value.to_i.positive?
      end
      munge(&:to_i)
    end
  end

  validate do
    nodes = Array(self[:cluster_nodes])
    if nodes.size > 1 && %w[127.0.0.1 localhost ::1].include?(self[:hostname].to_s)
      raise ArgumentError, 'couchbase_cluster: set hostname to an address the other cluster_nodes can reach'
    end
  end

  autorequire(:file) { [PuppetX::Couchbase::Client.config_path] }
  autorequire(:service) { ['couchbase-server'] }
end
