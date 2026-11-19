# frozen_string_literal: true

require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'puppet_x', 'couchbase', 'client'))

Puppet::Type.newtype(:couchbase_bucket) do
  @doc = <<-DOC
    @summary Manages a Couchbase bucket.

    @example
      couchbase_bucket { 'sessions':
        ensure          => present,
        bucket_type     => 'ephemeral',
        ram_quota       => 512,
        replicas        => 1,
        eviction_policy => 'nruEviction',
        max_ttl         => 3600,
      }
  DOC

  ensurable do
    defaultto :present
    newvalue(:present) { provider.create }
    newvalue(:absent) { provider.destroy }
  end

  newparam(:name, namevar: true) do
    desc 'Bucket name.'
    validate do |value|
      unless value =~ /\A[A-Za-z0-9._%-]{1,100}\z/
        raise ArgumentError, "Invalid bucket name '#{value}': up to 100 characters from A-Z a-z 0-9 . _ % -"
      end
    end
  end

  newparam(:bucket_type) do
    desc 'Bucket type, fixed at creation: couchbase (default), ephemeral or memcached.'
    newvalues(:couchbase, :ephemeral, :memcached)
    defaultto :couchbase
  end

  newparam(:storage_backend) do
    desc 'Storage engine for couchbase buckets, fixed at creation: couchstore or magma.'
    newvalues(:couchstore, :magma)
  end

  newparam(:conflict_resolution) do
    desc 'Conflict resolution type, fixed at creation: seqno, lww or custom.'
    newvalues(:seqno, :lww, :custom)
  end

  newparam(:replica_index, boolean: true) do
    desc 'Whether view indexes are replicated, fixed at creation (couchstore only).'
    newvalues(:true, :false)
  end

  newproperty(:ram_quota) do
    desc 'Per-node RAM quota in MB. Defaults to 100 when the bucket is created; unmanaged afterwards unless set.'
    validate do |value|
      raise ArgumentError, "ram_quota must be an integer >= 100, got '#{value}'" unless value.to_s =~ /\A\d+\z/ && value.to_i >= 100
    end
    munge(&:to_i)
  end

  newproperty(:replicas) do
    desc 'Number of replicas (0-3). Changing it on an existing bucket requires a rebalance to take effect.'
    validate do |value|
      raise ArgumentError, "replicas must be 0-3, got '#{value}'" unless value.to_s =~ /\A[0-3]\z/
    end
    munge(&:to_i)
  end

  newproperty(:flush_enabled) do
    desc 'Whether the bucket can be flushed.'
    newvalues(:true, :false)
    munge { |value| value.to_s.to_sym }
  end

  newproperty(:eviction_policy) do
    desc 'valueOnly / fullEviction (couchbase), noEviction / nruEviction (ephemeral). ' \
         'Changing it restarts a couchbase bucket; on ephemeral buckets it can only be set at creation.'
    newvalues(:valueOnly, :fullEviction, :noEviction, :nruEviction)

    # Couchbase rejects eviction policy updates on existing ephemeral
    # buckets: warn instead of failing the whole bucket update every run.
    def insync?(is)
      return true if super
      return false unless provider.respond_to?(:get) && provider.get(:bucket_type) == :ephemeral

      Puppet.warning("couchbase_bucket[#{resource[:name]}]: eviction_policy is #{is} but #{should} is requested; " \
                     'ephemeral buckets only accept it at creation, so the bucket must be recreated to change it')
      true
    end
  end

  newproperty(:durability_min_level) do
    desc 'Minimum durability level: none, majority, majorityAndPersistActive or persistToMajority.'
    newvalues(:none, :majority, :majorityAndPersistActive, :persistToMajority)
  end

  newproperty(:compression_mode) do
    desc 'Compression mode (Enterprise Edition): off, passive or active.'
    newvalues(:off, :passive, :active)
  end

  newproperty(:max_ttl) do
    desc 'Maximum document TTL in seconds (0 = none).'
    validate do |value|
      raise ArgumentError, "max_ttl must be a non-negative integer, got '#{value}'" unless value.to_s =~ /\A\d+\z/
    end
    munge(&:to_i)
  end

  validate do
    next unless self[:ensure] == :present || self[:ensure].nil?

    type = (self[:bucket_type] || :couchbase).to_sym
    if self[:eviction_policy]
      ok = type == :ephemeral ? %i[noEviction nruEviction] : %i[valueOnly fullEviction]
      unless ok.include?(self[:eviction_policy].to_sym)
        raise ArgumentError, "eviction_policy #{self[:eviction_policy]} is not valid for #{type} buckets (use #{ok.join(' or ')})"
      end
    end
    raise ArgumentError, 'storage_backend only applies to couchbase buckets' if self[:storage_backend] && type != :couchbase
  end

  autorequire(:couchbase_cluster) { catalog.resources.select { |r| r.type == :couchbase_cluster }.map(&:title) }
  autorequire(:file) { [PuppetX::Couchbase::Client.config_path] }
  autorequire(:service) { ['couchbase-server'] }
end
