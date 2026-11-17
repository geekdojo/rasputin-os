#!/bin/sh
# Functional test for package/temurin-jre (geekdojo/geekdojo-brain#969): the
# package built by the pinned Buildroot, for real, on one target architecture.
# CI runs it in the temurin-jre job, one leg per architecture (aarch64 and
# x86_64), because the binaries differ per architecture (SEC-PLATFORM).
#
# Both defconfigs carry the package since Identity 2.3 (keycloak selects it),
# but only the release build reaches its install, its NEEDED hook and
# legal-info. This builds a minimal
# config with the Bootlin glibc stable external toolchain (no toolchain build),
# no init, no /bin/sh, no busybox and no rootfs image, plus the package, then:
#
#   TC-969-10  make succeeds, check-needed reports success, the install has
#              exactly the release's top level, no Buildroot stamp files, no
#              desktop libraries, the licences, and the host keytool.
#   TC-969-11  lib/security/jssecacerts is a non-empty PKCS-12 store with no
#              entries.
#   TC-969-05  legal-info saves the source tarball, not the binary, for target
#              and host, and the licence files pass legal-info's hash check.
#   TC-969-12  the cpe-id show-info gives, run through the pinned Buildroot's
#              own CVE matcher (support/scripts/cve.py, what cve-watch uses)
#              against NVD snapshots of CVE-2025-53057 and CVE-2026-21932
#              (test/fixtures/nvd/, from github.com/fkie-cad/nvd-json-data-feeds
#              at commit 2ea002cc3b166ddbd3dfaf54371d7e6729fac92a). The pin is
#              not affected; the same vendor and product at an affected version
#              is; oracle:openjdk, the control, is not.
#   TC-969-07  every tarball Buildroot downloaded on this leg: its sha256 is its
#              one temurin-jre.hash line, and Adoptium's signature over it
#              verifies with gpg against the committed key, whose fingerprint
#              is the .mk's anchor. A one-byte-tampered copy gives BADSIG.
#              The gpg status lines below are this run's transcript.
#   TC-969-03  Buildroot's own check-hash refuses the tampered copy (exit 2)
#              and accepts the original (exit 0).
#   TC-969-04  with libm.so.6 deleted from the target, make fails, and fails
#              in check-needed, naming libm.so.6.
#
# What this does NOT prove: the JRE booting or running on an image, or the
# internal Buildroot glibc toolchain the image uses (same sonames).
#
# Needs: network access (Adoptium's release site, Bootlin), GNU make, gcc and
# Buildroot's host prerequisites, gpg, jq, curl, sha256sum, and python3 with
# setuptools (Buildroot's cve.py imports distutils, which Python 3.12 dropped).
# Any of them missing is a failure, never a skip.
#
# Run, from the repo root, on an x86_64 Linux host (the Bootlin toolchains
# are x86_64 binaries):
#   ./scripts/init-buildroot.sh && sh test/temurin-jre-functional.sh aarch64
#   ./scripts/init-buildroot.sh && sh test/temurin-jre-functional.sh x86_64
# The build goes to output/temurin-jre-<arch>/ (TEMURIN_JRE_FUNC_OUT
# overrides it) and takes a few minutes, most of it downloads.
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

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BR="$ROOT/buildroot"
PKG="$ROOT/package/temurin-jre"
HASH="$PKG/temurin-jre.hash"
KEY="$PKG/adoptium-signing-key.asc"
NVD="$ROOT/test/fixtures/nvd"
OUT="${TEMURIN_JRE_FUNC_OUT:-$ROOT/output/temurin-jre-$ARCH}"
T="$OUT/target"

. "$ROOT/test/lib/cve-verdict.sh"

