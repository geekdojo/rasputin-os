#!/bin/sh
# Functional test for how rasputin-api.service is wired to the secrets store,
# against REAL systemd 258.7 as PID 1 (the release Buildroot 2026.08 builds
# into the image), with the shipped api and store units and one docker volume
# standing in for the persistent partition (geekdojo/geekdojo-brain#757).
#
# WHY THIS EXISTS. test/api-store-wiring-test.sh pins the lines. What only
# systemd can show is what they do: that the api's Wants= pulls a store nothing
# else wants into the api's own start, that the api comes up with the store
# skipped, stopped or restarted, and that the environment the api's process
# gets holds the selector and the address byte-exact.
#
# Boots, each a new container on the same volume:
#   1  role marker and store CA, no server leaf, as on a node upgraded from
#      2026.10.0: the store is pulled in and skipped, the api is active
#      (TC-757-05)
#   2  the server leaf and placeholder seal material too: the store starts
#      before the api; stopping it, then reset-failed and restart, leave the
#      api active on its boot MainPID with no restart (TC-757-06)
#   3  boot 2 plus a Requires=openbao.service drop-in on the api: a store
#      restart now restarts the api, so the test can tell a hard dependency
#      from Wants= (TC-757-07)
#
# TEST HARNESS, not from the image, and labelled where it is done:
#   * the store and the api run stand-in ExecStart lines (`sleep infinity`,
#     Type=simple, no watchdog) through drop-ins. Their units are otherwise
#     verbatim, so their dependencies, ordering, conditions, credentials and
#     environment are the shipped ones. The store is wanted by NO target here,
#     so only the api's Wants= can start it;
#   * a stand-in rasputin-firstboot.service (the api Requires= it), and the role
#     marker, the store CA, the server leaf and the seal material, which
#     firstboot, the api and the seal-key oneshot write on a node, written by
#     the test as placeholder files;
#   * the openbao user, which mkusers creates on the image;
#   * `mount --make-rshared /` early in boot, which a booted image gets from
#     systemd's mount-setup and a container does not;
#   * boot 3's Requires= drop-in, the negative control.
#
# NOT COVERED: the real api binary (the pinned 2026.10.0 does not read the
# selector; its behaviour with the store down is #760), the image's kernel, and
# the other architecture: CI runs this on amd64. "The store fails at start and
# the api stays active" is test/seal-key-functional.sh boot 4 (TC-803-22),
# which runs the same shipped api unit.
#
# Needs: docker with privileged containers. Linux runner or Docker Desktop.
# Run:   sh test/api-store-wiring-functional.sh
#
# Every wait has a deadline and fails naming the fact that never became true.
# The deadlines bound the test; the units under test choose none.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
UNITS="$OVERLAY/etc/systemd/system"
TMPFILES="$OVERLAY/usr/lib/tmpfiles.d/rasputin.conf"
BASE=rasputin-api-store-wiring-functional:f43-systemd-258.7
IMAGE=rasputin-api-store-wiring-functional:boot
CTR_DEADLINE="${API_STORE_WIRING_TEST_DEADLINE:-90}"
V=/var/lib/rasputin
API=rasputin-api.service
STORE=openbao.service
WANT_BACKEND=RASPUTIN_SECRETSTORE_BACKEND=openbao
WANT_ADDR=RASPUTIN_SECRETSTORE_ADDR=https://127.0.0.1:8200
# systemd 258.7's journal line for a unit whose start job finds a condition
# unmet, captured from this test's own run (journalctl -o cat). With both leaf
# files absent it names the last unmet condition in the unit, the leaf key.
SKIP_LINE="$STORE - OpenBao secrets store skipped, unmet condition check ConditionPathExists=$V/tls/openbao-server/leaf.key"

command -v docker >/dev/null 2>&1 || { echo "FAILED: this test needs docker, and docker is not on PATH."; exit 1; }
for f in "$TMPFILES" "$UNITS/$API" "$UNITS/$STORE"; do
	[ -f "$f" ] || { echo "FAILED: the file $f is missing."; exit 1; }
done

. "$ROOT/test/lib/checks.sh"
. "$ROOT/test/lib/f43-systemd.sh"
. "$ROOT/test/lib/container-systemd.sh"

SCRATCH=$(mktemp -d)
VOL="rasputin-api-store-wiring-functional-$$"
cleanup() {
	ctr_cleanup
	docker volume rm -f "$VOL" >/dev/null 2>&1
	docker image rm -f "$IMAGE" >/dev/null 2>&1
	rm -rf "$SCRATCH"
}
trap cleanup EXIT INT TERM

