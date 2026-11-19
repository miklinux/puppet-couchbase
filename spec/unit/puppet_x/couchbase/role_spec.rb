# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/couchbase/role'

describe PuppetX::Couchbase::Role do
  describe '.normalize' do
    {
      'admin' => 'admin',
      ' ro_admin ' => 'ro_admin',
      'bucket_admin[*]' => 'bucket_admin[*]',
      'data_reader[b:*:*]' => 'data_reader[b]',
      'data_reader[b:s:*]' => 'data_reader[b:s]',
      'data_writer[ b : s : c ]' => 'data_writer[b:s:c]',
      'data_reader[*:*:*]' => 'data_reader[*]',
    }.each do |input, expected|
      it("#{input.inspect} -> #{expected}") { expect(described_class.normalize(input)).to eq(expected) }
    end

    ['', 'Admin', 'data_reader[]', 'data_reader[a:b:c:d]', 'data_reader[a::c]', 'x[y'].each do |bad|
      it("rejects #{bad.inspect}") { expect { described_class.normalize(bad) }.to raise_error(ArgumentError) }
    end
  end

  describe '.from_api' do
    it 'drops wildcard scope/collection' do
      obj = { 'role' => 'data_reader', 'bucket_name' => 'b', 'scope_name' => '*', 'collection_name' => '*' }
      expect(described_class.from_api(obj)).to eq('data_reader[b]')
    end

    it 'keeps cluster roles bare' do
      expect(described_class.from_api('role' => 'admin')).to eq('admin')
    end
  end

  describe '.direct_from_api' do
    it 'ignores roles inherited from groups only' do
      roles = [
        { 'role' => 'admin', 'origins' => [{ 'type' => 'group', 'name' => 'g' }] },
        { 'role' => 'ro_admin', 'origins' => [{ 'type' => 'group', 'name' => 'g' }, { 'type' => 'user' }] },
        { 'role' => 'bucket_admin', 'bucket_name' => 'x', 'origins' => [{ 'type' => 'user' }] },
      ]
      expect(described_class.direct_from_api(roles)).to eq(['bucket_admin[x]', 'ro_admin'])
    end
  end

  it 'extracts the bucket of a role' do
    expect(described_class.bucket('data_reader[b:s]')).to eq('b')
    expect(described_class.bucket('bucket_admin[*]')).to be_nil
    expect(described_class.bucket('admin')).to be_nil
  end
end
