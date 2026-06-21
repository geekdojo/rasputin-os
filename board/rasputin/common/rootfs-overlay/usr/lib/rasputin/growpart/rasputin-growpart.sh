#!/bin/sh
# rasputin-growpart — one-time grow of the data partition to fill the disk.
#
# The images ship a fixed-size GPT (genimage): a small data partition with the
# rest of the medium left unallocated. The fstab's x-systemd.growfs only grows
# the FILESYSTEM to its PARTITION, so without this the data partition stays at
# its image size (e.g. 512 MiB) no matter how big the disk is — every unit ends
# up cramped regardless of SSD/eMMC size. (Found on a 128 GB n100: ~116 GB sat
# unpartitioned. See backlog updates.md.)
#
# This extends the last (data) partition into the unallocated remainder, then
# reboots so the kernel re-reads the table and the next mount's x-systemd.growfs
# expands the ext4 filesystem to match. Only the partition's END moves — its
# start (and therefore its filesystem + any data) is untouched.
#
# IDEMPOTENT: a no-op once the partition already fills the disk, so it's safe to
# run on every boot. It MUST be ordered AFTER rasputin-mark-good.service: the
# GRUB boot-counter consumes one try per boot, so rebooting before the slot is
# marked good would trip a rollback. By the time this runs the slot is committed,
# so the reboot is clean.
set -eu

log() { echo "rasputin-growpart: $*"; }

PARTDEV="$(readlink -f /dev/disk/by-partlabel/persistent 2>/dev/null || true)"
if [ -z "$PARTDEV" ] || [ ! -b "$PARTDEV" ]; then
	log "data partition (by-partlabel/persistent) not present; nothing to do"
	exit 0
fi

PARTBASE="${PARTDEV##*/}"                                       # nvme0n1p4 / sda4 / mmcblk0p4
DISKBASE="$(lsblk -ndo pkname "$PARTDEV" 2>/dev/null || true)"  # nvme0n1 / sda / mmcblk0
if [ -z "$DISKBASE" ] || [ ! -b "/dev/$DISKBASE" ]; then
	log "cannot resolve parent disk of $PARTDEV; nothing to do"
	exit 0
fi
DISK="/dev/$DISKBASE"

DISK_SZ="$(cat "/sys/class/block/$DISKBASE/size")"             # 512-byte sectors
P_START="$(cat "/sys/class/block/$PARTBASE/start")"
P_SZ="$(cat "/sys/class/block/$PARTBASE/size")"
TAIL=$(( DISK_SZ - (P_START + P_SZ) ))                         # unallocated sectors after the partition

# Already fills the disk (tail < 32 MiB)? This is the steady state — and the
# guard that makes the unit safe every boot and prevents any reboot loop.
if [ "$TAIL" -lt 65536 ]; then
	log "$PARTDEV already fills $DISK ($((P_SZ / 2048)) MiB; $((TAIL / 2048)) MiB tail) — nothing to do"
	exit 0
fi

log "extending $PARTDEV into $((TAIL / 2048)) MiB of unallocated space on $DISK"

# Rewrite the GPT: drop last-lba (sfdisk recomputes it to the real disk end) and
# drop the data partition's size (it then fills to the disk end). Every other
# partition is copied verbatim, so the ESP + rootfs A/B slots are untouched, and
# the data partition's start is unchanged, so its filesystem is preserved.
# --no-reread: the data partition is mounted, so the kernel can't re-read the
# table now — that's fine, the reboot below picks it up cleanly.
sfdisk --dump "$DISK" \
	| grep -v '^last-lba:' \
	| sed "\\#^${PARTDEV} #s/size=[[:space:]]*[0-9][0-9]*,[[:space:]]*//" \
	| sfdisk --no-reread "$DISK"
sync

log "GPT extended; rebooting so the kernel re-reads it and growfs expands the fs"
systemctl reboot
# Hold the oneshot open until the reboot lands so boot doesn't race ahead.
sleep 120
