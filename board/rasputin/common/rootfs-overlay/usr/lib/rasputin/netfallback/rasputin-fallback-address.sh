#!/bin/sh
# Give a controlplane a REACHABLE address when the LAN has no DHCP server yet.
#
# The chicken-and-egg this solves: on a brand-new network the Rasputin firewall
# is what serves DHCP, but you configure the firewall from the control plane,
# and you cannot reach the control plane without an address. Nothing on the
# segment hands out addresses, so the controlplane falls back to IPv4
# link-local (169.254.x, per LinkLocalAddressing=ipv4 in 20-wired.network) --
# which only helps if the operator's laptop ALSO fell back to link-local. A
# laptop holding a lease from some other network, or statically addressed, has
# no route to 169.254.x and the box is simply unreachable.
#
# So: when the wired link comes up with NO DHCPv4 lease, take 192.168.1.2/24.
#
# Why that address is not a guess. The firewall deliberately leaves OpenWrt's
# stock LAN alone (rasputin-openwrt-firewall, uci-defaults/99-rasputin: "don't
# mutate network.lan" -- an earlier version did and dev.2 boxes lost LAN DHCP),
# so the LAN it will eventually serve is 192.168.1.0/24 with the firewall on
# .1 and its dnsmasq pool on .100-.249 (bench-verified 2026-07-05). .2 is one
# above the gateway and far below the pool: once the firewall does arrive,
# there is no lease it can ever hand out that collides with this address.
#
# Why a drop-in under /run rather than `ip addr add`. Two reasons. (1) networkd
# owns every address on a link it manages; an address added behind its back can
# be flushed on the next reconfigure. Writing a drop-in and reloading keeps
# networkd the owner. (2) /run is tmpfs, so the drop-in evaporates on reboot --
# which is exactly the handover we want: boot with a DHCP server present (the
# firewall now exists) and this unit no-ops, leaving DHCP in sole possession.
# No teardown path to get wrong.
#
# Known limit, deliberate: if DHCP appears WITHOUT a reboot, .2 stays alongside
# the new lease until the next boot. Harmless -- .2 is outside the pool, so
# nothing else can hold it -- but it is why this is a boot-time decision and
# not a live watcher. There is no networkd hook for "a lease arrived" the way
# sd-ipv4ll gets sd_ipv4ll_stop for free.
#
# NOT a networkd-native feature: systemd 256 has no conditional-static address.
# `Address=` is unconditional (it would exist on every cluster, DHCP or not,
# and land in the api leaf's IP SANs -- the objection that kept geekdojo-brain
# #232 from being implemented the wrong way). `LinkLocalAddressing=` is the only
# fallback-shaped setting and it only speaks 169.254. Hence this unit.
set -u

# Injectable for tests; the defaults are the real runtime paths.
LEASE_DIR="${RASPUTIN_FALLBACK_LEASE_DIR:-/run/systemd/netif/leases}"
DROPIN_DIR="${RASPUTIN_FALLBACK_DROPIN_DIR:-/run/systemd/network/20-wired.network.d}"
SYSCLASS="${RASPUTIN_FALLBACK_SYSCLASS:-/sys/class/net}"
NODE_ENV="${RASPUTIN_FALLBACK_NODE_ENV:-/var/lib/rasputin/node.env}"
DRY_RUN="${RASPUTIN_FALLBACK_DRY_RUN:-0}"
# Indirected so the test suite can substitute a recording stub and exercise the
# real write-and-reload path without a networkd to talk to.
NETWORKCTL="${RASPUTIN_FALLBACK_NETWORKCTL:-networkctl}"

log() { printf 'rasputin-fallback-address: %s\n' "$*" >&2; }

# The operator can override the address in the seed (it reaches us via
# node.env), for a bench or a site that already uses 192.168.1.0/24 for
# something else. Unset -> the documented default.
if [ -r "$NODE_ENV" ]; then
	# shellcheck disable=SC1090
	. "$NODE_ENV" 2>/dev/null || true
