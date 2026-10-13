#!/bin/sh
#
# Fixture tests for scripts/store-policy-drift.sh, which compares two copies of
# the secrets store's policy text (geekdojo/geekdojo-brain#804, TC-804-10).
#
# Why. The drift check is what keeps the image's policy text equal to the text
# rasputin-control-plane tests, and the post-build guard runs the same script.
# A check that passed two empty directories, or skipped an unreadable side,
# would pass a build with no policy at all (F-804-06). So every exit status is
# pinned against scratch fixtures: a match, a changed byte, a missing and an
# extra file (each named), an unreadable side, an empty side and bad usage.
#
# Shells: each shell in TEST_SHELLS (default: sh, dash and bash where
# installed), plus `busybox sh` when busybox is installed. REQUIRE_BUSYBOX=1
# (CI sets it) makes a missing busybox a failure. Not as root: root reads a
# mode-000 directory, so the unreadable case would prove nothing.
#
# Run:  sh test/store-policy-drift-test.sh
set -u
LC_ALL=C
export LC_ALL

if [ "$(id -u)" = 0 ]; then
	echo "FAILED: this suite must not run as root, because root reads a mode-000 directory and the unreadable case would prove nothing." >&2
	exit 1
fi
if [ "${REQUIRE_BUSYBOX:-0}" = "1" ] && ! command -v busybox >/dev/null 2>&1; then
	echo "FAILED: REQUIRE_BUSYBOX=1 but busybox is not installed." >&2
	exit 1
fi

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
DRIFT="$ROOT/scripts/store-policy-drift.sh"
[ -f "$DRIFT" ] || { echo "FAILED: the file $DRIFT is missing." >&2; exit 1; }

if [ -z "${TEST_SHELLS:-}" ]; then
	TEST_SHELLS=""
	for s in sh dash bash; do
		command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"
	done
fi
command -v busybox >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS busybox_sh"

TMP=$(mktemp -d)
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

pass=0 fail=0 SH=""
ok() {
	if [ "$2" = 0 ]; then pass=$((pass + 1)); else
		fail=$((fail + 1)); printf '  FAIL [%s] %s\n' "$SH" "$1" >&2
		[ -n "${3:-}" ] && printf '       %s\n' "$3" | head -20 >&2
	fi
	return 0
}
yes_if() { if "$@"; then echo 0; else echo 1; fi; }
has() { grep -qF -- "$2" "$1"; }

# pair — two directories holding the same two policies, and a Go file beside
# them on the B side, as rasputin-control-plane's storepolicy/ has.
pair() {
	W=$(mktemp -d "$TMP/w.XXXXXX")
	A="$W/a" B="$W/b"
	mkdir -p "$A" "$B"
	printf 'path "rasputin-secrets/data/apps/*" {\n  capabilities = ["read"]\n}\n' > "$A/rasputin-api.hcl"
	printf 'path "sys/rotate/root" {\n  capabilities = ["update", "sudo"]\n}\n' > "$A/rasputin-seal-rotate.hcl"
	cp "$A"/*.hcl "$B/"
	printf 'package storepolicy\n' > "$B/storepolicy.go"
}

# drift — the script under $SH on A and B; status in RC, stderr in $W/err.
drift() {
	case "$SH" in
		busybox_sh) busybox sh "$DRIFT" "$@" > "$W/out" 2> "$W/err" ;;
		*) "$SH" "$DRIFT" "$@" > "$W/out" 2> "$W/err" ;;
	esac
	RC=$?
}
# verdict LABEL RC NEEDLE... — the run exited RC and stderr (or stdout, for a
# match) names every NEEDLE.
verdict() {
	_l=$1 _want=$2; shift 2
	ok "$_l: exits $_want" "$(yes_if test "$RC" = "$_want")" "rc=$RC $(cat "$W/err" "$W/out")"
	for _n in "$@"; do
		ok "$_l: names '$_n'" "$(yes_if eval 'has "$W/err" "$_n" || has "$W/out" "$_n"')" "$(cat "$W/err" "$W/out")"
	done
}

cases() {
	pair; drift "$A" "$B"
	verdict "identical directories (the Go file on one side ignored)" 0 \
		"The policy files in $A and $B match: rasputin-api.hcl rasputin-seal-rotate.hcl."
	ok "identical directories: stderr is empty" "$(yes_if test ! -s "$W/err")" "$(cat "$W/err")"

	pair; printf 'path "rasputin-secrets/data/apps/*" {\n  capabilities = ["read"]\n}\n#' > "$B/rasputin-api.hcl"
	drift "$A" "$B"; verdict "one changed byte" 1 "The policy file rasputin-api.hcl differs between $A and $B."

	pair; rm "$B/rasputin-seal-rotate.hcl"
	drift "$A" "$B"; verdict "a file missing from B" 1 "The policy file rasputin-seal-rotate.hcl is in $A but missing from $B."

	pair; printf 'path "x" {\n  capabilities = ["read"]\n}\n' > "$B/rasputin-provisioner.hcl"
	drift "$A" "$B"; verdict "an extra file in B" 1 "The policy file rasputin-provisioner.hcl is in $B but not in $A."

	pair; rm "$A/rasputin-api.hcl"; printf 'x' > "$B/rasputin-seal-rotate.hcl"
	drift "$A" "$B"; verdict "a missing file and a changed one together" 1 \
		"rasputin-seal-rotate.hcl differs" "rasputin-api.hcl is in $B but not in $A."

	pair; chmod 000 "$B"; drift "$A" "$B"; chmod 0700 "$B"
	verdict "an unreadable side" 2 "The policy directory $B cannot be read, so the two copies cannot be compared."

	pair; chmod 000 "$B/rasputin-api.hcl"; drift "$A" "$B"; chmod 0600 "$B/rasputin-api.hcl"
	verdict "an unreadable file" 2 "The policy file rasputin-api.hcl cannot be read on both sides, so it cannot be compared."

	pair; drift "$A" "$W/none"
	verdict "a side that does not exist" 2 "The policy directory $W/none cannot be read"

	pair; rm "$A"/*.hcl "$B"/*.hcl; drift "$A" "$B"
	verdict "two empty directories" 2 "The policy directory $A holds no .hcl file, so there is nothing to compare."

	pair; rm "$B"/*.hcl; drift "$A" "$B"
	verdict "an empty B" 2 "The policy directory $B holds no .hcl file, so there is nothing to compare."

	pair; mkdir "$B/dir.hcl"; rm "$B/rasputin-api.hcl"; drift "$A" "$B"
	verdict "a directory named like a policy is not a policy" 1 "rasputin-api.hcl is in $A but missing from $B."

	pair; drift "$A"; verdict "one argument" 2 "Usage: "
	pair; drift "$A" ""; verdict "an empty argument" 2 "Usage: "
}

echo "store-policy drift tests, shells:$TEST_SHELLS"
for SH in $TEST_SHELLS; do cases; done
case "$TEST_SHELLS" in
	*busybox_sh*) SH=harness; ok "the busybox row ran" 0 ;;
	*) SH=harness; [ "${REQUIRE_BUSYBOX:-0}" = 1 ] && ok "the busybox row ran" 1 ;;
esac
echo "store-policy drift tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
