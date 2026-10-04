#!/bin/sh
#
# post-image.sh — the dual-output hook (os-images/buildroot-os.md §4).
# Buildroot calls this via BR2_ROOTFS_POST_IMAGE_SCRIPT with BINARIES_DIR
# as $1 and the board's extra args (the SoC name) appended.
#
# Produces, in $BINARIES_DIR:
#   1. <img>      — full initial-flash image (genimage)
#   2. bundle/    — the RAUC OTA bundle's SOURCES, UNSIGNED (CI signs them)
#
# THE BUNDLE CARRIES THE KERNEL (geekdojo/geekdojo-brain#807). An update used to
# replace only the rootfs and leave the slot booting its old kernel against the
# new rootfs's modules; dev.276 changed the Pi kernel config and docker died on
# every OTA'd arm64 node. So bundle/ now also holds the slot's boot files plus
# hook.sh (rauc-bundle-hook.sh), which RAUC runs as install-check and as the
# rootfs image's post-install hook to write them:
#   rpi   boot.vfat (ONE slot-neutral boot FAT: firmware, config.txt, both
#         kernels, DTBs, overlays — no cmdline.txt), cmdline-A.txt,
#         cmdline-B.txt, cmdline-policy.sh (the BMC-host policy; the hook runs
#         on the OLD rootfs, which may not have it).
#   n100  bzImage (written as the slot's own /bzImage-<slot> on the ESP) and
#         grub.cfg (per-slot kernels, falling back to the legacy shared
#         /bzImage for a slot no bundle has written yet).
#   both  boot-version (the marker the hook writes last) and
#         boot-payload.sha256 (what the hook checks every payload file against).
# The flash image is built from the SAME files, so a flashed slot and an
# updated slot boot identical bytes.
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
# The boot marker: which image's boot files a slot carries. Flashed onto every
# boot slot here, and written by the bundle hook as the last step of an update.
printf '%s\n' "$VERSION" > "$BINARIES_DIR/rasputin-boot-version"
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
		#   - selector (p1, RASPUTIN-OS): autoboot.txt + the provisioning seed ONLY.
		#     No kernel/config — so the firmware MUST honor boot_partition + redirect
		#     to a real boot slot. The RAUC backend edits autoboot.txt here at runtime
		#     (mounted /run/rasputin-seed).
		#   - boot-a (p2, RASPUTIN-A): slot A's COMPLETE boot env, cmdline.txt → rootfs-0.
		#   - boot-b (p3, RASPUTIN-B): same, cmdline.txt → rootfs-1.
		# boot-a/boot-b shared contents, flattened to root: kernel_2712.img (Pi 5/CM5
		# bcm2712 `Image`) + kernel8.img (Pi 4 bcm2711, built in post-build.sh) + all
		# *.dtb (bcm2712-rpi-5-b + bcm2712d0-rpi-5-b D0 + bcm2711-rpi-4-b) +
		# rpi-firmware/* (GPU/boot firmware incl. start4.elf/fixup4.dat + config.txt +
		# overlays/). config.txt arrives via rpi-firmware/ (Buildroot CONFIG_FILE).
		# The Pi 4 fix: the EEPROM loads start4.elf FROM boot_partition (p2/p3), so
		# the kernel is in the same slot it reads.
		#
		# The shared contents become ONE slot-neutral FAT, boot.vfat, with no
		# cmdline.txt: the only per-slot file is cmdline.txt (which rootfs it
		# roots), so each slot's FAT is boot.vfat + its own cmdline + the boot
		# marker. The bundle ships boot.vfat and both cmdlines, and the hook
		# assembles the slot's FAT on the device the same way (geekdojo/geekdojo-brain#807).
		COMMON_STAGE="$BINARIES_DIR/rpi-boot-common"
		rm -rf "$COMMON_STAGE"; mkdir -p "$COMMON_STAGE"
		cp "$BINARIES_DIR/Image" "$COMMON_STAGE/kernel_2712.img"   # Pi 5 / CM5 (bcm2712)
		cp "$BINARIES_DIR/kernel8.bin" "$COMMON_STAGE/kernel8.img" # Pi 4 (bcm2711, post-build; .bin → kernel8.img on the FAT)
		cp "$BINARIES_DIR"/*.dtb "$COMMON_STAGE/"
		cp -a "$BINARIES_DIR"/rpi-firmware/. "$COMMON_STAGE/"      # incl. config.txt
		# CMDLINE_FILE drops a slot-A cmdline.txt into rpi-firmware/; the slot's
		# cmdline is added per slot below, never baked into the shared FAT.
		rm -f "$COMMON_STAGE/cmdline.txt"

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
		build_fat "$BINARIES_DIR/selector.vfat" RASPUTIN-OS 64 "$STAGE_SEL"

		# boot.vfat: the slot-neutral boot FAT, shipped in the bundle as-is. 256M
		# is the boot partition size (genimage sizes p2/p3 from these images), and
		# the hook's install-check refuses a device whose boot partitions are
		# smaller. One label for both slots, since the same bytes land on both;
		# nothing finds a boot slot by label (the Pi firmware goes by partition
		# number, everything else by PARTUUID).
		build_fat "$BINARIES_DIR/boot.vfat" RASPUTIN-BT 256 "$COMMON_STAGE"

		# boot-a (p2) / boot-b (p3): boot.vfat + that slot's cmdline + the marker.
		for _slot in A B; do
			case "$_slot" in
				A) _cmdline="$BOARD_DIR/cmdline.txt"; _out="$BINARIES_DIR/boot-a.vfat" ;;
				B) _cmdline="$BOARD_DIR/cmdline-b.txt"; _out="$BINARIES_DIR/boot-b.vfat" ;;
			esac
			cp "$BINARIES_DIR/boot.vfat" "$_out"
			MTOOLS_SKIP_CHECK=1 "$HOST_DIR/bin/mcopy" -o -i "$_out" "$_cmdline" ::cmdline.txt
			MTOOLS_SKIP_CHECK=1 "$HOST_DIR/bin/mcopy" -o -i "$_out" "$BINARIES_DIR/rasputin-boot-version" ::rasputin-boot-version
			echo "post-image: built boot slot $_slot ($(basename "$_out")) = boot.vfat + $(basename "$_cmdline") + boot marker"
		done
		;;
esac

# --- persistent (data) partition: ship it PRE-FORMATTED (empty ext4) ---------
# The image used to leave the persistent partition's bytes unwritten (it's the
# last, content-less partition, so genimage truncated the .img at the end of the
# last populated partition). On BLANK media that region reads as zeros and
# systemd-makefs formats it on first boot — fine. But reflashing onto a
# PREVIOUSLY-USED drive left the old filesystem's superblock in place: makefs
# (format-only-if-unformatted) skipped it and the mount then failed on the
# geometry mismatch — e.g. a prior node whose persistent was grown to fill a
# 500 GB medium leaves "block count … exceeds size of device (131072 blocks)",
# which cascades to firstboot and bricks the node. Shipping a real empty 512 MiB
# ext4 makes a flash write a correct superblock over whatever was there, so first
# boot works regardless of the disk's prior state. rasputin-growpart re-expands
# it to fill the medium on first boot as before. Keep this size == the genimage
# `persistent` partition size in BOTH board layouts.
PERSIST_MB=512
PERSIST_IMG="$BINARIES_DIR/persistent.ext4"
dd if=/dev/zero of="$PERSIST_IMG" bs=1M count="$PERSIST_MB" status=none
# mke2fs -t ext4 (not the mkfs.ext4 symlink) so this doesn't depend on the host
# alias being installed; -F: it's a plain file, not a block device.
"$HOST_DIR/sbin/mke2fs" -F -q -t ext4 -L persistent "$PERSIST_IMG"
echo "post-image: built persistent.ext4 (${PERSIST_MB}M empty ext4, pre-formatted)"

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
#    build job (decision recorded in os-images/release-pipeline.md §3). The
#    discrete `sign-and-release` CI job downloads this bundle/ dir, runs
#    `rauc bundle` with the leaf key materialized to tmpfs, and uploads the
#    signed .raucb to the GitHub Release.
#
#    For a local dev .raucb, run `rauc bundle bundle/ output.raucb
#    --cert=... --key=... --signing-keyring=...` from this dir yourself.
BUNDLE_DIR="$BINARIES_DIR/bundle"
rm -rf "$BUNDLE_DIR"; mkdir -p "$BUNDLE_DIR"
cp "$BINARIES_DIR/rootfs.squashfs" "$BUNDLE_DIR/rootfs.img"

# The boot payload (see the header) and the hook that installs it.
case "$SOC" in
	rpi)
		cp "$BINARIES_DIR/boot.vfat" "$BUNDLE_DIR/boot.vfat"
		cp "$BOARD_DIR/cmdline.txt" "$BUNDLE_DIR/cmdline-A.txt"
		cp "$BOARD_DIR/cmdline-b.txt" "$BUNDLE_DIR/cmdline-B.txt"
		cp "$COMMON_DIR/rootfs-overlay/usr/lib/rasputin/bmc/cmdline-policy.sh" "$BUNDLE_DIR/cmdline-policy.sh"
		PAYLOAD="boot.vfat cmdline-A.txt cmdline-B.txt cmdline-policy.sh boot-version"
		;;
	n100)
		cp "$BINARIES_DIR/bzImage" "$BUNDLE_DIR/bzImage"
		cp "$BOARD_DIR/grub.cfg" "$BUNDLE_DIR/grub.cfg"
		PAYLOAD="bzImage grub.cfg boot-version"
		;;
esac
cp "$BINARIES_DIR/rasputin-boot-version" "$BUNDLE_DIR/boot-version"
cp "$COMMON_DIR/rauc-bundle-hook.sh" "$BUNDLE_DIR/hook.sh"
chmod 0755 "$BUNDLE_DIR/hook.sh"
# shellcheck disable=SC2086 # PAYLOAD is a list of plain file names
(cd "$BUNDLE_DIR" && sha256sum $PAYLOAD > boot-payload.sha256)

# [hooks] install-check REPLACES RAUC's compatible check; hook.sh re-implements
# it. post-install on the rootfs image runs after RAUC wrote the rootfs and
# before it calls set-primary, so a failed boot-file write leaves the device on
# its current slot. Both declarations are parsed by RAUC 1.13 (dev.269) and
# 1.15.2 (dev.276), which is what lets the first update from those images
# install its kernel: neither needs a slot the device's system.conf lacks.
cat > "$BUNDLE_DIR/manifest.raucm" <<EOF
[update]
compatible=$COMPATIBLE
version=$VERSION

[bundle]
format=verity

[hooks]
filename=hook.sh
hooks=install-check

[image.rootfs]
filename=rootfs.img
hooks=post-install
EOF

echo "post-image: done — $ARCH artifacts in $BINARIES_DIR"
echo "  - $BINARIES_DIR/rasputin-os-$SOC-$VERSION.img"
echo "  - $BUNDLE_DIR/{rootfs.img,manifest.raucm,hook.sh} + $PAYLOAD  (signed into .raucb by CI)"