# --- the image: the shipped units, plus the labelled harness -------------------
f43_systemd_image "$BASE" || exit 1
CTX="$SCRATCH/ctx"
mkdir -p "$CTX"
cp "$UNITS/$API" "$UNITS/$STORE" "$CTX/"
cp "$TMPFILES" "$CTX/rasputin.conf"
docker build -q -t "$IMAGE" -f - "$CTX" >/dev/null <<DOCKERFILE || { echo "FAILED: the boot image could not be built."; exit 1; }
FROM $BASE
# The shipped files, verbatim. The api is enabled as preset-all enables it; the
# store is wanted by nothing.
COPY $API $STORE /etc/systemd/system/
COPY rasputin.conf /usr/lib/tmpfiles.d/rasputin.conf
RUN mkdir -p /etc/systemd/system/multi-user.target.wants \\
 && ln -s /etc/systemd/system/$API /etc/systemd/system/multi-user.target.wants/
# TEST HARNESS: both the store and the api run a stand-in. The store's
# stand-in also clears the self-init outcome hooks (#804): they record what
# bao's first start did, and with no bao there is nothing to record. A
# Type=simple stand-in would also run ExecStartPost alongside its own start,
# which the shipped Type=notify unit never does (it waits for READY).
RUN mkdir -p /etc/systemd/system/$STORE.d /etc/systemd/system/$API.d \\
 && printf '[Service]\nType=simple\nExecStartPre=\nExecStartPost=\nExecStopPost=\nExecStart=\nExecStart=/usr/bin/sleep infinity\n' \\
      > /etc/systemd/system/$STORE.d/harness.conf \\
 && printf '[Service]\nType=simple\nWatchdogSec=0\nExecStart=\nExecStart=/usr/bin/sleep infinity\n' \\
      > /etc/systemd/system/$API.d/harness.conf
# TEST HARNESS: firstboot, which the api Requires=, as a stand-in.
RUN printf '[Unit]\nDescription=stand-in firstboot\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/bin/true\n' \\
      > /etc/systemd/system/rasputin-firstboot.service
# TEST HARNESS: the openbao user, which mkusers creates on the image.
RUN echo 'openbao:x:990:' >>/etc/group && echo 'openbao:x:990:990::/:/sbin/nologin' >>/etc/passwd
# TEST HARNESS: a shared root, as systemd's mount-setup gives a booted image.
RUN printf '[Unit]\nDefaultDependencies=no\nBefore=sysinit.target\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/bin/mount --make-rshared /\n[Install]\nWantedBy=sysinit.target\n' \\
      > /etc/systemd/system/harness-rshared.service \\
 && mkdir -p /etc/systemd/system/sysinit.target.wants \\
 && ln -s /etc/systemd/system/harness-rshared.service /etc/systemd/system/sysinit.target.wants/
DOCKERFILE

docker volume create "$VOL" >/dev/null || { echo "FAILED: the docker volume could not be created."; exit 1; }
# on_volume SCRIPT — run SCRIPT as root on the volume, with no init: the
# persistent partition between boots.
on_volume() { docker run --rm -v "$VOL:$V" "$IMAGE" sh -c "$1"; }

# boot N [DOCKER_RUN_OPTION ...] — a new container on the volume.
boot() {
	_n=$1; shift
	ctr_boot "boot $_n" "$IMAGE" -v "$VOL:$V" "$@"
}
show() { inside "systemctl show $1 -p $2 --value"; }
# settled UNIT STATE — wait until UNIT is STATE with no job queued.
settled() {
	wait_for "$1 is $2 with no job queued" \
		"[ \"\$(systemctl show $1 -p ActiveState --value)\" = $2 ] && [ -z \"\$(systemctl show $1 -p Job --value)\" ]" \
		|| fails=$((fails + 1))
}
# api_steady LABEL — the api is active on BOOT_PID with no restart.
api_steady() {
	_st="$(show $API ActiveState) $(show $API MainPID) $(show $API NRestarts)"
	check "TC-757-06 $1: the api is active on its boot MainPID with NRestarts=0 (want 'active $BOOT_PID 0', got '$_st')" \
		"$(yes_if [ "$_st" = "active $BOOT_PID 0" ])"
}

# TEST HARNESS: what firstboot leaves on a control plane, and the store CA the
# api minted on the previous release. No server leaf.
on_volume "
set -e
chmod 0755 $V
touch $V/role.controlplane
mkdir -p $V/trust
echo placeholder-ca > $V/trust/store-ca.pem
" || { echo "FAILED: could not prepare the volume."; exit 1; }

echo
echo "boot 1: no server leaf, so the store the api pulls in is skipped and the api is up (TC-757-05)"
boot 1 || exit 1
echo "in the container: $(inside 'systemctl --version | head -1')"
settled $API active
wait_for "$STORE has a condition timestamp and no job queued" \
	"[ \"\$(systemctl show $STORE -p ConditionTimestampMonotonic --value)\" -gt 0 ] && [ -z \"\$(systemctl show $STORE -p Job --value)\" ]" \
	|| fails=$((fails + 1))
