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
	cm5)  ARCH=arm64; COMPATIBLE=rasputin-pi5-cm5 ;;
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
		;;
	cm5)
		# Pi firmware reads config.txt + autoboot.txt from the boot FAT. The
		# kernel Image + firmware blobs are added during hardware bring-up
		# (see genimage.cfg TODO); these two get the layout assembling now.
		cp "$BOARD_DIR/config.txt" "$BINARIES_DIR/config.txt"
		cat > "$BINARIES_DIR/autoboot.txt" <<'EOF'
# tryboot A/B one-shot (no boot-counter) — RAUC's custom CM5 backend rewrites
# this on mark-good / set-primary. STARTER values; confirm on real Pi hardware.
[all]
tryboot_a_b=1
boot_partition=2

[tryboot]
boot_partition=3
EOF
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
