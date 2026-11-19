# frozen_string_literal: true

require 'spec_helper'

describe 'couchbase::find_self' do
  let(:node_facts) do
    {
      'networking' => {
        'fqdn' => 'cb02.example.com', 'hostname' => 'cb02', 'ip' => '10.0.0.12',
        'interfaces' => {
          'eth0' => { 'bindings' => [{ 'address' => '10.0.0.12' }] },
          'eth1' => { 'bindings' => [{ 'address' => '192.168.5.2' }], 'bindings6' => [{ 'address' => 'fd00::2' }] },
        }
      }
    }
  end

  it { is_expected.to run.with_params(['cb01.example.com', 'CB02.Example.com'], node_facts).and_return('CB02.Example.com') }
  it { is_expected.to run.with_params(['cb01', 'cb02'], node_facts).and_return('cb02') }
  it { is_expected.to run.with_params(['192.168.5.1', '192.168.5.2'], node_facts).and_return('192.168.5.2') }
  it { is_expected.to run.with_params(['fd00::1', 'fd00::2'], node_facts).and_return('fd00::2') }
  it { is_expected.to run.with_params(['cb01', 'cb03'], node_facts).and_raise_error(%r{none of cluster_nodes}) }
  it { is_expected.to run.with_params(['cb02', '10.0.0.12'], node_facts).and_raise_error(%r{several cluster_nodes entries}) }
end
