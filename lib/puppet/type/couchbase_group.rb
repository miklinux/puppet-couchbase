# frozen_string_literal: true

require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'puppet_x', 'couchbase', 'client'))
require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'puppet_x', 'couchbase', 'role'))

Puppet::Type.newtype(:couchbase_group) do
  @doc = <<-DOC
    @summary Manages a Couchbase RBAC group (Enterprise Edition).

    As for users, `roles` is authoritative when set; leave it unset to grant
    roles to the group with `couchbase_acl` resources.

    @example
      couchbase_group { 'developers':
        description => 'Read access to every bucket',
        roles       => ['data_reader[*]', 'query_select[*]'],
      }
  DOC

  ensurable do
    defaultto :present
    newvalue(:present) { provider.create }
    newvalue(:absent) { provider.destroy }
  end

  newparam(:name, namevar: true) do
    desc 'Group id.'
    validate do |value|
      raise ArgumentError, "Invalid couchbase group name '#{value}'" if value.to_s.empty? || value.to_s =~ %r{[()<>@,;:\\"/\[\]?={}\s]}
    end
  end

  newproperty(:description) do
    desc 'Free-form description.'
  end

  newproperty(:ldap_group_ref) do
    desc 'Distinguished name of an LDAP group mapped to this group.'
  end

  newproperty(:roles, array_matching: :all) do
    desc 'Roles granted to the group.'

    validate { |value| PuppetX::Couchbase::Role.parse(value) }
    munge { |value| PuppetX::Couchbase::Role.normalize(value) }

    def insync?(is)
      PuppetX::Couchbase::Role.normalize_all(is) == PuppetX::Couchbase::Role.normalize_all(should)
    end

    def should_to_s(value)
      Array(value).sort.inspect
    end

    def is_to_s(value) # rubocop:disable Naming/PredicateName
      Array(value).sort.inspect
    end
  end

  autorequire(:couchbase_bucket) { Array(self[:roles]).map { |r| PuppetX::Couchbase::Role.bucket(r) }.compact.uniq }
  autorequire(:couchbase_cluster) { catalog.resources.select { |r| r.type == :couchbase_cluster }.map(&:title) }
  autorequire(:file) { [PuppetX::Couchbase::Client.config_path] }
  autorequire(:service) { ['couchbase-server'] }
end