st=$(show $API ActiveState)
check "TC-757-05 the api is active (got '$st')" "$(yes_if [ "$st" = active ])"
st=$(show $STORE ActiveState)
check "TC-757-05 the store is inactive, not failed (got '$st')" "$(yes_if [ "$st" = inactive ])"
failed=$(inside "systemctl --failed --no-legend --plain")
r=1; contains "$STORE" "$failed" || r=0
check "TC-757-05 systemctl --failed does not list the store" "$r" "$failed"
st="$(show $STORE ConditionResult) $(show $STORE ConditionTimestampMonotonic)"
r=1; [ "${st%% *}" = no ] && [ "${st#* }" -gt 0 ] 2>/dev/null && r=0
check "TC-757-05 the store's ConditionResult=no with a non-zero ConditionTimestampMonotonic (got '$st')" "$r"
line=$(inside "journalctl -u $STORE --no-pager -o cat" | grep -xF -- "$SKIP_LINE" | head -1)
check "TC-757-05 the store's journal has systemd's skip line: $SKIP_LINE" "$(yes_if [ -n "$line" ])" \
	"journal: $(inside "journalctl -u $STORE --no-pager -o cat" | tr '\n' '|')"
st=$(show $STORE WantedBy)
check "TC-757-05 the store's WantedBy includes $API (got '$st')" "$(yes_if contains " $API " " $st ")"
st=$(show multi-user.target Wants)
r=0; contains " $STORE " " $st " && r=1
check "TC-757-05 multi-user.target does not want the store" "$r" "multi-user.target Wants=$st"
pid=$(show $API MainPID)
inside "tr '\\0' '\\n' < /proc/$pid/environ" > "$SCRATCH/environ" 2>/dev/null
for want in "$WANT_BACKEND" "$WANT_ADDR"; do
	n=$(grep -cxF -- "$want" "$SCRATCH/environ")
	check "TC-757-05 /proc/<api MainPID $pid>/environ holds '$want' byte-exact, once (got $n)" "$(yes_if [ "$n" = 1 ])" \
		"$(grep '^RASPUTIN_SECRETSTORE_' "$SCRATCH/environ" | tr '\n' '|')"
done

echo
echo "boot 2: the store starts before the api, and stopping or restarting it leaves the api alone (TC-757-06)"
ctr_cleanup
# TEST HARNESS: the server leaf the api mints and the seal material the
# seal-key oneshot writes, as placeholders the stand-in store never reads.
on_volume "
set -e
mkdir -p $V/tls/openbao-server $V/openbao-seal
echo placeholder-leaf > $V/tls/openbao-server/leaf.pem
echo placeholder-key > $V/tls/openbao-server/leaf.key
echo placeholder-seal-key > $V/openbao-seal/seal-key
echo placeholder-seal-hcl > $V/openbao-seal/seal.hcl
" || check "the server leaf and seal material were written" 1
boot 2 || exit 1
settled $STORE active
settled $API active
store_t=$(show $STORE ActiveEnterTimestampMonotonic)
api_t=$(show $API ExecMainStartTimestampMonotonic)
r=1; [ "${store_t:-0}" -gt 0 ] && [ "${api_t:-0}" -gt "$store_t" ] && r=0
check "TC-757-06 the store was active ($store_t) before the api's process started ($api_t)" "$r"
BOOT_PID=$(show $API MainPID)
echo "  the api's boot MainPID is $BOOT_PID"
api_steady "at boot"
inside "systemctl stop $STORE" || check "systemctl stop $STORE succeeded" 1
settled $STORE inactive
settled $API active
api_steady "after systemctl stop $STORE"
inside "systemctl reset-failed $STORE; systemctl restart $STORE" || check "systemctl restart $STORE succeeded" 1
settled $STORE active
settled $API active
api_steady "after systemctl reset-failed $STORE; systemctl restart $STORE"

echo
echo "boot 3: control, with Requires=$STORE on the api a store restart restarts the api (TC-757-07)"
ctr_cleanup
# TEST HARNESS: the hard dependency the shipped unit refuses.
printf '[Unit]\nRequires=%s\n' "$STORE" > "$SCRATCH/control-requires.conf"
boot 3 -v "$SCRATCH/control-requires.conf:/etc/systemd/system/$API.d/control-requires.conf:ro" || exit 1
settled $STORE active
settled $API active
st=$(show $API Requires)
check "TC-757-07 the control's drop-in is loaded: the api Requires= includes $STORE (got '$st')" "$(yes_if contains " $STORE " " $st ")"
before=$(show $API MainPID)
inside "systemctl restart $STORE" || check "systemctl restart $STORE succeeded" 1
settled $STORE active
settled $API active
after=$(show $API MainPID)
r=1; [ "${before:-0}" -gt 0 ] && [ "${after:-0}" -gt 0 ] && [ "$after" != "$before" ] && r=0
check "TC-757-07 control: with Requires= the api's MainPID changed on a store restart ($before -> $after)" "$r"

echo
if [ "$fails" -eq 0 ]; then
	echo "api-store-wiring-functional: all checks passed"
else
	echo "api-store-wiring-functional: $fails check(s) FAILED"
fi
[ "$fails" -eq 0 ]
