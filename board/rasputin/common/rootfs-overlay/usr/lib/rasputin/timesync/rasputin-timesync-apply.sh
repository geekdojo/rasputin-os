#!/bin/sh
#
# rasputin-timesync-apply.sh — apply the operator's seed-provided NTP server(s)
# to systemd-timesyncd. Runs every boot (multi-user.target.wants) after
# rasputin-firstboot has written node.env.
#
# Why a per-boot render into /run: the rootfs /etc is read-only squashfs, so
# the drop-in can't be persisted there. node.env on the persistent partition is
# the source of truth; /run/systemd/timesyncd.conf.d is re-rendered each boot.
# The rendered NTP= outranks the image's baked FallbackNTP= but is still
# superseded by any DHCP option-42 server — the documented precedence.
#
# No RASPUTIN_NTP_SERVER in node.env -> no-op: the baked FallbackNTP already
# guarantees a reachable time source on a DNS-less network, so most nodes never
# need this.
set -eu

NODE_ENV=/var/lib/rasputin/node.env
DROPIN_DIR=/run/systemd/timesyncd.conf.d
DROPIN="$DROPIN_DIR/20-rasputin-seed-ntp.conf"

[ -r "$NODE_ENV" ] || exit 0
# shellcheck disable=SC1090
. "$NODE_ENV"
NTP="${RASPUTIN_NTP_SERVER:-}"
[ -n "$NTP" ] || exit 0

# Sanitize to a single line of host/IP/space characters — never let a seed
# value inject extra timesyncd directives or [section] headers.
NTP=$(printf '%s' "$NTP" | tr -d '\n' | tr -cd 'A-Za-z0-9 .:_-')
[ -n "$NTP" ] || exit 0

mkdir -p "$DROPIN_DIR"
cat > "$DROPIN" <<EOF
# Generated each boot from RASPUTIN_NTP_SERVER (seed) by
# rasputin-timesync-apply.service. Do not edit — edit the seed instead.
[Time]
NTP=$NTP
EOF

echo "rasputin-timesync: applied seed NTP server(s): $NTP" > /dev/kmsg 2>/dev/null || true

# timesyncd starts early (before this unit); bounce it so it re-reads config and
# prefers the operator's server. --no-block: don't wait inside the boot
# transaction. try-restart: only act if it's actually running.
systemctl try-restart --no-block systemd-timesyncd.service 2>/dev/null || true
