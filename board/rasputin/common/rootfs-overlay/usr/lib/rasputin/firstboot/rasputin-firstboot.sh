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
# ROLE is REQUIRED (from 1 or 2) — a blank/absent role is an un-provisioned node
# and firstboot fails loud rather than inventing one. Optional fields default:
# id from the SoC/DMI serial, nats to the controlplane mDNS name (rasputin.local).
#
set -eu

# PERSIST is the mounted persistent partition (per-SoC fstab: PARTLABEL on the
# n100/GPT, PARTUUID on the rpi/MBR; formatted on first use via x-systemd.makefs).
# The rootfs is read-only
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
# RASPUTIN-OS — common to both boards even though the GPT partition name
# differs (n100 "esp", cm5 "firmware"). If the mount failed we fall through
# to the cmdline/defaults below.
ROLE=""
NODE_ID=""
NATS_URL=""
JOIN_TOKEN=""
BUS_AUTH=""
RELEASE_CHANNEL=""
SSH_KEY=""
NTP_SERVER=""
BMC_HOST=""

if [ -f "$SEED_FILE" ]; then
	log "reading seed $SEED_FILE"
	# shellcheck disable=SC1090
	. "$SEED_FILE"
	ROLE="${RASPUTIN_NODE_ROLE:-}"
	NODE_ID="${RASPUTIN_NODE_ID:-}"
	NATS_URL="${RASPUTIN_NATS_URL:-}"
	JOIN_TOKEN="${RASPUTIN_CP_JOIN_TOKEN:-}"
	BUS_AUTH="${RASPUTIN_BUS_AUTH:-}"
	RELEASE_CHANNEL="${RASPUTIN_RELEASE_CHANNEL:-}"
	SSH_KEY="${RASPUTIN_SSH_AUTHORIZED_KEY:-}"
	NTP_SERVER="${RASPUTIN_NTP_SERVER:-}"
	BMC_HOST="${RASPUTIN_BMC_HOST:-}"
else
	log "no seed file at $SEED_FILE; using defaults"
fi

# --- seed-supplied SSH authorized key -----------------------------------------
# Merge the operator's public key into the persistent authorized_keys — the
# file dropbear reads (-D, see dropbear.service). Done BEFORE the fail-loud
# provisioning checks below: a mis-provisioned seed that at least carries a
# key still gives the operator SSH access to debug it. Public key, not a
# secret — no scrub, and never let a merge hiccup fail provisioning.
if [ -n "$SSH_KEY" ]; then
	if printf '%s\n' "$SSH_KEY" | /usr/lib/rasputin/dropbear/merge-authorized-keys.sh; then
		log "merged seed SSH authorized key into /var/lib/rasputin/dropbear/authorized_keys"
	else
		log "WARNING: failed to merge seed SSH authorized key (continuing)"
	fi
fi

# --- kernel cmdline override (escape hatch) ----------------------------------
for tok in $(cat /proc/cmdline); do
	case "$tok" in
		rasputin.role=*) ROLE="${tok#rasputin.role=}" ;;
		rasputin.id=*)   NODE_ID="${tok#rasputin.id=}" ;;
		rasputin.nats=*) NATS_URL="${tok#rasputin.nats=}" ;;
	esac
done

# --- require a real provisioning signal --------------------------------------
# ROLE must come from the seed or the kernel cmdline. A blank/absent role means
# the node was never provisioned — the seed template ships every field empty and
# documents "firstboot waits until these are set". Do NOT invent an identity and
# half-join: that strands the node as a zombie that never reaches the bus — it
# looks "up" but never appears in inventory. Found 2026-06-22 on the bench, when
# a seed write silently failed to land on the ESP: the node booted the blank
# template and defaulted to compute + node-<dmi> + an unresolvable NATS fallback,
# with no error anywhere. Fail loud instead — exit non-zero so this unit shows
# failed (rasputin-agent Requires= us, so it won't start on a junk identity), and
# leave .provisioned unset so firstboot re-runs once a real seed is dropped on
# the RASPUTIN-OS partition and the node is rebooted.
if [ -z "$ROLE" ]; then
	log "ERROR: no provisioning seed — this node is un-provisioned."
	log "Drop a rasputin-seed.env (control plane -> Add node) on the RASPUTIN-OS partition and reboot."
	exit 1
fi

# Non-controlplane nodes enroll with a one-time join token minted by the control
# plane and bound to their node id; without it they cannot pass the bus auth
# callout. A provisioned compute/storage seed always carries one, so an empty
# token here is a botched/partial seed — fail loud rather than half-join. The
# controlplane is loopback-trusted and carries no token (handled below).
if [ "$ROLE" != "controlplane" ] && [ -z "$JOIN_TOKEN" ]; then
	log "ERROR: role=$ROLE seed carries no join token (RASPUTIN_CP_JOIN_TOKEN) — cannot enroll."
	log "Re-generate the enrollment file from the control plane (Add node) and re-seed."
	exit 1
fi

