#!/bin/sh
#
# Tests for scripts/fetch-vendored.sh, release.yml's fetch of the pinned
# control-plane tarballs into Buildroot's dl/ cache.
#
# Why. The retry exists for one network fault that a pull request never sees
# (run 40229531683: `connection reset by peer` from the release CDN), so its
# branches would otherwise run for the first time inside a release build. A
# stub `gh` on PATH plays a scripted sequence of outcomes, one per call: ok
# (writes the pinned bytes), bad (exits 0 but writes other bytes, a truncated
# download) and fail (writes a partial file and exits 1). Each row checks the
# exit status, how many times gh was called, the output, and what is left in
# dl/: a matching tarball after a pass, nothing after a refusal.
#
# Shells: each shell in TEST_SHELLS (default: sh, dash and bash where
# installed), plus `busybox sh` when busybox is installed. REQUIRE_BUSYBOX=1
# makes a missing busybox a failure.
#
# Needs: openssl, awk, sed. No network, no GitHub.
# Run:  sh test/fetch-vendored-test.sh
set -u
LC_ALL=C
export LC_ALL

if [ "${REQUIRE_BUSYBOX:-0}" = "1" ] && ! command -v busybox >/dev/null 2>&1; then
	echo "FAILED: REQUIRE_BUSYBOX=1 but busybox is not installed." >&2
	exit 1
fi

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
FETCH="$ROOT/scripts/fetch-vendored.sh"
[ -f "$FETCH" ] || { echo "FAILED: the file $FETCH is missing." >&2; exit 1; }
# shellcheck source=test/lib/checks.sh
. "$ROOT/test/lib/checks.sh"

if [ -z "${TEST_SHELLS:-}" ]; then
	TEST_SHELLS=""
	for s in sh dash bash; do
		command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"
	done
	command -v busybox >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS busybox_sh"
fi

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# Fixture ROOT: two packages pinned to v1.2.3, each with a .hash line for the
# amd64 tarball made from known bytes.
fix="$tmp/root"
for pkg in rasputin-agent rasputin-api; do
	var=$(printf '%s' "$pkg" | tr 'a-z-' 'A-Z_')
	mkdir -p "$fix/package/$pkg" "$tmp/assets"
	printf '%s_VERSION = 1.2.3\n' "$var" >"$fix/package/$pkg/$pkg.mk"
	src="$pkg-1.2.3-linux-amd64.tar.gz"
	printf 'pinned bytes of %s\n' "$pkg" >"$tmp/assets/$src"
	sum=$(openssl dgst -sha256 -r "$tmp/assets/$src" | cut -d' ' -f1)
	printf '# fixture\nsha256  %s  %s\n' "$sum" "$src" >"$fix/package/$pkg/$pkg.hash"
done
# A package whose .hash has no line for the tarball, and one with no version.
mkdir -p "$fix/package/rasputin-nohash" "$fix/package/rasputin-nover"
printf 'RASPUTIN_NOHASH_VERSION = 1.2.3\n' >"$fix/package/rasputin-nohash/rasputin-nohash.mk"
printf '# empty\n' >"$fix/package/rasputin-nohash/rasputin-nohash.hash"
printf '# no version\n' >"$fix/package/rasputin-nover/rasputin-nover.mk"

# Stub gh: pops the next outcome from $tmp/plan, logs its args to $tmp/calls.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_DIR/calls"
outcome=$(head -n 1 "$STUB_DIR/plan")
sed '1d' "$STUB_DIR/plan" >"$STUB_DIR/plan.next" && mv "$STUB_DIR/plan.next" "$STUB_DIR/plan"
tag=$3 pattern= dir=
while [ "$#" -gt 0 ]; do
	case "$1" in
		--pattern) pattern=$2; shift ;;
		--dir) dir=$2; shift ;;
	esac
	shift
done
[ "$tag" = "v1.2.3" ] || { echo "stub gh: unexpected tag $tag" >&2; exit 9; }
case "$outcome" in
	ok) cp "$STUB_DIR/assets/$pattern" "$dir/$pattern" ;;
	bad) printf 'truncated' >"$dir/$pattern" ;;
	fail) printf 'part' >"$dir/$pattern"; echo "read: connection reset by peer" >&2; exit 1 ;;
	*) echo "stub gh: plan exhausted" >&2; exit 9 ;;
esac
EOF
chmod +x "$tmp/bin/gh"
STUB_DIR=$tmp
export STUB_DIR

