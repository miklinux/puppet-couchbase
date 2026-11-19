# frozen_string_literal: true

require File.expand_path(File.join(File.dirname(__FILE__), '..', 'couchbase'))

Puppet::Type.type(:couchbase_cluster).provide(:rest, parent: Puppet::Provider::Couchbase) do
  desc 'Initialises or joins the cluster and manages cluster settings through the Couchbase REST API.'

  # Puppet property => REST field in /pools/default and /clusterInit.
  def self.quota_fields
    {
      data_ramsize: 'memoryQuota',
      index_ramsize: 'indexMemoryQuota',
      fts_ramsize: 'ftsMemoryQuota',
      eventing_ramsize: 'eventingMemoryQuota',
      analytics_ramsize: 'cbasMemoryQuota',
    }
  end

  mk_resource_methods

  def self.instances
    with_client do |c|
      return [] unless c.initialized?

      pool = c.get('/pools/default')
      me = Array(pool['nodes']).find { |n| n['thisNode'] } || {}
      hash = { name: pool['clusterName'].to_s, ensure: :present, cluster_name: pool['clusterName'].to_s,
               membership: me['clusterMembership']&.to_sym }
      quota_fields.each { |prop, field| hash[prop] = pool[field].to_i if pool.key?(field) }
      [new(hash)]
    end
  end

  # A node belongs to exactly one cluster, so whatever the resource is
  # called, it describes the local one.
  def self.prefetch(resources)
    raise Puppet::Error, 'Only one couchbase_cluster resource can be declared per node' if resources.size > 1

    found = instances.first
    resources.each_value { |r| r.provider = found } if found
  end

  def create
    others = Array(resource[:cluster_nodes]) - [resource[:hostname].to_s]
    seed = find_cluster_member(others)
    if seed
      join(seed)
    elsif Array(resource[:cluster_nodes]).empty? || resource[:cluster_nodes].first == resource[:hostname].to_s
      initialize_cluster
    else
      raise Puppet::Error, "None of #{others.join(', ')} is part of a cluster yet; this node joins once the " \
                           "bootstrap node #{resource[:cluster_nodes].first} has created it (next Puppet run)"
    end
    @property_hash = { ensure: :present }
  end

  # First listed member that already belongs to a cluster.
  def find_cluster_member(candidates)
    candidates.find do |host|
      state = remote(host).probe
      Puppet.debug("couchbase_cluster: #{host} is #{state}")
      state == :initialized
    end
  end

  def remote(host)
    host_part = host.include?(':') && !host.start_with?('[') ? "[#{host}]" : host
    PuppetX::Couchbase::Client.new(url: "http://#{host_part}:#{resource[:port]}",
                                   username: client.username, password: client.password, timeout: 60)
  end

  # Asks an existing member to add this node, then rebalances it in.
  def join(seed)
    Puppet.notice("couchbase_cluster: joining the cluster through #{seed} as #{resource[:hostname]}")
    with_client do |c|
      if resource[:data_path] || resource[:index_path]
        c.post('/nodes/self/controller/settings',
               { 'path' => resource[:data_path], 'index_path' => resource[:index_path] }, auth: false)
      end
      remote(seed).post('/controller/addNode', {
                          'hostname' => resource[:hostname],
                          'user' => client.username,
                          'password' => client.password,
                          'services' => Array(resource[:services]).join(','),
                        })
      c.reset_ready!
      c.rebalance(resource[:rebalance_timeout]) if resource[:auto_rebalance].to_s == 'true'
    end
  rescue PuppetX::Couchbase::Error => e
    raise Puppet::Error, "Joining the cluster through #{seed} failed: #{e.message}"
  end

  def membership=(value)
    return unless value == :active

    Puppet.notice("couchbase_cluster: node is #{@property_hash[:membership]}, rebalancing it in")
    with_client { |c| c.rebalance(resource[:rebalance_timeout]) }
    @property_hash[:membership] = :active
  end

  def initialize_cluster
    params = {
      'hostname' => resource[:hostname],
      'services' => Array(resource[:services]).join(','),
      'clusterName' => resource[:cluster_name],
      'indexerStorageMode' => resource[:index_storage_mode],
      'dataPath' => resource[:data_path],
      'indexPath' => resource[:index_path],
      'sendStats' => resource[:send_stats].to_s == 'true',
      'username' => client.username,
      'password' => client.password,
      'port' => 'SAME',
    }
    self.class.quota_fields.each { |prop, field| params[field] = resource[prop] unless resource[prop].nil? }

    with_client do |c|
      res = c.request(:post, '/clusterInit', params: params, ok: [200, 202, 404], auth: false)
      # /clusterInit does not exist before 7.0: provision step by step.
      legacy_init(c, params) if res.code.to_i == 404
      # ns_server restarts parts of itself after provisioning.
      c.reset_ready!
    end
  end

  # Same sequence couchbase-cli cluster-init used on 6.x. Everything before
  # /settings/web runs unauthenticated, as the node has no admin yet.
  def legacy_init(c, params)
    if params['dataPath'] || params['indexPath']
      c.post('/nodes/self/controller/settings',
             { 'path' => params['dataPath'], 'index_path' => params['indexPath'] }, auth: false)
    end
    c.post('/node/controller/rename', { 'hostname' => params['hostname'] }, auth: false)
    c.post('/node/controller/setupServices', { 'services' => params['services'] }, auth: false)

    quotas = params.slice(*self.class.quota_fields.values)
    quotas['clusterName'] = params['clusterName']
    c.post('/pools/default', quotas, auth: false)

    if params['services'].split(',').include?('index')
      mode = params['indexerStorageMode']
      mode ||= c.get('/pools', auth: false)['isEnterprise'] ? 'plasma' : 'forestdb'
      c.post('/settings/indexes', { 'storageMode' => mode }, auth: false)
    end
    c.post('/settings/stats', { 'sendStats' => params['sendStats'] }, auth: false)
    c.post('/settings/web', { 'username' => params['username'], 'password' => params['password'], 'port' => 'SAME' },
           auth: false)
  end

  def destroy
    raise Puppet::Error, 'couchbase_cluster cannot be removed through Puppet'
  end

  def flush
    # Nothing changed (or the cluster was just initialised with everything).
    return unless @changed

    params = {}
    params['clusterName'] = resource[:cluster_name] if @changed.include?(:cluster_name)
    self.class.quota_fields.each do |prop, field|
      params[field] = resource[prop] if @changed.include?(prop)
    end
    @changed = nil
    return if params.empty?

    with_client { |c| c.post('/pools/default', params) }
  end

  ([:cluster_name] + quota_fields.keys).each do |prop|
    define_method("#{prop}=") do |value|
      (@changed ||= []) << prop
      @property_hash[prop] = value
    end
  end
end