# A controlplane seed must NAME the node. The serial fallback below is fine for
# a compute/storage node (zero-touch adds), but the controlplane's id is the
# cluster's identity anchor — its mesh hostname, the setup wizard's self-enroll
# target, its inventory row — and every real provisioning path
# (rasputin-provision, the Add-node wizard) always writes RASPUTIN_NODE_ID, so a
# controlplane seed without one is by construction a hand-written/botched seed.
# Fail loud like the role/token checks above rather than silently minting
# node-<serial> (bit rasputin-local 2026-07-12: a leftover OTA-test hand-seed
# left the CP named node-9bbaa24a — and, unnoticed alongside it, unenforced).
if [ "$ROLE" = "controlplane" ] && [ -z "$NODE_ID" ]; then
	log "ERROR: role=controlplane seed carries no RASPUTIN_NODE_ID — the controlplane must be named."
	log "Re-generate the seed (rasputin-provision / Add node) or add RASPUTIN_NODE_ID, then reboot."
	exit 1
fi

# --- BMC-host serial-console policy (control-plane/bmc-bitscope.md §5) -------
# On the node whose serial0 drives a BMC bus, that UART is the command
# channel: no login getty (the baked serial-getty drop-in conditions on the
# marker below) and no kernel serial console (stripped from both boot slots'
# cmdline — printk onto an UNLOCKED bus is live power-command traffic). The
# cmdline edit only takes effect on the next boot, so when it changes
# anything we reboot ONCE, deliberately BEFORE .provisioned is stamped and
# before the join token is consumed: this whole script re-runs cleanly on
# the way back up and completes provisioning with the console already gone.
# Runs before node.env so the danger window never overlaps an agent start
# (rasputin-agent Requires= this unit).
if [ "$BMC_HOST" = "1" ]; then
	log "bmc-host node: suppressing serial console on serial0"
	touch "$PERSIST/bmc-host"
	/usr/lib/rasputin/bmc/strip-serial-console.sh
	case $? in
	10)
		# Exit NON-zero on purpose: rasputin-agent Requires= this unit, and
		# a zero exit would let it start in the seconds before the queued
		# reboot lands. The "failed" status is transient and self-heals on
		# the way back up (same fail-loud contract as the seed checks).
		log "kernel serial console stripped from boot slots; rebooting once to apply"
		sync
		systemctl reboot
		exit 1
		;;
	0) ;;
	*)
		log "WARNING: strip-serial-console failed (continuing; getty is still suppressed by the marker)"
		;;
	esac
else
	rm -f "$PERSIST/bmc-host"
fi

# --- defaults for the remaining (optional) fields ----------------------------
if [ -z "$NODE_ID" ]; then
	# Derive a stable id from the SoC serial. Pi: /proc/cpuinfo Serial;
	# x86: DMI board serial.
	SERIAL=$(awk '/^Serial/ {print $3; exit}' /proc/cpuinfo 2>/dev/null || true)
	if [ -z "$SERIAL" ] && [ -r /sys/class/dmi/id/board_serial ]; then
		SERIAL=$(cat /sys/class/dmi/id/board_serial 2>/dev/null || true)
	fi
	SERIAL=$(echo "$SERIAL" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')
	# Reject BIOS placeholder serials (unprogrammed on many mini-PCs) — they are
	# NON-UNIQUE, so two such boards would collide on one node-id (the CWWK n100's
	# board_serial "Default string" sanitizes to "defaultstring" -> "ltstring").
	case "$SERIAL" in
		defaultstring|tobefilledbyoem|none|na|null|unknown|serialnumber|systemserialnumber|oem|0|00000000|123456789) SERIAL="" ;;
	esac
	[ "${#SERIAL}" -lt 6 ] && SERIAL=""   # too short => not enough entropy to trust
	if [ -n "$SERIAL" ]; then
		NODE_ID="node-$(printf '%s' "$SERIAL" | tail -c 8)"
	else
		# No usable hardware serial: mint a RANDOM id, persisted so it is stable
		# across reboots/OTA (a node's id must not change once enrolled). A reflash
		# wipes $PERSIST and re-mints — correctly a new node. See #9.
		IDFILE=$PERSIST/node-id.rand
		if [ -r "$IDFILE" ]; then
			NODE_ID=$(cat "$IDFILE")
		else
			NODE_ID="node-$(tr -d '-' < /proc/sys/kernel/random/uuid | cut -c1-8)"
			(umask 077; printf '%s\n' "$NODE_ID" > "$IDFILE") 2>/dev/null || true
		fi
	fi
fi