[ -f "$BR/Makefile" ] || { echo "FAIL — The pinned Buildroot is not checked out at $BR. Run ./scripts/init-buildroot.sh first."; exit 1; }
for t in make gpg jq curl sha256sum python3 cmp; do
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
finish() {
	echo
	if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
	echo "all Temurin JRE functional checks passed ($ARCH)"
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
cat > "$OUT/temurin-jre.defconfig" <<EOF
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
# BR2_PACKAGE_RASPUTIN_API is not set
# BR2_TARGET_ROOTFS_TAR is not set
BR2_PACKAGE_TEMURIN_JRE=y
EOF
brmake defconfig BR2_DEFCONFIG="$OUT/temurin-jre.defconfig" > "$OUT/defconfig.log" 2>&1 \
	|| { cat "$OUT/defconfig.log"; abort "make defconfig failed."; }
# Kconfig drops a symbol whose dependencies are unmet without a word, so the
# config the test means to build is checked, not assumed.
for sym in BR2_PACKAGE_TEMURIN_JRE=y BR2_TOOLCHAIN_USES_GLIBC=y BR2_INIT_NONE=y BR2_SYSTEM_BIN_SH_NONE=y; do
	check "config has $sym" "$(grep -cxF "$sym" "$OUT/.config")" 1
done
# The external tree's default-y packages are off too, so the build is the
# toolchain, the skeleton and this package.
for sym in BUSYBOX CADDY RASPUTIN_AGENT RASPUTIN_API; do
	check "config has no BR2_PACKAGE_$sym" "$(grep -cx "BR2_PACKAGE_$sym=y" "$OUT/.config")" 0
done

# Everything below is read from the package as Buildroot evaluates it.
VARS=$(brmake -s --no-print-directory printvars \
	VARS="TEMURIN_JRE_VERSION TEMURIN_JRE_SOURCE HOST_TEMURIN_JRE_SOURCE TEMURIN_JRE_ACTUAL_SOURCE_TARBALL TEMURIN_JRE_SITE TEMURIN_JRE_ADOPTIUM_SIGNER_FPR TEMURIN_JRE_DL_DIR TEMURIN_JRE_DIR TEMURIN_JRE_LICENSE_FILES") \
	|| abort "make printvars failed."
var() { printf '%s\n' "$VARS" | sed -n "s/^$1=//p"; }
PIN=$(var TEMURIN_JRE_VERSION)
SITE=$(var TEMURIN_JRE_SITE)
FPR=$(var TEMURIN_JRE_ADOPTIUM_SIGNER_FPR)
DL=$(var TEMURIN_JRE_DL_DIR)
SRCDIR=$(var TEMURIN_JRE_DIR)
SRC_TGZ=$(var TEMURIN_JRE_ACTUAL_SOURCE_TARBALL)
LICENSE_FILES=$(var TEMURIN_JRE_LICENSE_FILES)
DOWNLOADS=$(printf '%s\n' "$(var TEMURIN_JRE_SOURCE)" "$(var HOST_TEMURIN_JRE_SOURCE)" "$SRC_TGZ" | sort -u)
for v in PIN SITE FPR DL SRCDIR SRC_TGZ LICENSE_FILES; do
	eval "[ -n \"\$$v\" ]" || abort "Buildroot gave no value for $v, so nothing below has anything to compare against."
done
echo "pin $PIN; downloads on this leg:"; printf '  %s\n' $DOWNLOADS

echo "── TC-969-10 real build"
brmake > "$OUT/build.log" 2>&1; rc=$?
tail -n 20 "$OUT/build.log"
check "TC-969-10 make exits 0" "$rc" 0
[ "$rc" = 0 ] || abort "The build failed, so nothing after it can be checked; the log is $OUT/build.log."
has_line "TC-969-10 check-needed's success line, with a count" "$OUT/build.log" \
	'^check-needed: every NEEDED library of the [1-9][0-9]* ELF files under usr/lib/temurin-jre is in the image\.$'
JRE="$T/usr/lib/temurin-jre"
check "TC-969-10 top level is exactly the release's" \
	"$(ls -A "$JRE" | LC_ALL=C sort | tr '\n' ' ')" "NOTICE bin conf legal lib release "
check "TC-969-10 no .stamp_* or .files-list* file" \
	"$(find "$JRE" \( -name '.stamp_*' -o -name '.files-list*' \) | wc -l | tr -d ' ')" 0
for lib in libawt_xawt.so libjawt.so libsplashscreen.so libjsound.so; do
	check "TC-969-10 $lib is not installed" "$(find "$JRE" -name "$lib" | wc -l | tr -d ' ')" 0
done
for f in $LICENSE_FILES; do
	b=$(basename "$f")
	if cmp -s "$SRCDIR/$f" "$T/usr/share/licenses/temurin-jre/$b"; then r=equal; else r=differs; fi
	check "TC-969-10 /usr/share/licenses/temurin-jre/$b is the tarball's $f" "$r" equal
done
KEYTOOL="$OUT/host/lib/temurin-jre/bin/keytool"
check "TC-969-10 the host keytool is installed" "$([ -x "$KEYTOOL" ] && echo yes || echo no)" yes

echo "── TC-969-11 empty jssecacerts"
JSSE="$JRE/lib/security/jssecacerts"
check "TC-969-11 jssecacerts is a non-empty file" "$([ -s "$JSSE" ] && echo yes || echo no)" yes
"$KEYTOOL" -list -storetype PKCS12 -storepass changeit -keystore "$JSSE" > "$SCRATCH/list" 2>&1; rc=$?
sed 's/^/   keytool| /' "$SCRATCH/list"
check "TC-969-11 keytool -list exits 0" "$rc" 0
check "TC-969-11 keytool reports no entries" "$(grep -cx 'Your keystore contains 0 entries' "$SCRATCH/list")" 1

echo "── TC-969-05 legal-info"
brmake legal-info > "$OUT/legal-info.log" 2>&1; rc=$?
check "TC-969-05 make legal-info exits 0 (licence hashes checked)" "$rc" 0
LI="$OUT/legal-info"
# Buildroot names a host package by its raw name in host-manifest.csv, so
# host-temurin-jre's row there is "temurin-jre" too.
for m in manifest.csv host-manifest.csv; do
	set -- "$m" temurin-jre
	row=$(grep "^\"$2\"," "$LI/$1")
	echo "   $1: $row"
	check "TC-969-05 $1 has one $2 row" "$(printf '%s\n' "$row" | grep -c .)" 1
	check "TC-969-05 $1's $2 row names the pin, the source tarball and the site" \
		"$(printf '%s\n' "$row" | grep -c "^\"$2\",\"$PIN\",.*,\"$SRC_TGZ\",\"$SITE\",")" 1
