#!/bin/sh
# Functional test for package/keycloak (geekdojo/geekdojo-brain#971): the
# package built by the pinned Buildroot, for real, on one target architecture.
# CI runs it in the temurin-jre job, one leg per architecture (aarch64 and
# x86_64), because the image and defconfigs change per architecture
# (SEC-PLATFORM). Both legs run on the native amd64 runner: kc.sh build runs on
# the build host's own JVM, never emulated.
#
# This builds a minimal config with the Bootlin glibc stable external
# toolchain (no toolchain build), no init, no /bin/sh, no busybox and no rootfs
# image, plus rasputin-api and keycloak (which selects the JRE), then:
#
#   TC-971-12  make succeeds, and the pin check's and the options check's
#              success lines are in the build log.
#   TC-971-13  the install layout: exactly the dist's top level plus the data
#              link, no Buildroot stamp files, both links, an empty
#              conf/truststores/, no provider jar, the licence and SOURCE.
#   TC-971-14  check-build-options.sh on the target's jar and conf exits 0,
#              and the persisted file is exactly the conf plus the 3 fixed
#              keys.
#   TC-971-15  identity/ is installed unchanged from the api tarball.
#   TC-971-22  show-info's cpe-id, through Buildroot's own CVE matcher
#              (test/lib/cve-verdict.sh) against NVD's CVE-2026-0871
#              (test/fixtures/nvd/, from github.com/fkie-cad/nvd-json-data-feeds
#              at commit 2ea002cc3b166ddbd3dfaf54371d7e6729fac92a).
#   TC-971-19  legal-info saves Keycloak's source and every GPL-family jar's
#              source, not the binary dist, and scripts/gpl-sources.py passes
#              on every manifest row but this config's Bootlin toolchain.
#   TC-971-20  the jar scan: the GPL-family jars in the installed dist are
#              exactly KEYCLOAK_GPL_JARS, each with its source saved; a fixture
#              GPL jar with no source listed fails, named.
#   TC-971-21  the dist's Maven Central .asc verifies against the committed
#              key, whose fingerprint is the .mk's anchor (VALIDSIG; the key
#              expires 2027-02-12, after which gpg reports EXPKEYSIG with
#              VALIDSIG). A tampered copy gives BADSIG and check-hash exit 2; a
#              key with another fingerprint fails the anchor check; a .asc by
#              another key gives NO_PUBKEY. The status lines are the transcript.
#   TC-971-16  an unknown option, and an unknown feature, fail the build.
#   TC-971-17  a pins.json mismatch fails the build in the pin hook, before
#              kc.sh build runs.
#   TC-971-18  an api tarball without identity/ fails rasputin-api's install.
# The destructive cases run last, in that order.
#
# What this does NOT prove: Keycloak running on an image or on hardware (that
# is the image smoke's facts and the bench's TC-971-26 and TC-971-27).
#
# TEST-ONLY OVERRIDE. RASPUTIN_API_LOCAL_DIR=<extracted api tarball> builds
# rasputin-api from that directory (Buildroot's RASPUTIN_API_OVERRIDE_SRCDIR)
# instead of the pinned tarball, and prints a LOCAL OVERRIDE: line, because
# such a run says nothing about the pin. CI never sets it.
#
# Needs: network access (Maven Central, GitHub, Adoptium, Bootlin), GNU make,
# gcc and Buildroot's host prerequisites, gpg, jq, curl, sha256sum, unzip, and
# python3 with setuptools. Any of them missing is a failure, never a skip.
#
# Run, from the repo root, on an x86_64 Linux host:
#   ./scripts/init-buildroot.sh && sh test/keycloak-functional.sh aarch64
#   ./scripts/init-buildroot.sh && sh test/keycloak-functional.sh x86_64
# The build goes to output/keycloak-<arch>/ (KEYCLOAK_FUNC_OUT overrides it).
set -u

ARCH="${1:-}"
case "$ARCH" in
	aarch64) BR_ARCH="BR2_aarch64=y
BR2_cortex_a72=y
BR2_TOOLCHAIN_EXTERNAL_BOOTLIN_AARCH64_GLIBC_STABLE=y" ;;
	x86_64) BR_ARCH="BR2_x86_64=y
