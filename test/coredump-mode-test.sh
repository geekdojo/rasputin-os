#!/bin/sh
#
# Tests for usr/lib/rasputin/coredump/coredump-restrict-mode.sh — the
# ExecStopPost that tightens stored core dumps to 0600.
#
# Why. A core is a copy of a crashing process's memory, so its mode is an
# at-rest question; systemd hard-codes 0640 on a stored core and has no knob
# for it, which is why this script exists at all. The functional suite
# (test/coredump-functional.sh) proves systemd really runs it and that a core
# stored through the real path ends up 0600; this suite pins what the script
# does on its own, including the cases the functional test cannot stage: no
# store yet, a symlink in the store, a subdirectory.
#
# Shells. The image's /bin/sh is busybox ash, and the script leans on `find
# -exec ... +`, which not every find has. Every case runs under each shell in
# TEST_SHELLS (default: whichever of sh, dash and bash are installed) and, when
# busybox is present, once more with busybox's own applets ahead of PATH so the
# image's find and chmod are the ones exercised. REQUIRE_BUSYBOX=1 (CI sets it)
# turns a missing busybox into a failure rather than a silent skip.
#
# Run:  sh test/coredump-mode-test.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/board/rasputin/common/rootfs-overlay/usr/lib/rasputin/coredump/coredump-restrict-mode.sh"
[ -f "$SCRIPT" ] || { echo "missing: $SCRIPT" >&2; exit 2; }

if [ -z "${TEST_SHELLS:-}" ]; then
	TEST_SHELLS=""
	for s in sh dash bash; do
		command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"
	done
fi

BUSYBOX_DIR=""
if command -v busybox >/dev/null 2>&1; then
	BUSYBOX_DIR=$(mktemp -d)
	for applet in find chmod; do
		printf '#!/bin/sh\nexec busybox %s "$@"\n' "$applet" > "$BUSYBOX_DIR/$applet"
		chmod 0755 "$BUSYBOX_DIR/$applet"
	done
	TEST_SHELLS="$TEST_SHELLS busybox_applets"
elif [ -n "${REQUIRE_BUSYBOX:-}" ]; then
	echo "REQUIRE_BUSYBOX is set but busybox is not installed" >&2
	exit 2
fi

pass=0
fail=0
TMP=$(mktemp -d)
cleanup() {
	rm -rf "$TMP"
	[ -n "$BUSYBOX_DIR" ] && rm -rf "$BUSYBOX_DIR"
	return 0
}
trap cleanup EXIT

# run SHELL STORE — run the script against STORE, print "|rc=<status>".
run() {
	_sh=$1 _store=$2
	case "$_sh" in
		busybox_applets) PATH="$BUSYBOX_DIR:$PATH" busybox sh "$SCRIPT" "$_store" 2>&1; printf '|rc=%s' "$?" ;;
		*)               "$_sh" "$SCRIPT" "$_store" 2>&1; printf '|rc=%s' "$?" ;;
	esac
}

modeof() { ls -ld "$1" | cut -c1-10; }

check() {
	_label=$1 _want=$2 _got=$3
	if [ "$_want" = "$_got" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$_label" "$_want" "$_got" >&2
	fi
}

for sh_name in $TEST_SHELLS; do
	# A store that does not exist yet: before the bind mount, or when
	# Storage= keeps cores in the journal. Not an error.
	check "[$sh_name] a missing store is not an error" "|rc=0" \
		"$(run "$sh_name" "$TMP/does-not-exist")"

	# An empty store: nothing to do, still not an error.
	store="$TMP/$sh_name-empty"; mkdir -p "$store"
	check "[$sh_name] an empty store is not an error" "|rc=0" "$(run "$sh_name" "$store")"

	# The case that matters: what systemd leaves behind is 0640.
	store="$TMP/$sh_name-cores"; mkdir -p "$store"
	: > "$store/core.a.zst"; chmod 0640 "$store/core.a.zst"
	: > "$store/core.b.zst"; chmod 0644 "$store/core.b.zst"
	: > "$store/core.c.zst"; chmod 0600 "$store/core.c.zst"
	chmod 0700 "$store"
	out=$(run "$sh_name" "$store")
	check "[$sh_name] exits 0 and says nothing" "|rc=0" "$out"
	check "[$sh_name] 0640 becomes 0600" "-rw-------" "$(modeof "$store/core.a.zst")"
	check "[$sh_name] 0644 becomes 0600" "-rw-------" "$(modeof "$store/core.b.zst")"
	check "[$sh_name] 0600 is left alone" "-rw-------" "$(modeof "$store/core.c.zst")"
	check "[$sh_name] the store's own mode is untouched" "drwx------" "$(modeof "$store")"

	# A file in a subdirectory is still in the store.
	store="$TMP/$sh_name-nested"; mkdir -p "$store/sub"
	: > "$store/sub/core.d.zst"; chmod 0644 "$store/sub/core.d.zst"
	run "$sh_name" "$store" >/dev/null
	check "[$sh_name] a core in a subdirectory is tightened too" "-rw-------" \
		"$(modeof "$store/sub/core.d.zst")"

	# A symlink is not a regular file, so it is not followed: chmod through
	# one would change something outside the store.
	store="$TMP/$sh_name-link"; mkdir -p "$store"
	outside="$TMP/$sh_name-outside"; : > "$outside"; chmod 0644 "$outside"
	ln -s "$outside" "$store/core.link.zst"
	run "$sh_name" "$store" >/dev/null
	check "[$sh_name] a symlink out of the store is not followed" "-rw-r--r--" "$(modeof "$outside")"
done

printf '\ncoredump-restrict-mode: %d passed, %d failed (shells:%s)\n' "$pass" "$fail" "$TEST_SHELLS"
[ "$fail" -eq 0 ]
