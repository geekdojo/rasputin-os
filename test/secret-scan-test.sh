#!/bin/sh
#
# Tests for test/lib/secret-scan.sh, the one exact-needle scanner the host
# and the guest share, and for store-guest-checks.sh's scan after its exact
# counts moved there (geekdojo/geekdojo-brain#967, TC-967-09 and TC-967-10;
# F-967-02, F-967-03, F-967-07).
#
# Every needle and token is made at run time from /dev/urandom; none is a
# literal here. A fake journalctl first on PATH prints $FAKE_JOURNAL.
#
# Shells: each of TEST_SHELLS (default: dash and bash where installed, and
# `busybox sh` when busybox is installed). REQUIRE_BUSYBOX=1 (CI sets it)
# makes a missing busybox a failure.
#
# Run:  sh test/secret-scan-test.sh
set -u
LC_ALL=C
export LC_ALL

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
LIB="$ROOT/test/lib"
. "$LIB/checks.sh"
for f in secret-scan.sh store-guest-checks.sh; do
	[ -f "$LIB/$f" ] || { echo "FAILED: the file $LIB/$f is missing."; exit 1; }
done
if [ "${REQUIRE_BUSYBOX:-0}" = 1 ] && ! command -v busybox >/dev/null 2>&1; then
	echo "FAILED: REQUIRE_BUSYBOX=1 but busybox is not installed."
	exit 1
fi
if [ -z "${TEST_SHELLS:-}" ]; then
	TEST_SHELLS=""
	for s in dash bash; do command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"; done
	command -v busybox >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS busybox_sh"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat >"$TMP/bin/journalctl" <<'EOF'
#!/bin/sh
cat "$FAKE_JOURNAL"
EOF
chmod +x "$TMP/bin/journalctl"
PATH="$TMP/bin:$PATH"
export PATH

rand_hex() { od -An -N12 -tx1 /dev/urandom | tr -d ' \n'; }
rand_alnum() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24; }
lines() { printf '%s\n' "$1" | grep -c ''; }

# shell_run ARGS... — sh with $SH, so `busybox sh` is two words.
shell_run() {
	case "$SH" in
		busybox_sh) busybox sh "$@" ;;
		*) "$SH" "$@" ;;
	esac
}
# scan FUNCTION ARGS... — the library function under $SH; output in OUT, status in RC.
scan() {
	OUT=$(shell_run -c '. "$0"; "$@"' "$LIB/secret-scan.sh" "$@" 2>&1); RC=$?
}

