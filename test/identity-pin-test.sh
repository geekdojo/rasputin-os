#!/bin/sh
# Tests for package/keycloak/check-pins.sh, the pre-build hook that fails the
# build when the api tarball's identity/pins.json names a different Keycloak or
# JRE than this tree pins (geekdojo/geekdojo-brain#971).
#
#   TC-971-01  keycloak.release differs: exit 1, one sentence naming the
#              field, both values and the fix order.
#   TC-971-02  each other field differs alone: exit 1 naming it and both
#              values; every field equal: exit 0.
#   TC-971-03  every input it cannot read refuses with a sentence.
#   TC-971-11  the real run: the pinned rasputin-api tarball, checked against
#              rasputin-api.hash, and its identity/pins.json against the real
#              .mk and .hash values. Red until the api pin carries identity/,
#              by design: the image would not build either.
#
# The fixtures are made from the real pins, read with real GNU make
# (test/lib/mk-var.sh), so a bump moves them too. No make or jq is a failure,
# not a skip.
#
# RASPUTIN_API_TARBALL=<local api tarball> runs TC-971-11 against a local
# control-plane build instead of the pin, saying so on a LOCAL OVERRIDE: line
# (test/lib/api-tarball.sh). CI never sets it.
#
# Needs: GNU make, jq, curl, openssl, tar.
# Run:   sh test/identity-pin-test.sh
set -u
LC_ALL=C
export LC_ALL

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
CHECK="$ROOT/package/keycloak/check-pins.sh"
KC_MK="$ROOT/package/keycloak/keycloak.mk"
KC_HASH="$ROOT/package/keycloak/keycloak.hash"
JRE_MK="$ROOT/package/temurin-jre/temurin-jre.mk"
JRE_HASH="$ROOT/package/temurin-jre/temurin-jre.hash"
for t in make jq curl openssl tar; do
	command -v "$t" >/dev/null 2>&1 || { echo "FAILED: this test needs $t, and it is not on PATH." >&2; exit 1; }
done
for f in "$CHECK" "$KC_MK" "$KC_HASH" "$JRE_MK" "$JRE_HASH" "$ROOT/test/lib/mk-var.sh" \
	"$ROOT/test/lib/api-tarball.sh" "$ROOT/test/lib/checks.sh"; do
	[ -f "$f" ] || { echo "FAILED: the file $f is missing." >&2; exit 1; }
done
. "$ROOT/test/lib/mk-var.sh"
. "$ROOT/test/lib/api-tarball.sh"
. "$ROOT/test/lib/checks.sh"
JQ_BIN=$(command -v jq)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

# The real pins, as Buildroot evaluates them. The x64 JRE tarball comes from
# keycloak.mk's own derivation, evaluated with temurin-jre.mk beside it, as the
# hook receives it.
printf 'include %s\ninclude %s\n' "$JRE_MK" "$KC_MK" > "$TMP/both.mk"
ON="BR2_PACKAGE_TEMURIN_JRE=y BR2_x86_64=y BR2_ARCH=x86_64 HOSTARCH=x86_64"
# shellcheck disable=SC2086 # ON is split on purpose
KC_V=$(mk_var "$KC_MK" KEYCLOAK_VERSION) \
	&& KC_TGZ=$(mk_var "$KC_MK" KEYCLOAK_SOURCE) \
	&& JRE_V=$(mk_var "$JRE_MK" TEMURIN_JRE_VERSION) \
	&& JRE_TGZ=$(mk_var "$TMP/both.mk" KEYCLOAK_JRE_X64_TARBALL $ON) \
	|| { echo "FAILED: could not read the pins, so nothing below has anything to compare against." >&2; exit 1; }
sha_line() { awk -v t="$2" '$1 == "sha256" && $3 == t { print $2 }' "$1"; }
KC_SHA=$(sha_line "$KC_HASH" "$KC_TGZ")
JRE_SHA=$(sha_line "$JRE_HASH" "$JRE_TGZ")
[ -n "$KC_SHA" ] && [ -n "$JRE_SHA" ] \
	|| { echo "FAILED: keycloak.hash or temurin-jre.hash has no line for $KC_TGZ or $JRE_TGZ." >&2; exit 1; }
