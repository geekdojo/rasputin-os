#!/bin/sh
# Functional test for the controlplane fallback address, against REAL
# systemd-networkd 256.17 -- the version Buildroot 2025.02.17 builds into the
# image -- and the real units from the rootfs overlay.
#
# Why this exists next to fallback-address-test.sh. That suite pins the
# script's decisions with stubs. It cannot show what #427 was about: what
# networkd, the kernel and systemd's path units actually do when a lease turns
# up after the boot-time decision. This test boots systemd in a privileged
# container with no network of its own, gives it one veth link, and puts a
# dnsmasq DHCP server on the far end, in a network namespace, when the scenario
# calls for one.
#
# Scenarios, each in a fresh container:
#   a  no DHCP at all          -> the link ends on 192.168.1.2/24 and nothing else
#   b  DHCP already serving    -> exactly one address, and it is the DHCP lease
#   c  DHCP arrives late (#427) -> .2 first; once the lease exists, exactly one
#                                 address, the DHCP one
#   d  after c, a carrier flap -> .2 does not come back when the lease does
#
# Needs: docker, with privileged containers. Linux runner or Docker Desktop.
# Run:   sh test/fallback-address-functional.sh
#
# Every wait below has a deadline and fails naming the fact that never became
# true. The deadlines bound the test; the units under test use none.
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
IMAGE=rasputin-fallback-functional:f41-networkd-256.17
LINK=en0test
FALLBACK=192.168.1.2/24
DEADLINE="${FALLBACK_TEST_DEADLINE:-90}"

command -v docker >/dev/null 2>&1 || { echo "docker not found - this test needs docker with privileged containers"; exit 1; }

fails=0
check() {
	if [ "$2" = "0" ]; then printf '  ok   %s\n' "$1"
	else printf '  FAIL %s\n       %s\n' "$1" "${3:-}"; fails=$((fails + 1)); fi
}

# Fedora 41 ships systemd-networkd 256.17, the same release as the image, so
# networkd's lease-file and reload behaviour here is the image's, not a guess.
# The build fails loudly if that exact version is no longer installable.
echo "building test image ($IMAGE)"
docker build -q -t "$IMAGE" - >/dev/null <<'DOCKERFILE' || { echo "FAILED: could not build the test image"; exit 1; }
FROM fedora:41
RUN dnf -y install --setopt=install_weak_deps=False \
      systemd-256.17 systemd-networkd-256.17 systemd-udev-256.17 \
      dnsmasq iproute util-linux procps-ng \
 && dnf clean all \
 && systemctl enable systemd-networkd.service \
 && systemctl mask systemd-resolved.service systemd-homed.service systemd-userdbd.service \
      dnf-makecache.timer systemd-networkd-wait-online.service
STOPSIGNAL SIGRTMIN+3
CMD ["/usr/sbin/init"]
DOCKERFILE
# wait-online is masked: this test starts the units by hand once the link is up,
# so network-online.target has nothing to wait for. The ordering it gives at boot
# is not what is under test; the lease race is.

CID=""
cleanup() { [ -n "$CID" ] && docker rm -f "$CID" >/dev/null 2>&1; CID=""; }
trap cleanup EXIT INT TERM

inside() { docker exec "$CID" sh -c "$*"; }

# wait_for "what should become true" 'shell condition run inside the container'
wait_for() {
	i=0
	while [ "$i" -lt "$DEADLINE" ]; do
		inside "$2" >/dev/null 2>&1 && return 0
		sleep 1
		i=$((i + 1))
	done
	echo "  DEADLINE: after ${DEADLINE}s, still not true: $1"
	return 1
}

addrs() { inside "ip -4 -o addr show dev $LINK scope global | awk '{print \$4}' | sort | tr '\n' ' '"; }

boot() {
	cleanup
	CID=$(docker run -d --privileged --cgroupns=private --network none \
		--tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
		-v "$OVERLAY:/overlay:ro" "$IMAGE") || { echo "FAILED: could not start container"; exit 1; }
	wait_for "systemd is running in the container" \
		's=$(systemctl is-system-running 2>/dev/null); [ "$s" = running ] || [ "$s" = degraded ]' || return 1
	# Install exactly what the image installs for this feature.
	inside '
		set -e
		install -D -m 0755 /overlay/usr/lib/rasputin/netfallback/rasputin-fallback-address.sh /usr/lib/rasputin/netfallback/rasputin-fallback-address.sh
		for u in rasputin-fallback-address.service rasputin-fallback-address-release.path rasputin-fallback-address-release.service; do
			install -m 0644 /overlay/etc/systemd/system/$u /etc/systemd/system/$u
		done
		install -D -m 0644 /overlay/etc/systemd/network/20-wired.network /etc/systemd/network/20-wired.network
		mkdir -p /var/lib/rasputin && touch /var/lib/rasputin/role.controlplane
		systemctl daemon-reload
		networkctl reload
		# One wired link; its peer lives in the "lan" namespace where a DHCP
		# server can be started and stopped.
		ip netns add lan
		ip link add '"$LINK"' type veth peer name lan0
		ip link set lan0 netns lan
		ip -n lan link set lo up
		ip -n lan addr add 192.168.1.1/24 dev lan0
		ip -n lan link set lan0 up
	' || { echo "FAILED: container setup"; return 1; }
	wait_for "networkd manages $LINK and it has carrier" \
		"[ \"\$(cat /sys/class/net/$LINK/carrier 2>/dev/null)\" = 1 ] && networkctl status $LINK 2>/dev/null | grep -Eq 'State: .*(degraded|routable|carrier).*\\((configured|configuring)\\)'"
}

