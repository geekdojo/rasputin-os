#!/bin/sh
# Functional test for the secrets store's persistent paths, against REAL
# systemd-tmpfiles 258.7, the version Buildroot 2026.08 builds into the image,
# and the real at-rest audit, both run as root over the files the overlay ships.
# geekdojo/geekdojo-brain#754.
#
# WHY THIS EXISTS. The store's six directories are six tmpfiles.d lines and six
# inventory rows, and three claims about them are readings of systemd's
# behaviour that nothing else here can check:
#
#   * a numeric owner (990) works with no such user in /etc/passwd. The test
#     container has no openbao user, which is the point: the line has to work
#     because it is a number, not because a name resolved;
#   * a declared parent (tls/) is created at its own mode, not at the 0755
#     tmpfiles gives a missing parent, and keeps what the api already wrote in
#     it;
#   * a `d` line re-asserts mode, owner and group on an existing directory on
#     every boot, and never touches the files inside it.
#
# Scenarios, all in one container:
#   0  the test fails closed: no docker is a failure naming docker, and an image
#      whose systemd is not 258.7 is refused (TC-754-17)
#   1  from empty: every directory at its declared mode and ids, and the real
#      audit over the shipped store rows says PASS (TC-754-14)
#   2  an existing install: wrong owners and widened modes are refused by the
#      audit, then re-asserted by the next tmpfiles run (TC-754-15)
#   3  the OTA shape: contents already on the partition survive two runs
#      byte for byte and mode for mode (TC-754-16)
#
# NOT COVERED: that the store can run on these paths, credential delivery with
# LoadCredential=, the files' modes from their real writers, and the image's
# mkusers. The store's own issues and the bench cover those.
#
# Needs: docker. Linux runner or Docker Desktop.
# Run:   sh test/store-paths-functional.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
TMPFILES="$OVERLAY/usr/lib/tmpfiles.d/rasputin.conf"
INVENTORY="$OVERLAY/usr/lib/rasputin/atrest/inventory"
AUDIT="$OVERLAY/usr/lib/rasputin/atrest/rasputin-atrest-audit.sh"
IMAGE=rasputin-store-paths-functional:f43-systemd-258.7

for f in "$TMPFILES" "$INVENTORY" "$AUDIT"; do
	[ -f "$f" ] || { echo "missing: $f" >&2; exit 2; }
done
command -v docker >/dev/null 2>&1 || { echo "docker not found - this test needs docker"; exit 1; }

fails=0
check() {
	if [ "$2" = "0" ]; then printf '  ok   %s\n' "$1"
	else printf '  FAIL %s\n       %s\n' "$1" "${3:-}"; fails=$((fails + 1)); fi
}
yes_if() { if "$@"; then echo 0; else echo 1; fi; }
contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
neither() { ! contains "$1" "$3" && ! contains "$2" "$3"; }

V=/var/lib/rasputin
# Each directory with the `stat -c '%a %u %g'` it must have. Literals, not read
# from the files under test.
EXPECTED="$V/openbao 700 990 990
$V/openbao-audit 700 990 990
$V/openbao-seal 700 0 0
$V/tls 700 0 0
$V/tls/openbao-server 700 0 0
$V/tls/openbao-client 700 0 0"

echo
echo "0. the test fails closed"
# No docker on PATH: a stub directory holding only dirname, which the script
# needs before it looks for docker.
NODOCKER=$(mktemp -d)
ln -s "$(command -v dirname)" "$NODOCKER/dirname"
SH_BIN=$(command -v sh)
out=$(PATH="$NODOCKER" "$SH_BIN" "$0" 2>&1); rc=$?
rm -rf "$NODOCKER"
check "with no docker the test exits non-zero" "$(yes_if [ "$rc" -ne 0 ])" "exit=$rc"
check "with no docker the message names docker" "$(yes_if contains docker "$out")" "$out"
check "with no docker nothing reports success or a skip" \
	"$(yes_if neither passed skip "$out")" "$out"

. "$ROOT/test/lib/f43-systemd.sh"
f43_systemd_image "$IMAGE" || exit 1
# The base image this one is built from has no systemd 258.7, so the version
# check must refuse it.
out=$(f43_systemd_is_pinned fedora:43); rc=$?
check "an image whose systemd is not $F43_SYSTEMD_VERSION is refused" "$(yes_if [ "$rc" -ne 0 ])" "$out"
check "the refusal names the version it wanted" "$(yes_if contains "not $F43_SYSTEMD_VERSION" "$out")" "$out"

