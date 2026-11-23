# @summary Writes the connection settings and admin credentials used by the
#   couchbase_* providers (root-only JSON file).
#
# @api private
class couchbase::config {
  assert_private()

  $password = $couchbase::admin_password ? {
    Sensitive => $couchbase::admin_password.unwrap,
    default   => $couchbase::admin_password,
  }

  $settings = {
    'url'      => $couchbase::api_url,
    'username' => $couchbase::admin_user,
    'password' => $password,
    'timeout'  => $couchbase::api_timeout,
  }

  file { dirname($couchbase::client_config):
    ensure => 'directory',
    owner  => 'root',
    group  => 'root',
    mode   => '0700',
  }

  file { $couchbase::client_config:
    ensure    => 'file',
    owner     => 'root',
    group     => 'root',
    mode      => '0600',
    content   => Sensitive(stdlib::to_json_pretty($settings)),
    show_diff => false,
  }
}
