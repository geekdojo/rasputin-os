#!/bin/sh
#
# merge-authorized-keys.sh — append key lines from stdin into the persistent
# authorized_keys (append-if-missing; blank lines and comments skipped).
#
# /var/lib/rasputin/dropbear/authorized_keys is the ONE file dropbear reads
# (dropbear.service runs with -D /var/lib/rasputin/dropbear); the read-only
# squashfs rootfs means /root/.ssh can't hold seed-supplied keys. Two callers
# feed it:
#   - dropbear.service ExecStartPre merges the build-baked key
#     (/usr/share/rasputin/authorized_keys.build — bench builds only), every
#     start, so a bench image works before any seed exists.
#   - rasputin-firstboot.sh merges RASPUTIN_SSH_AUTHORIZED_KEY from the seed.
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
