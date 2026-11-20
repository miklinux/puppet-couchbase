# couchbase

Installs Couchbase Server and manages the **cluster**, **buckets**, **users**,
**groups** and **RBAC grants (ACLs)** with native Puppet types and providers
written in Ruby. The providers talk to the local Couchbase REST API at
`http://127.0.0.1:8091`.

## Installation

### Puppetfile (r10k / Code Manager)

Add the module and its dependency, `puppetlabs-stdlib`, to your control
repository's `Puppetfile`. r10k doesn't resolve dependencies, so stdlib
has to be listed too:

```ruby
mod 'puppetlabs-stdlib', '9.7.0'

mod 'couchbase',
  git: 'https://github.com/miklinux/puppet-couchbase.git',
  tag: 'v0.1.2'
```

* The module name (`'couchbase'`) must stay as it is. It becomes the
  directory name in `modules/`, and the class is called `couchbase`.
* Pin a release with `tag:`. Use `branch: 'main'` to follow development,
  or `ref: '<commit sha>'` to pin an exact commit.
* The repository is public, so the Puppet server needs no credentials or
  keys to fetch it.

Then deploy as usual (`r10k deploy environment -pv`, or a Code Manager
deploy). The types and providers in `lib/` are synced to agents
automatically (pluginsync).

### Without r10k

```sh
puppet module install puppetlabs-stdlib --version 9.7.0
git clone --branch v0.1.2 https://github.com/miklinux/puppet-couchbase.git /etc/puppetlabs/code/environments/production/modules/couchbase
```

## How Puppet talks to Couchbase

The providers send REST calls to `api_url` (default
`http://127.0.0.1:8091`) and log in as the full admin. The `couchbase` class
writes the admin credentials to `/etc/couchbase/puppet.json` (root, 0600),
and the providers read that file at run time. This keeps credentials out of
the individual resources. Set `PUPPET_COUCHBASE_CONFIG` to use a different
file, for example in tests.

## Admin account

Couchbase has one built-in full administrator. Puppet creates it when it
sets up the cluster, and uses it for every API call. Its name defaults to
`Administrator`. To use another name, set it before the cluster is set up:

```yaml
couchbase::admin_user: 'admin'
couchbase::admin_password: 'changeme-please'   # better: eyaml
```

On a multi-node cluster, use the same values on every node; the account
belongs to the whole cluster.

### Renaming the admin or changing its password

On a running cluster, always change the credentials **in Couchbase first,
then in Hiera**. Puppet logs in with the credentials from Hiera, so it can't
rename the account it's logged in with. If you change Hiera first, Puppet
is simply locked out (HTTP 401) until Couchbase matches; nothing breaks,
just carry on with step 2.

The admin belongs to the whole cluster: run the command once, on any one
node, and every node uses the new credentials immediately.

**1. Prepare**

* List everything else that logs in as the admin: applications and SDK
  connections, monitoring, backup jobs (`cbbackupmgr`), scripts, and XDCR
  remote cluster references on **other** clusters that replicate to or
  from this one. They stop working at step 2 until you update them. Giving
  them their own users (`couchbase_user`) avoids this next time.
* Optionally pause Puppet on the cluster nodes, so the runs between steps 2
  and 4 don't fail and raise alerts:
  ```sh
  puppet agent --disable 'renaming the Couchbase admin'
  ```

**2. Change the credentials in Couchbase** (on any one node)

```sh
/opt/couchbase/bin/couchbase-cli setting-cluster -c localhost \
  -u Administrator -p '<current-password>' \
  --cluster-username admin --cluster-password '<new-password>'
```

Expect `SUCCESS: Cluster settings modified`. Check it on every node: the
new credentials work and the old ones don't.

```sh
curl -s -o /dev/null -w '%{http_code}\n' -u 'admin:<new-password>' http://localhost:8091/pools/default          # 200
curl -s -o /dev/null -w '%{http_code}\n' -u 'Administrator:<current-password>' http://localhost:8091/pools/default # 401
```

**3. Update Hiera and deploy**

```yaml
couchbase::admin_user: 'admin'
couchbase::admin_password: '<new-password>'   # better: eyaml
```

With a shared (symlinked) Hiera file, this one edit covers every node.
Deploy as usual (`r10k deploy environment -pv`, or Code Manager).

**4. Run Puppet on every node**

```sh
puppet agent --enable    # if you disabled it in step 1
puppet agent -t
```