echo "pins: Keycloak $KC_V ($KC_TGZ $KC_SHA), JRE $JRE_V ($JRE_TGZ $JRE_SHA)"

# fixture NAME JQ_FILTER — pins.json in pack-identity.sh's schema with the real
# values, then the filter applied.
fixture() {
	"$JQ_BIN" -n --arg kr "$KC_V" --arg ks "$KC_SHA" --arg jr "$JRE_V" --arg js "$JRE_SHA" \
		'{keycloak: {release: $kr, sha256: $ks}, jre: {release: $jr, linux_x64_sha256: $js}}' \
		| "$JQ_BIN" "$2" > "$TMP/$1.json"
}
# run PINS [ENV...] — the hook as keycloak.mk calls it, with JQ from ENV
# (default the host jq). Leaves RC, OUT and ERR.
run() {
	_p=$1; shift
	[ "$#" -gt 0 ] || set -- JQ="$JQ_BIN"
	OUT=$(env -u JQ "$@" "$CHECK" "$_p" "$KC_V" "$KC_HASH" "$KC_TGZ" "$JRE_V" "$JRE_HASH" "$JRE_TGZ" 2> "$TMP/err")
	RC=$?
	ERR=$(cat "$TMP/err")
}
eq() { [ "$1" = "$2" ] && echo 0 || echo 1; }
FIX="change control-plane identitytest/pin.go first, then cut a control-plane release, then move the OS api pin and this pin together."
mismatch() { # mismatch FIELD API OS WHERE — the sentence check-pins.sh prints
	echo "The api's pins.json has $1 $2 but $4 has $3, so this image would ship a Keycloak and JRE pairing control-plane CI never ran; $FIX"
}

echo "── TC-971-01 keycloak.release differs"
fixture kc-release '.keycloak.release = "26.8.1"'
run "$TMP/kc-release.json"
check "TC-971-01 exits 1" "$(eq "$RC" 1)" "rc=$RC"
check "TC-971-01 one sentence naming the field, both values and the fix order" \
	"$(eq "$ERR" "$(mismatch keycloak.release 26.8.1 "$KC_V" package/keycloak/keycloak.mk)")" "$ERR"
check "TC-971-01 no success line" "$(eq "$OUT" "")" "$OUT"

echo "── TC-971-02 each other field, and all equal"
W64=$(printf '%064d' 0)
# row NAME FILTER FIELD API OS WHERE
row() {
	fixture "$1" "$2"
	run "$TMP/$1.json"
	check "TC-971-02 $3 differs: exits 1" "$(eq "$RC" 1)" "rc=$RC"
	check "TC-971-02 $3 differs: names it and both values" "$(eq "$ERR" "$(mismatch "$3" "$4" "$5" "$6")")" "$ERR"
}
row kc-sha ".keycloak.sha256 = \"$W64\"" keycloak.sha256 "$W64" "$KC_SHA" package/keycloak/keycloak.hash
row jre-release '.jre.release = "25.0.4+7"' jre.release 25.0.4+7 "$JRE_V" package/temurin-jre/temurin-jre.mk
row jre-sha ".jre.linux_x64_sha256 = \"$W64\"" jre.linux_x64_sha256 "$W64" "$JRE_SHA" package/temurin-jre/temurin-jre.hash
fixture equal .
run "$TMP/equal.json"
check "TC-971-02 every field equal: exits 0" "$(eq "$RC" 0)" "rc=$RC: $ERR"
check "TC-971-02 every field equal: the success line" \
	"$(eq "$OUT" "check-pins: the api's pins.json agrees with this image's pins (Keycloak $KC_V, JRE $JRE_V).")" "$OUT"
check "TC-971-02 every field equal: nothing on stderr" "$(eq "$ERR" "")" "$ERR"

