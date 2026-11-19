# frozen_string_literal: true

require File.expand_path(File.join(File.dirname(__FILE__), '..', 'couchbase'))

Puppet::Type.type(:couchbase_user).provide(:rest, parent: Puppet::Provider::Couchbase) do
  desc 'Manages RBAC users through the Couchbase REST API (/settings/rbac/users).'

  mk_resource_methods

  def self.from_api(u)
    {
      name: u['id'],
      ensure: :present,
      domain: u['domain'].to_s.to_sym,
      display_name: u['name'].to_s,
      roles: PuppetX::Couchbase::Role.direct_from_api(u['roles']),
      groups: Array(u['groups']).map(&:to_s).sort,
    }
  end

  def self.instances
    with_client do |c|
      Array(c.get('/settings/rbac/users')).map { |u| new(from_api(u)) }
    end
  end

  def self.prefetch(resources)
    found = instances
    resources.each do |name, resource|
      domain = (resource[:domain] || :local).to_sym
      provider = found.find { |p| p.name == name && p.domain == domain }
      resource.provider = provider if provider
    end
  end

  def self.user_path(domain, name)
    "/settings/rbac/users/#{domain}/#{url_escape(name)}"
  end

  def user_path
    self.class.user_path(resource[:domain] || :local, resource[:name])
  end

  # The password is write-only; report the desired value when it works for
  # authentication, something else when it does not.
  def password
    return nil unless exists?
    return nil if resource[:password].nil?

    ok = with_client { |c| c.valid_credentials?(resource[:name], resource[:password]) }
    ok ? resource[:password] : '<mismatch>'
  end

  def create
    if resource[:domain] != :external && resource[:password].nil?
      raise Puppet::Error, "couchbase_user[#{resource[:name]}]: a password is required to create a local user"
    end

    params = {
      'name' => resource[:display_name],
      'roles' => Array(resource[:roles]).join(','),
      'groups' => resource[:groups].nil? ? nil : Array(resource[:groups]).join(','),
      'password' => resource[:password],
    }
    with_client { |c| c.put(user_path, params) }
    @property_hash = { ensure: :present, name: resource[:name] }
    @created = true
  end

  def destroy
    with_client { |c| c.delete(user_path) }
    @property_hash = { ensure: :absent }
  end

  %i[display_name password roles groups].each do |prop|
    define_method("#{prop}=") do |value|
      (@changed ||= {})[prop] = value
    end
  end

  # PUT replaces the whole user, so re-read the current state and send every
  # field, overriding only what changed.
  def flush
    return if @created || @changed.nil? || @changed.empty? || @property_hash[:ensure] == :absent

    current = with_client { |c| c.get_or_nil(user_path) }
    raise Puppet::Error, "couchbase_user[#{resource[:name]}] disappeared while being updated" if current.nil?

    state = self.class.from_api(current).merge(@changed)
    params = {
      'name' => state[:display_name],
      'roles' => Array(state[:roles]).join(','),
      # Omitted when unused so Community Edition (no groups) keeps working.
      'groups' => (Array(state[:groups]).empty? && !@changed.key?(:groups)) ? nil : Array(state[:groups]).join(','),
    }
    params['password'] = @changed[:password] if @changed.key?(:password)
    with_client { |c| c.put(user_path, params) }
    @property_hash.merge!(@changed)
    @changed = nil
  end
end
