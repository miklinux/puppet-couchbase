# frozen_string_literal: true

require File.expand_path(File.join(File.dirname(__FILE__), '..', 'couchbase'))

Puppet::Type.type(:couchbase_xdcr_remote).provide(:rest, parent: Puppet::Provider::Couchbase) do
  desc 'Manages XDCR remote cluster references through the Couchbase REST API (/pools/default/remoteClusters).'

  mk_resource_methods

  def self.from_api(r)
    {
      name: r['name'], ensure: :present, uuid: r['uuid'],
      hostname: r['hostname'], username: r['username'],
      secure_type: (r['secureType'] || 'none').to_sym,
      certificate: r['certificate'].to_s.strip,
      # Couchbase 7.x+ checks the stored credentials periodically.
      auth_error: r['connectivityStatus'] == 'RC_AUTH_ERR',
    }
  end

  def self.instances
    with_client do |c|
      Array(c.get('/pools/default/remoteClusters')).reject { |r| r['deleted'] }.map { |r| new(from_api(r)) }
    end
  end

  def auth_failed?
    @property_hash[:auth_error] == true
  end

  def path
    "/pools/default/remoteClusters/#{self.class.url_escape(resource[:name])}"
  end

  # Every write must carry the full reference, password included.
  def params
    p = {
      'name' => resource[:name], 'hostname' => resource[:hostname], 'username' => resource[:username],
      'password' => resource[:password], 'secureType' => resource[:secure_type] || :none
    }
    p['certificate'] = resource[:certificate] if resource[:certificate]
    p['clientCertificate'] = resource[:client_certificate] if resource[:client_certificate]
    p['clientKey'] = resource[:client_key] if resource[:client_key]
    p
  end

  def create
    with_client do |c|
      c.post('/pools/default/remoteClusters', params)
    rescue PuppetX::Couchbase::HTTPError => e
      # Another node of the cluster created it a moment ago.
      raise unless e.code == 400 && e.body.to_s =~ /duplicate cluster names/i

      Puppet.notice("couchbase_xdcr_remote[#{resource[:name]}]: already created by another node")
    end
    @property_hash = { ensure: :present, name: resource[:name] }
  end

  def destroy
    with_client { |c| c.delete(path) }
    @property_hash = { ensure: :absent }
  end

  %i[hostname username password secure_type certificate].each do |prop|
    define_method("#{prop}=") { |_value| @changed = true }
  end

  def flush
    return unless @changed && @property_hash[:ensure] == :present

    with_client { |c| c.post(path, params) }
  end
end
