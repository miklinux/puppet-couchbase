# frozen_string_literal: true

# XDCR acceptance test: two single-node clusters in Docker, a source and a
# target. Puppet runs against the source only.
#
#   ruby spec/acceptance/docker_xdcr.rb [--rmi] IMAGE [IMAGE...]
#
#   1. create a remote reference and a replication: documents written on the
#      source reach the target; the next run has nothing to do
#   2. pause it and change its settings; again nothing to do afterwards
#   3. the target changes the XDCR user's password: once Couchbase reports
#      the stored one as rejected (7.x and later), Puppet sends the new one
#   4. remove the replication and the reference in one run

require 'json'
require 'net/http'
require 'open3'
require 'set'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)
SUBNET = ENV.fetch('CB_TEST_SUBNET', '172.31.249')
NETWORK = 'cb-puppet-xdcr'
ADMIN = %w[Administrator adminpass].freeze
SOURCE = "#{SUBNET}.11"
TARGET = "#{SUBNET}.12"

class Failure < StandardError; end

def sh(*cmd)
  out, status = Open3.capture2e(*cmd)
  raise Failure, "#{cmd.join(' ')} failed:\n#{out}" unless status.success?

  out
end

def request(host, method, path, form = nil)
  Net::HTTP.start(host, 8091, open_timeout: 5, read_timeout: 30) do |h|
    req = Object.const_get("Net::HTTP::#{method}").new(path)
    req.basic_auth(*ADMIN)
    req.set_form_data(form) if form
    res = h.request(req)
    [res.code.to_i, (JSON.parse(res.body) rescue res.body)]
  end
rescue StandardError
  [nil, nil]
end

def check(desc, cond)
  raise Failure, "check failed: #{desc}" unless cond

  puts "  check      ok: #{desc}"
end

def wait_for(desc, seconds)
  seconds.times do
    return true if yield

    sleep 1
  end
  raise Failure, "timed out: #{desc}"
end

def cli(container, *args)
  sh('docker', 'exec', container, '/opt/couchbase/bin/couchbase-cli', *args, '-c', 'localhost', '-u', ADMIN[0], '-p', ADMIN[1])
end

def apply(work, name, manifest)
  file = File.join(work, "#{name}.pp")
  File.write(file, manifest)
  out, = Open3.capture2e({ 'PUPPET_COUCHBASE_CONFIG' => File.join(work, 'client.json') },
                         'puppet', 'apply', '--color=false', '--modulepath', File.join(work, 'modules'),
                         '--vardir', File.join(work, 'var'), '--confdir', File.join(work, 'conf'),
                         '--publicdir', File.join(work, 'public'), file)
  changes = out.scan(%r{^Notice: /Stage\[main\]/Main/(Couchbase_\w+\[.*\])/(\w+): }).map { |r, p| "#{r}/#{p}" }.to_set
  [changes, out.lines.grep(/^Error:/), out]
end

def expect_apply(work, name, manifest, expected)
  changes, errors, out = apply(work, name, manifest)
  problems = []
  problems << "errors:\n  #{errors.join('  ')}" unless errors.empty?
  missing = expected.to_set - changes
  extra = changes - expected.to_set
  problems << "missing changes: #{missing.to_a.sort.join(', ')}" unless missing.empty?
  problems << "unexpected changes: #{extra.to_a.sort.join(', ')}" unless extra.empty?
  raise Failure, "#{name}: #{problems.join("\n")}\n--- output ---\n#{out}" unless problems.empty?

  puts format('  %-10s ok (%d changes)', name, changes.size)
end

