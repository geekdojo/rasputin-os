#!/bin/sh
#
# Tests for the console root password on this image (geekdojo/geekdojo-brain#546):
# /usr/lib/rasputin/set-root-hash, and the image declarations that make it able
# to work at all.
#
# Why. Two failure modes here are silent and serious. One is a console that
# admits anybody — the image used to bake a single public password, the same on
# every download, reachable over BMC serial-over-LAN. The other is a helper
# that half-writes /etc/shadow: a corrupted row locks every account out of a
# headless box with no other way in. So every refusal below asserts that the
# file was not touched, and the success cases assert the whole file, not just
# root's field.
#
# The third thing checked is the arrangement that lets the control plane
# deliver a hash at all: /etc/shadow is a symlink onto the persistent
# partition, because the rootfs is a read-only squashfs. The helper has to
# write beside the RESOLVED file; a temp file beside the link would land on the
# squashfs and fail with EROFS on a real node, which no scratch-directory test
# would notice unless it looked for it. So the symlink case is explicit.
#
# How. The real script runs against a scratch shadow file through
# RASPUTIN_SHADOW_FILE. No root, no partitions, no systemd.
#
# Shells. Every case runs under each shell in TEST_SHELLS (default: whichever
# of sh, dash, bash and `busybox sh` are installed). REQUIRE_BUSYBOX=1 (CI sets
# it) fails the run when busybox is missing, since busybox ash is the image's
# /bin/sh.
#
# Run:  sh test/console-root-hash-test.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
SCRIPT="$OVERLAY/usr/lib/rasputin/set-root-hash"
TMPFILES="$OVERLAY/usr/lib/tmpfiles.d/rasputin.conf"
INVENTORY="$OVERLAY/usr/lib/rasputin/atrest/inventory"
POST_BUILD="$ROOT/board/rasputin/common/post-build.sh"
[ -f "$SCRIPT" ] || { echo "missing: $SCRIPT" >&2; exit 2; }

if [ -z "${TEST_SHELLS:-}" ]; then
	TEST_SHELLS=""
	for s in sh dash bash; do
		command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"
	done
	command -v busybox >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS busybox_sh"
fi
if [ "${REQUIRE_BUSYBOX:-0}" = "1" ] && ! command -v busybox >/dev/null 2>&1; then
	echo "FAIL: REQUIRE_BUSYBOX=1 but busybox is not installed" >&2
	exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
SH=""

ok() {
	if [ "$2" = 0 ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf '  FAIL [%s] %s\n' "$SH" "$1" >&2
		[ -n "${3:-}" ] && printf '       %s\n' "$3" | head -20 >&2
	fi
	return 0
}
yes_if() { if "$@"; then echo 0; else echo 1; fi; }
not_grep() { ! grep -qE "$1" "$2"; }
not_contains() { ! printf '%s' "$1" | grep -qF -- "$2"; }
contains_out() { printf '%s' "$OUT" | grep -qF -- "$1"; }

# A realistic shadow file: root locked as the image ships it, plus a second
# account, so a rewrite that dropped or mangled a row is visible.
LOCKED='*'
shadow_body() {
	printf 'root:%s:20000:0:99999:7:::\nnobody:!:20000:0:99999:7:::\n' "$1"
}

setup() {
	W=$(mktemp -d "$TMP/w.XXXXXX")
	S="$W/shadow"
	(umask 077 && shadow_body "$LOCKED" > "$S")
}

# run HASH_ON_STDIN [ARGS...] — run the helper; sets OUT (stdout+stderr) and RC.
run() {
	stdin_value="$1"; shift
	case "$SH" in
		busybox_sh) set -- busybox sh "$SCRIPT" "$@" ;;
		*)          set -- "$SH" "$SCRIPT" "$@" ;;
	esac
	OUT=$(printf '%s' "$stdin_value" | RASPUTIN_SHADOW_FILE="$TARGET" "$@" 2>&1)
	RC=$?
}

root_field() { awk -F: '$1=="root"{print $2; exit}' "$1"; }
file_mode() { ls -l "$1" 2>/dev/null | cut -c1-10; }
unchanged() { [ "$(cat "$S")" = "$(shadow_body "$LOCKED")" ]; }
no_leftovers() { [ -z "$(find "$(dirname "$S")" -name '*.rasputin.*' 2>/dev/null)" ]; }

