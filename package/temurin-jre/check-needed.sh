#!/bin/sh
#
# check-needed.sh — fail the build when any ELF file in the installed Temurin
# JRE names a NEEDED library the image does not carry
# (geekdojo/geekdojo-brain#969). Adoptium's binaries are linked against glibc
# and were not built by this toolchain, so nothing else in the build notices a
# missing library; the node would find out when Keycloak's JVM fails to load.
# Run by temurin-jre.mk as a target-finalize hook.
#
#   READELF=<cross readelf> check-needed.sh TARGET_DIR JRE_REL_DIR
#
# Every regular file under TARGET_DIR/JRE_REL_DIR that starts with the ELF
# magic bytes is read with `$READELF -d`. Each NEEDED name resolves when it is
#   * a file (or link) anywhere under the JRE's own lib/, lib/server/ included:
#     the launcher loads libjvm.so from lib/server/ itself, so strict RUNPATH
#     resolution would fail falsely; or
#   * present in TARGET_DIR's lib, lib64, usr/lib or usr/lib64.
#
# Success: one stdout line with the number of ELF files checked, exit 0.
# A miss: one stderr line per miss, then a summary, exit 1.
# FAILS CLOSED, exit 1 with a sentence: READELF unset or not executable,
# readelf failing on a file, a missing directory, or no ELF file found.

set -u

fail() {
	echo "$*" >&2
	exit 1
}

[ "$#" -eq 2 ] || fail "check-needed.sh needs the target directory and the JRE directory relative to it."
TARGET_DIR="$1"
JRE_REL="$2"
JRE_DIR="$TARGET_DIR/$JRE_REL"

[ -n "${READELF:-}" ] || fail "Cannot check the Temurin JRE's libraries, because READELF is not set."
case "$READELF" in
	*/*) [ -f "$READELF" ] && [ -x "$READELF" ] ;;
	*) command -v "$READELF" >/dev/null 2>&1 ;;
esac || fail "Cannot check the Temurin JRE's libraries, because READELF ($READELF) is not an executable file."
[ -d "$TARGET_DIR" ] || fail "Cannot check the Temurin JRE's libraries, because the target directory $TARGET_DIR does not exist."
[ -d "$JRE_DIR" ] || fail "Cannot check the Temurin JRE's libraries, because the JRE directory $JRE_DIR does not exist."

WORK=$(mktemp -d) || fail "Cannot check the Temurin JRE's libraries, because a scratch directory could not be created."
trap 'rm -rf "$WORK"' EXIT

# The names the JRE's own lib/ tree provides.
if [ -d "$JRE_DIR/lib" ]; then
	find "$JRE_DIR/lib" \( -type f -o -type l \) | sed 's#.*/##' | sort -u > "$WORK/jre-libs"
else
	: > "$WORK/jre-libs"
fi

find "$JRE_DIR" -type f | sort > "$WORK/files" \
	|| fail "Cannot check the Temurin JRE's libraries, because $JRE_DIR could not be listed."

elfs=0
misses=0
while IFS= read -r f; do
	magic=$(dd if="$f" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
	[ "$magic" = 7f454c46 ] || continue
	elfs=$((elfs + 1))
	rel=${f#"$TARGET_DIR"/}
	"$READELF" -d "$f" > "$WORK/dynamic" 2>&1 \
		|| fail "Cannot check the Temurin JRE's libraries, because $READELF failed on $rel."
	sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p' "$WORK/dynamic" > "$WORK/needed"
	while IFS= read -r lib; do
		grep -qxF "$lib" "$WORK/jre-libs" && continue
		found=0
		for d in lib lib64 usr/lib usr/lib64; do
			if [ -e "$TARGET_DIR/$d/$lib" ]; then
				found=1
				break
			fi
		done
		[ "$found" = 1 ] && continue
		echo "$rel needs $lib, which is not in the image." >&2
		misses=$((misses + 1))
	done < "$WORK/needed"
done < "$WORK/files"

[ "$elfs" -gt 0 ] || fail "Found no ELF file under $JRE_DIR, so the Temurin JRE is not installed as expected."
if [ "$misses" -gt 0 ]; then
	fail "The image is missing NEEDED libraries of the Temurin JRE (count: $misses), so the runtime would fail to load on the node."
fi
echo "check-needed: every NEEDED library of the $elfs ELF files under $JRE_REL is in the image."