Each run rewrites `/etc/couchbase/puppet.json` with the new credentials and
should report no other changes. Then update the consumers from step 1.

Until step 4, Puppet runs on the cluster fail with "authentication failed
for 'Administrator'" and change nothing. Data, buckets and other users
aren't affected.

**Changing only the password.** Same procedure, but keep the name in
step 2 (`--cluster-username` with the current name) and change only
`couchbase::admin_password` in step 3. If you've lost the current password,
use this instead in step 2. It runs as root on any node and doesn't need
the old password:

```sh
/opt/couchbase/bin/couchbase-cli reset-admin-password --new-password '<new-password>'
```

**Rolling back.** Run step 2 again with the names swapped (log in with the
new credentials, set the old ones), and revert the Hiera change.

Tested on a 2-node Community 7.6.2 cluster (rename on one node, both nodes
switched; Puppet failed cleanly with the old credentials and ran with no
changes using the new ones; password-only change with both commands) and
on a single Enterprise 7.6.3 node.

## Usage

```puppet
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
}

couchbase_user { 'webapp':
  password => Sensitive('webapp-password'),
  roles    => ['data_reader[sessions]', 'data_writer[sessions]'],
}
```

`services` takes the names used by the web UI and `couchbase-cli`
(`data`, `query`, `index`, `search`, `analytics`, `eventing`, `backup`) or
the REST API names (`kv`, `n1ql`, `index`, `fts`, `cbas`, `eventing`,
`backup`). Friendly names are translated, and both forms can be mixed.

Everything can also come from Hiera:

```yaml
couchbase::admin_password: ENC[...]
couchbase::buckets:
  sessions: { bucket_type: ephemeral, ram_quota: 256 }
couchbase::users:
  webapp: { password: 'webapp-password', roles: ['data_reader[sessions]'] }
couchbase::acls:
  'user:webapp/data_writer[sessions:_default]': {}
```

The class installs the package from a configured repository. To install it
from the Couchbase download site instead, set `package_source`:

```puppet
package_source => 'https://packages.couchbase.com/releases/7.6.3/couchbase-server-enterprise_7.6.3-linux_amd64.deb'
```

See `examples/init.pp` for a fuller example.

## Classes

### `couchbase` (public)

This is the only class you declare, either with `include couchbase` and
Hiera data, or with resource-style `class { 'couchbase': ... }`. It runs
these steps in order, each in its own private class:

```
couchbase::install -> couchbase::service -> couchbase::config -> couchbase::cluster
```

It then declares `couchbase_bucket`, `couchbase_group`, `couchbase_user`
and `couchbase_acl` resources from the `buckets`, `groups`, `users` and
`acls` hashes.

The only required parameter is `admin_password`.

**Admin account**

| Parameter | Default | Description |
|---|---|---|
| `admin_password` | *(required)* | Password of the built-in full admin. String or `Sensitive`, at least 6 characters. |
| `admin_user` | `'Administrator'` | Name of the built-in full admin. Set it before the cluster is first set up (see "Admin account"). |

**Package and service**

| Parameter | Default | Description |
|---|---|---|
| `edition` | `'enterprise'` | `enterprise` or `community`. Selects the default package name. |
| `package_name` | `couchbase-server` / `couchbase-server-community` | Overrides the package name. |
| `package_ensure` | `'installed'` | `installed`, `latest` or a version. |
| `package_source` | `undef` | URL of a `.deb` or `.rpm` to install, instead of a configured repository. |
| `manage_package` | `true` | Set to `false` to install Couchbase some other way. |
| `manage_service` | `true` | Set to `false` without systemd, for example in containers. |
| `service_name` | `'couchbase-server'` | systemd service name. |

**REST API access**

| Parameter | Default | Description |
|---|---|---|
| `api_url` | `'http://127.0.0.1:8091'` | The local REST API used by every `couchbase_*` resource. |
| `api_timeout` | `180` | Seconds to wait for the API to come up, for example after installation. |

**Cluster**

