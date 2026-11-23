# frozen_string_literal: true

require 'spec_helper'

HIERA_FIXTURE = File.expand_path('../fixtures/hiera', __dir__)

def node_facts(fqdn, ip)
  short = fqdn.split('.').first
  {
    os: { family: 'Debian', name: 'Ubuntu', release: { major: '22.04', full: '22.04' } },
    networking: {
      fqdn: fqdn, hostname: short, ip: ip,
      interfaces: { eth0: { bindings: [{ address: ip }] }, lo: { bindings: [{ address: '127.0.0.1' }] } }
    },
  }
end

describe 'couchbase' do
  let(:hiera_config) { File.join(HIERA_FIXTURE, 'hiera.yaml') }

  it 'shares one Hiera file between members through symlinks' do
    dir = File.join(HIERA_FIXTURE, 'data', 'nodes')
    %w[cb02 cb03].each do |n|
      expect(File.symlink?(File.join(dir, "#{n}.example.com.yaml"))).to be true
    end
  end

  {
    'cb01.example.com' => '10.0.0.11',
    'cb02.example.com' => '10.0.0.12',
    'cb03.example.com' => '10.0.0.13',
  }.each do |fqdn, ip|
    context "on #{fqdn}" do
      let(:node) { fqdn }
      let(:facts) { node_facts(fqdn, ip) }

      it { is_expected.to compile.with_all_deps }

      it 'registers the node under its own entry of the shared member list' do
        is_expected.to contain_couchbase_cluster('production').with(
          hostname: fqdn,
          cluster_nodes: ['cb01.example.com', 'cb02.example.com', 'cb03.example.com'],
          services: ['kv', 'n1ql', 'index'],
          data_ramsize: 4096,
          auto_rebalance: true,
        )
      end

      it 'declares the same cluster-wide resources everywhere' do
        is_expected.to contain_couchbase_bucket('sessions').with(bucket_type: 'ephemeral', ram_quota: 512)
        is_expected.to contain_couchbase_user('webapp').with(display_name: 'Web application')
        is_expected.to contain_couchbase_acl('webapp full access to sessions')
          .with(user: 'webapp', role: 'bucket_full_access', bucket: 'sessions')
      end

      it 'keeps the admin password out of the catalog in clear' do
        is_expected.to contain_file('/etc/couchbase/puppet.json').with(mode: '0600', show_diff: false)
        expect(catalogue.resource('File', '/etc/couchbase/puppet.json').sensitive_parameters).to include(:content)
      end

      it 'orders config before the cluster and the cluster before the buckets' do
        is_expected.to contain_couchbase_cluster('production').that_requires('Class[couchbase::config]')
      end
    end
  end

  context 'when the members are listed by short name' do
    let(:node) { 'cb02.example.com' }
    let(:facts) { node_facts('cb02.example.com', '10.0.0.12') }
    let(:params) { { cluster_nodes: ['cb01', 'cb02', 'cb03'] } }

    it 'requires node_hostname, since the FQDN is not listed' do
      is_expected.to compile.and_raise_error(%r{node_hostname 'cb02.example.com' is not in cluster_nodes})
    end
  end

  context 'when the members are listed by IP address with node_hostname from facts' do
    let(:node) { 'cb03.example.com' }
    let(:facts) { node_facts('cb03.example.com', '10.0.0.13') }
    let(:params) { { cluster_nodes: ['10.0.0.11', '10.0.0.12', '10.0.0.13'], node_hostname: '10.0.0.13' } }

    it { is_expected.to contain_couchbase_cluster('production').with_hostname('10.0.0.13') }
  end

  context 'on a host that is not in the member list' do
    let(:node) { 'cb09.example.com' }
    let(:facts) { node_facts('cb09.example.com', '10.0.0.19') }
    let(:params) { { admin_password: 'changeme-please', cluster_nodes: ['cb01.example.com', 'cb02.example.com'] } }

    it { is_expected.to compile.and_raise_error(%r{node_hostname 'cb09.example.com' is not in cluster_nodes}) }
  end

  context 'with node_hostname set explicitly' do
    let(:node) { 'cb01.example.com' }
    let(:facts) { node_facts('cb01.example.com', '10.0.0.11') }
    let(:params) { { node_hostname: 'cb01-replication.example.com' } }

    it 'still has to be one of cluster_nodes' do
      is_expected.to compile.and_raise_error(%r{'cb01-replication.example.com' is not in cluster_nodes})
    end
  end

  context 'with UI / couchbase-cli service names' do
    let(:node) { 'standalone.example.com' }
    let(:facts) { node_facts('standalone.example.com', '10.0.0.50') }
    let(:params) { { admin_password: 'changeme-please', services: ['data', 'query', 'index', 'search'] } }

    # Passed through as declared; couchbase_cluster translates them to REST
    # names on the agent (see the type spec).
    it { is_expected.to contain_couchbase_cluster('default').with_services(%w[data query index search]) }
  end

  context 'with an unknown service name' do
    let(:node) { 'standalone.example.com' }
    let(:facts) { node_facts('standalone.example.com', '10.0.0.50') }
    let(:params) { { admin_password: 'changeme-please', services: ['data', 'cache'] } }

    it { is_expected.to compile.and_raise_error(%r{services}) }
  end

  context 'README "Quick start" example' do
    let(:node) { 'standalone.example.com' }
    let(:facts) { node_facts('standalone.example.com', '10.0.0.50') }
    let(:params) do
      {
        admin_user: 'admin', admin_password: sensitive('changeme-please'),
        services: ['data', 'query', 'index'], data_ramsize: 2048, index_ramsize: 512,
        buckets: { 'sessions' => { 'bucket_type' => 'ephemeral', 'ram_quota' => 256 } },
        users: { 'webapp' => { 'password' => sensitive('webapp-password'), 'roles' => ['bucket_full_access[sessions]'] } },
      }
    end

    it { is_expected.to compile.with_all_deps }
    it { is_expected.to contain_couchbase_bucket('sessions').with(bucket_type: 'ephemeral', ram_quota: 256) }
    it { is_expected.to contain_couchbase_user('webapp').with_roles(['bucket_full_access[sessions]']) }
  end

  describe 'README "Common setups"' do
    let(:node) { 'standalone.example.com' }
    let(:facts) { node_facts('standalone.example.com', '10.0.0.50') }

    context 'Community Edition from the download site' do
      let(:params) do
        { admin_password: 'changeme-please',
          package_source: 'https://packages.couchbase.com/releases/7.6.2/couchbase-server-community_7.6.2-linux_amd64.deb' }
      end

      it { is_expected.to compile.with_all_deps }
      it { is_expected.to contain_package('couchbase-server-community').with(provider: 'dpkg', source: '/var/cache/couchbase-puppet/couchbase-server-community_7.6.2-linux_amd64.deb') }
    end

    context 'Enterprise Edition from the download site' do
      let(:params) do
        { admin_password: 'changeme-please', edition: 'enterprise',
          package_source: 'https://packages.couchbase.com/releases/7.6.3/couchbase-server-enterprise_7.6.3-linux_amd64.deb' }
      end

      it { is_expected.to contain_package('couchbase-server').with(provider: 'dpkg', source: '/var/cache/couchbase-puppet/couchbase-server-enterprise_7.6.3-linux_amd64.deb') }
    end

    context 'an Enterprise download without edition' do
      let(:params) do
        { admin_password: 'changeme-please',
          package_source: 'https://packages.couchbase.com/releases/7.6.3/couchbase-server-enterprise_7.6.3-linux_amd64.deb' }
      end

      it { is_expected.to compile.and_raise_error(%r{is the enterprise edition, but edition is 'community'; set couchbase::edition: enterprise}) }
    end

    context 'a Community download with edition enterprise' do
      let(:params) do
        { admin_password: 'changeme-please', edition: 'enterprise',
          package_source: 'https://mirror.example.com/couchbase-server-community-7.6.2-linux.x86_64.rpm' }
      end

      it { is_expected.to compile.and_raise_error(%r{is the community edition, but edition is 'enterprise'}) }
    end

    context 'a download with no edition in its name' do
      let(:params) do
        { admin_password: 'changeme-please', package_source: 'https://mirror.example.com/couchbase.deb' }
      end

      it { is_expected.to contain_package('couchbase-server-community').with_source('/var/cache/couchbase-puppet/couchbase.deb') }
    end

    context 'a custom package_name' do
      let(:params) do
        { admin_password: 'changeme-please', package_name: 'cb-enterprise',
          package_source: 'https://mirror.example.com/couchbase-server-enterprise_7.6.3-linux_amd64.deb' }
      end

      it 'is trusted as given' do
        is_expected.to contain_package('cb-enterprise')
      end
    end

    context 'only managing resources on an existing installation' do
      let(:params) do
        { admin_password: 'changeme-please', manage_package: false, manage_service: false, manage_cluster: false,
          buckets: { 'sessions' => { 'ram_quota' => 256 } } }
      end

      it { is_expected.to compile.with_all_deps }
      it { is_expected.not_to contain_package('couchbase-server-community') }
      it { is_expected.not_to contain_service('couchbase-server') }
      it { is_expected.not_to contain_class('couchbase::cluster') }
      it { is_expected.to contain_file('/etc/couchbase/puppet.json') }
      it { is_expected.to contain_couchbase_bucket('sessions').with_ram_quota(256) }
    end
  end

  context 'as a single node (no cluster_nodes)' do
    let(:node) { 'standalone.example.com' }
    let(:facts) { node_facts('standalone.example.com', '10.0.0.50') }
    let(:params) { { admin_password: 'changeme-please' } }

    it { is_expected.to contain_couchbase_cluster('default').with(hostname: '127.0.0.1', cluster_nodes: []) }
    it { is_expected.to contain_package('couchbase-server-community') }
  end

  context 'with the Enterprise Edition' do
    let(:node) { 'standalone.example.com' }
    let(:facts) { node_facts('standalone.example.com', '10.0.0.50') }
    let(:params) { { admin_password: 'changeme-please', edition: 'enterprise' } }

    it { is_expected.to contain_package('couchbase-server') }
    it { is_expected.not_to contain_package('couchbase-server-community') }
  end
end

describe 'couchbase::cluster' do
  let(:node) { 'standalone.example.com' }
  let(:facts) { node_facts('standalone.example.com', '10.0.0.50') }

  it 'cannot be declared directly' do
    is_expected.to compile.and_raise_error(%r{private})
  end
end
