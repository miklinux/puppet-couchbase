# frozen_string_literal: true

# Multi-node acceptance test: builds a Couchbase cluster out of Docker
# containers, the way N Puppet agents would.
#
#   ruby spec/acceptance/docker_cluster.rb [--rmi] IMAGE [IMAGE...]
#
# Every node gets a fixed IP on a private Docker network; its "Puppet run"
# talks to its own REST API and declares the same cluster_nodes list and the
# same cluster-wide resources (bucket, user, ACL). Scenario:
#
#   1. all 3 nodes run at once: only the bootstrap node may create the
#      cluster, the others must fail cleanly (nothing to join yet)
#   2. all 3 run at once again: nodes 2 and 3 join concurrently and get
#      rebalanced in; the cluster-wide resources stay untouched
#   3. all 3 run again: nothing to do
#   4. scale out: node 4 joins with auto_rebalance => false and stays
#      "inactiveAdded"; its next run with auto_rebalance => true rebalances
#      it in; then nothing to do anywhere with the 4-node list
#   5. graceful removal (README procedure): node 3 is dropped from the list
#      and rebalanced out; Couchbase resets it to unprovisioned; the
#      remaining nodes have nothing to do with the new list
#   6. dead node replacement (README procedure): node 4 dies, is hard
#      failed over and rebalanced out, then rebuilt empty at the same
#      address; its Puppet run joins it back

require 'json'
require 'net/http'
require 'open3'
require 'set'
require 'tmpdir'
require 'fileutils'

ROOT = File.expand_path('../..', __dir__)
SUBNET = ENV.fetch('CB_TEST_SUBNET', '172.31.250')
NETWORK = 'cb-puppet-acceptance'
ADMIN = %w[Administrator adminpass].freeze

class Failure < StandardError; end

def ip(i) = "#{SUBNET}.#{10 + i}"

def http(host, path, auth: true)
  Net::HTTP.start(host, 8091, open_timeout: 5, read_timeout: 30) do |h|
    req = Net::HTTP::Get.new(path)
    req.basic_auth(*ADMIN) if auth
    res = h.request(req)
    [res.code.to_i, (JSON.parse(res.body) rescue res.body)]
  end
rescue StandardError
  [nil, nil]
end

# Runs the exact couchbase-cli commands documented in the README
# ("Adding and removing nodes") on node 1.
def cb_cli(*args)
  sh('docker', 'exec', 'cb-acc-1', '/opt/couchbase/bin/couchbase-cli', *args,
     '-c', 'localhost', '-u', ADMIN[0], '-p', ADMIN[1])
end

# Community 7.6.x ships a couchbase-cli whose `rebalance` and `failover`
# fail with "Unable to get the HTTPS port"; the README gives the equivalent
# REST calls, which are run here in that case.
HTTPS_PORT_BUG = /Unable to get the HTTPS port/

def cb_cli_or_rest(args, rest)
  cb_cli(*args)
rescue Failure => e
  raise unless e.message.match?(HTTPS_PORT_BUG)

  puts "  couchbase-cli #{args.first} hit the CE 7.6 HTTPS port bug, using the README REST fallback"
  api = "api() { curl -fsS -u '#{ADMIN.join(':')}' \"http://localhost:8091$1\" \"${@:2}\"; }"
  known = "known=$(/opt/couchbase/bin/couchbase-cli server-list -c localhost -u #{ADMIN[0]} -p #{ADMIN[1]} | awk '{print $1}' | paste -sd,)"
  sh('docker', 'exec', 'cb-acc-1', 'bash', '-c', [api, known, rest].join("\n"))
  # The REST call only starts the rebalance; wait for it like the CLI does.
  600.times do
    _c, st = http(ip(1), '/pools/default/rebalanceProgress')
    break if st.is_a?(Hash) && st['status'] == 'none'

    sleep 1
  end
end

def otp(i) = "ns_1@#{ip(i)}"

def sh(*cmd)
  out, status = Open3.capture2e(*cmd)
  raise Failure, "#{cmd.join(' ')} failed:\n#{out}" unless status.success?

  out
end

