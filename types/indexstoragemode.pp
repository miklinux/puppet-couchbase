# @summary Storage mode of the index service: `plasma` (standard global
#   secondary indexes), `memory_optimized` (Enterprise Edition) or
#   `forestdb` (Community Edition).
type Couchbase::IndexStorageMode = Enum['plasma', 'memory_optimized', 'forestdb']
