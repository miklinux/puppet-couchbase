# frozen_string_literal: true

require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'puppet_x', 'couchbase', 'client'))
require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'puppet_x', 'couchbase', 'settings'))

Puppet::Type.newtype(:couchbase_xdcr_replication) do
  @doc = <<-DOC
    @summary Manages an XDCR replication from a local bucket to a bucket on a
      remote cluster.

    The title is a free-form label; a replication is identified by
    `from_bucket`, `to_cluster` and `to_bucket` together. `settings` holds
    per-replication settings, named as in the REST API
    (/settings/replications/<id>); only the fields given are managed.

    @example
      couchbase_xdcr_replication { 'orders to DR':
        from_bucket => 'orders',
        to_cluster  => 'dr',
        settings    => { 'compressionType' => 'Auto' },
      }

    @example Paused, with a filter (Enterprise Edition)
      couchbase_xdcr_replication { 'EU customers to DR':
        from_bucket => 'customers',
        to_cluster  => 'dr',
        to_bucket   => 'customers-eu',
        paused      => true,
        settings    => { 'filterExpression' => 'region = "EU"' },
      }
  DOC

  ensurable do
    defaultto :present
    newvalue(:present) { provider.create }
    newvalue(:absent) { provider.destroy }
  end

  newparam(:name, namevar: true) do
    desc 'A free-form label for this replication.'
  end

  bucket_re = /\A[A-Za-z0-9._%-]+\z/

  # Resources listed by `puppet resource` are built from their provider
  # alone, so these default to what the server reported.
  discovered = lambda do |resource, attr|
    value = resource.provider.respond_to?(:get) ? resource.provider.get(attr) : nil
    value == :absent ? nil : value
  end

  # These say *which* replication a resource is, so they are never changed
  # in place. They are properties only so that `puppet resource` shows them.
  identity = Module.new do
    def insync?(_is)
      true
    end
  end

  newproperty(:from_bucket) do
    include identity
    desc 'Local bucket to replicate.'
    defaultto { discovered.call(@resource, :from_bucket) }
    validate { |value| raise ArgumentError, "Invalid bucket name '#{value}'" unless value.to_s =~ bucket_re }
  end

  newproperty(:to_cluster) do
    include identity
    desc 'Name of the couchbase_xdcr_remote reference to replicate to.'
    defaultto { discovered.call(@resource, :to_cluster) }
  end

  newproperty(:to_bucket) do
    include identity
    desc 'Bucket on the remote cluster. Defaults to `from_bucket`.'
    defaultto { discovered.call(@resource, :to_bucket) || @resource[:from_bucket] }
    validate { |value| raise ArgumentError, "Invalid bucket name '#{value}'" unless value.to_s =~ bucket_re }
  end

  newproperty(:paused, boolean: true) do
    desc 'Whether the replication is paused. Defaults to false.'
    newvalues(:true, :false)
    defaultto :false
  end

  newproperty(:settings) do
    desc 'Per-replication settings to manage, named as in the REST API, e.g. `compressionType`, ' \
         '`filterExpression`, `priority` (Enterprise Edition) or `networkUsageLimit`.'

    validate do |value|
      raise ArgumentError, 'settings must be a hash' unless value.is_a?(Hash)
      raise ArgumentError, 'use the paused attribute instead of pauseRequested in settings' if value.key?('pauseRequested')
    end

    munge { |value| PuppetX::Couchbase::Settings.stringify(value) }

    def insync?(is)
      return false unless is.is_a?(Hash)

      PuppetX::Couchbase::Settings.diff('xdcr_replication', should, is).empty?
    end

    def change_to_s(current, desired)
      changes = PuppetX::Couchbase::Settings.diff('xdcr_replication', desired, current || {})
      return 'settings changed' if changes.empty?

      changes.map { |field, (from, to)| "#{field} #{from.inspect} => #{to.inspect}" }.join(', ')
    rescue StandardError
      'settings changed'
    end
  end

  validate do
    label = "couchbase_xdcr_replication[#{self[:name]}]"
    raise ArgumentError, "#{label}: from_bucket is required" if self[:from_bucket].nil?
    raise ArgumentError, "#{label}: to_cluster is required" if self[:to_cluster].nil?
  end

  # What this resource replicates; two resources must not manage the same.
  def key
    "#{self[:to_cluster]}/#{self[:from_bucket]}/#{self[:to_bucket]}"
  end

  def pre_run_check
    twin = catalog.resources.find { |r| r.type == :couchbase_xdcr_replication && !r.equal?(self) && r.key == key }
    return unless twin

    raise Puppet::Error, "#{ref} and #{twin.ref} both manage the replication of #{self[:from_bucket]} " \
                         "to #{self[:to_cluster]}/#{self[:to_bucket]}; keep only one"
  end

  autorequire(:couchbase_cluster) { catalog.resources.select { |r| r.type == :couchbase_cluster }.map(&:title) }
  autorequire(:couchbase_bucket) { [self[:from_bucket]] }
  autorequire(:couchbase_xdcr_remote) { self[:ensure] == :absent ? [] : [self[:to_cluster]] }
  autorequire(:file) { [PuppetX::Couchbase::Client.config_path] }
  autorequire(:service) { ['couchbase-server'] }
end
