# frozen_string_literal: true

begin
  require 'puppetlabs_spec_helper/module_spec_helper'
rescue LoadError
  # Plain rspec + the puppet gem is enough for the unit tests.
  require 'puppet'
  require 'tmpdir'
  dir = Dir.mktmpdir('puppet-couchbase-spec')
  Puppet.initialize_settings(['--vardir', dir, '--confdir', dir, '--codedir', dir, '--logdir', dir, '--rundir', dir])
  at_exit { FileUtils.rm_rf(dir) }
end

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