BR2_x86_corei7=y
BR2_TOOLCHAIN_EXTERNAL_BOOTLIN_X86_64_GLIBC_STABLE=y" ;;
	*) echo "FAIL — Give the target architecture, aarch64 or x86_64."; exit 1 ;;
esac

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BR="$ROOT/buildroot"
PKG="$ROOT/package/keycloak"
HASH="$PKG/keycloak.hash"
KEY="$PKG/keycloak-signing-key.asc"
OTHER_KEY="$ROOT/package/temurin-jre/adoptium-signing-key.asc"
NVD="$ROOT/test/fixtures/nvd"
OUT="${KEYCLOAK_FUNC_OUT:-$ROOT/output/keycloak-$ARCH}"
T="$OUT/target"
KC="$T/usr/lib/keycloak"
ID="$T/usr/share/rasputin/identity"
. "$ROOT/test/lib/cve-verdict.sh"

[ -f "$BR/Makefile" ] || { echo "FAIL — The pinned Buildroot is not checked out at $BR. Run ./scripts/init-buildroot.sh first."; exit 1; }
for t in make gpg jq curl sha256sum python3 cmp unzip; do
	command -v "$t" >/dev/null 2>&1 || { echo "FAIL — $t is not on PATH. This test needs it and never skips."; exit 1; }
done
python3 -c 'import distutils.version' 2>/dev/null \
	|| { echo "FAIL — python3 cannot import distutils.version, which Buildroot's cve.py needs. Install python3-setuptools; this test never skips the CPE check."; exit 1; }

fails=0
check() { # check LABEL GOT WANT
	if [ "$2" = "$3" ]; then echo "ok   — $1 ($2)"
	else echo "FAIL — $1: expected '$3', got '$2'"; fails=$((fails + 1)); fi
}
has_line() { # has_line LABEL FILE REGEX — some line of FILE matches REGEX
	if grep -qE "$3" "$2"; then echo "ok   — $1: $(grep -E "$3" "$2" | head -1)"
	else echo "FAIL — $1: no line matching '$3' in $2"; fails=$((fails + 1)); fi
}
lacks_line() { # lacks_line LABEL FILE REGEX — no line of FILE matches REGEX
	if grep -qE "$3" "$2"; then echo "FAIL — $1: $(grep -E "$3" "$2" | head -1)"; fails=$((fails + 1))
	else echo "ok   — $1"; fi
}
yes_no() { if "$@"; then echo yes; else echo no; fi; }
nonzero() { [ "$1" -ne 0 ] && echo non-zero || echo 0; }
finish() {
	echo
	if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
	echo "all Keycloak functional checks passed ($ARCH)"
	exit 0
}
abort() { # abort SENTENCE — a step the rest depends on failed
	echo "FAIL — $1"
	fails=$((fails + 1))
	finish
}
brmake() { make -C "$BR" BR2_EXTERNAL="$ROOT" O="$OUT" "$@"; }

SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT

echo "── configure ($ARCH)"
mkdir -p "$OUT"
OVERRIDE_LINE=""
if [ -n "${RASPUTIN_API_LOCAL_DIR:-}" ]; then
	[ -d "$RASPUTIN_API_LOCAL_DIR/identity" ] \
		|| abort "RASPUTIN_API_LOCAL_DIR=$RASPUTIN_API_LOCAL_DIR is not an extracted api tarball with identity/."
	echo "LOCAL OVERRIDE: rasputin-api is built from RASPUTIN_API_LOCAL_DIR=$RASPUTIN_API_LOCAL_DIR, not the pinned tarball, with no hash check. This run says nothing about the pin."
	printf 'RASPUTIN_API_OVERRIDE_SRCDIR = %s\n' "$RASPUTIN_API_LOCAL_DIR" > "$OUT/local.mk"
	OVERRIDE_LINE="BR2_PACKAGE_OVERRIDE_FILE=\"$OUT/local.mk\""
