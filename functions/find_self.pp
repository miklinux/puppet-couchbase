# @summary Finds which entry of a cluster member list is the local node.
#
# Compares every entry with the node's FQDN, short hostname and all its
# IPv4/IPv6 addresses (case-insensitive), so the same member list can be
# shared by every node, e.g. by symlinking per-host Hiera files.
#
# @param cluster_nodes
#   Member addresses, as written in `couchbase::cluster_nodes`.
# @param node_facts
#   The node's facts (normally `$facts`).
# @return
#   The matching entry. Compilation fails when no entry, or more than one,
#   matches, since guessing would add the node under a wrong address.
function couchbase::find_self(
  Array[String[1]] $cluster_nodes,
  Hash $node_facts,
) >> String[1] {
  $net = $node_facts.dig('networking').lest || { {} }
  $interface_ips = $net.dig('interfaces').lest || { {} }.reduce([]) |$memo, $iface| {
    $addrs = ($iface[1]['bindings'].lest || { [] } + $iface[1]['bindings6'].lest || { [] }).map |$b| { $b['address'] }
    $memo + $addrs
  }
  $identities = ([$net['fqdn'], $net['hostname'], $net['ip'], $net['ip6']] + $interface_ips)
    .filter |$id| { $id =~ String[1] }
    .map |$id| { downcase($id) }
    .unique

  $matches = $cluster_nodes.filter |$entry| { downcase($entry) in $identities }

  case $matches.length {
    1: { $matches[0] }
    0: {
      fail("couchbase: none of cluster_nodes (${cluster_nodes.join(', ')}) is this node (${identities.join(', ')}); set couchbase::node_hostname")
    }
    default: {
      fail("couchbase: several cluster_nodes entries match this node (${matches.join(', ')}); set couchbase::node_hostname")
    }
  }
}
