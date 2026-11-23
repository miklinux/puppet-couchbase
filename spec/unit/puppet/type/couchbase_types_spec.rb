# frozen_string_literal: true

require 'spec_helper'

describe 'couchbase types' do
  describe Puppet::Type.type(:couchbase_acl) do
    def acl(**params)
      described_class.new(title: 'grant', **params)
    end

    it 'builds a bucket-level grant from parameters' do
      a = acl(user: 'app', role: 'data_reader', bucket: 'catalog')
      expect(a.principal).to eq('user:app')
      expect(a.role_spec).to eq('data_reader[catalog]')
    end

    it 'builds collection-level, all-bucket and cluster-wide grants' do
      expect(acl(user: 'app', role: 'data_writer', bucket: 'b', scope: 's', collection: 'c').role_spec).to eq('data_writer[b:s:c]')
      expect(acl(group: 'devs', role: 'query_select', bucket: '*').acl_key).to eq('group:devs/query_select[*]')
      expect(acl(user: 'mon', role: 'ro_admin').role_spec).to eq('ro_admin')
    end

    it 'treats wildcard scope and collection as the whole bucket' do
      expect(acl(user: 'app', role: 'data_reader', bucket: 'b', scope: '*', collection: '*').role_spec).to eq('data_reader[b]')
    end

    it 'supports LDAP users' do
      expect(acl(user: 'alice', domain: 'external', role: 'ro_admin').principal).to eq('external:alice')
    end

    it 'requires exactly one of user and group' do
      expect { acl(role: 'ro_admin') }.to raise_error(Puppet::ResourceError, %r{either user or group})
      expect { acl(user: 'a', group: 'b', role: 'ro_admin') }.to raise_error(Puppet::ResourceError, %r{either user or group})
    end

    it 'requires a role' do
      expect { acl(user: 'a') }.to raise_error(Puppet::ResourceError, %r{role is required})
    end

    it 'asks for bucket/scope/collection parameters instead of the bracket syntax' do
      expect { acl(user: 'a', role: 'data_reader[b]') }.to raise_error(Puppet::ResourceError, %r{set bucket, scope and collection as parameters})
    end

    it 'requires bucket for scope and scope for collection' do
      expect { acl(user: 'a', role: 'data_reader', scope: 's') }.to raise_error(Puppet::ResourceError, %r{scope requires bucket})
      expect { acl(user: 'a', role: 'data_reader', bucket: 'b', collection: 'c') }.to raise_error(Puppet::ResourceError, %r{collection requires scope})
    end

    it 'refuses two resources granting the same role' do
      catalog = Puppet::Resource::Catalog.new
      catalog.add_resource(acl(user: 'app', role: 'data_reader', bucket: 'b'))
      twin = described_class.new(title: 'again', user: 'app', role: 'data_reader', bucket: 'b', scope: '*')
      catalog.add_resource(twin)
      expect { twin.pre_run_check }.to raise_error(Puppet::Error, %r{both manage data_reader\[b\] for user:app})
    end
  end

  describe Puppet::Type.type(:couchbase_user) do
    it 'normalises roles' do
      u = described_class.new(title: 'app', password: 'secret1', roles: ['data_reader[b:*:*]', 'admin'])
      expect(u.should(:roles)).to eq(['data_reader[b]', 'admin'])
      expect(u.property(:roles).insync?(['admin', 'data_reader[b]'])).to be true
    end

    it 'rejects passwords on external users' do
      expect { described_class.new(title: 'ldapuser', domain: 'external', password: 'secret1') }.to raise_error(Puppet::ResourceError)
    end

    it 'never prints passwords' do
      u = described_class.new(title: 'app', password: 'secret1')
      expect(u.property(:password).should_to_s('secret1')).to eq('[redacted]')
    end
  end

  describe Puppet::Type.type(:couchbase_bucket) do
    it 'validates eviction policy against bucket type' do
      expect {
        described_class.new(title: 'b', bucket_type: 'ephemeral', eviction_policy: 'fullEviction')
      }.to raise_error(Puppet::ResourceError, %r{not valid for ephemeral})
    end

    it 'rejects tiny quotas' do
      expect { described_class.new(title: 'b', ram_quota: 50) }.to raise_error(Puppet::ResourceError)
    end
  end

  describe Puppet::Type.type(:couchbase_cluster) do
    it 'translates UI / couchbase-cli service names to REST names' do
      c = described_class.new(title: 'c', services: ['data', 'Query', 'index', 'search', 'analytics', 'eventing', 'backup'])
      expect(c[:services]).to eq(%w[kv n1ql index fts cbas eventing backup])
    end

    it 'accepts REST names and mixed names, without duplicates' do
      expect(described_class.new(title: 'c', services: ['kv', 'data', 'n1ql'])[:services]).to eq(%w[kv n1ql])
    end

    it 'validates services' do
      expect { described_class.new(title: 'c', services: ['kv', 'nope']) }.to raise_error(Puppet::ResourceError)
    end

    it 'requires a reachable hostname for multi-node clusters' do
      expect {
        described_class.new(title: 'c', cluster_nodes: ['a', 'b'])
      }.to raise_error(Puppet::ResourceError, %r{hostname})
    end

    it 'defaults the cluster name to the title' do
      expect(described_class.new(title: 'prod')[:cluster_name]).to eq('prod')
    end
  end

  describe Puppet::Type.type(:couchbase_settings) do
    it 'accepts the known groups' do
      expect(described_class.new(title: 'auto_failover', settings: { 'enabled' => true })[:settings]).to eq('enabled' => true)
    end

    it 'rejects unknown groups' do
      expect { described_class.new(title: 'failover', settings: { 'enabled' => true }) }
        .to raise_error(Puppet::ResourceError, %r{Unknown settings group 'failover'})
    end

    it 'is applied after the cluster exists' do
      catalog = Puppet::Resource::Catalog.new
      cluster = Puppet::Type.type(:couchbase_cluster).new(title: 'default')
      xdcr = described_class.new(title: 'xdcr', settings: { 'goMaxProcs' => 8 })
      [cluster, xdcr].each { |r| catalog.add_resource(r) }
      expect(xdcr.autorequire.map(&:source)).to include(cluster)
    end

    it 'requires a non-empty hash' do
      expect { described_class.new(title: 'xdcr', settings: {}) }.to raise_error(Puppet::ResourceError, %r{must not be empty})
      expect { described_class.new(title: 'xdcr', settings: 'goMaxProcs=4') }.to raise_error(Puppet::ResourceError, %r{must be a hash})
    end
  end

  describe Puppet::Type.type(:couchbase_xdcr_remote) do
    it 'adds the default port' do
      expect(described_class.new(title: 'dr', hostname: 'dr.example.com', username: 'u', password: 'p')[:hostname]).to eq('dr.example.com:8091')
    end

    it 'requires hostname, username and password to create a reference' do
      expect { described_class.new(title: 'dr', username: 'u', password: 'p') }.to raise_error(Puppet::ResourceError, %r{hostname is required})
      expect { described_class.new(title: 'dr', hostname: 'h', password: 'p') }.to raise_error(Puppet::ResourceError, %r{username is required})
      expect { described_class.new(title: 'dr', hostname: 'h', username: 'u') }.to raise_error(Puppet::ResourceError, %r{password is required})
    end

    it 'needs nothing but the name to remove a reference' do
      expect { described_class.new(title: 'dr', ensure: 'absent') }.not_to raise_error
    end
  end

  describe Puppet::Type.type(:couchbase_xdcr_replication) do
    it 'replicates to a bucket of the same name by default' do
      r = described_class.new(title: 'x', from_bucket: 'orders', to_cluster: 'dr')
      expect(r[:to_bucket]).to eq('orders')
      expect(r.key).to eq('dr/orders/orders')
    end

    it 'requires from_bucket and to_cluster' do
      expect { described_class.new(title: 'x', to_cluster: 'dr') }.to raise_error(Puppet::ResourceError, %r{from_bucket is required})
      expect { described_class.new(title: 'x', from_bucket: 'orders') }.to raise_error(Puppet::ResourceError, %r{to_cluster is required})
    end

    it 'manages pausing through the paused attribute' do
      expect { described_class.new(title: 'x', from_bucket: 'o', to_cluster: 'dr', settings: { 'pauseRequested' => true }) }
        .to raise_error(Puppet::ResourceError, %r{use the paused attribute})
    end

    it 'refuses two resources managing the same replication' do
      catalog = Puppet::Resource::Catalog.new
      a = described_class.new(title: 'a', from_bucket: 'orders', to_cluster: 'dr')
      b = described_class.new(title: 'b', from_bucket: 'orders', to_cluster: 'dr', to_bucket: 'orders')
      [a, b].each { |r| catalog.add_resource(r) }
      expect { a.pre_run_check }.to raise_error(Puppet::Error, %r{both manage the replication of orders})
    end
  end
end
