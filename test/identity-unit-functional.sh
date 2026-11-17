#!/bin/sh
# Functional test for the identity service's units, keycloak.service and
# keycloak-db.service (geekdojo/geekdojo-brain#973), against REAL systemd 258.7
# as PID 1, the release Buildroot 2026.08 builds into the image.
#
# PRE-BUILD PROOF (TC-973-20). This first cut carries only the sandbox probe:
# a connect from inside a unit's cgroup under IPAddressDeny=any and
# IPAddressAllow=localhost gets EPERM to the container's own non-loopback
# address and reaches a 127.0.0.1 listener, and the same connect from outside
# that cgroup reaches the non-loopback listener. The outside connect is the
# control: it proves the container enforces systemd's BPF firewall, so an
# EPERM inside is the firewall and not the network.
#
# Needs: docker with privileged containers. Linux runner or Docker Desktop.
# Run:   sh test/identity-unit-functional.sh
#
# Every wait has a deadline and fails naming the fact that never became true.
# The deadlines bound the test; the units under test choose none.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BASE=rasputin-identity-unit-functional:f43-systemd-258.7
IMAGE=rasputin-identity-unit-functional:harness
CTR_DEADLINE="${IDENTITY_UNIT_TEST_DEADLINE:-120}"
PROBE_PORT=9973

command -v docker >/dev/null 2>&1 || { echo "FAILED: this test needs docker, and docker is not on PATH."; exit 1; }

. "$ROOT/test/lib/checks.sh"
. "$ROOT/test/lib/f43-systemd.sh"
. "$ROOT/test/lib/container-systemd.sh"

cleanup() { ctr_cleanup; }
trap cleanup EXIT INT TERM

f43_systemd_image "$BASE" || exit 1
# TEST HARNESS: ncat for the listeners the probe connects to.
docker build -q -t "$IMAGE" - >/dev/null <<DOCKERFILE || { echo "FAILED: the harness image could not be built."; exit 1; }
FROM $BASE
RUN dnf -y install --setopt=install_weak_deps=False nmap-ncat iproute && dnf clean all
DOCKERFILE

ctr_boot "the identity units" "$IMAGE" || exit 1
echo "in the container: $(inside 'systemctl --version | head -1')"

# The container's own non-loopback IPv4 address.
ADDR=$(inside "ip -4 -o addr show scope global | awk '{ sub(/\\/.*/, \"\", \$4); print \$4; exit }'")
[ -n "$ADDR" ] || { echo "FAILED: the container has no non-loopback IPv4 address to probe."; exit 1; }
echo "non-loopback address: $ADDR"

# TEST HARNESS: one UDP listener on the non-loopback address and one on
# loopback, each writing what it receives to its own file. Each gets one
# datagram, so neither needs -k.
inside "systemd-run --quiet --unit=probe-listen-lan -p StandardOutput=append:/run/probe-lan ncat -u -l $ADDR $PROBE_PORT &&
	systemd-run --quiet --unit=probe-listen-lo -p StandardOutput=append:/run/probe-lo ncat -u -l 127.0.0.1 $PROBE_PORT" \
	|| { echo "FAILED: the probe's listeners could not be started."; exit 1; }
wait_for "both probe listeners are bound" \
	"ss -Hlun | grep -q '$ADDR:$PROBE_PORT' && ss -Hlun | grep -q '127.0.0.1:$PROBE_PORT'" || exit 1

# probe CGROUP HOST TOKEN — sends TOKEN in one UDP datagram to HOST:PROBE_PORT
# from a shell that first moves itself into CGROUP (a path under
# /sys/fs/cgroup, or "" for its own), and prints "sent" or bash's error. UDP,
# because the firewall's verdict reaches the sender at once: the send of a
# datagram the egress program drops fails with EPERM, while a dropped TCP SYN
# is retransmitted and only times out (tcp_connect ignores the transmit
# error), which says nothing until a chosen wait runs out.
probe() {
	inside "sh -c '[ -z \"$1\" ] || echo \$\$ > \"/sys/fs/cgroup$1/cgroup.procs\" || exit 9
		exec bash -c \"exec 3<>/dev/udp/$2/$PROBE_PORT && echo $3 >&3 && echo sent\"' 2>&1"
}
# received FILE TOKEN — the listener writing FILE has TOKEN.
received() { wait_for "the listener's $1 holds $2" "grep -qx '$2' $1"; }

echo
echo "20. IPAddressDeny holds, with a control (TC-973-20, pre-build proof)"
# A transient unit carrying the identity units' three network lines, whose
# cgroup the probe joins.
inside "systemd-run --quiet --unit=probe-sandbox -p IPAddressDeny=any -p IPAddressAllow=localhost \
	-p 'RestrictAddressFamilies=AF_INET AF_UNIX' sleep infinity" \
	|| { echo "FAILED: the sandbox stand-in unit could not be started."; exit 1; }
CG=$(inside "systemctl show -P ControlGroup probe-sandbox.service")
echo "the stand-in's cgroup: $CG"
out=$(probe "" "$ADDR" outside-lan)
check "TC-973-20 control: outside the unit's cgroup the send to $ADDR succeeds" \
	"$(yes_if [ "$out" = sent ])" "$out"
check "TC-973-20 control: the listener on $ADDR received it, so the container's network carries it" \
	"$(yes_if received /run/probe-lan outside-lan)"
out=$(probe "$CG" "$ADDR" inside-lan)
check "TC-973-20 inside the unit's cgroup the send to $ADDR gets EPERM" \
	"$(yes_if contains 'Operation not permitted' "$out")" "$out"
out=$(probe "$CG" 127.0.0.1 inside-lo)
check "TC-973-20 inside the unit's cgroup the send to 127.0.0.1 succeeds" \
	"$(yes_if [ "$out" = sent ])" "$out"
check "TC-973-20 the loopback listener received it" "$(yes_if received /run/probe-lo inside-lo)"
check "TC-973-20 the listener on $ADDR never received the denied datagram" \
	"$(yes_if inside "! grep -qx inside-lan /run/probe-lan")" "$(inside 'cat /run/probe-lan')"

echo
if [ "$fails" -eq 0 ]; then
	echo "identity-unit-functional: all checks passed"
else
	echo "identity-unit-functional: $fails check(s) FAILED"
fi
[ "$fails" -eq 0 ]
