#!/bin/sh
# Tests for package/temurin-jre, the pinned Java runtime
# (geekdojo/geekdojo-brain#969). What can be wrong in the package without a
# Buildroot run noticing, pinned here:
#
#   * the per-arch tarball maps, target and host. An architecture they do not
#     know must fail the build when the runtime is on, and only then, with a
#     sentence (TC-969-01, TC-969-02);
#   * temurin-jre.hash covers exactly the three tarballs and the three licence
#     files, one line each, and the actual-source variables point legal-info
#     at the source tarball for target and host (TC-969-06);
#   * check-needed.sh, the NEEDED-library hook, on synthetic ELFs compiled
#     here and read by the real readelf: it passes, names a miss, ignores
#     non-ELF files, and fails closed (TC-969-08, TC-969-09);
#   * no defconfig enables the package, and its Config.in has the glibc
#     dependency and no architecture one (TC-969-15).
#
# The .mk file is evaluated with REAL GNU make through test/lib/mk-var.sh.
# No make, no cc and no readelf are failures, not skips.
#
# What this does NOT prove: that Buildroot downloads, installs or runs any of
# it. test/temurin-jre-functional.sh does that, in the temurin-jre CI job.
#
# Run:  sh test/temurin-jre-package-test.sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PKG="$ROOT/package/temurin-jre"
MK="$PKG/temurin-jre.mk"
HASH="$PKG/temurin-jre.hash"
CHECK="$PKG/check-needed.sh"
. "$ROOT/test/lib/mk-var.sh"

for f in "$MK" "$HASH" "$CHECK" "$PKG/Config.in"; do
	[ -f "$f" ] || { echo "FAIL — missing: $f"; exit 1; }
done
case "$(make --version 2>/dev/null)" in
	"GNU Make"*) ;;
	*) echo "FAIL — GNU make is not on PATH. This suite evaluates temurin-jre.mk with it and never skips."; exit 1 ;;
esac
for t in cc readelf; do
	command -v "$t" >/dev/null 2>&1 || { echo "FAIL — $t is not on PATH. The check-needed cases need it and this suite never skips them."; exit 1; }
done

fails=0
check() { # check LABEL GOT WANT
	if [ "$2" = "$3" ]; then echo "ok   — $1 ($2)"
	else echo "FAIL — $1: expected '$3', got '$2'"; fails=$((fails + 1)); fi
}
contains() { # contains LABEL HAYSTACK NEEDLE
	case "$2" in
		*"$3"*) echo "ok   — $1" ;;
		*) echo "FAIL — $1: '$3' not in: $2"; fails=$((fails + 1)) ;;
	esac
}
lacks() { # lacks LABEL HAYSTACK NEEDLE
	case "$2" in
		*"$3"*) echo "FAIL — $1: '$3' is in: $2"; fails=$((fails + 1)) ;;
		*) echo "ok   — $1" ;;
	esac
}
has_line_ending() { # has_line_ending LABEL TEXT LINE — some line of TEXT is
	# LINE exactly, after make's "<file>:<line>: " location prefix.
	_found=0
	while IFS= read -r _l; do
		case "$_l" in *": $3") _found=1 ;; esac
	done <<EOF_LINES
$2
EOF_LINES
	if [ "$_found" = 1 ]; then echo "ok   — $1"
	else echo "FAIL — $1: no line ending ': $3' in: $2"; fails=$((fails + 1)); fi
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# map_row LABEL MKFILE VAR WANT_STATUS WANT NAME=VALUE... — evaluate VAR.
# WANT is the value on success, or the exact error line on failure.
map_row() {
	_label="$1"; _mk="$2"; _var="$3"; _want_rc="$4"; _want="$5"; shift 5
	_out=$(mk_var "$_mk" "$_var" "$@" 2> "$TMP/err"); _rc=$?
	_err=$(cat "$TMP/err")
	if [ "$_want_rc" = 0 ]; then
		check "$_label: exit status" "$_rc" 0
		check "$_label: $_var" "$_out" "$_want"
	else
		check "$_label: exit status is non-zero" "$([ "$_rc" -ne 0 ] && echo non-zero || echo 0)" non-zero
		check "$_label: nothing on stdout" "$_out" ""
		has_line_ending "$_label: stderr carries the line the reader sees" "$_err" "$_want"
		lacks "$_label: no doubled full stop" "$_err" ".."
	fi
}

