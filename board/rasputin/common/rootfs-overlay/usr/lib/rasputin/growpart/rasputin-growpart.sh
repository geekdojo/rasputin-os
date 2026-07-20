#!/bin/sh
# rasputin-growpart — one-time grow of the data (persistent) partition to fill
# the disk.
#
# The images ship a fixed-size data partition with the rest of the medium left
# unallocated. The fstab's x-systemd.growfs only grows the FILESYSTEM to its
# PARTITION — so without this the partition stays at its image size (e.g. 512
# MiB) no matter how big the disk is. This extends the partition into the
# unallocated tail, then reboots so the kernel re-reads the table and the next
# mount's x-systemd.growfs expands the fs. Only the END moves; the start (and
# therefore the filesystem + data) is untouched.
#
# Table-aware (the two arches diverge at the partition table):
#   - GPT (n100): drop last-lba + the partition's size via sfdisk — the data
#     partition is a top-level GPT partition, so this is a one-liner.
#   - MBR (rpi):  persistent is the LAST LOGICAL inside an EXTENDED partition, so
#     BOTH must grow (the extended first). Raw sfdisk on MBR extended/logical is
#     a data-loss trap (the EBR-sector math) — so this uses the vendored
#     cloud-utils `growpart` (battle-tested) with `-u off`: write the table only
#     and defer the kernel re-read to the reboot below (the disk is busy because
#     persistent is mounted). Validated against the rpi layout in a loopback
#     container, including with partx/udevadm/sgdisk absent (the image case).
#
# IDEMPOTENT: a no-op once the partition already fills the disk, so it's safe to
# run every boot. MUST be ordered AFTER rasputin-mark-good.service (n100 GRUB
# boot-counter — rebooting before the slot is committed would trip a rollback).
# On the rpi mark-good is skipped (n100-only) so the After is a no-op, and this
# only ever reboots at FIRST boot (persistent still 512 MiB), before any OTA — so
# it can't abort an A/B trial.
set -eu

log() { echo "rasputin-growpart: $*"; }
GROWPART=/usr/lib/rasputin/growpart/growpart

# Every run's outcome is also appended to a breadcrumb log on the persistent
# partition itself — the journal is volatile, so the one boot where the grow
# actually happens is unreadable after the post-grow reboot (#2). The first
# token after the timestamp is a machine-readable outcome keyword:
#   grown | already-full | deferred-trial | skipped | failed
# Logging must never fail (or fail) the grow: the whole append is || true, and
# timestamps may be pre-NTP fake time on a no-RTC first boot — post-mortems
# should lean on the keyword and ordering, not the clock. Bounded by keeping
# the newest 32 KiB once the file passes 64 KiB (steady state appends one
# already-full line per boot).
CRUMB_LOG=/var/lib/rasputin/growpart.log
CRUMBED=""
crumb() {
	log "$*"
	CRUMBED=1
	{
		if [ "$(wc -c <"$CRUMB_LOG" 2>/dev/null || echo 0)" -gt 65536 ]; then
			tail -c 32768 "$CRUMB_LOG" >"$CRUMB_LOG.tmp" && mv "$CRUMB_LOG.tmp" "$CRUMB_LOG"
		fi
		echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >>"$CRUMB_LOG"
	} 2>/dev/null || true
}
# set -eu aborts leave no outcome line — catch them so a wedged grow is visible
# in the breadcrumb, not just the (lost) journal. Non-zero exits only: the
# not-a-mount path exits 0 without crumbing (nowhere durable to write), and
# crumb sets CRUMBED, which disarms this for the post-reboot SIGTERM of the
# sleep below.
trap 'rc=$?; [ "$rc" -eq 0 ] || [ -n "$CRUMBED" ] || crumb "failed: exit=$rc — grow aborted, see journalctl -u rasputin-growpart on this boot"' EXIT

# Resolve the persistent partition via its mount — works for GPT (PARTLABEL) and
# MBR (PARTUUID) alike, since both mount at /var/lib/rasputin per the per-SoC fstab.
PARTDEV="$(findmnt -no SOURCE /var/lib/rasputin 2>/dev/null || true)"
PARTDEV="$(readlink -f "$PARTDEV" 2>/dev/null || true)"
if [ -z "$PARTDEV" ] || [ ! -b "$PARTDEV" ]; then
	log "persistent (/var/lib/rasputin) not on a block device; nothing to do"
	exit 0
fi

PARTBASE="${PARTDEV##*/}"                                      # nvme0n1p7 / sda4 / mmcblk0p7
DISKBASE="$(lsblk -ndo pkname "$PARTDEV" 2>/dev/null || true)" # nvme0n1 / sda / mmcblk0
if [ -z "$DISKBASE" ] || [ ! -b "/dev/$DISKBASE" ]; then
	crumb "skipped: cannot resolve parent disk of $PARTDEV; nothing to do"
	exit 0
