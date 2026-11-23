# frozen_string_literal: true

require File.expand_path(File.join(File.dirname(__FILE__), '..', 'couchbase'))
require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', '..', 'puppet_x', 'couchbase', 'settings'))

Puppet::Type.type(:couchbase_settings).provide(:rest, parent: Puppet::Provider::Couchbase) do
  desc 'Manages cluster-wide settings through the Couchbase REST API.'

  mk_resource_methods

  # Current settings of one group, or nil when this server doesn't have it.
  def self.fetch(client, name)
    client.get(PuppetX::Couchbase::Settings.group(name)[:path])
  rescue PuppetX::Couchbase::HTTPError => e
    raise unless [400, 404].include?(e.code) && e.body.to_s =~ PuppetX::Couchbase::Settings::UNSUPPORTED_RE

    nil
  end

  def self.instances
    with_client do |c|
      PuppetX::Couchbase::Settings.names.filter_map do |name|
        current = fetch(c, name)
        new(name: name, settings: current) if current.is_a?(Hash)
      end
    end
  end

  def self.prefetch(resources)
    with_client do |c|
      resources.each do |name, resource|
        current = fetch(c, name)
        resource.provider = new(name: name, settings: current, unsupported: current.nil?)
      end
    end
  end

  def settings
    if @property_hash[:unsupported]
      raise Puppet::Error, "couchbase_settings[#{resource[:name]}]: this Couchbase server has no #{resource[:name]} settings " \
                           '(not available in this version or edition)'
    end
    current = @property_hash[:settings]
    # Report fields this server doesn't have now, as one clear error,
    # rather than while Puppet compares values.
    desired = resource && resource.should(:settings)
    PuppetX::Couchbase::Settings.diff(resource[:name], desired, current) if desired.is_a?(Hash) && current.is_a?(Hash)
    current
  end

  def settings=(desired)
    name = resource[:name]
    group = PuppetX::Couchbase::Settings.group(name)
    body = PuppetX::Couchbase::Settings.payload(name, desired, @property_hash[:settings] || {})
    with_client do |c|
      group[:encoding] == :json ? c.post_json(group[:path], body) : c.post(group[:path], body)
      @property_hash[:settings] = self.class.fetch(c, name)
    end
  end
end