cases() {
	GOOD='$6$rounds=100000$abcdefgh$OaYaNCzQ5LMOS2bLSX0Q1WLxbNRJqyqsRwbn3yEQ2t2ThEV5m9JGkRfkxGZ8aBvMLQdKiHVuGYCFFDf0iXo8Y1'

	# ── the hash is applied, and only root's field changes ──────────────
	setup; TARGET="$S"
	run "$GOOD"
	ok "a delivered hash is applied" "$(yes_if [ "$RC" = 0 ])" "$OUT"
	ok "root's field is exactly the delivered hash" "$(yes_if [ "$(root_field "$S")" = "$GOOD" ])" "$(cat "$S")"
	ok "every other row survives" \
		"$(yes_if grep -qx 'nobody:!:20000:0:99999:7:::' "$S")" "$(cat "$S")"
	ok "the file is still 0600" "$(yes_if [ "$(file_mode "$S")" = "-rw-------" ])" "$(file_mode "$S")"
	ok "no temp file is left behind" "$(yes_if no_leftovers)" "$(ls -a "$W")"
	ok "the hash is never printed" \
		"$(yes_if not_contains "$OUT" "$GOOD")" "$OUT"

	# ── idempotent: re-applying the same hash is a no-op ────────────────
	before=$(cat "$S")
	run "$GOOD"
	ok "re-applying the same hash succeeds" "$(yes_if [ "$RC" = 0 ])" "$OUT"
	ok "re-applying the same hash changes nothing" "$(yes_if [ "$(cat "$S")" = "$before" ])" "$(cat "$S")"

	# ── an explicit lock is accepted (the floor the image ships) ────────
	setup; TARGET="$S"
	run '*'
	ok "a lock token is accepted" "$(yes_if [ "$RC" = 0 ])" "$OUT"
	ok "root is locked" "$(yes_if [ "$(root_field "$S")" = '*' ])" "$(cat "$S")"

	# ── refusals: every one leaves the file exactly as it was ───────────
	for bad_desc in \
		'empty|' \
		'a plaintext password|hunter2' \
		'a bare word|rasputin' \
		'a value with a colon|$6$salt$hash:extra' \
		'a value with a space|$6$salt$ha sh' \
		'a $ with no second $|$notahash'
	do
		desc=${bad_desc%%|*}
		value=${bad_desc#*|}
		setup; TARGET="$S"
		run "$value"
		ok "refuses $desc" "$(yes_if [ "$RC" != 0 ])" "$OUT"
		ok "refusing $desc changes nothing" "$(yes_if unchanged)" "$(cat "$S")"
		ok "refusing $desc leaves no temp file" "$(yes_if no_leftovers)" "$(ls -a "$W")"
	done

	# A plaintext that HAPPENS to be the value an operator typed must never be
	# stored verbatim as if it were a hash — that is the whole reason this
	# takes a hash and not a password.
	setup; TARGET="$S"
	run 'correct horse battery staple'
	ok "a plaintext passphrase is refused" "$(yes_if [ "$RC" != 0 ])" "$OUT"
	ok "a plaintext passphrase never reaches the file" "$(yes_if unchanged)" "$(cat "$S")"

	# ── the argument form still works (an operator at a console) ────────
	setup; TARGET="$S"
	case "$SH" in
		busybox_sh) OUT=$(RASPUTIN_SHADOW_FILE="$S" busybox sh "$SCRIPT" "$GOOD" 2>&1); RC=$? ;;
		*)          OUT=$(RASPUTIN_SHADOW_FILE="$S" "$SH" "$SCRIPT" "$GOOD" 2>&1); RC=$? ;;
	esac
	ok "an argument is accepted too" "$(yes_if [ "$RC" = 0 ])" "$OUT"
	ok "the argument form applies the hash" "$(yes_if [ "$(root_field "$S")" = "$GOOD" ])" "$(cat "$S")"

	# ── THE image-shaped case: /etc/shadow is a symlink onto the
	#    persistent partition, and the rootfs holding the link is
	#    read-only. The temp file must be written beside the RESOLVED
	#    file; beside the link it would be EROFS on a real node.
	setup
	mkdir -p "$W/etc" "$W/persist/console"
	mv "$S" "$W/persist/console/shadow"
	S="$W/persist/console/shadow"
	ln -s "$W/persist/console/shadow" "$W/etc/shadow"
	TARGET="$W/etc/shadow"
	run "$GOOD"
	ok "a symlinked shadow is followed" "$(yes_if [ "$RC" = 0 ])" "$OUT"
	ok "the hash lands in the resolved file" "$(yes_if [ "$(root_field "$S")" = "$GOOD" ])" "$(cat "$S")"
	ok "/etc/shadow is still a symlink afterwards" "$(yes_if [ -L "$W/etc/shadow" ])" "$(ls -l "$W/etc")"
	ok "no temp file is left on the link's directory" \
		"$(yes_if [ -z "$(find "$W/etc" -name '*.rasputin.*' 2>/dev/null)" ])" "$(ls -a "$W/etc")"

	# A dangling link is refused rather than written through: it means the
	# persistent partition is not mounted, and a console that admits nobody
	# is the right state to leave alone.
	setup
	mkdir -p "$W/etc"
	ln -s "$W/persist/console/shadow" "$W/etc/shadow"
	TARGET="$W/etc/shadow"
	run "$GOOD"
	ok "a dangling shadow symlink is refused" "$(yes_if [ "$RC" != 0 ])" "$OUT"

	# A read-only shadow gives the reason the control plane reports for a node
	# that cannot take a password at all.
	setup; TARGET="$S"
	chmod 400 "$S"
	run "$GOOD"
	chmod 600 "$S"
	ok "an unwritable shadow is refused" "$(yes_if [ "$RC" != 0 ])" "$OUT"
	ok "an unwritable shadow says why" \
		"$(yes_if contains_out 'read-only')" "$OUT"
	ok "an unwritable shadow is unchanged" "$(yes_if unchanged)" "$(cat "$S")"

	# A shadow file with no root row is a file this helper does not understand.
	setup; TARGET="$S"
	printf 'nobody:!:20000:0:99999:7:::\n' > "$S"
	run "$GOOD"
	ok "a shadow with no root row is refused" "$(yes_if [ "$RC" != 0 ])" "$OUT"
}

