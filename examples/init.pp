# Single-node Couchbase with two buckets, a group, users and fine-grained grants.
class { 'couchbase':
  admin_password => Sensitive('changeme-please'),
  services       => ['kv', 'n1ql', 'index'],
  data_ramsize   => 2048,
  index_ramsize  => 512,
}

couchbase_bucket { 'sessions':
  bucket_type     => 'ephemeral',
  ram_quota       => 256,
  eviction_policy => 'nruEviction',
  max_ttl         => 3600,
}

couchbase_bucket { 'catalog':
  ram_quota       => 1024,
  replicas        => 1,
  storage_backend => 'magma',
  flush_enabled   => false,
}

# Authoritative role list on the group.
couchbase_group { 'developers':
  description => 'Read-only access to everything',
  roles       => ['data_reader[*]', 'query_select[*]'],
}

# Authoritative role list on the user.
couchbase_user { 'webapp':
  display_name => 'Web application',
  password     => Sensitive('webapp-password'),
  roles        => ['data_reader[sessions]', 'data_writer[sessions]'],
}

# No `roles` here: grants are added one by one with couchbase_acl, e.g. from
# the profiles that own each bucket.
couchbase_user { 'indexer':
  password => Sensitive('indexer-password'),
  groups   => ['developers'],
}
couchbase_acl { 'user:indexer/data_reader[catalog:inventory]': }
couchbase_acl { 'indexer can write the catalog products':
  principal => 'user:indexer',
  role      => 'data_writer[catalog:inventory:products]',
}