fi
cat > "$OUT/keycloak.defconfig" <<EOF
$BR_ARCH
BR2_DL_DIR="$OUT/dl"
BR2_TOOLCHAIN_EXTERNAL=y
BR2_TOOLCHAIN_EXTERNAL_BOOTLIN=y
BR2_INIT_NONE=y
BR2_SYSTEM_BIN_SH_NONE=y
# BR2_PACKAGE_BUSYBOX is not set
# BR2_PACKAGE_IFUPDOWN_SCRIPTS is not set
# BR2_PACKAGE_CADDY is not set
# BR2_PACKAGE_RASPUTIN_AGENT is not set
# BR2_TARGET_ROOTFS_TAR is not set
BR2_PACKAGE_RASPUTIN_API=y
BR2_PACKAGE_KEYCLOAK=y
$OVERRIDE_LINE
EOF
brmake defconfig BR2_DEFCONFIG="$OUT/keycloak.defconfig" > "$OUT/defconfig.log" 2>&1 \
	|| { cat "$OUT/defconfig.log"; abort "make defconfig failed."; }
# Kconfig drops a symbol whose dependencies are unmet without a word, so the
# config the test means to build is checked, not assumed.
for sym in BR2_PACKAGE_KEYCLOAK=y BR2_PACKAGE_TEMURIN_JRE=y BR2_PACKAGE_RASPUTIN_API=y BR2_TOOLCHAIN_USES_GLIBC=y BR2_INIT_NONE=y; do
	check "config has $sym" "$(grep -cxF "$sym" "$OUT/.config")" 1
done

VARS=$(brmake -s --no-print-directory printvars \
	VARS="KEYCLOAK_VERSION KEYCLOAK_SITE KEYCLOAK_SOURCE KEYCLOAK_ACTUAL_SOURCE_TARBALL KEYCLOAK_ACTUAL_SOURCE_SITE KEYCLOAK_SIGNER_FPR KEYCLOAK_DL_DIR KEYCLOAK_DIR KEYCLOAK_EXTRA_DOWNLOADS KEYCLOAK_GPL_JARS RASPUTIN_API_DIR") \
	|| abort "make printvars failed."
var() { printf '%s\n' "$VARS" | sed -n "s/^$1=//p"; }
PIN=$(var KEYCLOAK_VERSION)
SITE=$(var KEYCLOAK_SITE)
DIST=$(var KEYCLOAK_SOURCE)
SRC_TGZ=$(var KEYCLOAK_ACTUAL_SOURCE_TARBALL)
SRC_SITE=$(var KEYCLOAK_ACTUAL_SOURCE_SITE)
FPR=$(var KEYCLOAK_SIGNER_FPR)
DL=$(var KEYCLOAK_DL_DIR)
BUILDDIR=$(var KEYCLOAK_DIR)
EXTRA=$(var KEYCLOAK_EXTRA_DOWNLOADS)
GPL_JARS=$(var KEYCLOAK_GPL_JARS)
API_DIR=$(var RASPUTIN_API_DIR)
for v in PIN SITE DIST SRC_TGZ SRC_SITE FPR DL BUILDDIR EXTRA GPL_JARS API_DIR; do
	eval "[ -n \"\$$v\" ]" || abort "Buildroot gave no value for $v, so nothing below has anything to compare against."
done
CONF="$ID/keycloak-build.conf"
PINS="$ID/pins.json"
echo "pin $PIN; dist $DIST; source $SRC_SITE/$SRC_TGZ"

echo "── TC-971-12 real build"
brmake > "$OUT/build.log" 2>&1; rc=$?
tail -n 20 "$OUT/build.log"
check "TC-971-12 make exits 0" "$rc" 0
[ "$rc" = 0 ] || abort "The build failed, so nothing after it can be checked; the log is $OUT/build.log."
has_line "TC-971-12 the pin check's success line" "$OUT/build.log" \
	"^check-pins: the api's pins\\.json agrees with this image's pins \\(Keycloak $PIN, JRE [^)]*\\)\\.\$"
has_line "TC-971-12 the options check's success line" "$OUT/build.log" \
	"^check-build-options: the [1-9][0-9]* options Keycloak persisted equal .*/usr/share/rasputin/identity/keycloak-build\\.conf\\.\$"

