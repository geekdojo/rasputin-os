#!/bin/sh
# Tests for package/keycloak, the pinned identity service
# (geekdojo/geekdojo-brain#971). What can be wrong in the package without a
# Buildroot run noticing, pinned here:
#
#   TC-971-04  check-build-options.sh on jar fixtures: an equal set passes, a
#              conf-only key is named as unknown or misspelt, a differing value
#              names both, a persisted-only key is named, and comments, blank
#              lines, the timestamp and Keycloak's three fixed keys are ignored.
#   TC-971-05  check-build-options.sh fails closed on every input it cannot
#              read.
#   TC-971-06  keycloak.mk's table per architecture, by real GNU make.
#   TC-971-07  keycloak.hash has exactly one line per download and no other,
#              and its dist line and provenance are the verified ones.
#   TC-971-08  Config.in, the root Config.in and both defconfigs.
#   TC-971-09  SOURCE names no Keycloak version but the pin (F-971-02).
#
# No make, python3 or unzip is a failure, not a skip.
#
# What this does NOT prove: that Buildroot downloads, builds or installs any of
# it. test/keycloak-functional.sh does that, in the temurin-jre CI job.
#
# Run:  sh test/keycloak-package-test.sh
set -u
LC_ALL=C
export LC_ALL

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
PKG="$ROOT/package/keycloak"
MK="$PKG/keycloak.mk"
HASH="$PKG/keycloak.hash"
OPTS="$PKG/check-build-options.sh"
JRE_MK="$ROOT/package/temurin-jre/temurin-jre.mk"
for f in "$MK" "$HASH" "$OPTS" "$PKG/Config.in" "$PKG/SOURCE" "$JRE_MK" \
	"$ROOT/test/lib/mk-var.sh" "$ROOT/test/lib/checks.sh"; do
	[ -f "$f" ] || { echo "FAILED: the file $f is missing." >&2; exit 1; }
done
case "$(make --version 2>/dev/null)" in
	"GNU Make"*) ;;
	*) echo "FAILED: GNU make is not on PATH. This suite evaluates keycloak.mk with it and never skips." >&2; exit 1 ;;
esac
for t in python3 unzip; do
	command -v "$t" >/dev/null 2>&1 || { echo "FAILED: this test needs $t, and it is not on PATH." >&2; exit 1; }
done
. "$ROOT/test/lib/mk-var.sh"
. "$ROOT/test/lib/checks.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
eq() { [ "$1" = "$2" ] && echo 0 || echo 1; }

echo "── TC-971-04 check-build-options.sh on jar fixtures"
# jar NAME PROPERTIES_FILE|- — a zip holding the file as the persisted
# properties, or (with -) holding only a manifest, as the unbuilt dist's jar.
jar() {
	python3 -I - "$TMP/$1.jar" "$2" <<'EOF'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w")
z.writestr("META-INF/MANIFEST.MF", "Manifest-Version: 1.0\n")
if sys.argv[2] != "-":
    z.writestr("META-INF/keycloak-persisted.properties", open(sys.argv[2]).read())
z.close()
EOF
}
cat > "$TMP/build.conf" <<'EOF'
# The options, as the api ships them.

db=postgres
https-client-auth=required
features-disabled=account,admin
EOF
cat > "$TMP/equal.props" <<'EOF'
# Auto-generated, DO NOT change this file
#Sun Nov 15 11:37:12 PST 2026
kc.db=postgres
kc.features-disabled=account,admin
kc.https-client-auth=required
kc.optimized=true
kc.profile=prod

quarkus.profile=prod
EOF
jar equal "$TMP/equal.props"
# opts CONF JAR [ENV...] — run the check; leaves RC, OUT and ERR.
opts() {
	_c=$1 _j=$2; shift 2
	OUT=$(env "$@" "$OPTS" "$_c" "$_j" 2> "$TMP/err"); RC=$?
	ERR=$(cat "$TMP/err")
}
opts "$TMP/build.conf" "$TMP/equal.jar"
check "TC-971-04 an equal set exits 0" "$(eq "$RC" 0)" "rc=$RC: $ERR"
check "TC-971-04 an equal set prints the success line, counting 3 options" \
	"$(eq "$OUT" "check-build-options: the 3 options Keycloak persisted equal $TMP/build.conf.")" "$OUT"
check "TC-971-04 comments, blanks, the timestamp and the three fixed keys are ignored: nothing on stderr" "$(eq "$ERR" "")" "$ERR"

