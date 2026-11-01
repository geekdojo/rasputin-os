#!/bin/sh
# Functional test for the secrets store's unit, openbao.service, against REAL
# systemd 258.7 as PID 1 (the release Buildroot 2026.08 builds into the image)
# and the REAL pinned bao, downloaded for this machine's architecture and
# checked against package/openbao/openbao.hash (geekdojo/geekdojo-brain#755),
# running the image's own main config, openbao.hcl, and self-init config,
# init.json, byte for byte (#756, #804), with the policy files taken from the
# pinned rasputin-api tarball (#804).
#
# WHY THIS EXISTS. The unit is nothing but systemd configuration around a
# third-party binary, and what matters about it is what systemd and bao do with
# it together: whether bao runs at all as 990:990 with no capabilities inside a
# read-only filesystem, whether LoadCredential= reaches it, whether the
# conditions skip it cleanly, and what a crash loop leaves behind. A static
# test cannot show any of that, and neither can a stub ExecStart.
#
# Scenarios, in one container, in this order:
#   0  the test fails closed: no docker, a failed download, a tarball that
#      does not match openbao.hash and a tree with no openbao.hcl or no
#      init.json each stop it with a sentence (TC-755-08, TC-756-10)
#   1  wanted: post-build.sh's link survives real preset-all, and the unit is
#      enabled (TC-756-11)
#   2  no role marker: skipped, not failed (TC-755-10)
#   3  first boot, no leaf or no CA: skipped; then a restart starts it
#      (TC-755-11). That first real start self-initialises the store from
#      init.json, so from here on it is initialised (#804).
#   4  no seal key: fails, never skips (TC-755-12)
#
# The seal key and the seal fragment are NOT harness: the real
# rasputin-seal-key.sh (#803) writes them in the container, against the empty
# store tree tmpfiles makes, so scenario 5's credential and sys/health checks
# run bao on the oneshot's own output under 258.7 (TC-803-24).
#   5  the running store: its user, capabilities, environment, core limit,
#      credentials, writable paths and memory (TC-755-13 to TC-755-16, 18)
#   6  repeated crashes: the start limit, then recovery by reset-failed and
#      start (TC-755-17)
#   7  the shipped config at work, on an emptied data directory: the store
#      initialises itself with no sys/init call, leaves t=0 n=0 and no root
#      token, holds the tarball's policy text, the kv-v2 mount, exactly the
#      two roles and one audit device whose file is 0600 990:990 and HMACs a
#      written value, and the outcome record says initialised (TC-804-18);
#      the audit records the api's X-Rasputin-Job-Id header in plain text
#      (TC-802-16); a restart runs no self-init and changes none of it, the
#      header included, unsealing from the oneshot's fragment with no unseal
#      call (TC-804-19, TC-756-15); the
#      only bao socket is 127.0.0.1:8200 (TC-756-12); only a store-CA client
#      certificate finishes the handshake (TC-756-13); the unauthenticated
#      rekey and generate-root endpoints (TC-756-14); log level info
#      (TC-756-16); and no key material or token in the journal (TC-756-17)
#   8  a forced failed self-init, one policy file missing: bao's ERROR line,
#      a <3> rasputin-store-init: outcome=failed line and record, later
#      starts refusing to unseal into the start limit, the record unchanged,
#      and no token in the journal (TC-804-20)
#   9  a seal-key rotation through the shipped unit, by hand as the api's job
#      does it (geekdojo/geekdojo-brain#830): an empty rotation/ starts the
#      store with no extra credential; key B staged with the Staged fragment
#      reaches it as seal-rotation_<id> and opens it; sys/rotate/root answers
#      204 to the rasputin-seal-rotate role from init.json; Verify (B alone)
#      and then Clean (seal-key = B) each open it; rotation/ removed fails the
#      unit at the CREDENTIALS step; and no key byte or token in the journal
#      (TC-830-26)
#  10  the store provisioner, rasputin-store-provision.service (#805): a
#      one-item first boot whose wait ends on the replayed success line
#      (TC-805-27); N to N+1 with no root token (TC-805-29); the no-op
#      re-apply (TC-805-30); a refused write (TC-805-31); a wrong-key store
#      that ends on bao's own failure line, not a timer (TC-805-32); the store
#      stopped mid-wait (TC-805-33); the store crashing into its start limit
#      mid-wait (F-805-19); the provisioner's leaf absent
#      (TC-805-34); and #833's read point (TC-805-41)
#      The provisioner holds Requisite= and PartOf= on the store, never a
#      requirement dependency, which cuts scenario 6's and scenario 8's crash
#      loops short of StartLimitBurst under 258.7 (ledger F-805-17). The store
#      starts it from its last ExecStartPost=, never by Wants=, whose queued
#      job Requisite= fails with result 'dependency' when the store is
#      condition-skipped (ledger F-805-28). This scenario shows what it relies
#      on: a condition-skipped store leaves it inactive with no failed job
#      (scenarios 2 and 3, TC-805-27), a stopped store stops it
#      mid-wait and it records failed (TC-805-33), and a restarted store
#      re-runs it under a new run_id (TC-805-30, TC-805-41). A store that
#      crashes mid-wait stops it too, into its start limit with NRestarts
#      still StartLimitBurst: Restart=always queues a restart job on every
#      exit, the refused last one included, and PartOf= carries it (F-805-19).
#  11  the store's first start with the console redirect below removed: the
#      outcome writer's line reaches the real /dev/kmsg from inside the
#      store's unit, its device policy included (TC-804-23's console path)
#  12  a staged store restore applied around a running store
#      (geekdojo/geekdojo-brain#766): the shipped rasputin-api.service, with a
#      stub ExecStart playing the api's restore hook, stops the store and
#      exits 75; its restart pulls the store's start in, whose first
#      ExecStartPre= swaps the staged data, seal key and fragment in, and the
#      store comes up unsealed on the restored secrets before the api's next
#      start sees the marker (TC-766-16); a staging missing seal.hcl fails the
#      store's start, changes nothing and writes no marker (TC-766-17); and no
#      start in scenarios 1 to 11 printed a rasputin-store-restore: line
#      (TC-766-18)
#  13  the store's version gate (geekdojo/geekdojo-brain#801), the unit's
#      second ExecStartPre=: a start on data with no version marker adopts it
#      as the pin (TC-801-35); equal versions change nothing (13a,
#      TC-801-31); data marked newer than the pin with a pre-update copy in
#      #800's shape, its version the live store's sys/health version, is
#      rolled back to the copy before bao starts (13b, TC-801-32); with no
#      copy the store never runs, its data is untouched and it stays stopped
#      across restarts (13c, TC-801-33); and the gate's lines carry its
#      identifier (13d, TC-801-34). Scenario 12's staged openbao-version is
#      the live store's sys/health version (F-801-02), and every start in
#      scenarios 1 to 12 passed the gate (TC-801-35)
# The provisioner runs in every scenario from 2 on, as on a node: each start
# of the store that reaches READY starts it. Scenario 3's first boot carries TC-805-27's empty
# provision.tsv half, and scenario 7 its four policies and three roles
# (TC-805-28).
#
# The main config is the overlay's openbao.hcl, installed byte for byte
# (TC-756-09); this test writes no config of its own.
#
# TEST HARNESS, not from the image, and labelled where it is done:
#   * the openbao user, which mkusers creates on the image from OPENBAO_USERS;
#   * a throwaway PKI (test/lib/test-pki.sh) standing in for the store CA and
#     the server leaf the api mints (#758), plus a foreign CA's client leaf;
#   * the policy files under /usr/share/rasputin/openbao-policy/, which
#     package/rasputin-api installs on the image, copied in from the pinned api
#     tarball (test/lib/api-tarball.sh, checked against rasputin-api.hash);
#   * scenario 7's test-only inspector: a drop-in ExecStart that is the
#     shipped one plus -config=/etc/rasputin/openbao/test-inspector.json, a
#     self-init stanza adding one read-only role for the test's own leaf, so
#     the test can read what self-init made without a root token;
#   * a drop-in Environment= pointing rasputin-store-init.sh's console line at
#     a file, because in a privileged container /dev/kmsg is the host's, and
#     the same for rasputin-store-provision.sh;
#   * the provisioner's leaf, minted by the test PKI where the api mints it
#     (#805), and a leaf for a provisioned role's CommonName;
#   * scenario 10's labelled provision.tsv files, its stub rasputin-api.service,
#     the copy of the oneshot whose parse admits rasputin-seal-rotate
#     (TC-805-31), a wrong seal key (TC-805-32, TC-805-33) and a LogLevelMax
#     drop-in that keeps bao's lines out of the journal (TC-805-33);
#   * scenario 8's missing policy file;
#   * scenario 12's stub api ExecStart (a drop-in on the shipped
#     rasputin-api.service), its stand-in rasputin-firstboot.service, the
#     stores A and B and the staging laid out as the api's PrepareRestore lays
#     it out, written by the test; A and B share the test store CA, standing
#     in for the api placing the restored CA (#765);
#   * scenario 13's drop-in ExecStartPre= after the shipped three, which
#     hashes the data directory between the gate and bao, its pre-update copy
#     built by the test in #800's layout, and its version markers;
#   * `mount --make-rshared /`. A booted image gets a shared root from systemd
#     itself (mount-setup); a container's root is private, and without this the
#     credentials systemd mounts never reach the service.
#
# NOT COVERED: the image's kernel and squashfs (test/update-smoke.sh), memory
# under load (F3.6), the api's first-boot handoff (#758), F3.3's alert itself
# (#760), the job and alert for a failed init (#833), the real api binary's
# restore (#765) and its store CA re-issue, and the other architecture: CI
# runs this on amd64. The unauthenticated-endpoint codes in
# scenario 7 cannot tell the options from their defaults; their placement is
# test/store-config-test.sh's.
#
# Needs: docker with privileged containers, openssl, GNU make, curl, jq,
# network access to the OpenBao and control-plane releases. Linux runner or
# Docker Desktop. RASPUTIN_API_TARBALL is test/lib/api-tarball.sh's test-only
# override; CI never sets it.
# Run:   sh test/store-unit-functional.sh
#
# Every wait below has a deadline and fails naming the fact that never became
# true. The deadlines bound the test; the unit under test chooses none.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
UNIT="$OVERLAY/etc/systemd/system/openbao.service"
TMPFILES="$OVERLAY/usr/lib/tmpfiles.d/rasputin.conf"
CONFIG="$OVERLAY/etc/rasputin/openbao/openbao.hcl"
INIT="$OVERLAY/etc/rasputin/openbao/init.json"
STOREINIT="$OVERLAY/usr/lib/rasputin/store-init/rasputin-store-init.sh"
STORERESTORE="$OVERLAY/usr/lib/rasputin/store-restore/rasputin-store-restore.sh"
STOREROLLBACK="$OVERLAY/usr/lib/rasputin/store-rollback/rasputin-store-rollback.sh"
STORESWAP="$OVERLAY/usr/lib/rasputin/store-swap/swap.sh"
APIUNIT="$OVERLAY/etc/systemd/system/rasputin-api.service"
PUNIT="$OVERLAY/etc/systemd/system/rasputin-store-provision.service"
PSCRIPT="$OVERLAY/usr/lib/rasputin/store-provision/rasputin-store-provision.sh"
PTSV="$OVERLAY/etc/rasputin/openbao/provision.tsv"
OUTCOME_LIB="$OVERLAY/usr/lib/rasputin/outcome/outcome.sh"
APIPKG="$ROOT/package/rasputin-api"
POSTBUILD="$ROOT/board/rasputin/common/post-build.sh"
PKG="$ROOT/package/openbao"
TLS_REFUSAL="$ROOT/test/lib/tls-refusal.sh"
IMAGE=rasputin-store-unit-functional:f43-systemd-258.7
CTR_DEADLINE="${STORE_UNIT_TEST_DEADLINE:-60}"
V=/var/lib/rasputin
CREDS=/run/credentials/openbao.service
PORT=8200

# --- fail closed (scenario 0 checks this) ------------------------------------
command -v docker >/dev/null 2>&1 || { echo "FAILED: this test needs docker, and docker is not on PATH."; exit 1; }
for t in openssl make curl tar jq; do
	command -v "$t" >/dev/null 2>&1 || { echo "FAILED: this test needs $t, and it is not on PATH."; exit 1; }
done
for f in "$UNIT" "$TMPFILES" "$POSTBUILD" "$PKG/openbao.mk" "$PKG/openbao.hash" "$TLS_REFUSAL" \
	"$STOREINIT" "$STORERESTORE" "$STOREROLLBACK" "$STORESWAP" "$APIUNIT" "$OUTCOME_LIB" "$APIPKG/rasputin-api.mk" "$APIPKG/rasputin-api.hash" "$PUNIT" "$PSCRIPT" "$PTSV"; do
	[ -f "$f" ] || { echo "FAILED: the file $f is missing."; exit 1; }
done
# The store's main config, which this test never writes for itself (TC-756-10).
[ -f "$CONFIG" ] || { echo "FAILED: the store's main config $CONFIG is missing, and this test runs only the shipped one."; exit 1; }
[ -f "$INIT" ] || { echo "FAILED: the store's self-init config $INIT is missing, and this test runs only the shipped one."; exit 1; }

. "$ROOT/test/lib/checks.sh"
. "$ROOT/test/lib/mk-var.sh"
. "$ROOT/test/lib/f43-systemd.sh"
. "$ROOT/test/lib/container-systemd.sh"
. "$ROOT/test/lib/test-pki.sh"
. "$ROOT/test/lib/listen-sockets.sh"
. "$ROOT/test/lib/api-tarball.sh"
neither() { ! contains "$1" "$3" && ! contains "$2" "$3"; }
not_contains() { ! contains "$1" "$2"; }

SCRATCH=$(mktemp -d)
cleanup() { ctr_cleanup; rm -rf "$SCRATCH"; }
trap cleanup EXIT INT TERM

# The architecture of the containers docker runs, which is the bao this needs.
case "$(docker info --format '{{.Architecture}}' 2>/dev/null)" in
	aarch64|arm64) BR_ARCH=BR2_aarch64 ;;
	x86_64|amd64) BR_ARCH=BR2_x86_64 ;;
	*) echo "FAILED: docker reports an architecture this test has no OpenBao tarball for: '$(docker info --format '{{.Architecture}}' 2>/dev/null)'."; exit 1 ;;
esac

# The pin, the tarball name and the static user, read the way Buildroot reads
# them. No version, URL or uid is written in this file.
SITE=$(mk_var "$PKG/openbao.mk" OPENBAO_SITE) || exit 1
PIN=$(mk_var "$PKG/openbao.mk" OPENBAO_VERSION) || exit 1
SOURCE=$(mk_var "$PKG/openbao.mk" OPENBAO_SOURCE BR2_PACKAGE_OPENBAO=y "$BR_ARCH=y") || exit 1
USERS=$(mk_var "$PKG/openbao.mk" OPENBAO_USERS) || exit 1
set -f
# shellcheck disable=SC2086 # the fields of OPENBAO_USERS; -f as field 5 is *
set -- $USERS
set +f
BAO_USER=$1 BAO_UID=$2 BAO_GROUP=$3 BAO_GID=$4

# --- fetch and verify the pinned binary ----------------------------------------
WANT_SHA=$(awk -v s="$SOURCE" '$1 == "sha256" && $3 == s { print $2 }' "$PKG/openbao.hash")
[ -n "$WANT_SHA" ] || { echo "FAILED: openbao.hash has no sha256 line for $SOURCE."; exit 1; }
echo "downloading $SITE/$SOURCE"
curl -fsSL -o "$SCRATCH/$SOURCE" "$SITE/$SOURCE" \
	|| { echo "FAILED: the download of $SITE/$SOURCE failed, so there is no bao to test."; exit 1; }
GOT_SHA=$(openssl dgst -sha256 -r "$SCRATCH/$SOURCE" | cut -d' ' -f1)
[ "$GOT_SHA" = "$WANT_SHA" ] \
	|| { echo "FAILED: $SOURCE does not match openbao.hash (got $GOT_SHA, want $WANT_SHA)."; exit 1; }
echo "  $SOURCE matches openbao.hash"
tar -xzf "$SCRATCH/$SOURCE" -C "$SCRATCH" bao \
	|| { echo "FAILED: $SOURCE has no bao in it."; exit 1; }

# --- the policy files, from the pinned api tarball (#804) ----------------------
api_policy_fetch "$ROOT" "$BR_ARCH" "$SCRATCH/api" || exit 1
echo "  policy files from api $API_VERSION: $(ls "$API_POLICY" | tr '\n' ' ')"