echo "── TC-971-13 install layout"
check "TC-971-13 top level is exactly the dist's plus the data link" \
	"$(ls -A "$KC" | LC_ALL=C sort | tr '\n' ' ')" "LICENSE.txt README.md bin conf data lib providers themes version.txt "
check "TC-971-13 no .stamp_* or .files-list* file" \
	"$(find "$KC" \( -name '.stamp_*' -o -name '.files-list*' \) | wc -l | tr -d ' ')" 0
check "TC-971-13 data links to /var/lib/rasputin/keycloak/data" "$(readlink "$KC/data")" /var/lib/rasputin/keycloak/data
check "TC-971-13 themes/rasputin links to the api's theme" "$(readlink "$KC/themes/rasputin")" /usr/share/rasputin/identity/theme
check "TC-971-13 conf/truststores/ is an empty directory" \
	"$([ -d "$KC/conf/truststores" ] && ls -A "$KC/conf/truststores" | wc -l | tr -d ' ')" 0
check "TC-971-13 providers/ holds no jar" "$(find "$KC/providers" -name '*.jar' | wc -l | tr -d ' ')" 0
check "TC-971-13 /usr/share/licenses/keycloak/LICENSE.txt is the dist's" \
	"$(cmp -s "$BUILDDIR/LICENSE.txt" "$T/usr/share/licenses/keycloak/LICENSE.txt" && echo equal || echo differs)" equal
check "TC-971-13 /usr/share/licenses/keycloak/SOURCE is the package's" \
	"$(cmp -s "$PKG/SOURCE" "$T/usr/share/licenses/keycloak/SOURCE" && echo equal || echo differs)" equal
check "TC-971-13 version.txt names the pin" "$(cat "$KC/version.txt")" "Keycloak - Version $PIN"

echo "── TC-971-14 persisted options equal the conf"
JAR="$KC/lib/quarkus/generated-bytecode.jar"
"$PKG/check-build-options.sh" "$CONF" "$JAR" > "$SCRATCH/opts" 2>&1; rc=$?
sed 's/^/   /' "$SCRATCH/opts"
check "TC-971-14 check-build-options.sh on the target's jar and conf exits 0" "$rc" 0
unzip -p "$JAR" META-INF/keycloak-persisted.properties > "$SCRATCH/persisted" \
	|| abort "The target's generated-bytecode.jar has no persisted properties."
sed 's/^/   persisted| /' "$SCRATCH/persisted"
grep -v '^#' "$SCRATCH/persisted" | sed '/^$/d' | LC_ALL=C sort > "$SCRATCH/persisted.set"
{ sed '/^[[:space:]]*$/d; /^[[:space:]]*#/d; s/^/kc./' "$CONF"; printf '%s\n' kc.optimized=true kc.profile=prod quarkus.profile=prod; } \
	| LC_ALL=C sort > "$SCRATCH/want.set"
check "TC-971-14 the persisted file is exactly the conf's $(($(wc -l < "$SCRATCH/want.set") - 3)) keys plus the 3 fixed keys" \
	"$(cmp -s "$SCRATCH/persisted.set" "$SCRATCH/want.set" && echo equal || echo differs)" equal

echo "── TC-971-15 identity/ installed unchanged"
diff -r "$API_DIR/identity" "$ID" > "$SCRATCH/diff" 2>&1; rc=$?
cat "$SCRATCH/diff"
check "TC-971-15 diff -r against the api tarball's identity/ exits 0" "$rc" 0
ls -lA "$ID" | sed 's/^/   /'
for f in keycloak-build.conf pins.json realm-baseline.json; do
	check "TC-971-15 $f is present" "$(yes_no [ -f "$ID/$f" ])" yes
done
check "TC-971-15 theme/ is a directory" "$(yes_no [ -d "$ID/theme" ])" yes