SUMMARY1="Keycloak's persisted build options differ from $TMP/bogus.conf (1 difference(s)), so the image would ship options the api does not assume."
{ cat "$TMP/build.conf"; echo bogus-option=1; } > "$TMP/bogus.conf"
opts "$TMP/bogus.conf" "$TMP/equal.jar"
check "TC-971-04 a conf-only key exits 1" "$(eq "$RC" 1)" "rc=$RC"
check "TC-971-04 a conf-only key is named as an unknown or misspelt option" "$(eq "$ERR" \
	"$TMP/bogus.conf sets bogus-option=1, which Keycloak did not persist: an unknown or misspelt option.
$SUMMARY1")" "$ERR"
check "TC-971-04 a conf-only key: no success line" "$(eq "$OUT" "")" "$OUT"

sed 's/^kc.https-client-auth=required$/kc.https-client-auth=request/' "$TMP/equal.props" > "$TMP/value.props"
jar value "$TMP/value.props"
opts "$TMP/build.conf" "$TMP/value.jar"
check "TC-971-04 a differing value exits 1" "$(eq "$RC" 1)" "rc=$RC"
check "TC-971-04 a differing value names both values" "$(eq "$ERR" \
	"$TMP/build.conf sets https-client-auth=required, but Keycloak persisted kc.https-client-auth=request.
Keycloak's persisted build options differ from $TMP/build.conf (1 difference(s)), so the image would ship options the api does not assume.")" "$ERR"

{ cat "$TMP/equal.props"; echo 'kc.provider.file.extra.jar.last-modified=1763241432000'; } > "$TMP/extra.props"
jar extra "$TMP/extra.props"
opts "$TMP/build.conf" "$TMP/extra.jar"
check "TC-971-04 a persisted-only kc.provider.file.* key exits 1" "$(eq "$RC" 1)" "rc=$RC"
check "TC-971-04 a persisted-only key is named" "$(eq "$ERR" \
	"Keycloak persisted kc.provider.file.extra.jar.last-modified=1763241432000 in $TMP/extra.jar, which $TMP/build.conf does not set.
Keycloak's persisted build options differ from $TMP/build.conf (1 difference(s)), so the image would ship options the api does not assume.")" "$ERR"

# A fixed key with another value is not one of the three ignored lines.
sed 's/^kc.profile=prod$/kc.profile=dev/' "$TMP/equal.props" > "$TMP/profile.props"
jar profile "$TMP/profile.props"
opts "$TMP/build.conf" "$TMP/profile.jar"
check "TC-971-04 kc.profile=dev is not ignored: exits 1" "$(eq "$RC" 1)" "rc=$RC"
check "TC-971-04 kc.profile=dev is named" \
	"$(yes_if contains "Keycloak persisted kc.profile=dev in $TMP/profile.jar, which $TMP/build.conf does not set." "$ERR")" "$ERR"

echo "── TC-971-05 check-build-options.sh fails closed"
B="Cannot check Keycloak's build options, because"
# closed LABEL WANT CONF JAR [ENV...]
closed() {
	_l=$1 _w=$2; shift 2
	opts "$@"
	check "TC-971-05 $_l: exits 1" "$(eq "$RC" 1)" "rc=$RC"
	check "TC-971-05 $_l: the sentence" "$(eq "$ERR" "$_w")" "$ERR"
	check "TC-971-05 $_l: no success line" "$(eq "$OUT" "")" "$OUT"
}
closed "conf missing" "$B the conf $TMP/absent.conf does not exist." "$TMP/absent.conf" "$TMP/equal.jar"
cp "$TMP/build.conf" "$TMP/locked.conf"; chmod 000 "$TMP/locked.conf"
closed "conf unreadable (run unprivileged)" "$B the conf $TMP/locked.conf cannot be read." "$TMP/locked.conf" "$TMP/equal.jar"
chmod 600 "$TMP/locked.conf"
closed "jar missing" "$B $TMP/absent.jar does not exist." "$TMP/build.conf" "$TMP/absent.jar"
printf 'not a zip\n' > "$TMP/notzip.jar"
closed "jar not a zip" "$B $TMP/notzip.jar is not a zip archive." "$TMP/build.conf" "$TMP/notzip.jar"
jar unbuilt -
closed "no persisted file (the unbuilt dist)" \
	"$B $TMP/unbuilt.jar holds no META-INF/keycloak-persisted.properties, so kc.sh build has not run on it." \
	"$TMP/build.conf" "$TMP/unbuilt.jar"
printf '#!/bin/sh\nexit 3\n' > "$TMP/unzip-fails"; chmod +x "$TMP/unzip-fails"
closed "UNZIP exits non-zero" \
	"$B $TMP/unzip-fails exited 3 reading META-INF/keycloak-persisted.properties from $TMP/equal.jar." \
	"$TMP/build.conf" "$TMP/equal.jar" UNZIP="$TMP/unzip-fails"
{ cat "$TMP/build.conf"; echo 'not an option'; } > "$TMP/malformed.conf"
closed "a conf line that is not key=value" \
	"$B line 6 of $TMP/malformed.conf is not blank, a # comment or key=value." \
	"$TMP/malformed.conf" "$TMP/equal.jar"

