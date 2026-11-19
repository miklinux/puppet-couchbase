# frozen_string_literal: true

# Acceptance test of the couchbase_* types against real Couchbase Server
# containers.
#
#   ruby spec/acceptance/docker_matrix.rb [--rmi] IMAGE [IMAGE...]
#   ruby spec/acceptance/docker_matrix.rb couchbase/server:community-6.6.0 couchbase/server:enterprise-7.6.3
#
# For every image: start a container, apply a "create" manifest, re-apply it
# (must be a no-op), apply a "change" manifest that modifies every mutable
# property, re-apply it (no-op again). Each apply must report *exactly* the
# expected set of changes. Passwords are additionally checked against the
# server. --rmi removes each image after its test (saves disk space).

require 'json'
require 'net/http'
require 'open3'
require 'set'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)
PORT = Integer(ENV.fetch('CB_TEST_PORT', '18091'))
ADMIN = %w[Administrator adminpass].freeze

CLUSTER = <<~PP
  couchbase_cluster { 'matrix':
    services      => ['kv', 'n1ql', 'index'],
    data_ramsize  => 512,
    index_ramsize => 256,
  }
PP

# Roles differ a lot between editions/versions (Community 6.6 only knows
# admin, ro_admin and bucket_full_access), so pick them from what the server
# reports in /settings/rbac/roles.
def role_plan(available, version)
  scoped = version.split('.').first.to_i >= 7
  if available.include?('data_reader')
    reader = scoped ? 'data_reader[data:_default:_default]' : 'data_reader[data]'
    {
      app_create: [reader, 'query_select[data]'],
      app_change: [reader, 'data_writer[data]'],
      acl_keep: 'bucket_admin[data]', acl_revoke: 'data_reader[cache]', acl_add: 'query_select[data]',
    }
  else
    {
      app_create: ['bucket_full_access[data]', 'ro_admin'],
      app_change: ['bucket_full_access[data]', 'bucket_full_access[cache]'],
      acl_keep: 'bucket_full_access[data]', acl_revoke: 'bucket_full_access[cache]', acl_add: 'ro_admin',
    }
  end
end

def pp_list(roles)
  "[#{roles.map { |r| "'#{r}'" }.join(', ')}]"
end

def create_manifest(f)
  <<~PP
    #{CLUSTER}
    couchbase_bucket { 'data':
      ram_quota            => 128,
      replicas             => 1,
      flush_enabled        => false,
      eviction_policy      => 'valueOnly',
      durability_min_level => 'none',
      #{f[:enterprise] ? 'max_ttl => 0,' : ''}
    }
    couchbase_bucket { 'cache':
      bucket_type     => 'ephemeral',
      ram_quota       => 100,
      eviction_policy => 'noEviction',
    }
    couchbase_bucket { 'doomed': ram_quota => 100 }
    couchbase_user { 'app':
      display_name => 'App',
      password     => Sensitive('app-pass-1'),
      roles        => #{pp_list(f[:roles][:app_create])},
    }
    couchbase_user { 'svc': password => 'svc-pass-1' }
    couchbase_user { 'doomed': password => 'doomed-pass' }
    couchbase_acl { 'user:svc/#{f[:roles][:acl_revoke]}': }
    couchbase_acl { 'user:svc/#{f[:roles][:acl_keep]}': }
  PP
end

def create_changes(f)
  [
    'Couchbase_bucket[data]/ensure', 'Couchbase_bucket[cache]/ensure', 'Couchbase_bucket[doomed]/ensure',
    'Couchbase_user[app]/ensure', 'Couchbase_user[svc]/ensure', 'Couchbase_user[doomed]/ensure',
    "Couchbase_acl[user:svc/#{f[:roles][:acl_revoke]}]/ensure", "Couchbase_acl[user:svc/#{f[:roles][:acl_keep]}]/ensure"
  ]
end