# row SHELL NAME PLAN WANT_STATUS WANT_CALLS WANT_OUTPUT WANT_FILES PKG...
# PLAN is space-separated outcomes. WANT_FILES lists the tarballs that must be
# in dl/ afterwards ("" = none at all).
row() {
	sh_=$1 name=$2 plan=$3 want_status=$4 want_calls=$5 want_output=$6 want_files=$7
	shift 7
	rm -rf "$tmp/dl" "$tmp/calls"
	: >"$tmp/calls"
	printf '%s\n' "$plan" | tr ' ' '\n' >"$tmp/plan"
	status=0
	if [ "$sh_" = busybox_sh ]; then
		output=$(PATH="$tmp/bin:$PATH" busybox sh "$FETCH" "$fix" amd64 "$tmp/dl" "$@" 2>&1) || status=$?
	else
		output=$(PATH="$tmp/bin:$PATH" "$sh_" "$FETCH" "$fix" amd64 "$tmp/dl" "$@" 2>&1) || status=$?
	fi
	calls=$(wc -l <"$tmp/calls" | tr -d ' ')
	files=$(cd "$tmp" && find dl -type f 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')
	ok=0 detail=
	if [ "$status" != "$want_status" ]; then ok=1 detail="exit $status, want $want_status"
	elif [ "$calls" != "$want_calls" ]; then ok=1 detail="gh called $calls times, want $want_calls"
	elif ! contains "$want_output" "$output"; then ok=1 detail="output lacks '$want_output'"
	elif [ "$files" != "$want_files" ]; then ok=1 detail="dl/ holds '$files', want '$want_files'"
	else
		bytes=$(printf '%s\n' "$want_files" | tr ' ' '\n' | while IFS= read -r f; do
			[ -z "$f" ] || cmp -s "$tmp/$f" "$tmp/assets/${f##*/}" || echo "$f"
		done)
		[ -z "$bytes" ] || { ok=1 detail="not the pinned bytes: $bytes"; }
	fi
	check "[$sh_] $name" "$ok" "$detail
$output"
}

A=dl/rasputin-agent/rasputin-agent-1.2.3-linux-amd64.tar.gz
P=dl/rasputin-api/rasputin-api-1.2.3-linux-amd64.tar.gz
for s in $TEST_SHELLS; do
	row "$s" "first attempt matches" "ok" 0 1 "matches package/rasputin-agent/rasputin-agent.hash" "$A" rasputin-agent
	row "$s" "a failed download is retried" "fail ok" 0 2 "failed on attempt 1 of 3" "$A" rasputin-agent
	row "$s" "a hash mismatch is retried" "bad ok" 0 2 "does not match package/rasputin-agent/rasputin-agent.hash on attempt 1 of 3" "$A" rasputin-agent
	row "$s" "the last attempt still counts" "fail bad ok" 0 3 "attempt 3 of 3" "$A" rasputin-agent
	row "$s" "three failed downloads refuse" "fail fail fail ok" 1 3 "::error::could not fetch rasputin-agent-1.2.3-linux-amd64.tar.gz" "" rasputin-agent
	row "$s" "three mismatches refuse and leave no file" "bad bad bad ok" 1 3 "after 3 attempts" "" rasputin-agent
	row "$s" "each package gets its own attempts" "fail fail ok fail ok" 0 5 "matches package/rasputin-api/rasputin-api.hash" "$A $P" rasputin-agent rasputin-api
	row "$s" "a missing hash line refuses before any download" "ok" 1 0 "has no sha256 line for rasputin-nohash-1.2.3-linux-amd64.tar.gz" "" rasputin-nohash
	row "$s" "a missing version refuses before any download" "ok" 1 0 "could not parse RASPUTIN_NOVER_VERSION" "" rasputin-nover
done

# Usage errors, once: no network, so the shell does not matter.
status=0; out=$(sh "$FETCH" "$fix" riscv64 "$tmp/dl" rasputin-agent 2>&1) || status=$?
check "an unknown ARCH is a usage error" "$(yes_if [ "$status" = 2 ])" "exit $status: $out"
status=0; out=$(sh "$FETCH" "$fix" amd64 "$tmp/dl" 2>&1) || status=$?
check "no PKG is a usage error" "$(yes_if [ "$status" = 2 ])" "exit $status: $out"

if [ "$fails" -ne 0 ]; then
	echo "FAILED: $fails check(s) failed."
	exit 1
fi
echo "PASSED"