echo "── TC-971-03 fails closed"
# closed LABEL WANT PINS [ENV...]
closed() {
	_l=$1 _w=$2; shift 2
	run "$@"
	check "TC-971-03 $_l: exits 1" "$(eq "$RC" 1)" "rc=$RC"
	check "TC-971-03 $_l: the sentence" "$(eq "$ERR" "$_w")" "$ERR"
	check "TC-971-03 $_l: no success line" "$(eq "$OUT" "")" "$OUT"
}
P="Cannot check the identity pins, because"
closed "pins.json absent" "$P $TMP/absent.json does not exist: the api tarball carries no identity/pins.json." "$TMP/absent.json"
: > "$TMP/empty.json"
closed "pins.json empty" "$P $TMP/empty.json is empty." "$TMP/empty.json"
printf '{"keycloak": \n' > "$TMP/broken.json"
closed "pins.json not JSON" "$P $TMP/broken.json is not a JSON object." "$TMP/broken.json"
for f in .keycloak.release .keycloak.sha256 .jre.release .jre.linux_x64_sha256; do
	fixture missing "del($f)"
	closed "$f missing" "$P $TMP/missing.json has no $f, or it is empty." "$TMP/missing.json"
done
fixture blank '.jre.release = ""'
closed ".jre.release empty" "$P $TMP/blank.json has no .jre.release, or it is empty." "$TMP/blank.json"
closed "JQ unset" "$P JQ is not set." "$TMP/equal.json" PATH="$PATH"
printf 'not a program\n' > "$TMP/jq-noexec"
closed "JQ not executable" "$P JQ ($TMP/jq-noexec) is not an executable file." "$TMP/equal.json" JQ="$TMP/jq-noexec"
# The hash files: copies, so the real ones are never touched.
grep -v " $KC_TGZ\$" "$KC_HASH" > "$TMP/no-line.hash"
OUT=$(JQ="$JQ_BIN" "$CHECK" "$TMP/equal.json" "$KC_V" "$TMP/no-line.hash" "$KC_TGZ" "$JRE_V" "$JRE_HASH" "$JRE_TGZ" 2> "$TMP/err"); RC=$?; ERR=$(cat "$TMP/err")
check "TC-971-03 hash file with no line for the tarball: exits 1" "$(eq "$RC" 1)" "rc=$RC"
check "TC-971-03 hash file with no line for the tarball: the sentence" \
	"$(eq "$ERR" "$P $TMP/no-line.hash has 0 sha256 lines for $KC_TGZ, and needs exactly one.")" "$ERR"
cp "$JRE_HASH" "$TMP/unreadable.hash"; chmod 000 "$TMP/unreadable.hash"
OUT=$(JQ="$JQ_BIN" "$CHECK" "$TMP/equal.json" "$KC_V" "$KC_HASH" "$KC_TGZ" "$JRE_V" "$TMP/unreadable.hash" "$JRE_TGZ" 2> "$TMP/err"); RC=$?; ERR=$(cat "$TMP/err")
check "TC-971-03 unreadable hash file: exits 1" "$(eq "$RC" 1)" "rc=$RC (run unprivileged: root reads any file)"
check "TC-971-03 unreadable hash file: the sentence" \
	"$(eq "$ERR" "$P the hash file $TMP/unreadable.hash cannot be read.")" "$ERR"
chmod 600 "$TMP/unreadable.hash"

echo "── TC-971-11 the pinned api tarball's identity/pins.json"
OUT=$(api_dir_fetch "$ROOT" BR2_x86_64 "$TMP/api" identity 2>&1); RC=$?
printf '%s\n' "$OUT" | sed 's/^/   /'
check "TC-971-11 the api tarball is fetched, checked and has identity/" "$(eq "$RC" 0)" "$OUT"
if [ "$RC" = 0 ]; then
	API_DIR="$TMP/api/identity"
	run "$API_DIR/pins.json"
	printf '%s\n' "$OUT" "$ERR" | sed '/^$/d; s/^/   /'
	check "TC-971-11 check-pins.sh exits 0 on the api's pins.json" "$(eq "$RC" 0)" "rc=$RC: $ERR"
	check "TC-971-11 and prints its success line" \
		"$(yes_if contains "check-pins: the api's pins.json agrees with this image's pins" "$OUT")" "$OUT"
fi

echo
if [ "$fails" -ne 0 ]; then
	echo "identity-pin-test: $fails check(s) failed"
	exit 1
fi
echo "identity-pin-test: all checks passed"
