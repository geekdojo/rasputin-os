#!/bin/sh
# strip-serial-console.sh — remove the kernel serial console from both boot
# slots' cmdline.txt on a BMC-host node (control-plane/bmc-bitscope.md §5).
#
# On the BMC host, serial0/ttyAMA0 is the command channel to the BitScope
# BMC bus. The BMC ignores bytes while locked, but the bitscope driver
# UNLOCKS the bus to operate — after which kernel printk to ttyAMA0 is live
# command traffic (single-char verbs; '\' is a hard power cut). The login
# getty is suppressed separately by a marker-gated drop-in; this script
# handles the kernel side, which only cmdline can.
#
# Mechanics: the rpi layout keeps a full boot env per RAUC slot on two FAT
# partitions that are NOT normally mounted (genimage.cfg: p2 boot-a, p3
# boot-b; MBR, so addressed by PARTUUID disk-sig+partnum). Mount each rw,
# strip `console=ttyAMA<n>,<baud>` from cmdline.txt with the tryboot
# backend's atomic tmp+mv+sync idiom, and report whether anything changed
# so the caller (firstboot) can reboot once to shed the live console.
#
# Exit: 0 = done, nothing changed · 10 = done, cmdline(s) changed (reboot
# needed) · other = error. No-op (exit 0) on non-rpi layouts.

set -u

# The policy itself (which tokens go) lives in cmdline-policy.sh, shared with
# the RAUC bundle hook that rewrites cmdline.txt on every update.
. "$(dirname "$0")/cmdline-policy.sh"

BOOT_PARTS="/dev/disk/by-partuuid/52415350-02 /dev/disk/by-partuuid/52415350-03"
MNT=/run/rasputin-bootfat
CHANGED=0

log() { echo "strip-serial-console: $*"; }

for dev in $BOOT_PARTS; do
	[ -e "$dev" ] || { log "no $dev (not the rpi layout?) — skipping"; continue; }
	mkdir -p "$MNT"
	if ! mount -t vfat -o rw "$dev" "$MNT"; then
		log "ERROR: mount $dev failed"
		exit 1
	fi
	CMDLINE="$MNT/cmdline.txt"
	if [ ! -f "$CMDLINE" ]; then
		log "WARNING: $dev has no cmdline.txt"
		umount "$MNT"
		continue
	fi
	# Strip any serial console token (ttyS0 is the header UART on this
	# image, bench-verified 2026-07-23; see cmdline-policy.sh).
	if cmdline_has_serial_console "$CMDLINE"; then
		cmdline_strip_serial_console "$CMDLINE" > "$CMDLINE.tmp"
		mv "$CMDLINE.tmp" "$CMDLINE"
		sync
		CHANGED=1
		log "stripped serial console from $dev cmdline"
	fi
	umount "$MNT"
done

[ "$CHANGED" = "1" ] && exit 10
exit 0
