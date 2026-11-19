# frozen_string_literal: true

require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'puppet_x', 'couchbase', 'client'))
require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'puppet_x', 'couchbase', 'role'))

# Common parent for all couchbase_* REST providers.
class Puppet::Provider::Couchbase < Puppet::Provider
  # The client config is written by Puppet itself, so only confine on the
  # REST client being loadable - not on the file existing at compile time.
  confine feature: :posix

  class << self
    def client
      PuppetX::Couchbase::Client.instance
    end

    # Couchbase needs to be up (and the client config present) before any
    # resource can be prefetched; a failure here should fail the resources,
    # not the whole run.
    def with_client
      yield client
    rescue PuppetX::Couchbase::Error => e
      raise Puppet::Error, e.message
    end

    # Standard prefetch: match managed resources by name.
    def prefetch(resources)
      found = instances
      resources.each_key do |name|
        provider = found.find { |p| p.name == name }
        resources[name].provider = provider if provider
      end
    end

    def url_escape(value)
      URI.encode_www_form_component(value.to_s).gsub('+', '%20')
    end
  end

  def client
    self.class.client
  end

  def with_client(&block)
    self.class.with_client(&block)
  end

  def exists?
    @property_hash[:ensure] == :present
  end
end
