#!/bin/sh
#
# Fixture tests for test/lib/api-tarball.sh's api_policy_fetch, the pinned api
# tarball fetch that store-unit-functional.sh and store-policy-live-drift.sh
# share (geekdojo/geekdojo-brain#804, F-804-18), and api_dir_fetch, the same
# fetch generalized to any directory, which identity-pin-test.sh uses for
# identity/ (geekdojo/geekdojo-brain#971, TC-971-10).
#
# Why. Both callers reach the download and the hash check only against the
# real pin, which predates the policy files until the store-arming cut, so in
# CI a broken download branch or a hash check that never refuses would go
# unseen. This runs the function on a fixture ROOT (its ROOT argument is the
# injection point): the real rasputin-api.mk with only RASPUTIN_API_SITE
# pointed at a local file:// directory, so the version and the per-arch source
# name are still read by GNU make from the real file, and a fixture
# rasputin-api.hash. Three rows:
#   - a matching tarball: exit 0, the hash line, the policy text extracted;
#   - a failed download (nothing at the site): exit 1, a sentence naming the
#     URL, nothing extracted;
#   - a hash that does not match: exit 1, a sentence with both hashes,
#     nothing extracted.
# The real-tag drift (exit 1 on differing text) is left to the cut, when the
# pin carries the files. Then TC-971-10: tarballs with and without identity/
# and openbao-policy/, through api_dir_fetch and the api_policy_fetch wrapper:
# a present directory returns 0 and sets the variable, an absent one returns
# non-zero naming the directory and the api version.
#
# Needs: GNU make, curl, openssl, tar.
# Run:   sh test/api-tarball-test.sh
set -u
LC_ALL=C
export LC_ALL
unset RASPUTIN_API_TARBALL

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
for t in make curl openssl tar; do
	command -v "$t" >/dev/null 2>&1 || { echo "FAILED: this test needs $t, and it is not on PATH." >&2; exit 1; }
done
for f in "$ROOT/test/lib/mk-var.sh" "$ROOT/test/lib/api-tarball.sh" "$ROOT/test/lib/checks.sh" \
	"$ROOT/package/rasputin-api/rasputin-api.mk"; do
	[ -f "$f" ] || { echo "FAILED: the file $f is missing." >&2; exit 1; }
done
. "$ROOT/test/lib/mk-var.sh"
. "$ROOT/test/lib/api-tarball.sh"
. "$ROOT/test/lib/checks.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

# The fixture ROOT: the real .mk with only the site moved to a local directory.
SITE="$TMP/site"
FX="$TMP/root/package/rasputin-api"
mkdir -p "$SITE" "$FX"
sed "s|^RASPUTIN_API_SITE = .*|RASPUTIN_API_SITE = file://$SITE|" \
	"$ROOT/package/rasputin-api/rasputin-api.mk" > "$FX/rasputin-api.mk"
grep -qxF "RASPUTIN_API_SITE = file://$SITE" "$FX/rasputin-api.mk" \
	|| { echo "FAILED: could not point the fixture rasputin-api.mk at $SITE; the RASPUTIN_API_SITE line changed shape." >&2; exit 1; }
VERSION=$(mk_var "$FX/rasputin-api.mk" RASPUTIN_API_VERSION) || exit 1
SRC=$(mk_var "$FX/rasputin-api.mk" RASPUTIN_API_SOURCE BR2_x86_64=y) || exit 1

# A tarball shaped like the release's: the binary, and openbao-policy/.
mkdir -p "$TMP/tb/openbao-policy"
printf '#!/bin/sh\n' > "$TMP/tb/rasputin-api"
printf 'path "rasputin-secrets/data/apps/*" {\n  capabilities = ["read"]\n}\n' > "$TMP/tb/openbao-policy/rasputin-api.hcl"
tar -czf "$TMP/$SRC" -C "$TMP/tb" rasputin-api openbao-policy
GOOD=$(openssl dgst -sha256 -r "$TMP/$SRC" | cut -d' ' -f1)
WRONG=0000000000000000000000000000000000000000000000000000000000000000

# row NAME HASH STAGE — STAGE=yes puts the tarball at the site; HASH goes in
# rasputin-api.hash. Runs api_policy_fetch in a subshell; RC, $OUT (its
# stdout and stderr) and $WORK (its work directory) are left for the checks.
row() {
	rm -f "$SITE/$SRC"
	[ "$3" = yes ] && cp "$TMP/$SRC" "$SITE/$SRC"
	printf 'sha256  %s  %s\n' "$2" "$SRC" > "$FX/rasputin-api.hash"
	WORK="$TMP/work-$1"
	OUT=$( (api_policy_fetch "$TMP/root" BR2_x86_64 "$WORK" && printf 'API_VERSION=%s\nAPI_POLICY=%s\n' "$API_VERSION" "$API_POLICY") 2>&1)
	RC=$?
}

