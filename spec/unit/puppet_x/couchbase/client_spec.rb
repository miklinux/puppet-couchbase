# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/couchbase/client'

describe PuppetX::Couchbase::Client do
  it 'defaults to the local REST port' do
    expect(described_class.new.endpoint).to eq('http://127.0.0.1:8091')
  end

  it 'rejects invalid urls' do
    expect { described_class.new(url: 'ftp://x') }.to raise_error(PuppetX::Couchbase::Error)
  end

  it 'reports a missing config file clearly' do
    expect { described_class.from_config('/nonexistent/puppet.json') }.to raise_error(PuppetX::Couchbase::Error, %r{does not exist})
  end
end