echo "── TC-971-06 keycloak.mk per architecture"
# Buildroot's github macro (support: package/pkg-download.mk:54 at 2026.08.1),
# which mk_var's lone include does not define. TC-971-19 checks the site
# legal-info records with the real one.
GITHUB='github=https://github.com/$(1)/$(2)/archive/$(3)'
printf 'include %s\ninclude %s\n' "$JRE_MK" "$MK" > "$TMP/both.mk"
FPR=861AB50E8CC6611FB6BC01A6B8F12EA26FD6EEBA
for a in aarch64 x86_64; do
	ARCH="BR2_$a=y"
	: > "$TMP/table-$a"
	# row VAR WANT
	row() {
		_g=$(mk_var "$MK" "$1" "$ARCH" "BR2_ARCH=$a" "$GITHUB" 2>&1)
		check "TC-971-06 $a $1" "$(eq "$_g" "$2")" "got: $_g"
		printf '%s=%s\n' "$1" "$_g" >> "$TMP/table-$a"
	}
	row KEYCLOAK_VERSION 26.8.2
	row KEYCLOAK_SITE https://repo1.maven.org/maven2/org/keycloak/keycloak-quarkus-dist/26.8.2
	row KEYCLOAK_SOURCE keycloak-quarkus-dist-26.8.2.tar.gz
	row KEYCLOAK_ACTUAL_SOURCE_TARBALL keycloak-26.8.2.tar.gz
	row KEYCLOAK_ACTUAL_SOURCE_SITE https://github.com/keycloak/keycloak/archive/26.8.2
	row KEYCLOAK_DEPENDENCIES "host-temurin-jre rasputin-api host-jq"
	row KEYCLOAK_CPE_ID_VENDOR redhat
	row KEYCLOAK_LICENSE_FILES LICENSE.txt
	row KEYCLOAK_SIGNER_FPR "$FPR"
	_g=$(mk_var "$TMP/both.mk" KEYCLOAK_JRE_X64_TARBALL "$ARCH" "BR2_ARCH=$a" BR2_PACKAGE_TEMURIN_JRE=y HOSTARCH=x86_64 2>&1)
	check "TC-971-06 $a KEYCLOAK_JRE_X64_TARBALL is the x64 JRE, whatever the target" \
		"$(eq "$_g" OpenJDK25U-jre_x64_linux_hotspot_25.0.5_8.tar.gz)" "got: $_g"
	printf 'KEYCLOAK_JRE_X64_TARBALL=%s\n' "$_g" >> "$TMP/table-$a"
done
check "TC-971-06 the anchor is 40 hex characters" \
	"$(printf '%s' "$FPR" | grep -qxE '[0-9A-F]{40}' && echo 0 || echo 1)"
check "TC-971-06 the two architectures give identical values" \
	"$(yes_if cmp -s "$TMP/table-aarch64" "$TMP/table-x86_64")" "$(diff "$TMP/table-aarch64" "$TMP/table-x86_64")"

echo "── TC-971-07 keycloak.hash"
DIST=$(mk_var "$MK" KEYCLOAK_SOURCE) || exit 1
SRC_TGZ=$(mk_var "$MK" KEYCLOAK_ACTUAL_SOURCE_TARBALL) || exit 1
EXTRA=$(mk_var "$MK" KEYCLOAK_EXTRA_DOWNLOADS) || exit 1
LICENSE_FILES=$(mk_var "$MK" KEYCLOAK_LICENSE_FILES) || exit 1
WANT=$(for u in $EXTRA; do basename "$u"; done; printf '%s\n' "$DIST" "$SRC_TGZ" $LICENSE_FILES)
WANT=$(printf '%s\n' "$WANT" | sort)
check "TC-971-07 the download list is the dist, the source, 16 sources jars and LICENSE.txt" \
	"$(eq "$(printf '%s\n' "$WANT" | wc -l | tr -d ' ')" 19)" "$WANT"
