#!/bin/sh
#
# bundle-kernel-match.sh — check, on every image build, that the RAUC bundle
# installs the kernel its rootfs was built for (geekdojo/geekdojo-brain#807).
#
#   usage: test/bundle-kernel-match.sh <rpi|n100> <buildroot output dir>
#          (release.yml runs it after the build on output/<sku>)
#
# WHY. An update used to replace only the rootfs, and dev.276 booted the old
# Pi kernel under a rootfs whose modules.builtin said bridge.ko was built in, so
# docker died on every OTA'd arm64 node. Nothing in CI looked at the bundle: the
# boot smokes boot the flash image, which always had its own kernel. This looks
# at exactly what ships to a device that updates:
#   1. the manifest declares hook.sh as install-check and as the rootfs image's
#      post-install hook, and hook.sh is there, executable and parses — without
#      that the boot payload is dead weight and the old defect is back;
#   2. every boot-payload file matches boot-payload.sha256 (what the hook
#      checks on the device before it writes anything);
#   3. the kernels in the payload (rpi: kernel_2712.img + kernel8.img out of
#      boot.vfat; n100: bzImage) are exactly the kernels the bundle's rootfs
#      lists in /usr/lib/rasputin/kernel-ids, by full identity — release AND
#      build version, since dev.276 changed the config without changing the
#      release string;
#   4. the rootfs carries modules.builtin + modules.dep for each of those
#      releases, and no module tree for a release no payload kernel has.
# Every failure is reported, then the script exits 1.
#
# Tools: mcopy and unsquashfs from the build's own host dir when present (the
# rpi build makes host-mtools; every build makes host-squashfs), else PATH.
set -u

SKU="${1:?usage: bundle-kernel-match.sh <rpi|n100> <output dir>}"
O="${2:?usage: bundle-kernel-match.sh <rpi|n100> <output dir>}"
REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
B="$O/images/bundle"
KID="$REPO/scripts/kernel-id.sh"

tool() { if [ -x "$O/host/bin/$1" ]; then echo "$O/host/bin/$1"; else command -v "$1"; fi; }
MCOPY="$(tool mcopy || true)"
UNSQUASHFS="$(tool unsquashfs || true)"

FAILS=0
bad() { echo "::error::bundle-kernel-match ($SKU): $*"; FAILS=$((FAILS + 1)); }
ok() { echo "ok  $*"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

[ -d "$B" ] || { bad "no bundle directory at $B"; exit 1; }

# --- 1. the hooks are declared and present --------------------------------------
# section KEY: the value of KEY inside [SECTION] of the manifest.
mf_value() {
	awk -v sec="[$1]" -v key="$2" '
		/^\[/ { cur = $0 }
		cur == sec && index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }
	' "$B/manifest.raucm"
}
has_word() { case ";$1;" in *";$2;"*) return 0 ;; *) return 1 ;; esac; }

if [ "$(mf_value hooks filename)" = "hook.sh" ]; then ok "manifest [hooks] filename=hook.sh"; else
	bad "manifest.raucm declares no [hooks] filename=hook.sh — the bundle cannot install its boot payload"; fi
if has_word "$(mf_value hooks hooks)" install-check; then ok "manifest [hooks] hooks has install-check"; else
	bad "manifest.raucm [hooks] does not declare install-check — the boot partitions are never checked before the rootfs is written"; fi
if has_word "$(mf_value image.rootfs hooks)" post-install; then ok "manifest [image.rootfs] hooks has post-install"; else
	bad "manifest.raucm [image.rootfs] does not declare post-install — an update would replace the rootfs and leave the old kernel (the dev.276 failure)"; fi
if [ -x "$B/hook.sh" ] && sh -n "$B/hook.sh"; then ok "hook.sh is executable and parses"; else
	bad "hook.sh is missing, not executable, or does not parse"; fi

# --- 2. the payload matches its checksums ---------------------------------------
if [ -f "$B/boot-payload.sha256" ] && (cd "$B" && sha256sum -c boot-payload.sha256 >/dev/null 2>&1); then
	ok "boot payload matches boot-payload.sha256 ($(wc -l < "$B/boot-payload.sha256" | tr -d ' ') files)"
else
	bad "boot payload missing or not matching boot-payload.sha256"
fi