done
SAVED="$LI/sources/temurin-jre-$PIN/$SRC_TGZ"
ls -l "$LI/sources/temurin-jre-$PIN/" "$LI/host-sources/" | sed 's/^/   /'
check "TC-969-05 the source tarball is saved" "$([ -f "$SAVED" ] && echo yes || echo no)" yes
check "TC-969-05 its sha256 is its temurin-jre.hash line" \
	"$(sha256sum "$SAVED" 2>/dev/null | cut -d' ' -f1)" "$(awk -v n="$SRC_TGZ" '$1 == "sha256" && $3 == n { print $2 }' "$HASH")"
check "TC-969-05 no binary tarball is saved as source" \
	"$(find "$LI/sources" "$LI/host-sources" -name 'OpenJDK*U-jre_*' | wc -l | tr -d ' ')" 0
for f in $LICENSE_FILES; do
	check "TC-969-05 legal-info has $f" \
		"$([ -f "$LI/licenses/temurin-jre-$PIN/$f" ] && echo yes || echo no)" yes
done

echo "── TC-969-12 CPE against NVD's Java SE 25 records"
CPE=$(brmake -s --no-print-directory show-info | jq -r '."temurin-jre"."cpe-id"')
check "TC-969-12 show-info's cpe-id" "$CPE" 'cpe:2.3:a:oracle:jre:25.0.5:-:*:*:*:*:*:*'
# cpe_at VERSION [PRODUCT] — the show-info id with the version (and product)
# replaced, so every case below is Buildroot's own id but for that field.
cpe_at() { printf '%s\n' "$CPE" | awk -F: -v OFS=: -v v="$1" -v p="${2:-}" '{ $6 = v; if (p != "") $5 = p; print }'; }
# verdict CVE CPEID — prints AFFECTS, DOESNT_AFFECT or UNKNOWN
verdict() { cve_verdict "$BR" "$NVD/$1.json" temurin-jre "$2"; }
case_row() { # case_row CVE CPEID WANT
	got=$(verdict "$1" "$2") || got="matcher failed"
	check "TC-969-12 $1 at $2" "$got" "$3"
}
case_row CVE-2025-53057 "$CPE" DOESNT_AFFECT
case_row CVE-2026-21932 "$CPE" DOESNT_AFFECT
case_row CVE-2026-21932 "$(cpe_at 25.0.1)" AFFECTS
case_row CVE-2025-53057 "$(cpe_at 25)" AFFECTS
case_row CVE-2026-21932 "$(cpe_at 25.0.1 openjdk)" DOESNT_AFFECT

