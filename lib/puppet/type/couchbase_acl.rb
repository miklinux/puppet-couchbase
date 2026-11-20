# frozen_string_literal: true

require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'puppet_x', 'couchbase', 'client'))
require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'puppet_x', 'couchbase', 'role'))

Puppet::Type.newtype(:couchbase_acl) do
  @doc = <<-DOC
    @summary Grants (or revokes) one role to one user or group.

    Unlike the `roles` property of `couchbase_user` and `couchbase_group`,
    which replaces the whole list, each `couchbase_acl` adds or removes a
    single role and leaves every other grant alone. Use one style or the
    other for a given user or group, not both.

    The title is a free-form label.

    @example A bucket-level role
      couchbase_acl { 'indexer reads the catalog':
        user   => 'indexer',
        role   => 'data_reader',
        bucket => 'catalog',
      }

    @example A collection-level role
      couchbase_acl { 'indexer writes products':
        user       => 'indexer',
        role       => 'data_writer',
        bucket     => 'catalog',
        scope      => 'inventory',
        collection => 'products',
      }

    @example A role on every bucket, for a group
      couchbase_acl { 'developers query everything':
        group  => 'developers',
        role   => 'query_select',
        bucket => '*',
      }

    @example A cluster-wide role (no bucket)
      couchbase_acl { 'monitoring is read-only admin':
        user => 'monitoring',
        role => 'ro_admin',
      }
  DOC

  name_re = /\A[^\s:\[\]\/]+\z/

  # Resources listed by `puppet resource` are built from their provider
  # alone, so the grant's details default to what the server reported.
  discovered = lambda do |resource, attribute|
    provider = resource.provider
    provider.respond_to?(:discovered) ? provider.discovered(attribute) : nil
  end
  keyspace_re = /\A(\*|[A-Za-z0-9._%-]+)\z/

  # These attributes say *which* grant a resource is; a resource is matched
  # to an existing grant by all of them together, so they are never changed
  # in place. They are properties only so that `puppet resource` shows them.
  identity = Module.new do
    def insync?(_is)
      true
    end
  end

  ensurable do
    defaultto :present
    newvalue(:present) { provider.create }
    newvalue(:absent) { provider.destroy }
  end

  newparam(:name, namevar: true) do
    desc 'A free-form label for this grant.'
  end

  newproperty(:user) do
    include identity
    defaultto { discovered.call(@resource, :user) }
    desc 'User receiving the role. Set either `user` or `group`.'
    validate { |value| raise ArgumentError, "Invalid user name '#{value}'" unless value.to_s =~ name_re }
  end

  newproperty(:group) do
    include identity
    defaultto { discovered.call(@resource, :group) }
    desc 'Group receiving the role (Enterprise Edition). Set either `user` or `group`.'
    validate { |value| raise ArgumentError, "Invalid group name '#{value}'" unless value.to_s =~ name_re }
  end

  newproperty(:domain) do
    include identity
    desc 'Domain of `user`: `local` (default) or `external` for LDAP users.'
    newvalues(:local, :external)
    defaultto { discovered.call(@resource, :domain) || (:local if @resource[:user]) }
  end

  newproperty(:role) do
    include identity
    defaultto { discovered.call(@resource, :role) }
    desc 'Role name, e.g. `data_reader`, `bucket_full_access` or `ro_admin`. ' \
         'Set the bucket, scope and collection with their own parameters.'
    validate do |value|
      if value.to_s.include?('[')
        raise ArgumentError, "role '#{value}': give only the role name and set bucket, scope and collection as parameters"
      end
      raise ArgumentError, "Invalid role name '#{value}'" unless value.to_s =~ /\A[a-z][a-z0-9_]*\z/
    end
  end

  newproperty(:bucket) do
    include identity
    defaultto { discovered.call(@resource, :bucket) }
    desc 'Bucket the role applies to, or `*` for every bucket. Leave unset for cluster-wide roles.'
    validate { |value| raise ArgumentError, "Invalid bucket '#{value}'" unless value.to_s =~ keyspace_re }
  end

  newproperty(:scope) do
    include identity
    defaultto { discovered.call(@resource, :scope) }
    desc 'Scope within `bucket`, or `*`. Requires `bucket`.'
    validate { |value| raise ArgumentError, "Invalid scope '#{value}'" unless value.to_s =~ keyspace_re }
  end

  newproperty(:collection) do
    include identity
    defaultto { discovered.call(@resource, :collection) }
    desc 'Collection within `scope`, or `*`. Requires `scope`.'
    validate { |value| raise ArgumentError, "Invalid collection '#{value}'" unless value.to_s =~ keyspace_re }
  end

  validate do
    label = "couchbase_acl[#{self[:name]}]"
    raise ArgumentError, "#{label}: set either user or group" if self[:user].nil? == self[:group].nil?
    raise ArgumentError, "#{label}: role is required" if self[:role].nil?
    raise ArgumentError, "#{label}: scope requires bucket" if self[:scope] && self[:bucket].nil?
    raise ArgumentError, "#{label}: collection requires scope" if self[:collection] && self[:scope].nil?
    raise ArgumentError, "#{label}: domain only applies to users" if self[:group] && self[:domain] == :external
  end

  # `user:<name>`, `external:<name>` or `group:<name>`.
  def principal
    return "group:#{self[:group]}" if self[:group]

    "#{self[:domain] == :external ? 'external' : 'user'}:#{self[:user]}"
  end

  # The role in Couchbase syntax, normalised: `data_reader[catalog]`.
  def role_spec
    PuppetX::Couchbase::Role.build(self[:role], [self[:bucket], self[:scope], self[:collection]].compact)
  end

  # What this resource grants; two resources must not grant the same thing.
  def acl_key
    "#{principal}/#{role_spec}"
  end

  def pre_run_check
    # Two resources granting the same role to the same principal.
    twin = catalog.resources.find { |r| r.type == :couchbase_acl && !r.equal?(self) && r.acl_key == acl_key }
    if twin
      raise Puppet::Error, "#{ref} and #{twin.ref} both manage #{role_spec} for #{principal}; keep only one"
    end

    # A complete `roles` list on the user or group that contradicts this
    # grant: the two would undo each other on every run.
    owner = catalog.resource(self[:group] ? :couchbase_group : :couchbase_user, self[:group] || self[:user])
    return if owner.nil? || owner.should(:roles).nil?

    roles = PuppetX::Couchbase::Role.normalize_all(owner.should(:roles))
    present = self[:ensure].nil? || self[:ensure] == :present
    return if present == roles.include?(role_spec)

    raise Puppet::Error, "#{ref} conflicts with the roles list of #{owner.ref}; " \
                         'manage its roles either with the roles property or with couchbase_acl resources, not both'
  end

  autorequire(:couchbase_user) { self[:user] ? [self[:user]] : [] }
  autorequire(:couchbase_group) { self[:group] ? [self[:group]] : [] }
  autorequire(:couchbase_bucket) { self[:bucket] && self[:bucket] != '*' ? [self[:bucket]] : [] }
  autorequire(:couchbase_cluster) { catalog.resources.select { |r| r.type == :couchbase_cluster }.map(&:title) }
  autorequire(:file) { [PuppetX::Couchbase::Client.config_path] }
  autorequire(:service) { ['couchbase-server'] }
end
