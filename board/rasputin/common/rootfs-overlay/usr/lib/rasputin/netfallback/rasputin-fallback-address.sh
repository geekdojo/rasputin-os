#!/bin/sh
# Give a controlplane a REACHABLE address when the LAN has no DHCP server yet,
# and take it away again the moment DHCP is serving the box.
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
# So: while no DHCPv4 lease exists, take 192.168.1.2/24. Once one exists, drop
# it. The controlplane must never hold both.
#
# Why that address is not a guess. The firewall deliberately leaves OpenWrt's
# stock LAN alone (rasputin-openwrt-firewall, uci-defaults/99-rasputin: "don't
# mutate network.lan" -- an earlier version did and dev.2 boxes lost LAN DHCP),
# so the LAN it will eventually serve is 192.168.1.0/24 with the firewall on
# .1 and its dnsmasq pool on .100-.249 (bench-verified 2026-07-05). .2 is one
# above the gateway and far below the pool, so no lease can collide with it.
#
# Why a second address is NOT harmless (geekdojo-brain#427). An earlier version
# of this script decided once, after network-online.target, and left .2 in
# place if a lease turned up later. wait-online runs with --any, and the
# 169.254.x link-local address satisfies it, so the decision routinely ran
# 0.4-2 s before the lease arrived. The controlplane then held two LAN
# addresses with .2 primary. mDNS and the bus answer on both, but the cluster
# nameserver answers only on the DHCP address, so compute nodes that dialled .2
# lost cluster DNS and fell off the mesh.
#
# THE FACT everything keys on: networkd writes /run/systemd/netif/leases/<ifindex>
# while it holds a DHCPv4 lease on a link, and unlinks it when the lease goes
# (systemd 256.17, the version Buildroot 2025.02.17 ships: link_save() in
# src/network/networkd-state-file.c). The write is atomic -- a dot-prefixed temp
# file renamed into place -- so "a non-dot file exists in that directory" is
# exactly "networkd holds a lease". In this image only the wired links can hold
# one: 20-wired.network is the only DHCP client config that matches hardware
# (systemd's own 80-container-host0*.network match only inside a container, and
# there is no Wi-Fi supplicant).
#
# Two transitions, both driven by that fact and neither by a timer:
#
#   apply   (rasputin-fallback-address.service, once per boot, after
#           network-online.target): no lease -> write the drop-in. A lease
#           already held -> refuse.
#   release (rasputin-fallback-address-release.path/.service): the path unit
#           fires the moment a lease file exists (PathExistsGlob, re-checked
#           whenever the service stops), and the service removes the fallback.
#
# Mode "lease-held" is the release service's ExecCondition: it exits 0 when a
# lease exists and 1 when not, so a lease that vanished before the service ran
# skips the unit instead of latching it.
#
# A lease that is lost later does NOT bring .2 back; see the release unit for why.
#
# Why a drop-in under /run rather than `ip addr add`. networkd owns every
# address on a link it manages. An address added behind its back is "foreign"
# and is flushed the next time networkd configures the link (a reconfigure, a
# reload that changed the link's config, or a networkd restart). Writing a
# drop-in and reloading keeps networkd the owner. /run is tmpfs, so a reboot
# starts from a clean slate and the decision is made again.
#
# NOT a networkd-native feature: systemd 256 has no conditional-static address.
# `Address=` is unconditional (it would exist on every cluster, DHCP or not,
# and land in the api leaf's IP SANs -- the objection that kept geekdojo-brain
# #232 from being implemented the wrong way). `LinkLocalAddressing=` is the only
# fallback-shaped setting and it only speaks 169.254. Hence these units.
set -u

MODE="${1:-apply}"

