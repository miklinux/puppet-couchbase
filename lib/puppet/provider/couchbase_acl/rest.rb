# frozen_string_literal: true

require File.expand_path(File.join(File.dirname(__FILE__), '..', 'couchbase'))

Puppet::Type.type(:couchbase_acl).provide(:rest, parent: Puppet::Provider::Couchbase) do
  desc 'Grants single RBAC roles by read-modify-write of users and groups through the Couchbase REST API.'

  mk_resource_methods

  def self.instances
    with_client do |c|
      acls = []
      Array(c.get('/settings/rbac/users')).each do |u|
        kind = u['domain'].to_s == 'external' ? 'external' : 'user'
        PuppetX::Couchbase::Role.direct_from_api(u['roles']).each do |role|
          acls << new(name: "#{kind}:#{u['id']}/#{role}", principal: "#{kind}:#{u['id']}", role: role, ensure: :present)
        end
      end
      groups = begin
        c.get('/settings/rbac/groups')
      rescue PuppetX::Couchbase::HTTPError => e
        raise unless [400, 404].include?(e.code)

        []
      end
      Array(groups).each do |g|
        PuppetX::Couchbase::Role.direct_from_api(g['roles']).each do |role|
          acls << new(name: "group:#{g['id']}/#{role}", principal: "group:#{g['id']}", role: role, ensure: :present)
        end
      end
      acls
    end
  end

  def self.prefetch(resources)
    found = instances.each_with_object({}) { |p, h| h[p.name] = p }
    resources.each_value do |resource|
      provider = found[resource.acl_key]
      resource.provider = provider if provider
    end
  end

  def create
    update_roles { |roles| roles | [resource[:role]] }
    @property_hash[:ensure] = :present
  end

  def destroy
    update_roles { |roles| roles - [resource[:role]] }
    @property_hash[:ensure] = :absent
  end

  private

  def principal_parts
    kind, id = resource[:principal].split(':', 2)
    [kind, id]
  end

  # Read the principal fresh (other acl resources may have touched it in the
  # same run), apply the change and write everything back.
  def update_roles
    kind, id = principal_parts
    path = if kind == 'group'
             "/settings/rbac/groups/#{self.class.url_escape(id)}"
           else
             "/settings/rbac/users/#{kind == 'external' ? 'external' : 'local'}/#{self.class.url_escape(id)}"
           end

    with_client do |c|
      current = c.get_or_nil(path)
      raise Puppet::Error, "couchbase_acl[#{resource[:name]}]: #{resource[:principal]} does not exist" if current.nil?

      roles = yield(PuppetX::Couchbase::Role.direct_from_api(current['roles'])).uniq.sort
      params = if kind == 'group'
                 {
                   'description' => current['description'],
                   'ldap_group_ref' => current['ldap_group_ref'].to_s.empty? ? nil : current['ldap_group_ref'],
                   'roles' => roles.join(','),
                 }
               else
                 groups = Array(current['groups'])
                 {
                   'name' => current['name'],
                   'roles' => roles.join(','),
                   'groups' => groups.empty? ? nil : groups.join(','),
                 }
               end
      c.put(path, params)
    end
  end
end