def change_manifest(f)
  <<~PP
    couchbase_cluster { 'matrix':
      cluster_name  => 'matrix-renamed',
      data_ramsize  => 768,
      index_ramsize => 256,
    }
    couchbase_bucket { 'data':
      conflict_resolution  => 'lww', # create-only: must warn, not change
      ram_quota            => 200,
      replicas             => 0,
      flush_enabled        => true,
      eviction_policy      => 'fullEviction',
      # 7.6+ refuses durability above 'none' on a single node.
      durability_min_level => '#{f[:durability] ? 'majority' : 'none'}',
      #{f[:enterprise] ? 'max_ttl => 600,' : ''}
    }
    couchbase_bucket { 'cache':
      bucket_type     => 'ephemeral',
      ram_quota       => 150,
      eviction_policy => 'nruEviction',
      #{f[:enterprise] ? 'max_ttl => 60,' : ''}
    }
    couchbase_bucket { 'doomed': ensure => absent }
    couchbase_user { 'app':
      display_name => 'App v2',
      password     => Sensitive('app-pass-2'),
      roles        => #{pp_list(f[:roles][:app_change])},
    }
    couchbase_user { 'svc': password => 'not-applied', password_management => on_create }
    couchbase_user { 'doomed': ensure => absent }
    couchbase_acl { 'user:svc/#{f[:roles][:acl_revoke]}': ensure => absent }
    couchbase_acl { 'user:svc/#{f[:roles][:acl_keep]}': }
    couchbase_acl { 'user:svc/#{f[:roles][:acl_add]}': }
  PP
end

def change_changes(f)
  list = [
    'Couchbase_cluster[matrix]/cluster_name', 'Couchbase_cluster[matrix]/data_ramsize',
    'Couchbase_bucket[data]/ram_quota', 'Couchbase_bucket[data]/replicas', 'Couchbase_bucket[data]/flush_enabled',
    'Couchbase_bucket[data]/eviction_policy',
    'Couchbase_bucket[cache]/ram_quota',
    'Couchbase_bucket[doomed]/ensure',
    'Couchbase_user[app]/display_name', 'Couchbase_user[app]/password', 'Couchbase_user[app]/roles',
    'Couchbase_user[doomed]/ensure',
    "Couchbase_acl[user:svc/#{f[:roles][:acl_revoke]}]/ensure", "Couchbase_acl[user:svc/#{f[:roles][:acl_add]}]/ensure"
  ]
  list += ['Couchbase_bucket[data]/max_ttl', 'Couchbase_bucket[cache]/max_ttl'] if f[:enterprise]
  list << 'Couchbase_bucket[data]/durability_min_level' if f[:durability]
  list
end

class Failure < StandardError; end

def http_code(path, user, pass)
  Net::HTTP.start('127.0.0.1', PORT, open_timeout: 5, read_timeout: 30) do |h|
    req = Net::HTTP::Get.new(path)
    req.basic_auth(user, pass) if user
    h.request(req).code.to_i
  end
rescue StandardError
  nil
end

def get_json(path)
  Net::HTTP.start('127.0.0.1', PORT) do |h|
    req = Net::HTTP::Get.new(path)
    req.basic_auth(*ADMIN)
    JSON.parse(h.request(req).body)
  end
end

def sh(*cmd)
  out, status = Open3.capture2e(*cmd)
  raise Failure, "#{cmd.join(' ')} failed:\n#{out}" unless status.success?

  out
end

def apply(work, name, manifest)
  file = File.join(work, "#{name}.pp")
  File.write(file, manifest)
  env = { 'PUPPET_COUCHBASE_CONFIG' => File.join(work, 'client.json') }
  out, = Open3.capture2e(env, 'puppet', 'apply', '--color=false', '--detailed-exitcodes',
                         '--modulepath', File.join(work, 'modules'), '--vardir', File.join(work, 'var'),
                         '--confdir', File.join(work, 'conf'), '--codedir', File.join(work, 'code'), file)
  changes = out.scan(%r{^Notice: /Stage\[main\]/Main/(Couchbase_\w+\[.*\])/(\w+): }).map { |r, p| "#{r}/#{p}" }
  errors = out.lines.grep(/^Error:/)
  warnings = out.lines.grep(/^Warning:/)
  [changes.to_set, errors, warnings, out]
