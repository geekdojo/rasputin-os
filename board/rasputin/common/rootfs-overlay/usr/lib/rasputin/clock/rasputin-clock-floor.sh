#!/bin/sh
#
# rasputin-clock-floor.sh — give systemd-timesyncd a WRITABLE timestamp file,
# stamped no earlier than this image's build date, before it starts.
#
# ── WHAT THIS IS NOW, AFTER THE ARM64 FIX (geekdojo-brain#601) ───────────────
#
# This unit used to be the node's clock floor. It is not any more, and it must
# not behave as though it still is, because there are now three mechanisms and
# two of them run before this one:
#
#   1. the PID 1 shim (usr/lib/rasputin/machine-id/rasputin-init) restores the
#      last-known-good time from /var/lib/rasputin/clock BEFORE systemd starts;
#   2. failing that, systemd's own clock_apply_epoch() applies
#      /usr/lib/clock-epoch, which post-fakeroot.sh now bakes with the IMAGE
#      build date;
#   3. THIS unit, which runs at mono ~12 — after journald, after the journal
#      flush, and therefore too late to be a floor for anything that matters.
#
# So its job is the one thing it is still the only thing that can do: give
# systemd-timesyncd a writable state directory on a read-only rootfs. The
# timestamp it leaves there is now max(the image build date, whatever the clock
# already reads), which is a DERIVATIVE of the floor rather than a competing
# one — it cannot pull time backwards and it cannot disagree with the shim.
#
# Concretely, if the shim restored 2026-09-22 and this stamped the state file at
# the 2026-06 build date instead, timesyncd would see a clock AHEAD of its
# recorded timestamp, take no action, and the two would merely look
# inconsistent in a log. Stamping from the running clock removes even that.
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
# WHY NOT THE PERSISTENT PARTITION -- AND WHAT CHANGED. The original reasoning
# here was that /var/lib/rasputin is a separate mount which on FIRST boot is
# still being created and grown (x-systemd.makefs, x-systemd.growfs over ~250
# GB), that timesyncd starts early in sysinit, and that ordering this unit
# behind that mount would delay time on every boot to improve a floor only
# consulted when NTP is unreachable.
#
# That reasoning was sound for THIS unit and it still is -- this unit still does
# not touch the persistent partition. What it missed is that the floor did not
# have to be a unit at all. The persisted last-known-good time is read by the
# PID 1 shim, which mounts that partition read-only before systemd starts, pays
# no ordering cost inside the boot transaction at all, and lands in front of
# journald rather than behind it. See usr/lib/rasputin/machine-id/rasputin-init.
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
# Overridden only by test/clock-floor-test.sh, which has to be able to say what
# "now" is in order to test both sides of the comparison below. The unit sets
# nothing, so the real boot takes the real date.
DATE="${RASPUTIN_CLOCK_DATE:-date}"

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

# -p preserves the mtime, which IS the stamp -- the contents are never read.
cp -p "$FACTORY" "$STATE_FILE"

# ...and then bring it up to the running clock if that is later.
#
# By the time this unit runs, the clock has already been floored twice: by the
# PID 1 shim from /var/lib/rasputin/clock, or failing that by systemd's
# clock_apply_epoch() from /usr/lib/clock-epoch, which carries this same image's
# build date. So "now" is >= the factory mtime on every healthy boot, and this
# touch is what keeps the state file from being the one stale number in the set.
#
# Strictly one-directional: the file is only ever moved FORWARD, so on a node
# where both earlier floors failed and the clock is still at systemd's package
# build date, the comparison is false and the factory mtime stands -- exactly
# the behaviour this unit had before. Every step is guarded because `set -e` is
# in force and a failed floor must not fail a boot.
now=$("$DATE" -u +%s 2>/dev/null || echo '')
stamp=$("$DATE" -u -r "$STATE_FILE" +%s 2>/dev/null || echo '')
# Both have to be plain decimals before either goes into `[ -gt ]`, and an
# empty one is not a decimal. Checked as one string so the guard cannot be
# half-applied.
comparable=no
if [ -n "$now" ] && [ -n "$stamp" ]; then
	case "$now$stamp" in
		*[!0123456789]*) ;;
		*) comparable=yes ;;
	esac
fi
if [ "$comparable" = no ]; then
	log "WARNING: could not compare the clock ('${now:-?}') with $STATE_FILE ('${stamp:-?}'); leaving the factory stamp in place"
elif [ "$now" -gt "$stamp" ]; then
	if touch "$STATE_FILE" 2>/dev/null; then
		log "advanced $STATE_FILE from the build date to the running clock"
	else
		log "WARNING: could not restamp $STATE_FILE; it keeps the build date"
	fi
fi

chown "$TS_USER:$TS_USER" "$STATE_DIR" "$STATE_FILE" 2>/dev/null || true
log "clock floor seeded at $STATE_FILE ($("$DATE" -u -r "$STATE_FILE" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo 'build date'))"
