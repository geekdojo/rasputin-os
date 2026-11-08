#!/usr/bin/env bash
# SPIKE ONLY — geekdojo/geekdojo-brain#957. Packs the identity stack the
# footprint probe runs in scratch mode, from the +identity build's target/:
#   usr/lib/keycloak, usr/lib/temurin-jre, PostgreSQL's server binaries with
#   their lib and share trees, and lib/: the ELF NEEDED closure of all of it.
# The squashfs uses the rootfs's own mksquashfs options (xz, 128 KiB blocks),
# so files are read through squashfs and xz as the root filesystem reads them.
#
# glibc's own libraries are left out of lib/: the probe runs the stack with
# LD_LIBRARY_PATH on the node, and mixing a packed libc with the node's
# ld.so would test nothing but the mix. The node runs the same Buildroot glibc.
#
# Usage: pack-stack.sh <target-dir> <out.squashfs> <closure-report>
set -euo pipefail

TARGET="${1:?usage: $0 <target-dir> <out.squashfs> <closure-report>}"
OUT="${2:?usage}"
REPORT="${3:?usage}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/usr/lib" "$STAGE/usr/bin" "$STAGE/usr/share" "$STAGE/lib"
cp -a "$TARGET/usr/lib/keycloak" "$STAGE/usr/lib/keycloak"
cp -a "$TARGET/usr/lib/temurin-jre" "$STAGE/usr/lib/temurin-jre"
for b in postgres initdb; do cp -a "$TARGET/usr/bin/$b" "$STAGE/usr/bin/$b"; done
cp -a "$TARGET/usr/lib/postgresql" "$STAGE/usr/lib/postgresql"
cp -a "$TARGET/usr/share/postgresql" "$STAGE/usr/share/postgresql"

is_glibc() {
	case "$1" in
		libc.so.*|libm.so.*|libdl.so.*|libpthread.so.*|librt.so.*|libresolv.so.*|libutil.so.*|libanl.so.*|ld-linux*.so.*) return 0 ;;
	esac
	return 1
}

needed() { readelf -d "$1" 2>/dev/null | sed -n 's/.*(NEEDED).*Shared library: \[\(.*\)\]/\1/p'; }

: > "$REPORT"
declare -A seen=()
queue=()
while IFS= read -r -d '' f; do
	if head -c 4 "$f" | grep -q $'\x7fELF'; then queue+=("$f"); fi
done < <(find "$STAGE/usr" -type f -print0)

# Names the JRE resolves itself through its $ORIGIN runpath.
declare -A jre=()
while IFS= read -r -d '' f; do jre["$(basename "$f")"]=1; done < <(find "$STAGE/usr/lib/temurin-jre" -name '*.so*' -print0)

while [ "${#queue[@]}" -gt 0 ]; do
	f="${queue[0]}"; queue=("${queue[@]:1}")
	while IFS= read -r lib; do
		[ -n "$lib" ] || continue
		[ -z "${seen[$lib]:-}" ] || continue
		seen["$lib"]=1
		if is_glibc "$lib"; then echo "node-glibc $lib" >> "$REPORT"; continue; fi
		if [ -n "${jre[$lib]:-}" ]; then echo "jre-runpath $lib" >> "$REPORT"; continue; fi
		src=""
		for d in lib usr/lib; do
			if [ -e "$TARGET/$d/$lib" ]; then src="$TARGET/$d/$lib"; break; fi
		done
		if [ -z "$src" ]; then echo "UNRESOLVED $lib (needed by ${f#"$STAGE"/})" >> "$REPORT"; continue; fi
		cp -L "$src" "$STAGE/lib/$lib"
		echo "packed $lib" >> "$REPORT"
		queue+=("$STAGE/lib/$lib")
	done < <(needed "$f")
done
sort -o "$REPORT" "$REPORT"
if grep -q '^UNRESOLVED' "$REPORT"; then
	echo "::error::pack-stack: unresolved NEEDED libraries:"; grep '^UNRESOLVED' "$REPORT"; exit 1
fi

mksquashfs "$STAGE" "$OUT" -noappend -comp xz -b 128K -all-root -quiet