# NATS URL fallback. A provisioned seed sets this explicitly; the fallback only
# matters for a self-initing controlplane or a partial seed. The controlplane
# dials its own embedded broker; every other node defaults to the control
# plane's mDNS name on the LAN — rasputin.local, IPv4-only (locked decision #9),
# matching the control plane UI's enrollment default. NOT a hardcoded tailnet
# hostname: that was unresolvable on a plain LAN and silently stranded a
# mis-seeded node (2026-06-22).
if [ -z "$NATS_URL" ]; then
	if [ "$ROLE" = "controlplane" ]; then
		NATS_URL="nats://127.0.0.1:4222"
	else
		NATS_URL="nats://rasputin.local:4222"
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
# Optional operator NTP server(s) — ALL roles: every node needs correct time to
# mint/verify its mesh + API TLS (a no-RTC node with a bogus clock mints an
# "expired" leaf). rasputin-timesync-apply.service renders this into a
# timesyncd drop-in each boot; the image's numeric FallbackNTP is the safety
# net when it's unset. provisioning.md "Time sync".
if [ -n "$NTP_SERVER" ]; then
	# node.env is SOURCED by sh (rasputin-hostname + rasputin-timesync-apply),
	# so a space-separated value MUST be written double-quoted or the 2nd word
	# executes as a command (same trap as the SSH key). Sanitize to host/IP/
	# space chars first so the quoting can't be broken out of.
	NTP_SERVER=$(printf '%s' "$NTP_SERVER" | tr -d '\n' | tr -cd 'A-Za-z0-9 .:_-')
	[ -n "$NTP_SERVER" ] && echo "RASPUTIN_NTP_SERVER=\"$NTP_SERVER\"" >> "$NODE_ENV"
fi
# The controlplane needs to know its own id for the system.update self-skip
# and the BMC host default (see control-plane/updates.md, bmc.md).
if [ "$ROLE" = "controlplane" ]; then
	echo "RASPUTIN_SELF_NODE_ID=$NODE_ID" >> "$NODE_ENV"
	# A provisioned matched set ships enforce on (bus auth required), carried in
	# the seed so a pre-paired cluster comes up enforced with no manual flip.
	# Absent → the api's default (off). Only the controlplane's api reads this.
	# token-provisioning-pipeline.md §4.
	if [ -n "$BUS_AUTH" ]; then
		echo "RASPUTIN_BUS_AUTH=$BUS_AUTH" >> "$NODE_ENV"
	fi
	# Update channel (stable|dev) the api's Check-for-Updates tracks.
	# provision-cluster writes this into the controlplane seed when flashing a
	# dev/pre-release image; absent → the api's default (stable). Only the
	# controlplane runs the api, so it's controlplane-only like BUS_AUTH.
	if [ -n "$RELEASE_CHANNEL" ]; then
		echo "RASPUTIN_RELEASE_CHANNEL=$RELEASE_CHANNEL" >> "$NODE_ENV"
	fi
fi
# Non-controlplane nodes present the join token to the bus auth callout: the
# agent sends NATS username=node-id, password=token, and the controlplane
# validates it (token-provisioning-pipeline.md). The controlplane's own
# co-located agent is loopback-trusted and carries no token.
if [ -n "$JOIN_TOKEN" ] && [ "$ROLE" != "controlplane" ]; then
	echo "RASPUTIN_CP_JOIN_TOKEN=$JOIN_TOKEN" >> "$NODE_ENV"
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
	# Copy the provisioning bus-token preseed (sha256 hashes + node bindings —
	# NO plaintext) from the seed FAT onto the persistent partition, where the
	# api preloads it so a pre-paired cluster's nodes are accepted on first boot
	# with enforcement on (token-provisioning-pipeline.md §4c). Absent on a
	# self-provisioned/un-paired controlplane — that's fine.
	if [ -f "$SEED_MNT/rasputin-bus-tokens.json" ]; then
		mkdir -p "$PERSIST/bus"
		cp "$SEED_MNT/rasputin-bus-tokens.json" "$PERSIST/bus/preseed.json"
		log "staged bus-token preseed for the api to preload"
	fi
else
	rm -f "$PERSIST/role.controlplane"
fi

# --- stamp provisioned -------------------------------------------------------
date -u +%Y-%m-%dT%H:%M:%SZ > "$PERSIST/.provisioned"

# Scrub the consumed one-time join token from the seed FAT so it isn't left in
# plaintext at rest. Best-effort, and only on this successful path: we've already
# stamped .provisioned (firstboot won't re-run and re-need it) and the token now
# lives in node.env on the root-only persistent partition for the agent. A
# read-only/degraded seed mount just leaves it — the token is node-bound +
# single-use. Never let a scrub hiccup fail an otherwise-successful provision.
if [ -n "$JOIN_TOKEN" ] && [ -f "$SEED_FILE" ] && mount -o remount,rw "$SEED_MNT" 2>/dev/null; then
	scrub="$PERSIST/.seed-scrub.$$"
	if sed 's#^RASPUTIN_CP_JOIN_TOKEN=.*#RASPUTIN_CP_JOIN_TOKEN=#' "$SEED_FILE" > "$scrub" 2>/dev/null; then
		cat "$scrub" > "$SEED_FILE" 2>/dev/null && sync && log "scrubbed consumed join token from seed FAT" || true
	fi
	rm -f "$scrub"
	mount -o remount,ro "$SEED_MNT" 2>/dev/null || true
fi

log "provisioning complete"