def manifest(password:, paused: false, settings: {}, ensure_value: 'present')
  list = settings.map { |k, v| "'#{k}' => '#{v}'" }.join(', ')
  if ensure_value == 'absent'
    return <<~PP
      couchbase_xdcr_remote { 'dr': ensure => 'absent' }
      couchbase_xdcr_replication { 'orders to dr': ensure => 'absent', from_bucket => 'orders', to_cluster => 'dr' }
    PP
  end

  <<~PP
    couchbase_xdcr_remote { 'dr':
      hostname => '#{TARGET}',
      username => 'xdcr',
      password => Sensitive('#{password}'),
    }
    couchbase_xdcr_replication { 'orders to dr':
      from_bucket => 'orders',
      to_cluster  => 'dr',
      paused      => #{paused},
      settings    => { #{list} },
    }
  PP
end

def item_count(host)
  _c, b = request(host, 'Get', '/pools/default/buckets/orders')
  b.is_a?(Hash) ? b.dig('basicStats', 'itemCount').to_i : -1
end

def write_docs(prefix, count)
  count.times do |i|
    code, = request(SOURCE, 'Post', "/pools/default/buckets/orders/docs/#{prefix}#{i}", 'value' => JSON.generate(n: i))
    raise Failure, "could not write #{prefix}#{i} (HTTP #{code})" unless code == 200
  end
end

def remote_status
  _c, list = request(SOURCE, 'Get', '/pools/default/remoteClusters')
  Array(list).find { |r| r['name'] == 'dr' }&.fetch('connectivityStatus', nil)
end

def test_image(image)
  Dir.mktmpdir('cb-xdcr') do |work|
    Dir.mkdir(File.join(work, 'modules'))
    File.symlink(ROOT, File.join(work, 'modules', 'couchbase'))
    File.write(File.join(work, 'client.json'),
               JSON.generate(url: "http://#{SOURCE}:8091", username: ADMIN[0], password: ADMIN[1], timeout: 180))
    sh('docker', 'pull', '-q', image)
    system('docker', 'network', 'rm', NETWORK, out: File::NULL, err: File::NULL)
    sh('docker', 'network', 'create', '--subnet', "#{SUBNET}.0/24", NETWORK)
    begin
      { 'cb-xdcr-src' => SOURCE, 'cb-xdcr-dst' => TARGET }.each do |name, ip|
        sh('docker', 'run', '-d', '--name', name, '--network', NETWORK, '--ip', ip, image)
      end
      { 'cb-xdcr-src' => SOURCE, 'cb-xdcr-dst' => TARGET }.each do |name, ip|
        wait_for("#{name} REST API", 120) { request(ip, 'Get', '/pools')[0] }
        cli(name, 'cluster-init', '--cluster-username', ADMIN[0], '--cluster-password', ADMIN[1],
            '--services', 'data', '--cluster-ramsize', '512')
        cli(name, 'bucket-create', '--bucket', 'orders', '--bucket-type', 'couchbase', '--bucket-ramsize', '100',
            '--bucket-replica', '0', '--wait', *(image.include?('community-8') ? ['--storage-backend', 'couchstore'] : []))
      end
      cli('cb-xdcr-dst', 'user-manage', '--set', '--rbac-username', 'xdcr', '--rbac-password', 'xdcr-pass-1',
          '--roles', 'admin', '--auth-domain', 'local')
      _c, pools = request(SOURCE, 'Get', '/pools')
      enterprise = pools['isEnterprise']
      puts "  server     #{pools['implementationVersion']}"

      # Enterprise-only settings are exercised where available.
      # (compressionType and priority can only be changed on Enterprise).
      first = enterprise ? { 'compressionType' => 'None', 'priority' => 'Medium' } : { 'workerBatchSize' => 1000 }
      second = enterprise ? { 'compressionType' => 'Auto', 'priority' => 'Low' } : { 'workerBatchSize' => 2000 }

      created = ['Couchbase_xdcr_remote[dr]/ensure', 'Couchbase_xdcr_replication[orders to dr]/ensure']
      expect_apply(work, 'create', manifest(password: 'xdcr-pass-1', settings: first), created)
      expect_apply(work, 'create-2', manifest(password: 'xdcr-pass-1', settings: first), [])
      write_docs('a', 5)
      wait_for('documents to reach the target', 120) { item_count(TARGET) == 5 }
      check('5 documents replicated to the target', true)

      expect_apply(work, 'change', manifest(password: 'xdcr-pass-1', paused: true, settings: second),
                   ['Couchbase_xdcr_replication[orders to dr]/paused', 'Couchbase_xdcr_replication[orders to dr]/settings'])
      expect_apply(work, 'change-2', manifest(password: 'xdcr-pass-1', paused: true, settings: second), [])
      write_docs('b', 3)
      sleep 10
      check('paused replication sends nothing', item_count(TARGET) == 5)

      rotated = !remote_status.nil?
      if rotated
        cli('cb-xdcr-dst', 'user-manage', '--set', '--rbac-username', 'xdcr', '--rbac-password', 'xdcr-pass-2',
            '--roles', 'admin', '--auth-domain', 'local')
        wait_for('Couchbase to notice the rejected password', 180) { remote_status == 'RC_AUTH_ERR' }
        expect_apply(work, 'password', manifest(password: 'xdcr-pass-2', paused: true, settings: second),
                     ['Couchbase_xdcr_remote[dr]/password'])
        wait_for('the reference to work again', 180) { remote_status == 'RC_OK' }
        expect_apply(work, 'password-2', manifest(password: 'xdcr-pass-2', paused: true, settings: second), [])
      else
        puts '  skip       password rotation: this version does not report connectivityStatus'
      end

      expect_apply(work, 'resume', manifest(password: rotated ? 'xdcr-pass-2' : 'xdcr-pass-1', settings: second),
                   ['Couchbase_xdcr_replication[orders to dr]/paused'])
      wait_for('the paused documents to reach the target', 120) { item_count(TARGET) == 8 }
      check('resumed replication caught up (8 documents)', true)

      expect_apply(work, 'remove', manifest(password: '', ensure_value: 'absent'),
                   ['Couchbase_xdcr_replication[orders to dr]/ensure', 'Couchbase_xdcr_remote[dr]/ensure'])
      expect_apply(work, 'remove-2', manifest(password: '', ensure_value: 'absent'), [])
      _c, remotes = request(SOURCE, 'Get', '/pools/default/remoteClusters')
      check('reference removed', Array(remotes).none? { |r| r['name'] == 'dr' && !r['deleted'] })
    ensure
      %w[cb-xdcr-src cb-xdcr-dst].each { |n| system('docker', 'rm', '-f', n, out: File::NULL, err: File::NULL) }
      system('docker', 'network', 'rm', NETWORK, out: File::NULL, err: File::NULL)
    end
  end
end

rmi = ARGV.delete('--rmi')
abort "usage: #{$PROGRAM_NAME} [--rmi] IMAGE..." if ARGV.empty?

results = ARGV.map do |image|
  puts "== #{image}"
  begin
    test_image(image)
    [image, 'PASS']
  rescue Failure => e
    puts e.message.gsub(/^/, '  ')
    [image, 'FAIL']
  ensure
    system('docker', 'rmi', image, out: File::NULL, err: File::NULL) if rmi
  end
end

puts "\n== summary"
results.each { |image, r| puts format('%-45s %s', image, r) }
exit(results.all? { |_, r| r == 'PASS' } ? 0 : 1)
