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
		# Assemble the Pi boot FATs ourselves with mtools so we control exactly
		# what lands at the FAT ROOT — the Pi firmware reads config.txt + kernel +
		# DTBs + start4.elf/fixup4.dat from the root, never a subdir. We pre-build
		# the vfats here (rather than a genimage vfat `files` list) because the
		# firmware blob set is large + version-varying, and genimage's vfat `files`
		# preserves each entry's relative path (rpi-firmware/start4.elf would land
		# in a /rpi-firmware subdir, where the firmware can't find it). Staging flat
		# + `mcopy ::` is unambiguous.
		#
		# A/B = the CANONICAL Pi tryboot mechanism: autoboot.txt `boot_partition`
		# switching at the EEPROM stage (portable Pi 4 + Pi 5). THREE FATs:
		#   - selector (p1, RASPUTIN-FW): autoboot.txt + the provisioning seed ONLY.
		#     No kernel/config — so the firmware MUST honor boot_partition + redirect
		#     to a real boot slot. The RAUC backend edits autoboot.txt here at runtime
		#     (mounted /run/rasputin-seed).
		#   - boot-a (p2, RASPUTIN-A): slot A's COMPLETE boot env, cmdline.txt → rootfs-0.
		#   - boot-b (p3, RASPUTIN-B): same, cmdline.txt → rootfs-1.
		# boot-a/boot-b shared contents, flattened to root: kernel_2712.img (Pi 5/CM5
		# bcm2712 `Image`) + kernel8.img (Pi 4 bcm2711, built in post-build.sh) + all
		# *.dtb (bcm2712-rpi-5-b + bcm2712d0-rpi-5-b D0 + bcm2711-rpi-4-b) +
		# rpi-firmware/* (GPU/boot firmware incl. start4.elf/fixup4.dat + config.txt +
		# overlays/). config.txt arrives via rpi-firmware/ (Buildroot CONFIG_FILE);
		# cmdline.txt arrives there too (CMDLINE_FILE = slot A) and is overwritten with
		# the slot-B cmdline on boot-b. The Pi 4 fix: the EEPROM loads start4.elf FROM
		# boot_partition (p2/p3), so the kernel is in the same slot it reads.
		COMMON_STAGE="$BINARIES_DIR/rpi-boot-common"
		rm -rf "$COMMON_STAGE"; mkdir -p "$COMMON_STAGE"
		cp "$BINARIES_DIR/Image" "$COMMON_STAGE/kernel_2712.img"   # Pi 5 / CM5 (bcm2712)
		cp "$BINARIES_DIR/kernel8.img" "$COMMON_STAGE/kernel8.img" # Pi 4 (bcm2711, post-build)
		cp "$BINARIES_DIR"/*.dtb "$COMMON_STAGE/"
		cp -a "$BINARIES_DIR"/rpi-firmware/. "$COMMON_STAGE/"      # incl. config.txt + cmdline.txt(=A)

		# Build one FAT from a staging dir: build_fat <out.vfat> <label> <MB> <stagedir>
		build_fat() {
			_out="$1"; _label="$2"; _mb="$3"; _stage="$4"
			rm -f "$_out"
			dd if=/dev/zero of="$_out" bs=1M count="$_mb" status=none
			"$HOST_DIR/sbin/mkfs.vfat" -F 32 -n "$_label" "$_out" >/dev/null
			MTOOLS_SKIP_CHECK=1 "$HOST_DIR/bin/mcopy" -s -i "$_out" "$_stage"/* ::
			echo "post-image: built $_label ($(du -h "$_out" | cut -f1)) — $(MTOOLS_SKIP_CHECK=1 "$HOST_DIR/bin/mdir" -i "$_out" :: | grep -c '^') entries"
		}

		# selector (p1): autoboot.txt + seed only. 64M = comfortably above the FAT32
		# floor (~33M); the firmware reads autoboot.txt from this first FAT.
		STAGE_SEL="$BINARIES_DIR/rpi-selector"
		rm -rf "$STAGE_SEL"; mkdir -p "$STAGE_SEL"
		cp "$BOARD_DIR/autoboot.txt" "$STAGE_SEL/autoboot.txt"
		cp "$COMMON_DIR/rasputin-seed.env.template" "$STAGE_SEL/rasputin-seed.env"
		build_fat "$BINARIES_DIR/selector.vfat" RASPUTIN-FW 64 "$STAGE_SEL"

		# boot-a (p2): common; cmdline.txt stays = slot A. No autoboot.txt/seed.
		build_fat "$BINARIES_DIR/boot-a.vfat" RASPUTIN-A 256 "$COMMON_STAGE"

		# boot-b (p3): common with cmdline.txt overwritten = slot B.
		STAGE_B="$BINARIES_DIR/rpi-boot-b"
		rm -rf "$STAGE_B"; cp -a "$COMMON_STAGE" "$STAGE_B"
		cp "$BOARD_DIR/cmdline-b.txt" "$STAGE_B/cmdline.txt"
		build_fat "$BINARIES_DIR/boot-b.vfat" RASPUTIN-B 256 "$STAGE_B"
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