echo
echo "0. the test fails closed (TC-755-08)"
SH_BIN=$(command -v sh)
# No docker on PATH: a stub directory holding only dirname, which the script
# needs before it looks for docker.
mkdir -p "$SCRATCH/nodocker"
ln -s "$(command -v dirname)" "$SCRATCH/nodocker/dirname"
out=$(PATH="$SCRATCH/nodocker" "$SH_BIN" "$0" 2>&1); rc=$?
check "with no docker the test exits non-zero" "$(yes_if [ "$rc" -ne 0 ])" "exit=$rc"
check "with no docker the message names docker" "$(yes_if contains 'needs docker' "$out")" "$out"
check "with no docker nothing reports success or a skip" "$(yes_if neither passed skip "$out")" "$out"
# A root that is this tree with the pin's site moved: once to nowhere, once to
# a directory holding a tarball of the right name and the wrong content.
fake_root() {
	_r="$SCRATCH/$1"
	mkdir -p "$_r/test/lib" "$_r/package/openbao" "$_r/package/rasputin-api" \
		"$_r/board/rasputin/common/rootfs-overlay/etc/systemd/system" \
		"$_r/board/rasputin/common/rootfs-overlay/usr/lib/tmpfiles.d" \
		"$_r/board/rasputin/common/rootfs-overlay/usr/lib/rasputin/store-init" \
		"$_r/board/rasputin/common/rootfs-overlay/usr/lib/rasputin/store-restore" \
		"$_r/board/rasputin/common/rootfs-overlay/usr/lib/rasputin/store-rollback" \
		"$_r/board/rasputin/common/rootfs-overlay/usr/lib/rasputin/store-swap" \
		"$_r/board/rasputin/common/rootfs-overlay/usr/lib/rasputin/outcome" \
		"$_r/board/rasputin/common/rootfs-overlay/usr/lib/rasputin/store-provision" \
		"$_r/board/rasputin/common/rootfs-overlay/etc/rasputin/openbao"
	cp "$0" "$_r/test/store-unit-functional.sh"
	cp "$ROOT"/test/lib/*.sh "$_r/test/lib/"
	cp "$UNIT" "$PUNIT" "$APIUNIT" "$_r/board/rasputin/common/rootfs-overlay/etc/systemd/system/"
	cp "$CONFIG" "$INIT" "$PTSV" "$_r/board/rasputin/common/rootfs-overlay/etc/rasputin/openbao/"
	cp "$PSCRIPT" "$_r/board/rasputin/common/rootfs-overlay/usr/lib/rasputin/store-provision/"
	cp "$STOREINIT" "$_r/board/rasputin/common/rootfs-overlay/usr/lib/rasputin/store-init/"
	cp "$STORERESTORE" "$_r/board/rasputin/common/rootfs-overlay/usr/lib/rasputin/store-restore/"
	cp "$STOREROLLBACK" "$_r/board/rasputin/common/rootfs-overlay/usr/lib/rasputin/store-rollback/"
	cp "$STORESWAP" "$_r/board/rasputin/common/rootfs-overlay/usr/lib/rasputin/store-swap/"
	cp "$OUTCOME_LIB" "$_r/board/rasputin/common/rootfs-overlay/usr/lib/rasputin/outcome/"
	cp "$APIPKG/rasputin-api.mk" "$APIPKG/rasputin-api.hash" "$_r/package/rasputin-api/"
	cp "$POSTBUILD" "$_r/board/rasputin/common/"
	cp "$TMPFILES" "$_r/board/rasputin/common/rootfs-overlay/usr/lib/tmpfiles.d/"
	cp "$PKG/openbao.hash" "$_r/package/openbao/"
	sed "s|^OPENBAO_SITE = .*|OPENBAO_SITE = $2|" "$PKG/openbao.mk" >"$_r/package/openbao/openbao.mk"
	echo "$_r/test/store-unit-functional.sh"
}
out=$("$SH_BIN" "$(fake_root nosite http://127.0.0.1:9)" 2>&1); rc=$?
check "a failed download exits non-zero" "$(yes_if [ "$rc" -ne 0 ])" "exit=$rc"
check "a failed download is named as one" "$(yes_if contains 'the download of' "$out")" "$out"
check "a failed download reports no success or skip" "$(yes_if neither passed skip "$out")" "$out"
mkdir -p "$SCRATCH/badsite"
echo "not the pinned tarball" >"$SCRATCH/badsite/$SOURCE"
out=$("$SH_BIN" "$(fake_root badhash "file://$SCRATCH/badsite")" 2>&1); rc=$?
check "a tarball that does not match openbao.hash exits non-zero" "$(yes_if [ "$rc" -ne 0 ])" "exit=$rc"
check "the mismatch names openbao.hash" "$(yes_if contains 'does not match openbao.hash' "$out")" "$out"
check "a mismatch reports no success or skip" "$(yes_if neither passed skip "$out")" "$out"
# No openbao.hcl in the overlay (TC-756-10): a stop with a sentence, never a
# config of the test's own.
_r=$(fake_root noconfig "file://$SCRATCH/badsite")
rm -f "$SCRATCH/noconfig/board/rasputin/common/rootfs-overlay/etc/rasputin/openbao/openbao.hcl"
out=$("$SH_BIN" "$_r" 2>&1); rc=$?
check "TC-756-10 with no openbao.hcl the test exits non-zero" "$(yes_if [ "$rc" -ne 0 ])" "exit=$rc"
check "TC-756-10 with no openbao.hcl the message names the missing config" "$(yes_if contains 'openbao.hcl is missing' "$out")" "$out"
check "TC-756-10 with no openbao.hcl nothing reports success or a skip" "$(yes_if neither passed skip "$out")" "$out"
printf '         it said: %s\n' "$out"
_r=$(fake_root noinit "file://$SCRATCH/badsite")
rm -f "$SCRATCH/noinit/board/rasputin/common/rootfs-overlay/etc/rasputin/openbao/init.json"
out=$("$SH_BIN" "$_r" 2>&1); rc=$?
check "TC-804-18 with no init.json the test exits non-zero" "$(yes_if [ "$rc" -ne 0 ])" "exit=$rc"
check "TC-804-18 with no init.json the message names the missing config" "$(yes_if contains 'init.json is missing' "$out")" "$out"
check "TC-804-18 with no init.json nothing reports success or a skip" "$(yes_if neither passed skip "$out")" "$out"
printf '         it said: %s\n' "$out"
# The 258.7 pin refusal is f43_systemd_is_pinned, shown by
# test/store-paths-functional.sh (TC-754-17).

# --- the test PKI (TEST HARNESS: stands in for the CA and leaf the api mints) ---
# server: the store CA's serverAuth leaf, SAN 127.0.0.1; it is also the
# "serverAuth only" client of TC-756-13. client: the store CA's clientAuth
# leaf. api: the leaf the api mints for itself, CN rasputin-api (#758).
# inspector: the test-only inspector's leaf. foreign: a clientAuth leaf from a
# CA the store does not trust.
P="$SCRATCH/pki"
mkdir -p "$P"
{
	mint_ca "$P/ca.key" "$P/store-ca.pem" store-unit-test-ca &&
	mint_leaf "$P/server.key" "$P/server.pem" store-unit-test-server "$P/store-ca.pem" "$P/ca.key" serverAuth IP:127.0.0.1 &&
	mint_leaf "$P/client.key" "$P/client.pem" store-unit-test-client "$P/store-ca.pem" "$P/ca.key" clientAuth &&
	mint_leaf "$P/api.key" "$P/api.pem" rasputin-api "$P/store-ca.pem" "$P/ca.key" clientAuth &&
	mint_leaf "$P/inspector.key" "$P/inspector.pem" store-unit-test-inspector "$P/store-ca.pem" "$P/ca.key" clientAuth &&
	mint_leaf "$P/rotate.key" "$P/rotate.pem" rasputin-seal-rotate "$P/store-ca.pem" "$P/ca.key" clientAuth &&
	mint_leaf "$P/provisioner.key" "$P/provisioner.pem" rasputin-provisioner "$P/store-ca.pem" "$P/ca.key" clientAuth &&
	mint_leaf "$P/rel.key" "$P/rel.pem" rasputin-rel-n1 "$P/store-ca.pem" "$P/ca.key" clientAuth &&
	mint_ca "$P/foreign-ca.key" "$P/foreign-ca.pem" store-unit-test-foreign-ca &&
	mint_leaf "$P/foreign.key" "$P/foreign.pem" store-unit-test-foreign "$P/foreign-ca.pem" "$P/foreign-ca.key" clientAuth
} || { echo "FAILED: openssl could not make the test PKI."; exit 1; }

# --- the container ---------------------------------------------------------------
f43_systemd_image "$IMAGE" || exit 1
ctr_boot "the store unit" "$IMAGE" -v "$OVERLAY:/overlay:ro" || exit 1
echo "in the container: $(inside 'systemctl --version | head -1')"
if ! { docker cp "$SCRATCH/bao" "$CID:/usr/bin/bao" >/dev/null && docker cp "$P" "$CID:/pki" >/dev/null \
	&& docker cp "$TLS_REFUSAL" "$CID:/root/tls-refusal.sh" >/dev/null \
	&& docker cp "$API_POLICY" "$CID:/root/openbao-policy" >/dev/null; }; then
	echo "FAILED: could not copy bao, the test PKI, test/lib/tls-refusal.sh and the policy files into the container."; exit 1
fi

inside "
set -e
# TEST HARNESS: a booted image gets a shared root from systemd's mount-setup.
mount --make-rshared /
# TEST HARNESS: mkusers creates this user on the image, from OPENBAO_USERS.
! getent passwd $BAO_UID >/dev/null && ! getent group $BAO_GID >/dev/null
echo '$BAO_GROUP:x:$BAO_GID:' >>/etc/group
echo '$BAO_USER:x:$BAO_UID:$BAO_GID::/:/sbin/nologin' >>/etc/passwd
chown 0:0 /usr/bin/bao && chmod 0755 /usr/bin/bao
# The image's tmpfiles.d creates the persistent tree, as on a node. Lines this
# container cannot satisfy (the console master copy, the baked root CA) are
# not this test's.
mkdir -p $V && chmod 0755 $V
install -D -m 0644 /overlay/usr/lib/tmpfiles.d/rasputin.conf /usr/lib/tmpfiles.d/rasputin.conf
systemd-tmpfiles --create /usr/lib/tmpfiles.d/rasputin.conf >/dev/null 2>&1 || true
# The unit, the main and self-init configs and the outcome writer with its
# library, verbatim from the overlay.
install -m 0644 /overlay/etc/systemd/system/openbao.service /etc/systemd/system/openbao.service
install -D -m 0644 /overlay/etc/rasputin/openbao/openbao.hcl /etc/rasputin/openbao/openbao.hcl
install -D -m 0644 /overlay/etc/rasputin/openbao/init.json /etc/rasputin/openbao/init.json
install -D -m 0755 /overlay/usr/lib/rasputin/store-init/rasputin-store-init.sh /usr/lib/rasputin/store-init/rasputin-store-init.sh
install -D -m 0755 /overlay/usr/lib/rasputin/store-restore/rasputin-store-restore.sh /usr/lib/rasputin/store-restore/rasputin-store-restore.sh
install -D -m 0755 /overlay/usr/lib/rasputin/store-rollback/rasputin-store-rollback.sh /usr/lib/rasputin/store-rollback/rasputin-store-rollback.sh
install -D -m 0644 /overlay/usr/lib/rasputin/store-swap/swap.sh /usr/lib/rasputin/store-swap/swap.sh
install -D -m 0644 /overlay/usr/lib/rasputin/outcome/outcome.sh /usr/lib/rasputin/outcome/outcome.sh
# The store provisioner (#805): its unit, its script and the shipped
# provision.tsv, verbatim.
install -m 0644 /overlay/etc/systemd/system/rasputin-store-provision.service /etc/systemd/system/rasputin-store-provision.service
install -D -m 0755 /overlay/usr/lib/rasputin/store-provision/rasputin-store-provision.sh /usr/lib/rasputin/store-provision/rasputin-store-provision.sh
install -D -m 0644 /overlay/etc/rasputin/openbao/provision.tsv /etc/rasputin/openbao/provision.tsv
# TEST HARNESS: package/rasputin-api installs the policy files on the image;
# here they come from the pinned api tarball, at the package's 0644.
mkdir -p /usr/share/rasputin/openbao-policy
install -m 0644 /root/openbao-policy/*.hcl /usr/share/rasputin/openbao-policy/
# TEST HARNESS: in a privileged container /dev/kmsg is the host's, so the
# outcome writer's console line goes to a file the test reads instead.
mkdir -p /etc/systemd/system/openbao.service.d
printf '[Service]\nEnvironment=RASPUTIN_STOREINIT_KMSG=/run/store-init-console\nEnvironment=RASPUTIN_STORERESTORE_KMSG=/run/store-restore-console\nEnvironment=RASPUTIN_STOREROLLBACK_KMSG=/run/store-rollback-console\n' >/etc/systemd/system/openbao.service.d/harness-console.conf
mkdir -p /etc/systemd/system/rasputin-store-provision.service.d
printf '[Service]\nEnvironment=RASPUTIN_STOREPROV_KMSG=/run/store-provision-console\n' >/etc/systemd/system/rasputin-store-provision.service.d/harness-console.conf
systemctl daemon-reload
" || { echo "FAILED: could not install the unit, its config and the test harness into the container."; exit 1; }
echo
echo "the shipped config (TC-756-09)"
want_sha=$(openssl dgst -sha256 -r "$CONFIG" | cut -d' ' -f1)
got_sha=$(inside "sha256sum /etc/rasputin/openbao/openbao.hcl" | cut -d' ' -f1)
r=1; [ -n "$want_sha" ] && [ "$got_sha" = "$want_sha" ] && r=0
check "TC-756-09 the installed openbao.hcl is the overlay's, byte for byte (sha256 $got_sha)" "$r" \
	"overlay $want_sha, installed $got_sha"
want_sha=$(openssl dgst -sha256 -r "$INIT" | cut -d' ' -f1)
got_sha=$(inside "sha256sum /etc/rasputin/openbao/init.json" | cut -d' ' -f1)
r=1; [ -n "$want_sha" ] && [ "$got_sha" = "$want_sha" ] && r=0
check "TC-804-18 the installed init.json is the overlay's, byte for byte (sha256 $got_sha)" "$r" \
	"overlay $want_sha, installed $got_sha"

# The seal key and fragment, from the real oneshot (#803, TC-803-24), run as
# root with its production paths. Its kernel-log line goes to /dev/null: in a
# privileged container /dev/kmsg is the host's. A copy of its output is kept
# in /pki, so put_seal below re-installs exactly what the oneshot wrote.
echo
echo "the seal key and fragment, from the real rasputin-seal-key.sh (TC-803-24)"
out=$(inside "RASPUTIN_SEALKEY_KMSG=/dev/null sh /overlay/usr/lib/rasputin/seal-key/rasputin-seal-key.sh; echo rc=\$?" 2>&1)
check "the oneshot exits 0" "$(yes_if contains 'rc=0' "$out")" "$out"
check "the oneshot reports outcome=created" "$(yes_if contains 'rasputin-seal-key: outcome=created' "$out")" "$out"
inside "cp -p $V/openbao-seal/seal-key /pki/seal-key && cp -p $V/openbao-seal/seal.hcl /pki/seal.hcl" \
	|| { echo "FAILED: could not keep a copy of the oneshot's key and fragment."; exit 1; }
ONESHOT_SHA=$(inside "cat $V/openbao-seal/seal-key $V/openbao-seal/seal.hcl | sha256sum")
# seal_is_oneshots LABEL — the installed pair is byte-identical to the oneshot's.
seal_is_oneshots() {
	check "$1: the installed key and fragment are the oneshot's, byte for byte" \
		"$(yes_if [ "$(inside "cat $V/openbao-seal/seal-key $V/openbao-seal/seal.hcl | sha256sum")" = "$ONESHOT_SHA" ])"
}

# The credential sources, written as their writers would (root, 0600 or 0644).
put_seal() { inside "install -m 0600 /pki/seal-key $V/openbao-seal/seal-key && install -m 0600 /pki/seal.hcl $V/openbao-seal/seal.hcl"; }
put_ca() { inside "install -m 0644 /pki/store-ca.pem $V/trust/store-ca.pem"; }
put_leaf() { inside "install -m 0644 /pki/server.pem $V/tls/openbao-server/leaf.pem && install -m 0600 /pki/server.key $V/tls/openbao-server/leaf.key"; }
# The provisioner's leaf, where the api mints it (#805).
put_prov_leaf() { inside "install -m 0644 /pki/provisioner.pem $V/tls/openbao-provisioner/leaf.pem && install -m 0600 /pki/provisioner.key $V/tls/openbao-provisioner/leaf.key"; }
PROV=rasputin-store-provision.service
PRECORD=/run/rasputin-store-provision/outcome
pshow() { inside "systemctl show $PROV -p $1 --value"; }
# prov_settled PREV_ID — waits until the provisioner has a run other than
# PREV_ID that has finished: no job, and active (exited) or failed.
prov_settled() {
	wait_for "a $PROV run after $1 has finished" \
		"[ -z \"\$(systemctl show $PROV -p Job --value)\" ] && [ \"\$(systemctl show $PROV -p InvocationID --value)\" != '$1' ] &&
		 case \"\$(systemctl show $PROV -p ActiveState --value)\" in active|failed) true ;; *) false ;; esac"
}
show() { inside "systemctl show openbao.service -p $1 --value"; }
# as_uid UID COMMAND — COMMAND as UID, its own group, no supplementary groups.
as_uid() { inside "setpriv --reuid=$1 --regid=$1 --clear-groups sh -c '$2'"; }
# --max-time bounds the one I/O call, so a listener that accepts and never
# answers is a failure, not a hang.
health() { inside "curl -sS --max-time $CTR_DEADLINE -o /dev/null -w '%{http_code}' --cacert /pki/store-ca.pem --cert /pki/client.pem --key /pki/client.key https://127.0.0.1:$PORT/v1/sys/health 2>&1"; }
# skipped LABEL — ConditionResult=no, inactive, no MainPID, not failed, no restarts.
skipped() {
	_s="$(show ConditionResult) $(show ActiveState) $(show MainPID) $(show NRestarts)"
	check "$1: ConditionResult=no, inactive, MainPID=0, NRestarts=0 (got '$_s')" "$(yes_if [ "$_s" = "no inactive 0 0" ])"
	_f=$(inside "systemctl --failed --no-legend --plain" | grep openbao || true)
	check "$1: not in systemctl --failed" "$(yes_if [ -z "$_f" ])" "$_f"
}

echo
echo "1. wanted by post-build.sh's link, under real preset-all (TC-756-11)"
# The link line exactly as post-build.sh has it, run with TARGET_DIR set to a
# tree holding the shipped unit. test/store-config-test.sh holds it to one line.
LN_LINE=$(grep -v '^[[:space:]]*#' "$POSTBUILD" | grep 'multi-user\.target\.wants/openbao\.service' | head -1)
check "TC-756-11 post-build.sh has the line that links openbao.service" "$(yes_if [ -n "$LN_LINE" ])"
WANTS=/tmp/preset-shipped/etc/systemd/system/multi-user.target.wants/openbao.service
inside "
set -e
for t in shipped control; do
	mkdir -p /tmp/preset-\$t/etc/systemd/system/multi-user.target.wants
	cp /overlay/etc/systemd/system/openbao.service /tmp/preset-\$t/etc/systemd/system/
done
printf '\n[Install]\nWantedBy=multi-user.target\n' >>/tmp/preset-control/etc/systemd/system/openbao.service
TARGET_DIR=/tmp/preset-shipped
$LN_LINE
systemctl --root=/tmp/preset-shipped preset-all >/dev/null 2>&1
systemctl --root=/tmp/preset-control preset-all >/dev/null 2>&1
" || check "TC-756-11 the link line and preset-all ran on both trees" 1
link=$(inside "readlink $WANTS 2>&1")
check "TC-756-11 after preset-all the wants link is still there (-> $link)" \
	"$(yes_if [ "$link" = /etc/systemd/system/openbao.service ])"
st=$(inside "systemctl --root=/tmp/preset-shipped is-enabled openbao.service 2>&1")
check "TC-756-11 the shipped unit with post-build.sh's link is enabled after preset-all (got '$st')" "$(yes_if [ "$st" = enabled ])"
st=$(inside "systemctl --root=/tmp/preset-control is-enabled openbao.service 2>&1")
check "TC-756-11 control: the unit with [Install] appended comes out enabled (got '$st')" "$(yes_if [ "$st" = enabled ])"

echo
echo "2. no role marker: skipped (TC-755-10)"
if ! { put_seal && put_ca && put_leaf && put_prov_leaf; }; then check "the credential sources are written" 1; fi
seal_is_oneshots "put_seal"
inside "rm -f $V/role.controlplane; systemctl start openbao.service" >/dev/null 2>&1
skipped "no role marker"

echo
echo "3. first boot: no leaf, or no CA, then the restart that starts it (TC-755-11)"
inside "touch $V/role.controlplane" >/dev/null
# TC-805-27: case A is the api's first boot. No CA-signed leaf exists yet, the
# provisioner's included; the api mints the provisioner's leaf, then the
# server's, and restarts the store (#805).
put_prov_then_server_leaf() { put_prov_leaf && put_leaf; }
for case in "A no leaf:rm -f $V/tls/openbao-server/leaf.pem $V/tls/openbao-server/leaf.key $V/tls/openbao-provisioner/leaf.pem $V/tls/openbao-provisioner/leaf.key:put_prov_then_server_leaf" \
	"B no store CA:rm -f $V/trust/store-ca.pem:put_ca"; do
	label=${case%%:*}; rest=${case#*:}; remove=${rest%%:*}; restore=${rest#*:}
	inside "$remove; rm -rf /run/rasputin-store-provision; systemctl start openbao.service" >/dev/null 2>&1
	skipped "case $label"
	pst="$(pshow ActiveState) $(pshow Result)"
	check "TC-805-27 case $label: the provisioner is inactive, not failed (got '$pst')" "$(yes_if [ "$pst" = "inactive success" ])"
	check "TC-805-27 case $label: there is no provisioner record" "$(yes_if [ -z "$(inside "ls -A /run/rasputin-store-provision 2>/dev/null")" ])"
	# F-805-28: no provisioner job was queued and failed. The whole journal so
	# far, so scenario 2's skipped store is held to it too. The console says
	# "Dependency failed for Secrets store provisioner."; the journal names the
	# unit before its description.
	pdep=$(inside "journalctl --no-pager -o cat" | grep -e 'Dependency failed for .*Secrets store provisioner' \
		-e "$PROV: Job $PROV/[a-z-]* failed with result 'dependency'" || true)
	check "TC-805-27 case $label (F-805-28): the journal has no 'Dependency failed for Secrets store provisioner' line and no $PROV job failed with result 'dependency'" \
		"$(yes_if [ -z "$pdep" ])" "$pdep"
	pprev=$(pshow InvocationID)
	$restore
	inside "systemctl restart openbao.service" >/dev/null 2>&1
	st="$(show ActiveState) $(show MainPID)"
	r=1; [ "${st%% *}" = active ] && [ "${st#* }" != 0 ] && r=0
	check "case $label: once written, systemctl restart leaves it active with a MainPID (got '$st')" "$r"
	if [ "$label" = "A no leaf" ]; then
		prov_settled "$pprev" || fails=$((fails + 1))
		prec=$(inside "cat $PRECORD")
		pid=$(pshow InvocationID)
		check "TC-805-27 first boot, the shipped empty provision.tsv: the record says unchanged, with this run's run_id" \
			"$(yes_if eval 'contains "outcome=unchanged" "$prec" && contains "run_id=$pid" "$prec" && [ ${#pid} = 32 ]')" "$prec"
		pline=$(inside "cat /run/store-provision-console")
		check "TC-805-27 first boot: a <6> rasputin-store-provision: outcome=unchanged changed=0 line" \
			"$(yes_if contains '<6>rasputin-store-provision: outcome=unchanged changed=0 ' "$pline")" "$pline"
		ready=$(show ActiveEnterTimestampMonotonic)
		pstart=$(pshow InactiveExitTimestampMonotonic)
		check "TC-805-27 first boot: the provisioner ran after the store's READY ($pstart >= $ready)" \
			"$(yes_if eval '[ "$pstart" -ge "$ready" ] && [ "$ready" -gt 0 ]')"
	fi
	inside "systemctl stop openbao.service" >/dev/null 2>&1
done

echo
echo "4. no seal key: fails, never skips (TC-755-12)"
inside "rm -f $V/openbao-seal/seal-key; systemctl reset-failed openbao.service 2>/dev/null; systemctl start openbao.service" >/dev/null 2>&1
wait_for "openbao.service is failed after the missing seal key" \
	'[ "$(systemctl show openbao.service -p ActiveState --value)" = failed ]' || fails=$((fails + 1))
st="$(show ConditionResult) $(show ActiveState) $(show Result)"
check "ConditionResult=yes, ActiveState=failed, Result=exit-code (got '$st')" "$(yes_if [ "$st" = "yes failed exit-code" ])"
# systemd 258.7 names the failed step, not the credential, at its default log
# level: "Failed at step CREDENTIALS spawning /usr/bin/bao" and status
# 243/CREDENTIALS.
journal=$(inside "journalctl -u openbao.service --no-pager -o cat" | grep 'Failed at step CREDENTIALS' | head -1)
check "the unit's journal says the credentials could not be set up" "$(yes_if [ -n "$journal" ])" \
	"$(inside "journalctl -u openbao.service --no-pager -o cat | tail -5" | tr '\n' '|')"
[ -n "$journal" ] && printf '         journal: %s\n' "$journal"
# systemd sets the credentials up when it spawns the unit's first process,
# which since geekdojo/geekdojo-brain#766 is the restore step, the first
# ExecStartPre=. So the failed spawn is that control process's, and systemd
# puts 243, the spawn step's own status, on it rather than on ExecMainStatus:
# bao was never executed (as for the provisioner's control process,
# TC-805-34).
c243=$(inside "journalctl -u openbao.service --no-pager -o cat" | grep -c 'Control process exited, code=exited, status=243/CREDENTIALS' || true)
check "the store's start failed with 243, systemd's CREDENTIALS status, on its first control process (got ${c243:-0} lines)" "$(yes_if [ "${c243:-0}" -ge 1 ])"
check "the failed spawn is the restore step's, the unit's first process" \
	"$(yes_if contains "spawning /usr/lib/rasputin/store-restore/rasputin-store-restore.sh" "$journal")" "$journal"
put_seal
inside "systemctl reset-failed openbao.service" >/dev/null 2>&1

echo
echo "5. the running store (TC-755-13 to TC-755-16, TC-755-18)"
inside "touch /tmp/before-start" >/dev/null
inside "systemctl start openbao.service" >/dev/null 2>&1
st=$(show ActiveState)
check "systemctl start returns with the store active: it waited for READY=1 (got '$st')" "$(yes_if [ "$st" = active ])"
PID=$(show MainPID)
status=$(inside "cat /proc/$PID/status")
field() { printf '%s\n' "$status" | awk -v f="$1:" '$1 == f { $1 = ""; sub(/^ /, ""); print }'; }
echo "  MainPID $PID"
for f in Uid Gid; do
	got=$(field $f)
	check "$f is $BAO_UID in all four slots (got '$got')" "$(yes_if [ "$got" = "$BAO_UID $BAO_UID $BAO_UID $BAO_UID" ])"
done
# systemd sets the groups with initgroups(3), which always lists the user's
# own primary group; nothing beyond it means no supplementary group.
check "no group beyond its own: Groups is exactly $BAO_GID (got '$(field Groups)')" "$(yes_if [ "$(field Groups)" = "$BAO_GID" ])"
for f in CapEff CapBnd CapAmb CapPrm CapInh; do
	check "$f is 0 (got '$(field $f)')" "$(yes_if [ "$(field $f)" = 0000000000000000 ])"
done
check "NoNewPrivs is 1 (got '$(field NoNewPrivs)')" "$(yes_if [ "$(field NoNewPrivs)" = 1 ])"
env_line=$(inside "tr '\\0' '\\n' </proc/$PID/environ | grep '^GOMEMLIMIT='")
check "GOMEMLIMIT=60MiB reaches the store (got '$env_line')" "$(yes_if [ "$env_line" = GOMEMLIMIT=60MiB ])"

core=$(inside "grep 'Max core file size' /proc/$PID/limits")
echo "  $core"
check "core limit is 0 soft and 0 hard (TC-755-14)" \
	"$(yes_if [ "$(printf '%s' "$core" | awk '{ print $5, $6 }')" = "0 0" ])" "$core"

echo "  -- credentials (TC-755-15)"
code=$(health)
# 200 since #804: scenario 3's first real start initialised the store itself.
check "sys/health over TLS with a client cert from the test CA answers 200: initialised by its own self-init in scenario 3 (got '$code')" \
	"$(yes_if [ "$code" = 200 ])"
n=$(as_uid "$BAO_UID" "wc -c <$CREDS/seal-key")
check "uid $BAO_UID reads the 32-byte seal-key (got '$n' bytes)" "$(yes_if [ "$n" = 32 ])"
for c in seal-key seal.hcl store-ca.pem server.pem server.key; do
	err=$(as_uid 65534 "cat $CREDS/$c >/dev/null" 2>&1) && r=1 || r=0
	check "uid 65534 is refused $c ($err)" "$r"
done
for s in openbao-seal/seal-key openbao-seal/seal.hcl trust/store-ca.pem tls/openbao-server/leaf.pem tls/openbao-server/leaf.key; do
	err=$(as_uid "$BAO_UID" "cat $V/$s >/dev/null" 2>&1) && r=1 || r=0
	check "uid $BAO_UID is refused the root source $s ($err)" "$r"
done

echo "  -- writes, inside the unit's mount namespace (TC-755-16)"
for d in "$V/openbao" "$V/openbao-audit"; do
	err=$(inside "nsenter -t $PID -m setpriv --reuid=$BAO_UID --regid=$BAO_GID --clear-groups touch $d/.store-unit-test" 2>&1) && r=0 || r=1
	check "uid $BAO_UID can create a file in $d" "$r" "$err"
done
for d in "$V" "$V/openbao-seal" "$V/tls" "$V/trust" /etc /usr /var/log /run; do
	err=$(inside "nsenter -t $PID -m setpriv --reuid=$BAO_UID --regid=$BAO_GID --clear-groups touch $d/.store-unit-test" 2>&1) && r=1 || r=0
	check "uid $BAO_UID cannot create a file in $d (${err##*: })" "$r"
done
err=$(inside "nsenter -t $PID -m touch $V/.store-unit-test-root" 2>&1) && r=1 || r=0
contains 'Read-only file system' "$err" || r=1
check "root in the namespace gets EROFS writing $V (${err##*: })" "$r" "$err"

echo "  -- memory (TC-755-18)"
CG=/sys/fs/cgroup$(show ControlGroup)
inside "sync; echo 3 >/proc/sys/vm/drop_caches" >/dev/null 2>&1 || check "drop_caches was written" 1
# Exercise the store so its pages fault back in, charged to its own cgroup.
for _ in 1 2 3 4 5 6 7 8 9 10; do health >/dev/null; done
st=$(show ActiveState)
check "still active after the binary's pages are charged to it (got '$st')" "$(yes_if [ "$st" = active ])"
oom=$(inside "awk '\$1 == \"oom_kill\" { print \$2 }' $CG/memory.events")
check "memory.events oom_kill is 0 (got '$oom')" "$(yes_if [ "$oom" = 0 ])"
mm=$(show MemoryMax)
check "MemoryMax is 134217728 (got '$mm')" "$(yes_if [ "$mm" = 134217728 ])"
for f in memory.max:134217728 memory.high:max memory.swap.max:0; do
	got=$(inside "cat $CG/${f%%:*}" 2>&1)
	check "${f%%:*} is ${f#*:} (got '$got')" "$(yes_if [ "$got" = "${f#*:}" ])"
done
adj=$(inside "cat /proc/$PID/oom_score_adj")
check "oom_score_adj is -999 (got '$adj')" "$(yes_if [ "$adj" = -999 ])"
echo "  memory.peak $(inside "cat $CG/memory.peak" 2>&1) bytes; memory.current $(inside "cat $CG/memory.current" 2>&1) bytes"

inside "systemctl stop openbao.service" >/dev/null 2>&1
gone=$(inside "test -e $CREDS && echo present || echo gone")
check "after stop, $CREDS is gone (got '$gone')" "$(yes_if [ "$gone" = gone ])"
newer=$(inside "find $V \\( -path $V/openbao -o -path $V/openbao-audit \\) -prune -o -newer /tmp/before-start -print")
check "nothing under $V outside its two directories changed while it ran" "$(yes_if [ -z "$newer" ])" "$newer"

echo
echo "6. repeated crashes: the start limit, then recovery (TC-755-17)"
inside "systemctl reset-failed openbao.service 2>/dev/null; systemctl start openbao.service" >/dev/null 2>&1
pid=$(show MainPID)
inside "kill -KILL $pid" >/dev/null 2>&1
if wait_for "after one SIGKILL, a new active MainPID other than $pid" \
	"[ \"\$(systemctl show openbao.service -p ActiveState --value)\" = active ] &&
	 p=\$(systemctl show openbao.service -p MainPID --value) && [ \"\$p\" != 0 ] && [ \"\$p\" != $pid ]"; then
	check "after one SIGKILL of $pid systemd restarts it: active, MainPID $(show MainPID)" 0
else
	check "after one SIGKILL of $pid systemd restarts it" 1 "$(show ActiveState) $(show MainPID)"
fi
# The crash loop is systemd's, not this test's: a seal fragment bao cannot
# parse makes bao exit non-zero on every start, and systemd's own restart
# delay drives each restart. Nothing below waits on the test reaching a step
# inside StartLimitIntervalSec.
inside "systemctl stop openbao.service; systemctl reset-failed openbao.service 2>/dev/null
printf 'seal \"static\" {\n  this is not hcl\n' >$V/openbao-seal/seal.hcl
systemctl start openbao.service" >/dev/null 2>&1
burst=$(show StartLimitBurst)
echo "  StartLimitBurst $burst, StartLimitIntervalUSec $(show StartLimitIntervalUSec), RestartUSec $(show RestartUSec): systemd's defaults"
wait_for "openbao.service is failed with no job, after bao rejects its seal config on every start" \
	'[ "$(systemctl show openbao.service -p ActiveState --value)" = failed ] && [ -z "$(systemctl show openbao.service -p Job --value)" ]' \
	|| fails=$((fails + 1))
st="$(show ActiveState) $(show Result)"
check "the unit is failed and Result keeps the crash's own value, exit-code (got '$st')" "$(yes_if [ "$st" = "failed exit-code" ])"
job=$(inside "systemctl list-jobs --no-legend --plain" | grep openbao || true)
check "no job is queued for it" "$(yes_if [ -z "$job" ])" "$job"
# NRestarts = StartLimitBurst holds here because reset-failed cleared the
# start-limit counter and the loop's first start is the `systemctl start`
# above, inside the window: that start plus StartLimitBurst-1 restarts use up
# the burst, and the restart after them is counted and refused. It is not a
# general rule: a store that ran longer than StartLimitIntervalSec before it
# crashed ends at StartLimitBurst+1 (verifier r1, F-755-08).
nr=$(show NRestarts)
check "NRestarts = StartLimitBurst = $burst, both from systemctl show (got '$nr')" "$(yes_if [ "$nr" = "$burst" ])"
line=$(inside "journalctl -u openbao.service --no-pager -o cat" | grep 'Start request repeated too quickly' | tail -1)
check "the journal says 'Start request repeated too quickly'" "$(yes_if [ -n "$line" ])"
code=$(health)
r=1; { contains 'Could not connect' "$code" || contains 'Connection refused' "$code"; } && r=0
check "sys/health on 127.0.0.1 gets connection refused (got '$code')" "$r"
put_seal
seal_is_oneshots "put_seal after the crash loop"
inside "systemctl reset-failed openbao.service && systemctl start openbao.service" >/dev/null 2>&1
st=$(show ActiveState)
check "with the valid seal.hcl back, reset-failed then start brings it back active (got '$st')" "$(yes_if [ "$st" = active ])"
inside "systemctl stop openbao.service" >/dev/null 2>&1

echo
echo "7. self-init on the shipped config, and the config at work (TC-804-18, TC-804-19, TC-756-12 to TC-756-17)"
# store_get PATH [CURL_ARG ...] — the HTTP code of PATH with the store-CA client
# certificate and no token. --max-time bounds the one call.
store_get() {
	_sg_path=$1; shift
	inside "curl -sS --max-time $CTR_DEADLINE -o /dev/null -w '%{http_code}' --cacert /pki/store-ca.pem --cert /pki/client.pem --key /pki/client.key $* https://127.0.0.1:$PORT/v1/$_sg_path 2>&1"
}
# health_is_200 — the wait condition, run inside the container.
# health_version — the version field of the running store's sys/health, read
# with jq as the api's capture reads it.
health_version() { inside "curl -s --max-time $CTR_DEADLINE --cacert /pki/store-ca.pem --cert /pki/client.pem --key /pki/client.key https://127.0.0.1:$PORT/v1/sys/health" | jq -r .version; }
HEALTH_200="[ \"\$(curl -s --max-time $CTR_DEADLINE -o /dev/null -w '%{http_code}' --cacert /pki/store-ca.pem --cert /pki/client.pem --key /pki/client.key https://127.0.0.1:$PORT/v1/sys/health)\" = 200 ]"
# only_loopback WHEN — the MainPID's LISTEN sockets, read from its own fds,
# are exactly 127.0.0.1:8200 (TC-756-12).
only_loopback() {
	_ol_pid=$(show MainPID)
	_ol=$(inside "cat /proc/$_ol_pid/net/tcp /proc/$_ol_pid/net/tcp6; ls -l /proc/$_ol_pid/fd" 2>/dev/null | bao_listeners)
	check "TC-756-12 $1: bao's only LISTEN socket is 127.0.0.1:$PORT (got '$(printf '%s' "$_ol" | tr '\n' ' ')')" \
		"$(yes_if [ "$_ol" = "127.0.0.1:$PORT" ])"
}
# cursor — the journal's current cursor, so a later read covers only what came
# after it.
cursor() { inside "journalctl --show-cursor -n 0 -o cat" | sed -n 's/^-- cursor: //p'; }
# journal_after CURSOR [ARG ...] — openbao.service's journal after CURSOR.
journal_after() { _ja=$1; shift; inside "journalctl -u openbao.service --after-cursor='$_ja' --no-pager -o cat $*"; }
# The line bao logs when it runs the self-init stanzas, its self-init marker
# (internal/command/server.go), measured with v2.7.1: absent on a start that
# finds the store initialised.
SELFINIT_LINE='beginning post-unseal configuration'
RECORD=/run/rasputin-store-init/outcome

# TEST HARNESS: the inspector. Its self-init stanza adds one policy and one
# role, for the test's own leaf, that can list and read what self-init made and
# nothing else. It reaches bao through a drop-in ExecStart that is the shipped
# line plus one -config, read from the unit so it cannot drift from it.
SHIPPED_EXEC=$(sed -n 's/^ExecStart=//p' "$UNIT")
cat >"$SCRATCH/test-inspector.json" <<'JSON'
{"initialize": [{"test-inspector": {"request": [
  {"policy-test-inspector": {"operation": "update", "path": "sys/policies/acl/test-inspector", "data": {"policy":
    "path \"sys/policies/acl\" { capabilities = [\"list\"] }\npath \"sys/policies/acl/*\" { capabilities = [\"read\"] }\npath \"sys/mounts\" { capabilities = [\"read\"] }\npath \"auth/cert/certs\" { capabilities = [\"list\"] }\npath \"sys/audit\" { capabilities = [\"read\", \"sudo\"] }\npath \"auth/token/accessors\" { capabilities = [\"list\", \"sudo\"] }\npath \"auth/token/lookup-accessor\" { capabilities = [\"update\"] }\n"}}},
  {"role-test-inspector": {"operation": "update", "path": "auth/cert/certs/store-unit-test-inspector", "data": {
    "certificate": {"eval_type": "string", "eval_source": "file", "path": "/run/credentials/openbao.service/store-ca.pem"},
    "allowed_common_names": ["store-unit-test-inspector"], "token_policies": ["test-inspector"], "token_no_default_policy": true}}}
]}}]}
JSON
# TEST HARNESS, run in the container: logs in and reads, keeping every token
# in a 0600 file and never printing one. `inspect` prints one "KEY<TAB>JSON"
# line per read; `write` writes the sentinel through the api's role and prints
# the status; `job ID` reads it back through the api's role with the header
# X-Rasputin-Job-Id: ID, as the api sends it under a job (#802).
cat >"$SCRATCH/store-read.sh" <<'READ'
#!/bin/sh
set -u
umask 077
U=https://127.0.0.1:8200/v1
c() { curl -s --max-time 30 --cacert /pki/store-ca.pem "$@"; }
# login LEAF ROLE FILE — the token, into FILE, and a header file beside it.
login() {
	c --cert "/pki/$1.pem" --key "/pki/$1.key" -X POST --data "{\"name\":\"$2\"}" "$U/auth/cert/login" \
		| sed -n 's/.*"client_token":"\([^"]*\)".*/\1/p' >"$3"
	[ -s "$3" ] || return 1
	printf 'X-Vault-Token: %s\n' "$(cat "$3")" >"$3.hdr"
}
get() { c --cert /pki/inspector.pem --key /pki/inspector.key -H "@/root/insp.token.hdr" "$@"; }
case "$1" in
	inspect)
		login inspector store-unit-test-inspector /root/insp.token || { echo "login	failed"; exit 1; }
		printf 'policies\t%s\n' "$(get "$U/sys/policies/acl?list=true")"
		printf 'roles\t%s\n' "$(get "$U/auth/cert/certs?list=true")"
		printf 'mounts\t%s\n' "$(get "$U/sys/mounts")"
		printf 'audit\t%s\n' "$(get "$U/sys/audit")"
		for p in rasputin-api rasputin-seal-rotate rasputin-provisioner rasputin-bindable; do
			printf 'policy-%s\t%s\n' "$p" "$(get "$U/sys/policies/acl/$p")"
		done
		for a in $(get "$U/auth/token/accessors?list=true" | sed 's/.*"keys":\[\([^]]*\)\].*/\1/; s/[",]/ /g'); do
			printf 'token\t%s\n' "$(get -X POST --data "{\"accessor\":\"$a\"}" "$U/auth/token/lookup-accessor")"
		done
		;;
	lookup)
		# lookup LEAF ROLE — the policies a login through ROLE with LEAF carries.
		login "$2" "$3" /root/lookup.token || { echo "login failed"; exit 1; }
		c --cert "/pki/$2.pem" --key "/pki/$2.key" -H "@/root/lookup.token.hdr" "$U/auth/token/lookup-self" \
			| sed -n 's/.*"policies":\(\[[^]]*\]\).*/\1/p'
		rm -f /root/lookup.token /root/lookup.token.hdr
		;;
	write)
		login api rasputin-api /root/api.token || { echo "login failed"; exit 1; }
		od -An -N12 -tx1 /dev/urandom | tr -d ' \n' >/root/sentinel
		c --cert /pki/api.pem --key /pki/api.key -H "@/root/api.token.hdr" -o /dev/null -w '%{http_code}' \
			-X POST --data "{\"data\":{\"v\":\"$(cat /root/sentinel)\"}}" "$U/rasputin-secrets/data/apps/store-unit-test"
		;;
	job)
		login api rasputin-api /root/api.token || { echo "login failed"; exit 1; }
		c --cert /pki/api.pem --key /pki/api.key -H "@/root/api.token.hdr" -H "X-Rasputin-Job-Id: $2" -o /dev/null -w '%{http_code}' \
			"$U/rasputin-secrets/data/apps/store-unit-test"
		;;
	read)
		# read — the sentinel's status through the api's role; the body, when
		# there is one, into /root/read.json (scenario 12).
		login api rasputin-api /root/api.token || { echo "login failed"; exit 1; }
		rm -f /root/read.json
		c --cert /pki/api.pem --key /pki/api.key -H "@/root/api.token.hdr" -o /root/read.json -w '%{http_code}' \
			"$U/rasputin-secrets/data/apps/store-unit-test"
		;;