echo "── TC-971-22 CPE against NVD's CVE-2026-0871"
CPE=$(brmake -s --no-print-directory show-info | jq -r '.keycloak."cpe-id"')
# The update field is Buildroot's default, "-" (pkg-generic.mk, CPE_ID_UPDATE).
check "TC-971-22 show-info's cpe-id" "$CPE" "cpe:2.3:a:redhat:keycloak:$PIN:-:*:*:*:*:*:*"
cpe_at() { printf '%s\n' "$CPE" | awk -F: -v OFS=: -v v="$1" '{ $6 = v; print }'; }
got=$(cve_verdict "$BR" "$NVD/CVE-2026-0871.json" keycloak "$CPE") || got="matcher failed"
check "TC-971-22 CVE-2026-0871 at $CPE" "$got" DOESNT_AFFECT
got=$(cve_verdict "$BR" "$NVD/CVE-2026-0871.json" keycloak "$(cpe_at 26.3.0)") || got="matcher failed"
check "TC-971-22 CVE-2026-0871 at $(cpe_at 26.3.0)" "$got" AFFECTS

echo "── TC-971-19 legal-info"
brmake legal-info > "$OUT/legal-info.log" 2>&1; rc=$?
tail -n 5 "$OUT/legal-info.log"
check "TC-971-19 make legal-info exits 0 (licence hashes checked)" "$rc" 0
LI="$OUT/legal-info"
row=$(grep '^"keycloak",' "$LI/manifest.csv")
echo "   manifest.csv: $row"
check "TC-971-19 manifest.csv has one keycloak row" "$(printf '%s\n' "$row" | grep -c .)" 1
check "TC-971-19 the row names the pin, Apache-2.0 and the GPL-family licences, the source and its site" \
	"$(printf '%s\n' "$row" | grep -c "^\"keycloak\",\"$PIN\",\"Apache-2.0,.*GPL-2.0 with Classpath-exception-2.0.*LGPL-2.1+.*\",.*,\"$SRC_TGZ\",\"$SRC_SITE\",")" 1
SAVED="$LI/sources/keycloak-$PIN"
ls -l "$SAVED" | sed 's/^/   /'
check "TC-971-19 the source archive is saved" "$(yes_no [ -f "$SAVED/$SRC_TGZ" ])" yes
check "TC-971-19 its sha256 is its keycloak.hash line" \
	"$(sha256sum "$SAVED/$SRC_TGZ" 2>/dev/null | cut -d' ' -f1)" "$(awk -v n="$SRC_TGZ" '$1 == "sha256" && $3 == n { print $2 }' "$HASH")"
for u in $EXTRA; do
	j=$(basename "$u")
	check "TC-971-19 $j is saved" "$(yes_no [ -s "$SAVED/$j" ])" yes
done
check "TC-971-19 no binary dist is saved as source" \
	"$(find "$LI/sources" -name 'keycloak-quarkus-dist-*' | wc -l | tr -d ' ')" 0
check "TC-971-19 legal-info has LICENSE.txt" "$(yes_no [ -f "$LI/licenses/keycloak-$PIN/LICENSE.txt" ])" yes
# This config's Bootlin external toolchain has licence 'unknown' in Buildroot,
# which gpl-sources.py refuses; the images build their own toolchain, so that
# row is never in a release. The check reads every other row, keycloak's
# included, from this legal-info.
mkdir -p "$SCRATCH/li"
grep -v '^"toolchain-external-bootlin",' "$LI/manifest.csv" > "$SCRATCH/li/manifest.csv"
ln -s "$LI/sources" "$SCRATCH/li/sources"
check "TC-971-19 only the toolchain-external-bootlin row is left out" \
	"$(($(wc -l < "$LI/manifest.csv") - $(wc -l < "$SCRATCH/li/manifest.csv")))" 1
python3 -I "$ROOT/scripts/gpl-sources.py" legal-info "$SCRATCH/li" > "$SCRATCH/gpl" 2>&1; rc=$?
sed 's/^/   gpl-sources| /' "$SCRATCH/gpl"
check "TC-971-19 gpl-sources.py legal-info exits 0" "$rc" 0

