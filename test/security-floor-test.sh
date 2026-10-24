#!/bin/sh
#
# Table tests for scripts/security-floor.sh, which reads the security floor
# release.yml puts in manifest.json (geekdojo/geekdojo-brain#772, TC-772-18).
#
# Why. The floor raises a crit alert on every cluster whose nodes run an older
# version. A floor the script let through above its own release would name a
# version that release never reaches, so the alert would never clear; a floor
# it refused wrongly would stop a release that carries a fix. The ranking is
# the part that is easy to get wrong in shell: a zero-padded month (09) is not
# a number to $(( )) in dash, and a plain string compare puts 2026.10.10 below
# 2026.10.9. So each of those is a row here, along with the carry-forward of a
# floor across bases and every refusal.
#
# Every row checks stdout, stderr and the exit status. A row that passes must
# write nothing to stderr, and a row that refuses must write exactly one line
# naming the value, so a shell's own arithmetic or test(1) error cannot hide
# inside an expected failure.
#
# Shells: each shell in TEST_SHELLS (default: sh, dash and bash where
# installed), plus `busybox sh` when busybox is installed. REQUIRE_BUSYBOX=1
# (CI sets it) makes a missing busybox a failure.
#
# Run:  sh test/security-floor-test.sh
set -u
LC_ALL=C
export LC_ALL

if [ "${REQUIRE_BUSYBOX:-0}" = "1" ] && ! command -v busybox >/dev/null 2>&1; then
	echo "FAILED: REQUIRE_BUSYBOX=1 but busybox is not installed." >&2
	exit 1
fi

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
FLOOR="$ROOT/scripts/security-floor.sh"
[ -f "$FLOOR" ] || { echo "FAILED: the file $FLOOR is missing." >&2; exit 1; }

if [ -z "${TEST_SHELLS:-}" ]; then
	TEST_SHELLS=""
	for s in sh dash bash; do
		command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"
	done
	command -v busybox >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS busybox_sh"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0 SH=""
bad() {
	fail=$((fail + 1))
	printf '  FAIL [%s] %s: %s\n       rc=%s stdout=[%s] stderr=[%s]\n' \
		"$SH" "$1" "$2" "$RC" "$(cat "$TMP/out")" "$(cat "$TMP/err")" >&2
}

# run FILE RELEASE — the script under $SH; status in RC, output in $TMP/out
# and $TMP/err.
run() {
	case "$SH" in
		busybox_sh) busybox sh "$FLOOR" "$@" > "$TMP/out" 2> "$TMP/err" ;;
		*) "$SH" "$FLOOR" "$@" > "$TMP/out" 2> "$TMP/err" ;;
	esac
	RC=$?
}

# floor_file VALUE — a fixture security-floor.txt holding VALUE and a newline,
# as an editor leaves it; prints its path.
floor_file() {
	printf '%s\n' "$1" > "$TMP/security-floor.txt"
	printf '%s' "$TMP/security-floor.txt"
}

# accepts LABEL FILE RELEASE WANT — exit 0, stdout exactly WANT (empty WANT:
# no output at all), stderr empty.
accepts() {
	_l=$1 _want=$4
	run "$2" "$3"
	if [ "$RC" != 0 ]; then bad "$_l" "want exit 0"
	elif [ -s "$TMP/err" ]; then bad "$_l" "want empty stderr"
	elif [ -z "$_want" ] && [ -s "$TMP/out" ]; then bad "$_l" "want no output"
	elif [ -n "$_want" ] && [ "$(cat "$TMP/out")" != "$_want" ]; then bad "$_l" "want stdout '$_want'"
	else pass=$((pass + 1)); fi
}

# refuses LABEL FILE RELEASE VALUE — exit 1, no stdout, stderr one line naming
# VALUE.
refuses() {
	_l=$1 _v=$4
	run "$2" "$3"
	if [ "$RC" != 1 ]; then bad "$_l" "want exit 1"
	elif [ -s "$TMP/out" ]; then bad "$_l" "want no stdout"
	elif [ "$(wc -l < "$TMP/err" | tr -d ' ')" != 1 ]; then bad "$_l" "want exactly one stderr line"
	elif ! grep -qF -- "'$_v'" "$TMP/err"; then bad "$_l" "want stderr naming '$_v'"
	else pass=$((pass + 1)); fi
}

for SH in $TEST_SHELLS; do
	echo "== $SH"

	# TC-772-18: the empty file and the absent file both mean "no floor".
	: > "$TMP/empty.txt"
	accepts "empty file" "$TMP/empty.txt" 2026.10.2 ""
	accepts "absent file" "$TMP/no-such-file.txt" 2026.10.2 ""

	# TC-772-18: floors at or below the release are printed.
	accepts "equal stable"                 "$(floor_file 2026.10.2)"         2026.10.2         2026.10.2
	accepts "older dev on same-base dev"   "$(floor_file 2026.10.2-dev.300)" 2026.10.2-dev.305 2026.10.2-dev.300
	accepts "dev floor on its stable"      "$(floor_file 2026.10.2-dev.300)" 2026.10.2         2026.10.2-dev.300
	accepts "zero-padded month"            "$(floor_file 2026.09.6-dev.276)" 2026.09.6-dev.280 2026.09.6-dev.276
	accepts "older base, stable"           "$(floor_file 2026.08.4)"         2026.09.1         2026.08.4
	accepts "carry-forward across bases"   "$(floor_file 2026.09.6-dev.276)" 2026.10.1-dev.303 2026.09.6-dev.276
	accepts "numeric patch"                "$(floor_file 2026.10.9)"         2026.10.10        2026.10.9

	# TC-772-18: refusals, each naming the value on stderr.
	refuses "not a version"                "$(floor_file not-a-version)"     2026.10.2         not-a-version
	refuses "stable floor on its dev"      "$(floor_file 2026.10.2)"         2026.10.2-dev.305 2026.10.2
	refuses "newer dev on same-base dev"   "$(floor_file 2026.10.2-dev.310)" 2026.10.2-dev.305 2026.10.2-dev.310
	refuses "higher base"                  "$(floor_file 2026.11.0-dev.1)"   2026.10.2         2026.11.0-dev.1
	refuses "numeric patch, above"         "$(floor_file 2026.10.10)"        2026.10.9         2026.10.10

	# The script's own exit 2: a release version it cannot rank against fails
	# the release rather than letting any floor through.
	run "$(floor_file 2026.10.2)" v2026.10.2
	if [ "$RC" != 2 ] || [ -s "$TMP/out" ] || ! grep -qF "'v2026.10.2'" "$TMP/err"; then
		bad "non-CalVer release version" "want exit 2 naming the version"
	else pass=$((pass + 1)); fi
done

echo "security-floor: $pass passed, $fail failed"
[ "$fail" = 0 ]