for SH in $TEST_SHELLS; do
	echo "== $SH"
	cases
done

# ── image declarations — shell-independent, so checked once ─────────────────
SH=image

# The image must bake NO usable console password. This is the regression that
# matters most: one password on every image anyone downloads.
for cfg in "$ROOT"/configs/rasputin_*_defconfig; do
	name=$(basename "$cfg")
	ok "$name disables root password login" \
		"$(yes_if grep -qx 'BR2_TARGET_ENABLE_ROOT_LOGIN=n' "$cfg")" "$(grep -n ROOT_ "$cfg")"
	# The ASSIGNMENT, not a mention: the comment above the new setting names
	# the symbol it replaced, and that history is worth keeping.
	ok "$name assigns no root password" \
		"$(yes_if not_grep '^BR2_TARGET_GENERIC_ROOT_PASSWD=' "$cfg")" "$(grep -n ROOT_PASSWD "$cfg")"
done

# /etc/shadow has to be writable at runtime or nothing above can ever run on a
# real node: post-build moves it onto the persistent partition and keeps the
# build's copy as the master.
ok "post-build symlinks /etc/shadow onto the persistent partition" \
	"$(yes_if grep -q 'ln -s /var/lib/rasputin/console/shadow' "$POST_BUILD")" "$(grep -n shadow "$POST_BUILD")"
ok "post-build keeps the build's shadow as the master copy" \
	"$(yes_if grep -q 'usr/share/factory/rasputin' "$POST_BUILD")" "$(grep -n factory "$POST_BUILD")"
ok "post-build refuses a rootfs with a usable baked root password" \
	"$(yes_if grep -q 'usable password baked into the image' "$POST_BUILD")" "$(grep -n baked "$POST_BUILD")"

# tmpfiles seeds the persistent copy only when it is absent (C), so a delivered
# hash survives a reboot and an A/B update.
ok "tmpfiles creates the console directory 0700" \
	"$(yes_if grep -qx 'd /var/lib/rasputin/console 0700 root root -' "$TMPFILES")" "$(grep -n console "$TMPFILES")"
ok "tmpfiles copies the master shadow in only when absent" \
	"$(yes_if grep -qx 'C /var/lib/rasputin/console/shadow 0600 root root - /usr/share/factory/rasputin/shadow' "$TMPFILES")" "$(grep -n console "$TMPFILES")"

# The at-rest audit has to know about it, or a widened mode on the file that
# holds every account's hash would pass a release build.
ok "the at-rest inventory declares the console shadow 0600" \
	"$(yes_if grep -qE '^0600[[:space:]]+required[[:space:]]+/var/lib/rasputin/console/shadow$' "$INVENTORY")" "$(grep -n console "$INVENTORY")"
ok "the at-rest inventory declares the console directory 0700" \
	"$(yes_if grep -qE '^0700[[:space:]]+required[[:space:]]+/var/lib/rasputin/console$' "$INVENTORY")" "$(grep -n console "$INVENTORY")"

# The agent calls ONE path on both images. If this moves, the control plane's
# push fails on this image with a reason nobody can act on.
ok "the helper ships at the path both images share" \
	"$(yes_if [ -f "$OVERLAY/usr/lib/rasputin/set-root-hash" ])" "$(ls -l "$OVERLAY/usr/lib/rasputin")"
ok "the helper is executable" \
	"$(yes_if [ -x "$OVERLAY/usr/lib/rasputin/set-root-hash" ])" "$(ls -l "$OVERLAY/usr/lib/rasputin/set-root-hash")"

echo "console-root-hash: $pass passed, $fail failed (shells:$TEST_SHELLS)"
[ "$fail" -eq 0 ]
