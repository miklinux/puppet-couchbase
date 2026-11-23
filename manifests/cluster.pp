# @summary Initialises or joins the cluster and manages its settings.
#
# @api private
class couchbase::cluster {
  assert_private()

  couchbase_cluster { $::couchbase::cluster_name:
    ensure             => 'present',
    hostname           => $::couchbase::_node_hostname,
    cluster_nodes      => $::couchbase::cluster_nodes,
    auto_rebalance     => $::couchbase::auto_rebalance,
    rebalance_timeout  => $::couchbase::rebalance_timeout,
    services           => $::couchbase::services,
    index_storage_mode => $::couchbase::index_storage_mode,
    data_ramsize       => $::couchbase::data_ramsize,
    index_ramsize      => $::couchbase::index_ramsize,
    fts_ramsize        => $::couchbase::fts_ramsize,
    eventing_ramsize   => $::couchbase::eventing_ramsize,
    analytics_ramsize  => $::couchbase::analytics_ramsize,
  }
}