fi
DISK="/dev/$DISKBASE"

DISK_SZ="$(cat "/sys/class/block/$DISKBASE/size")"            # 512-byte sectors
P_START="$(cat "/sys/class/block/$PARTBASE/start")"
P_SZ="$(cat "/sys/class/block/$PARTBASE/size")"
TAIL=$(( DISK_SZ - (P_START + P_SZ) ))                        # unallocated sectors after the partition

# Already fills the disk (tail < 32 MiB)? Steady state — and the guard that
# makes the unit safe every boot and prevents any reboot loop. Checked BEFORE the
# trial guard below so an already-grown node never reboots, even mid-trial.
if [ "$TAIL" -lt 65536 ]; then
	crumb "already-full: $PARTDEV fills $DISK ($((P_SZ / 2048))MiB; $((TAIL / 2048))MiB tail) — nothing to do"
	exit 0
fi

# Don't grow+reboot while in an uncommitted A/B trial — the reboot would boot the
# COMMITTED slot and abort the trial before the update saga commits it. On the
# n100 the unit's After=mark-good already guarantees a committed slot here; on the
# rpi the commit is saga-driven (no local mark-good), so growpart can land mid-
# trial — guard explicitly. A trial = the booted slot differs from the activated
# (committed) slot in `rauc status`. Defer to a committed boot (a fresh flash's
# first boot is already committed; after an OTA, the next committed boot grows it).
RAUC_ST="$(rauc status 2>/dev/null)"
BOOTED="$(printf '%s\n' "$RAUC_ST" | grep -i 'Booted from' | grep -oE 'rootfs\.[0-9]+' | head -1)"
ACTIVE="$(printf '%s\n' "$RAUC_ST" | grep -i 'Activated'   | grep -oE 'rootfs\.[0-9]+' | head -1)"
if [ -n "$BOOTED" ] && [ -n "$ACTIVE" ] && [ "$BOOTED" != "$ACTIVE" ]; then
	crumb "deferred-trial: in an uncommitted A/B trial (booted=$BOOTED, committed=$ACTIVE) — deferring grow+reboot to a committed boot"
	exit 0
fi

PARTNUM="$(echo "$PARTBASE" | sed 's/.*[^0-9]//')"           # trailing digits = partition number
PTTYPE="$(lsblk -ndo PTTYPE "$DISK" 2>/dev/null || true)"
log "extending $PARTDEV (part $PARTNUM, table=$PTTYPE) into $((TAIL / 2048)) MiB on $DISK"

case "$PTTYPE" in
gpt)
	# Drop last-lba (sfdisk recomputes to the real disk end) + the partition's
	# size (it then fills to the end). Every other partition is copied verbatim,
	# and the start is unchanged, so the filesystem is preserved. --no-reread:
	# the partition is mounted, so the reboot below picks up the new table.
	sfdisk --dump "$DISK" \
		| grep -v '^last-lba:' \
		| sed "\\#^${PARTDEV} #s/size=[[:space:]]*[0-9][0-9]*,[[:space:]]*//" \
		| sfdisk --no-reread "$DISK"
	;;
dos)
	# Grow the EXTENDED partition (type 0x05/0x0f) first, then the persistent
	# logical into it. growpart handles the EBR/extended math; -u off writes the
	# table and defers the re-read to the reboot. If the extended can't be found,
	# fail SAFE — skip (persistent just stays at its image size), never guess.
	EXTNUM="$(sfdisk -d "$DISK" 2>/dev/null \
		| grep -iE 'type=0?[5f]([^0-9a-f]|$)' \
		| sed -n 's#.*[^0-9]\([0-9][0-9]*\) :.*#\1#p' | head -1)"
	if [ -z "$EXTNUM" ]; then
		crumb "skipped: no extended partition found on $DISK (MBR) — cannot grow a logical"
		exit 0
	fi
	sh "$GROWPART" -u off "$DISK" "$EXTNUM"
	sh "$GROWPART" -u off "$DISK" "$PARTNUM"
	;;
*)
	crumb "skipped: unrecognized partition table '$PTTYPE' on $DISK; not growing"
	exit 0
	;;
esac
sync

# The grown line must land (and sync) BEFORE the reboot — it's the one outcome
# whose journal is guaranteed lost.
crumb "grown: $PARTDEV $((P_SZ / 2048))MiB -> $(((P_SZ + TAIL) / 2048))MiB (table=$PTTYPE, part $PARTNUM); rebooting"
sync
log "table extended; rebooting so the kernel re-reads it and growfs expands the fs"
systemctl reboot
# Hold the oneshot open until the reboot lands so boot doesn't race ahead.
sleep 120
