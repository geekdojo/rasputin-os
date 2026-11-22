#!/bin/sh
#
# node-id.sh — DNS-label helpers, SOURCED (not executed) by
# firstboot/rasputin-firstboot.sh and hostname/rasputin-hostname.sh.
#
# A node id is always the first label of an FQDN: it becomes the node's mDNS
# hostname and the NATS username the agent presents to the bus, and the control
# plane only accepts an RFC 1123 DNS label — 1-63 characters of a-z, 0-9 and
# '-', not starting or ending with '-', lowercase only. This is the same rule
# rasputin-provision's normalizeDNSLabel applies when it assigns an id (and to
# the cluster id, which rasputin-hostname.sh checks with the same helpers).
#
# A node id is always SUPPLIED (seed RASPUTIN_NODE_ID, or rasputin.id= on the
# kernel cmdline) — the node never derives one, because the join token is bound
# to the id it was issued for (geekdojo/geekdojo-brain#423). So it is only
# lowercased and trimmed (rasputin_label_canon, as rasputin-provision does) and
# then CHECKED with rasputin_label_valid. Rewriting it any further would produce
# an id the token does not match — a node that can never join, with no hint why.
#
# Plain POSIX sh (the image's /bin/sh is not bash): no `local`; helper
# variables carry an _rl_ prefix instead. Tested by test/node-id-test.sh.

# rasputin_label_valid VALUE
#   Exit 0 when VALUE is already a valid node id, 1 otherwise. The set is
#   spelled out rather than written as a-z: range expressions in shell patterns
#   can follow the locale's collation order, which is not ASCII everywhere.
rasputin_label_valid() {
	case "$1" in
		"" | -* | *- | *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) return 1 ;;
	esac
	[ "${#1}" -le 63 ]
}

# rasputin_label_canon VALUE
#   Print VALUE with leading/trailing whitespace (including a CR from a seed
#   saved on Windows) removed and ASCII letters lowercased. Nothing else changes:
#   the result still has to pass rasputin_label_valid.
rasputin_label_canon() {
	_rl_ws=$(printf ' \t\n\r\v\f')
	_rl_v=$1
	_rl_v=${_rl_v#"${_rl_v%%[!$_rl_ws]*}"}
	_rl_v=${_rl_v%"${_rl_v##*[!$_rl_ws]}"}
	printf '%s' "$_rl_v" | LC_ALL=C tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz'
}

# rasputin_cluster_id_check VALUE
#   Print nothing and exit 0 when VALUE (already canonical, see
#   rasputin_label_canon) may be used as a NEW cluster's id. Otherwise print the
#   one sentence naming the rule it breaks and exit 1. A cluster signs in at
#   sso-<cluster id>.local, so a cluster id is held to 59 characters (that name
#   must still fit in one DNS label) and may not itself start with sso-, or it
#   would publish another cluster's sign-in name (geekdojo/geekdojo-brain#996).
#   This is for provisioning only: rasputin-hostname.sh keeps
#   rasputin_label_valid, so a node whose id was accepted before this rule keeps
#   its name.
rasputin_cluster_id_check() {
	if [ "${#1}" -gt 59 ]; then
		printf '%s\n' "The cluster id '$1' is ${#1} characters, and a cluster id allows at most 59 so that its sign-in name, sso-<cluster id>.local, fits in one DNS label."
		return 1
	fi
	if ! rasputin_label_valid "$1"; then
		printf '%s\n' "The cluster id '$1' is not a DNS label: it may hold only a-z, 0-9 and -, and must not start or end with -."
		return 1
	fi
	case "$1" in
		sso-*)
			printf '%s\n' "The cluster id '$1' starts with sso-, which is reserved for sign-in names: every cluster signs in at sso-<cluster id>.local, so this one would publish another cluster's sign-in name."
			return 1
			;;
	esac
	return 0
}