# --- 3. payload kernels == the rootfs's kernel-ids -------------------------------
: > "$TMP/payload-ids"
case "$SKU" in
	rpi)
		if [ -f "$B/boot.vfat" ] && [ -n "$MCOPY" ]; then
			for k in kernel_2712.img kernel8.img; do
				if MTOOLS_SKIP_CHECK=1 "$MCOPY" -n -i "$B/boot.vfat" "::$k" "$TMP/$k" 2>/dev/null; then
					sh "$KID" "$TMP/$k" >> "$TMP/payload-ids" || bad "cannot read the identity of $k in boot.vfat"
				else
					bad "boot.vfat carries no $k"
				fi
			done
		else
			bad "no boot.vfat in the bundle (or no mcopy to read it)"
		fi
		;;
	n100)
		if [ -f "$B/bzImage" ]; then
			sh "$KID" "$B/bzImage" >> "$TMP/payload-ids" || bad "cannot read the identity of the bundle's bzImage"
		else
			bad "no bzImage in the bundle"
		fi
		;;
	*) bad "unknown sku '$SKU'" ;;
esac
sort -u "$TMP/payload-ids" > "$TMP/payload-ids.sorted"
sed 's/^/    payload kernel: /' "$TMP/payload-ids.sorted"

if [ -z "$UNSQUASHFS" ]; then
	bad "no unsquashfs to read the bundle's rootfs"
elif ! "$UNSQUASHFS" -l "$B/rootfs.img" > "$TMP/rootfs.list" 2>/dev/null || ! grep -qx 'squashfs-root/usr' "$TMP/rootfs.list"; then
	bad "cannot list the bundle's rootfs ($B/rootfs.img)"
else
	"$UNSQUASHFS" -no-xattrs -q -d "$TMP/rootfs" "$B/rootfs.img" usr/lib/rasputin/kernel-ids >/dev/null 2>&1 || true
	if [ -s "$TMP/rootfs/usr/lib/rasputin/kernel-ids" ]; then
		sort -u "$TMP/rootfs/usr/lib/rasputin/kernel-ids" > "$TMP/rootfs-ids.sorted"
		if [ -s "$TMP/payload-ids.sorted" ] && cmp -s "$TMP/payload-ids.sorted" "$TMP/rootfs-ids.sorted"; then
			ok "the bundle's kernels are exactly the kernels its rootfs was built for"
		else
			bad "the bundle's kernels are not the kernels its rootfs was built for"
			echo "    rootfs kernel-ids:"; sed 's/^/      /' "$TMP/rootfs-ids.sorted"
			echo "    payload kernels:";   sed 's/^/      /' "$TMP/payload-ids.sorted"
		fi
	else
		bad "the bundle's rootfs has no /usr/lib/rasputin/kernel-ids — nothing records which kernel it was built for"
	fi

	# --- 4. module trees for exactly those releases ------------------------------
	sed -n 's#^squashfs-root/usr/lib/modules/\([^/]*\)$#\1#p' "$TMP/rootfs.list" | sort -u > "$TMP/module-releases"
	cut -d' ' -f1 "$TMP/payload-ids.sorted" | sort -u > "$TMP/payload-releases"
	while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		"$UNSQUASHFS" -no-xattrs -q -d "$TMP/m-$rel" "$B/rootfs.img" \
			"usr/lib/modules/$rel/modules.builtin" "usr/lib/modules/$rel/modules.dep" >/dev/null 2>&1 || true
		if [ -f "$TMP/m-$rel/usr/lib/modules/$rel/modules.builtin" ] && [ -f "$TMP/m-$rel/usr/lib/modules/$rel/modules.dep" ]; then
			ok "rootfs has modules.builtin + modules.dep for $rel ($(wc -l < "$TMP/m-$rel/usr/lib/modules/$rel/modules.builtin" | tr -d ' ') built-in)"
		else
			bad "rootfs has no modules.builtin/modules.dep for payload kernel release $rel"
		fi
	done < "$TMP/payload-releases"
	orphans="$(comm -23 "$TMP/module-releases" "$TMP/payload-releases" | tr '\n' ' ')"
	if [ -n "$orphans" ]; then
		bad "rootfs carries module trees for releases no bundle kernel has: $orphans"
	else
		ok "no module tree without a kernel"
	fi
fi

if [ "$FAILS" -gt 0 ]; then
	echo "bundle-kernel-match ($SKU): $FAILS check(s) failed"
	exit 1
fi
echo "bundle-kernel-match ($SKU): all checks passed"
