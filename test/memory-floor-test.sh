#!/bin/sh
#
# Table tests for scripts/memory-floor.sh, which writes the control plane's
# memory floor and the identity-service marker into the release manifest
# (geekdojo/geekdojo-brain#1011, TC-1011-01 to TC-1011-04).
#
# Why. A control plane refuses a fleet update whose release states a floor
# above its own memory, and refuses an identity release that states none. So
# a release signed with no floor, or a wrong one, either strands the fleet or
# lets an identity release onto a board too small to run it; and a marker
# read wrongly from the image (a keycloak-db.service, a drop-in directory)
# makes the reader demand a floor for a release without the identity service.
# The marker is read from real squashfs images built here with mksquashfs and
# listed by the real unsquashfs, as the sign job does.
#
# Every row checks stdout and the exit status. A refusal must also write
# nothing to stdout, so a half-written object never reaches the manifest.
#
# Needs mksquashfs, unsquashfs and jq. A missing tool is a failure, not a skip.
# The unreadable-rootfs row needs a non-root user (mode 000 does not stop
# root); run as root it fails rather than passing unproven.
#
# Shells: each shell in TEST_SHELLS (default: sh, dash and bash where
# installed), plus `busybox sh` when busybox is installed. REQUIRE_BUSYBOX=1
# (CI sets it) makes a missing busybox a failure.
#
# Run:  sh test/memory-floor-test.sh
set -u
LC_ALL=C
export LC_ALL

if [ "${REQUIRE_BUSYBOX:-0}" = "1" ] && ! command -v busybox >/dev/null 2>&1; then
	echo "FAILED: REQUIRE_BUSYBOX=1 but busybox is not installed." >&2
	exit 1
fi
for t in mksquashfs unsquashfs jq; do
	command -v "$t" >/dev/null 2>&1 || { echo "FAILED: $t is not installed; these tests need it." >&2; exit 1; }
done

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/memory-floor.sh"
[ -f "$SCRIPT" ] || { echo "FAILED: the file $SCRIPT is missing." >&2; exit 1; }

if [ -z "${TEST_SHELLS:-}" ]; then
	TEST_SHELLS=""
	for s in sh dash bash; do
		command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"
	done
	command -v busybox >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS busybox_sh"
fi

TMP=$(mktemp -d)
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# rootfs NAME [PATH...] — a real squashfs image $TMP/NAME.img holding an
# empty file at each PATH (plus an unrelated unit, so no image is empty).
rootfs() {
	_n=$1
	shift
	_d="$TMP/tree-$_n"
	mkdir -p "$_d/usr/lib/systemd/system"
	: > "$_d/usr/lib/systemd/system/sshd.service"
	for _p in "$@"; do
		mkdir -p "$_d/$(dirname "$_p")"
		: > "$_d/$_p"
	done
	if ! mksquashfs "$_d" "$TMP/$_n.img" -noappend -all-root -quiet >/dev/null 2>&1; then
		echo "FAILED: mksquashfs could not build the fixture $_n." >&2
		exit 1
	fi
}

rootfs plain
rootfs etc-unit etc/systemd/system/keycloak.service
rootfs lib-unit usr/lib/systemd/system/keycloak.service
rootfs db-only etc/systemd/system/keycloak-db.service usr/lib/systemd/system/keycloak-db.service
rootfs dropin-only etc/systemd/system/keycloak.service.d/override.conf usr/lib/systemd/system/keycloak.service.d/10-mem.conf
head -c 8192 /dev/urandom > "$TMP/random.img"
cp "$TMP/etc-unit.img" "$TMP/unreadable.img"
chmod 000 "$TMP/unreadable.img"

printf '3584\n' > "$TMP/floor.txt"
FLOOR="$TMP/floor.txt"
BYTES=3758096384 # 3584 x 1,048,576
PLAIN="{\"controlPlaneMemoryFloorBytes\":$BYTES}"
IDENT="{\"controlPlaneMemoryFloorBytes\":$BYTES,\"identityService\":true}"

pass=0 fail=0 SH=""
bad() {
	fail=$((fail + 1))
	printf '  FAIL [%s] %s: %s\n       rc=%s stdout=[%s] stderr=[%s]\n' \
		"$SH" "$1" "$2" "$RC" "$(cat "$TMP/out")" "$(cat "$TMP/err")" >&2
}

# run ARGS... — the script under $SH; status in RC, output in $TMP/out and
# $TMP/err.
run() {
	case "$SH" in
		busybox_sh) busybox sh "$SCRIPT" "$@" > "$TMP/out" 2> "$TMP/err" ;;
		*) "$SH" "$SCRIPT" "$@" > "$TMP/out" 2> "$TMP/err" ;;
	esac
	RC=$?
}

