# frozen_string_literal: true

require File.expand_path(File.join(File.dirname(__FILE__), '..', 'couchbase'))
require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', '..', 'puppet_x', 'couchbase', 'settings'))

Puppet::Type.type(:couchbase_xdcr_replication).provide(:rest, parent: Puppet::Provider::Couchbase) do
  desc 'Manages XDCR replications through the Couchbase REST API (/controller/createReplication, /settings/replications).'

  mk_resource_methods

  # Replications as { "remote/from/to" => {id:, ...} }.
  def self.replications(client)
    remotes = Array(client.get('/pools/default/remoteClusters')).reject { |r| r['deleted'] }.to_h { |r| [r['uuid'], r['name']] }
    Array(client.get('/pools/default/tasks')).select { |t| t['type'] == 'xdcr' }.each_with_object({}) do |t, out|
      # "/remoteClusters/<remote uuid>/buckets/<bucket>"
      m = %r{\A/remoteClusters/([^/]+)/buckets/(.+)\z}.match(t['target'].to_s)
      next unless m && remotes[m[1]]

      key = "#{remotes[m[1]]}/#{t['source']}/#{m[2]}"
      out[key] = { id: t['id'], to_cluster: remotes[m[1]], from_bucket: t['source'], to_bucket: m[2],
                   paused: t['pauseRequested'] ? :true : :false }
    end
  end

  def self.settings_path(id)
    "/settings/replications/#{url_escape(id)}"
  end

  def self.instances
    with_client do |c|
      replications(c).map do |key, r|
        new(r.merge(name: key, ensure: :present, settings: c.get(settings_path(r[:id]))))
      end
    end
  end

  def self.prefetch(resources)
    with_client do |c|
      found = replications(c)
      resources.each_value do |resource|
        r = found[resource.key]
        next unless r

        resource.provider = new(r.merge(name: resource[:name], ensure: :present, settings: c.get(settings_path(r[:id]))))
      end
    end
  end

  def create
    params = {
      'fromBucket' => resource[:from_bucket], 'toCluster' => resource[:to_cluster],
      'toBucket' => resource[:to_bucket], 'replicationType' => 'continuous'
    }
    params.merge!(PuppetX::Couchbase::Settings.payload('xdcr_replication', resource[:settings], {})) if resource[:settings]
    params['pauseRequested'] = 'true' if resource[:paused].to_s == 'true'
    with_client do |c|
      c.post('/controller/createReplication', params)
    rescue PuppetX::Couchbase::HTTPError => e
      # Another node of the cluster created it a moment ago.
      raise unless e.code == 400 && e.body.to_s =~ /already exists/i

      Puppet.notice("#{resource.ref}: already created by another node")
    end
    @property_hash = { ensure: :present, name: resource[:name] }
  end

  def destroy
    with_client { |c| c.delete("/controller/cancelXDCR/#{self.class.url_escape(@property_hash[:id])}") }
    @property_hash = { ensure: :absent }
  end

  def settings=(_value)
    @changed = true
  end

  def paused=(_value)
    @changed = true
  end

  def flush
    return unless @changed && @property_hash[:ensure] == :present

    with_client { |c| c.post(self.class.settings_path(@property_hash[:id]), changes) }
  end

  # Only the fields that differ: re-sending an unchanged filter would make
  # Couchbase stream the whole bucket again.
  def changes
    params = {}
    desired = resource[:settings]
    if desired
      current = @property_hash[:settings] || {}
      changed = PuppetX::Couchbase::Settings.diff('xdcr_replication', desired, current).keys.map { |k| k.split('/').first }
      subset = PuppetX::Couchbase::Settings.stringify(desired).select { |k, _| changed.include?(k) || k == 'filterSkipRestream' }
      params.merge!(PuppetX::Couchbase::Settings.payload('xdcr_replication', subset, current)) unless subset.empty?
      # A new filter applies to documents replicated from now on unless
      # Couchbase streams the bucket again; restream unless told otherwise.
      params['filterSkipRestream'] ||= 'false' if params.key?('filterExpression')
    end
    params['pauseRequested'] = resource[:paused].to_s if resource[:paused].to_s != @property_hash[:paused].to_s
    params
  end
end
