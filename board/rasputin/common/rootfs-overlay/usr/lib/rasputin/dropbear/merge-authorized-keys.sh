#!/bin/sh
#
# merge-authorized-keys.sh — append key lines from stdin into the persistent
# authorized_keys (append-if-missing; blank lines and comments skipped).
#
# /var/lib/rasputin/dropbear/authorized_keys is the ONE file dropbear reads
# (dropbear.service runs with -D /var/lib/rasputin/dropbear); the read-only
# squashfs rootfs means /root/.ssh can't hold seed-supplied keys. The image
# bakes NO key (pre-GA vendor-key removal, 2026-07-09) — the caller is
# rasputin-firstboot.sh merging RASPUTIN_SSH_AUTHORIZED_KEY from the seed
# (an operator can also pipe a key in by hand: printf '%s\n' "<key>" | ...).
#
# Append-if-missing (never overwrite): the file is operator-owned — manual
# additions survive, and revocation is a manual edit of this file.
#
set -eu

DIR=/var/lib/rasputin/dropbear
OUT=$DIR/authorized_keys

umask 077
mkdir -p "$DIR"
touch "$OUT"
chmod 600 "$OUT"

while IFS= read -r line; do
	case "$line" in
		'' | '#'*) continue ;;
	esac
	grep -qxF -- "$line" "$OUT" || printf '%s\n' "$line" >> "$OUT"
done