PIN=$(mk_var "$MK" TEMURIN_JRE_VERSION) || { echo "FAIL — Could not read the pin, so nothing below has anything to compare against."; exit 1; }
check "the pin" "$PIN" "25.0.5+8"
FV=25.0.5_8
SITE="https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.5%2B8"
AARCH64_TGZ="OpenJDK25U-jre_aarch64_linux_hotspot_${FV}.tar.gz"
X64_TGZ="OpenJDK25U-jre_x64_linux_hotspot_${FV}.tar.gz"
SRC_TGZ="OpenJDK25U-jdk-sources_${FV}.tar.gz"
ON="BR2_PACKAGE_TEMURIN_JRE=y"
X86HOST="HOSTARCH=x86_64"

echo "── target tarball map"
# TC-969-01
map_row "TC-969-01 aarch64" "$MK" TEMURIN_JRE_SOURCE 0 "$AARCH64_TGZ" "$ON" BR2_aarch64=y BR2_ARCH=aarch64 "$X86HOST"
map_row "TC-969-01 x86_64" "$MK" TEMURIN_JRE_SOURCE 0 "$X64_TGZ" "$ON" BR2_x86_64=y BR2_ARCH=x86_64 "$X86HOST"
for a in arm riscv; do
	map_row "TC-969-01 package on, $a" "$MK" TEMURIN_JRE_SOURCE 1 \
		"*** Temurin JRE has no release tarball mapped for the target architecture $a. Add the architecture to the map in package/temurin-jre/temurin-jre.mk and its sha256 to temurin-jre.hash.  Stop." \
		"$ON" "BR2_$a=y" "BR2_ARCH=$a" "$X86HOST"
done
_out=$(mk_var "$MK" TEMURIN_JRE_VERSION BR2_arm=y BR2_ARCH=arm 2> "$TMP/err"); _rc=$?
check "TC-969-01 package off, arm: exit status" "$_rc" 0
check "TC-969-01 package off, arm: no error on stderr" "$(cat "$TMP/err")" ""
# Negative control: a copy with the x86_64 mapping removed must fail x86_64,
# so the rows above can tell a working map from a broken one.
awk '/^else ifeq \(\$\(BR2_x86_64\),y\)$/ { skip = 2 } skip > 0 { skip--; next } { print }' "$MK" > "$TMP/no-x64.mk"
check "TC-969-01 the broken copy lacks exactly the x86_64 mapping" "$(diff "$MK" "$TMP/no-x64.mk" | grep -c '^<')" 2
map_row "TC-969-01 broken copy, x86_64" "$TMP/no-x64.mk" TEMURIN_JRE_SOURCE 1 \
	"*** Temurin JRE has no release tarball mapped for the target architecture x86_64. Add the architecture to the map in package/temurin-jre/temurin-jre.mk and its sha256 to temurin-jre.hash.  Stop." \
	"$ON" BR2_x86_64=y BR2_ARCH=x86_64 "$X86HOST"

echo "── host tarball map, one pin"
# TC-969-02
map_row "TC-969-02 host x86_64" "$MK" HOST_TEMURIN_JRE_SOURCE 0 "$X64_TGZ" "$ON" BR2_aarch64=y BR2_ARCH=aarch64 HOSTARCH=x86_64
map_row "TC-969-02 host aarch64" "$MK" HOST_TEMURIN_JRE_SOURCE 0 "$AARCH64_TGZ" "$ON" BR2_aarch64=y BR2_ARCH=aarch64 HOSTARCH=aarch64
check "TC-969-02 HOST_TEMURIN_JRE_VERSION is the pin" \
	"$(mk_var "$MK" HOST_TEMURIN_JRE_VERSION "$ON" BR2_aarch64=y BR2_ARCH=aarch64 "$X86HOST")" "$PIN"
map_row "TC-969-02 host riscv64" "$MK" HOST_TEMURIN_JRE_SOURCE 1 \
	"*** Temurin JRE has no release tarball mapped for the build host architecture riscv64. Add the architecture to the map in package/temurin-jre/temurin-jre.mk and its sha256 to temurin-jre.hash.  Stop." \
	"$ON" BR2_aarch64=y BR2_ARCH=aarch64 HOSTARCH=riscv64