CID=""
cleanup() { [ -n "$CID" ] && docker rm -f "$CID" >/dev/null 2>&1; CID=""; }
trap cleanup EXIT INT TERM

# No init needed: systemd-tmpfiles is run directly, which is exactly what
# systemd-tmpfiles-setup.service does on a node. Not privileged: nothing here
# mounts, and root in the container can chown without it.
CID=$(docker run -d --tmpfs /run --tmpfs /tmp \
	-v "$OVERLAY:/overlay:ro" "$IMAGE" sleep 900) \
	|| { echo "FAILED: could not start container"; exit 1; }
inside() { docker exec "$CID" sh -c "$*"; }
echo "in the container: $(inside 'systemd-tmpfiles --version | head -1')"
check "the container has no openbao user, so 990 works as a number or not at all" \
	"$(yes_if inside '! getent passwd 990 >/dev/null && ! getent group 990 >/dev/null')"

# The image's tmpfiles.d, whole, as a node runs it. The audit and the store
# rows of the shipped inventory: every row naming openbao* or tls, the sweep
# line included, so the file under test is the input and nothing is retyped.
inside 'mkdir -p /usr/lib/tmpfiles.d /usr/lib/rasputin/atrest && \
	cp /overlay/usr/lib/tmpfiles.d/rasputin.conf /usr/lib/tmpfiles.d/rasputin.conf && \
	cp /overlay/usr/lib/rasputin/atrest/rasputin-atrest-audit.sh /usr/lib/rasputin/atrest/audit.sh && \
	grep -E "^[^#]*[[:space:]]/var/lib/rasputin/(openbao|tls)" /overlay/usr/lib/rasputin/atrest/inventory \
		> /usr/lib/rasputin/atrest/store-inventory' >/dev/null
echo "store rows under test:"
inside 'sed "s/^/    /" /usr/lib/rasputin/atrest/store-inventory'

# tmpfiles — one run of the shipped file. Its output is kept: an error on any
# store line is a failure, while the lines this container cannot satisfy (the
# console master copy, the root CA the image bakes) are not this test's.
tmpfiles() { inside 'systemd-tmpfiles --create /usr/lib/tmpfiles.d/rasputin.conf 2>&1; true'; }
# tmpfiles names a line it rejects by file and line number ("rasputin.conf:112:
# Failed to resolve user ...") and a path it fails on by path, so both are
# matched: the store lines' numbers, taken from the shipped file, and the paths.
STORE_LINES=$(awk '$1 !~ /^#/ && $2 ~ /^\/var\/lib\/rasputin\/(openbao|tls)/ { printf "%s%d", sep, NR; sep = "|" }' "$TMPFILES")
[ -n "$STORE_LINES" ] || { echo "FAILED: no store lines found in $TMPFILES"; exit 1; }
store_errors() { printf '%s\n' "$1" | grep -E "rasputin\.conf:($STORE_LINES):|/var/lib/rasputin/(openbao|tls)" || true; }
# audit — the real script, as root, with no -u or -g: the production defaults.
# -q because a container has no kernel log of its own to write the verdict to.
audit() { inside 'sh /usr/lib/rasputin/atrest/audit.sh -i /usr/lib/rasputin/atrest/store-inventory -q; echo "rc=$?"'; }
stat_of() { inside "stat -c '%a %u %g' '$1' 2>/dev/null"; }
# all_as_declared — every directory has its expected mode and ids.
all_as_declared() {
	_bad=""
	while read -r _p _want; do
		_got=$(stat_of "$_p")
		[ "$_got" = "$_want" ] || _bad="$_bad $_p=($_got want $_want)"
	done <<EOF_EXPECTED
$EXPECTED
EOF_EXPECTED
	[ -z "$_bad" ] || { echo "$_bad"; return 1; }
}

echo
echo "1. from empty: a fresh node"
inside "mkdir -p $V && chmod 0755 $V" >/dev/null
out=$(tmpfiles)
errs=$(store_errors "$out")
check "tmpfiles reports nothing for any store line" "$(yes_if [ -z "$errs" ])" "$errs"
while read -r p want; do
	got=$(stat_of "$p")
	check "$p is $want" "$(yes_if [ "$got" = "$want" ])" "got: ${got:-missing}"
done <<EOF_EXPECTED
$EXPECTED
EOF_EXPECTED
check "tls is 700 0 0, not the 755 tmpfiles gives a missing parent" \
	"$(yes_if [ "$(stat_of $V/tls)" = '700 0 0' ])" "got: $(stat_of $V/tls)"
