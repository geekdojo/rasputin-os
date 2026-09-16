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