echo "── TC-969-07 / TC-969-03 hash provenance and tamper"
export GNUPGHOME="$SCRATCH/gnupg"
mkdir -m 700 "$GNUPGHOME"
KEY_FPR=$(gpg --show-keys --with-colons "$KEY" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
check "TC-969-07 the committed key's primary fingerprint is the .mk anchor" "$KEY_FPR" "$FPR"
gpg --batch --quiet --import "$KEY" 2>/dev/null
check "TC-969-07 the throwaway keyring holds only the committed key" \
	"$(gpg --batch --with-colons --list-keys 2>/dev/null | awk -F: '$1 == "pub"' | wc -l | tr -d ' ')" 1
for f in $DOWNLOADS; do
	echo "== $f"
	file="$DL/$f"
	check "TC-969-07 $f was downloaded" "$([ -f "$file" ] && echo yes || echo no)" yes
	[ -f "$file" ] || continue
	check "TC-969-07 $f has exactly one hash line" \
		"$(awk -v n="$f" '$1 == "sha256" && $3 == n' "$HASH" | wc -l | tr -d ' ')" 1
	check "TC-969-07 $f's sha256 is its hash line" \
		"$(sha256sum "$file" | cut -d' ' -f1)" "$(awk -v n="$f" '$1 == "sha256" && $3 == n { print $2 }' "$HASH")"
	curl -fsSL --retry 3 -o "$SCRATCH/$f.sig" "$SITE/$f.sig" \
		|| { check "TC-969-07 $f.sig downloaded from $SITE" failed ok; continue; }
	gpg --batch --status-fd 1 --verify "$SCRATCH/$f.sig" "$file" > "$SCRATCH/status" 2>/dev/null; rc=$?
	sed 's/^/   status| /' "$SCRATCH/status"
	check "TC-969-07 gpg --verify $f exits 0" "$rc" 0
	has_line "TC-969-07 GOODSIG" "$SCRATCH/status" '^\[GNUPG:\] GOODSIG '
	has_line "TC-969-07 VALIDSIG by the anchor" "$SCRATCH/status" "^\\[GNUPG:\\] VALIDSIG .* $FPR\$"
	# The negative control: one byte changed in a copy.
	cp "$file" "$SCRATCH/$f"
	printf '\377' | dd of="$SCRATCH/$f" bs=1 seek=4096 count=1 conv=notrunc 2>/dev/null
	check "TC-969-07 the tampered copy differs from the original" \
		"$(cmp -s "$file" "$SCRATCH/$f" && echo same || echo differs)" differs
	gpg --batch --status-fd 1 --verify "$SCRATCH/$f.sig" "$SCRATCH/$f" > "$SCRATCH/status" 2>/dev/null; rc=$?
	sed 's/^/   status| /' "$SCRATCH/status"
	check "TC-969-07 tampered copy: gpg exits non-zero" "$([ "$rc" -ne 0 ] && echo non-zero || echo 0)" non-zero
	has_line "TC-969-07 tampered copy: BADSIG" "$SCRATCH/status" '^\[GNUPG:\] BADSIG '
	# TC-969-03: Buildroot's own download check, on the same pair.
	"$BR/support/download/check-hash" "$file" "$f" "$HASH" > "$SCRATCH/ch" 2>&1; rc=$?
	sed 's/^/   check-hash| /' "$SCRATCH/ch"
	check "TC-969-03 check-hash accepts $f" "$rc" 0
	"$BR/support/download/check-hash" "$SCRATCH/$f" "$f" "$HASH" > "$SCRATCH/ch" 2>&1; rc=$?
	sed 's/^/   check-hash| /' "$SCRATCH/ch"
	check "TC-969-03 check-hash refuses the tampered $f" "$rc" 2
	has_line "TC-969-03 and names it" "$SCRATCH/ch" "^ERROR: $f has wrong sha256 hash:"
	rm -f "$SCRATCH/$f"
done

echo "── TC-969-04 a missing NEEDED library fails the build"
removed=0
for d in lib lib64 usr/lib usr/lib64; do
	if [ -e "$T/$d/libm.so.6" ] || [ -L "$T/$d/libm.so.6" ]; then
		real=$(readlink -f "$T/$d/libm.so.6")
		rm -f "$T/$d/libm.so.6"
		# Its resolved file too, but never anything outside the target.
		case "$real" in "$T"/*) rm -f "$real" ;; esac
		removed=1
	fi
done
check "TC-969-04 libm.so.6 was in the target and is removed" "$removed" 1
brmake > "$OUT/needed.log" 2>&1; rc=$?
tail -n 20 "$OUT/needed.log"
check "TC-969-04 make exits non-zero" "$([ "$rc" -ne 0 ] && echo non-zero || echo 0)" non-zero
has_line "TC-969-04 check-needed names libm.so.6" "$OUT/needed.log" \
	'^usr/lib/temurin-jre/.* needs libm\.so\.6, which is not in the image\.$'
has_line "TC-969-04 then its summary" "$OUT/needed.log" \
	'^The image is missing NEEDED libraries of the Temurin JRE \(count: [1-9][0-9]*\), so the runtime would fail to load on the node\.$'

finish