echo "── temurin-jre.hash and the actual-source variables"
# TC-969-06
LICENSES="legal/java.base/LICENSE legal/java.base/ASSEMBLY_EXCEPTION legal/java.base/ADDITIONAL_LICENSE_INFO"
check "TC-969-06 TEMURIN_JRE_LICENSE_FILES" "$(mk_var "$MK" TEMURIN_JRE_LICENSE_FILES)" "$LICENSES"
# check_hash HASHFILE — exactly one sha256 line for each tarball and licence
# file, and no other tarball line. One sentence per problem; status 1 if any.
check_hash() {
	_hf="$1"
	_bad=0
	for _name in "$AARCH64_TGZ" "$X64_TGZ" "$SRC_TGZ" $LICENSES; do
		_n=$(grep -cE "^sha256[[:space:]]+[0-9a-f]{64}[[:space:]]+$(printf '%s' "$_name" | sed 's/\./\\./g')\$" "$_hf")
		if [ "$_n" -ne 1 ]; then
			echo "temurin-jre.hash has $_n sha256 lines for $_name, and needs exactly one."
			_bad=1
		fi
	done
	_others=$(grep -E '\.tar\.gz[[:space:]]*$' "$_hf" | grep -v '^#' | awk '{ print $3 }' \
		| grep -vxF -e "$AARCH64_TGZ" -e "$X64_TGZ" -e "$SRC_TGZ")
	if [ -n "$_others" ]; then
		echo "temurin-jre.hash has a line for $_others, which the package never downloads."
		_bad=1
	fi
	return "$_bad"
}
_msg=$(check_hash "$HASH"); _rc=$?
check "TC-969-06 the real temurin-jre.hash passes${_msg:+: $_msg}" "$_rc" 0
grep -v " $X64_TGZ\$" "$HASH" > "$TMP/hash-removed"
_msg=$(check_hash "$TMP/hash-removed"); _rc=$?
check "TC-969-06 a copy without the x64 line fails" "$_rc" 1
contains "TC-969-06 and says why" "$_msg" "temurin-jre.hash has 0 sha256 lines for $X64_TGZ, and needs exactly one."
{ cat "$HASH"; grep " legal/java.base/LICENSE\$" "$HASH"; } > "$TMP/hash-dup"
_msg=$(check_hash "$TMP/hash-dup"); _rc=$?
check "TC-969-06 a copy with the LICENSE line duplicated fails" "$_rc" 1
contains "TC-969-06 and says why" "$_msg" "temurin-jre.hash has 2 sha256 lines for legal/java.base/LICENSE, and needs exactly one."
{ cat "$HASH"; echo "sha256  $(printf '%064d' 0)  OpenJDK25U-jre_riscv64_linux_hotspot_${FV}.tar.gz"; } > "$TMP/hash-extra"
_msg=$(check_hash "$TMP/hash-extra"); _rc=$?
check "TC-969-06 a copy with an extra tarball line fails" "$_rc" 1
contains "TC-969-06 and says why" "$_msg" "temurin-jre.hash has a line for OpenJDK25U-jre_riscv64_linux_hotspot_${FV}.tar.gz, which the package never downloads."
for v in TEMURIN_JRE HOST_TEMURIN_JRE; do
	check "TC-969-06 ${v}_ACTUAL_SOURCE_TARBALL" "$(mk_var "$MK" "${v}_ACTUAL_SOURCE_TARBALL")" "$SRC_TGZ"
	check "TC-969-06 ${v}_ACTUAL_SOURCE_SITE" "$(mk_var "$MK" "${v}_ACTUAL_SOURCE_SITE")" "$SITE"
done
check "TC-969-06 TEMURIN_JRE_SITE" "$(mk_var "$MK" TEMURIN_JRE_SITE)" "$SITE"

echo "── Config.in and the defconfigs"
# TC-969-15
check "TC-969-15 no defconfig sets BR2_PACKAGE_TEMURIN_JRE" \
	"$(grep -rl 'BR2_PACKAGE_TEMURIN_JRE' "$ROOT/configs" | wc -l | tr -d ' ')" 0
check "TC-969-15 Config.in depends on a glibc toolchain" \
	"$(grep -cxE '[[:space:]]*depends on BR2_TOOLCHAIN_USES_GLIBC' "$PKG/Config.in")" 1
check "TC-969-15 Config.in has no other depends on (no architecture)" \
	"$(grep -E '^[[:space:]]*depends on' "$PKG/Config.in" | grep -vc 'BR2_TOOLCHAIN_USES_GLIBC$')" 0
check "TC-969-15 the root Config.in sources the package" \
	"$(grep -cxF 'source "$BR2_EXTERNAL_RASPUTIN_PATH/package/temurin-jre/Config.in"' "$ROOT/Config.in")" 1

echo "── check-needed.sh on synthetic ELFs"
# A fake target: an executable needing libm.so.6, libc.so.6 and libfoo.so,
# where libfoo.so exists only under the JRE's lib/server/ (as libjvm.so does).
JRE_REL=usr/lib/temurin-jre
T="$TMP/target"
mkdir -p "$TMP/src" "$T/$JRE_REL/bin" "$T/$JRE_REL/lib/server" "$T/lib" "$T/usr/lib"
printf 'int foo(void) { return 1; }\n' > "$TMP/src/foo.c"
printf '#include <math.h>\nint foo(void);\nint main(int c, char **v) { (void)v; return foo() + (int)floor((double)c); }\n' > "$TMP/src/main.c"
cc -shared -fPIC -Wl,-soname,libfoo.so -o "$T/$JRE_REL/lib/server/libfoo.so" "$TMP/src/foo.c" \
	|| { echo "FAIL — cc could not build the synthetic library."; exit 1; }