esac
READ
docker cp "$SCRATCH/test-inspector.json" "$CID:/etc/rasputin/openbao/test-inspector.json" >/dev/null \
	&& docker cp "$SCRATCH/store-read.sh" "$CID:/root/store-read.sh" >/dev/null \
	|| { echo "FAILED: could not copy the inspector's config and reader into the container."; exit 1; }
# job_header LABEL ID — TC-802-16: a read through the api's role carrying
# X-Rasputin-Job-Id: ID writes the header into its request and response audit
# entries as request.headers["x-rasputin-job-id"] == [ID], in plain text, so
# self-init's init.json request configured the audited header. Only the lines
# holding ID leave the container; the audit HMACs every secret value in them.
job_header() {
	_code=$(inside "sh /root/store-read.sh job '$2'")
	check "TC-802-16 $1: the api's role reads the value with X-Rasputin-Job-Id: $2 (got '$_code')" "$(yes_if [ "$_code" = 200 ])"
	_types=$(inside "grep -F '$2' $V/openbao-audit/audit.log" \
		| jq -s -c --arg id "$2" '[.[] | select(.request.headers["x-rasputin-job-id"] == [$id]) | .type] | sort' 2>&1)
	check "TC-802-16 $1: the request and response audit entries carry request.headers[\"x-rasputin-job-id\"] == [\"$2\"] in plain text (got $_types)" \
		"$(yes_if [ "$_types" = '["request","response"]' ])"
}
# field KEY TEXT — the JSON of the line KEY in an inspect read.
field() { printf '%s\n' "$2" | awk -F'\t' -v k="$1" '$1 == k { sub(/^[^\t]*\t/, ""); print; exit }'; }
# view TEXT — what self-init made, one line per fact, for comparing two reads.
view() {
	printf 'policies %s\n' "$(field policies "$1" | jq -c '.data.keys | sort')"
	printf 'roles %s\n' "$(field roles "$1" | jq -c '.data.keys | sort')"
	printf 'mount %s\n' "$(field mounts "$1" | jq -c '.data["rasputin-secrets/"] | {type, options, accessor, uuid}')"
	printf 'audit %s\n' "$(field audit "$1" | jq -c '.data')"
	printf 'mounts %s\n' "$(field mounts "$1" | jq -c '.data | keys | sort')"
	for _p in rasputin-api rasputin-seal-rotate rasputin-provisioner rasputin-bindable; do
		printf 'policy-%s %s\n' "$_p" "$(field "policy-$_p" "$1" | jq -j '.data.policy' | openssl dgst -sha256 -r | cut -d' ' -f1)"
	done
	printf 'root-tokens %s\n' "$(printf '%s\n' "$1" | awk -F'\t' '$1 == "token" { sub(/^[^\t]*\t/, ""); print }' | jq -s '[.[] | select(.data.policies | index("root"))] | length')"
}