def manifest(node, nodes, auto_rebalance: true)
  list = nodes.map { |n| "'#{ip(n)}'" }.join(', ')
  <<~PP
    couchbase_cluster { 'acceptance':
      hostname       => '#{ip(node)}',
      cluster_nodes  => [#{list}],
      services       => ['kv', 'n1ql', 'index'],
      data_ramsize   => 512,
      index_ramsize  => 256,
      auto_rebalance => #{auto_rebalance},
    }
    couchbase_bucket { 'shared': ram_quota => 128, replicas => 1 }
    couchbase_settings { 'auto_failover': settings => { 'enabled' => true, 'timeout' => 60 } }
    couchbase_user { 'app': password => Sensitive('app-password') }
    couchbase_acl { 'app full access to shared': user => 'app', role => 'bucket_full_access', bucket => 'shared' }
  PP
end

# Runs Puppet "on" node i (i.e. against its REST API).
def run_node(work, node, nodes, **opts)
  dir = File.join(work, "node#{node}")
  Dir.mkdir(dir) unless Dir.exist?(dir)
  File.write(File.join(dir, 'client.json'),
             JSON.generate(url: "http://#{ip(node)}:8091", username: ADMIN[0], password: ADMIN[1], timeout: 180))
  file = File.join(dir, 'site.pp')
  File.write(file, manifest(node, nodes, **opts))
  out, = Open3.capture2e({ 'PUPPET_COUCHBASE_CONFIG' => File.join(dir, 'client.json') },
                         'puppet', 'apply', '--color=false', '--modulepath', File.join(work, 'modules'),
                         '--vardir', File.join(dir, 'var'), '--confdir', File.join(dir, 'conf'),
                         '--publicdir', File.join(dir, 'public'), file)
  changes = out.scan(%r{^Notice: /Stage\[main\]/Main/(Couchbase_\w+\[.*\])/(\w+): }).map { |r, p| "#{r}/#{p}" }.to_set
  { node: node, changes: changes, errors: out.lines.grep(/^Error:/), out: out }
end

def run_parallel(work, nodes_to_run, nodes)
  nodes_to_run.map { |n| Thread.new { run_node(work, n, nodes) } }.map(&:value)
end

def expect_result(label, result, changes:, error: nil)
  problems = []
  if error
    problems << "expected an error matching #{error.inspect}" unless result[:errors].any? { |e| e =~ error }
  else
    problems << "errors:\n    #{result[:errors].join('    ')}" unless result[:errors].empty?
  end
  missing = changes.to_set - result[:changes]
  extra = result[:changes] - changes.to_set
  problems << "missing changes: #{missing.to_a.sort.join(', ')}" unless missing.empty?
  problems << "unexpected changes: #{extra.to_a.sort.join(', ')}" unless extra.empty?
  raise Failure, "#{label} node#{result[:node]}: #{problems.join("\n")}\n--- output ---\n#{result[:out]}" unless problems.empty?

  puts format('  %-22s node%d ok (%d changes%s)', label, result[:node], result[:changes].size, error ? ', expected error' : '')
end

def check(desc, cond)
  raise Failure, "check failed: #{desc}" unless cond

  puts "  check                  ok: #{desc}"
end

def cluster_nodes(host)
  _code, pool = http(host, '/pools/default')
  Array(pool.is_a?(Hash) ? pool['nodes'] : nil)
end

CLUSTER_WIDE = ['Couchbase_bucket[shared]/ensure', 'Couchbase_user[app]/ensure',
                'Couchbase_acl[app full access to shared]/ensure', 'Couchbase_settings[auto_failover]/settings'].freeze

def test_image(image)
  Dir.mktmpdir('cb-cluster') do |work|
    Dir.mkdir(File.join(work, 'modules'))
    File.symlink(ROOT, File.join(work, 'modules', 'couchbase'))
    sh('docker', 'pull', '-q', image)
    system('docker', 'network', 'rm', NETWORK, out: File::NULL, err: File::NULL)
    sh('docker', 'network', 'create', '--subnet', "#{SUBNET}.0/24", NETWORK)
    begin
      (1..4).each do |i|
        sh('docker', 'run', '-d', '--name', "cb-acc-#{i}", '--network', NETWORK, '--ip', ip(i), image)
      end
      (1..4).each do |i|
        120.times { break if http(ip(i), '/pools', auth: false)[0] == 200; sleep 1 }
      end
      _c, pools = http(ip(1), '/pools', auth: false)
      puts "  server                 #{pools['implementationVersion']}"

      three = [1, 2, 3]
      r = run_parallel(work, three, three)
      expect_result('1 parallel bootstrap', r[0], changes: ['Couchbase_cluster[acceptance]/ensure'] + CLUSTER_WIDE)
      # Nodes 2/3 either wait for the bootstrap node or, if it finished
      # provisioning before they looked, join it right away. Both are fine.
      joined = Set.new
      r[1..].each do |res|
        if res[:changes].include?('Couchbase_cluster[acceptance]/ensure')
          expect_result('1 parallel bootstrap', res, changes: ['Couchbase_cluster[acceptance]/ensure'])
          joined << res[:node]
        else
          expect_result('1 parallel bootstrap', res, changes: [], error: /joins once the bootstrap node/)
        end
      end

      r = run_parallel(work, three, three)
      expect_result('2 parallel join', r[0], changes: [])
      r[1..].each do |res|
        expect_result('2 parallel join', res, changes: joined.include?(res[:node]) ? [] : ['Couchbase_cluster[acceptance]/ensure'])
      end
      members = cluster_nodes(ip(1))
      check('3 nodes, all active', members.size == 3 && members.all? { |n| n['clusterMembership'] == 'active' })
      check('every node runs kv, n1ql and index', members.all? { |n| n['services'].sort == %w[index kv n1ql] })
      _c, bucket = http(ip(3), '/pools/default/buckets/shared')
      check('bucket spread over the 3 nodes', bucket.is_a?(Hash) && bucket['nodes'].size == 3)

      run_parallel(work, three, three).each { |res| expect_result('3 idempotent', res, changes: []) }

      four = [1, 2, 3, 4]
      res = run_node(work, 4, four, auto_rebalance: false)
      expect_result('4 join, no rebalance', res, changes: ['Couchbase_cluster[acceptance]/ensure'])
      me = cluster_nodes(ip(1)).find { |n| n['hostname'].start_with?("#{ip(4)}:") }
      check('node4 added but not rebalanced in', me && me['clusterMembership'] == 'inactiveAdded')
      res = run_node(work, 4, four)
      expect_result('4 rebalance in', res, changes: ['Couchbase_cluster[acceptance]/membership'])
      members = cluster_nodes(ip(1))
      check('4 nodes, all active', members.size == 4 && members.all? { |n| n['clusterMembership'] == 'active' })
      run_parallel(work, four, four).each { |res2| expect_result('4 idempotent', res2, changes: []) }

      # 5. graceful removal of node 3
      rest = [1, 2, 4]
      cb_cli_or_rest(['rebalance', '--server-remove', "#{ip(3)}:8091"],
                     %(api /controller/rebalance -d knownNodes="$known" -d ejectedNodes=#{otp(3)}))
      members = cluster_nodes(ip(1))
      check('node3 rebalanced out, 3 active nodes left',
            members.size == 3 && members.none? { |n| n['hostname'].start_with?("#{ip(3)}:") })
      # An ejected node wipes itself and restarts ns_server; give it time.
      state3 = nil
      90.times do
        code, pools3 = http(ip(3), '/pools', auth: false)
        state3 = [code, pools3.is_a?(Hash) ? pools3['pools'] : pools3]
        break if code == 200 && Array(state3[1]).empty?

        sleep 1
      end
      check("removed node3 is reset to unprovisioned (last seen: #{state3.inspect})",
            state3[0] == 200 && Array(state3[1]).empty?)
      run_parallel(work, rest, rest).each { |res2| expect_result('5 after removal', res2, changes: []) }

      # 6. node 4 dies and is replaced by an empty node at the same address
      sh('docker', 'kill', 'cb-acc-4')
      sleep 10
      cb_cli_or_rest(['failover', '--server-failover', "#{ip(4)}:8091", '--hard'],
                     %(api /controller/failOver -d otpNode=#{otp(4)}))
      cb_cli_or_rest(['rebalance'], %(api /controller/rebalance -d knownNodes="$known" -d ejectedNodes=))
      check('dead node4 failed over and rebalanced out', cluster_nodes(ip(1)).size == 2)
      sh('docker', 'rm', '-f', 'cb-acc-4')
      sh('docker', 'run', '-d', '--name', 'cb-acc-4', '--network', NETWORK, '--ip', ip(4), image)
      120.times { break if http(ip(4), '/pools', auth: false)[0] == 200; sleep 1 }
      FileUtils.rm_rf(File.join(work, 'node4', 'var'))
      expect_result('6 replacement joins', run_node(work, 4, rest), changes: ['Couchbase_cluster[acceptance]/ensure'])
      members = cluster_nodes(ip(1))
      check('3 active nodes again', members.size == 3 && members.all? { |n| n['clusterMembership'] == 'active' })
      run_parallel(work, rest, rest).each { |res2| expect_result('6 idempotent', res2, changes: []) }
    ensure
      (1..4).each { |i| system('docker', 'rm', '-f', "cb-acc-#{i}", out: File::NULL, err: File::NULL) }
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