echo "── TC-971-20 GPL-family source completeness"
# gpl_jars DIR... — the basename of every jar under DIR whose pom.xml
# licences, Bundle-License or top-level licence file names the GNU GPL or LGPL.
gpl_jars() {
	python3 -I - "$@" <<'PY'
import glob, os, re, sys, zipfile
pat = re.compile(r'GNU (Lesser |Library )?General Public License|\b(L|A)?GPL', re.I)
for root in sys.argv[1:]:
    for j in sorted(glob.glob(os.path.join(root, '**', '*.jar'), recursive=True)):
        z = zipfile.ZipFile(j)
        hit = False
        for n in z.namelist():
            b = os.path.basename(n).upper()
            if n.startswith('META-INF/maven') and n.endswith('pom.xml'):
                t = z.read(n).decode('utf8', 'replace')
                hit |= any(pat.search(m) for m in re.findall(r'<license>.*?<name>(.*?)</name>', t, re.S))
            elif n == 'META-INF/MANIFEST.MF':
                t = z.read(n).decode('utf8', 'replace').replace('\r\n ', '').replace('\n ', '')
                m = re.search(r'Bundle-License: (.*)', t)
                hit |= bool(m and pat.search(m.group(1)))
            elif n.count('/') <= 1 and b.startswith(('LICENSE', 'COPYING', 'LICENCE')):
                hit |= bool(pat.search(z.read(n).decode('utf8', 'replace')[:3000]))
        if hit:
            print(os.path.basename(j))
PY
}
# The jar names the list promises: <groupId>.<artifactId>-<version>.jar.
for c in $GPL_JARS; do
	printf '%s\n' "$c" | awk -F: '{ print $1 "." $2 "-" $3 ".jar" }'
done | LC_ALL=C sort > "$SCRATCH/listed"
# scan_vs_list DIR... — one sentence per jar the scan and the list disagree on.
scan_vs_list() {
	gpl_jars "$@" | LC_ALL=C sort > "$SCRATCH/scanned" || { echo "The jar scan failed."; return 1; }
	comm -23 "$SCRATCH/scanned" "$SCRATCH/listed" | sed 's/$/ names a GPL-family licence but has no -sources.jar in KEYCLOAK_GPL_JARS./'
	comm -13 "$SCRATCH/scanned" "$SCRATCH/listed" | sed 's/$/ is in KEYCLOAK_GPL_JARS but no installed jar by that name names a GPL-family licence./'
}
msg=$(scan_vs_list "$KC/lib")
check "TC-971-20 the GPL-family jars installed are exactly KEYCLOAK_GPL_JARS (16)" \
	"${msg:-none}:$(wc -l < "$SCRATCH/scanned" | tr -d ' ')" "none:16"
for c in $GPL_JARS; do
	j=$(printf '%s\n' "$c" | awk -F: '{ print $2 "-" $3 "-sources.jar" }')
	check "TC-971-20 $c: $j is in KEYCLOAK_EXTRA_DOWNLOADS and saved" \
		"$(printf '%s\n' $EXTRA | grep -c "/$j\$"):$(yes_no [ -s "$SAVED/$j" ])" "1:yes"
done
mkdir -p "$SCRATCH/fixture-lib"
python3 -I - "$SCRATCH/fixture-lib/org.example.gpl-thing-1.0.jar" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w")
z.writestr("META-INF/maven/org.example/gpl-thing/pom.xml",
           "<project><licenses><license><name>GNU General Public License, version 2</name></license></licenses></project>")
z.close()
PY
msg=$(scan_vs_list "$KC/lib" "$SCRATCH/fixture-lib")
check "TC-971-20 an extra GPL jar with no source listed fails, named" "$msg" \
	"org.example.gpl-thing-1.0.jar names a GPL-family licence but has no -sources.jar in KEYCLOAK_GPL_JARS."

