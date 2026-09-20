#!/bin/sh
# Restrict stored core dumps to 0600.
#
# Run as ExecStopPost of systemd-coredump@.service — i.e. in the same unit
# that just wrote a core, after ExecStart has linked it into place. See
# etc/systemd/system/systemd-coredump@.service.d/rasputin-coredump.conf for
# why this exists at all: systemd hard-codes 0640 on a stored core and offers
# no configuration knob, so the mode can only be corrected afterwards.
#
# Idempotent and cheap: the store is hard-capped at a handful of files by
# coredump.conf.d/rasputin.conf, and chmod on a file already at 0600 is a
# no-op. It runs on every dump rather than once at boot so a core written
# hours into an uptime is covered too.
#
# Deliberately silent about which files it touched: the filenames carry the
# comm and pid of processes that crashed, and this runs unconditionally, so
# logging them would put that in the journal on every dump for no operator
# benefit. A failure still surfaces — the exit status fails the unit.
set -eu

STORE="${1:-/var/lib/systemd/coredump}"

# Nothing to do before the store is mounted, or when Storage= is not external
# (cores in the journal never become files here). Not an error either way.
[ -d "$STORE" ] || exit 0

# -type f so the directory's own mode is left to StateDirectoryMode, and so a
# stray symlink cannot redirect the chmod at something outside the store.
find "$STORE" -type f -exec chmod 0600 {} +