| Parameter | Default | Description |
|---|---|---|
| `manage_cluster` | `true` | Set up or join the cluster and manage its settings. Set to `false` when the cluster is set up some other way; buckets, users and so on are still managed. |
| `cluster_name` | `'couchbase'` | Shown in the UI. Use the same value on every node. |
| `cluster_nodes` | `[]` | All members, the same list on every node. The first one creates the cluster. Leave it empty for a single node. |
| `node_hostname` | `127.0.0.1` for a single node, otherwise the FQDN | This node's address as the others reach it. It must be one of `cluster_nodes`. |
| `services` | `['kv', 'n1ql', 'index']` | Services on this node: `data`/`kv`, `query`/`n1ql`, `index`, `search`/`fts`, `analytics`/`cbas`, `eventing`, `backup`. Only used when the node creates or joins the cluster. |
| `index_storage_mode` | `plasma` (EE) / `forestdb` (CE) | `plasma`, `memory_optimized` or `forestdb`. Only used when the cluster is created. |
| `auto_rebalance` | `true` | Rebalance (and wait) after this node joins. |
| `rebalance_timeout` | `3600` | Seconds to wait for a rebalance. |

**Memory quotas** (MB, for the whole cluster, so keep them the same on
every node; `undef` leaves the current value alone)

| Parameter | Service |
|---|---|
| `data_ramsize` | Data (kv) |
| `index_ramsize` | Index |
| `fts_ramsize` | Search |
| `eventing_ramsize` | Eventing |
| `analytics_ramsize` | Analytics (at least 1024) |

**Resources** (hashes of resource title => attributes; see "Types")

| Parameter | Declares |
|---|---|
| `buckets` | `couchbase_bucket` |
| `users` | `couchbase_user` |
| `groups` | `couchbase_group` |
| `acls` | `couchbase_acl` |

### Private classes

You can't declare these yourself (they fail with `assert_private`). Each
one is switched by a `couchbase` parameter:

| Class | What it does | Skipped with |
|---|---|---|
| `couchbase::install` | Installs the package, from a repository or from `package_source` (downloaded to `/var/cache/couchbase-puppet`). | `manage_package => false` |
| `couchbase::service` | Starts and enables `couchbase-server`. | `manage_service => false` |
| `couchbase::config` | Writes `/etc/couchbase/puppet.json` (root, `0600`): the API URL and admin credentials used by the `couchbase_*` providers. | always declared |
| `couchbase::cluster` | Declares `couchbase_cluster`: creates or joins the cluster, rebalances, sets the name and quotas. | `manage_cluster => false` |

### Common setups

```puppet
# Single node from a configured package repository
class { 'couchbase':
  admin_password => Sensitive('changeme-please'),
}

# Community Edition straight from the download site
class { 'couchbase':
  admin_password => Sensitive('changeme-please'),
  edition        => 'community',
  package_source => 'https://packages.couchbase.com/releases/7.6.2/couchbase-server-community_7.6.2-linux_amd64.deb',
}

# Couchbase installed and set up some other way (for example an image):
# only manage buckets, users and ACLs
class { 'couchbase':
  admin_password => Sensitive('changeme-please'),
  manage_package => false,
  manage_service => false,
  manage_cluster => false,
  buckets        => { 'sessions' => { 'ram_quota' => 256 } },
}
```

The `couchbase_*` types can also be used without the class. In that case,
write `/etc/couchbase/puppet.json` yourself, as `couchbase::config` does:
`{"url": "http://127.0.0.1:8091", "username": "...", "password": "..."}`.

## Multi-node clusters

Give every node the same `cluster_nodes` list, and give each node its own
`node_hostname`: the address the other nodes reach it at, written exactly
as it appears in the list.

```puppet
class { 'couchbase':
  admin_password => Sensitive('changeme-please'),
  cluster_name   => 'production',
  cluster_nodes  => ['10.0.0.11', '10.0.0.12', '10.0.0.13'],
  node_hostname  => $facts['networking']['ip'],
  services       => ['kv', 'n1ql', 'index'],
  data_ramsize   => 4096,
  index_ramsize  => 1024,
}
```

When the local node isn't set up yet, each Puppet run does this:

* If another listed node already belongs to a cluster, this node asks it to
  add this node (`/controller/addNode`, with this node's own `services`).
  It then rebalances and waits for the rebalance to finish
  (`auto_rebalance`, `rebalance_timeout`).
* If no listed node belongs to a cluster yet, only the first node in
  `cluster_nodes` creates one. The other nodes fail with a clear message and
  join on their next run. This guarantees two nodes can never each create a
  separate cluster. A rebuilt bootstrap node joins the existing cluster
  instead of creating a new one.
* If a node is in the cluster but wasn't rebalanced in (for example the
  earlier rebalance failed, or `auto_rebalance` was `false`), the next run
  with `auto_rebalance` reports it as `membership changed` and rebalances.

