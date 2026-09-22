#!/bin/sh
#
# rasputin-clock-save.sh — persist the node's current time to the persistent
# partition, so the PID 1 shim can use it as a clock floor on the next boot.
#
# This is the fake-hwclock pattern, which is what every distro that ships a
# no-RTC board does: a board with no battery RTC boots with no clock, so the
# last time it is known to have had becomes the floor for the next boot. It is
# the SAVE half; the RESTORE half is in
# usr/lib/rasputin/machine-id/rasputin-init, which reads this file before
# systemd starts. Read that script for why the restore cannot be a unit.
#
# ── ONLY FORWARDS ────────────────────────────────────────────────────────────
#
# The store is never moved backwards. A clock that reads earlier than the store
# means this boot has not been corrected yet (an offline node sitting on its own
# floor, or one that got no further than the image's /usr/lib/clock-epoch), and
# overwriting the store with it would ratchet the floor DOWN one boot at a time
# until it was the image build date again — the defect with extra steps. So the
# comparison is the whole logic and the write is the easy part.
#
# ── WHEN IT RUNS, AND WHY MORE THAN ONCE ─────────────────────────────────────
#
#   ExecStart of rasputin-clock-save.service   once per boot
#   ExecStop  of rasputin-clock-save.service   at every clean shutdown
#   ExecStart of rasputin-clock-tick.service   hourly, from its .timer
#
# The shutdown write is the one that matters and is mandatory: a node that is
# powered down cleanly and brought up days later restores the time it went down
# with. The hourly tick exists because an appliance loses power uncleanly, and
# without it the floor after a power cut is the last CLEAN shutdown, which on a
# box that has been up for three months is three months stale — the same defect
# at a slower rate.
#
# The write cost of the tick is one 4 KiB ext4 block an hour, on a partition
# that journald is already writing continuously (measured at 9.6 KB per five
# minutes on an idle node, i.e. roughly two orders of magnitude more). So the
# wear argument does not bind here, and an hour is the coarsest cadence that
# still bounds post-power-cut staleness to something no operator would notice.
#
# ── POSIX sh: no arrays, no [[ ]], no local. ─────────────────────────────────

set -eu

STORE="${RASPUTIN_CLOCK_STORE:-/var/lib/rasputin/clock}"
DATE="${RASPUTIN_CLOCK_DATE:-date}"

log() {
	echo "rasputin-clock-save: $*"
	echo "rasputin-clock-save: $*" > /dev/kmsg 2>/dev/null || true
}

# Exactly the rule rasputin-init applies when it reads this file back: ten
# decimal digits. Validating on the way out as well means a value the shim would
# refuse never reaches the store in the first place, so a refusal at boot always
# means damage rather than a disagreement between the two halves.
valid() {
	[ "${#1}" -eq 10 ] || return 1
	case "$1" in
		*[!0123456789]*) return 1 ;;
	esac
	return 0
}

now=$("$DATE" -u +%s 2>/dev/null || echo '')
if ! valid "$now"; then
	log "refusing to save: the clock reads '${now:-<nothing>}', which is not a ten-digit Unix timestamp"
	exit 0
fi

stored=
if [ -r "$STORE" ]; then
	# read returns non-zero on a final line with no newline, having set the
	# variable, so its status is not a test — hence `|| :` under set -e.
	read -r stored <"$STORE" 2>/dev/null || :
fi

if valid "$stored" && [ "$stored" -ge "$now" ]; then
	# The offline-node case, and every boot of a node whose clock has not been
	# corrected yet. Not a fault; say so without alarming language.
	log "clock $now is not ahead of the stored $stored; leaving the floor where it is"
	exit 0
fi

if [ -e "$STORE" ] && ! valid "$stored"; then
	log "replacing an unusable clock store at $STORE (content '${stored:-<empty>}')"
fi

# Temp file in the same directory then rename, so a power cut leaves either the
# old floor or the new one and never half a timestamp — the same shape
# rasputin-machine-id-commit.sh uses, and for the same reason. 0644: this is the
# image's own record of how long the node has been alive, not a credential, and
# it is not in the at-rest inventory for that reason.
tmp="$STORE.tmp"
(umask 0133; printf '%s\n' "$now" >"$tmp")
mv "$tmp" "$STORE"
sync

log "saved clock $now to $STORE"
