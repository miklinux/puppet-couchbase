# @summary Installs the Couchbase Server package.
#
# Either from an already configured package repository, or from a .deb/.rpm
# URL given in `couchbase::package_source`.
#
# @api private
class couchbase::install {
  assert_private()

  if $couchbase::manage_package {
    if $couchbase::package_source {
      $filename = basename($couchbase::package_source)
      $local = "/var/cache/couchbase-puppet/${filename}"

      file { '/var/cache/couchbase-puppet':
        ensure => 'directory',
        owner  => 'root',
        group  => 'root',
        mode   => '0755',
      }

      file { $local:
        ensure   => 'file',
        source   => $couchbase::package_source,
        checksum => 'mtime',
        owner    => 'root',
        group    => 'root',
        mode     => '0644',
        before   => Package[$couchbase::_package_name],
      }

      $provider = $facts['os']['family'] ? {
        'Debian' => 'dpkg',
        default  => 'rpm',
      }

      package { $couchbase::_package_name:
        ensure   => $couchbase::package_ensure,
        provider => $provider,
        source   => $local,
      }
    } else {
      package { $couchbase::_package_name:
        ensure => $couchbase::package_ensure,
      }
    }
  }
}
