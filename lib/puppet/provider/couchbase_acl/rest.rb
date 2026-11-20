# frozen_string_literal: true

require File.expand_path(File.join(File.dirname(__FILE__), '..', 'couchbase'))

Puppet::Type.type(:couchbase_acl).provide(:rest, parent: Puppet::Provider::Couchbase) do
  desc 'Grants single RBAC roles by read-modify-write of users and groups through the Couchbase REST API.'

  mk_resource_methods

  # One existing grant, described with the type's parameters. The name is
  # the grant's identity (principal/role), shown by `puppet resource`.
  def self.grant(principal_kind, id, role)
    name, params = PuppetX::Couchbase::Role.parse(role)
    hash = { name: "#{principal_kind}:#{id}/#{role}", ensure: :present, role: name }
    if principal_kind == 'group'
      hash[:group] = id
    else
      hash[:user] = id
      hash[:domain] = principal_kind == 'external' ? :external : :local
    end
    %i[bucket scope collection].zip(params).each { |key, value| hash[key] = value if value }
    new(hash)
  end

  # Grant details of a resource found on the server (nil otherwise).
  def discovered(attribute)
    @property_hash[attribute]
  end

  def self.instances
    with_client do |c|
      acls = []
      Array(c.get('/settings/rbac/users')).each do |u|
        kind = u['domain'].to_s == 'external' ? 'external' : 'user'
        PuppetX::Couchbase::Role.direct_from_api(u['roles']).each { |role| acls << grant(kind, u['id'], role) }
      end
      groups = begin
        c.get('/settings/rbac/groups')
      rescue PuppetX::Couchbase::HTTPError => e
        raise unless [400, 404].include?(e.code)

        []
      end
      Array(groups).each do |g|
        PuppetX::Couchbase::Role.direct_from_api(g['roles']).each { |role| acls << grant('group', g['id'], role) }
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
    update_roles { |roles| roles | [resource.role_spec] }
    @property_hash[:ensure] = :present
  end

  def destroy
    update_roles { |roles| roles - [resource.role_spec] }
    @property_hash[:ensure] = :absent
  end

  private

  def principal_parts
    resource.principal.split(':', 2)
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
      raise Puppet::Error, "couchbase_acl[#{resource[:name]}]: #{kind} '#{id}' does not exist" if current.nil?

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
