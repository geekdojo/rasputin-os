#!/bin/sh
# Tests for scripts/update-plan.sh, the update smoke's choice of published
# images to start from (geekdojo/geekdojo-brain#1012, TC-1012-13).
#
# How. Each case pipes a release-list fixture, the JSON `gh release list
# --json tagName,isDraft,isPrerelease,publishedAt` prints, into the script
# with a run tag and EXTRA, and reads the matrix or the refusal. Nothing here
# touches the network. The cases run under each shell in TEST_SHELLS
# (default: whichever of sh, dash and bash are installed).
#
# Run:  sh test/update-plan-test.sh
set -u
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
PLAN="$ROOT/scripts/update-plan.sh"
for f in "$ROOT/test/lib/checks.sh" "$PLAN"; do
	[ -f "$f" ] || { echo "FAILED: the file $f is missing."; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "FAILED: jq is not installed, and this suite needs it."; exit 1; }
# shellcheck source=test/lib/checks.sh
. "$ROOT/test/lib/checks.sh"

if [ -z "${UP_TEST_SHELL:-}" ]; then
	if [ -z "${TEST_SHELLS:-}" ]; then
		for s in sh dash bash; do
			command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="${TEST_SHELLS:-} $s"
		done
	fi
	rc=0
	for s in $TEST_SHELLS; do
		echo "== cases under $s"
		UP_TEST_SHELL=$s "$s" "$0" || rc=1
	done
	exit "$rc"
fi

# rel TAG DRAFT PRERELEASE DAY — one release, published on 2026-11-DAY.
rel() { printf '{"tagName":"%s","isDraft":%s,"isPrerelease":%s,"publishedAt":"2026-11-%sT00:00:00Z"}' "$1" "$2" "$3" "$4"; }
list() { printf '['; _sep=""; for r in "$@"; do printf '%s%s' "$_sep" "$r"; _sep=,; done; printf ']'; }

# plan LIST TAG [EXTRA] — sets OUT, RC and BASES (the matrix's bases, rows in order).
plan() {
	OUT=$(printf '%s' "$1" | EXTRA="${3:-}" "$UP_TEST_SHELL" "$PLAN" "$2" 2>&1); RC=$?
	BASES=$(printf '%s' "$OUT" | jq -r '[.include[] | "\(.arch)/\(.sku)/\(.base)"] | join(" ")' 2>/dev/null)
}

DEV="$(rel 2026.11.4-dev.400 false true 25)"
STABLE="$(rel 2026.11.3 false false 22)"
OLDER="$(rel 2026.11.2 false false 16)"
OLDDEV="$(rel 2026.11.3-dev.394 false true 20)"

echo "== bases (TC-1012-13)"
plan "$(list "$DEV" "$OLDDEV" "$STABLE" "$OLDER")" main
check "a dev newest and an older stable: both bases, both arches, 4 rows" \
	"$(yes_if test "$RC:$BASES" = "0:amd64/n100/2026.11.4-dev.400 arm64/rpi/2026.11.4-dev.400 amd64/n100/2026.11.3 arm64/rpi/2026.11.3")" "rc=$RC $OUT"

plan "$(list "$STABLE" "$OLDDEV" "$OLDER")" main
check "the stable is the newest published: one base, 2 rows" \
	"$(yes_if test "$RC:$BASES" = "0:amd64/n100/2026.11.3 arm64/rpi/2026.11.3")" "rc=$RC $OUT"

plan "$(list "$STABLE" "$OLDDEV" "$OLDER")" 2026.11.3
check "the run's own tag is the newest stable: the newest other release and the next older stable" \
	"$(yes_if test "$RC:$BASES" = "0:amd64/n100/2026.11.3-dev.394 arm64/rpi/2026.11.3-dev.394 amd64/n100/2026.11.2 arm64/rpi/2026.11.2")" "rc=$RC $OUT"

plan "$(list "$DEV" "$(rel 2026.11.5 true false 26)" "$STABLE")" main
check "a draft stable, even the newest, is never chosen" \
	"$(yes_if test "$RC:$BASES" = "0:amd64/n100/2026.11.4-dev.400 arm64/rpi/2026.11.4-dev.400 amd64/n100/2026.11.3 arm64/rpi/2026.11.3")" "rc=$RC $OUT"

plan "$(list "$DEV" "$OLDDEV" "$STABLE")" main
check "a prerelease is never chosen as the stable" "$(yes_if contains "amd64/n100/2026.11.3 " "$BASES ")" "$BASES"
check "the older prerelease is not a base at all" "$(yes_if test "$(printf '%s' "$BASES" | grep -c 2026.11.3-dev.394)" = 0)" "$BASES"

echo "== refusals (TC-1012-13)"
for c in "no stable|$(list "$DEV" "$OLDDEV" "$(rel 2026.11.5 true false 26)")|no published stable release" \
	"no published release|$(list "$(rel 2026.11.5 true false 26)")|no published release to update from" \
	"only the run's own tag|$(list "$STABLE")|no published release to update from" \
	"a list that is not JSON|not json|is not a JSON array"; do
	name=${c%%|*} rest=${c#*|}
	fixture=${rest%|*} said=${rest##*|}
	tag=main
	[ "$name" = "only the run's own tag" ] && tag=2026.11.3
	plan "$fixture" "$tag"
	check "$name: exit 1" "$(yes_if test "$RC" = 1)" "rc=$RC $OUT"
	check "$name: exactly one line, an ::error:: naming why" \
		"$(yes_if test "$(printf '%s\n' "$OUT" | wc -l | tr -d ' '):$(printf '%s\n' "$OUT" | grep -c "^::error::update-plan: .*$said")" = "1:1")" "$OUT"
done

echo "== EXTRA (TC-1012-13)"
plan "$(list "$DEV" "$STABLE")" main "2026.11.1, 2026.11.3,2026.11.1"
check "a good EXTRA entry is appended once, and one naming an existing base adds nothing" \
	"$(yes_if test "$RC:$BASES" = "0:amd64/n100/2026.11.4-dev.400 arm64/rpi/2026.11.4-dev.400 amd64/n100/2026.11.3 arm64/rpi/2026.11.3 amd64/n100/2026.11.1 arm64/rpi/2026.11.1")" "rc=$RC $OUT"
for bad in 'v2026.11.1' '2026.11.1;rm -rf /' '2026.11' '$(id)'; do
	plan "$(list "$DEV" "$STABLE")" main "2026.11.1,$bad"
	check "EXTRA entry '$bad' is refused: exit 1 and one ::error:: naming it" \
		"$(yes_if test "$RC:$(printf '%s\n' "$OUT" | grep -c "^::error::update-plan: update_smoke_from entry .* is not a CalVer release version")" = "1:1")" "rc=$RC $OUT"
done

if [ "$fails" -ne 0 ]; then
	echo "update-plan-test ($UP_TEST_SHELL): $fails failed"
	exit 1
fi
echo "update-plan-test ($UP_TEST_SHELL): all passed"
