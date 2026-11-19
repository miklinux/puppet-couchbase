# frozen_string_literal: true

require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'puppet_x', 'couchbase', 'client'))
require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'puppet_x', 'couchbase', 'role'))

Puppet::Type.newtype(:couchbase_acl) do
  @doc = <<-DOC
    @summary Grants (or revokes) a single RBAC role to a user or group.

    Unlike the `roles` property of `couchbase_user` / `couchbase_group`,
    which replaces the full list, each `couchbase_acl` only adds or removes
    one role, leaving every other grant alone. This lets different parts of
    the code base (e.g. the profile owning a bucket) grant access
    independently. Do not combine both styles for the same principal.

    The title can carry everything, as `<principal>/<role>`:

    @example Title form
      couchbase_acl { 'user:app/data_writer[sessions:_default]': }

    @example Explicit parameters
      couchbase_acl { 'developers can query everything':
        principal => 'group:developers',
        role      => 'query_select[*]',
      }

    Principals are `user:<id>` (local user), `external:<id>` (LDAP/external
    user) or `group:<id>`.
  DOC

  ensurable do
    defaultto :present
    newvalue(:present) { provider.create }
    newvalue(:absent) { provider.destroy }
  end

  newparam(:name, namevar: true) do
    desc 'Free-form title, or `<principal>/<role>`.'
  end

  newparam(:principal) do
    desc 'Who receives the role: `user:<id>`, `external:<id>` or `group:<id>`. Defaults to the part of the title before `/`.'
    defaultto do
      m = PuppetX::Couchbase::Role::ACL_TITLE_RE.match(@resource[:name].to_s)
      m ? m[1] : nil
    end
    validate do |value|
      raise ArgumentError, "Invalid principal '#{value}', expected user:<id>, external:<id> or group:<id>" unless value.to_s =~ /\A(user|external|group):[^\s\/]+\z/
    end
  end

  newparam(:role) do
    desc 'Role to grant, e.g. `data_reader[bucket:scope:collection]`. Defaults to the part of the title after `/`.'
    defaultto do
      m = PuppetX::Couchbase::Role::ACL_TITLE_RE.match(@resource[:name].to_s)
      m ? m[2] : nil
    end
    validate { |value| PuppetX::Couchbase::Role.parse(value) }
    munge { |value| PuppetX::Couchbase::Role.normalize(value) }
  end

  validate do
    if self[:principal].nil? || self[:role].nil?
      raise ArgumentError, "couchbase_acl[#{self[:name]}]: set principal and role, or use a '<principal>/<role>' title"
    end
  end

  # Refuse catalogs where an authoritative `roles` list on the principal's
  # couchbase_user / couchbase_group contradicts this grant: the two would
  # undo each other on every run.
  def pre_run_check
    kind, id = self[:principal].to_s.split(':', 2)
    owner = catalog.resource(kind == 'group' ? :couchbase_group : :couchbase_user, id)
    return if owner.nil? || owner.should(:roles).nil?

    roles = PuppetX::Couchbase::Role.normalize_all(owner.should(:roles))
    present = self[:ensure].nil? || self[:ensure] == :present
    return if present == roles.include?(self[:role])

    raise Puppet::Error, "#{ref} conflicts with the roles list of #{owner.ref}; " \
                         'manage roles either with the roles property or with couchbase_acl resources, not both'
  end

  # Canonical identity used for prefetch matching.
  def acl_key
    "#{self[:principal]}/#{self[:role]}"
  end

  autorequire(:couchbase_user) do
    kind, id = self[:principal].to_s.split(':', 2)
    %w[user external].include?(kind) ? [id] : []
  end
  autorequire(:couchbase_group) do
    kind, id = self[:principal].to_s.split(':', 2)
    kind == 'group' ? [id] : []
  end
  autorequire(:couchbase_bucket) { [PuppetX::Couchbase::Role.bucket(self[:role])].compact }
  autorequire(:couchbase_cluster) { catalog.resources.select { |r| r.type == :couchbase_cluster }.map(&:title) }
  autorequire(:file) { [PuppetX::Couchbase::Client.config_path] }
  autorequire(:service) { ['couchbase-server'] }
end
