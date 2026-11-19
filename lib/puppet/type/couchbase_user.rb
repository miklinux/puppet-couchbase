# frozen_string_literal: true

require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'puppet_x', 'couchbase', 'client'))
require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'puppet_x', 'couchbase', 'role'))

Puppet::Type.newtype(:couchbase_user) do
  @doc = <<-DOC
    @summary Manages a Couchbase RBAC user (local, or external/LDAP).

    `roles` is the authoritative list of roles granted *directly* to the user
    (roles inherited from groups are ignored). Leave it unset to manage the
    user's grants with individual `couchbase_acl` resources instead.

    @example
      couchbase_user { 'app':
        ensure       => present,
        display_name => 'Application user',
        password     => Sensitive('s3cret'),
        roles        => ['data_reader[sessions]', 'data_writer[sessions:_default:_default]'],
        groups       => ['developers'],
      }
  DOC

  ensurable do
    defaultto :present
    newvalue(:present) { provider.create }
    newvalue(:absent) { provider.destroy }
  end

  newparam(:name, namevar: true) do
    desc 'User id (login name).'
    validate do |value|
      raise ArgumentError, "Invalid couchbase user name '#{value}'" if value.to_s.empty? || value.to_s =~ %r{[()<>@,;:\\"/\[\]?={}\s]} || value.to_s.length > 128
    end
  end

  newparam(:domain) do
    desc 'Authentication domain: `local` (password stored in Couchbase) or `external` (LDAP/PAM/SAML).'
    newvalues(:local, :external)
    defaultto :local
  end

  newparam(:password_management) do
    desc '`enforce` (default) resets the password whenever it does not match; `on_create` only sets it when the user is created.'
    newvalues(:enforce, :on_create)
    defaultto :enforce
  end

  newproperty(:display_name) do
    desc 'Full name of the user.'
  end

  newproperty(:password) do
    desc 'Password of a local user. Checked by authenticating as the user, never read back.'

    validate do |value|
      raise ArgumentError, 'password must be at least 6 characters' if value.to_s.length < 6
    end

    def insync?(is)
      return true if @resource[:password_management] == :on_create

      super
    end

    def change_to_s(_currentvalue, _newvalue)
      'password changed'
    end

    def is_to_s(_value) # rubocop:disable Naming/PredicateName
      '[redacted]'
    end

    def should_to_s(_value)
      '[redacted]'
    end
  end

  newproperty(:roles, array_matching: :all) do
    desc "Roles granted directly to the user, e.g. ['admin'] or ['data_reader[bucket:scope:collection]']."

    validate do |value|
      PuppetX::Couchbase::Role.parse(value)
    end

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

  newproperty(:groups, array_matching: :all) do
    desc 'Groups the user belongs to (Enterprise Edition).'

    def insync?(is)
      Array(is).map(&:to_s).sort.uniq == Array(should).map(&:to_s).sort.uniq
    end

    def should_to_s(value)
      Array(value).sort.inspect
    end

    def is_to_s(value) # rubocop:disable Naming/PredicateName
      Array(value).sort.inspect
    end
  end

  validate do
    next if self[:ensure] == :absent

    if self[:domain] == :external && self[:password]
      raise ArgumentError, "couchbase_user[#{self[:name]}]: external users cannot have a password"
    end
  end

  autorequire(:couchbase_group) { Array(self[:groups]) }
  autorequire(:couchbase_bucket) { Array(self[:roles]).map { |r| PuppetX::Couchbase::Role.bucket(r) }.compact.uniq }
  autorequire(:couchbase_cluster) { catalog.resources.select { |r| r.type == :couchbase_cluster }.map(&:title) }
  autorequire(:file) { [PuppetX::Couchbase::Client.config_path] }
  autorequire(:service) { ['couchbase-server'] }
end
