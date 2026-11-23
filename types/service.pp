# @summary A Couchbase service name, either as shown in the UI and
#   couchbase-cli (data, query, search, analytics) or as used by the REST
#   API (kv, n1ql, fts, cbas).
type Couchbase::Service = Enum[
  'data', 'query', 'search', 'analytics',
  'kv', 'n1ql', 'index', 'fts', 'eventing', 'cbas', 'backup',
]
