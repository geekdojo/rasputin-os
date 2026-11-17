#!/bin/sh
#
# check-pins.sh — fail the build when the api tarball's identity/pins.json
# names a different Keycloak or JRE than this tree pins
# (geekdojo/geekdojo-brain#971). Control-plane CI tests one Keycloak and JRE
# pairing, written to pins.json from its identitytest/pin.go; an image with any
# other pairing ships one nobody ran. Run by keycloak.mk as a pre-build hook,
# before kc.sh build.
#
#   JQ=<host jq> check-pins.sh PINS_JSON KC_VERSION KC_HASHFILE KC_TARBALL \
#       JRE_VERSION JRE_HASHFILE JRE_X64_TARBALL
#
# Compares, field by field:
#   .keycloak.release        with KC_VERSION
#   .keycloak.sha256         with KC_HASHFILE's sha256 line for KC_TARBALL
#   .jre.release             with JRE_VERSION
#   .jre.linux_x64_sha256    with JRE_HASHFILE's sha256 line for JRE_X64_TARBALL
#
# Success: one stdout line, exit 0. A difference: one stderr sentence per
# field naming both values and the fix order, exit 1.
# FAILS CLOSED, exit 1 with a sentence: JQ unset or not executable; pins.json
# absent, empty, not a JSON object, or a field missing or empty; a hash file
# unreadable or without exactly one line for its tarball.

set -u

fail() {
	echo "$*" >&2
	exit 1
}

[ "$#" -eq 7 ] || fail "check-pins.sh needs pins.json, the Keycloak version, hash file and tarball, and the JRE version, hash file and x64 tarball."
PINS="$1"
KC_VERSION="$2"
KC_HASHFILE="$3"
KC_TARBALL="$4"
JRE_VERSION="$5"
JRE_HASHFILE="$6"
JRE_TARBALL="$7"

[ -n "${JQ:-}" ] || fail "Cannot check the identity pins, because JQ is not set."
case "$JQ" in
	*/*) [ -f "$JQ" ] && [ -x "$JQ" ] ;;
	*) command -v "$JQ" >/dev/null 2>&1 ;;
esac || fail "Cannot check the identity pins, because JQ ($JQ) is not an executable file."

[ -f "$PINS" ] || fail "Cannot check the identity pins, because $PINS does not exist: the api tarball carries no identity/pins.json."
[ -s "$PINS" ] || fail "Cannot check the identity pins, because $PINS is empty."
"$JQ" -e 'type == "object"' "$PINS" >/dev/null 2>&1 \
	|| fail "Cannot check the identity pins, because $PINS is not a JSON object."

# pin FIELD — the field's value, a non-empty string, or a failure.
pin() {
	_v=$("$JQ" -r "$1 | if type == \"string\" then . else \"\" end" "$PINS" 2>/dev/null) \
		|| fail "Cannot check the identity pins, because $JQ could not read $1 from $PINS."
	[ -n "$_v" ] || fail "Cannot check the identity pins, because $PINS has no $1, or it is empty."
	printf '%s\n' "$_v"
}

# hash_of HASHFILE TARBALL — its one sha256 line's hash, or a failure.
hash_of() {
	[ -f "$1" ] && [ -r "$1" ] || fail "Cannot check the identity pins, because the hash file $1 cannot be read."
	_n=$(awk -v t="$2" '$1 == "sha256" && $3 == t' "$1" | wc -l | tr -d ' ')
	[ "$_n" = 1 ] || fail "Cannot check the identity pins, because $1 has $_n sha256 lines for $2, and needs exactly one."
	awk -v t="$2" '$1 == "sha256" && $3 == t { print $2 }' "$1"
}

KC_REL=$(pin .keycloak.release) || exit 1
KC_SHA=$(pin .keycloak.sha256) || exit 1
JRE_REL=$(pin .jre.release) || exit 1
JRE_SHA=$(pin .jre.linux_x64_sha256) || exit 1
OS_KC_SHA=$(hash_of "$KC_HASHFILE" "$KC_TARBALL") || exit 1
OS_JRE_SHA=$(hash_of "$JRE_HASHFILE" "$JRE_TARBALL") || exit 1

bad=0
# differ FIELD API_VALUE OS_VALUE WHERE
differ() {
	[ "$2" = "$3" ] && return 0
	echo "The api's pins.json has $1 $2 but $4 has $3, so this image would ship a Keycloak and JRE pairing control-plane CI never ran; change control-plane identitytest/pin.go first, then cut a control-plane release, then move the OS api pin and this pin together." >&2
	bad=1
}
differ keycloak.release "$KC_REL" "$KC_VERSION" "package/keycloak/keycloak.mk"
differ keycloak.sha256 "$KC_SHA" "$OS_KC_SHA" "package/keycloak/keycloak.hash"
differ jre.release "$JRE_REL" "$JRE_VERSION" "package/temurin-jre/temurin-jre.mk"
differ jre.linux_x64_sha256 "$JRE_SHA" "$OS_JRE_SHA" "package/temurin-jre/temurin-jre.hash"
[ "$bad" = 0 ] || exit 1

echo "check-pins: the api's pins.json agrees with this image's pins (Keycloak $KC_VERSION, JRE $JRE_VERSION)."
