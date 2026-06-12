#!/bin/sh
#
# rasputin-firstboot.sh — read the provisioning seed and stamp this node's
# identity. Idempotent: guarded by /var/lib/rasputin/.provisioned and a
# no-op on an already-provisioned persistent partition.
#
# Design: os-images/provisioning.md §1-§3. This is the cloud-init-NoCloud
# essence (one FAT env file) without the cloud-init dependency.
#
# Seed sources, in priority order:
#   1. /run/rasputin-seed/rasputin-seed.env   (mounted seed partition)
#   2. kernel cmdline rasputin.role=… rasputin.nats=… (override/escape hatch)
#   3. defaults (role=compute, id from SoC serial, nats from controlplane mDNS)
#
set -eu

# PERSIST is the mounted persistent partition (fstab: PARTLABEL=persistent,
# formatted on first use via x-systemd.makefs). The rootfs is read-only
# squashfs, so EVERYTHING this script writes must land under PERSIST.
# /etc/rasputin/node.env is a baked-in symlink to $NODE_ENV for operators.
PERSIST=/var/lib/rasputin
NODE_ENV=$PERSIST/node.env
SEED_MNT=/run/rasputin-seed
SEED_FILE="$SEED_MNT/rasputin-seed.env"

# Also log to /dev/kmsg: systemd stops mirroring unit output to the console
# once journald is up, but printk always reaches every console= device —
# so these lines show on serial/HDMI and the CI smoke can assert on them.
log() {
	echo "rasputin-firstboot: $*"
	echo "rasputin-firstboot: $*" > /dev/kmsg 2>/dev/null || true
}

# --- locate + read the seed --------------------------------------------------
# The seed FAT is mounted read-only at $SEED_MNT by run-rasputin\x2dseed.mount
# (Wants'd by rasputin-firstboot.service), matched by filesystem label
# RASPUTIN-FW — common to both boards even though the GPT partition name
# differs (n100 "esp", cm5 "firmware"). If the mount failed we fall through
# to the cmdline/defaults below.
ROLE=""
NODE_ID=""
NATS_URL=""
JOIN_TOKEN=""

if [ -f "$SEED_FILE" ]; then
	log "reading seed $SEED_FILE"
	# shellcheck disable=SC1090
	. "$SEED_FILE"
	ROLE="${RASPUTIN_NODE_ROLE:-}"
	NODE_ID="${RASPUTIN_NODE_ID:-}"
	NATS_URL="${RASPUTIN_NATS_URL:-}"
	JOIN_TOKEN="${RASPUTIN_CP_JOIN_TOKEN:-}"
else
	log "no seed file at $SEED_FILE; using defaults"
fi

# --- kernel cmdline override (escape hatch) ----------------------------------
for tok in $(cat /proc/cmdline); do
	case "$tok" in
		rasputin.role=*) ROLE="${tok#rasputin.role=}" ;;
		rasputin.id=*)   NODE_ID="${tok#rasputin.id=}" ;;
		rasputin.nats=*) NATS_URL="${tok#rasputin.nats=}" ;;
	esac
done

# --- defaults ----------------------------------------------------------------
ROLE="${ROLE:-compute}"

if [ -z "$NODE_ID" ]; then
	# Derive a stable id from the SoC serial. Pi: /proc/cpuinfo Serial;
	# x86: DMI board serial. Fall back to machine-id.
	SERIAL=$(awk '/^Serial/ {print $3; exit}' /proc/cpuinfo 2>/dev/null || true)
	if [ -z "$SERIAL" ] && [ -r /sys/class/dmi/id/board_serial ]; then
		SERIAL=$(cat /sys/class/dmi/id/board_serial 2>/dev/null || true)
	fi
	[ -z "$SERIAL" ] && SERIAL=$(cat /etc/machine-id 2>/dev/null | cut -c1-12)
	NODE_ID="node-$(echo "$SERIAL" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9' | tail -c 8)"
fi

# The first controlplane self-inits against its own embedded NATS and needs
# no upstream (it IS the authority). Others default to the controlplane's
# tailnet hostname — overridden by the seed in practice.
if [ -z "$NATS_URL" ]; then
	if [ "$ROLE" = "controlplane" ]; then
		NATS_URL="nats://127.0.0.1:4222"
	else
		NATS_URL="nats://cp-1.rasputin.tailnet:4222"
	fi
fi

# --- write node.env ----------------------------------------------------------
log "role=$ROLE id=$NODE_ID nats=$NATS_URL"
umask 077
cat > "$NODE_ENV" <<EOF
RASPUTIN_NODE_ROLE=$ROLE
RASPUTIN_NODE_ID=$NODE_ID
RASPUTIN_NATS_URL=$NATS_URL
EOF
# The controlplane needs to know its own id for the system.update self-skip
# and the BMC host default (see control-plane/updates.md, bmc.md).
if [ "$ROLE" = "controlplane" ]; then
	echo "RASPUTIN_SELF_NODE_ID=$NODE_ID" >> "$NODE_ENV"
fi

# --- tailnet enrollment (join token) -----------------------------------------
# TODO(scaffold): call `tailscale up --login-server=… --auth-key=$JOIN_TOKEN`
# (non-controlplane) once the agent/tailscale wiring is on the image. The
# controlplane generates its own enrollment locally on api first-start.
if [ -n "$JOIN_TOKEN" ] && [ "$ROLE" != "controlplane" ]; then
	log "tailnet join token present (enrollment TODO in scaffold)"
fi

# NOTE: the per-role hostname (controlplane answers rasputin.local via mDNS,
# everything else uses its node id) is NOT set here — firstboot runs once,
# but a transient hostname must be re-set every boot. That lives in
# rasputin-hostname.service / usr/lib/rasputin/hostname/rasputin-hostname.sh,
# which reads the node.env written above.

# --- role marker: gates rasputin-api.service ----------------------------------
# /etc is read-only squashfs, so runtime `systemctl enable` can't work (and
# ConditionEnvironment can't see node.env — it checks PID 1's environment).
# The api ships preset-enabled on every image and is gated by
# ConditionPathExists on this marker instead. provisioning.md §2.
if [ "$ROLE" = "controlplane" ]; then
	log "marking controlplane role (gates rasputin-api + sidecars)"
	touch "$PERSIST/role.controlplane"
	# TODO(scaffold): sidecar containers (Headscale, VictoriaMetrics, Loki,
	# Grafana) get the same marker gate once their compose units land.
else
	rm -f "$PERSIST/role.controlplane"
fi

# --- stamp provisioned + clear the seed token --------------------------------
date -u +%Y-%m-%dT%H:%M:%SZ > "$PERSIST/.provisioned"
log "provisioning complete"