# Injectable for tests; the defaults are the real runtime paths.
LEASE_DIR="${RASPUTIN_FALLBACK_LEASE_DIR:-/run/systemd/netif/leases}"
DROPIN_DIR="${RASPUTIN_FALLBACK_DROPIN_DIR:-/run/systemd/network/20-wired.network.d}"
STATE_DIR="${RASPUTIN_FALLBACK_STATE_DIR:-/run/rasputin/fallback-address}"
SYSCLASS="${RASPUTIN_FALLBACK_SYSCLASS:-/sys/class/net}"
NODE_ENV="${RASPUTIN_FALLBACK_NODE_ENV:-/var/lib/rasputin/node.env}"
DRY_RUN="${RASPUTIN_FALLBACK_DRY_RUN:-0}"
# Indirected so the test suite can substitute recording stubs and exercise the
# real write-and-reload path without a networkd to talk to.
NETWORKCTL="${RASPUTIN_FALLBACK_NETWORKCTL:-networkctl}"
IP="${RASPUTIN_FALLBACK_IP:-ip}"
SYSTEMCTL="${RASPUTIN_FALLBACK_SYSTEMCTL:-systemctl}"
FLOCK="${RASPUTIN_FALLBACK_FLOCK:-flock}"

DROPIN="$DROPIN_DIR/50-rasputin-fallback.conf"
RELEASE_UNIT=rasputin-fallback-address-release.service

log() { printf 'rasputin-fallback-address: %s\n' "$*" >&2; }

