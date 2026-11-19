# frozen_string_literal: true

require File.expand_path(File.join(File.dirname(__FILE__), '..', 'couchbase'))

Puppet::Type.type(:couchbase_group).provide(:rest, parent: Puppet::Provider::Couchbase) do
  desc 'Manages RBAC groups through the Couchbase REST API (/settings/rbac/groups).'

  mk_resource_methods

  def self.from_api(g)
    {
      name: g['id'],
      ensure: :present,
      description: g['description'].to_s,
      ldap_group_ref: g['ldap_group_ref'].to_s,
      roles: PuppetX::Couchbase::Role.direct_from_api(g['roles']),
    }
  end

  def self.instances
    with_client do |c|
      groups = begin
        c.get('/settings/rbac/groups')
      rescue PuppetX::Couchbase::HTTPError => e
        # Community Edition has no groups at all.
        raise unless [400, 404].include?(e.code)

        Puppet.debug("couchbase_group: groups not available (#{e.message})")
        []
      end
      Array(groups).map { |g| new(from_api(g)) }
    end
  end

  def group_path
    "/settings/rbac/groups/#{self.class.url_escape(resource[:name])}"
  end

  def create
    params = {
      'description' => resource[:description],
      'ldap_group_ref' => resource[:ldap_group_ref],
      'roles' => Array(resource[:roles]).join(','),
    }
    with_client { |c| c.put(group_path, params) }
    @property_hash = { ensure: :present, name: resource[:name] }
    @created = true
  end

  def destroy
    with_client { |c| c.delete(group_path) }
    @property_hash = { ensure: :absent }
  end

  %i[description ldap_group_ref roles].each do |prop|
    define_method("#{prop}=") do |value|
      (@changed ||= {})[prop] = value
    end
  end

  def flush
    return if @created || @changed.nil? || @changed.empty? || @property_hash[:ensure] == :absent

    current = with_client { |c| c.get_or_nil(group_path) }
    raise Puppet::Error, "couchbase_group[#{resource[:name]}] disappeared while being updated" if current.nil?

    state = self.class.from_api(current).merge(@changed)
    params = {
      'description' => state[:description],
      'ldap_group_ref' => state[:ldap_group_ref].to_s.empty? ? nil : state[:ldap_group_ref],
      'roles' => Array(state[:roles]).join(','),
    }
    with_client { |c| c.put(group_path, params) }
    @property_hash.merge!(@changed)
    @changed = nil
  end
end
