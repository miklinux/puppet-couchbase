# frozen_string_literal: true

source 'https://rubygems.org'

gem 'puppet', ENV.fetch('PUPPET_GEM_VERSION', '>= 7.0')

group :development, :test do
  gem 'puppetlabs_spec_helper', '>= 7.0'
  gem 'rspec-puppet', '>= 4.0'
  gem 'puppet-lint', '>= 4.0'
  gem 'metadata-json-lint'
  gem 'rubocop', require: false
end
