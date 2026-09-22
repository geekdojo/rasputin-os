#!/bin/sh
#
# rasputin-machine-id-commit.sh — store this node's machine-id on the persistent
# partition, once, so /sbin/init (rasputin-init) can hand the same value back to
# systemd on every subsequent boot.
#
# This is systemd-machine-id-commit.service's job, done where systemd cannot do
# it. Upstream commits the transient /run/machine-id to /etc/machine-id as soon
# as /etc becomes writable; ours never does — the unit is skipped on every boot
# of every node with "ConditionPathIsReadWrite=/etc was not met" — so the commit
# target here is /var/lib/rasputin/machine-id on the persistent partition
# instead. That partition is outside both RAUC rootfs slots, so ONE stored id
# serves slot A and slot B and survives every OTA (a bundle carries rootfs.img
# and nothing else — post-image.sh).
#
# WHAT IT COMMITS is whatever id the node is running with right now. On the
# first boot of a fresh node, and on the first boot after this image lands on a
# fielded one, that is the transient id systemd minted this boot: the node keeps
# the identity it already has rather than being handed a new one. From the next
# boot onward rasputin-init restores it before systemd starts, and this script
# is a no-op forever.
#
# IT NEVER REPLACES A STORED ID. If the store and the running id disagree, the
# restore did not happen this boot (an unreadable persistent partition, a
# missing findfs, /sbin/init reverted) — overwriting would make the identity
# churn again, and churn is the whole defect. It says so loudly and changes
# nothing.
#
# Run:  ExecStart of rasputin-machine-id-commit.service, after the persistent
#       partition is mounted. test/machine-id-test.sh runs it against a scratch
#       directory through the RASPUTIN_MACHINE_ID_* overrides below; the unit
#       sets none of them.
#
set -eu

PERSIST="${RASPUTIN_MACHINE_ID_PERSIST:-/var/lib/rasputin}"
STORE="$PERSIST/machine-id"
CURRENT="${RASPUTIN_MACHINE_ID_CURRENT:-/etc/machine-id}"

log() { echo "rasputin-machine-id-commit: $*"; }

# Exactly what rasputin-init will accept when it reads the store back: systemd's
# own rule, 32 lowercase hex digits and not all zeros. Validating here as well
# keeps a malformed value out of the store in the first place.
valid() {
	[ "${#1}" -eq 32 ] || return 1
	case "$1" in
		*[!0123456789abcdef]*) return 1 ;;
		00000000000000000000000000000000) return 1 ;;
	esac
	return 0
}

# read_id FILE — print FILE's first line, or nothing. Never fails, so `set -e`
# does not turn a missing store into an aborted unit. `read` also returns
# non-zero on a last line with no newline, having set the variable — hence the
# `|| :` rather than a test on its status.
read_id() {
	_ri_v=
	if [ -r "$1" ]; then
		read -r _ri_v <"$1" 2>/dev/null || :
	fi
	printf '%s' "$_ri_v"
}

running=$(read_id "$CURRENT")
if ! valid "$running"; then
	# Nothing to commit. systemd always has a machine-id by this point, so this
	# means /etc/machine-id is not what it should be — report it rather than
	# writing a broken value into the store.
	log "refusing to commit: $CURRENT is not a valid machine-id (got '${running:-<empty>}')"
	exit 0
fi

stored=$(read_id "$STORE")
if valid "$stored"; then
	if [ "$stored" = "$running" ]; then
		log "machine-id $running already committed"
		exit 0
	fi
	log "WARNING: stored machine-id $stored was NOT restored this boot (running $running)"
	log "WARNING: leaving the store alone — /sbin/init did not deliver it; see rasputin-init"
	exit 0
fi

if [ -e "$STORE" ]; then
	log "replacing an unusable store at $STORE (content '${stored:-<empty>}')"
fi

# Write through a temp file in the same directory so a power cut leaves either
# no store or a complete one, never half an id. 0444 to match the mode systemd
# gives /etc/machine-id: this is an identity, not a setting, and nothing on the
# node may edit it in place.
tmp="$STORE.tmp"
(umask 0222; printf '%s\n' "$running" >"$tmp")
mv "$tmp" "$STORE"
sync

log "committed machine-id $running to $STORE — it takes effect on the next boot"