# emits LABEL WANT ARGS... — exit 0, stdout exactly WANT and valid JSON whose
# floor is 3584 MiB in bytes, stderr empty.
emits() {
	_l=$1 _want=$2
	shift 2
	run "$@"
	if [ "$RC" != 0 ]; then bad "$_l" "want exit 0"
	elif [ -s "$TMP/err" ]; then bad "$_l" "want empty stderr"
	elif [ "$(cat "$TMP/out")" != "$_want" ]; then bad "$_l" "want stdout '$_want'"
	elif [ "$(jq -r '.controlPlaneMemoryFloorBytes' < "$TMP/out" 2>/dev/null)" != "$((3584 * 1048576))" ]; then
		bad "$_l" "want jq to read controlPlaneMemoryFloorBytes as 3584 x 1048576"
	else pass=$((pass + 1)); fi
}

# refuses LABEL NAME ARGS... — exit 1, no stdout, stderr exactly one
# ::error::memory-floor: line naming NAME.
refuses() {
	_l=$1 _name=$2
	shift 2
	run "$@"
	if [ "$RC" != 1 ]; then bad "$_l" "want exit 1"
	elif [ -s "$TMP/out" ]; then bad "$_l" "want no stdout"
	elif [ "$(wc -l < "$TMP/err" | tr -d ' ')" != 1 ]; then bad "$_l" "want exactly one stderr line"
	elif ! grep -qF -- "::error::memory-floor: $_name:" "$TMP/err"; then bad "$_l" "want an ::error::memory-floor: line naming $_name"
	else pass=$((pass + 1)); fi
}

# usage LABEL ARGS... — exit 2, no stdout.
usage() {
	_l=$1
	shift
	run "$@"
	if [ "$RC" != 2 ]; then bad "$_l" "want exit 2"
	elif [ -s "$TMP/out" ]; then bad "$_l" "want no stdout"
	else pass=$((pass + 1)); fi
}

# bad_floor NAME CONTENT — a floor fixture $TMP/NAME holding CONTENT exactly
# (printf format, so '\n' is a newline); prints its path.
bad_floor() {
	# shellcheck disable=SC2059 # CONTENT is the format on purpose.
	printf -- "$2" > "$TMP/$1"
	printf '%s' "$TMP/$1"
}

for SH in $TEST_SHELLS; do
	echo "== $SH"

	# TC-1011-01: the floor, in bytes, for a rootfs with no identity unit.
	emits "floor 3584, no identity unit" "$PLAIN" "$FLOOR" "$TMP/plain.img"

	# TC-1011-02: identityService comes from the built rootfs.
	emits "(a) etc/systemd/system/keycloak.service" "$IDENT" "$FLOOR" "$TMP/etc-unit.img"
	emits "(b) usr/lib/systemd/system/keycloak.service" "$IDENT" "$FLOOR" "$TMP/lib-unit.img"
	emits "(c) keycloak-db.service only" "$PLAIN" "$FLOOR" "$TMP/db-only.img"
	emits "(d) keycloak.service.d drop-in only" "$PLAIN" "$FLOOR" "$TMP/dropin-only.img"
	emits "(e) no unit" "$PLAIN" "$FLOOR" "$TMP/plain.img"
	emits "(f) two SKUs, unit in the second" "$IDENT" "$FLOOR" "$TMP/plain.img" "$TMP/lib-unit.img"
	emits "(f) two SKUs, unit in the first" "$IDENT" "$FLOOR" "$TMP/etc-unit.img" "$TMP/plain.img"

	# TC-1011-03: the producer fails closed on the floor file.
	refuses "absent floor file" "$TMP/no-such-floor.txt" "$TMP/no-such-floor.txt" "$TMP/plain.img"
	for row in "empty|" "zero|0\n" "negative|-1\n" "fraction|9.5\n" "non-numeric|abc\n" \
		"two lines|3584\n3584\n" "leading plus|+3584\n"; do
		_f=$(bad_floor floor-bad.txt "${row#*|}")
		refuses "floor ${row%%|*}" "$_f" "$_f" "$TMP/plain.img"
	done

	# TC-1011-04: a rootfs nobody can list is refused; usage errors exit 2.
	refuses "missing rootfs" "$TMP/no-such.img" "$FLOOR" "$TMP/no-such.img"
	refuses "non-squashfs rootfs" "$TMP/random.img" "$FLOOR" "$TMP/random.img"
	refuses "one good, one non-squashfs" "$TMP/random.img" "$FLOOR" "$TMP/etc-unit.img" "$TMP/random.img"
	if [ "$(id -u)" = 0 ]; then
		RC=-; : > "$TMP/out"; : > "$TMP/err"
		bad "unreadable rootfs" "running as root, where mode 000 does not stop reading; run as a non-root user"
	else
		refuses "unreadable rootfs (mode 000)" "$TMP/unreadable.img" "$FLOOR" "$TMP/unreadable.img"
	fi
	usage "no arguments"
	usage "floor file only" "$FLOOR"
done

echo "memory-floor: $pass passed, $fail failed"
[ "$fail" = 0 ]
