# frozen_string_literal: true

require File.expand_path(File.join(File.dirname(__FILE__), '..', 'couchbase'))

Puppet::Type.type(:couchbase_bucket).provide(:rest, parent: Puppet::Provider::Couchbase) do
  desc 'Manages buckets through the Couchbase REST API (/pools/default/buckets).'

  mk_resource_methods

  # Puppet property => form field accepted on create and edit.
  def self.editable_fields
    {
      ram_quota: 'ramQuotaMB',
      replicas: 'replicaNumber',
      flush_enabled: 'flushEnabled',
      eviction_policy: 'evictionPolicy',
      durability_min_level: 'durabilityMinLevel',
      compression_mode: 'compressionMode',
      max_ttl: 'maxTTL',
    }
  end

  def self.from_api(b)
    type = case b['bucketType']
           when 'membase', 'couchbase' then :couchbase
           else b['bucketType'].to_s.to_sym
           end
    raw_ram = b.dig('quota', 'rawRAM') || b.dig('quota', 'ram')
    hash = {
      name: b['name'],
      ensure: :present,
      bucket_type: type,
      ram_quota: raw_ram ? (raw_ram.to_i / 1024 / 1024) : nil,
      replicas: b['replicaNumber'],
      flush_enabled: (b['controllers'].is_a?(Hash) && b['controllers'].key?('flush')) ? :true : :false,
      eviction_policy: b['evictionPolicy']&.to_sym,
      durability_min_level: b['durabilityMinLevel']&.to_sym,
      compression_mode: b['compressionMode']&.to_sym,
      max_ttl: b['maxTTL'],
      storage_backend: b['storageBackend']&.to_sym,
      conflict_resolution: b['conflictResolutionType']&.to_sym,
    }
    hash.reject { |_k, v| v.nil? }
  end

  def self.instances
    with_client do |c|
      Array(c.get('/pools/default/buckets')).map { |b| new(from_api(b)) }
    end
  end

  # Create-only settings cannot be changed in place: say so instead of
  # silently ignoring a manifest that no longer matches the bucket.
  def self.prefetch(resources)
    found = instances
    resources.each do |name, resource|
      provider = found.find { |p| p.name == name }
      next unless provider

      resource.provider = provider
      next if resource[:ensure] == :absent

      %i[bucket_type storage_backend conflict_resolution].each do |param|
        want = resource[param]
        have = provider.get(param)
        next if want.nil? || have.nil? || want.to_s == have.to_s

        Puppet.warning("couchbase_bucket[#{name}]: #{param} is #{have} but #{want} is requested; " \
                       'it can only be set at creation, so the bucket must be recreated to change it')
      end
    end
  end

  def self.form_value(prop, value)
    case prop
    when :flush_enabled then value.to_s == 'true' ? 1 : 0
    else value.to_s
    end
  end

  # Couchbase refuses bucket changes while a rebalance runs (e.g. a node
  # that is joining the cluster in the same Puppet run).
  def mutate
    with_client do |c|
      c.wait_for_rebalance(c.timeout * 10)
      yield c
    end
  end

  def bucket_path
    "/pools/default/buckets/#{self.class.url_escape(resource[:name])}"
  end

  def create
    type = (resource[:bucket_type] || :couchbase).to_sym
    params = { 'name' => resource[:name], 'bucketType' => type.to_s }
    params['storageBackend'] = resource[:storage_backend] if resource[:storage_backend]
    params['conflictResolutionType'] = resource[:conflict_resolution] if resource[:conflict_resolution]
    params['replicaIndex'] = resource[:replica_index].to_s == 'true' ? 1 : 0 unless resource[:replica_index].nil?
    params['ramQuotaMB'] = 100 if resource[:ram_quota].nil?
    self.class.editable_fields.each do |prop, field|
      next if resource[prop].nil?
      # memcached buckets know nothing about replicas/eviction/durability.
      next if type == :memcached && !%i[ram_quota flush_enabled].include?(prop)

      params[field] = self.class.form_value(prop, resource[prop])
    end

    mutate do |c|
      c.post('/pools/default/buckets', params)
    rescue PuppetX::Couchbase::HTTPError => e
      # Another node of the cluster created it a moment ago.
      raise unless e.code == 400 && e.body.to_s =~ /already exists/i

      Puppet.notice("couchbase_bucket[#{resource[:name]}]: already created by another node")
    end
    @property_hash = { ensure: :present, name: resource[:name] }
  end

  def destroy
    mutate { |c| c.delete(bucket_path) }
    @property_hash = { ensure: :absent }
  end

  self.editable_fields.each_key do |prop|
    define_method("#{prop}=") do |value|
      (@changed ||= {})[prop] = value
    end
  end

  def flush
    return if @changed.nil? || @changed.empty? || @property_hash[:ensure] == :absent

    if @changed.key?(:replicas)
      Puppet.warning("couchbase_bucket[#{resource[:name]}]: replica count changed, a rebalance is required for it to take effect")
    end
    params = @changed.each_with_object({}) do |(prop, value), h|
      h[self.class.editable_fields[prop]] = self.class.form_value(prop, value)
    end
    mutate { |c| c.post(bucket_path, params) }
    @property_hash.merge!(@changed)
    @changed = nil
  end
end