for d in openbao-seal tls/openbao-server tls/openbao-client; do
	n=$(inside "find $V/$d -mindepth 1 | wc -l")
	check "$d holds no files: tmpfiles creates no secret" "$(yes_if [ "$n" -eq 0 ])" "$(inside "ls -la $V/$d")"
done
out=$(audit)
check "the real audit over the shipped store rows says PASS checked=6" \
	"$(yes_if contains 'rasputin-atrest: PASS checked=6' "$out")" "$out"

echo
echo "2. an existing install: wrong owners, then widened modes, then a boot"
# Ownership first, with the modes still right: the audit stops at the first
# thing wrong with a path, so a widened mode would hide the owner finding.
inside "chown 0:0 $V/openbao $V/openbao-audit && chown 990:990 $V/tls/openbao-server" >/dev/null
out=$(audit)
check "the audit refuses the wrong owners" "$(yes_if contains 'rc=1' "$out")" "$out"
check "openbao owned by root is refused" \
	"$(yes_if contains "$V/openbao is owned by uid 0, not 990" "$out")" "$out"
check "openbao-audit owned by root is refused" \
	"$(yes_if contains "$V/openbao-audit is owned by uid 0, not 990" "$out")" "$out"
check "tls/openbao-server owned by the store is refused" \
	"$(yes_if contains "$V/tls/openbao-server is owned by uid 990, not 0" "$out")" "$out"
while read -r p want; do inside "chmod 0755 $p" >/dev/null; done <<EOF_EXPECTED
$EXPECTED
EOF_EXPECTED
out=$(audit)
check "the audit refuses the widened modes" "$(yes_if contains 'rc=1' "$out")" "$out"
while read -r p want; do
	check "$p at 0755 is refused" "$(yes_if contains "$p is 0755, declared 0700" "$out")" "$out"
done <<EOF_EXPECTED
$EXPECTED
EOF_EXPECTED
out=$(tmpfiles)
errs=$(store_errors "$out")
check "the re-run reports nothing for any store line" "$(yes_if [ -z "$errs" ])" "$errs"
bad=$(all_as_declared)
check "the re-run puts every directory back at its mode, owner and group" "$(yes_if [ -z "$bad" ])" "$bad"
out=$(audit)
check "the audit says PASS again" "$(yes_if contains 'rasputin-atrest: PASS checked=6' "$out")" "$out"

echo
echo "3. the OTA shape: what is already on the partition is kept"
# A node updated from a release without these lines: the api's tls/ and its
# leaf, a seal key and store data already present before tmpfiles first sees
# the new lines.
inside "rm -rf $V && mkdir -p $V/tls/api $V/openbao-seal $V/openbao && \
	chmod 0700 $V/tls $V/tls/api $V/openbao-seal $V/openbao && \
	head -c 64 /dev/urandom > $V/tls/api/leaf.key && chmod 0600 $V/tls/api/leaf.key && \
	head -c 64 /dev/urandom > $V/tls/api/leaf.pem && chmod 0644 $V/tls/api/leaf.pem && \
	head -c 32 /dev/urandom > $V/openbao-seal/seal-key && chmod 0600 $V/openbao-seal/seal-key && \
	head -c 64 /dev/urandom > $V/openbao/data.db && chmod 0600 $V/openbao/data.db" >/dev/null
# snapshot — every file under the store's paths and the api's tls/, with its
# sha256 and mode, sorted. Equal snapshots mean nothing was changed, created or
# removed.
snapshot() {
	inside "cd $V && find openbao openbao-audit openbao-seal tls -type f 2>/dev/null | sort | \
		while read -r f; do printf '%s %s %s\n' \"\$f\" \"\$(stat -c %a \"\$f\")\" \"\$(sha256sum < \"\$f\" | cut -d' ' -f1)\"; done"
}
before=$(snapshot)
check "the staged files are in place" \
	"$(yes_if [ "$(printf '%s\n' "$before" | grep -c .)" -eq 4 ])" "$before"
tmpfiles >/dev/null
tmpfiles >/dev/null
after=$(snapshot)
check "two runs keep every file's content and mode, and add or remove none" \
	"$(yes_if [ "$before" = "$after" ])" "before:
$before
after:
$after"
check "the api's leaf key is still 0600" \
	"$(yes_if contains 'tls/api/leaf.key 600 ' "$after")" "$after"
bad=$(all_as_declared)
check "the directories still end up as declared" "$(yes_if [ -z "$bad" ])" "$bad"

echo
if [ "$fails" -eq 0 ]; then
	echo "store-paths-functional: all checks passed"
else
	echo "store-paths-functional: $fails check(s) FAILED"
fi
[ "$fails" -eq 0 ]