# The fact. Same test as the release path unit's PathExistsGlob: the shell's *
# skips dot files just as glob(3) does, so networkd's temp files never count.
lease_held() {
	for f in "$LEASE_DIR"/*; do
		[ -e "$f" ] && return 0
	done
	return 1
}

# apply and release must not interleave: a release that deletes the drop-in
# while an apply is halfway through writing it would leave networkd's view and
# the kernel's out of step. systemd already orders the release unit after the
# apply unit, which covers boot; the lock also covers a manual restart of either.
# The lock waits on the other holder finishing, not on a clock. busybox ships
# flock in this image; if it is somehow missing, say so rather than refuse to
# run, since refusing would strand a no-DHCP box with no address.
take_lock() {
	mkdir -p "$STATE_DIR" || { log "could not create $STATE_DIR"; return 1; }
	if command -v "$FLOCK" >/dev/null 2>&1; then
		exec 9>"$STATE_DIR/lock"
		"$FLOCK" 9 || log "could not take $STATE_DIR/lock - continuing unserialised"
	else
		log "$FLOCK not found - continuing unserialised"
	fi
}

# Every wired link, carrier or not: 20-wired.network (and so the drop-in)
# matches all of them.
wired_links() {
	for d in "$SYSCLASS"/en* "$SYSCLASS"/eth*; do
		[ -e "$d" ] && basename "$d"
	done
}

# ---------------------------------------------------------------------------
# lease-held: ExecCondition for the release unit.
if [ "$MODE" = "lease-held" ]; then
	lease_held && exit 0
	exit 1
fi

# ---------------------------------------------------------------------------
# release: a lease exists, so the fallback goes.
#
# Removal order, and why there is no `networkctl reconfigure`:
#   1. mark a reload as pending. If this run dies before step 4, the next run
#      still reloads, even though the drop-in is already gone.
#   2. delete the drop-in, so networkd's config no longer asks for the address.
#   3. `ip addr del` the address from every wired link that holds it. It is gone
#      at once, whatever happens next. networkd forgets an IPv4 address the
#      kernel reports removed and does not put it back (address_drop(),
#      networkd-address.c).
#   4. `networkctl reload`. Without this, networkd keeps the old config in
#      memory and re-adds the address the next time it configures the link,
#      e.g. after a cable is pulled and replugged.
#
# The reload is not free, and it cannot be made free on systemd 256. A reload
# that finds a changed drop-in reconfigures the link: network_reload() spots the
# change, manager_reload() calls link_reconfigure(), and link_reconfigure_impl()
# stops the DHCP client. So the DHCP address drops and is re-acquired, exactly
# as `networkctl reconfigure` would do. Skipping the reload is the only way to
# avoid that, and the price would be the stale in-memory Address= above, which
# would put .2 back after the next carrier flap. A second address is the bug
# this fixes, so we pay for one DHCP renewal instead, once per affected boot.
if [ "$MODE" = "release" ]; then
	take_lock

	addr=""
	[ -f "$DROPIN" ] && addr=$(sed -n 's/^Address=//p' "$DROPIN" | head -n 1)

	if [ ! -f "$DROPIN" ] && [ ! -e "$STATE_DIR/reload-pending" ]; then
		log "DHCPv4 lease held and no fallback address applied - nothing to do"
		exit 0
	fi

	if [ "$DRY_RUN" = "1" ]; then
		printf 'WOULD_RELEASE address=%s dropin=%s\n' "${addr:-none}" "$DROPIN"
		exit 0
	fi

	: > "$STATE_DIR/reload-pending" || { log "could not write $STATE_DIR/reload-pending"; exit 1; }
	rm -f "$DROPIN" || { log "could not remove $DROPIN"; exit 1; }

	rc=0
	if [ -n "$addr" ]; then
		for n in $(wired_links); do
			"$IP" -4 -o addr show dev "$n" 2>/dev/null | grep -qF " inet $addr " || continue
			if "$IP" addr del "$addr" dev "$n"; then
				log "removed $addr from $n"
			else
				log "could not remove $addr from $n"
				rc=1
			fi
		done
	fi

	"$NETWORKCTL" reload || { log "networkctl reload failed - networkd may still hold ${addr:-the fallback address}"; exit 1; }
	rm -f "$STATE_DIR/reload-pending"

	log "DHCPv4 lease held - fallback ${addr:-address} released, DHCP has sole ownership"
	printf '\n**** Rasputin OS  |  DHCP lease acquired - fallback address %s released ****\n\n' \
		"${addr%%/*}" > /dev/console 2>/dev/null || true
	exit "$rc"
fi

if [ "$MODE" != "apply" ]; then
	log "unknown mode '$MODE' (expected apply, release or lease-held)"
	exit 2
fi

# ---------------------------------------------------------------------------
# apply: the boot-time decision.

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

[ "$DRY_RUN" = "1" ] || take_lock

# A lease already held: DHCP is serving this box, so stay out of the way. This
# is checked under the lock, so a release cannot slip in between the check and
# the write. A lease that arrives AFTER this check is the release unit's job.
if lease_held; then
	log "$LINK has a DHCPv4 lease - leaving addressing to DHCP"
	exit 0
fi

log "$LINK has no DHCPv4 lease - taking $FALLBACK_ADDRESS so the control plane is reachable"

if [ "$DRY_RUN" = "1" ]; then
	printf 'WOULD_APPLY link=%s address=%s dropin=%s\n' "$LINK" "$FALLBACK_ADDRESS" "$DROPIN"
	exit 0
fi

mkdir -p "$DROPIN_DIR" || { log "could not create $DROPIN_DIR"; exit 1; }
# Address only -- deliberately NO Gateway=. The firewall that would be .1 does
# not exist yet (that is the whole premise), and a default route to a dead next
# hop is worse than no default route: it black-holes traffic that link-local
# and, later, the real lease would have carried.
cat > "$DROPIN" <<EOF
# Written by rasputin-fallback-address.service because this controlplane had no
# DHCPv4 lease. rasputin-fallback-address-release.service deletes it as soon as
# a lease exists; it lives on tmpfs, so a reboot starts clean either way.
[Network]
Address=$FALLBACK_ADDRESS
EOF

"$NETWORKCTL" reload || { log "networkctl reload failed"; exit 1; }
"$NETWORKCTL" reconfigure "$LINK" || { log "networkctl reconfigure $LINK failed"; exit 1; }

# Re-arm the release. Its path unit re-checks for a lease whenever the release
# service stops, so stopping it guarantees that a lease which exists now, or
# arrives later, removes what we just added. At boot the release cannot have
# run yet, because it is ordered after this unit; at most a start job is
# waiting, and stopping it only makes the path unit look again. It matters when
# this unit is restarted by hand on a box whose release has already run.
"$SYSTEMCTL" --no-block stop "$RELEASE_UNIT" 2>/dev/null \
	|| log "could not re-arm $RELEASE_UNIT - a later DHCPv4 lease may not release $FALLBACK_ADDRESS"

log "applied - reach the control plane at ${FALLBACK_ADDRESS%%/*} (or by name over mDNS)"
printf '\n**** Rasputin OS  |  no DHCP on this network - control plane at %s ****\n\n' \
	"${FALLBACK_ADDRESS%%/*}" > /dev/console 2>/dev/null || true
exit 0