# An empty data directory, as on a fresh flash: what the earlier scenarios'
# first start initialised is cleared, with its audit log and this boot's
# record, and the inspector's drop-in goes in before the start that inits.
inside "systemctl stop openbao.service; systemctl reset-failed openbao.service 2>/dev/null
rm -rf $V/openbao/* $V/openbao/.[!.]* $V/openbao-audit/* /run/rasputin-store-init /run/store-init-console
printf '[Service]\nExecStart=\nExecStart=%s -config=/etc/rasputin/openbao/test-inspector.json\n' '$SHIPPED_EXEC' >/etc/systemd/system/openbao.service.d/harness-inspector.conf
systemctl daemon-reload" >/dev/null 2>&1
check "the data directory is empty before the start that initialises" "$(yes_if [ -z "$(inside "ls -A $V/openbao")" ])"
C7=$(cursor)
inside "systemctl start openbao.service" >/dev/null 2>&1
st=$(show ActiveState)
check "systemctl start returns with the store active on the shipped config (got '$st')" "$(yes_if [ "$st" = active ])"
wait_for "sys/health answers 200 after the store's own self-init" "$HEALTH_200" || fails=$((fails + 1))
only_loopback "after the start that initialised it"

echo "  -- self-init (TC-804-18)"
j7=$(journal_after "$C7")
check "TC-804-18 (1) bao ran its self-init stanzas on this start ('$SELFINIT_LINE')" "$(yes_if contains "$SELFINIT_LINE" "$j7")"
check "TC-804-18 (1) sys/health answers 200 (got '$(store_get sys/health)')" "$(yes_if [ "$(store_get sys/health)" = 200 ])"
ss=$(inside "curl -s --max-time $CTR_DEADLINE --cacert /pki/store-ca.pem --cert /pki/client.pem --key /pki/client.key https://127.0.0.1:$PORT/v1/sys/seal-status")
check "TC-804-18 (1) seal-status: initialized, unsealed, t=0 n=0 (got $(printf '%s' "$ss" | jq -c '{initialized, sealed, t, n}' 2>&1))" \
	"$(yes_if [ "$(printf '%s' "$ss" | jq -c '{initialized, sealed, t, n}' 2>/dev/null)" = '{"initialized":true,"sealed":false,"t":0,"n":0}' ])"
r7=$(inside "sh /root/store-read.sh inspect")
v7=$(view "$r7")
printf '%s\n' "$v7" | sed 's/^/         /'
check "TC-804-18 (2) zero tokens carry the root policy" "$(yes_if contains 'root-tokens 0' "$v7")" "$v7"
for p in rasputin-api rasputin-seal-rotate rasputin-provisioner rasputin-bindable; do
	want=$(openssl dgst -sha256 -r "$API_POLICY/$p.hcl" | cut -d' ' -f1)
	check "TC-804-18 TC-805-28 (2) policy $p's text in the store is the api tarball's, byte for byte" \
		"$(yes_if contains "policy-$p $want" "$v7")" "$v7"
done
check "TC-804-18 (2) rasputin-secrets/ is a kv mount, version 2" \
	"$(yes_if [ "$(field mounts "$r7" | jq -c '.data["rasputin-secrets/"] | [.type, .options.version]')" = '["kv","2"]' ])" "$(field mounts "$r7" | jq -c '.data["rasputin-secrets/"]' 2>&1)"
# TC-805-28: the three roles init.json makes since #805, plus the inspector,
# and the four policies (the #805 PINS of TC-804-18).
check "TC-804-18 TC-805-28 (2) the cert roles are exactly the three plus the inspector" \
	"$(yes_if contains 'roles ["rasputin-api","rasputin-provisioner","rasputin-seal-rotate","store-unit-test-inspector"]' "$v7")" "$v7"
check "TC-805-28 (2) the policies are the four, the inspector's, and the store's own default and root" \
	"$(yes_if contains 'policies ["default","rasputin-api","rasputin-bindable","rasputin-provisioner","rasputin-seal-rotate","root","test-inspector"]' "$v7")" "$v7"
check "TC-804-18 (2) exactly one audit device, a file at /var/lib/rasputin/openbao-audit/audit.log" \
	"$(yes_if [ "$(field audit "$r7" | jq -c '.data | [length, (.[] | .type, .options.file_path)]')" = '[1,"file","/var/lib/rasputin/openbao-audit/audit.log"]' ])" "$(field audit "$r7" | jq -c .data 2>&1)"
code=$(inside "sh /root/store-read.sh write")
check "TC-804-18 (3) the api's role writes a value under rasputin-secrets/data/apps/ (got '$code')" "$(yes_if [ "$code" = 200 ])"
audit=$(inside "stat -c '%a %u:%g' $V/openbao-audit/audit.log; grep -c 'hmac-sha256:' $V/openbao-audit/audit.log; grep -c -F -f /root/sentinel $V/openbao-audit/audit.log; grep -c '\"path\":\"sys/init\"' $V/openbao-audit/audit.log")
set -- $audit
check "TC-804-18 (3) audit.log is 0600 $BAO_UID:$BAO_GID (got '${1:-} ${2:-}')" "$(yes_if [ "${1:-} ${2:-}" = "600 $BAO_UID:$BAO_GID" ])"
check "TC-804-18 (3) audit.log holds hmac-sha256: values (got ${3:-0} lines)" "$(yes_if [ "${3:-0}" -gt 0 ])"
check "TC-804-18 (3) audit.log does not hold the written value (got ${4:-?} lines)" "$(yes_if [ "${4:-}" = 0 ])"
check "TC-804-18 (1) no request ever reached sys/init (got ${5:-?} audit lines)" "$(yes_if [ "${5:-}" = 0 ])"
echo "  -- the audited job-id header, from init.json (TC-802-16)"
job_header "on the start that initialised" "store-unit-job-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
rec7=$(inside "stat -c '%a %u' $RECORD; cat $RECORD")
boot=$(inside "cat /proc/sys/kernel/random/boot_id")
r=1
[ "$(printf '%s\n' "$rec7" | sed -n '1p;2p;3p' | cut -d= -f1 | tr '\n' ' ')" = "600 0 outcome boot_id " ] \
	&& contains "outcome=initialised
boot_id=$boot
reason=" "$rec7" && [ "$(printf '%s\n' "$rec7" | wc -l | tr -d ' ')" = 4 ] && r=0
check "TC-804-18 (4) the record is 0600 root and exactly outcome=initialised, this boot's boot_id and a reason" "$r" "$rec7"
line=$(journal_after "$C7" -p info..info | grep 'rasputin-store-init: outcome=initialised' || true)
check "TC-804-18 (4) the journal has one info-level rasputin-store-init: outcome=initialised line" \
	"$(yes_if [ "$(printf '%s\n' "$line" | grep -c 'outcome=initialised')" = 1 ])" "$line"
[ -n "$line" ] && printf '         journal: %s\n' "$line"
check "TC-804-18 (4) the console line is the journal's, with its <6>" \
	"$(yes_if [ "$(inside "cat /run/store-init-console")" = "<6>$line" ])" "console: $(inside "cat /run/store-init-console")"
REC7_SHA=$(inside "sha256sum $RECORD" | cut -d' ' -f1)

echo "  -- the handshake (TC-756-13)"
# tls_refused LABEL REASON CURL_ARGS — refused inside TLS: the store's own
# "http: TLS handshake error" line names REASON, curl gets no HTTP status, and
# nothing reports a connection refusal. Under TLS 1.3 a client's words for the
# refusal depend on timing (F-756-16); the store's line does not.
# test/lib/tls-refusal.sh follows the journal from a cursor taken before the
# attempt, and `timeout` in the container is its deadline.
tls_refused() {
	_tr=$(inside "timeout $CTR_DEADLINE sh /root/tls-refusal.sh openbao.service '$2' curl -sS --max-time $CTR_DEADLINE -o /dev/null -w 'code=%{http_code}' --cacert /pki/store-ca.pem $3 https://127.0.0.1:$PORT/v1/sys/health")
	_tr_client=$(printf '%s\n' "$_tr" | sed -n 's/^client: //p')
	_tr_line=$(printf '%s\n' "$_tr" | sed -n 's/^journal: //p')
	_st=1
	if contains 'code=000|' "$_tr_client" && ! contains 'onnection refused' "$_tr_client" && ! contains 'Could not connect' "$_tr_client"; then
		case "$_tr_line" in *"http: TLS handshake error from 127.0.0.1:"*"$2"*) _st=0 ;; esac
	fi
	check "TC-756-13 $1 is refused in the TLS handshake (store: ${_tr_line:-none}; curl: ${_tr_client:-none})" "$_st" "$_tr"
}
code=$(store_get sys/health)
r=1
case "$code" in [1-5][0-9][0-9]) r=0 ;; esac
check "TC-756-13 control: a store-CA clientAuth certificate gets an HTTP status from sys/health (got '$code')" "$r"
tls_refused "no client certificate" "provide a certificate" ""
tls_refused "a clientAuth certificate from a foreign CA" "certificate signed by unknown authority" "--cert /pki/foreign.pem --key /pki/foreign.key"
tls_refused "a store-CA certificate with serverAuth only" "certificate specifies an incompatible key usage" "--cert /pki/server.pem --key /pki/server.key"

echo "  -- the unauthenticated rekey and generate-root endpoints (TC-756-14)"
# These codes cannot tell disable_unauthed_* from their defaults; the options'
# placement is held by test/store-config-test.sh (TC-756-02, TC-756-06).
for e in sys/rekey/init:405 sys/rekey-recovery-key/init:404 sys/generate-root/attempt:405; do
	code=$(store_get "${e%:*}")
	check "TC-756-14 GET ${e%:*} with a client certificate and no token answers ${e##*:} (got '$code')" "$(yes_if [ "$code" = "${e##*:}" ])"
done

echo "  -- a restart: no self-init, nothing changed, unsealed from the fragment (TC-804-19, TC-756-15)"
C8=$(cursor)
inside "systemctl restart openbao.service" >/dev/null 2>&1
st=$(show ActiveState)
check "TC-756-15 systemctl restart returns with the store active (got '$st')" "$(yes_if [ "$st" = active ])"
wait_for "sys/health answers 200 after the restart, with no unseal call" "$HEALTH_200" || fails=$((fails + 1))
check "TC-756-15 after the restart sys/health answers 200 with no unseal call (got '$(store_get sys/health)')" \
	"$(yes_if [ "$(store_get sys/health)" = 200 ])"
only_loopback "after systemctl restart, with sys/health answering 200 again"
seal_is_oneshots "TC-756-15 after self-init and restart"
j8=$(journal_after "$C8")
check "TC-804-19 the restart ran no self-init (no '$SELFINIT_LINE')" "$(yes_if not_contains "$SELFINIT_LINE" "$j8")"
check "TC-804-19 the restart printed no rasputin-store-init: line" "$(yes_if not_contains 'rasputin-store-init:' "$j8")"
# The outcome hooks run as root outside the sandbox (`+`); none of the unit's
# processes may fail its execution setup (credentials included) on the start
# that initialised or on the restart, or test/boot-smoke.sh's generic
# "Failed at step" check would fail the image.
check "TC-804-18 no process of the unit failed its execution setup on the start that initialised or the restart" \
	"$(yes_if not_contains 'Failed at step' "$j7$j8")" "$(printf '%s\n%s\n' "$j7" "$j8" | grep 'Failed' | head -3)"
check "TC-804-19 the record is unchanged, byte for byte" "$(yes_if [ "$(inside "sha256sum $RECORD" | cut -d' ' -f1)" = "$REC7_SHA" ])"
# TC-805-28: the comparison carries the three roles and four policies.
r8=$(inside "sh /root/store-read.sh inspect")
v8=$(view "$r8")
check "TC-804-19 policies, roles, the mount, the audit device and the policy text are identical, with still zero root tokens" \
	"$(yes_if [ "$v8" = "$v7" ])" "before: $(printf '%s' "$v7" | tr '\n' '|') after: $(printf '%s' "$v8" | tr '\n' '|')"
job_header "after the restart, with no self-init" "store-unit-job-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"

echo "  -- the journal (TC-756-16, TC-756-17)"
journal=$(inside "journalctl -u openbao.service --no-pager -o cat")
banner=$(printf '%s\n' "$journal" | grep -m1 'Log Level: info' | sed 's/^[[:space:]]*//')
check "TC-756-16 the journal has bao's 'Log Level: info' banner line" "$(yes_if [ -n "$banner" ])"
[ -n "$banner" ] && printf '         journal: %s\n' "$banner"
noisy=$(printf '%s\n' "$journal" | grep -c -e '\[TRACE\]' -e '\[DEBUG\]')
check "TC-756-16 no [TRACE] or [DEBUG] line in the journal (got $noisy)" "$(yes_if [ "$noisy" = 0 ])"
# The search runs inside the container, so no value is printed or passed on
# a command line: each value is a file, read by grep -f. Counts only. Since
# #804 self-init leaves no root token and no recovery share, so the tokens
# searched for are the two this test logged in with, and the token SHAPES are
# searched too: Vault's hv[sbr]. form, which the test plan names, and
# OpenBao's own [sbr]. form, which is what v2.7.1 issues (measured: s. plus
# 24 characters).
cat >"$SCRATCH/scan-journal.sh" <<'SCAN'
#!/bin/sh
set -u
umask 077
N=/root/needles
rm -rf "$N" /root/journal.txt /root/control.txt
mkdir "$N"
od -An -v -tx1 /pki/seal-key | tr -d ' \n' >"$N/seal-hex"
base64 -w0 /pki/seal-key >"$N/seal-b64"
i=0
grep -v '^-----' /pki/server.key | while IFS= read -r l; do
	i=$((i + 1))
	printf '%s\n' "$l" >"$N/server-key-$i"