Nodes can run Puppet at the same time. Concurrent joins and rebalances are
coordinated, and if another node is already rebalancing, a node waits for
that rebalance and then rebalances again if it still needs to.

Buckets, users, groups and ACLs belong to the whole cluster, so you can
declare them on one node or on all of them. Bucket changes wait for any
running rebalance (Couchbase rejects them during one). A "bucket already
exists" error caused by two nodes racing to create it is treated as
success. Keep `cluster_name` and the memory quotas the same on every node,
because they also apply to the whole cluster.

### Sharing one Hiera file between members

All the cluster data can go in a single per-host file, with the other
members' files symlinked to it:

```
data/nodes/cb01.example.com.yaml                            # the real file
data/nodes/cb02.example.com.yaml -> cb01.example.com.yaml
data/nodes/cb03.example.com.yaml -> cb01.example.com.yaml
```

```yaml
# data/nodes/cb01.example.com.yaml - shared by every member
couchbase::admin_user: 'admin'                   # default: Administrator
couchbase::admin_password: 'changeme-please'     # better: eyaml
couchbase::cluster_name: 'production'
couchbase::cluster_nodes: ['cb01.example.com', 'cb02.example.com', 'cb03.example.com']
couchbase::services: ['kv', 'n1ql', 'index']
couchbase::data_ramsize: 4096
couchbase::buckets:
  sessions: { bucket_type: 'ephemeral', ram_quota: 512 }
couchbase::users:
  webapp: { password: 'webapp-password' }
couchbase::acls:
  'user:webapp/bucket_full_access[sessions]': {}
```

List the members by FQDN and leave `couchbase::node_hostname` out of the
shared file: each node then uses its own FQDN (`$facts['networking']['fqdn']`).
The node's address must appear in `cluster_nodes`, otherwise its catalog
fails to compile. That stops a host that isn't (or is no longer) a member
from joining the cluster just because it received the shared data.

To list members by IP address instead, interpolate the address in the
shared file, so every node still gets the same file:
`couchbase::node_hostname: "%{facts.networking.ip}"`.

To keep the admin password Sensitive everywhere, add to `common.yaml`:

```yaml
lookup_options:
  couchbase::admin_password:
    convert_to: Sensitive
```

Passwords nested in `couchbase::users` stay plain strings in Hiera.
Puppet redacts them in logs and reports anyway. Encrypt them with eyaml.

Git, r10k and Code Manager keep symlinks, but a Windows checkout may turn
them into plain text files. A hierarchy level per cluster (for example
`clusters/%{facts.couchbase_cluster}.yaml`, using a custom fact) avoids
symlinks altogether. `spec/classes/couchbase_spec.rb` compiles the catalog
of each member from exactly this symlinked layout
(`spec/fixtures/hiera`).

### Adding and removing nodes

Puppet adds nodes to a cluster on its own. It never removes one, because
that moves data and can't be undone, so removal is a short manual
procedure. `spec/acceptance/docker_cluster.rb` runs these commands
exactly as written on Community 6.6.0 and 8.0.2 and Enterprise 7.6.3:
adding nodes (with and without `auto_rebalance`), removing a healthy node,
and replacing a dead node (hard failover). The swap rebalance and graceful
failover follow standard Couchbase practice but aren't part of the test.

In the examples, `cb` stands for:

```sh
cb() { /opt/couchbase/bin/couchbase-cli "$@" -c localhost -u admin -p 'changeme-please'; }
```

Run it on any node that stays in the cluster.

#### Add a node

1. Append the node to `couchbase::cluster_nodes` in the shared data. Keep
   the current first entry first.
2. Give the new node the data. With symlinked files:
   `ln -s cb01.example.com.yaml cb04.example.com.yaml`.
3. Run Puppet on the new node. It installs Couchbase, joins the cluster
   through a running member with its own `couchbase::services`,
   rebalances and waits for the rebalance. The other nodes see the longer
   list on their next run and change nothing.

You can add several nodes at once by running Puppet on them at the same
time. Their rebalances are coordinated.

