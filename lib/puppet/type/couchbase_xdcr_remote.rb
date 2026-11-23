# frozen_string_literal: true

require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'puppet_x', 'couchbase', 'client'))

Puppet::Type.newtype(:couchbase_xdcr_remote) do
  @doc = <<-DOC
    @summary Manages an XDCR remote cluster reference: where a replication
      sends its data, and the credentials it uses there.

    Couchbase checks the credentials when the reference is created or
    changed, and never reports the password back. Puppet sends the password
    again when another attribute changes, or when Couchbase reports that the
    stored one is rejected by the remote cluster (Couchbase 7.x and later).

    @example
      couchbase_xdcr_remote { 'dr':
        hostname => 'cb01.dr.example.com',
        username => 'xdcr',
        password => Sensitive('xdcr-password'),
      }

    @example Encrypted (Enterprise Edition)
      couchbase_xdcr_remote { 'dr':
        hostname    => 'cb01.dr.example.com',
        username    => 'xdcr',
        password    => Sensitive('xdcr-password'),
        secure_type => 'full',
        certificate => file('profile/dr-ca.pem'),
      }
  DOC

  ensurable do
    defaultto :present
    newvalue(:present) { provider.create }
    newvalue(:absent) { provider.destroy }
  end

  newparam(:name, namevar: true) do
    desc 'Name of the reference, used by replications as `to_cluster`.'
    validate { |value| raise ArgumentError, "Invalid remote cluster name '#{value}'" unless value.to_s =~ /\A[^\/\s]+\z/ }
  end

  newproperty(:hostname) do
    desc 'Address of any node of the remote cluster, optionally with `:port` (default 8091).'
    munge { |value| value.to_s.include?(':') ? value.to_s : "#{value}:8091" }
  end

  newproperty(:username) do
    desc 'User on the remote cluster, which needs the XDCR Inbound role on the target buckets.'
  end

  newproperty(:password) do
    desc 'Password of `username`. Accepts a Sensitive value.'
    sensitive true

    # Couchbase never reports it; the provider says whether the remote
    # cluster currently rejects the stored one.
    def insync?(_is)
      !provider.auth_failed?
    end

    def change_to_s(_from, _to)
      'password updated: the remote cluster rejected the stored one'
    end

    def is_to_s(_value) # rubocop:disable Naming/PredicateName
      '[redacted]'
    end

    def should_to_s(_value)
      '[redacted]'
    end
  end

  newproperty(:secure_type) do
    desc '`none` (default), `half` (encrypted password) or `full` (TLS); encryption needs Enterprise Edition.'
    newvalues(:none, :half, :full)
    defaultto :none
  end

  newproperty(:certificate) do
    desc "CA certificate (PEM) of the remote cluster, for `secure_type` `half` or `full`."
    munge { |value| value.to_s.strip }
    def insync?(is)
      is.to_s.strip == should.to_s.strip
    end

    def change_to_s(_from, _to)
      'certificate changed'
    end
  end

  newparam(:client_certificate) do
    desc 'Client certificate (PEM), for `secure_type` `full` with certificate authentication.'
  end

  newparam(:client_key) do
    desc 'Key of `client_certificate` (PEM). Accepts a Sensitive value.'
    sensitive true
  end

  validate do
    next unless self[:ensure] == :present || self[:ensure].nil?
    # Listed by `puppet resource`: it exists, nothing is created.
    next if provider.respond_to?(:get) && provider.get(:ensure) == :present

    raise ArgumentError, "couchbase_xdcr_remote[#{self[:name]}]: hostname is required" if self[:hostname].nil?
    raise ArgumentError, "couchbase_xdcr_remote[#{self[:name]}]: username is required" if self[:username].nil?
    if self[:password].nil? && self[:client_certificate].nil?
      raise ArgumentError, "couchbase_xdcr_remote[#{self[:name]}]: password is required"
    end
  end

  autorequire(:couchbase_cluster) { catalog.resources.select { |r| r.type == :couchbase_cluster }.map(&:title) }
  autorequire(:file) { [PuppetX::Couchbase::Client.config_path] }
  autorequire(:service) { ['couchbase-server'] }

  # Replications must be removed before the reference they use.
  autorequire(:couchbase_xdcr_replication) do
    catalog.resources.select { |r|
      r.type == :couchbase_xdcr_replication && r[:to_cluster] == self[:name] && r[:ensure] == :absent
    }.map(&:title)
  end
end