done
cp /root/api.token "$N/api-token"
cp /root/insp.token "$N/inspector-token"
cp /root/sentinel "$N/kv-value"
journalctl --no-pager -o cat >/root/journal.txt
cat "$N"/* >/root/control.txt
n=0 empty=0 hits=0 control=0
for f in "$N"/*; do
	n=$((n + 1))
	[ -s "$f" ] || { empty=$((empty + 1)); continue; }
	grep -q -F -f "$f" /root/journal.txt && hits=$((hits + 1))
	grep -q -F -f "$f" /root/control.txt && control=$((control + 1))
done
V='hv[sbr]\.[A-Za-z0-9]{24}'
B='(^|[^A-Za-z0-9])[sbr]\.[A-Za-z0-9]{24}([^A-Za-z0-9]|$)'
vj=$(grep -c -E "$V" /root/journal.txt); bj=$(grep -c -E "$B" /root/journal.txt); bc=$(grep -c -E "$B" /root/control.txt)
rm -rf "$N" /root/journal.txt /root/control.txt
echo "needles=$n empty=$empty journal=$hits control=$control vault_shape=$vj bao_shape=$bj bao_shape_control=$bc"
SCAN
docker cp "$SCRATCH/scan-journal.sh" "$CID:/root/scan-journal.sh" >/dev/null || check "the journal scan is copied into the container" 1
scan=$(inside "sh /root/scan-journal.sh")
echo "  scan: $scan"
n=$(printf '%s' "$scan" | sed -n 's/.*needles=\([0-9]*\).*/\1/p')
r=1; [ "${n:-0}" -ge 6 ] && contains ' empty=0 ' "$scan" && r=0
check "TC-756-17 the search has the seal key (hex, base64), server.key's lines, both tokens and the written value, none empty" \
	"$r" "$scan"
r=1; [ -n "$n" ] && contains " control=$n " "$scan" && r=0
check "TC-756-17 positive control: the same search finds every value in a file that holds them" "$r" "$scan"
check "TC-756-17 none of them is in the journal, every unit and the kernel's included" "$(yes_if contains ' journal=0 ' "$scan")" "$scan"
check "TC-804-18 positive control: the OpenBao token shape matches the tokens themselves" \
	"$(yes_if eval 'printf "%s" "$scan" | grep -q "bao_shape_control=[1-9]"')" "$scan"
check "TC-804-18 no token shape (hv[sbr]. or OpenBao's [sbr].) in the journal" \
	"$(yes_if contains 'vault_shape=0 bao_shape=0 ' "$scan")" "$scan"
inside "systemctl stop openbao.service" >/dev/null 2>&1

echo
echo "8. a forced failed self-init: one policy file missing (TC-804-20)"
# TEST HARNESS: the shipped ExecStart again (no inspector), an empty data
# directory, and rasputin-api.hcl moved away, as an image whose tarball lacked
# it would be (the post-build guard refuses to build that image).
inside "systemctl reset-failed openbao.service 2>/dev/null
rm -f /etc/systemd/system/openbao.service.d/harness-inspector.conf
rm -rf $V/openbao/* $V/openbao/.[!.]* $V/openbao-audit/* /run/rasputin-store-init /run/store-init-console
mv /usr/share/rasputin/openbao-policy/rasputin-api.hcl /root/rasputin-api.hcl.moved
systemctl daemon-reload" >/dev/null 2>&1
C9=$(cursor)
inside "systemctl start openbao.service" >/dev/null 2>&1
wait_for "openbao.service is failed with no job, after a failed self-init and the starts that refuse to unseal" \
	'[ "$(systemctl show openbao.service -p ActiveState --value)" = failed ] && [ -z "$(systemctl show openbao.service -p Job --value)" ]' \
	|| fails=$((fails + 1))
j9=$(journal_after "$C9")
err=$(printf '%s\n' "$j9" | grep -m1 '\[ERROR\] failed to initialize' || true)
check "TC-804-20 (1) bao logs 'failed to initialize' at ERROR" "$(yes_if [ -n "$err" ])" "$(printf '%s' "$j9" | tail -5 | tr '\n' '|')"
[ -n "$err" ] && printf '         journal: %s\n' "$(printf '%s' "$err" | cut -c1-160)"
fl=$(journal_after "$C9" -p err..err | grep 'rasputin-store-init: outcome=failed' || true)
check "TC-804-20 (2) one error-level rasputin-store-init: outcome=failed line" \
	"$(yes_if [ "$(printf '%s\n' "$fl" | grep -c 'outcome=failed')" = 1 ])" "$fl"
[ -n "$fl" ] && printf '         journal: %s\n' "$fl"
rec9=$(inside "cat $RECORD")
check "TC-804-20 (2) the record says outcome=failed, naming the service result" \
	"$(yes_if eval 'contains "outcome=failed" "$rec9" && contains "(service result exit-code, status " "$rec9" && contains "it will refuse to unseal until its data directory is cleared." "$rec9"')" "$rec9"
check "TC-804-20 (2) the console line is the journal's, with its <3>" \
	"$(yes_if [ "$(inside "cat /run/store-init-console")" = "<3>$fl" ])" "console: $(inside "cat /run/store-init-console")"
check "TC-804-20 (3) later starts refuse to unseal ('self-initialization failed: refusing to unseal')" \
	"$(yes_if contains 'self-initialization failed: refusing to unseal' "$j9")"
st="$(show ActiveState) $(show Result) $(show NRestarts)"
check "TC-804-20 (3) the unit ends failed at its start limit (ActiveState Result NRestarts: '$st')" \
	"$(yes_if contains "failed exit-code $(show StartLimitBurst)" "$st")"
check "TC-804-20 (3) the journal says 'Start request repeated too quickly'" \
	"$(yes_if contains 'Start request repeated too quickly' "$(inside "journalctl -u openbao.service --after-cursor='$C9' --no-pager -o cat")")"
check "TC-804-20 (4) the record still says failed, from the first start only" \
	"$(yes_if eval 'contains "outcome=failed" "$(inside "cat $RECORD")" && [ "$(printf "%s\n" "$j9" | grep -c "rasputin-store-init: outcome=")" = 1 ]')" "$(inside "cat $RECORD")"
tokens=$(inside "journalctl --no-pager -o cat | grep -c -E 'hv[sbr]\.[A-Za-z0-9]{24}|(^|[^A-Za-z0-9])[sbr]\.[A-Za-z0-9]{24}([^A-Za-z0-9]|\$)'")
check "TC-804-20 (5) no token shape in the journal (got ${tokens:-?} lines)" "$(yes_if [ "${tokens:-}" = 0 ])"
inside "systemctl stop openbao.service; systemctl reset-failed openbao.service 2>/dev/null
mv /root/rasputin-api.hcl.moved /usr/share/rasputin/openbao-policy/rasputin-api.hcl" >/dev/null 2>&1

echo
echo "9. a seal-key rotation through the shipped unit (TC-830-26)"
# The api's job does these steps (geekdojo/geekdojo-brain#830); here each is
# done by hand, so what is under test is what systemd and bao do with the
# shipped unit, init.json and policy: the rotation/ directory credential, the
# Staged and Verify fragments, and the rotation role. The fragments are
# written byte for byte as the api's renderer writes them.
# Key A's id: the oneshot's, from the copy of its fragment kept in /pki.
FRAG_A_ID=$(inside "grep -o 'rasputin-[0-9a-f-]*' /pki/seal.hcl | head -n 1")
check "TC-830-26 the oneshot's key id is read from its fragment (got '$FRAG_A_ID')" "$(yes_if [ -n "$FRAG_A_ID" ])"
KEY_B=rasputin-bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
ROTDIR=$V/openbao-seal/rotation
cat >"$SCRATCH/rotate-store.sh" <<'ROT'
#!/bin/sh
# TEST HARNESS: the rotation job's two store calls, as rasputin-seal-rotate.
# The token stays in a 0600 file and is never printed. Prints the re-wrap's
# status and its body's length.
set -u
umask 077
U=https://127.0.0.1:8200/v1
c() { curl -s --max-time 30 --cacert /pki/store-ca.pem --cert /pki/rotate.pem --key /pki/rotate.key "$@"; }
c -X POST --data '{"name":"rasputin-seal-rotate"}' "$U/auth/cert/login" \
	| sed -n 's/.*"client_token":"\([^"]*\)".*/\1/p' >/root/rotate.token
[ -s /root/rotate.token ] || { echo "login failed"; exit 1; }
printf 'X-Vault-Token: %s\n' "$(cat /root/rotate.token)" >/root/rotate.token.hdr
code=$(c -H @/root/rotate.token.hdr -o /root/rotate.body -w '%{http_code}' -X POST "$U/sys/rotate/root")
echo "$code $(wc -c </root/rotate.body | tr -d ' ')"
ROT
docker cp "$SCRATCH/rotate-store.sh" "$CID:/root/rotate-store.sh" >/dev/null || check "the rotation helper is copied into the container" 1
# creds — the store's credential names, sorted, on one line.
creds() { inside "ls $CREDS 2>/dev/null | sort | tr '\n' ' '"; }
# opens LABEL — after a restart, active and sys/health 200.
opens() {
	inside "systemctl reset-failed openbao.service 2>/dev/null; systemctl restart openbao.service" >/dev/null 2>&1
	check "TC-830-26 $1: systemctl restart leaves the store active (got '$(show ActiveState)')" "$(yes_if [ "$(show ActiveState)" = active ])"
	wait_for "sys/health answers 200 $1" "$HEALTH_200" || fails=$((fails + 1))
}
# A fresh store from the oneshot's own key A, initialised by the shipped
# init.json (which creates the rasputin-seal-rotate role), as on a node.
inside "systemctl stop openbao.service; systemctl reset-failed openbao.service 2>/dev/null
rm -rf $V/openbao/* $V/openbao/.[!.]* $V/openbao-audit/* /run/rasputin-store-init /run/store-init-console $ROTDIR/*
systemctl daemon-reload" >/dev/null 2>&1
put_seal
check "TC-830-26 tmpfiles made $ROTDIR at 0700 root (got '$(inside "stat -c '%a %U %G' $ROTDIR")')" \
	"$(yes_if [ "$(inside "stat -c '%a %U %G' $ROTDIR")" = "700 root root" ])"
C10=$(cursor)
opens "with rotation/ empty"
check "TC-830-26 with rotation/ empty the store gets no extra credential (got '$(creds)')" \
	"$(yes_if [ "$(creds)" = "seal-key seal.hcl server.key server.pem store-ca.pem " ])"

inside "head -c 32 /dev/urandom >$ROTDIR/$KEY_B && chmod 0600 $ROTDIR/$KEY_B && cp $ROTDIR/$KEY_B /root/key-b
printf 'seal \"static\" {\n  current_key_id  = \"%s\"\n  current_key     = \"file://$CREDS/seal-rotation_%s\"\n  previous_key_id = \"%s\"\n  previous_key    = \"file://$CREDS/seal-key\"\n}\n' $KEY_B $KEY_B $FRAG_A_ID >$V/openbao-seal/seal.hcl
chmod 0600 $V/openbao-seal/seal.hcl" || check "TC-830-26 key B and the Staged fragment are written" 1
opens "on the Staged fragment"
check "TC-830-26 the staged key reaches the store as seal-rotation_$KEY_B (got '$(creds)')" \
	"$(yes_if [ "$(creds)" = "seal-key seal-rotation_$KEY_B seal.hcl server.key server.pem store-ca.pem " ])"

rw=$(inside "sh /root/rotate-store.sh")
check "TC-830-26 sys/rotate/root as rasputin-seal-rotate answers 204 with an empty body (got '$rw')" "$(yes_if [ "$rw" = "204 0" ])"

inside "printf 'seal \"static\" {\n  current_key_id = \"%s\"\n  current_key    = \"file://$CREDS/seal-rotation_%s\"\n}\n' $KEY_B $KEY_B >$V/openbao-seal/seal.hcl" \
	|| check "TC-830-26 the Verify fragment is written" 1
opens "on the Verify fragment, the new key alone"

inside "install -m 0600 $ROTDIR/$KEY_B $V/openbao-seal/seal-key
printf 'seal \"static\" {\n  current_key_id = \"%s\"\n  current_key    = \"%s\"\n}\n' $KEY_B file://$CREDS/seal-key >$V/openbao-seal/seal.hcl" \
	|| check "TC-830-26 seal-key = B and the Clean fragment are written" 1
opens "on the Clean fragment with seal-key = B"
inside "rm -f $ROTDIR/*" >/dev/null 2>&1
opens "on the Clean fragment with rotation/ emptied"
check "TC-830-26 settled: no seal-rotation credential (got '$(creds)')" \
	"$(yes_if [ "$(creds)" = "seal-key seal.hcl server.key server.pem store-ca.pem " ])"
j10=$(journal_after "$C10")
check "TC-830-26 no process of the unit failed its execution setup during the rotation" \
	"$(yes_if not_contains 'Failed at step' "$j10")" "$(printf '%s\n' "$j10" | grep 'Failed' | head -3)"

# rotation/ missing: the directory source is required, so the unit fails at
# CREDENTIALS rather than starting without it (fail closed); tmpfiles makes it
# again on every boot.
C11=$(cursor)
inside "systemctl stop openbao.service; rmdir $ROTDIR; systemctl reset-failed openbao.service 2>/dev/null; systemctl start openbao.service" >/dev/null 2>&1
wait_for "openbao.service is failed with rotation/ missing" \
	'[ "$(systemctl show openbao.service -p ActiveState --value)" = failed ]' || fails=$((fails + 1))
check "TC-830-26 with rotation/ missing the unit fails at the CREDENTIALS step" \
	"$(yes_if contains 'Failed at step CREDENTIALS' "$(journal_after "$C11")")" "$(journal_after "$C11" | tail -3 | tr '\n' '|')"
inside "systemctl reset-failed openbao.service 2>/dev/null; systemd-tmpfiles --create /usr/lib/tmpfiles.d/rasputin.conf >/dev/null 2>&1; true" >/dev/null 2>&1

# The journal holds neither key (hex, base64), the rotation token, nor any
# token shape. Searched inside the container, values in files; a positive
# control proves the search finds each needle where it is.
cat >"$SCRATCH/scan-rotation.sh" <<'SCAN'
#!/bin/sh
set -u
umask 077
N=/root/rot-needles
rm -rf "$N"; mkdir "$N"
for k in /pki/seal-key /root/key-b; do
	b=$(basename "$k")
	od -An -v -tx1 "$k" | tr -d ' \n' >"$N/$b-hex"
	base64 -w0 "$k" >"$N/$b-b64"
done
cp /root/rotate.token "$N/rotate-token"
journalctl --no-pager -o cat >/root/rot-journal.txt
cat "$N"/* >/root/rot-control.txt
n=0 empty=0 hits=0 control=0
for f in "$N"/*; do
	n=$((n + 1))
	[ -s "$f" ] || { empty=$((empty + 1)); continue; }
	grep -q -F -f "$f" /root/rot-journal.txt && hits=$((hits + 1))
	grep -q -F -f "$f" /root/rot-control.txt && control=$((control + 1))
done
B='(^|[^A-Za-z0-9])(hv)?[sbr]\.[A-Za-z0-9]{24}([^A-Za-z0-9]|$)'
bj=$(grep -c -E "$B" /root/rot-journal.txt)
rm -rf "$N" /root/rot-journal.txt /root/rot-control.txt /root/key-b /root/rotate.token /root/rotate.token.hdr
echo "needles=$n empty=$empty journal=$hits control=$control token_shape=$bj"
SCAN
docker cp "$SCRATCH/scan-rotation.sh" "$CID:/root/scan-rotation.sh" >/dev/null || check "the rotation scan is copied into the container" 1
scan=$(inside "sh /root/scan-rotation.sh")
echo "  scan: $scan"
check "TC-830-26 the search has both keys (hex, base64) and the rotation token, none empty" \
	"$(yes_if contains 'needles=5 empty=0 ' "$scan")" "$scan"
check "TC-830-26 positive control: the search finds every needle where it is" "$(yes_if contains ' control=5 ' "$scan")" "$scan"
check "TC-830-26 no key byte or token in the journal" \
	"$(yes_if eval 'contains " journal=0 " "$scan" && contains " token_shape=0" "$scan"')" "$scan"

echo
echo "10. the store provisioner (TC-805-27, TC-805-29 to TC-805-34, TC-805-41)"
pjournal_after() { inside "journalctl -u $PROV --after-cursor='$1' --no-pager -o cat"; }
pfield() { printf '%s\n' "$2" | sed -n "s/^$1=//p"; }
# set_tsv TEXT — TEST HARNESS: a labelled provision.tsv (printf %b), installed
# where the image's sits.
set_tsv() { inside "printf '%b' '# TEST HARNESS (store-unit-functional.sh)\n$1' >/etc/rasputin/openbao/provision.tsv"; }
# api_restart — the store's and the api's restart as a node does it: the stub
# api's start pulls in the store, whose start starts the provisioner, and the
# api waits for it (Before=). systemctl start returns once the api has started.
api_restart() { inside "systemctl stop rasputin-api.service openbao.service; systemctl reset-failed openbao.service $PROV 2>/dev/null; systemctl start rasputin-api.service" >/dev/null 2>&1; }
audit_lines() { inside "wc -l <$V/openbao-audit/audit.log" | tr -d ' '; }
# audit_after N — the audit log's entries after its first N lines.
audit_after() { inside "tail -n +$(( $1 + 1 )) $V/openbao-audit/audit.log"; }
# unseal_mono RUN_ID — the store run's "unsealed with stored key" line's
# monotonic time, from the journal.
unseal_mono() { inside "journalctl _SYSTEMD_INVOCATION_ID=$1 -o json --no-pager" | jq -r 'select((.MESSAGE | tostring) | test("unsealed with stored key")) | .__MONOTONIC_TIMESTAMP' | head -1; }
# TEST HARNESS: a stub rasputin-api.service with the real one's Wants= on the
# store, so the provisioner's Before= has something to hold.
inside "cat >/etc/systemd/system/rasputin-api.service <<'UNIT'
[Unit]
Description=TEST HARNESS stub rasputin-api
Wants=openbao.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
UNIT
systemctl daemon-reload" || check "the stub api is installed" 1

echo "  -- a one-item first boot: the replayed success line (TC-805-27)"
inside "systemctl stop openbao.service; systemctl reset-failed openbao.service $PROV 2>/dev/null
rm -rf $V/openbao/* $V/openbao/.[!.]* $V/openbao-audit/* /run/rasputin-store-init /run/rasputin-store-provision /run/store-provision-console" >/dev/null 2>&1
# Scenario 9 settled the seal on its rotated key B. This first boot starts
# from the test's key A and its fragment, which TC-805-32 restores later.
put_seal || check "the test's seal key and fragment are restored" 1
set_tsv 'mount\trasputin-rel-fb\n'
pprev=$(pshow InvocationID)
inside "systemctl start openbao.service" >/dev/null 2>&1
prov_settled "$pprev" || fails=$((fails + 1))
prec=$(inside "cat $PRECORD")
pline=$(inside "cat /run/store-provision-console")
check "TC-805-27 a one-item first boot: the record is applied" "$(yes_if contains 'outcome=applied' "$prec")" "$prec"
check "TC-805-27 a one-item first boot: the <6> line says applied changed=1" \
	"$(yes_if contains '<6>rasputin-store-provision: outcome=applied changed=1 ' "$pline")" "$pline"
sid=$(show InvocationID)
um=$(unseal_mono "$sid"); ready=$(show ActiveEnterTimestampMonotonic); pstart=$(pshow InactiveExitTimestampMonotonic)
check "TC-805-27 self-init logged 'unsealed with stored key' before READY, and the provisioner started after READY ($um < $ready <= $pstart)" \
	"$(yes_if eval '[ -n "$um" ] && [ "$um" -lt "$ready" ] && [ "$ready" -le "$pstart" ]')"
pj=$(inside "journalctl -u $PROV _SYSTEMD_INVOCATION_ID=$(pshow InvocationID) --no-pager -o cat")
check "TC-805-27 no provisioner line names the bound" "$(yes_if not_contains 'logged no unseal result within' "$pj$prec")" "$pj"

echo "  -- N to N+1, no root token (TC-805-29)"
# Config N: an emptied data directory, the shipped empty provision.tsv, the
# inspector (scenario 7's drop-in) to read what the store holds.
inside "systemctl stop openbao.service; systemctl reset-failed openbao.service $PROV 2>/dev/null
rm -rf $V/openbao/* $V/openbao/.[!.]* $V/openbao-audit/* /run/rasputin-store-init /run/rasputin-store-provision /run/store-provision-console
install -m 0644 /overlay/etc/rasputin/openbao/provision.tsv /etc/rasputin/openbao/provision.tsv
printf '[Service]\nExecStart=\nExecStart=%s -config=/etc/rasputin/openbao/test-inspector.json\n' '$SHIPPED_EXEC' >/etc/systemd/system/openbao.service.d/harness-inspector.conf
systemctl daemon-reload" >/dev/null 2>&1
api_restart
wait_for "sys/health answers 200 on config N" "$HEALTH_200" || fails=$((fails + 1))
check "TC-805-29 config N: the provisioner recorded unchanged" "$(yes_if contains 'outcome=unchanged' "$(inside "cat $PRECORD")")" "$(inside "cat $PRECORD")"
vN=$(view "$(inside "sh /root/store-read.sh inspect")")
check "TC-805-29 config N: zero tokens carry root" "$(yes_if contains 'root-tokens 0' "$vN")" "$vN"
# N+1: one mount and one role bound to rasputin-bindable.
set_tsv 'mount\trasputin-rel-n1\nrole\trasputin-rel-n1\trasputin-bindable\n'
A0=$(audit_lines)
api_restart
pid1=$(pshow InvocationID); sid=$(show InvocationID)
prec=$(inside "cat $PRECORD")
pline=$(inside "cat /run/store-provision-console")
check "TC-805-29 the record is exactly four lines, outcome=applied" \
	"$(yes_if eval '[ "$(printf "%s\n" "$prec" | cut -d= -f1 | tr "\n" " ")" = "outcome boot_id run_id reason " ] && [ "$(pfield outcome "$prec")" = applied ]')" "$prec"
check "TC-805-29 the record's run_id is the unit's InvocationID ($pid1)" "$(yes_if [ "$(pfield run_id "$prec")" = "$pid1" ])" "$prec"
check "TC-805-29 the record is 0600 root" "$(yes_if [ "$(inside "stat -c '%a %u:%g' $PRECORD")" = "600 0:0" ])" "$(inside "stat -c '%a %u:%g' $PRECORD")"
check "TC-805-29 the <6> line says applied changed=2" "$(yes_if contains '<6>rasputin-store-provision: outcome=applied changed=2 ' "$pline")" "$pline"
r9=$(inside "sh /root/store-read.sh inspect")
check "TC-805-29 the kv-v2 mount rasputin-rel-n1 exists" \
	"$(yes_if [ "$(field mounts "$r9" | jq -c '.data["rasputin-rel-n1/"] | [.type, .options.version]')" = '["kv","2"]' ])" "$(field mounts "$r9" | jq -c '.data | keys' 2>&1)"
check "TC-805-29 the role rasputin-rel-n1 exists" "$(yes_if eval 'field roles "$r9" | jq -e ".data.keys | index(\"rasputin-rel-n1\")" >/dev/null')" "$(field roles "$r9")"
lk=$(inside "sh /root/store-read.sh lookup rel rasputin-rel-n1")
check "TC-805-29 the role's leaf logs in carrying exactly [rasputin-bindable] (got $lk)" "$(yes_if [ "$lk" = '["rasputin-bindable"]' ])"
check "TC-805-29 zero tokens carry root after N+1" "$(yes_if contains 'root-tokens 0' "$(view "$r9")")"
au=$(audit_after "$A0")
for path in sys/mounts/rasputin-rel-n1 auth/cert/certs/rasputin-rel-n1; do
	pol=$(printf '%s\n' "$au" | jq -c --arg p "$path" 'select(.type == "request" and .request.path == $p and .request.operation == "update") | .auth.policies' 2>/dev/null | head -1)
	check "TC-805-29 the audit entry for the write to $path carries the provisioner's policies (got $pol)" "$(yes_if [ "$pol" = '["rasputin-provisioner"]' ])"
done
um=$(unseal_mono "$sid")
lt=$(printf '%s\n' "$au" | jq -r 'select(.type == "request" and .request.path == "auth/cert/login") | .time' 2>/dev/null | head -1)
lt_mono=""
if [ -n "$lt" ] && [ -n "$um" ]; then
	# Both on one clock: the journal entry's realtime against the audit time.
	ur=$(inside "journalctl _SYSTEMD_INVOCATION_ID=$sid -o json --no-pager" | jq -r 'select((.MESSAGE | tostring) | test("unsealed with stored key")) | .__REALTIME_TIMESTAMP' | head -1)
	lt_mono=$(inside "date -d '$lt' +%s%6N")
fi
check "TC-805-29 the wait ended on this run's 'unsealed with stored key' line, which precedes the provisioner's login in the audit file (${ur:-?} <= ${lt_mono:-?})" \
	"$(yes_if eval '[ -n "${ur:-}" ] && [ -n "$lt_mono" ] && [ "$ur" -le "$lt_mono" ]')"
pj=$(inside "journalctl -u $PROV _SYSTEMD_INVOCATION_ID=$pid1 --no-pager -o cat")
check "TC-805-29 no bound was reached" "$(yes_if not_contains 'logged no unseal result within' "$pj$prec")" "$pj"
papi=$(inside "systemctl show rasputin-api.service -p ActiveEnterTimestampMonotonic --value")
pdone=$(pshow ActiveEnterTimestampMonotonic)
check "TC-805-29 the stub api's start follows the provisioner's exit ($papi >= $pdone)" "$(yes_if eval '[ "$papi" -ge "$pdone" ] && [ "$pdone" -gt 0 ]')"
# followers — every process following a journal by invocation id, from /proc
# (the image has no pgrep). The bracket keeps this command's own line out.
followers() { inside "grep -la '[_]SYSTEMD_INVOCATION_ID=' /proc/[0-9]*/cmdline 2>/dev/null || true"; }
tasks=$(pshow TasksCurrent); cg=$(pshow ControlGroup); left=$(followers)
check "TC-805-29 the provisioner, active (exited), holds no process: TasksCurrent 0, or no cgroup left ('$tasks', cgroup '$cg'), and no journal follower anywhere" \
	"$(yes_if eval '{ [ "$tasks" = 0 ] || { [ "$tasks" = "[not set]" ] && [ -z "$cg" ]; }; } && [ -z "$left" ]')" "followers: $left"
