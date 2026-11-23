# @summary A group of cluster-wide settings managed by couchbase_settings.
type Couchbase::SettingsGroup = Enum[
  'auto_failover', 'auto_reprovision', 'rebalance', 'retry_rebalance',
  'data', 'resource_management', 'query', 'query_curl_access', 'index', 'xdcr',
]