end

def expect_apply(work, name, manifest, expected)
  changes, errors, warnings, out = apply(work, name, manifest)
  problems = []
  problems << "errors:\n  #{errors.join('  ')}" unless errors.empty?
  missing = expected.to_set - changes
  extra = changes - expected.to_set
  problems << "missing changes: #{missing.to_a.sort.join(', ')}" unless missing.empty?
  problems << "unexpected changes: #{extra.to_a.sort.join(', ')}" unless extra.empty?
  raise Failure, "#{name}: #{problems.join("\n")}\n--- output ---\n#{out}" unless problems.empty?

  puts format('  %-10s ok (%d changes)', name, changes.size)
  warnings
end

def check(desc, cond)
  raise Failure, "check failed: #{desc}" unless cond

  puts "  check      ok: #{desc}"
end

def test_image(image)
  name = "cb-matrix-#{Process.pid}"
  Dir.mktmpdir('cb-matrix') do |work|
    Dir.mkdir(File.join(work, 'modules'))
    File.symlink(ROOT, File.join(work, 'modules', 'couchbase'))
    File.write(File.join(work, 'client.json'),
               JSON.generate(url: "http://127.0.0.1:#{PORT}", username: ADMIN[0], password: ADMIN[1], timeout: 180))

    sh('docker', 'pull', '-q', image)
    sh('docker', 'run', '-d', '--name', name, '-p', "127.0.0.1:#{PORT}:8091", image)
    begin
      120.times do
        break if http_code('/pools', nil, nil) == 200

        sleep 1
      end
      pools = JSON.parse(Net::HTTP.get(URI("http://127.0.0.1:#{PORT}/pools")))
      puts "  server     #{pools['implementationVersion']} (#{pools['isEnterprise'] ? 'enterprise' : 'community'})"

      expect_apply(work, 'init', CLUSTER, ['Couchbase_cluster[matrix]/ensure'])
      roles = get_json('/settings/rbac/roles').map { |r| r['role'] }.uniq
      version = pools['implementationVersion'].split('.').first(2).map(&:to_i)
      f = { enterprise: pools['isEnterprise'], roles: role_plan(roles, pools['implementationVersion']),
            durability: (version <=> [7, 6]).negative? }
      puts "  roles      #{roles.size} available, using #{f[:roles][:app_create].join(', ')}"

      expect_apply(work, 'create', create_manifest(f), create_changes(f))
      expect_apply(work, 'create-2', create_manifest(f), [])
      check('app logs in with initial password', http_code('/whoami', 'app', 'app-pass-1') == 200)

      warnings = expect_apply(work, 'change', change_manifest(f), change_changes(f))
      check('create-only conflict_resolution change is reported as a warning',
            warnings.any? { |w| w.include?('couchbase_bucket[data]: conflict_resolution') })
      check('ephemeral eviction_policy change is reported as a warning',
            warnings.any? { |w| w.include?('couchbase_bucket[cache]: eviction_policy') })
      expect_apply(work, 'change-2', change_manifest(f), [])

      check('app logs in with the new password', http_code('/whoami', 'app', 'app-pass-2') == 200)
      check('app old password is rejected', http_code('/whoami', 'app', 'app-pass-1') == 401)
      check('svc keeps its password (on_create) through ACL updates', http_code('/whoami', 'svc', 'svc-pass-1') == 200)
      buckets = get_json('/pools/default/buckets').to_h { |b| [b['name'], b] }
      check('bucket data resized to 200MB', buckets.dig('data', 'quota', 'rawRAM') == 200 * 1024 * 1024)
      check('bucket doomed deleted', !buckets.key?('doomed'))
      check('cluster renamed', get_json('/pools/default')['clusterName'] == 'matrix-renamed')
    ensure
      system('docker', 'rm', '-f', name, out: File::NULL, err: File::NULL)
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
