#!/bin/sh
#
# rootfs-size-check.sh — report the built root filesystem's size on every
# release build, and fail the build above 768 MiB (platform.md §2.6;
# geekdojo/geekdojo-brain#969). post-image.sh runs it before it stages
# anything, so an over-limit image is never signed or published.
#
#   rootfs-size-check.sh SQUASHFS SOC     (SOC: rpi or n100)
#
# 768 MiB is the revisit fact of the control-plane-only extension image: a
# rootfs past it means that decision is due again, not that the slot is full.
# The report also gives the footprint probe's baselines for the SKU
# (geekdojo/geekdojo-brain#957, CI run 42548144644), without and with the
# identity service, so a reader sees how far a build has moved from them.
#
# Exit 0 at or under the limit, with one report line on stdout. Exit 1 above
# it, or for a missing or unreadable file, an unknown SoC or missing
# arguments, each with a sentence on stderr.

set -u

LIMIT=805306368   # 768 MiB

fail() {
	echo "rootfs-size-check: $*" >&2
	exit 1
}

[ "$#" -eq 2 ] || fail "Needs the squashfs path and the SoC (rpi or n100)."
SQUASHFS="$1"
SOC="$2"

case "$SOC" in
	rpi)  BASE_PLAIN=213209088; BASE_IDENTITY=432533504 ;;
	n100) BASE_PLAIN=207921152; BASE_IDENTITY=429506560 ;;
	*) fail "Unknown SoC '$SOC'. It must be rpi or n100." ;;
esac

[ -f "$SQUASHFS" ] || fail "The root filesystem $SQUASHFS does not exist, so its size cannot be checked."
SIZE=$(wc -c 2>/dev/null < "$SQUASHFS") || fail "The root filesystem $SQUASHFS cannot be read, so its size cannot be checked."
SIZE=$(printf '%s' "$SIZE" | tr -d ' \t')

if [ "$SIZE" -gt "$LIMIT" ]; then
	fail "The root filesystem is $SIZE bytes, over the 768 MiB limit ($LIMIT bytes). Revisit the control-plane-only extension image (platform.md §2.6) before shipping a root filesystem this large."
fi
echo "rootfs-size-check: the $SOC root filesystem is $SIZE bytes ($((SIZE / 1048576)) MiB) of the 768 MiB limit ($LIMIT bytes); the #957 baseline for $SOC is $BASE_PLAIN bytes without identity and $BASE_IDENTITY bytes with it."