PCREDS=/run/credentials/$PROV
n=$(as_uid "$BAO_UID" "wc -c <$PCREDS/provisioner.key")
check "TC-805-29 uid $BAO_UID reads the provisioner's key copy ($n bytes)" "$(yes_if [ "${n:-0}" -gt 0 ])"
for c in provisioner.pem provisioner.key store-ca.pem; do
	err=$(as_uid 65534 "cat $PCREDS/$c >/dev/null" 2>&1) && r=1 || r=0
	check "TC-805-29 uid 65534 is refused the credential copy $c" "$r" "$err"
done

echo "  -- the no-op re-apply (TC-805-30)"
A1=$(audit_lines); v29=$(view "$r9")
api_restart
pid2=$(pshow InvocationID); prec=$(inside "cat $PRECORD")
check "TC-805-30 the record says unchanged" "$(yes_if [ "$(pfield outcome "$prec")" = unchanged ])" "$prec"
check "TC-805-30 its run_id ($pid2) differs from TC-805-29's ($pid1)" "$(yes_if eval '[ "$(pfield run_id "$prec")" = "$pid2" ] && [ "$pid2" != "$pid1" ]')"
check "TC-805-30 the <6> line says unchanged changed=0" "$(yes_if contains '<6>rasputin-store-provision: outcome=unchanged changed=0 ' "$(inside "cat /run/store-provision-console")")"
wr=$(audit_after "$A1" | jq -c 'select(.type == "request" and (.request.operation == "create" or .request.operation == "update") and ((.request.path | startswith("sys/mounts/rasputin-rel-")) or (.request.path | startswith("auth/cert/certs/rasputin-rel-")))) | .request.path' 2>/dev/null)
check "TC-805-30 no create or update on sys/mounts/rasputin-rel-* or auth/cert/certs/rasputin-rel-* after the mark" "$(yes_if [ -z "$wr" ])" "$wr"
v30=$(view "$(inside "sh /root/store-read.sh inspect")")
check "TC-805-30 the inspector's view is byte-identical" "$(yes_if [ "$v30" = "$v29" ])" "before: $(printf '%s' "$v29" | tr '\n' '|') after: $(printf '%s' "$v30" | tr '\n' '|')"

echo "  -- a refused write, end to end (TC-805-31)"
# TEST HARNESS: a copy of the oneshot whose parse admits rasputin-seal-rotate,
# so the store's own refusal is what is shown.
inside "cp -p /usr/lib/rasputin/store-provision/rasputin-store-provision.sh /root/prov.sh.orig
sed -i 's/^BINDABLE=rasputin-bindable$/BINDABLE=rasputin-seal-rotate/' /usr/lib/rasputin/store-provision/rasputin-store-provision.sh
grep -q '^BINDABLE=rasputin-seal-rotate$' /usr/lib/rasputin/store-provision/rasputin-store-provision.sh" || check "TEST HARNESS: the parse-widened copy is installed" 1
set_tsv 'role\trasputin-rel-sr\trasputin-seal-rotate\n'
api_restart
prec=$(inside "cat $PRECORD"); pline=$(inside "cat /run/store-provision-console")
check "TC-805-31 the record is failed, naming the path and 403" \
	"$(yes_if eval '[ "$(pfield outcome "$prec")" = failed ] && contains "auth/cert/certs/rasputin-rel-sr (HTTP 403)" "$prec"')" "$prec"
