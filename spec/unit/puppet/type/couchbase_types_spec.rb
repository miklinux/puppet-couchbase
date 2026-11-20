# frozen_string_literal: true

require 'spec_helper'

describe 'couchbase types' do
  describe Puppet::Type.type(:couchbase_acl) do
    it 'derives principal and role from the title' do
      acl = described_class.new(title: 'user:app/data_reader[b:*:*]')
      expect(acl[:principal]).to eq('user:app')
      expect(acl[:role]).to eq('data_reader[b]')
      expect(acl.acl_key).to eq('user:app/data_reader[b]')
    end

    it 'accepts explicit parameters with a free-form title' do
      acl = described_class.new(title: 'devs query', principal: 'group:devs', role: 'query_select[*]')
      expect(acl.acl_key).to eq('group:devs/query_select[*]')
    end

    it 'requires principal and role' do
      expect { described_class.new(title: 'whatever') }.to raise_error(Puppet::ResourceError, %r{set principal and role})
    end

    it 'rejects bad principals' do
      expect { described_class.new(title: 'x', principal: 'robot:x', role: 'admin') }.to raise_error(Puppet::ResourceError)
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
end