To control when the data moves (for example outside business hours), set
`couchbase::auto_rebalance: false` for the new node. It joins as "added but
not rebalanced" and takes no data. Puppet reports it as `membership
inactiveAdded` until a run with `auto_rebalance` back on, or
`cb rebalance`, rebalances it in.

#### Remove a healthy node (scale in)

Take the node out of Puppet's control **before** removing it. A removed
node is wiped back to an unprovisioned state, and if Puppet still found it
in `cluster_nodes`, its next run would join it to the cluster again.

1. Remove the node from `couchbase::cluster_nodes`, delete its data file
   or symlink, and deploy the change. From then on that node's catalog
   fails to compile ("node_hostname ... is not in cluster_nodes"), so Puppet
   can't touch it, and the remaining nodes see nothing to change.
2. Check that the remaining nodes have enough memory quota and disk for
   the data, and enough nodes left for each bucket's `replicas` and
   `durability_min_level`.
3. Rebalance the node out. Its data moves to the others first:
   `cb rebalance --server-remove cb03.example.com:8091`
4. Decommission the machine, or remove the `couchbase` class from it.

#### Replace a failed node

1. If the node is unreachable, fail it over (`--hard`, because it can't
   hand its data over), then rebalance it out:
   `cb failover --server-failover cb03.example.com:8091 --hard`, then
   `cb rebalance`.
   If it's still running but must go, fail it over without `--hard`
   (graceful).
2. Rebuild the machine. Keep its name and keep it in `cluster_nodes`, or
   give it a new name and update the list as in "Add a node".
3. Run Puppet on it. It finds an empty local Couchbase, joins through a
   running member and rebalances.

Finish step 1 before running Puppet on a rebuilt node that keeps its old
address. While the old instance is still a cluster member (even failed
over), the cluster can't add a new node at that address, and the join
fails until the old one has been rebalanced out.

#### Replace the first (bootstrap) node

The first entry of `cluster_nodes` is only special when no cluster exists
yet. Once the cluster is running, every node joins through whichever
listed member is up. So:

* **Rebuild it in place:** the "Replace a failed node" steps work as they
  are. The rebuilt node sees the running cluster and joins it rather than
  creating a new one.
* **Retire it:** remove it like any other node. The next entry becomes the
  first, which only matters if the whole cluster is ever rebuilt from
  scratch.

#### Swap hardware or change a node's services

`couchbase::services` is only used when a node joins the cluster.
Couchbase can't change a running node's services. To move to new machines
or change services, add the new node(s) first, then remove the old one(s)
with the procedures above. With
`cb rebalance --server-remove old:8091` run after the new nodes have
joined with `auto_rebalance: false`, both happen in one rebalance (a "swap
rebalance").

## Types

| Type | Manages | REST endpoint |
|------|---------|---------------|
| `couchbase_cluster` | Creates or joins the cluster, rebalances, cluster name, memory quotas for each service | `/clusterInit`, `/controller/addNode`, `/controller/rebalance`, `/pools/default` |
| `couchbase_bucket` | Buckets: type, RAM quota, replicas, flush, eviction, durability, compression, max TTL, storage backend | `/pools/default/buckets` |
| `couchbase_user` | Local and external users: display name, password, direct roles, group membership | `/settings/rbac/users` |
| `couchbase_group` | RBAC groups (Enterprise Edition): description, LDAP mapping, roles | `/settings/rbac/groups` |
| `couchbase_acl` | One role granted to one user or group | read-modify-write of the above |

All of them support `puppet resource`, e.g. `puppet resource couchbase_acl`.
Resources depend automatically on the cluster, the buckets their roles
reference, the groups they join, the config file and the `couchbase-server` service.

### Roles and ACLs

Roles use the Couchbase syntax: `admin`, `bucket_admin[*]`,
`data_reader[bucket]`, `data_writer[bucket:scope:collection]`. They are
normalised before comparison, so `data_reader[b:*:*]` and `data_reader[b]`
are the same role and Puppet won't report a change between them.

You can manage grants in two ways:

1. **Authoritative list:** `roles => [...]` on `couchbase_user` or
   `couchbase_group`. Puppet revokes any direct role not in the list. Roles
   a user inherits from groups are ignored.
2. **Individual grants:** leave `roles` unset and declare `couchbase_acl`
   resources. Each one adds or removes a single role and leaves the others
   alone, which suits a setup where every profile grants access to its own
   bucket.

   ```puppet
   couchbase_acl { 'user:indexer/data_reader[catalog:inventory]': }
   couchbase_acl { 'group:developers/query_select[*]': ensure => absent }
   ```

   Principals are written `user:<id>`, `external:<id>` or `group:<id>`.

Mixing both styles on the same principal so that they contradict each other
fails the run before any change is applied (`pre_run_check`).

### Passwords

Passwords can't be read back from Couchbase. To check one, Puppet tries to
authenticate as the user (`GET /whoami`) and resets the password if that
fails. Set `password_management => on_create` to set the password only when
the user is created. Passwords are always redacted in logs and reports.

## Facts

| Fact | Example | Description |
|---|---|---|
| `couchbase_version` | `7.6.3-4200` | Version and build of the installed Couchbase Server, read from `/opt/couchbase/VERSION.txt`. Not set when Couchbase isn't installed, which includes the run that installs it. |

```puppet
if $facts['couchbase_version'] and versioncmp($facts['couchbase_version'], '7.6') >= 0 {
  # 7.6+ only: on a single node, durability above 'none' is refused
}
```

## Compatibility

Tested with `spec/acceptance/docker_matrix.rb` against the official Docker
images. Every test creates the resources, changes every mutable property,
deletes some, and checks that each apply reports exactly the expected
changes and that re-applying makes none:

| Version | Community | Enterprise |
|---------|-----------|------------|
| 6.6.0   | pass      | -          |
| 7.0.2   | pass      | -          |
| 7.1.1   | pass      | -          |
| 7.2.4   | pass      | -          |
| 7.6.x   | pass (7.6.2) | pass (7.6.3) |
| 8.0.2   | pass      | -          |

Notes from these runs:

* On 6.x the node is set up step by step, as `couchbase-cli` used to do,
  because `/clusterInit` doesn't exist there yet.
* Community Edition only has the `admin`, `ro_admin` and
  `bucket_full_access[...]` roles (still true in 8.0). Data-level roles
  such as `data_reader` and `query_select` are Enterprise-only, and
  Couchbase rejects them with a clear error.
* `max_ttl`, `compression_mode`, groups and LDAP users are Enterprise-only.
* Since 7.6, `durability_min_level` above `none` needs enough data nodes
  for it, so a single node only accepts `none`.

```sh
ruby spec/acceptance/docker_matrix.rb [--rmi] couchbase/server:community-6.6.0 couchbase/server:enterprise-7.6.3
```

Multi-node clusters are tested with `spec/acceptance/docker_cluster.rb`.
It starts 4 containers on a private Docker network and runs Puppet on all
of them concurrently. The bootstrap node creates the cluster while the
others wait, two nodes join and rebalance at the same time, and a fourth
node is added without a rebalance and rebalanced in on its next run.
Then a healthy node is rebalanced out, and a killed node is hard failed
over, rebalanced out and rebuilt empty at the same address, where Puppet
joins it back. Each
run must report exactly the expected changes, and re-running makes none. It
passes on Community 6.6.0 and 8.0.2 and Enterprise 7.6.3:

```sh
ruby spec/acceptance/docker_cluster.rb [--rmi] couchbase/server:community-6.6.0
```

## Changing parameters

Changing a property in the manifest updates the existing resource in place
on the next run: bucket RAM quota, replicas, flush, eviction policy,
durability and max TTL; user display name, password, roles and groups;
group description, roles and LDAP mapping; cluster name and memory quotas.
Puppet reports each change as `<property> changed X to Y`. Passwords are
reported as `[redacted]`.

Couchbase only accepts some settings when a bucket is created. When one of
them no longer matches the manifest, Puppet logs a **warning** and leaves
the bucket unchanged: `bucket_type`, `storage_backend`,
`conflict_resolution`, `replica_index`, and `eviction_policy` on ephemeral
buckets. Recreate the bucket (`ensure => absent`, then `present`) to change
them, which deletes its data.

## Limitations

* Puppet adds nodes but doesn't remove or fail them over (see "Adding and
  removing nodes"). Changing a bucket's `replicas` needs a rebalance, which
  Puppet doesn't start itself; it logs a warning.
* Scopes and collections can be referenced in roles but are not managed
  as resources.
* Puppet doesn't rename the admin or change its password on a running
  cluster (see "Admin account").
* Groups, `compression_mode` and external users need Enterprise Edition.
* Supports Couchbase Server 6.6 and later on systemd-based Linux.

## Development

```sh
bundle install
bundle exec rake spec      # unit + catalog tests (incl. the symlinked Hiera layout) and providers against a fake REST API
bundle exec rake lint validate
```

`spec/support/fake_couchbase.rb` is a small in-memory copy of the REST API.
It can also run standalone (`ruby spec/support/fake_couchbase.rb 18091`) for
manual `puppet apply` testing, with `PUPPET_COUCHBASE_CONFIG` pointing to a
client config whose `url` is `http://127.0.0.1:18091`.