check "TC-805-31 the console line is <3>" "$(yes_if contains '<3>rasputin-store-provision: outcome=failed ' "$pline")" "$pline"
check "TC-805-31 the store stays active" "$(yes_if [ "$(show ActiveState)" = active ])"
check "TC-805-31 the role is absent" "$(yes_if eval '! field roles "$(inside "sh /root/store-read.sh inspect")" | jq -e ".data.keys | index(\"rasputin-rel-sr\")" >/dev/null')"
check "TC-805-31 the stub api started" "$(yes_if [ "$(inside "systemctl show rasputin-api.service -p ActiveState --value")" = active ])"
inside "install -m 0755 /root/prov.sh.orig /usr/lib/rasputin/store-provision/rasputin-store-provision.sh" || check "the original oneshot is restored" 1
check "the original oneshot is back, byte for byte" "$(yes_if [ "$(inside "sha256sum </usr/lib/rasputin/store-provision/rasputin-store-provision.sh")" = "$(inside "sha256sum </overlay/usr/lib/rasputin/store-provision/rasputin-store-provision.sh")" ])"

echo "  -- a wrong-key store ends on bao's own line, not a timer (TC-805-32)"
set_tsv 'mount\trasputin-rel-wk\n'
A2=$(audit_lines)
# TEST HARNESS: a wrong seal key, so bao logs failed to unseal core every 5 s.
inside "head -c 32 /dev/urandom >/root/wrong-key && install -m 0600 /root/wrong-key $V/openbao-seal/seal-key" || check "the wrong key is installed" 1
api_restart
pid3=$(pshow InvocationID); prec=$(inside "cat $PRECORD")
check "TC-805-32 the provisioner records failed, quoting bao's fetching stored unseal keys failed: text" \
	"$(yes_if eval '[ "$(pfield outcome "$prec")" = failed ] && contains "(it logged: fetching stored unseal keys failed:" "$prec"')" "$prec"
pj=$(inside "journalctl -u $PROV _SYSTEMD_INVOCATION_ID=$pid3 --no-pager -o cat")
check "TC-805-32 no line names the bound" "$(yes_if not_contains 'logged no unseal result within' "$pj$prec")" "$pj"
pin=$(pshow InactiveExitTimestampMonotonic); pend=$(pshow StateChangeTimestampMonotonic)
check "TC-805-32 the provisioner's start to its exit is under 10 s ($(( (pend - pin) / 1000 )) ms)" \
	"$(yes_if eval '[ "$pin" -gt 0 ] && [ $(( pend - pin )) -lt 10000000 ]')"
papi=$(inside "systemctl show rasputin-api.service -p ActiveEnterTimestampMonotonic --value")
check "TC-805-32 the stub api starts after the provisioner exits, within the stated worst case of 10 + 2 + 2 x (1 + 2) = 18 s" \
	"$(yes_if eval '[ "$papi" -ge "$pend" ] && [ $(( papi - pin )) -le 18000000 ]')"
check "TC-805-32 the store is up, sealed" "$(yes_if eval '[ "$(show ActiveState)" = active ] && [ "$(store_get sys/health)" = 503 ]')"
nl=$(audit_after "$A2" | jq -c 'select(.request.path == "auth/cert/login")' 2>/dev/null | grep -c '' || true)
check "TC-805-32 no provisioner login reached the store's audit file (got $nl)" "$(yes_if [ "${nl:-0}" = 0 ])"
# The correct key back: a new run, applied, not ended by the earlier run's
# failure line, which is still in the journal.
put_seal
api_restart
pid4=$(pshow InvocationID); prec=$(inside "cat $PRECORD")
check "TC-805-32 with the key restored: a new run_id ($pid4, not $pid3) that ends applied" \
	"$(yes_if eval '[ "$pid4" != "$pid3" ] && [ "$(pfield run_id "$prec")" = "$pid4" ] && [ "$(pfield outcome "$prec")" = applied ]')" "$prec"
check "TC-805-32 the earlier run's failure line is still in the journal" \
	"$(yes_if contains 'fetching stored unseal keys failed' "$(inside "journalctl -u openbao.service --no-pager -o cat")")"

echo "  -- the store stopped mid-wait, then returned (TC-805-33)"
set_tsv 'mount\trasputin-rel-sw\n'
# TEST HARNESS: a wrong key, and LogLevelMax=notice on the store, so bao's
# lines (journald files them at info) never reach the journal: the store is
# sealed and silent, and the wait follows the journal.
inside "install -m 0600 /root/wrong-key $V/openbao-seal/seal-key
printf '[Service]\nLogLevelMax=notice\n' >/etc/systemd/system/openbao.service.d/harness-silent.conf
systemctl daemon-reload; systemctl stop rasputin-api.service openbao.service; systemctl reset-failed openbao.service $PROV 2>/dev/null
systemctl start --no-block openbao.service" >/dev/null 2>&1
pprev=$pid4
wait_for "the provisioner's wait is following the journal" \
	"[ \"\$(systemctl show $PROV -p ActiveState --value)\" = activating ] && [ \"\$(systemctl show $PROV -p InvocationID --value)\" != '$pprev' ] && grep -qa '[_]SYSTEMD_INVOCATION_ID=' /proc/[0-9]*/cmdline" \
	|| fails=$((fails + 1))
pid5=$(pshow InvocationID)
inside "systemctl stop openbao.service" >/dev/null 2>&1
wait_for "the provisioner is stopped" "[ -z \"\$(systemctl show $PROV -p Job --value)\" ] && case \"\$(systemctl show $PROV -p ActiveState --value)\" in inactive|failed) true ;; *) false ;; esac" || fails=$((fails + 1))
prec=$(inside "cat $PRECORD")
check "TC-805-33 the stopped run records failed, naming the stop, under its own run_id" \
	"$(yes_if eval '[ "$(pfield outcome "$prec")" = failed ] && [ "$(pfield run_id "$prec")" = "$pid5" ] && contains "stopped" "$prec"')" "$prec"
tasks=$(pshow TasksCurrent); cg=$(pshow ControlGroup); left=$(followers)
check "TC-805-33 its cgroup then holds no process: no journalctl and no sleeper ('$tasks', cgroup '$cg')" \
	"$(yes_if eval '[ "$tasks" = 0 ] || { [ "$tasks" = "[not set]" ] && [ -z "$cg" ]; }')"
check "TC-805-33 no journal follower is left anywhere" "$(yes_if [ -z "$left" ])" "$left"
inside "rm -f /etc/systemd/system/openbao.service.d/harness-silent.conf; systemctl daemon-reload" >/dev/null 2>&1
put_seal
pprev=$pid5
inside "systemctl start openbao.service" >/dev/null 2>&1
prov_settled "$pprev" || fails=$((fails + 1))
pid6=$(pshow InvocationID); prec=$(inside "cat $PRECORD")
check "TC-805-33 the store started again pulls the provisioner in: a new run_id with its outcome" \
	"$(yes_if eval '[ "$pid6" != "$pid5" ] && [ "$(pfield run_id "$prec")" = "$pid6" ] && [ "$(pfield outcome "$prec")" = applied ]')" "$prec"

echo "  -- the store crashes into its start limit mid-wait (F-805-19)"
# TC-805-33's one-item provision.tsv, already applied, so TC-805-34 still
# finds nothing to add once the store is back.
sprev=$(show InvocationID); k=0 pidk="" pcl=""
# Restart=always queues a restart job on every exit of the store, the last one
# too (which the start limit then refuses), and PartOf= carries each to the
# provisioner, so each kill stops its run mid-wait and none reaches the bound.
# TEST HARNESS: the wrong key and LogLevelMax=notice as in TC-805-33, so each
# run of the store is sealed and silent and the provisioner is mid-wait; and a
# StartLimitIntervalSec of an hour, so the kills below, each paced on the fact
# that the store's next run is up and followed, reach the store's own
# StartLimitBurst however long bao takes to start here.
inside "install -m 0600 /root/wrong-key $V/openbao-seal/seal-key
printf '[Service]\nLogLevelMax=notice\n' >/etc/systemd/system/openbao.service.d/harness-silent.conf
printf '[Unit]\nStartLimitIntervalSec=1h\n' >/etc/systemd/system/openbao.service.d/harness-startlimit.conf
systemctl daemon-reload; systemctl stop rasputin-api.service openbao.service; systemctl reset-failed openbao.service $PROV 2>/dev/null
systemctl start --no-block openbao.service" >/dev/null 2>&1
burst=$(show StartLimitBurst)
while [ "$k" -lt "$burst" ]; do
	k=$((k + 1))
	wait_for "kill $k of $burst: the store's next run is active and the provisioner is following that run's journal" \
		"s=\$(systemctl show openbao.service -p InvocationID --value) && [ \"\$s\" != '$sprev' ] && [ \"\$(systemctl show openbao.service -p ActiveState --value)\" = active ] && [ \"\$(systemctl show $PROV -p ActiveState --value)\" = activating ] && grep -qa \"[_]SYSTEMD_INVOCATION_ID=\$s\" /proc/[0-9]*/cmdline" \
		|| { fails=$((fails + 1)); break; }
	sprev=$(show InvocationID); pidk=$(pshow InvocationID); pcl=$(pshow InactiveExitTimestampMonotonic)
	inside "kill -KILL $(show MainPID)" >/dev/null 2>&1
done
wait_for "the store is failed at its start limit and the provisioner has no job and is not activating" \
	"[ \"\$(systemctl show openbao.service -p ActiveState --value)\" = failed ] && [ -z \"\$(systemctl show openbao.service -p Job --value)\" ] && [ -z \"\$(systemctl show $PROV -p Job --value)\" ] && [ \"\$(systemctl show $PROV -p ActiveState --value)\" != activating ]" \
	|| fails=$((fails + 1))
nr=$(show NRestarts)
check "F-805-19 the store's crash loop still runs to NRestarts = StartLimitBurst = $burst (got '$nr')" "$(yes_if [ "$nr" = "$burst" ])"
check "F-805-19 the journal says 'Start request repeated too quickly'" \
	"$(yes_if contains 'Start request repeated too quickly' "$(inside "journalctl -u openbao.service _PID=1 INVOCATION_ID=$sprev --no-pager -o cat; journalctl -u openbao.service --no-pager -o cat | tail -5")")"
prec=$(inside "cat $PRECORD"); pend=$(pshow InactiveEnterTimestampMonotonic)
check "F-805-19 the last run, killed into the start limit, records failed, naming the stop, under its own run_id ($pidk)" \
	"$(yes_if eval '[ "$(pfield outcome "$prec")" = failed ] && [ "$(pfield run_id "$prec")" = "$pidk" ] && contains "stopped" "$prec"')" "$prec"
pj=$(inside "journalctl -u $PROV _SYSTEMD_INVOCATION_ID=$pidk --no-pager -o cat")
check "F-805-19 no line names the bound" "$(yes_if not_contains 'logged no unseal result within' "$pj$prec")" "$pj"
check "F-805-19 the last run ended before the bound: its start to its end is under 10 s ($(( (${pend:-0} - ${pcl:-0}) / 1000 )) ms)" \
	"$(yes_if eval '[ "${pcl:-0}" -gt 0 ] && [ "${pend:-0}" -gt "$pcl" ] && [ $(( pend - pcl )) -lt 10000000 ]')"
left=$(followers)
check "F-805-19 no journal follower is left anywhere" "$(yes_if [ -z "$left" ])" "$left"
inside "rm -f /etc/systemd/system/openbao.service.d/harness-silent.conf /etc/systemd/system/openbao.service.d/harness-startlimit.conf; systemctl daemon-reload; systemctl reset-failed openbao.service $PROV" >/dev/null 2>&1
put_seal

echo "  -- the provisioner's leaf absent while the store runs (TC-805-34)"
inside "rm -f $V/tls/openbao-provisioner/leaf.pem $V/tls/openbao-provisioner/leaf.key" >/dev/null
api_restart
pid7=$(pshow InvocationID); prec=$(inside "cat $PRECORD"); pline=$(inside "cat /run/store-provision-console")
pst="$(pshow ActiveState) $(pshow Result)"
check "TC-805-34 the provisioner ends failed, exit-code (got '$pst')" "$(yes_if [ "$pst" = "failed exit-code" ])"
# The failing process is a control process (ExecStartPre), so systemd puts
# 243 on it, not on ExecMainStatus (the main process never ran).
c243=$(inside "journalctl -u $PROV _SYSTEMD_INVOCATION_ID=$pid7 --no-pager -o cat; journalctl -u $PROV --no-pager -o cat | tail -20" | grep -c 'status=243/CREDENTIALS' || true)
check "TC-805-34 systemd records the run's control process as status=243/CREDENTIALS (ExecMainStatus '$(pshow ExecMainStatus)')" "$(yes_if [ "${c243:-0}" -ge 1 ])"
check "TC-805-34 the record says failed: the provisioner's certificate could not be loaded" \
	"$(yes_if eval '[ "$(pfield outcome "$prec")" = failed ] && contains "certificate could not be loaded" "$prec"')" "$prec"
check "TC-805-34 a <3> line" "$(yes_if contains '<3>rasputin-store-provision: outcome=failed ' "$pline")" "$pline"
check "TC-805-34 the store and the stub api are unaffected" \
	"$(yes_if eval '[ "$(show ActiveState)" = active ] && [ "$(inside "systemctl show rasputin-api.service -p ActiveState --value")" = active ] && [ "$(store_get sys/health)" = 200 ]')"
put_prov_leaf
api_restart
pid8=$(pshow InvocationID); prec=$(inside "cat $PRECORD")
check "TC-805-34 with the leaf placed, the next run records unchanged under a new run_id" \
	"$(yes_if eval '[ "$pid8" != "$pid7" ] && [ "$(pfield run_id "$prec")" = "$pid8" ] && [ "$(pfield outcome "$prec")" = unchanged ]')" "$prec"

echo "  -- the read point #833 uses (TC-805-41)"
A=$(pfield run_id "$(inside "cat $PRECORD")")
out=$(inside "systemctl restart openbao.service && systemctl start $PROV && echo started; systemctl show $PROV -p ActiveState --value; systemctl show $PROV -p InvocationID --value; cat $PRECORD")
st41=$(printf '%s\n' "$out" | sed -n 2p); id41=$(printf '%s\n' "$out" | sed -n 3p)
check "TC-805-41 systemctl start returns only after the new run has finished: active, and the record is that run's ($id41, not $A)" \
	"$(yes_if eval 'contains started "$out" && [ "$st41" = active ] && [ "$id41" != "$A" ] && contains "run_id=$id41" "$out" && contains "outcome=unchanged" "$out"')" "$out"
inside "systemctl start $PROV" >/dev/null 2>&1
check "TC-805-41 systemctl start on the active (exited) unit starts no run: InvocationID and run_id unchanged" \
	"$(yes_if eval '[ "$(pshow InvocationID)" = "$id41" ] && [ "$(pfield run_id "$(inside "cat $PRECORD")")" = "$id41" ]')"

echo "  -- no token in any unit's journal (TC-805-28)"
tokens=$(inside "journalctl --no-pager -o cat | grep -c -E 'hv[sbr]\.[A-Za-z0-9]{24}|(^|[^A-Za-z0-9])[sbr]\.[A-Za-z0-9]{24}([^A-Za-z0-9]|\$)'")
check "TC-805-28 no token shape in the journal after every provisioner run (got ${tokens:-?} lines)" "$(yes_if [ "${tokens:-}" = 0 ])"
inside "systemctl stop rasputin-api.service openbao.service" >/dev/null 2>&1

echo
echo "11. the self-init line reaches the real /dev/kmsg from inside the store's unit (TC-804-23's console path)"
# Every scenario above sends the outcome writer's console line to a file
# (harness-console.conf), because in a privileged container /dev/kmsg is the
# host's. A file is not a device, so those scenarios cannot see the store
# unit's device policy, and the store-arming boot smoke found the line missing
# on both arches with the journal saying the hook "could not be written to
# /dev/kmsg" (geekdojo/geekdojo-brain#804, release run 38334384432). This start
# drops the redirect and writes where a node writes. The line lands in the
# runner's kernel log, which the job's VM discards.
inside "systemctl stop openbao.service; systemctl reset-failed openbao.service $PROV 2>/dev/null
rm -f /etc/systemd/system/openbao.service.d/harness-console.conf /etc/systemd/system/openbao.service.d/harness-inspector.conf
install -m 0644 /overlay/etc/rasputin/openbao/provision.tsv /etc/rasputin/openbao/provision.tsv
rm -rf /var/lib/rasputin/openbao/* /var/lib/rasputin/openbao/.[!.]* /var/lib/rasputin/openbao-audit/* /run/rasputin-store-init
systemctl daemon-reload" >/dev/null 2>&1
check "the data directory is empty and the console redirect is gone before the start" \
	"$(yes_if eval '[ -z "$(inside "ls -A /var/lib/rasputin/openbao")" ] && [ -z "$(inside "systemctl show openbao.service -p Environment --value" | grep RASPUTIN_STOREINIT_KMSG)" ]')"
C11=$(cursor)
inside "systemctl start openbao.service" >/dev/null 2>&1
j11=$(journal_after "$C11")
check "TC-804-23 the store's first start recorded initialised (got '$(inside "sed -n 's/^outcome=//p' /run/rasputin-store-init/outcome")')" \
	"$(yes_if [ "$(inside "sed -n 's/^outcome=//p' /run/rasputin-store-init/outcome")" = initialised ])"
check "TC-804-23 the outcome writer did not report that /dev/kmsg refused its line" \
	"$(yes_if not_contains 'could not be written to /dev/kmsg' "$j11")" "$(printf '%s\n' "$j11" | grep 'rasputin-store-init:')"
km=$(inside "dmesg" | grep -c 'rasputin-store-init: outcome=initialised' || true)
check "TC-804-23 the kernel log holds the rasputin-store-init: outcome=initialised line (got ${km:-0})" "$(yes_if [ "${km:-0}" -ge 1 ])"
inside "systemctl stop openbao.service" >/dev/null 2>&1

echo
echo "12. a staged store restore around a running store (TC-766-16 to TC-766-18)"
# TC-766-18: every start above ran the restore step with nothing staged, and
# it printed nothing.
rl=$(inside "journalctl --no-pager -o cat" | grep -c 'rasputin-store-restore:' || true)
check "TC-766-18 no start in scenarios 1 to 11 printed a rasputin-store-restore: line (got ${rl:-?})" "$(yes_if [ "${rl:-}" = 0 ])"

RP=$V/restore-pending
API_STUB_DIR=/run/stub-api
# TEST HARNESS: the api's restore hook (restoreRestartHook), played by a stub
# ExecStart on the shipped rasputin-api.service. Every start records whether
# the marker exists and the store's ActiveState. With the trigger file it
# stops the store, records the data and seal hashes the store stopped on, and
# exits 75, as the api does after staging a restore; otherwise it stays up.
cat >"$SCRATCH/stub-api.sh" <<'STUB'
#!/bin/sh
# TEST HARNESS (store-unit-functional.sh scenario 12): stands in for the api.
D=/run/stub-api
V=/var/lib/rasputin
mkdir -p "$D"
n=$(cat "$D/n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$D/n"
a=absent; [ -f "$V/restore-pending/store/applied" ] && a=present
echo "start=$n applied=$a store=$(systemctl show openbao.service -p ActiveState --value)" >>"$D/log"
if [ -e "$D/trigger" ]; then
	rm -f "$D/trigger"
	systemctl stop openbao.service
	(cd "$V/openbao" && find . -type f -exec sha256sum {} + | sort | sha256sum) >"$D/data-at-stop"
	cat "$V/openbao-seal/seal-key" "$V/openbao-seal/seal.hcl" | sha256sum >"$D/seal-at-stop"
	exit 75
fi
exec sleep infinity
STUB
docker cp "$SCRATCH/stub-api.sh" "$CID:/root/stub-api.sh" >/dev/null || check "the stub api is copied into the container" 1
inside "systemctl stop rasputin-api.service openbao.service; systemctl reset-failed openbao.service $PROV 2>/dev/null
chmod 0755 /root/stub-api.sh
install -m 0644 /overlay/etc/systemd/system/rasputin-api.service /etc/systemd/system/rasputin-api.service
mkdir -p /etc/systemd/system/rasputin-api.service.d
printf '[Service]\nType=simple\nWatchdogSec=0\nExecStart=\nExecStart=/root/stub-api.sh\n' >/etc/systemd/system/rasputin-api.service.d/harness-stub.conf
printf '[Unit]\nDescription=TEST HARNESS stand-in firstboot\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/bin/true\n' >/etc/systemd/system/rasputin-firstboot.service
printf '[Service]\nEnvironment=RASPUTIN_STOREINIT_KMSG=/run/store-init-console\nEnvironment=RASPUTIN_STORERESTORE_KMSG=/run/store-restore-console\nEnvironment=RASPUTIN_STOREROLLBACK_KMSG=/run/store-rollback-console\n' >/etc/systemd/system/openbao.service.d/harness-console.conf
systemctl daemon-reload" >/dev/null 2>&1 || check "the shipped api unit, its stub drop-in and the stand-in firstboot are installed" 1
want_sha=$(openssl dgst -sha256 -r "$APIUNIT" | cut -d' ' -f1)
got_sha=$(inside "sha256sum /etc/systemd/system/rasputin-api.service" | cut -d' ' -f1)
check "TC-766-16 the installed rasputin-api.service is the overlay's, byte for byte (sha256 $got_sha)" \
	"$(yes_if eval '[ -n "$want_sha" ] && [ "$got_sha" = "$want_sha" ]')"

# fresh_store — a store as on a fresh flash: data and audit wiped, this boot's
# store-init record cleared, then a start that self-initialises it.
fresh_store() {
	inside "systemctl stop rasputin-api.service openbao.service; systemctl reset-failed openbao.service $PROV 2>/dev/null
rm -rf $V/openbao/* $V/openbao/.[!.]* $V/openbao-audit/* /run/rasputin-store-init $RP
systemctl start openbao.service" >/dev/null 2>&1
	wait_for "sys/health answers 200 on the freshly initialised store" "$HEALTH_200" || fails=$((fails + 1))
}
# reflash_b — store B, as on a reflashed node: data wiped, the seal key and
# fragment removed, a new pair from the real rasputin-seal-key.sh, then the
# store self-initialises on it.
reflash_b() {
	inside "systemctl stop rasputin-api.service openbao.service
rm -rf $V/openbao/* $V/openbao/.[!.]* $V/openbao-seal/seal-key $V/openbao-seal/seal.hcl" >/dev/null 2>&1
	_o=$(inside "RASPUTIN_SEALKEY_KMSG=/dev/null sh /overlay/usr/lib/rasputin/seal-key/rasputin-seal-key.sh; echo rc=\$?" 2>&1)
	check "$1: the real rasputin-seal-key.sh made B's key and fragment (outcome=created)" \
		"$(yes_if eval 'contains "rc=0" "$_o" && contains "rasputin-seal-key: outcome=created" "$_o"')" "$_o"
	fresh_store
	_b=$(inside "grep -o 'rasputin-[0-9a-f-]*' $V/openbao-seal/seal.hcl | head -n 1")
	check "$1: B's key id ($_b) is not A's ($FRAG_A_ID)" "$(yes_if eval '[ -n "$_b" ] && [ "$_b" != "$FRAG_A_ID" ]')"
	_c=$(inside "sh /root/store-read.sh read")
	check "$1: store B is running and A's sentinel answers 404 on it (got '$_c')" "$(yes_if [ "$_c" = 404 ])"
}
# stage_a [MISSING] — store A staged under restore-pending/ as PrepareRestore
# lays it out: root, 0700 directories, 0600 files; store/data, seal-key,
# seal.hcl and openbao-version, and trust/store-ca.{key,pem}. MISSING names a
# member left out.
stage_a() {
	inside "set -e
rm -rf $RP
mkdir -m 0700 $RP $RP/store $RP/trust
cp -a /root/stash-a/data $RP/store/data
chown -R 0:0 $RP/store/data
find $RP/store/data -type d -exec chmod 0700 {} +
find $RP/store/data -type f -exec chmod 0600 {} +
install -m 0600 /root/stash-a/seal-key $RP/store/seal-key
install -m 0600 /root/stash-a/seal.hcl $RP/store/seal.hcl
printf '%s' '$A_VERSION' >$RP/store/openbao-version; chmod 0600 $RP/store/openbao-version
install -m 0600 /pki/ca.key $RP/trust/store-ca.key
install -m 0600 /pki/store-ca.pem $RP/trust/store-ca.pem
printf '{\"id\":\"store-unit-functional\"}\n' >$RP/restore.json; chmod 0600 $RP/restore.json
[ -z '${1:-}' ] || rm -f $RP/store/${1:-none}" || check "store A is staged under $RP" 1
}
# staged_sum — every path under restore-pending/ but the marker, with each
# file's sha256.
staged_sum() { inside "cd $RP && find . ! -path ./store/applied -print | sort | while read -r f; do if [ -f \"\$f\" ]; then sha256sum \"\$f\"; else echo \"\$f\"; fi; done"; }
# trigger LABEL — the stub api's start, with the trigger: it stops the store
# and exits 75, and its restart follows.
trigger() {
	inside "rm -rf $API_STUB_DIR; mkdir -p $API_STUB_DIR; touch $API_STUB_DIR/trigger; rm -f /run/store-restore-console
systemctl start --no-block rasputin-api.service" >/dev/null 2>&1
}

echo "  -- store A, the backup's store"
put_seal || check "store A's seal key and fragment (the oneshot's, kept in /pki) are installed" 1
fresh_store
code=$(inside "sh /root/store-read.sh write")
check "TC-766-16 the api role writes a sentinel to store A (got '$code')" "$(yes_if [ "$code" = 200 ])"
# TC-801-35 (F-801-02): the staged openbao-version is the live store's own
# sys/health version, as the api stages it, not a literal: the version gate
# parses it strictly.
A_VERSION=$(health_version)
# xyz VERSION — VERSION is the gate's X.Y.Z shape.
xyz() { printf '%s\n' "$1" | grep -qxE '[0-9]{1,9}[.][0-9]{1,9}[.][0-9]{1,9}'; }
check "TC-801-35 store A's sys/health version is X.Y.Z (got '$A_VERSION')" "$(yes_if xyz "$A_VERSION")"
# TEST HARNESS: A's data and seal pair kept, standing in for the backup
# capture, with the store stopped.
inside "systemctl stop openbao.service; rm -rf /root/stash-a; mkdir -m 0700 /root/stash-a
cp -a $V/openbao /root/stash-a/data && cp -p $V/openbao-seal/seal-key $V/openbao-seal/seal.hcl /root/stash-a/ && cp -p /root/sentinel /root/stash-a/sentinel" \
	|| check "store A is stashed" 1

echo "  -- the restore applied around running store B (TC-766-16)"
reflash_b "TC-766-16"
stage_a
STAGED_SUM=$(staged_sum)
REC_BEFORE=$(inside "sha256sum /run/rasputin-store-init/outcome" | cut -d' ' -f1)
INV_B=$(show InvocationID)
check "TC-766-16 store B is active before the restore (InvocationID $INV_B)" "$(yes_if eval '[ "$(show ActiveState)" = active ] && [ -n "$INV_B" ]')"
C12=$(cursor)
trigger
wait_for "the stub api has started a second time, and the store is active under a new invocation" \
	"grep -q '^start=2 ' $API_STUB_DIR/log && [ \"\$(systemctl show openbao.service -p ActiveState --value)\" = active ] && [ \"\$(systemctl show openbao.service -p InvocationID --value)\" != '$INV_B' ]" \
	|| fails=$((fails + 1))
INV_A=$(show InvocationID)
stub=$(inside "cat $API_STUB_DIR/log")
printf '%s\n' "$stub" | sed 's/^/         stub api: /'
check "TC-766-16 the store was stopped by the stub api and started again under a new invocation ($INV_B -> $INV_A)" \
	"$(yes_if eval '[ -n "$INV_A" ] && [ "$INV_A" != "$INV_B" ] && contains "start=1 applied=absent store=active" "$stub"')" "$stub"
wait_for "the store's new invocation journals outcome=applied" \
	"journalctl _SYSTEMD_INVOCATION_ID=$INV_A --no-pager -o cat | grep -q 'rasputin-store-restore: outcome=applied'" || fails=$((fails + 1))
ji=$(inside "journalctl _SYSTEMD_INVOCATION_ID=$INV_A --no-pager -o cat")
line=$(printf '%s\n' "$ji" | grep 'rasputin-store-restore: outcome=applied' || true)
check "TC-766-16 that invocation's journal holds rasputin-store-restore: outcome=applied" "$(yes_if [ -n "$line" ])" \
	"$(printf '%s\n' "$ji" | tail -5 | tr '\n' '|')"
[ -n "$line" ] && printf '         journal: %s\n' "$line"
check "TC-766-16 the stub api's restarted start saw the marker, with the store active" \
	"$(yes_if contains "start=2 applied=present store=active" "$stub")" "$stub"
wait_for "sys/health answers 200 on the restored store" "$HEALTH_200" || fails=$((fails + 1))
check "TC-766-16 sys/health answers 200, unsealed (got '$(store_get sys/health)')" "$(yes_if [ "$(store_get sys/health)" = 200 ])"
check "TC-766-16 the seal.hcl credential names A's key id ($FRAG_A_ID)" \
	"$(yes_if inside "grep -qF '$FRAG_A_ID' $CREDS/seal.hcl")"
check "TC-766-16 the live seal-key is A's, byte for byte" \
	"$(yes_if [ "$(inside "sha256sum </root/stash-a/seal-key")" = "$(inside "sha256sum <$V/openbao-seal/seal-key")" ])"
code=$(inside "sh /root/store-read.sh read")
got=$(inside "cat /root/read.json" | jq -r .data.data.v 2>/dev/null)
want=$(inside "cat /root/stash-a/sentinel")
check "TC-766-16 the sentinel reads back as A's value (status '$code')" "$(yes_if eval '[ "$code" = 200 ] && [ -n "$want" ] && [ "$got" = "$want" ]')"
own=$(inside "stat -c '%a %u:%g' $V/openbao; find $V/openbao ! -uid $BAO_UID | wc -l")
check "TC-766-16 the data directory is 0700 $BAO_UID:$BAO_GID and every entry under it is owned by $BAO_UID (got '$(printf '%s' "$own" | tr '\n' ' ')')" \
	"$(yes_if [ "$own" = "700 $BAO_UID:$BAO_GID
0" ])"
left=$(inside "find $V -name '.rasputin-restore-*'")
check "TC-766-16 no .rasputin-restore-* path is left" "$(yes_if [ -z "$left" ])" "$left"
check "TC-766-16 restore-pending/ is whole, trust/store-ca.* and store/openbao-version included" \
	"$(yes_if eval '[ "$(staged_sum)" = "$STAGED_SUM" ] && contains "./trust/store-ca.key" "$STAGED_SUM" && contains "./store/openbao-version" "$STAGED_SUM"')"
check "TC-766-16 /run/rasputin-store-init/outcome is byte-identical to its content before the stop" \
	"$(yes_if [ "$(inside "sha256sum /run/rasputin-store-init/outcome" | cut -d' ' -f1)" = "$REC_BEFORE" ])"
check "TC-766-16 that invocation's journal has no rasputin-store-init: outcome=initialised line" \
	"$(yes_if not_contains 'rasputin-store-init: outcome=initialised' "$ji")"
hex=$(inside "od -An -v -tx1 /root/stash-a/seal-key | tr -d ' \n' >/root/a-key.hex; wc -c </root/a-key.hex; journalctl --no-pager -o cat | grep -c -F -f /root/a-key.hex; rm -f /root/a-key.hex")
check "TC-766-16 no byte of A's key, in hex, is in the journal (hex length, journal lines: '$(printf '%s' "$hex" | tr '\n' ' ')')" \
	"$(yes_if eval '[ "$(printf "%s\n" "$hex" | sed -n 1p | tr -d " ")" = 64 ] && [ "$(printf "%s\n" "$hex" | sed -n 2p)" = 0 ]')"

echo "  -- a staging missing seal.hcl, around running store B (TC-766-17)"
reflash_b "TC-766-17"
stage_a seal.hcl
ACT_B=$(show ActiveEnterTimestampMonotonic)
INV_B=$(show InvocationID)
trigger
wait_for "the stub api has started a second time, and the store is failed with no job after the refusal" \
	"grep -q '^start=2 ' $API_STUB_DIR/log && [ \"\$(systemctl show openbao.service -p ActiveState --value)\" = failed ] && [ -z \"\$(systemctl show openbao.service -p Job --value)\" ] && journalctl -u openbao.service --after-cursor='$C12' --no-pager -o cat | grep -q 'rasputin-store-restore: outcome=refused'" \
	|| fails=$((fails + 1))
stub=$(inside "cat $API_STUB_DIR/log")
printf '%s\n' "$stub" | sed 's/^/         stub api: /'
INV_F=$(show InvocationID)
jf=$(inside "journalctl _SYSTEMD_INVOCATION_ID=$INV_F --no-pager -o cat")
line=$(printf '%s\n' "$jf" | grep 'rasputin-store-restore: outcome=refused' || true)
check "TC-766-17 the store's start ($INV_F, not $INV_B) journals rasputin-store-restore: outcome=refused, naming seal.hcl" \
	"$(yes_if eval '[ "$INV_F" != "$INV_B" ] && contains "$RP/store/seal.hcl is missing" "$line"')" "$(printf '%s\n' "$jf" | tail -5 | tr '\n' '|')"
[ -n "$line" ] && printf '         journal: %s\n' "$line"
st="$(show ActiveState) $(show Result)"
check "TC-766-17 the store's start fails at ExecStartPre: failed, exit-code (got '$st')" "$(yes_if [ "$st" = "failed exit-code" ])"
check "TC-766-17 the store never became active while the staging was in place (ActiveEnterTimestampMonotonic still $ACT_B)" \
	"$(yes_if eval '[ "$(show ActiveEnterTimestampMonotonic)" = "$ACT_B" ] && [ "$ACT_B" -gt 0 ]')"
check "TC-766-17 B's data is unchanged since the store stopped" \
	"$(yes_if [ "$(inside "cd $V/openbao && find . -type f -exec sha256sum {} + | sort | sha256sum")" = "$(inside "cat $API_STUB_DIR/data-at-stop")" ])"
check "TC-766-17 B's seal-key and seal.hcl are unchanged" \
	"$(yes_if [ "$(inside "cat $V/openbao-seal/seal-key $V/openbao-seal/seal.hcl | sha256sum")" = "$(inside "cat $API_STUB_DIR/seal-at-stop")" ])"
check "TC-766-17 there is no restore-pending/store/applied" "$(yes_if inside "test ! -e $RP/store/applied")"
check "TC-766-17 the stub api's restarted start recorded the marker absent" "$(yes_if contains "start=2 applied=absent" "$stub")" "$stub"
left=$(inside "find $V -name '.rasputin-restore-*'")
check "TC-766-17 no .rasputin-restore-* path is left" "$(yes_if [ -z "$left" ])" "$left"
inside "systemctl stop rasputin-api.service openbao.service; systemctl reset-failed openbao.service $PROV 2>/dev/null; rm -rf $RP /root/stash-a" >/dev/null 2>&1

echo
echo "13. the store's version gate (TC-801-31 to TC-801-35)"
GREC=/run/rasputin-store-rollback/outcome
COPYF=$V/openbao-preupdate.tar
ASIDEF=$V/openbao-rolled-back.tar
MARK=$V/openbao-version
NEWER_V="$(( ${PIN%%.*} + 1 )).0.0"
# data_sum — the data directory's files and their hashes, as one hash.
DATA_SUM="cd $V/openbao && find . -type f -exec sha256sum {} + | sort | sha256sum"
data_sum() { inside "$DATA_SUM"; }
gate_outcome() { inside "sed -n 's/^outcome=//p' $GREC 2>/dev/null"; }
# TEST HARNESS: a fourth ExecStartPre=, after the shipped three (a drop-in's
# lines come after the unit's), records the data directory's hash between the
# gate and bao, so the data the gate left can be compared even though bao
# writes to it once it runs.
inside "systemctl stop rasputin-api.service openbao.service; systemctl reset-failed openbao.service $PROV 2>/dev/null
printf '[Service]\nExecStartPre=+/bin/sh -c \"cd $V/openbao && find . -type f -exec sha256sum {} + | sort | sha256sum >/run/data-at-pre\"\n' >/etc/systemd/system/openbao.service.d/harness-gate-hash.conf
systemctl daemon-reload" >/dev/null 2>&1 || check "the gate-hash drop-in is installed" 1
pre_sum() { inside "cat /run/data-at-pre 2>/dev/null"; }

echo "  -- the upgrade path: data and no marker (TC-801-35)"
check "TC-801-35 every start in scenarios 1 to 12 passed the gate: no outcome=refused or outcome=failed line in the journal" \
	"$(yes_if [ -z "$(inside "journalctl --no-pager -o cat" | grep -E 'rasputin-store-rollback: outcome=(refused|failed)' || true)" ])" \
	"$(inside "journalctl --no-pager -o cat" | grep 'rasputin-store-rollback: outcome=' | tail -3)"
check "TC-801-35 the data directory has data before this start" "$(yes_if [ -n "$(inside "ls -A $V/openbao")" ])"
inside "rm -f $MARK $V/openbao-version-hold $COPYF $ASIDEF; rm -rf /run/rasputin-store-rollback; systemctl start openbao.service" >/dev/null 2>&1
wait_for "sys/health answers 200 after the upgrade-path start" "$HEALTH_200" || fails=$((fails + 1))
check "TC-801-35 the record says current (got '$(gate_outcome)')" "$(yes_if [ "$(gate_outcome)" = current ])"
check "TC-801-35 the marker is the pin, $PIN (got '$(inside "cat $MARK")')" "$(yes_if [ "$(inside "cat $MARK")" = "$PIN" ])"
check "TC-801-35 the marker is 0600 root:root (got '$(inside "stat -c '%a %u:%g' $MARK")')" \
	"$(yes_if [ "$(inside "stat -c '%a %u:%g' $MARK")" = "600 0:0" ])"
inside "systemctl stop openbao.service" >/dev/null 2>&1

echo "  -- 13a equal versions (TC-801-31)"
inside "touch -d '2020-01-01' $MARK; rm -rf /run/rasputin-store-rollback /run/data-at-pre" >/dev/null
BEFORE=$(data_sum)
MARK_BEFORE=$(inside "sha256sum <$MARK; stat -c %Y $MARK")
inside "systemctl start openbao.service" >/dev/null 2>&1
wait_for "sys/health answers 200 with equal versions" "$HEALTH_200" || fails=$((fails + 1))
check "TC-801-31 sys/health answers 200 (got '$(store_get sys/health)')" "$(yes_if [ "$(store_get sys/health)" = 200 ])"
check "TC-801-31 the data the gate left, hashed before bao ran, is unchanged" "$(yes_if eval '[ -n "$BEFORE" ] && [ "$(pre_sum)" = "$BEFORE" ]')"
check "TC-801-31 the marker's bytes and mtime are unchanged" "$(yes_if [ "$(inside "sha256sum <$MARK; stat -c %Y $MARK")" = "$MARK_BEFORE" ])"
check "TC-801-31 the record says current (got '$(gate_outcome)')" "$(yes_if [ "$(gate_outcome)" = current ])"
check "TC-801-31 no aside copy was written" "$(yes_if inside "test ! -e $ASIDEF")"

echo "  -- 13b newer data and a matching copy (TC-801-32)"
code=$(inside "sh /root/store-read.sh write && cp /root/sentinel /root/sentinel-p")
check "TC-801-32 secret P is written (got '$code')" "$(yes_if [ "$code" = 200 ])"
LIVE_V=$(health_version)
check "TC-801-32 F-801-02 the live store's sys/health version is the pin (got '$LIVE_V')" "$(yes_if [ "$LIVE_V" = "$PIN" ])"
# TEST HARNESS: #800's copy, laid out as store_capture writes it: the data
# directory's regular files as store/data/<rel>, sorted, then
# store/openbao-version holding the sys/health version with no newline; no
# directory members.
inside "set -e
systemctl stop openbao.service
rm -rf /root/copy-stage; mkdir -p /root/copy-stage/store
cp -a $V/openbao /root/copy-stage/store/data
printf '%s' '$LIVE_V' >/root/copy-stage/store/openbao-version
cd /root/copy-stage
tar -cf $COPYF \$(find store/data -type f | LC_ALL=C sort) store/openbao-version
chmod 0600 $COPYF" >/dev/null 2>&1 || check "TC-801-32 the copy is built" 1
P_SUM=$(inside "cd /root/copy-stage/store/data && find . -type f -exec sha256sum {} + | sort | sha256sum")
dirs=$(inside "tar -tvf $COPYF" | grep -c '^d' || true)
check "TC-801-32 F-801-03 the copy has no directory members (got ${dirs:-?})" "$(yes_if [ "${dirs:-}" = 0 ])"
inside "systemctl start openbao.service" >/dev/null 2>&1
wait_for "sys/health answers 200 before secret Q" "$HEALTH_200" || fails=$((fails + 1))
code=$(inside "sh /root/store-read.sh write && cp /root/sentinel /root/sentinel-q")
check "TC-801-32 secret Q is written (got '$code')" "$(yes_if [ "$code" = 200 ])"
inside "systemctl stop openbao.service" >/dev/null 2>&1
Q_SUM=$(data_sum)
inside "printf '%s\n' '$NEWER_V' >$MARK; chmod 0600 $MARK; rm -rf /run/rasputin-store-rollback /run/data-at-pre" >/dev/null
C13=$(cursor)
inside "systemctl start openbao.service" >/dev/null 2>&1
wait_for "sys/health answers 200 on the rolled-back store" "$HEALTH_200" || fails=$((fails + 1))
INV13=$(show InvocationID)
code=$(inside "sh /root/store-read.sh read")
got=$(inside "cat /root/read.json" | jq -r .data.data.v 2>/dev/null)
check "TC-801-32 the store unsealed, and the secret reads back as P (status '$code')" \
	"$(yes_if eval '[ "$code" = 200 ] && [ -n "$got" ] && [ "$got" = "$(inside "cat /root/sentinel-p")" ]')"
check "TC-801-32 Q's value is gone" "$(yes_if eval '[ "$got" != "$(inside "cat /root/sentinel-q")" ]')"
check "TC-801-32 the data the gate left is the copy's store/data, byte for byte" "$(yes_if [ "$(pre_sum)" = "$P_SUM" ])"
check "TC-801-32 the marker is the pin (got '$(inside "cat $MARK")')" "$(yes_if [ "$(inside "cat $MARK")" = "$PIN" ])"
AX=$(inside "rm -rf /root/aside-x; mkdir /root/aside-x; tar -xf $ASIDEF -C /root/aside-x && cd /root/aside-x && find . -type f -exec sha256sum {} + | sort | sha256sum")
check "TC-801-32 the aside copy holds the post-Q data, byte for byte" "$(yes_if eval '[ -n "$Q_SUM" ] && [ "$AX" = "$Q_SUM" ]')"
check "TC-801-32 the record says restored (got '$(gate_outcome)')" "$(yes_if [ "$(gate_outcome)" = restored ])"
own=$(inside "find $V/openbao ! -uid $BAO_UID | wc -l; find $V/openbao -name '.rasputin-rollback-*' | wc -l")
check "TC-801-32 every data entry is owned by $BAO_UID and no work directory is left (got '$(printf '%s' "$own" | tr '\n' ' ')')" \
	"$(yes_if [ "$own" = "0
0" ])"
order=$(inside "journalctl _SYSTEMD_INVOCATION_ID=$INV13 --no-pager -o json" | jq -r '.SYSLOG_IDENTIFIER // empty' | awk '
	$0 == "rasputin-store-rollback.sh" && !g { g = NR } $0 == "bao" && !b { b = NR } END { print g + 0, b + 0 }')
check "TC-801-32 the gate's journal line precedes bao's first line in that start (lines: '$order')" \
	"$(yes_if eval 'set -- $order; [ "$1" -gt 0 ] && [ "$2" -gt "$1" ]')"
gl=$(journal_after "$C13" | grep 'rasputin-store-rollback: outcome=restored' || true)
[ -n "$gl" ] && printf '         journal: %s\n' "$gl"

echo "  -- 13c newer data and no copy (TC-801-33)"
inside "systemctl stop openbao.service; systemctl reset-failed openbao.service $PROV 2>/dev/null
rm -f $COPYF; printf '%s\n' '$NEWER_V' >$MARK; chmod 0600 $MARK
rm -rf /run/rasputin-store-rollback /run/rasputin-store-init" >/dev/null 2>&1
BEFORE=$(data_sum)
MARK_BEFORE=$(inside "sha256sum <$MARK")
for n in 1 2; do
	C13C=$(cursor)
	inside "systemctl reset-failed openbao.service 2>/dev/null; systemctl start openbao.service" >/dev/null 2>&1
	wait_for "openbao.service is failed with no job after the refusal (start $n)" \
		'[ "$(systemctl show openbao.service -p ActiveState --value)" = failed ] && [ -z "$(systemctl show openbao.service -p Job --value)" ]' \
		|| fails=$((fails + 1))
	l="TC-801-33 start $n"
	st="$(show ActiveState) $(show Result)"
	check "$l: the unit is failed, Result=exit-code (got '$st')" "$(yes_if [ "$st" = "failed exit-code" ])"
	bl=$(inside "journalctl -u openbao.service --after-cursor='$C13C' --no-pager -o json" | jq -r '.SYSLOG_IDENTIFIER // empty' | grep -cx bao || true)
	check "$l: no bao process ran: no bao line in the journal and no bao process (got ${bl:-?} lines)" \
		"$(yes_if eval '[ "${bl:-}" = 0 ] && [ -z "$(inside "for p in /proc/[0-9]*; do [ \"\$(cat \$p/comm 2>/dev/null)\" = bao ] && echo \$p; done; true")" ]')"
	check "$l: the data is unchanged" "$(yes_if [ "$(data_sum)" = "$BEFORE" ])"
	check "$l: the marker is unchanged" "$(yes_if [ "$(inside "sha256sum <$MARK")" = "$MARK_BEFORE" ])"
	check "$l: no store-init pending marker and no store-init record" \
		"$(yes_if inside "test ! -e /run/rasputin-store-init/pending && test ! -e /run/rasputin-store-init/outcome")"
	check "$l: the record says refused (got '$(gate_outcome)')" "$(yes_if [ "$(gate_outcome)" = refused ])"
	rl=$(journal_after "$C13C" | grep -c 'rasputin-store-rollback: outcome=refused' || true)
	check "$l: the gate refused on each restart (got ${rl:-0} refused lines)" "$(yes_if [ "${rl:-0}" -ge 1 ])"
done

echo "  -- 13d the gate's journal identifier (TC-801-34)"
ids=$(inside "journalctl --no-pager -o json" | jq -r 'select((.MESSAGE // "") | tostring | contains("rasputin-store-rollback: outcome=")) | .SYSLOG_IDENTIFIER' | sort -u)
check "TC-801-34 every gate outcome line carries SYSLOG_IDENTIFIER=rasputin-store-rollback.sh (got '$(printf '%s' "$ids" | tr '\n' ' ')')" \
	"$(yes_if [ "$ids" = rasputin-store-rollback.sh ])"

inside "systemctl reset-failed openbao.service $PROV 2>/dev/null
rm -f /etc/systemd/system/openbao.service.d/harness-gate-hash.conf $COPYF $ASIDEF; rm -rf /root/copy-stage /root/aside-x /root/sentinel-p /root/sentinel-q
printf '%s\n' '$PIN' >$MARK; systemctl daemon-reload" >/dev/null 2>&1

echo
if [ "$fails" -eq 0 ]; then
	echo "store-unit-functional: all checks passed"
else
	echo "store-unit-functional: $fails check(s) FAILED"
fi
[ "$fails" -eq 0 ]
