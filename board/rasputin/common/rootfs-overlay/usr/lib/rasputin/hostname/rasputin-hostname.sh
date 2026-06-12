#!/bin/sh
#
# rasputin-hostname.sh — set the per-role TRANSIENT hostname, every boot.
#
# Why: BR2_TARGET_GENERIC_HOSTNAME applies to every node built from this
# image. If that name were "rasputin", every compute node would fight the
# controlplane for rasputin.local via mDNS. Policy:
#
#   role == controlplane  ->  "rasputin"        (answers rasputin.local;
#                                                 WebAuthn RP ID + cert CN)
#   any other role        ->  the node id        (e.g. node-1a2b3c4d from
#                                                 the DMI/SoC serial, via
#                                                 firstboot's node.env)
#
# Why transient (kernel hostname, not /etc/hostname): the rootfs is
# read-only squashfs, so the static hostname cannot be rewritten at runtime.
# A transient name re-set each boot from node.env is also self-healing: the
# role can change via reprovisioning and the next boot just follows node.env.
# systemd-resolved watches /proc/sys/kernel/hostname and re-announces its
# mDNS records on change, so writing the kernel hostname is sufficient —
# no resolved restart, no dbus/hostnamed dependency.
#
set -eu

NODE_ENV=/var/lib/rasputin/node.env

# Same kmsg mirroring as rasputin-firstboot.sh: printk reaches every
# console= device, so these lines show on serial/HDMI and CI can grep them.
log() {
	echo "rasputin-hostname: $*"
	echo "rasputin-hostname: $*" > /dev/kmsg 2>/dev/null || true
}

ROLE=""
NODE_ID=""
if [ -f "$NODE_ENV" ]; then
	# shellcheck disable=SC1090
	. "$NODE_ENV"
	ROLE="${RASPUTIN_NODE_ROLE:-}"
	NODE_ID="${RASPUTIN_NODE_ID:-}"
else
	# RequiresMountsFor guarantees the partition is mounted; a missing
	# node.env means firstboot never completed. Keep the baked placeholder
	# ("rasputin-node") rather than guessing — it deliberately collides
	# with nothing.
	log "no $NODE_ENV; keeping baked hostname $(cat /proc/sys/kernel/hostname)"
	exit 0
fi

if [ "$ROLE" = "controlplane" ]; then
	NAME="rasputin"
else
	NAME="$NODE_ID"
fi

if [ -z "$NAME" ]; then
	log "empty hostname for role=$ROLE; keeping baked hostname"
	exit 0
fi

printf '%s' "$NAME" > /proc/sys/kernel/hostname
log "transient hostname set to $NAME (role=$ROLE)"