cc -o "$T/$JRE_REL/bin/app" "$TMP/src/main.c" -L"$T/$JRE_REL/lib/server" -lfoo -Wl,--no-as-needed -lm \
	|| { echo "FAIL — cc could not build the synthetic executable."; exit 1; }
NEEDED=$(readelf -d "$T/$JRE_REL/bin/app" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p' | sort | tr '\n' ' ')
check "the synthetic executable needs exactly libc, libfoo and libm" "$NEEDED" "libc.so.6 libfoo.so libm.so.6 "
: > "$T/lib/libc.so.6"
: > "$T/usr/lib/libm.so.6"
# (c) non-ELF files beside the ELFs, one of them starting with "ELF" but not
# the magic bytes.
printf 'not an ELF\n' > "$T/$JRE_REL/release"
printf 'ELF but no magic\n' > "$T/$JRE_REL/lib/notes.txt"
SUCCESS="check-needed: every NEEDED library of the 2 ELF files under $JRE_REL is in the image."

# run_check CMD... — run a check-needed command; leaves $out, $err and $rc.
run_check() {
	out=$("$@" 2> "$TMP/cn-err"); rc=$?
	err=$(cat "$TMP/cn-err")
}

# TC-969-08 (a) and (c)
run_check env READELF=readelf "$CHECK" "$T" "$JRE_REL"
check "TC-969-08 (a) every library present: exit status" "$rc" 0
check "TC-969-08 (a)(c) one success line counting the 2 ELF files, not the non-ELF ones" "$out" "$SUCCESS"
check "TC-969-08 (a) nothing on stderr" "$err" ""
# TC-969-08 (b)
rm "$T/usr/lib/libm.so.6"
run_check env READELF=readelf "$CHECK" "$T" "$JRE_REL"
check "TC-969-08 (b) libm.so.6 removed: exit status" "$rc" 1
check "TC-969-08 (b) names the ELF and the library, then the summary" "$err" \
	"$JRE_REL/bin/app needs libm.so.6, which is not in the image.
The image is missing NEEDED libraries of the Temurin JRE (count: 1), so the runtime would fail to load on the node."
check "TC-969-08 (b) no success line" "$out" ""
: > "$T/usr/lib/libm.so.6"

# TC-969-09: each way the check cannot finish refuses, with a sentence.
closed() { # closed LABEL WANT_STDERR CMD...
	_label="$1"; _want="$2"; shift 2
	run_check "$@"
	check "TC-969-09 $_label: exit status" "$rc" 1
	check "TC-969-09 $_label: stderr" "$err" "$_want"
	check "TC-969-09 $_label: no success line" "$out" ""
}
closed "READELF unset" "Cannot check the Temurin JRE's libraries, because READELF is not set." \
	env -u READELF "$CHECK" "$T" "$JRE_REL"
printf 'not a program\n' > "$TMP/readelf-noexec"
closed "READELF not executable" \
	"Cannot check the Temurin JRE's libraries, because READELF ($TMP/readelf-noexec) is not an executable file." \
	env READELF="$TMP/readelf-noexec" "$CHECK" "$T" "$JRE_REL"
printf '#!/bin/sh\ncase "$*" in *libfoo.so*) exit 1 ;; esac\nexec readelf "$@"\n' > "$TMP/readelf-fails"
chmod +x "$TMP/readelf-fails"
closed "readelf fails on one file" \
	"Cannot check the Temurin JRE's libraries, because $TMP/readelf-fails failed on $JRE_REL/lib/server/libfoo.so." \
	env READELF="$TMP/readelf-fails" "$CHECK" "$T" "$JRE_REL"
mkdir -p "$TMP/no-elf/$JRE_REL/lib"
printf 'text\n' > "$TMP/no-elf/$JRE_REL/release"
closed "no ELF in the JRE" \
	"Found no ELF file under $TMP/no-elf/$JRE_REL, so the Temurin JRE is not installed as expected." \
	env READELF=readelf "$CHECK" "$TMP/no-elf" "$JRE_REL"
closed "target directory missing" \
	"Cannot check the Temurin JRE's libraries, because the target directory $TMP/absent does not exist." \
	env READELF=readelf "$CHECK" "$TMP/absent" "$JRE_REL"

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all Temurin JRE package checks passed"