fi
# SET BUT EMPTY is an explicit opt-out; UNSET takes the documented default.
# Testing the value alone (-n) cannot tell those apart and silently turns an
# operator's deliberate "" into 192.168.1.2 -- caught by the test suite.
if [ -n "${RASPUTIN_FALLBACK_ADDRESS+set}" ]; then
	FALLBACK_ADDRESS="$RASPUTIN_FALLBACK_ADDRESS"
else
	FALLBACK_ADDRESS=192.168.1.2/24
fi

# An empty override is an explicit opt-out, not a fall-through to the default.
if [ -z "$FALLBACK_ADDRESS" ]; then
	log "RASPUTIN_FALLBACK_ADDRESS is empty - fallback disabled by configuration"
	exit 0
fi

case "$FALLBACK_ADDRESS" in
	*[!0-9.]*/*|*/*[!0-9]*) log "ignoring malformed RASPUTIN_FALLBACK_ADDRESS '$FALLBACK_ADDRESS'"; exit 0 ;;
	*/*) ;;
	*) log "RASPUTIN_FALLBACK_ADDRESS '$FALLBACK_ADDRESS' needs a prefix length (e.g. 192.168.1.2/24)"; exit 0 ;;
esac

# The wired uplink, by the same match 20-wired.network uses. Container and
# bridge interfaces (docker0, br-*, veth*) are excluded there and here.
find_link() {
	[ -n "${RASPUTIN_FALLBACK_LINK:-}" ] && { printf '%s' "$RASPUTIN_FALLBACK_LINK"; return; }
	for d in "$SYSCLASS"/en* "$SYSCLASS"/eth*; do
		[ -e "$d" ] || continue
		n=$(basename "$d")
		# Carrier only: an unplugged NIC is not the uplink. 1 = link up.
		[ "$(cat "$d/carrier" 2>/dev/null || echo 0)" = "1" ] || continue
		printf '%s' "$n"
		return
	done
}

LINK="$(find_link)"
if [ -z "$LINK" ]; then
	log "no wired link with carrier - nothing to do"
	exit 0
fi

# The fact we key on: networkd writes a lease file per ifindex the moment it
# has a DHCPv4 lease. Present = DHCP is serving this box, so stay out of the
# way. This is a checkable fact, not a timer -- the unit is ordered after
# network-online.target, so by the time we look networkd has either got a
# lease or exhausted its own bounded attempt.
IFINDEX="$(cat "$SYSCLASS/$LINK/ifindex" 2>/dev/null || true)"
if [ -n "$IFINDEX" ] && [ -e "$LEASE_DIR/$IFINDEX" ]; then
	log "$LINK has a DHCPv4 lease - leaving addressing to DHCP"
	exit 0
fi

log "$LINK has no DHCPv4 lease - taking $FALLBACK_ADDRESS so the control plane is reachable"

if [ "$DRY_RUN" = "1" ]; then
	printf 'WOULD_APPLY link=%s address=%s dropin=%s\n' "$LINK" "$FALLBACK_ADDRESS" "$DROPIN_DIR/50-rasputin-fallback.conf"
	exit 0
fi

mkdir -p "$DROPIN_DIR" || { log "could not create $DROPIN_DIR"; exit 1; }
# Address only -- deliberately NO Gateway=. The firewall that would be .1 does
# not exist yet (that is the whole premise), and a default route to a dead next
# hop is worse than no default route: it black-holes traffic that link-local
# and, later, the real lease would have carried.
cat > "$DROPIN_DIR/50-rasputin-fallback.conf" <<EOF
# Written at boot by rasputin-fallback-address.service because this
# controlplane came up with no DHCPv4 lease. Lives on tmpfs: a reboot with a
# DHCP server present removes it and DHCP resumes sole ownership.
[Network]
Address=$FALLBACK_ADDRESS
EOF

"$NETWORKCTL" reload || { log "networkctl reload failed"; exit 1; }
"$NETWORKCTL" reconfigure "$LINK" || { log "networkctl reconfigure $LINK failed"; exit 1; }

log "applied - reach the control plane at ${FALLBACK_ADDRESS%%/*} (or by name over mDNS)"
printf '\n**** Rasputin OS  |  no DHCP on this network - control plane at %s ****\n\n' \
	"${FALLBACK_ADDRESS%%/*}" > /dev/console 2>/dev/null || true
exit 0
