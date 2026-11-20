# frozen_string_literal: true

require 'spec_helper'
require 'facter'

describe 'couchbase_version fact' do
  let(:version_file) { '/opt/couchbase/VERSION.txt' }

  before(:each) do
    Facter.clear
    allow(Facter.fact(:kernel)).to receive(:value).and_return('Linux')
    allow(File).to receive(:readable?).and_call_original
    allow(File).to receive(:read).and_call_original
    load File.expand_path('../../../lib/facter/couchbase_version.rb', __dir__)
  end

  after(:each) { Facter.clear }

  it 'reports the version and build of an installed server' do
    allow(File).to receive(:readable?).with(version_file).and_return(true)
    # Real content of the file in couchbase/server:enterprise-7.6.3.
    allow(File).to receive(:read).with(version_file).and_return("7.6.3-4200\n")
    expect(Facter.fact(:couchbase_version).value).to eq('7.6.3-4200')
  end

  it 'is not set when Couchbase Server is not installed' do
    allow(File).to receive(:readable?).with(version_file).and_return(false)
    expect(Facter.fact(:couchbase_version).value).to be_nil
  end

  it 'is not set when the version file is empty' do
    allow(File).to receive(:readable?).with(version_file).and_return(true)
    allow(File).to receive(:read).with(version_file).and_return("\n")
    expect(Facter.fact(:couchbase_version).value).to be_nil
  end
end
