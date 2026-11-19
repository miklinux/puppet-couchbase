# @summary Installs Couchbase Server and manages its cluster, buckets, users,
#   groups and RBAC grants through native Puppet types.
#
# The couchbase_* providers talk to the local REST API (`api_url`, by
# default http://127.0.0.1:8091) with the admin credentials, which are kept
# in a root-only file (/etc/couchbase/puppet.json).
#
# @param admin_password
#   Password of the full admin account; used for cluster-init and by every
#   couchbase_* provider. Accepts a Sensitive value.
# @param admin_user
#   Name of the built-in full admin account, created when the cluster is
#   set up. Changing it later requires renaming the account in Couchbase
#   first (see "Admin account" in the README).
# @param edition
#   `enterprise` or `community`; selects the default package name.
# @param package_name
#   Overrides the package name (default couchbase-server /
#   couchbase-server-community).
# @param package_ensure
#   `installed`, `latest` or a version.
# @param package_source
#   Optional URL of a .deb/.rpm to install instead of using a configured
#   repository, e.g.
#   https://packages.couchbase.com/releases/7.6.3/couchbase-server-enterprise_7.6.3-linux_amd64.deb
# @param manage_package
#   Whether to install the package.
# @param manage_service
#   Whether to manage the couchbase-server service.
# @param service_name
#   Name of the systemd service.
# @param api_url
#   REST endpoint used by the providers.
# @param api_timeout
#   Seconds to wait for the REST API to come up.
# @param manage_cluster
#   Whether to initialise the node / manage cluster settings.
# @param cluster_name
#   Cluster name (cluster-wide: use the same value on every node).
# @param cluster_nodes
#   Addresses of all cluster members, identical on every node. The first one
#   bootstraps the cluster; the others join it. Empty means single node.
# @param node_hostname
#   Address of this node as the other members reach it (and as written in
#   `cluster_nodes`). Defaults to 127.0.0.1 for a single node; otherwise the
#   entry of `cluster_nodes` matching this node's FQDN, short hostname or one
#   of its IP addresses (see couchbase::find_self), so the same Hiera data
#   can be shared by every member.
# @param auto_rebalance
#   Rebalance (and wait) when this node has been added to the cluster.
# @param rebalance_timeout
#   Seconds to wait for a rebalance.
# @param services
#   Services run by this node (used at initialisation).
# @param index_storage_mode
#   Index storage mode (used at initialisation).
# @param data_ramsize
#   Data service memory quota (MB).
# @param index_ramsize
#   Index service memory quota (MB).
# @param fts_ramsize
#   Search service memory quota (MB).
# @param eventing_ramsize
#   Eventing service memory quota (MB).
# @param analytics_ramsize
#   Analytics service memory quota (MB).
# @param buckets
#   Hash of couchbase_bucket resources.
# @param users
#   Hash of couchbase_user resources.
# @param groups
#   Hash of couchbase_group resources.
# @param acls
#   Hash of couchbase_acl resources.
#
# @example
#   class { 'couchbase':
#     admin_password => Sensitive('changeme-please'),
#     services       => ['kv', 'n1ql', 'index'],
#     data_ramsize   => 2048,
#     index_ramsize  => 512,
#     buckets        => { 'sessions' => { 'ram_quota' => 256 } },
#     users          => {
#       'app' => {
#         'password' => Sensitive('app-password'),
#         'roles'    => ['data_reader[sessions]', 'data_writer[sessions]'],
#       },
#     },
#   }
class couchbase (
  Variant[String[6], Sensitive[String[6]]] $admin_password,
  String[1] $admin_user = 'Administrator',
  Enum['enterprise', 'community'] $edition = 'enterprise',
  Optional[String[1]] $package_name = undef,
  String[1] $package_ensure = 'installed',
  Optional[Stdlib::HTTPUrl] $package_source = undef,
  Boolean $manage_package = true,
  Boolean $manage_service = true,
  String[1] $service_name = 'couchbase-server',
  Stdlib::HTTPUrl $api_url = 'http://127.0.0.1:8091',
  Integer[1] $api_timeout = 180,
  Boolean $manage_cluster = true,
  String[1] $cluster_name = 'couchbase',
  Array[String[1]] $cluster_nodes = [],
  Optional[String[1]] $node_hostname = undef,
  Boolean $auto_rebalance = true,
  Integer[1] $rebalance_timeout = 3600,
  Array[Enum['kv', 'n1ql', 'index', 'fts', 'eventing', 'cbas', 'backup'], 1] $services = ['kv', 'n1ql', 'index'],
  Optional[Enum['plasma', 'memory_optimized', 'forestdb']] $index_storage_mode = undef,
  Optional[Integer[256]] $data_ramsize = undef,
  Optional[Integer[256]] $index_ramsize = undef,
  Optional[Integer[256]] $fts_ramsize = undef,
  Optional[Integer[256]] $eventing_ramsize = undef,
  Optional[Integer[1024]] $analytics_ramsize = undef,
  Hash[String[1], Hash] $buckets = {},
  Hash[String[1], Hash] $users = {},
  Hash[String[1], Hash] $groups = {},
  Hash[String[1], Hash] $acls = {},
) {
  # Must match PuppetX::Couchbase::Client::DEFAULT_CONFIG_PATH.
  $client_config = '/etc/couchbase/puppet.json'

  $_package_name = pick($package_name, $edition ? {
      'enterprise' => 'couchbase-server',
      default      => 'couchbase-server-community',
  })

  $_node_hostname = $node_hostname.lest || {
    $cluster_nodes ? {
      []      => '127.0.0.1',
      default => couchbase::find_self($cluster_nodes, $facts),
    }
  }

  contain couchbase::install
  contain couchbase::service
  contain couchbase::config

  Class['couchbase::install']
  -> Class['couchbase::service']
  -> Class['couchbase::config']

  if $manage_cluster {
    contain couchbase::cluster
    Class['couchbase::config'] -> Class['couchbase::cluster']
  }

  $buckets.each |$name, $attrs| {
    couchbase_bucket { $name: * => $attrs }
  }
  $groups.each |$name, $attrs| {
    couchbase_group { $name: * => $attrs }
  }
  $users.each |$name, $attrs| {
    couchbase_user { $name: * => $attrs }
  }
  $acls.each |$name, $attrs| {
    couchbase_acl { $name: * => $attrs }
  }
}
