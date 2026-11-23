# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/couchbase/settings'

describe PuppetX::Couchbase::Settings do
  let(:failover) do
    { 'enabled' => true, 'timeout' => 120, 'count' => 0,
      'failoverOnDataDiskIssues' => { 'enabled' => false, 'timePeriod' => 120 }, 'maxCount' => 1 }
  end

  describe '.diff' do
    it 'compares only the fields given, across types' do
      expect(described_class.diff('auto_failover', { 'enabled' => 'true', 'timeout' => '120' }, failover)).to be_empty
      expect(described_class.diff('auto_failover', { 'timeout' => 60 }, failover)).to eq('timeout' => [120, 60])
    end

    it 'compares nested fields' do
      want = { 'failoverOnDataDiskIssues' => { 'enabled' => true, 'timePeriod' => 120 } }
      expect(described_class.diff('auto_failover', want, failover)).to eq('failoverOnDataDiskIssues/enabled' => [false, true])
    end

    it 'ignores the other fields while a feature is switched off' do
      expect(described_class.diff('auto_failover', { 'enabled' => false, 'timeout' => 60 }, failover.merge('enabled' => false))).to be_empty
    end

    it 'ignores maxCount while disableMaxCount is set' do
      current = failover.reject { |k, _| k == 'maxCount' }.merge('disableMaxCount' => true)
      expect(described_class.diff('auto_failover', { 'disableMaxCount' => true, 'maxCount' => 3 }, current)).to be_empty
    end

    it 'reads fields that are reported under another name' do
      expect(described_class.diff('auto_reprovision', { 'maxNodes' => 2 }, { 'enabled' => true, 'max_nodes' => 1 }))
        .to eq('maxNodes' => [1, 2])
    end

    it 'treats fields missing from sparse groups as not set yet' do
      expect(described_class.diff('data', { 'num_reader_threads' => 8 }, {})).to eq('num_reader_threads' => [nil, 8])
    end

    it 'knows values that the server reports differently' do
      expect(described_class.diff('data', { 'num_reader_threads' => 'default' }, { 'num_reader_threads' => 'balanced' })).to be_empty
    end

    it 'compares lists regardless of order' do
      current = { 'all_access' => false, 'allowed_urls' => ['https://b', 'https://a'], 'disallowed_urls' => [] }
      expect(described_class.diff('query_curl_access', { 'allowed_urls' => ['https://a', 'https://b'] }, current)).to be_empty
    end

    it 'reports fields the server does not have' do
      expect { described_class.diff('auto_failover', { 'maxCount' => 2 }, failover.reject { |k, _| k == 'maxCount' }) }
        .to raise_error(Puppet::Error, %r{does not report 'maxCount'})
    end

    it 'rejects unknown groups' do
      expect { described_class.diff('nope', {}, {}) }.to raise_error(ArgumentError, %r{Unknown settings group 'nope'})
    end
  end

  describe '.payload' do
    it 'always sends the switch, and the timeout it needs, from the current settings' do
      expect(described_class.payload('auto_failover', { 'failoverOnDataDiskIssues' => { 'enabled' => true } }, failover))
        .to eq('failoverOnDataDiskIssues[enabled]' => 'true', 'enabled' => 'true', 'timeout' => '120')
    end

    it 'sends only the switch when turning a feature off' do
      expect(described_class.payload('auto_reprovision', { 'enabled' => false, 'maxNodes' => 3 }, { 'enabled' => true, 'max_nodes' => 1 }))
        .to eq('enabled' => 'false')
    end

    it 'carries renamed fields under their write name' do
      expect(described_class.payload('auto_reprovision', { 'enabled' => true }, { 'enabled' => false, 'max_nodes' => 2 }))
        .to eq('enabled' => 'true', 'maxNodes' => '2')
    end

    it 'uses dotted names where the endpoint expects them' do
      expect(described_class.payload('resource_management', { 'diskUsage' => { 'enabled' => true, 'maximum' => 90 } }, {}))
        .to eq('diskUsage.enabled' => 'true', 'diskUsage.maximum' => '90')
    end

    it 'posts JSON groups as the whole object' do
      current = { 'all_access' => false, 'allowed_urls' => [], 'disallowed_urls' => [] }
      expect(described_class.payload('query_curl_access', { 'allowed_urls' => ['https://a'] }, current))
        .to eq('all_access' => false, 'allowed_urls' => ['https://a'], 'disallowed_urls' => [])
    end
  end
end
