# @summary Runs the couchbase-server service.
#
# @api private
class couchbase::service {
  assert_private()

  if $couchbase::manage_service {
    service { $couchbase::service_name:
      ensure => running,
      enable => true,
    }
  }
}