# check_hash HASHFILE — one sentence per problem on stdout; status 1 if any.
check_hash() {
	_bad=0
	for _n in $WANT; do
		_c=$(awk -v n="$_n" '$1 == "sha256" && $2 ~ /^[0-9a-f]{64}$/ && $3 == n' "$1" | wc -l | tr -d ' ')
		if [ "$_c" != 1 ]; then
			echo "keycloak.hash has $_c sha256 lines for $_n, and needs exactly one."
			_bad=1
		fi
	done
	for _n in $(awk '$1 == "sha256" { print $3 }' "$1" | sort -u); do
		if ! printf '%s\n' "$WANT" | grep -qxF "$_n"; then
			echo "keycloak.hash has a line for $_n, which the package never downloads."
			_bad=1
		fi
	done
	return "$_bad"
}
_m=$(check_hash "$HASH"); _rc=$?
check "TC-971-07 the real keycloak.hash has exactly one line per download and no other" "$(eq "$_rc" 0)" "$_m"
J=jna-5.8.0-sources.jar
grep -v " $J\$" "$HASH" > "$TMP/h-missing"
_m=$(check_hash "$TMP/h-missing"); _rc=$?
check "TC-971-07 a copy with a line missing fails" "$(eq "$_rc" 1)"
check "TC-971-07 and names it" "$(eq "$_m" "keycloak.hash has 0 sha256 lines for $J, and needs exactly one.")" "$_m"
{ cat "$HASH"; grep " LICENSE.txt\$" "$HASH"; } > "$TMP/h-dup"
_m=$(check_hash "$TMP/h-dup"); _rc=$?
check "TC-971-07 a copy with a line duplicated fails" "$(eq "$_rc" 1)"
check "TC-971-07 and names it" "$(eq "$_m" "keycloak.hash has 2 sha256 lines for LICENSE.txt, and needs exactly one.")" "$_m"
{ cat "$HASH"; echo "sha256  $(printf '%064d' 0)  h2-2.3.232-sources.jar"; } > "$TMP/h-extra"
_m=$(check_hash "$TMP/h-extra"); _rc=$?
check "TC-971-07 a copy with an extra line fails" "$(eq "$_rc" 1)"
check "TC-971-07 and names it" "$(eq "$_m" "keycloak.hash has a line for h2-2.3.232-sources.jar, which the package never downloads.")" "$_m"
check "TC-971-07 the dist line is the verified sha256" \
	"$(eq "$(awk -v n="$DIST" '$1 == "sha256" && $3 == n { print $2 }' "$HASH")" dd124787283918bc597628887168333465ee2a811a389e0003569e52be7e487f)"
check "TC-971-07 the header cites the 958 transcript" \
	"$(yes_if grep -q '^# projects/rasputin/research/identity-evidence/958/raw/signature-verification-keycloak-26\.8\.2\.txt$' "$HASH")"
check "TC-971-07 and its sha256" \
	"$(yes_if grep -q '^# (sha256 cc00f833b4b19a825be7d800bcfc9b1135a1e3fea97adfee3153a5398e74921a)\.$' "$HASH")"

echo "── TC-971-08 Config.in and the defconfigs"
CIN="$PKG/Config.in"
check "TC-971-08 Config.in depends on a glibc toolchain" \
	"$(eq "$(grep -cxE '[[:space:]]*depends on BR2_TOOLCHAIN_USES_GLIBC' "$CIN")" 1)"
check "TC-971-08 Config.in depends on rasputin-api" \
	"$(eq "$(grep -cxE '[[:space:]]*depends on BR2_PACKAGE_RASPUTIN_API' "$CIN")" 1)"
check "TC-971-08 Config.in selects the JRE" \
	"$(eq "$(grep -cxE '[[:space:]]*select BR2_PACKAGE_TEMURIN_JRE' "$CIN")" 1)"
for d in rasputin_rpi_defconfig rasputin_n100_defconfig; do
	check "TC-971-08 $d sets BR2_PACKAGE_KEYCLOAK=y" "$(eq "$(grep -cx 'BR2_PACKAGE_KEYCLOAK=y' "$ROOT/configs/$d")" 1)"
done
check "TC-971-08 the root Config.in sources the package" \
	"$(eq "$(grep -cxF 'source "$BR2_EXTERNAL_RASPUTIN_PATH/package/keycloak/Config.in"' "$ROOT/Config.in")" 1)"

echo "── TC-971-09 SOURCE names no other version"
PIN=$(mk_var "$MK" KEYCLOAK_VERSION) || exit 1
# other_versions FILE — every x.y.z in FILE that is not the pin.
other_versions() { grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$1" | grep -vxF "$PIN" | sort -u | tr '\n' ' '; }
check "TC-971-09 the real SOURCE names no Keycloak version but $PIN" "$(eq "$(other_versions "$PKG/SOURCE")" "")" "$(other_versions "$PKG/SOURCE")"
{ cat "$PKG/SOURCE"; echo "  https://github.com/keycloak/keycloak/tree/26.8.1"; } > "$TMP/SOURCE-stale"
check "TC-971-09 a copy naming 26.8.1 fails, naming it" "$(eq "$(other_versions "$TMP/SOURCE-stale")" "26.8.1 ")" "$(other_versions "$TMP/SOURCE-stale")"

echo
if [ "$fails" -ne 0 ]; then
	echo "keycloak-package-test: $fails check(s) failed"
	exit 1
fi
echo "keycloak-package-test: all checks passed"
