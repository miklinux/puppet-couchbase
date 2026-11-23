# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'puppet_x/couchbase/client'
require_relative '../../../support/fake_couchbase'

# Runs the real providers against the in-memory fake REST API over HTTP on 127.0.0.1.
describe 'couchbase rest providers' do
  around(:each) do |example|
    Dir.mktmpdir('cb') do |dir|
      Dir.chdir(dir) do
        @fake = FakeCouchbase.new(0).listen
        server = Thread.new { @fake.run }
        File.write('client.json', JSON.generate(url: "http://127.0.0.1:#{@fake.port}", username: 'Administrator', password: 'adminpass', timeout: 5))
        ENV['PUPPET_COUCHBASE_CONFIG'] = File.join(dir, 'client.json')
        # Applying a catalog writes Puppet state files.
        Puppet[:statefile] = File.join(dir, 'state.yaml')
        Puppet[:transactionstorefile] = File.join(dir, 'transactionstore.yaml')
        PuppetX::Couchbase::Client.reset!
        begin
          example.run
        ensure
          server.kill
          ENV.delete('PUPPET_COUCHBASE_CONFIG')
        end
      end
    end
  end

  def apply(*resources)
    catalog = Puppet::Resource::Catalog.new
    resources.each { |r| catalog.add_resource(r) }
    catalog.apply.report
  end

  let(:cluster) { Puppet::Type.type(:couchbase_cluster).new(title: 'test', data_ramsize: 512) }

  it 'initialises the cluster and manages a bucket idempotently' do
    bucket = -> { Puppet::Type.type(:couchbase_bucket).new(title: 'b', ram_quota: 256, replicas: 0) }
    report = apply(cluster, bucket.call)
    expect(report.resource_statuses['Couchbase_bucket[b]'].changed).to be true
    expect(@fake.state[:buckets]['b']['quota']['rawRAM']).to eq(256 * 1024 * 1024)

    report = apply(Puppet::Type.type(:couchbase_cluster).new(title: 'test', data_ramsize: 512), bucket.call)
    expect(report.resource_statuses.values.map(&:changed)).to all(be false)
  end

  it 'never lets a non-bootstrap node create a cluster of its own' do
    node2 = Puppet::Type.type(:couchbase_cluster).new(
      title: 'test', hostname: 'cb2.invalid', cluster_nodes: ['cb1.invalid', 'cb2.invalid'],
    )
    report = apply(node2)
    expect(report.resource_statuses['Couchbase_cluster[test]'].failed).to be true
    expect(@fake.state[:initialized]).to be false
  end

  it 'lets the bootstrap node create the cluster when no member is up' do
    node1 = Puppet::Type.type(:couchbase_cluster).new(
      title: 'test', hostname: '127.0.0.2', cluster_nodes: ['127.0.0.2', 'cb2.invalid'], data_ramsize: 512,
    )
    apply(node1)
    expect(@fake.state[:initialized]).to be true
    expect(@fake.state[:nodes].first['otpNode']).to eq('ns_1@127.0.0.2')
  end

  it 'retries transient HTTP 500 answers on reads' do
    apply(cluster)
    @fake.flaky_pool_gets = 2
    report = apply(Puppet::Type.type(:couchbase_cluster).new(title: 'test', data_ramsize: 1024))
    expect(report.resource_statuses['Couchbase_cluster[test]'].failed).to be false
    expect(@fake.state[:pool]['memoryQuota'].to_i).to eq(1024)
  end

  it 'grants acls without touching other roles' do
    apply(cluster, Puppet::Type.type(:couchbase_user).new(title: 'u', password: 'secret1', roles: ['admin']))
    grant = -> { Puppet::Type.type(:couchbase_acl).new(title: 'u is read-only admin', user: 'u', role: 'ro_admin') }
    report = apply(grant.call)
    expect(report.resource_statuses['Couchbase_acl[u is read-only admin]'].changed).to be true
    expect(@fake.state[:users]['local/u'][:roles].split(',').sort).to eq(%w[admin ro_admin])
    expect(@fake.state[:users]['local/u'][:password]).to eq('secret1')

    report = apply(grant.call)
    expect(report.resource_statuses['Couchbase_acl[u is read-only admin]'].changed).to be false
  end

  it 'matches existing bucket-level grants and revokes them' do
    apply(cluster, Puppet::Type.type(:couchbase_bucket).new(title: 'b', ram_quota: 128),
          Puppet::Type.type(:couchbase_user).new(title: 'u', password: 'secret1'))
    acl = ->(ensure_value) do
      Puppet::Type.type(:couchbase_acl).new(title: 'u reads b', user: 'u', role: 'data_reader', bucket: 'b', ensure: ensure_value)
    end
    apply(acl.call(:present))
    expect(@fake.state[:users]['local/u'][:roles]).to eq('data_reader[b]')
    expect(apply(acl.call(:present)).resource_statuses['Couchbase_acl[u reads b]'].changed).to be false
    apply(acl.call(:absent))
    expect(@fake.state[:users]['local/u'][:roles]).to eq('')
  end

  it 'resets drifted passwords' do
    apply(cluster, Puppet::Type.type(:couchbase_user).new(title: 'u', password: 'secret1'))
    @fake.state[:users]['local/u'][:password] = 'changed-elsewhere'
    report = apply(Puppet::Type.type(:couchbase_user).new(title: 'u', password: 'secret1'))
    expect(report.resource_statuses['Couchbase_user[u]'].changed).to be true
    expect(@fake.state[:users]['local/u'][:password]).to eq('secret1')
  end

  describe 'couchbase_settings' do
    def settings(group, values)
      Puppet::Type.type(:couchbase_settings).new(title: group, settings: values)
    end

    def status(report, group)
      report.resource_statuses["Couchbase_settings[#{group}]"]
    end

    before(:each) { apply(cluster) }

    it 'changes only the fields given, then has nothing to do' do
      report = apply(settings('auto_failover', 'enabled' => true, 'timeout' => 60))
      expect(status(report, 'auto_failover').changed).to be true
      expect(@fake.state[:settings]['/settings/autoFailover']).to include('enabled' => true, 'timeout' => 60)

      report = apply(settings('auto_failover', 'enabled' => true, 'timeout' => 60))
      expect(status(report, 'auto_failover').changed).to be false
    end

    it 'adds the fields each endpoint requires from the current settings' do
      apply(settings('auto_failover', 'timeout' => 90))
      expect(@fake.state[:settings]['/settings/autoFailover']).to include('enabled' => true, 'timeout' => 90)
    end

    it 'keeps a switched-off feature stable' do
      apply(settings('auto_reprovision', 'enabled' => false, 'maxNodes' => 3))
      expect(@fake.state[:settings]['/settings/autoReprovision']).to include('enabled' => false)
      report = apply(settings('auto_reprovision', 'enabled' => false, 'maxNodes' => 3))
      expect(status(report, 'auto_reprovision').changed).to be false
    end

    it 'writes renamed fields under their write name' do
      apply(settings('auto_reprovision', 'enabled' => true, 'maxNodes' => 2))
      expect(@fake.state[:settings]['/settings/autoReprovision']['max_nodes']).to eq(2)
      expect(status(apply(settings('auto_reprovision', 'enabled' => true, 'maxNodes' => 2)), 'auto_reprovision').changed).to be false
    end

    it 'manages data, query, index and XDCR settings' do
      groups = {
        'data' => { 'num_reader_threads' => 8 },
        'query' => { 'queryTmpSpaceSize' => 2048 },
        'index' => { 'logLevel' => 'debug' },
        'xdcr' => { 'goMaxProcs' => 8 },
        'rebalance' => { 'rebalanceMovesPerNode' => 8 },
      }
      report = apply(*groups.map { |g, v| settings(g, v) })
      groups.each_key { |g| expect(status(report, g).changed).to be(true), g }
      expect(@fake.state[:settings]['/settings/replications']['goMaxProcs']).to eq(8)

      report = apply(*groups.map { |g, v| settings(g, v) })
      expect(report.resource_statuses.values.map(&:changed)).to all(be false)
    end

    it 'posts the CURL() access list as JSON' do
      apply(settings('query_curl_access', 'allowed_urls' => ['https://api.example.com']))
      expect(@fake.state[:settings]['/settings/querySettings/curlWhitelist'])
        .to eq('all_access' => false, 'allowed_urls' => ['https://api.example.com'], 'disallowed_urls' => [])
    end

    it 'fails clearly on groups the server does not have' do
      report = apply(settings('retry_rebalance', 'enabled' => true))
      expect(status(report, 'retry_rebalance').failed).to be true
      expect(report.logs.map(&:message).join).to match(%r{has no retry_rebalance settings})
    end

    it 'fails clearly on fields the server does not have' do
      report = apply(settings('index', 'noSuchField' => 1))
      expect(status(report, 'index').failed).to be true
      expect(report.logs.map(&:message).join).to match(%r{does not report 'noSuchField'})
    end
  end

  describe 'XDCR' do
    def remote(attrs = {})
      Puppet::Type.type(:couchbase_xdcr_remote).new(
        { title: 'dr', hostname: 'dr.example.com', username: 'xdcr', password: 'xdcr-pass' }.merge(attrs),
      )
    end

    def replication(attrs = {})
      Puppet::Type.type(:couchbase_xdcr_replication).new({ title: 'orders to dr', from_bucket: 'orders', to_cluster: 'dr' }.merge(attrs))
    end

    def changed(report)
      report.resource_statuses.select { |_, st| st.changed }.keys.sort
    end

    before(:each) { apply(cluster) }

    it 'creates a reference and a replication, then has nothing to do' do
      report = apply(remote, replication(settings: { 'compressionType' => 'None' }))
      expect(changed(report)).to eq(['Couchbase_xdcr_remote[dr]', 'Couchbase_xdcr_replication[orders to dr]'])
      expect(@fake.state[:remotes]['dr']).to include('hostname' => 'dr.example.com:8091', 'username' => 'xdcr')
      expect(@fake.state[:replications]['uuid1/orders/orders']).to include('compressionType' => 'None')

      report = apply(remote, replication(settings: { 'compressionType' => 'None' }))
      expect(changed(report)).to be_empty
    end

    it 'sends the password again only when the remote cluster rejects it' do
      apply(remote)
      @fake.state[:remotes]['dr']['connectivityStatus'] = 'RC_AUTH_ERR'
      report = apply(remote(password: 'new-pass'))
      expect(changed(report)).to eq(['Couchbase_xdcr_remote[dr]'])
      expect(@fake.state[:remote_passwords]['dr']).to eq('new-pass')
    end

    it 'updates the reference with every field Couchbase requires' do
      apply(remote)
      apply(remote(hostname: 'dr2.example.com'))
      expect(@fake.state[:remotes]['dr']['hostname']).to eq('dr2.example.com:8091')
      expect(@fake.state[:remote_passwords]['dr']).to eq('xdcr-pass')
    end

    it 'pauses and changes only the settings that differ' do
      apply(remote, replication(settings: { 'compressionType' => 'None', 'filterExpression' => 'x' }))
      @fake.state[:posted_replication_settings] = []
      report = apply(remote, replication(paused: true, settings: { 'compressionType' => 'Auto', 'filterExpression' => 'x' }))
      expect(changed(report)).to eq(['Couchbase_xdcr_replication[orders to dr]'])
      expect(@fake.state[:posted_replication_settings]).to eq([{ 'compressionType' => 'Auto', 'pauseRequested' => 'true' }])
      expect(@fake.state[:replications]['uuid1/orders/orders']).to include('pauseRequested' => true, 'compressionType' => 'Auto')
    end

    it 'restreams after a filter change unless told otherwise' do
      apply(remote, replication)
      apply(remote, replication(settings: { 'filterExpression' => 'region = "EU"' }))
      expect(@fake.state[:posted_replication_settings].last).to include('filterSkipRestream' => 'false')
      apply(remote, replication(settings: { 'filterExpression' => 'region = "US"', 'filterSkipRestream' => true }))
      expect(@fake.state[:posted_replication_settings].last).to include('filterSkipRestream' => 'true')
      expect(changed(apply(remote, replication(settings: { 'filterExpression' => 'region = "US"', 'filterSkipRestream' => true })))).to be_empty
    end

    it 'removes the replication before the reference it uses' do
      apply(remote, replication)
      report = apply(remote(ensure: 'absent'), replication(ensure: 'absent'))
      expect(report.resource_statuses.values.map(&:failed)).to all(be false)
      expect(@fake.state[:remotes]).to be_empty
      expect(@fake.state[:replications]).to be_empty
    end

    it 'tells replications to different buckets apart' do
      apply(remote, replication, replication(title: 'orders to archive', to_bucket: 'orders-archive'))
      expect(@fake.state[:replications].keys.sort).to eq(['uuid1/orders/orders', 'uuid1/orders/orders-archive'])
      expect(changed(apply(remote, replication, replication(title: 'orders to archive', to_bucket: 'orders-archive')))).to be_empty
    end
  end
end
