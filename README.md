# puppet-couchbase

[![CI](https://github.com/miklinux/puppet-couchbase/actions/workflows/ci.yml/badge.svg)](https://github.com/miklinux/puppet-couchbase/actions/workflows/ci.yml)

A Puppet module that installs **Couchbase Server** and manages it end to end:
single nodes or clusters of any size, buckets, users, groups and role-based
access control. It uses native Puppet types, so every setting is idempotent,
reports exactly what changed, and works with `puppet resource`.

- **Clusters from one Hiera file.** Every node gets the same data; nodes find
  themselves, the first one creates the cluster, and the others join and
  rebalance on their own.
- **Buckets, users, groups and ACLs** as resources, with in-place updates
  (bucket sizes, passwords, roles and more).
- **Two ways to grant access:** a complete role list per user, or individual
  grants declared wherever they belong.
- **Community and Enterprise**, Couchbase Server 6.6 through 8.0.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Managing data and access](#managing-data-and-access)
- [Clusters](#clusters)
- [Operations](#operations)
- [Reference](#reference)
- [Compatibility](#compatibility)
- [Limitations](#limitations)
- [How it works](#how-it-works)
- [Development](#development)

## Requirements

- Puppet 7 or 8, with `puppetlabs-stdlib` 9.x
- A systemd-based Linux: Debian, Ubuntu, RHEL, Rocky or AlmaLinux
- Couchbase Server 6.6 or later, either from a package repository the node
  already uses or from a download URL (`package_source`)
- In a cluster, the Couchbase ports open between nodes: 8091–8096, 11210, and
  21100 or higher

## Installation

Add the module and its dependency to your control repository's `Puppetfile`.
r10k doesn't resolve dependencies, so `stdlib` must be listed too.

```ruby
mod 'puppetlabs-stdlib', '9.7.0'

mod 'couchbase',
  git: 'https://github.com/miklinux/puppet-couchbase.git',
  tag: 'v0.3.0'
```

Pin a release with `tag:`, follow development with `branch: 'main'`, or pin a
commit with `ref:`. Keep the module name `couchbase`.

Without r10k:

```sh
puppet module install puppetlabs-stdlib --version 9.7.0
git clone --branch v0.3.0 https://github.com/miklinux/puppet-couchbase.git \
  /etc/puppetlabs/code/environments/production/modules/couchbase
```

## Quick start

A single node with one bucket and one application user:

```puppet
class { 'couchbase':
  admin_user     => 'admin',
  admin_password => Sensitive('changeme-please'),
  services       => ['data', 'query', 'index'],
  data_ramsize   => 2048,
  index_ramsize  => 512,
  buckets        => {
    'sessions' => { 'bucket_type' => 'ephemeral', 'ram_quota' => 256 },
  },
  users          => {
    'webapp' => {
      'password' => Sensitive('webapp-password'),
      'roles'    => ['bucket_full_access[sessions]'],
    },
  },
}
```

The same in Hiera, with `include couchbase` in the node's role or profile:

```yaml
couchbase::admin_user: 'admin'
couchbase::admin_password: 'changeme-please'   # encrypt with eyaml
couchbase::services: ['data', 'query', 'index']
couchbase::data_ramsize: 2048
couchbase::index_ramsize: 512
couchbase::buckets:
  sessions: { bucket_type: 'ephemeral', ram_quota: 256 }
couchbase::users:
  webapp:
    password: 'webapp-password'
    roles: ['bucket_full_access[sessions]']
```

To keep the admin password out of logs and reports, add this to `common.yaml`:

```yaml
lookup_options:
  couchbase::admin_password:
    convert_to: Sensitive
```

The first run installs Couchbase, creates the cluster, then creates the
bucket and the user. Later runs only change what differs from the manifest.

> **Choose the admin name before the first run.** Couchbase creates the
> admin account when the cluster is set up (default name: `Administrator`).
> Changing it later takes a short manual procedure; see
> [Renaming the admin](#renaming-the-admin-or-changing-its-password).

## Managing data and access

Buckets, users, groups and ACLs can be declared through the class's
`buckets`, `users`, `groups` and `acls` hashes, or as resources anywhere in
your code. They apply to the whole cluster, so in a cluster you can declare
them on one node or on all of them.

### Buckets

```puppet
couchbase_bucket { 'catalog':
  ram_quota            => 1024,   # MB per node
  replicas             => 1,
  eviction_policy      => 'fullEviction',
  durability_min_level => 'majority',
}

couchbase_bucket { 'cache':
  bucket_type     => 'ephemeral',
  ram_quota       => 256,
  eviction_policy => 'nruEviction',
  flush_enabled   => true,
}

couchbase_bucket { 'legacy': ensure => absent }
```

- The minimum `ram_quota` is 100 MB, and the total of all buckets must fit in
  the cluster's `data_ramsize`. Couchbase rejects a bucket that doesn't fit.
- Changing `ram_quota`, `replicas`, `flush_enabled`, `eviction_policy`,
  `durability_min_level`, `compression_mode` or `max_ttl` updates the bucket
  in place. A new `replicas` value takes effect after the next rebalance.
- `bucket_type`, `storage_backend`, `conflict_resolution`, `replica_index`,
  and the eviction policy of ephemeral buckets can only be set when the
  bucket is created. If they later differ, Puppet logs a warning and leaves
  the bucket alone. Changing them means recreating the bucket, which deletes
  its data.

### Users and roles

```puppet
couchbase_user { 'webapp':
  display_name => 'Web application',
  password     => Sensitive('webapp-password'),
  roles        => ['data_reader[sessions]', 'data_writer[sessions]'],
}

couchbase_user { 'alice':           # LDAP user (Enterprise Edition)
  domain => 'external',
  groups => ['ops'],
}
```

Roles use Couchbase's syntax: `admin`, `ro_admin`, `bucket_full_access[*]`,
`data_reader[bucket]`, `data_writer[bucket:scope:collection]`. Equivalent
forms, such as `data_reader[b]` and `data_reader[b:*:*]`, count as the same
role.

**Passwords.** Puppet checks a password by logging in as the user, and resets
it when it doesn't match. To set it only when the user is created, and let
people change it afterwards, use `password_management => on_create`.
Passwords are never shown in logs or reports.

**Community Edition** only has three roles: `admin`, `ro_admin` and
`bucket_full_access[...]`. The others, such as `data_reader` and
`query_select`, need Enterprise Edition.

### Two ways to grant roles

1. **A complete list** with `roles` on a user or group. Puppet removes any
   role not in the list (roles inherited from groups aren't affected).
2. **Individual grants** with `couchbase_acl`, leaving `roles` unset. Each
   grant adds or removes one role and leaves the rest alone. This suits code
   where each profile grants access to its own bucket.

```puppet
couchbase_user { 'indexer': password => Sensitive('indexer-password') }

couchbase_acl { 'indexer reads the catalog':
  user   => 'indexer',
  role   => 'data_reader',
  bucket => 'catalog',
}

couchbase_acl { 'indexer writes products':
  user       => 'indexer',
  role       => 'data_writer',
  bucket     => 'catalog',
  scope      => 'inventory',
  collection => 'products',
}

couchbase_acl { 'monitoring is read-only admin':
  user => 'monitoring',
  role => 'ro_admin',          # cluster-wide: no bucket
}

couchbase_acl { 'support no longer queries':
  ensure => absent,
  group  => 'support',
  role   => 'query_select',
  bucket => '*',               # every bucket
}
```

The title is just a label. Each grant names a `user` or a `group`, a `role`,
and optionally the `bucket`, `scope` and `collection` it applies to. In
Hiera, through the class:

```yaml
couchbase::acls:
  indexer reads the catalog:
    user: 'indexer'
    role: 'data_reader'
    bucket: 'catalog'
```

Puppet refuses the whole run, before changing anything, if two grants cover
the same role for the same user or group, or if a grant contradicts a
complete `roles` list. Otherwise the two would undo each other on every run.

### Groups

Groups need Enterprise Edition.

```puppet
couchbase_group { 'developers':
  description    => 'Read access to everything',
  roles          => ['data_reader[*]', 'query_select[*]'],
  ldap_group_ref => 'cn=developers,ou=groups,dc=example,dc=com',   # optional
}
```

## Clusters

Give every node the **same data** and the list of members in
`cluster_nodes`. The first node in the list creates the cluster; each other
node joins it on its first Puppet run after the cluster exists, and Puppet
rebalances it in.

### One Hiera file for every member

Put the cluster's data in one node file and symlink the other members to it:

```
data/nodes/cb01.example.com.yaml                            # the real file
data/nodes/cb02.example.com.yaml -> cb01.example.com.yaml
data/nodes/cb03.example.com.yaml -> cb01.example.com.yaml
```

```yaml
# data/nodes/cb01.example.com.yaml
couchbase::admin_user: 'admin'
couchbase::admin_password: 'changeme-please'   # encrypt with eyaml
couchbase::cluster_name: 'production'
couchbase::cluster_nodes:
  - 'cb01.example.com'
  - 'cb02.example.com'
  - 'cb03.example.com'
couchbase::services: ['data', 'query', 'index']
couchbase::data_ramsize: 4096
couchbase::index_ramsize: 1024
couchbase::buckets:
  sessions: { bucket_type: 'ephemeral', ram_quota: 512, replicas: 1 }
couchbase::users:
  webapp: { password: 'webapp-password', roles: ['bucket_full_access[sessions]'] }
```

Each node identifies itself by its FQDN, which must appear in
`cluster_nodes`. A host that isn't listed fails to compile, so a machine
that receives the data by mistake, or one you have removed from the cluster,
can't join it.

To list members by IP address instead, keep the file shared and add:

```yaml
couchbase::node_hostname: "%{facts.networking.ip}"
```

Keep `cluster_name`, the memory quotas and the admin credentials the same on
every node; they belong to the whole cluster. `services` is per node, so a
node with different services needs its own file.

A Hiera level per cluster (for example `clusters/%{facts.couchbase_cluster}.yaml`,
using a custom fact) works just as well and avoids symlinks, which some
Windows checkouts turn into plain files.

### Rolling it out

Run Puppet on all members, in any order or at the same time.

1. The first node installs Couchbase and creates the cluster, its buckets
   and its users.
2. Members that run before the cluster exists stop with "joins once the
   bootstrap node … has created it". This is expected: they join on their
   next run.
3. Each joining node is added with its own `services`, then Puppet rebalances
   and waits for the rebalance to finish. Several nodes can join at once.
4. Once every node has joined, Puppet runs report no changes.

Check the result on any node:

```sh
/opt/couchbase/bin/couchbase-cli server-list -c localhost -u admin -p 'changeme-please'
```

## Operations

The commands below use this shorthand, run on any node that stays in the
cluster:

```sh
cb() { /opt/couchbase/bin/couchbase-cli "$@" -c localhost -u admin -p 'changeme-please'; }
```

### Add a node

1. Append the node to `cluster_nodes`, keeping the current first entry first.
2. Give it the cluster's data, for example
   `ln -s cb01.example.com.yaml cb04.example.com.yaml`.
3. Run Puppet on it. It installs Couchbase, joins, and is rebalanced in. The
   other nodes change nothing.

To choose when the data moves, for example outside business hours, set
`couchbase::auto_rebalance: false` for the new node. It joins without taking
any data; rebalance later with `cb rebalance`, or by running Puppet with
`auto_rebalance` back on.

### Remove a node

Take the node out of Puppet **before** removing it from the cluster. Couchbase
wipes a removed node back to an empty state, and if the node were still
listed, its next Puppet run would join it again.

1. Remove it from `cluster_nodes`, delete its data file or symlink, and
   deploy. Its catalog now fails to compile, so Puppet leaves it alone.
2. Make sure the remaining nodes have enough memory and disk for the data,
   and enough nodes for each bucket's `replicas` and `durability_min_level`.
3. Rebalance it out; its data moves to the other nodes first:
   `cb rebalance --server-remove cb03.example.com:8091`
4. Decommission the machine, or remove the `couchbase` class from it.

### Replace a failed node

1. Fail it over and rebalance it out:
   `cb failover --server-failover cb03.example.com:8091 --hard`, then
   `cb rebalance`. Use `--hard` when the node is unreachable; leave it out
   (graceful failover) when the node still runs.
2. Rebuild the machine. It can keep its name and its place in
   `cluster_nodes`, or join under a new name as in [Add a node](#add-a-node).
3. Run Puppet on it. It joins and is rebalanced in.

Complete step 1 before running Puppet on a rebuilt node that keeps its old
address: until the old instance has been rebalanced out, the cluster can't
add a new node at that address.

The first node in `cluster_nodes` is only special while no cluster exists.
Rebuild or retire it like any other node: a rebuilt first node joins the
running cluster instead of creating a new one.

### When couchbase-cli rebalance or failover fails

On Community 7.6.2, `cb rebalance` and `cb failover` stop with
`ERROR: Unable to get the HTTPS port of the … node`. This is a `couchbase-cli`
bug (Community Edition has no HTTPS management port); the cluster itself is
fine. Make the same calls through the REST API:

```sh
api() { curl -fsS -u 'admin:changeme-please' "http://localhost:8091$1" "${@:2}"; }
known=$(cb server-list | awk '{print $1}' | paste -sd,)   # every node, e.g. ns_1@cb01.example.com,...

# cb rebalance --server-remove cb03.example.com:8091
api /controller/rebalance -d knownNodes="$known" -d ejectedNodes=ns_1@cb03.example.com

# cb failover --server-failover cb03.example.com:8091 --hard
api /controller/failOver -d otpNode=ns_1@cb03.example.com

# cb rebalance
api /controller/rebalance -d knownNodes="$known" -d ejectedNodes=
```

Node names are the first column of `cb server-list`. Unlike `couchbase-cli`,
the REST calls return as soon as the rebalance starts; follow it with
`cb rebalance-status` or in the web console.

### Move to new hardware or change a node's services

Couchbase can't change the services of a node that is already in a cluster.
Add the new nodes with `auto_rebalance: false`, then run
`cb rebalance --server-remove old-node:8091`. This adds the new nodes and
removes the old one in a single rebalance (a "swap rebalance").

### Renaming the admin or changing its password

Change the credentials in **Couchbase first, then in Hiera**. Puppet logs in
with the credentials from Hiera, so it can't rename the account it is using.
The admin belongs to the whole cluster: the command runs once, on any node.

1. **Prepare.** List everything else that logs in as the admin: applications,
   monitoring, backup jobs (`cbbackupmgr`), scripts, and XDCR references on
   other clusters that replicate with this one. They stop working at step 2
   until updated. Optionally pause Puppet on the cluster nodes:
   `puppet agent --disable 'renaming the Couchbase admin'`.
2. **Change the credentials in Couchbase**, on any one node:
   ```sh
   /opt/couchbase/bin/couchbase-cli setting-cluster -c localhost \
     -u Administrator -p '<current-password>' \
     --cluster-username admin --cluster-password '<new-password>'
   ```
   Check that the new credentials work on every node:
   ```sh
   curl -s -o /dev/null -w '%{http_code}\n' -u 'admin:<new-password>' http://localhost:8091/pools/default   # 200
   ```
3. **Update Hiera** (`couchbase::admin_user`, `couchbase::admin_password`)
   and deploy.
4. **Run Puppet on every node** (`puppet agent --enable` first, if you
   paused it). The runs should report no changes. Then update the consumers
   from step 1.

Between steps 2 and 4, Puppet runs fail with "authentication failed" and
change nothing; data and other users are unaffected.

- **Password only:** keep the current name in step 2, and change only
  `couchbase::admin_password` in step 3.
- **Lost password:** in step 2, run this as root on any node instead. It
  doesn't need the current password:
  `/opt/couchbase/bin/couchbase-cli reset-admin-password --new-password '<new-password>'`
- **Rolling back:** repeat step 2 with the old values, and revert Hiera.

## Reference

### Class `couchbase`

The only class to declare. Its steps run in the private classes
`couchbase::install`, `couchbase::service`, `couchbase::config` and
`couchbase::cluster`, which can't be declared on their own. `admin_password`
is the only required parameter.

**Admin account**

| Parameter | Default | Description |
|---|---|---|
| `admin_password` | *required* | Password of the built-in admin. String or `Sensitive`, at least 6 characters. |
| `admin_user` | `'Administrator'` | Name of the built-in admin. Set it before the cluster is first created. |

**Installation**

| Parameter | Default | Description |
|---|---|---|
| `edition` | `'community'` | `community` (package `couchbase-server-community`) or `enterprise` (package `couchbase-server`). Choose it when building a node: Puppet doesn't replace one edition's package with the other, and a cluster can't mix editions. |
| `package_name` | per `edition` | Overrides the package name, for example for a package republished under another name. |
| `package_ensure` | `'installed'` | `installed`, `latest` or a version. |
| `package_source` | — | URL of a `.deb` or `.rpm` to install instead of using a repository. Set `edition` to match the file; a mismatch fails the catalog. |
| `manage_package` | `true` | `false` when Couchbase is installed some other way. |
| `manage_service` | `true` | `false` without systemd, for example in containers. |
| `service_name` | `'couchbase-server'` | Name of the systemd service. |

**Cluster**

| Parameter | Default | Description |
|---|---|---|
| `manage_cluster` | `true` | `false` when the cluster is created some other way. Buckets, users, groups and ACLs are still managed. |
| `cluster_name` | `'default'` | Name shown in the web console. |
| `cluster_nodes` | `[]` | All members, identical on every node; the first one creates the cluster. Empty for a single node. |
| `node_hostname` | FQDN (`127.0.0.1` for a single node) | This node's address as the other members reach it. Must be one of `cluster_nodes`. |
| `services` | `['kv', 'n1ql', 'index']` | This node's services: `data`, `query`, `index`, `search`, `analytics`, `eventing`, `backup`. The REST names (`kv`, `n1ql`, `fts`, `cbas`) work too. Applied when the node creates or joins the cluster. |
| `index_storage_mode` | Couchbase default | `plasma`, `memory_optimized` or `forestdb` (Community). Applied when the cluster is created. |
| `auto_rebalance` | `true` | Rebalance a node in after it joins, and wait for it. |
| `rebalance_timeout` | `3600` | Seconds to wait for a rebalance. |

**Memory quotas**, in MB per node, for the whole cluster. Unset values are
left as they are.

| Parameter | Service |
|---|---|
| `data_ramsize` | Data. All bucket quotas must fit in it. |
| `index_ramsize` | Index |
| `fts_ramsize` | Search |
| `eventing_ramsize` | Eventing |
| `analytics_ramsize` | Analytics (1024 or more) |

**Resources and connection**

| Parameter | Default | Description |
|---|---|---|
| `buckets`, `users`, `groups`, `acls` | `{}` | Resources to declare, as `title => attributes` hashes. See the types below. |
| `api_url` | `'http://127.0.0.1:8091'` | The node's REST API. |
| `api_timeout` | `180` | Seconds to wait for the REST API, for example after installation. |

### Types

Every type supports `ensure => present | absent` (except `couchbase_cluster`)
and `puppet resource`, for example `puppet resource couchbase_user`.

**`couchbase_bucket`**

| Attribute | Values | Notes |
|---|---|---|
| `ram_quota` | MB, 100 or more | Default 100 at creation. |
| `replicas` | 0–3 | Takes effect after a rebalance. |
| `flush_enabled` | `true`, `false` | |
| `eviction_policy` | `valueOnly`, `fullEviction`; `noEviction`, `nruEviction` (ephemeral) | Fixed at creation for ephemeral buckets. |
| `durability_min_level` | `none`, `majority`, `majorityAndPersistActive`, `persistToMajority` | |
| `compression_mode` | `off`, `passive`, `active` | Enterprise Edition. |
| `max_ttl` | seconds, `0` for none | Enterprise Edition. |
| `bucket_type` | `couchbase`, `ephemeral`, `memcached` | At creation only. |
| `storage_backend` | `couchstore`, `magma` | At creation only. |
| `conflict_resolution` | `seqno`, `lww`, `custom` | At creation only. |
| `replica_index` | `true`, `false` | At creation only. |

**`couchbase_user`**

| Attribute | Values | Notes |
|---|---|---|
| `password` | string or `Sensitive` | Required for local users. |
| `password_management` | `enforce`, `on_create` | `on_create` sets the password only when the user is created. |
| `display_name` | string | |
| `roles` | array of roles | Complete list of the user's own roles. Leave unset to use `couchbase_acl`. |
| `groups` | array of group names | Enterprise Edition. |
| `domain` | `local`, `external` | `external` for LDAP users (no password). |

**`couchbase_group`** (Enterprise Edition)

| Attribute | Values | Notes |
|---|---|---|
| `description` | string | |
| `roles` | array of roles | Complete list. Leave unset to use `couchbase_acl`. |
| `ldap_group_ref` | LDAP DN | Maps an LDAP group to this group. |

**`couchbase_acl`**

The title is a free-form label.

| Attribute | Values | Notes |
|---|---|---|
| `user` | user name | Set either `user` or `group`. |
| `group` | group name | Enterprise Edition. |
| `domain` | `local`, `external` | For `user`: `external` for LDAP users. Default `local`. |
| `role` | role name, e.g. `data_reader`, `ro_admin` | Without brackets; use the parameters below. |
| `bucket` | bucket name or `*` | Omit for cluster-wide roles. |
| `scope` | scope name or `*` | Requires `bucket`. |
| `collection` | collection name or `*` | Requires `scope`. |

**`couchbase_cluster`** is declared by the class; parameters such as
`cluster_nodes`, `services` and the memory quotas map to its attributes.

### Data types

| Type | Values |
|---|---|
| `Couchbase::Service` | `data`, `query`, `search`, `analytics` (UI / couchbase-cli names) or `kv`, `n1ql`, `index`, `fts`, `eventing`, `cbas`, `backup` (REST names) |
| `Couchbase::IndexStorageMode` | `plasma`, `memory_optimized`, `forestdb` |

### Facts

| Fact | Example | Description |
|---|---|---|
| `couchbase_version` | `7.6.3-4200` | Installed Couchbase Server version and build. Not set before Couchbase is installed. |

```puppet
if $facts['couchbase_version'] and versioncmp($facts['couchbase_version'], '7.6') >= 0 {
  # Couchbase 7.6 or later
}
```

## Compatibility

Tested against the official Docker images. Each run creates resources, then
changes and removes them, and requires every run to report exactly the
expected changes, with nothing left to change afterwards.

| Couchbase Server | Community | Enterprise |
|---|---|---|
| 6.6 | 6.6.0: single node, cluster | |
| 7.0 | 7.0.2: single node, cluster | 7.0.5: cluster |
| 7.1 | 7.1.1: single node, cluster | 7.1.6: cluster |
| 7.2 | 7.2.4: single node, cluster | 7.2.6: cluster |
| 7.6 | 7.6.2: single node, cluster | 7.6.3: single node, cluster; 7.6.6: cluster |
| 8.0 | 8.0.2: single node, cluster | |

"Cluster" means the full multi-node scenario: three nodes bootstrapping and
joining concurrently, a fourth added with and without `auto_rebalance`, then
the [Operations](#operations) procedures for removing a node and replacing a
failed one.

Edition and version differences you may run into:

- **Community Edition** only has the `admin`, `ro_admin` and
  `bucket_full_access` roles. Groups, LDAP users, `compression_mode` and
  `max_ttl` need Enterprise Edition.
- **Since 7.6**, `durability_min_level` above `none` needs enough data nodes
  to honour it, so a single node only accepts `none`.
- **Community 7.6.2**'s `couchbase-cli rebalance` and `failover` fail with
  "Unable to get the HTTPS port"; use the
  [REST equivalents](#when-couchbase-cli-rebalance-or-failover-fails).

## Limitations

- Puppet adds nodes to a cluster but never removes or fails them over;
  those are deliberate, data-moving operations (see [Operations](#operations)).
- Scopes and collections can be used in roles, but aren't managed as
  resources.
- A changed bucket `replicas` value needs a rebalance, which Puppet doesn't
  start; it logs a warning instead.
- The admin account can't be renamed by Puppet on a running cluster (see
  [Renaming the admin](#renaming-the-admin-or-changing-its-password)).

## How it works

**Connection.** Each node's Puppet run talks to that node's REST API
(`api_url`) as the admin. `couchbase::config` writes the URL and credentials
to `/etc/couchbase/puppet.json` (root, mode 0600), and the providers read it
at run time, so credentials never appear in individual resources. The
providers wait for the API to come up after installation and retry transient
server errors on reads.

**Creating or joining a cluster.** When the local node isn't part of a
cluster yet, `couchbase_cluster` checks the other `cluster_nodes`:

- If one already belongs to a cluster, it asks that member to add this node
  (`/controller/addNode`), then starts a rebalance and waits for it.
- Otherwise, only the first listed node creates the cluster (`/clusterInit`,
  or the equivalent step-by-step sequence on 6.x); the others stop and retry
  on their next run. This guarantees that two nodes never create two
  separate clusters.

Concurrent joins are coordinated: a node waits for a rebalance already in
progress, and retries when the cluster's node list changed under it. Bucket
changes also wait for a running rebalance, and a bucket created by two nodes
at the same moment is not treated as an error.

**Roles.** Roles are compared in a normalised form. `couchbase_user` and
`couchbase_group` only manage roles assigned directly, not those inherited
from groups. `couchbase_acl` reads the user's or group's current roles, changes
one, and writes the result back.

**Passwords** can't be read from Couchbase, so they are checked by logging
in as the user (`/whoami`).

## Development

```sh
bundle install
bundle exec rake spec            # unit, catalog and provider tests
bundle exec rake lint validate
```

The provider tests run against `spec/support/fake_couchbase.rb`, an
in-memory imitation of the REST API that can also run standalone
(`ruby spec/support/fake_couchbase.rb 18091`) for manual testing, with
`PUPPET_COUCHBASE_CONFIG` pointing to a client config whose `url` uses that
port.

Acceptance tests run against real Couchbase containers and need Docker:

```sh
# Single node: create, change and remove every resource type
ruby spec/acceptance/docker_matrix.rb [--rmi] couchbase/server:community-8.0.2

# Four-node cluster: concurrent bootstrap and joins, scale out, removal,
# and replacement of a failed node
ruby spec/acceptance/docker_cluster.rb [--rmi] couchbase/server:enterprise-7.6.3
```

`--rmi` deletes each image after its test.

### Continuous integration

[GitHub Actions](.github/workflows/ci.yml) runs on every push to `main`, on
pull requests, weekly, and on demand:

- **Unit**: syntax, lint, metadata and the spec suite, on Puppet 7 (Ruby 2.7)
  and Puppet 8 (Ruby 3.2).
- **Single node** and **Cluster**: the two acceptance tests above, one job
  per Couchbase image: Community 6.6.0, 7.0.2, 7.1.1, 7.2.4, 7.6.2 and 8.0.2,
  and Enterprise 7.6.6. They start once the unit tests pass.

To test another image, add it to the `image` lists in the workflow.
