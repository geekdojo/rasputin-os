#!/bin/sh
#
# post-image.sh — the dual-output hook (os-images/buildroot-os.md §4).
# Buildroot calls this via BR2_ROOTFS_POST_IMAGE_SCRIPT with BINARIES_DIR
# as $1 and the board's extra args (the SoC name) appended.
#
# Produces, in $BINARIES_DIR:
#   1. <img>      — full initial-flash image (genimage)
#   2. <bundle>   — RAUC OTA bundle (host-rauc), UNSIGNED (CI signs it)
#
set -eu

BINARIES_DIR="$1"
SOC="${2:-unknown}"          # passed from the defconfig's POST_IMAGE_SCRIPT_ARGS
COMMON_DIR="$(dirname "$0")"
BOARD_DIR="$COMMON_DIR/../$SOC"
HOST_DIR="${HOST_DIR:-$BINARIES_DIR/../host}"
VERSION="${RASPUTIN_VERSION:-0.0.0-dev}"   # CI exports the CalVer tag

case "$SOC" in
	rpi)  ARCH=arm64; COMPATIBLE=rasputin-rpi-arm64 ;;
	n100) ARCH=amd64; COMPATIBLE=rasputin-n100 ;;
	*) echo "post-image: unknown SoC '$SOC'" >&2; exit 1 ;;
esac