echo "── TC-971-21 the dist's signature against the committed key"
export GNUPGHOME="$SCRATCH/gnupg"
mkdir -m 700 "$GNUPGHOME"
KEY_FPR=$(gpg --show-keys --with-colons "$KEY" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
check "TC-971-21 the committed key's primary fingerprint is the .mk anchor" "$KEY_FPR" "$FPR"
OTHER_FPR=$(gpg --show-keys --with-colons "$OTHER_KEY" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
check "TC-971-21 a key file with another fingerprint fails the anchor check" \
	"$([ -n "$OTHER_FPR" ] && [ "$OTHER_FPR" != "$FPR" ] && echo refused || echo accepted)" refused
gpg --batch --quiet --import "$KEY" 2>/dev/null
check "TC-971-21 the throwaway keyring holds only the committed key" \
	"$(gpg --batch --with-colons --list-keys 2>/dev/null | awk -F: '$1 == "pub"' | wc -l | tr -d ' ')" 1
file="$DL/$DIST"
check "TC-971-21 $DIST was downloaded" "$(yes_no [ -f "$file" ])" yes
[ -f "$file" ] || abort "The dist was not downloaded, so its signature cannot be checked."
check "TC-971-21 its sha256 is its keycloak.hash line" \
	"$(sha256sum "$file" | cut -d' ' -f1)" "$(awk -v n="$DIST" '$1 == "sha256" && $3 == n { print $2 }' "$HASH")"
curl -fsSL --retry 3 -o "$SCRATCH/$DIST.asc" "$SITE/$DIST.asc" \
	|| abort "$DIST.asc could not be downloaded from $SITE."
gpg --batch --status-fd 1 --verify "$SCRATCH/$DIST.asc" "$file" > "$SCRATCH/status" 2>/dev/null; rc=$?
sed 's/^/   status| /' "$SCRATCH/status"
check "TC-971-21 gpg --verify exits 0" "$rc" 0
has_line "TC-971-21 VALIDSIG by the anchor" "$SCRATCH/status" "^\\[GNUPG:\\] VALIDSIG .* $FPR\$"
cp "$file" "$SCRATCH/$DIST"
printf '\377' | dd of="$SCRATCH/$DIST" bs=1 seek=4096 count=1 conv=notrunc 2>/dev/null
check "TC-971-21 the tampered copy differs from the original" \
	"$(cmp -s "$file" "$SCRATCH/$DIST" && echo same || echo differs)" differs
gpg --batch --status-fd 1 --verify "$SCRATCH/$DIST.asc" "$SCRATCH/$DIST" > "$SCRATCH/status" 2>/dev/null; rc=$?
sed 's/^/   status| /' "$SCRATCH/status"
check "TC-971-21 tampered copy: gpg exits non-zero" "$(nonzero "$rc")" non-zero
has_line "TC-971-21 tampered copy: BADSIG" "$SCRATCH/status" '^\[GNUPG:\] BADSIG '
"$BR/support/download/check-hash" "$file" "$DIST" "$HASH" > "$SCRATCH/ch" 2>&1; rc=$?
check "TC-971-21 check-hash accepts $DIST" "$rc" 0
"$BR/support/download/check-hash" "$SCRATCH/$DIST" "$DIST" "$HASH" > "$SCRATCH/ch" 2>&1; rc=$?
sed 's/^/   check-hash| /' "$SCRATCH/ch"
check "TC-971-21 check-hash refuses the tampered copy" "$rc" 2
has_line "TC-971-21 and names it" "$SCRATCH/ch" "^ERROR: $DIST has wrong sha256 hash:"
# A .asc made by a throwaway key, in its own keyring, checked in the
# committed-key keyring.
OTHER_HOME="$SCRATCH/gnupg-other"
mkdir -m 700 "$OTHER_HOME"
GNUPGHOME="$OTHER_HOME" gpg --batch --quiet --passphrase '' --quick-gen-key 'throwaway <throwaway@example.invalid>' ed25519 sign never 2>/dev/null \
	&& GNUPGHOME="$OTHER_HOME" gpg --batch --quiet --armor --detach-sign -o "$SCRATCH/other.asc" "$file" 2>/dev/null \
	|| abort "A throwaway key could not sign the dist, so the wrong-key control cannot run."
gpg --batch --status-fd 1 --verify "$SCRATCH/other.asc" "$file" > "$SCRATCH/status" 2>/dev/null; rc=$?
sed 's/^/   status| /' "$SCRATCH/status"
check "TC-971-21 a .asc by another key: gpg exits non-zero" "$(nonzero "$rc")" non-zero
has_line "TC-971-21 a .asc by another key: ERRSIG" "$SCRATCH/status" '^\[GNUPG:\] ERRSIG '
has_line "TC-971-21 a .asc by another key: NO_PUBKEY" "$SCRATCH/status" '^\[GNUPG:\] NO_PUBKEY '
rm -f "$SCRATCH/$DIST"
unset GNUPGHOME

# The destructive cases. Each edits the installed identity/ and rebuilds
# keycloak from a clean build directory; each edit is undone after.
cp "$CONF" "$SCRATCH/conf.orig"
cp "$PINS" "$SCRATCH/pins.orig"
rebuild() { # rebuild LOG — keycloak from scratch, then the rest of make
	brmake keycloak-dirclean > /dev/null 2>&1
	brmake > "$1" 2>&1
}

echo "── TC-971-16 (a) an unknown option fails the build"
echo 'bogus-option=1' >> "$CONF"
rebuild "$OUT/bogus.log"; rc=$?
tail -n 8 "$OUT/bogus.log"
check "TC-971-16 (a) make exits non-zero" "$(nonzero "$rc")" non-zero
has_line "TC-971-16 (a) the log names bogus-option as unknown or misspelt" "$OUT/bogus.log" \
	'keycloak-build\.conf sets bogus-option=1, which Keycloak did not persist: an unknown or misspelt option\.$'
cp "$SCRATCH/conf.orig" "$CONF"

echo "── TC-971-16 (b) an unknown feature fails the build"
sed 's/^features-disabled=/features-disabled=no-such-feature,/' "$SCRATCH/conf.orig" > "$CONF"
check "TC-971-16 (b) the conf now disables no-such-feature" "$(grep -c '^features-disabled=no-such-feature,' "$CONF")" 1
rebuild "$OUT/feature.log"; rc=$?
tail -n 8 "$OUT/feature.log"
check "TC-971-16 (b) make exits non-zero" "$(nonzero "$rc")" non-zero
has_line "TC-971-16 (b) Keycloak's exit 2 is wrapped in a sentence naming the conf" "$OUT/feature.log" \
	'^kc\.sh build exited 2 on the build options in .*/usr/share/rasputin/identity/keycloak-build\.conf, so Keycloak cannot be built with them; its own output is above\.$'
has_line "TC-971-16 (b) Keycloak's own output stays in the log" "$OUT/feature.log" 'no-such-feature'
cp "$SCRATCH/conf.orig" "$CONF"

echo "── TC-971-17 a pin mismatch fails in the pin hook"
jq '.keycloak.release = "26.8.1"' "$SCRATCH/pins.orig" > "$PINS"
rebuild "$OUT/pins.log"; rc=$?
tail -n 8 "$OUT/pins.log"
check "TC-971-17 make exits non-zero" "$(nonzero "$rc")" non-zero
has_line "TC-971-17 the hook names keycloak.release, 26.8.1 and $PIN" "$OUT/pins.log" \
	"^The api's pins\\.json has keycloak\\.release 26\\.8\\.1 but package/keycloak/keycloak\\.mk has $PIN, "
lacks_line "TC-971-17 kc.sh build never ran" "$OUT/pins.log" 'Updating the configuration|Server configuration updated|kc\.sh build exited'
cp "$SCRATCH/pins.orig" "$PINS"

echo "── TC-971-18 a missing identity/ fails rasputin-api's install"
rm -rf "$API_DIR/identity"
# An override package re-syncs its source directory on reinstall, so under
# the local override the override points at a copy without identity/ too.
if [ -n "${RASPUTIN_API_LOCAL_DIR:-}" ]; then
	cp -R "$RASPUTIN_API_LOCAL_DIR" "$SCRATCH/api-no-identity"
	rm -rf "$SCRATCH/api-no-identity/identity"
	printf 'RASPUTIN_API_OVERRIDE_SRCDIR = %s\n' "$SCRATCH/api-no-identity" > "$OUT/local.mk"
fi
brmake rasputin-api-reinstall > "$OUT/no-identity.log" 2>&1; rc=$?
tail -n 8 "$OUT/no-identity.log"
check "TC-971-18 make exits non-zero" "$(nonzero "$rc")" non-zero
has_line "TC-971-18 the cp failure line" "$OUT/no-identity.log" "^cp: .*identity/\\.'?: No such file or directory\$"

finish