echo "matching tarball"
row good "$GOOD" yes
check "a matching tarball returns 0" "$([ "$RC" = 0 ] && echo 0 || echo 1)" "rc=$RC: $OUT"
check "it says the tarball matches rasputin-api.hash" "$(yes_if contains "$SRC matches rasputin-api.hash" "$OUT")" "$OUT"
check "API_VERSION is the .mk's version" "$(yes_if contains "API_VERSION=$VERSION" "$OUT")" "$OUT"
check "API_POLICY is the extracted openbao-policy/" "$(yes_if contains "API_POLICY=$WORK/openbao-policy" "$OUT")" "$OUT"
check "the policy text is extracted byte-equal" \
	"$(yes_if cmp -s "$WORK/openbao-policy/rasputin-api.hcl" "$TMP/tb/openbao-policy/rasputin-api.hcl")"

echo "failed download"
row nosite "$GOOD" no
check "a failed download returns 1" "$([ "$RC" = 1 ] && echo 0 || echo 1)" "rc=$RC: $OUT"
check "it names the URL that failed" \
	"$(yes_if contains "FAILED: the download of file://$SITE/$SRC failed, so there is no api tarball to take the policy text from." "$OUT")" "$OUT"
case "$OUT" in *"matches rasputin-api.hash"*) r=1 ;; *) r=0 ;; esac
check "no hash verdict is printed after a failed download" "$r" "$OUT"
check "nothing is extracted after a failed download" "$([ ! -e "$WORK/openbao-policy" ] && echo 0 || echo 1)"

echo "hash mismatch"
row badhash "$WRONG" yes
check "a hash mismatch returns 1" "$([ "$RC" = 1 ] && echo 0 || echo 1)" "rc=$RC: $OUT"
check "it names the tarball and both hashes" \
	"$(yes_if contains "FAILED: $SRC does not match rasputin-api.hash (got $GOOD, want $WRONG)." "$OUT")" "$OUT"
check "nothing is extracted after a hash mismatch" "$([ ! -e "$WORK/openbao-policy" ] && echo 0 || echo 1)"

# TC-971-10. pack NAME DIR... — a fixture tarball holding the binary and DIRs,
# staged at the site with its hash in rasputin-api.hash.
pack() {
	_n=$1; shift
	tar -czf "$SITE/$SRC" -C "$TMP/tb" rasputin-api "$@"
	printf 'sha256  %s  %s\n' "$(openssl dgst -sha256 -r "$SITE/$SRC" | cut -d' ' -f1)" "$SRC" > "$FX/rasputin-api.hash"
	WORK="$TMP/work-$_n"
}
mkdir -p "$TMP/tb/identity/theme"
printf '{"keycloak":{"release":"26.8.2"}}\n' > "$TMP/tb/identity/pins.json"
printf 'db=postgres\n' > "$TMP/tb/identity/keycloak-build.conf"

echo "TC-971-10 identity/ present"
pack both openbao-policy identity
OUT=$( (api_dir_fetch "$TMP/root" BR2_x86_64 "$WORK" identity && printf 'API_DIR=%s\n' "$API_DIR") 2>&1); RC=$?
check "TC-971-10 a tarball with identity/ returns 0" "$([ "$RC" = 0 ] && echo 0 || echo 1)" "rc=$RC: $OUT"
check "TC-971-10 API_DIR is the extracted identity/" "$(yes_if contains "API_DIR=$WORK/identity" "$OUT")" "$OUT"
check "TC-971-10 identity/ is extracted unchanged" "$(yes_if diff -r "$TMP/tb/identity" "$WORK/identity")"

echo "TC-971-10 identity/ absent"
pack noident openbao-policy
OUT=$( (api_dir_fetch "$TMP/root" BR2_x86_64 "$WORK" identity) 2>&1); RC=$?
check "TC-971-10 a tarball without identity/ returns non-zero" "$([ "$RC" != 0 ] && echo 0 || echo 1)" "rc=$RC: $OUT"
check "TC-971-10 it names identity/ and the api version" \
	"$(yes_if contains "FAILED: $SRC (api $VERSION) holds no identity/." "$OUT")" "$OUT"

echo "TC-971-10 openbao-policy/ present, through the wrapper"
pack policy openbao-policy identity
OUT=$( (api_policy_fetch "$TMP/root" BR2_x86_64 "$WORK" && printf 'API_POLICY=%s\n' "$API_POLICY") 2>&1); RC=$?
check "TC-971-10 the wrapper returns 0" "$([ "$RC" = 0 ] && echo 0 || echo 1)" "rc=$RC: $OUT"
check "TC-971-10 the wrapper sets API_POLICY" "$(yes_if contains "API_POLICY=$WORK/openbao-policy" "$OUT")" "$OUT"

echo "TC-971-10 openbao-policy/ absent, through the wrapper"
pack nopolicy identity
OUT=$( (api_policy_fetch "$TMP/root" BR2_x86_64 "$WORK") 2>&1); RC=$?
check "TC-971-10 the wrapper returns non-zero without openbao-policy/" "$([ "$RC" != 0 ] && echo 0 || echo 1)" "rc=$RC: $OUT"
check "TC-971-10 it names openbao-policy/ and the api version" \
	"$(yes_if contains "FAILED: $SRC (api $VERSION) holds no openbao-policy/." "$OUT")" "$OUT"
check "TC-971-10 nothing is extracted" "$([ ! -e "$WORK/openbao-policy" ] && echo 0 || echo 1)"

if [ "$fails" -ne 0 ]; then
	echo "api-tarball-test: $fails check(s) failed"
	exit 1
fi
echo "api-tarball-test: all checks passed"
