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
    report = apply(Puppet::Type.type(:couchbase_acl).new(title: 'user:u/ro_admin'))
    expect(report.resource_statuses['Couchbase_acl[user:u/ro_admin]'].changed).to be true
    expect(@fake.state[:users]['local/u'][:roles].split(',').sort).to eq(%w[admin ro_admin])
    expect(@fake.state[:users]['local/u'][:password]).to eq('secret1')
  end

  it 'resets drifted passwords' do
    apply(cluster, Puppet::Type.type(:couchbase_user).new(title: 'u', password: 'secret1'))
    @fake.state[:users]['local/u'][:password] = 'changed-elsewhere'
    report = apply(Puppet::Type.type(:couchbase_user).new(title: 'u', password: 'secret1'))
    expect(report.resource_statuses['Couchbase_user[u]'].changed).to be true
    expect(@fake.state[:users]['local/u'][:password]).to eq('secret1')
  end
end
