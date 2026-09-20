#!/bin/sh
#
# rasputin-clock-floor.sh — give systemd-timesyncd a WRITABLE timestamp file,
# stamped at this image's build date, before it starts.
#
# WHY THIS EXISTS AT ALL.
#
# A board with no battery-backed RTC (every Pi) boots at the Unix epoch. PID 1
# advances the clock to systemd's own compiled-in build time -- the systemd
# PACKAGE's, not this image's -- which on 2026.09.4 was 2025-06-25, fifteen
# months stale:
#
#     rpi-rtc soc:rpi_rtc: setting system clock to 1970-01-01T00:00:53 UTC
#     systemd[1]: System time before build time, advancing clock.
#
# The control plane then mints its Mesh CA and HTTPS leaf against that clock.
# On a node that can reach NTP the api's 90s clock gate covers it. On one that
# CANNOT -- the no-DHCP bootstrap address carries no gateway on purpose (#53),
# and the baked FallbackNTP is four off-LAN anycast IPs -- the gate always
# expires and the leaf is dated fifteen months in the past, i.e. already
# expired to every client, and never heals (the renewal check reads the same
# wrong clock and sees a year left). geekdojo/rasputin-os#1.
#
# WHY A TMPFS AND NOT JUST A BAKED FILE.
#
# systemd-timesyncd restores the clock from the mtime of its timestamp file
# before any NTP exchange -- proven on the bench 2026-09-20:
#
#     systemd-timesyncd[994]: System clock time unset or jumped backwards,
#       restored from recorded timestamp: Sun 2026-09-20 22:52:16 UTC
#
# But it opens that file READ-WRITE, so it can update it after a sync. The
# rootfs is a read-only squashfs, so a file baked straight into
# /var/lib/systemd/timesync/ fails that open with EROFS, timesyncd takes its
# "Unable to open timestamp file, ignoring" path, and SKIPS the restore --
# silently, with nothing at default log level. PR #101 shipped exactly that and
# the bench came up on 2025-06-25 with an expired leaf anyway.
#
# So the floor needs a writable home. A small tmpfs over the state directory,
# seeded from the factory copy with its mtime preserved, is the whole fix.
#
# WHY NOT THE PERSISTENT PARTITION. /var/lib/rasputin is writable and would
# carry a post-NTP timestamp across reboots, which is strictly a better floor.
# It is also a separate mount that on FIRST boot is still being created and
# grown (x-systemd.makefs, x-systemd.growfs over ~250 GB), and timesyncd starts
# early in sysinit. Ordering the clock floor behind that mount would delay time
# for every boot to improve a floor that is only ever consulted when NTP is
# unreachable. The build date is a correct, always-available answer; take it.
# Losing a post-sync timestamp at reboot costs nothing a reachable NTP server
# does not immediately fix.
#
# This is a FLOOR, not a clock. It does not make an offline node's time correct
# and replaces nothing about NTP -- it bounds how wrong the time can be at the
# moment a certificate is signed.
#
# POSIX sh: no arrays, no [[ ]], no local.

set -eu

FACTORY=/usr/share/factory/rasputin/timesync-clock
STATE_DIR=/var/lib/systemd/timesync
STATE_FILE="$STATE_DIR/clock"
# timesyncd drops privileges to this user and must be able to rewrite the file.
TS_USER=systemd-timesync

log() {
	echo "rasputin-clock-floor: $*"
	echo "rasputin-clock-floor: $*" > /dev/kmsg 2>/dev/null || true
}

[ -f "$FACTORY" ] || { log "no factory copy at $FACTORY; nothing to do"; exit 0; }

# Already writable? Then the image layout changed under us and the tmpfs is not
# needed -- seed the file only if it is missing, and never clobber a timestamp
# a previous sync recorded (it is newer than the build by definition).
if [ ! -w "$STATE_DIR" ] 2>/dev/null || ! touch "$STATE_DIR/.wtest" 2>/dev/null; then
	mkdir -p "$STATE_DIR"
	mount -t tmpfs -o size=64k,mode=0755 tmpfs "$STATE_DIR" \
		|| { log "WARNING: could not mount the tmpfs on $STATE_DIR; timesyncd will not restore the clock and an offline node will mint certificates dated to systemd's build time"; exit 0; }
	log "mounted a writable tmpfs on $STATE_DIR"
else
	rm -f "$STATE_DIR/.wtest"
	if [ -e "$STATE_FILE" ]; then
		log "$STATE_DIR is already writable and holds a timestamp; leaving it alone"
		exit 0
	fi
fi

# -p preserves the mtime, which IS the floor -- the contents are never read.
cp -p "$FACTORY" "$STATE_FILE"
chown "$TS_USER:$TS_USER" "$STATE_DIR" "$STATE_FILE" 2>/dev/null || true
log "clock floor seeded at $STATE_FILE ($(date -u -r "$STATE_FILE" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo 'build date'))"
