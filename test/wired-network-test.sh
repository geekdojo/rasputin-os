#!/bin/sh
# Static assertions on the shipped wired uplink config,
# board/rasputin/common/rootfs-overlay/etc/systemd/network/20-wired.network.
#
# Why this is tested at all. The DHCP client-id is invisible when it is wrong.
# /etc is a read-only squashfs, so systemd mints a TRANSIENT machine-id into
# /run every boot; networkd's default ClientIdentifier=duid derives the DHCPv4
# client-id from it, so the client-id changes on every reboot and the DHCP
# server — seeing an unknown client — hands the node a NEW address. Measured on
# the bench 2026-09-22: one MAC, two live dnsmasq leases, two client-ids, .232
# before the reboot and .231 after. Nothing in a build, a boot log or a node's
# own status says anything is wrong; the symptom is that addresses wander, the
# lease table fills with dead entries, and whoever was holding a node's address
# is stranded (geekdojo/geekdojo-brain#547). So the setting is pinned here.
#
# This is a config assertion, not a functional test: it reads the file that
# ships in the rootfs overlay. No network, no root, no networkd, runs anywhere.
# The live behaviour it stands for is checked on hardware.
#
# Run:  sh test/wired-network-test.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
NETDIR="$ROOT/board/rasputin/common/rootfs-overlay/etc/systemd/network"
CONF="$NETDIR/20-wired.network"
[ -f "$CONF" ] || { echo "missing: $CONF" >&2; exit 2; }

fails=0
check() {
	if [ "$2" = "0" ]; then printf '  ok   %s\n' "$1"
	else printf '  FAIL %s\n       %s\n' "$1" "${3:-}"; fails=$((fails + 1)); fi
}

# settings FILE — print every directive as "<Section>|<Key>=<Value>", so a key
# can be asserted to be in the section networkd will actually read it from.
# Putting ClientIdentifier= under [Network] parses without complaint and does
# nothing at all, which is exactly the failure this test exists to catch.
settings() {
	awk '
		/^[[:space:]]*(#|;)/ { next }
		/^[[:space:]]*\[/    { s = $0; gsub(/[][[:space:]]/, "", s); next }
		/=/                  { print s "|" $0 }
	' "$1"
}

echo "1. DHCP is keyed on the MAC, not on a machine-id-derived DUID"
got=$(settings "$CONF" | grep '|ClientIdentifier=' || true)
check "ClientIdentifier=mac is set, in the [DHCPv4] section" \
	"$([ "$got" = 'DHCPv4|ClientIdentifier=mac' ] && echo 0 || echo 1)" \
	"want 'DHCPv4|ClientIdentifier=mac', got '${got:-<unset>}'"

echo "2. the rest of the uplink config still stands"
# Guards against a bad section split: DHCP=yes and the IPv4-only settings are
# [Network] keys, and a [DHCPv4] header pasted above them would orphan every
# one of them into a section that ignores them.
for want in \
	'Network|DHCP=yes' \
	'Network|MulticastDNS=yes' \
	'Network|LinkLocalAddressing=ipv4' \
	'Network|IPv6AcceptRA=no' \
	'Match|Name=en* eth*'
do
	check "$want" "$(settings "$CONF" | grep -qxF "$want" && echo 0 || echo 1)" \
		"$(settings "$CONF")"
done

echo "3. no second .network can quietly opt a role out"
# Every role takes its uplink from this one file in the common overlay. If a
# per-role .network is ever added it inherits none of the above, so it has to
# come back through this test rather than silently ship a DUID client-id.
found=$(find "$NETDIR" -name '*.network' | sed "s|^$NETDIR/||" | sort | tr '\n' ' ')
check "20-wired.network is the only one shipped" \
	"$([ "$found" = '20-wired.network ' ] && echo 0 || echo 1)" "found: $found"

echo
if [ "$fails" -ne 0 ]; then echo "FAILED: $fails check(s)"; exit 1; fi
echo "all wired-network tests passed"
