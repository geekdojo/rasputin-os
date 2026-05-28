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
BOARD_DIR="$(dirname "$0")/../$SOC"
HOST_DIR="${HOST_DIR:-$BINARIES_DIR/../host}"
VERSION="${RASPUTIN_VERSION:-0.0.0-dev}"   # CI exports the CalVer tag

case "$SOC" in
	cm5)  ARCH=arm64; COMPATIBLE=rasputin-pi5-cm5 ;;
	n100) ARCH=amd64; COMPATIBLE=rasputin-n100 ;;
	*) echo "post-image: unknown SoC '$SOC'" >&2; exit 1 ;;
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

echo "post-image: building RAUC bundle…"
# 2. RAUC bundle. Manifest fields match the api verifier's expectations
#    (control-plane/updates.md §2). host-rauc is built by BR2_PACKAGE_RAUC.
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

# NOTE: unsigned here. CI signs with the leaf key in a discrete step
# (os-images/release-pipeline.md §3). For a local dev bundle, pass
# --cert/--key to host-rauc directly. The --keyring/--cert below is a
# placeholder that the CI signing step overrides.
"$HOST_DIR/bin/rauc" bundle \
	--signing-keyring="$BOARD_DIR/../common/dev-ca.pem" \
	--cert="${RAUC_CERT:-$BOARD_DIR/../common/dev-leaf.pem}" \
	--key="${RAUC_KEY:-$BOARD_DIR/../common/dev-leaf.key}" \
	"$BUNDLE_DIR" \
	"$BINARIES_DIR/rasputin-os-$SOC-$VERSION.raucb" || {
		echo "post-image: rauc bundle failed — for a local build, provide" >&2
		echo "  RAUC_CERT/RAUC_KEY env or a dev CA. CI signs separately." >&2
	}

echo "post-image: done — $ARCH artifacts in $BINARIES_DIR"