for SH in $TEST_SHELLS; do
	echo "== under $SH"
	T="$TMP/$SH"
	mkdir -p "$T/tree/sub" "$T/tree/excluded"
	n1=$(rand_hex) n2=$(rand_hex) n3=$(rand_hex)
	printf '%s\n%s\n%s\n' "$n1" "$n2" "$n3" >"$T/needles"
	printf 'a text file\nwith %s inside\n' "$n1" >"$T/tree/text"
	{ printf 'bin\000\001\002'; printf '%s' "$n2"; printf '\000end'; } >"$T/tree/sub/binary"
	printf 'clean\n' >"$T/tree/clean"
	printf '%s\n' "$n3" >"$T/tree/excluded/hidden"

	# TC-967-09: text and binary hits counted, the excluded path not.
	scan scan_tree "$T/tree" "$T/needles" "$T/tree/excluded"
	check "TC-967-09 [$SH] scan_tree counts the text and binary hits, not the excluded one" \
		"$(yes_if test "$OUT" = "files=3 files_exact=2")" "$OUT"
	check "TC-967-09 [$SH] scan_tree returns 1 on a hit" "$(yes_if test "$RC" = 1)" "rc=$RC"
	check "TC-967-09 [$SH] scan_tree prints no needle text" \
		"$(yes_if test "$(printf '%s\n' "$OUT" | grep -c -F -f "$T/needles")" = 0)" "$OUT"
	check "TC-967-09 [$SH] scan_tree leaves no scratch file" "$(yes_if test ! -e "$T/needles.files")"
	scan scan_tree "$T/tree/excluded" "$T/needles" "$T/tree/excluded"
	check "TC-967-09 [$SH] scan_tree over zero files is INCONCLUSIVE, exit 2" \
		"$(yes_if test "$RC" = 2 -a "$(printf '%s\n' "$OUT" | tail -1)" = "INCONCLUSIVE files=0")" "rc=$RC $OUT"
	scan scan_tree "$T/tree" "$T/needles" "$T/tree/excluded" "$T/tree/text" "$T/tree/sub"
	check "TC-967-09 [$SH] scan_tree with no needle present returns 0" \
		"$(yes_if test "$RC" = 0 -a "$OUT" = "files=1 files_exact=0")" "rc=$RC $OUT"
	: >"$T/empty"
	scan scan_tree "$T/tree" "$T/empty"
	check "TC-967-09 [$SH] an empty needles file is INCONCLUSIVE, exit 2" \
		"$(yes_if test "$RC" = 2 -a "$OUT" = "INCONCLUSIVE needles=0")" "rc=$RC $OUT"
	scan scan_tree "$T/tree" "$T/no-such-file"
	check "TC-967-09 [$SH] a missing needles file is INCONCLUSIVE, exit 2" \
		"$(yes_if test "$RC" = 2 -a "$OUT" = "INCONCLUSIVE needles=0")" "rc=$RC $OUT"

	printf 'boot\nsession %s issued\nend\n' "$n2" >"$T/journal"
	FAKE_JOURNAL="$T/journal" scan scan_journal "$T/needles"
	check "TC-967-09 [$SH] scan_journal counts the journal hit" \
		"$(yes_if test "$RC" = 1 -a "$OUT" = "journal_lines=3 journal_exact=1")" "rc=$RC $OUT"
	printf 'boot\nend\n' >"$T/journal"
	FAKE_JOURNAL="$T/journal" scan scan_journal "$T/needles"
	check "TC-967-09 [$SH] scan_journal with no hit returns 0" \
		"$(yes_if test "$RC" = 0 -a "$OUT" = "journal_lines=2 journal_exact=0")" "rc=$RC $OUT"
	: >"$T/journal"
	FAKE_JOURNAL="$T/journal" scan scan_journal "$T/needles"
	check "TC-967-09 [$SH] zero journal lines is INCONCLUSIVE, exit 2" \
		"$(yes_if test "$RC" = 2 -a "$(printf '%s\n' "$OUT" | tail -1)" = "INCONCLUSIVE journal_lines=0")" "rc=$RC $OUT"
	FAKE_JOURNAL="$T/journal" scan scan_journal "$T/empty"
	check "TC-967-09 [$SH] scan_journal with an empty needles file is INCONCLUSIVE, exit 2" \
		"$(yes_if test "$RC" = 2)" "rc=$RC $OUT"

	# TC-967-10: the store scan, its keys and counts as before the extraction.
	G="$T/guest"
	mkdir -p "$G/out" "$G/persist/docker" "$G/persist/db"
	cp "$LIB/store-guest-checks.sh" "$LIB/secret-scan.sh" "$G/"
	api="s.$(rand_alnum)" rot="s.$(rand_alnum)" sentinel=$(rand_hex)
	printf '%s' "$api" >"$G/out/api.token"
	printf '%s' "$rot" >"$G/out/rotate.token"
	printf '%s' "$sentinel" >"$G/out/sentinel"
	printf 'row %s row\n' "$api" >"$G/persist/db/leak"
	printf 'value %s\n' "$sentinel" >"$G/persist/value"
	printf 'clean\n' >"$G/persist/clean"
	printf '%s\n' "$rot" >"$G/persist/docker/layer"
	printf 'one\ntoken %s seen\nthree\n' "$rot" >"$G/journal"
	SC=$(FAKE_JOURNAL="$G/journal" OUT="$G/out" ROTATE_LEAF="$G/rotate" PERSIST="$G/persist" \
		shell_run "$G/store-guest-checks.sh" scan 2>&1)
	keys=$(printf '%s\n' "$SC" | tr ' ' '\n' | cut -d= -f1 | tr '\n' ' ')
	check "TC-967-10 [$SH] the store scan prints the keys it printed before the extraction" \
		"$(yes_if test "$keys" = "grep_a needles control_bao_shape files files_vault_shape files_bao_shape files_exact journal_lines journal_vault_shape journal_bao_shape journal_exact ")" "$keys"
	want="grep_a=ok
needles=3
control_bao_shape=2
files=3
files_vault_shape=0 files_bao_shape=1 files_exact=2
journal_lines=3
journal_vault_shape=0 journal_bao_shape=1 journal_exact=1"
	check "TC-967-10 [$SH] the store scan counts the planted token, the sentinel and the journal hit" \
		"$(yes_if test "$SC" = "$want")" "$(printf '%s' "$SC" | tr '\n' '|')"
	check "TC-967-10 [$SH] the store scan prints no token or value" \
		"$(yes_if test "$(printf '%s\n' "$SC" | grep -c -F -f "$G/out/needles")" = 0)"
	rm "$G/secret-scan.sh"
	SC=$(FAKE_JOURNAL="$G/journal" OUT="$G/out" ROTATE_LEAF="$G/rotate" PERSIST="$G/persist" \
		shell_run "$G/store-guest-checks.sh" scan 2>&1)
	check "TC-967-10 [$SH] without secret-scan.sh beside it the store scan says so and prints no counts" \
		"$(yes_if test "$(printf '%s\n' "$SC" | tail -1)" = "secret_scan=missing" -a "$(lines "$SC")" = 4)" "$SC"
done

case "$TEST_SHELLS" in *busybox_sh*) ;; *) echo "  note: busybox is not installed; the busybox rows did not run" ;; esac
if [ "$fails" -ne 0 ]; then
	echo "secret-scan-test: $fails failed"
	exit 1
fi
echo "secret-scan-test: all passed"
