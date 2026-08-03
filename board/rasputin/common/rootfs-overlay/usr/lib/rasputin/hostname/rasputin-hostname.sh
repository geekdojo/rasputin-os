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
	# ADR-0003: the controlplane answers to its CLUSTER's name, not a shared
	# literal. Defaults to "rasputin", so a node whose node.env predates
	# per-cluster naming keeps the exact hostname it has always had.
	CLUSTER_ID="${RASPUTIN_CLUSTER_ID:-rasputin}"
else
	# RequiresMountsFor guarantees the partition is mounted; a missing
	# node.env means firstboot never completed. Keep the baked placeholder
	# ("rasputin-node") rather than guessing — it deliberately collides
	# with nothing.
	log "no $NODE_ENV; keeping baked hostname $(cat /proc/sys/kernel/hostname)"
	exit 0
fi

if [ "$ROLE" = "controlplane" ]; then
	# This value becomes a DNS label: the mDNS name the whole cluster is
	# reached by, the CN/SAN of the api's TLS leaf, the WebAuthn RP ID, and the
	# host every node's seeded NATS URL dials. Nothing upstream validates it —
	# rasputin-provision accepts any --cluster-id string — so it is validated
	# HERE, at the last point before it becomes the machine's identity.
	#
	# Lowercase first rather than reject: DNS labels are case-insensitive, and
	# firstboot already lowercases the DMI serial when deriving a node id, so
	# "Home1" becoming "home1" is consistent rather than surprising.
	CLUSTER_ID=$(printf '%s' "$CLUSTER_ID" | tr 'A-Z' 'a-z')
	case "$CLUSTER_ID" in
		"" | -* | *- | *[!a-z0-9-]*) CLUSTER_VALID=no ;;
		*) CLUSTER_VALID=yes ;;
	esac
	if [ "${#CLUSTER_ID}" -gt 63 ]; then
		CLUSTER_VALID=no
	fi

	if [ "$CLUSTER_VALID" = yes ]; then
		NAME="$CLUSTER_ID"
	else
		# Fall back rather than fail. This runs at boot on a HEADLESS box: an
		# invalid hostname means no mDNS name at all, so the operator has no
		# way in and nothing to read. "rasputin" at least keeps it reachable —
		# the historical behaviour — and if that now collides with another
		# cluster, the agent's name guard detects and reports it.
		log "WARNING: cluster id '$CLUSTER_ID' is not a valid DNS label (a-z 0-9 -, no leading/trailing -, <=63 chars); falling back to 'rasputin'. This node will NOT answer to its cluster's name — re-provision with a valid --cluster-id."
		NAME="rasputin"
	fi
else
	NAME="$NODE_ID"
fi

if [ -z "$NAME" ]; then
	log "empty hostname for role=$ROLE; keeping baked hostname"
	exit 0
fi

printf '%s' "$NAME" > /proc/sys/kernel/hostname
log "transient hostname set to $NAME (role=$ROLE)"