dhcp_start() {
	inside 'ip netns exec lan dnsmasq --port=0 --interface=lan0 --bind-interfaces \
		--dhcp-range=192.168.1.100,192.168.1.249,255.255.255.0,12h \
		--dhcp-leasefile=/tmp/dnsmasq.leases --pid-file=/run/dnsmasq-lan.pid'
}

# The boot sequence, in the image's order: the path unit is enabled from
# multi-user.target, the apply unit runs once the link is online.
start_units() {
	inside 'systemctl start rasputin-fallback-address-release.path && systemctl start rasputin-fallback-address.service'
}

lease_file() { echo "[ -n \"\$(ls /run/systemd/netif/leases/ 2>/dev/null)\" ]"; }
in_pool() { case "$1" in 192.168.1.1[0-9][0-9]/24\ |192.168.1.2[0-4][0-9]/24\ ) return 0 ;; esac; return 1; }

# --- a. no DHCP --------------------------------------------------------------
echo "a. no DHCP server: the controlplane takes $FALLBACK"
if boot; then
	start_units
	wait_for "$FALLBACK on $LINK" "ip -4 -o addr show dev $LINK | grep -qF ' $FALLBACK '"
	a=$(addrs)
	check "exactly one global address, and it is $FALLBACK" "$([ "$a" = "$FALLBACK " ] && echo 0 || echo 1)" "got: $a"
	check "no lease file exists" "$(inside "$(lease_file)" && echo 1 || echo 0)"
	check "the release path unit is waiting" "$([ "$(inside 'systemctl is-active rasputin-fallback-address-release.path')" = active ] && echo 0 || echo 1)"
	check "the release service has not run" \
		"$([ "$(inside 'systemctl show -P ActiveState rasputin-fallback-address-release.service')" = inactive ] && echo 0 || echo 1)"
else
	check "scenario a set up" 1
fi

# --- b. DHCP already serving ---------------------------------------------------
echo "b. DHCP already serving: one address, the lease"
if boot; then
	dhcp_start
	start_units
	wait_for "a DHCP lease on $LINK and no fallback" \
		"$(lease_file) && ! ip -4 -o addr show dev $LINK | grep -qF ' $FALLBACK ' && ip -4 -o addr show dev $LINK scope global | grep -q ' 192\\.168\\.1\\.'"
	a=$(addrs)
	check "exactly one global address, from the DHCP pool" "$(in_pool "$a" && echo 0 || echo 1)" "got: $a"
	check "no fallback drop-in" "$(inside 'test -e /run/systemd/network/20-wired.network.d/50-rasputin-fallback.conf' && echo 1 || echo 0)"
else
	check "scenario b set up" 1
fi

# --- c. the #427 race: DHCP arrives after the decision ---------------------------
echo "c. the #427 race: the lease arrives after the fallback was applied"
if boot; then
	start_units
	if wait_for "$FALLBACK applied before any DHCP server exists" "ip -4 -o addr show dev $LINK | grep -qF ' $FALLBACK '"; then
		dhcp_start
		wait_for "the lease replaces the fallback" \
			"$(lease_file) && ! ip -4 -o addr show dev $LINK | grep -qF ' $FALLBACK ' && ip -4 -o addr show dev $LINK scope global | grep -q ' 192\\.168\\.1\\.'"
		a=$(addrs)
		check "exactly one global address, from the DHCP pool" "$(in_pool "$a" && echo 0 || echo 1)" "got: $a"
		check "the drop-in is gone" "$(inside 'test -e /run/systemd/network/20-wired.network.d/50-rasputin-fallback.conf' && echo 1 || echo 0)"
		check "the release service ran and stays active" \
			"$([ "$(inside 'systemctl show -P ActiveState rasputin-fallback-address-release.service')" = active ] && echo 0 || echo 1)" \
			"$(inside 'journalctl -b -u rasputin-fallback-address-release.service --no-pager | tail -20')"

		# --- d. carrier flap: networkd re-configures the link from its loaded
		# config. If the release had skipped the reload, .2 would come back here.
		echo "d. a carrier flap after the release does not bring $FALLBACK back"
		inside "ip -n lan link set lan0 down"
		wait_for "networkd drops the lease on carrier loss" "! $(lease_file)"
		inside "ip -n lan link set lan0 up"
		wait_for "a new lease after carrier returns" \
			"$(lease_file) && ip -4 -o addr show dev $LINK scope global | grep -q ' 192\\.168\\.1\\.'"
		a=$(addrs)
		check "still exactly one global address, from the DHCP pool" "$(in_pool "$a" && echo 0 || echo 1)" "got: $a"
	else
		check "scenario c: fallback applied" 1
	fi
else
	check "scenario c set up" 1
fi

cleanup
echo
if [ "$fails" -ne 0 ]; then echo "FAILED: $fails check(s)"; exit 1; fi
echo "all fallback-address functional tests passed"