# --- stage boot artifacts into BINARIES_DIR so genimage can pack them ---
# genimage reads its `file`/`files` entries from --inputpath ($BINARIES_DIR).
# The provisioning seed ships on every image's boot FAT (provisioning.md §1).
# The committed file is a .template (the bare name is gitignored — it holds
# per-deployment secrets once an operator fills it in post-flash).
cp "$COMMON_DIR/rasputin-seed.env.template" "$BINARIES_DIR/rasputin-seed.env"
case "$SOC" in
	n100)
		# Buildroot's grub2 (x86_64-efi) emits efi-part/EFI/BOOT/bootx64.efi plus
		# a default grub.cfg at the grub prefix (/EFI/BOOT). Replace that cfg
		# with ours (RAUC slot logic + serial console). genimage then packs the
		# whole efi-part/EFI tree + bzImage onto the ESP (see genimage.cfg).
		cp "$BOARD_DIR/grub.cfg" "$BINARIES_DIR/efi-part/EFI/BOOT/grub.cfg"
		# Initialize grubenv next to grub.cfg (== grub $prefix, so `load_env`
		# with no args finds it). Both slots ship the same rootfs (genimage
		# populates rootfs-1 too) and are marked good, with A first in ORDER so
		# it boots by default and B is a warm fallback. RAUC's grub-editenv
		# rewrites this in place at runtime on activate/mark-*. grub-editenv here
		# is the host tool built by host-grub2 (pulled in by the target grub2 build).
		GRUBENV="$BINARIES_DIR/efi-part/EFI/BOOT/grubenv"
		"$HOST_DIR/bin/grub-editenv" "$GRUBENV" create
		"$HOST_DIR/bin/grub-editenv" "$GRUBENV" set ORDER="A B" A_OK=1 A_TRY=0 B_OK=1 B_TRY=0
		echo "post-image: initialized grubenv (ORDER='A B', both slots good)"
		;;
	rpi)
		# Assemble the Pi boot FAT (label RASPUTIN-FW) ourselves with mtools so
		# we control exactly what lands at the FAT ROOT — the Pi GPU firmware
		# reads config.txt + the kernel + DTBs + start4.elf/fixup4.dat from the
		# root, never a subdir. We pre-build the vfat here (rather than let
		# genimage generate it from a `files` list) because the firmware blob set
		# is large + version-varying, and genimage's vfat `files` preserves the
		# relative path of each entry (rpi-firmware/start4.elf would land in a
		# /rpi-firmware subdir, where the firmware can't find it). Staging flat +
		# `mcopy ::` is unambiguous.
		#
		# Contents, all flattened to the FAT root:
		#   Image            RPi-fork bcm2712 arm64 kernel (config.txt `kernel=Image`)
		#   *.dtb            the Pi 5 board DTBs incl. the D0 variant (bcm2712-
		#                    rpi-5-b + bcm2712d0-rpi-5-b + bcm2712-rpi-500); the
		#                    firmware auto-selects the right one per board/stepping
		#   rpi-firmware/*   GPU/boot firmware + our config.txt + cmdline.txt +
		#                    overlays/ (from BR2_PACKAGE_RPI_FIRMWARE_*)
		#   rasputin-seed.env  the provisioning seed firstboot reads
		#
		# BRING-UP: single-slot for now — cmdline.txt roots at PARTLABEL=rootfs-0.
		# The tryboot A/B (two FAT boot partitions + autoboot.txt + the RAUC
		# custom backend) lands after a basic Pi 5 boot is confirmed on the bench.
		BOOT_STAGE="$BINARIES_DIR/rpi-boot"
		rm -rf "$BOOT_STAGE"; mkdir -p "$BOOT_STAGE"
		cp "$BINARIES_DIR/Image" "$BOOT_STAGE/"
		cp "$BINARIES_DIR"/*.dtb "$BOOT_STAGE/"
		cp -a "$BINARIES_DIR"/rpi-firmware/. "$BOOT_STAGE/"
		cp "$COMMON_DIR/rasputin-seed.env.template" "$BOOT_STAGE/rasputin-seed.env"
		BOOT_VFAT="$BINARIES_DIR/boot.vfat"
		rm -f "$BOOT_VFAT"
		dd if=/dev/zero of="$BOOT_VFAT" bs=1M count=256 status=none
		"$HOST_DIR/sbin/mkfs.vfat" -F 32 -n RASPUTIN-FW "$BOOT_VFAT" >/dev/null
		MTOOLS_SKIP_CHECK=1 "$HOST_DIR/bin/mcopy" -s -i "$BOOT_VFAT" "$BOOT_STAGE"/* ::
		echo "post-image: built boot FAT ($(du -h "$BOOT_VFAT" | cut -f1)) — $(MTOOLS_SKIP_CHECK=1 "$HOST_DIR/bin/mdir" -i "$BOOT_VFAT" :: | grep -c '^')"
		;;
esac

echo "post-image: assembling $SOC image (genimage)…"
# 1. Full .img via genimage using the board's layout.
GENIMAGE_CFG="$BOARD_DIR/genimage.cfg"
GENIMAGE_TMP="$BINARIES_DIR/genimage.tmp"
rm -rf "$GENIMAGE_TMP"
genimage \
	--rootpath   "$BINARIES_DIR/../target" \
	--tmppath    "$GENIMAGE_TMP" \
	--inputpath  "$BINARIES_DIR" \
	--outputpath "$BINARIES_DIR" \
	--config     "$GENIMAGE_CFG"

mv "$BINARIES_DIR/disk.img" "$BINARIES_DIR/rasputin-os-$SOC-$VERSION.img" 2>/dev/null || true

echo "post-image: staging RAUC bundle directory…"
# 2. RAUC bundle SOURCES. We deliberately do NOT call `rauc bundle` here —
#    `rauc bundle` requires the leaf signing key, which never lives in the
#    build job (locked decision, os-images/release-pipeline.md §3). The
#    discrete `sign-and-release` CI job downloads this bundle/ dir, runs
#    `rauc bundle` with the leaf key materialized to tmpfs, and uploads the
#    signed .raucb to the GitHub Release.
#
#    For a local dev .raucb, run `rauc bundle bundle/ output.raucb
#    --cert=... --key=... --signing-keyring=...` from this dir yourself.
BUNDLE_DIR="$BINARIES_DIR/bundle"
rm -rf "$BUNDLE_DIR"; mkdir -p "$BUNDLE_DIR"
cp "$BINARIES_DIR/rootfs.squashfs" "$BUNDLE_DIR/rootfs.img"

cat > "$BUNDLE_DIR/manifest.raucm" <<EOF
[update]
compatible=$COMPATIBLE
version=$VERSION

[bundle]
format=verity

[image.rootfs]
filename=rootfs.img
EOF

echo "post-image: done — $ARCH artifacts in $BINARIES_DIR"
echo "  - $BINARIES_DIR/rasputin-os-$SOC-$VERSION.img"
echo "  - $BUNDLE_DIR/{rootfs.img,manifest.raucm}  (signed into .raucb by CI)"
