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
# and firstboot fails loud rather than inventing one. The node id is REQUIRED
# too (seed RASPUTIN_NODE_ID, or rasputin.id= on the cmdline): the join token is
# bound to it, so the node never derives one. Optional fields default: nats to
# the controlplane mDNS name (rasputin.local).
#
set -eu

# PERSIST is the mounted persistent partition (per-SoC fstab: PARTLABEL on the
# n100/GPT, PARTUUID on the rpi/MBR; formatted on first use via x-systemd.makefs).
# The rootfs is read-only
# squashfs, so EVERYTHING this script writes must land under PERSIST.
# /etc/rasputin/node.env is a baked-in symlink to $NODE_ENV for operators.
#
# The RASPUTIN_FIRSTBOOT_* overrides exist for test/firstboot-test.sh, which runs
# this script against a scratch directory; the unit sets none of them, so on a
# node every path is the real one below.
PERSIST="${RASPUTIN_FIRSTBOOT_PERSIST:-/var/lib/rasputin}"
NODE_ENV=$PERSIST/node.env
SEED_MNT="${RASPUTIN_FIRSTBOOT_SEED_MNT:-/run/rasputin-seed}"
SEED_FILE="$SEED_MNT/rasputin-seed.env"
LIBDIR="${RASPUTIN_FIRSTBOOT_LIBDIR:-/usr/lib/rasputin}"
CMDLINE="${RASPUTIN_FIRSTBOOT_CMDLINE:-/proc/cmdline}"
KMSG="${RASPUTIN_FIRSTBOOT_KMSG:-/dev/kmsg}"
# Indirected rather than stubbed on PATH: under the CI runner's (Ubuntu)
# busybox sh, a PATH stub named mount was bypassed for busybox's own applet.
MOUNT="${RASPUTIN_FIRSTBOOT_MOUNT:-mount}"

# Also log to /dev/kmsg: systemd stops mirroring unit output to the console
# once journald is up, but printk always reaches every console= device —
# so these lines show on serial/HDMI and the CI smoke can assert on them.
log() {
	echo "rasputin-firstboot: $*"
	echo "rasputin-firstboot: $*" > "$KMSG" 2>/dev/null || true
}

# DNS-label helpers shared with rasputin-hostname.sh (node id rules, below).
# shellcheck source=/dev/null
. "$LIBDIR/node-id/node-id.sh"

# --- bus TLS seed values (geekdojo/geekdojo-brain#448) -------------------------
# The contract is docs/bus-tls-contract.md in rasputin-control-plane:
#   RASPUTIN_BUS_PIN  every seed. "sha256/" + the standard padded base64 of the
#                     SHA-256 of the bus key's DER SubjectPublicKeyInfo. Public.
#   RASPUTIN_BUS_KEY  controlplane seed only. The bus private key as one line of
#                     standard base64 of its PKCS#8 DER. SECRET: never logged,
#                     never put in node.env, scrubbed from the seed once written.
# Both use only A-Z a-z 0-9 + / =, so they are written unquoted.

# bus_trim VALUE — print VALUE without surrounding whitespace (a CR from a seed
# saved on Windows included). The agent and the api trim exactly this much and
# nothing else, so an inner space or a stray quote is still refused below.
bus_trim() {
	_bt_ws=$(printf ' \t\n\r\v\f')
	_bt_v=$1
	_bt_v=${_bt_v#"${_bt_v%%[!$_bt_ws]*}"}
	_bt_v=${_bt_v%"${_bt_v##*[!$_bt_ws]}"}
	printf '%s' "$_bt_v"
}

# The base64 alphabet, spelled out: range expressions in shell patterns follow
# the locale's collation, which is not ASCII everywhere.
B64="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

# bus_b64_strict VALUE — exit 0 when VALUE is canonical standard base64, as Go's
# base64.StdEncoding.Strict() demands: whole quanta, "=" padding only at the
# end, and the unused low bits of the last data character zero (so one byte
# string has exactly one encoding, and a pin compares byte for byte).
bus_b64_strict() {
	_bs=$1
	[ -n "$_bs" ] && [ "$(( ${#_bs} % 4 ))" -eq 0 ] || return 1
	case "$_bs" in *[!"$B64"=]*) return 1 ;; esac
	case "$_bs" in
		*==) _bs_body=${_bs%==}; _bs_last="AQgw" ;;
		*=)  _bs_body=${_bs%=};  _bs_last="AEIMQUYcgkosw048" ;;
		*)   _bs_body=$_bs;      _bs_last="$B64" ;;
	esac
	case "$_bs_body" in *=*) return 1 ;; esac
	case "$_bs_body" in *[!"$_bs_last"]) return 1 ;; esac
	return 0
}

# bus_pin_valid PIN — exit 0 for exactly the form the agent accepts
# (proto.ParseBusPin): "sha256/" then 44 characters of strict base64, which is
# 32 bytes. Hex, URL-safe base64, a missing "=", "SHA256/" and curl's
# "sha256//" are all refused, as they are by the agent.
bus_pin_valid() {
	case "$1" in sha256/*) ;; *) return 1 ;; esac
	_bp=${1#sha256/}
	[ "${#_bp}" -eq 44 ] || return 1
	case "$_bp" in *=) ;; *) return 1 ;; esac
	case "$_bp" in *==) return 1 ;; esac
	bus_b64_strict "$_bp"
}

# bus_b64_val CHAR — print the 6-bit value of one base64 character.
bus_b64_val() {
	_bv=${B64%%"$1"*}
	printf '%s' "${#_bv}"
}

# bus_key_valid KEY — exit 0 when KEY is strict base64 whose decoded length is
# exactly the length its outer DER SEQUENCE header declares. firstboot has no
# openssl or base64 binary it can count on, so it cannot parse the key; this is
# the check that catches the realistic damage — a value truncated or joined in
# transit — before it is written and scrubbed. The api parses the key properly
# at start; one that passes here and still fails there leaves the bus
# plaintext-only, logged, and the api never replaces the file.
bus_key_valid() {
	bus_b64_strict "$1" || return 1
	[ "${#1}" -ge 8 ] || return 1
	# Decode the first two quanta (6 bytes) — enough for any header up to
	# 30 82 HH LL — into two 24-bit numbers.
	_bk_rest=$1
	_bk_n1=0
	_bk_n2=0
	for _bk_i in 1 2 3 4 5 6 7 8; do
		_bk_c=${_bk_rest%"${_bk_rest#?}"}
		_bk_rest=${_bk_rest#?}
		[ "$_bk_c" = "=" ] && return 1
		_bk_v=$(bus_b64_val "$_bk_c")
		if [ "$_bk_i" -le 4 ]; then
			_bk_n1=$(( (_bk_n1 << 6) | _bk_v ))
		else
			_bk_n2=$(( (_bk_n2 << 6) | _bk_v ))
		fi
	done
	_bk_tag=$(( (_bk_n1 >> 16) & 255 ))
	_bk_len=$(( (_bk_n1 >> 8) & 255 ))
	_bk_b2=$(( _bk_n1 & 255 ))
	_bk_b3=$(( (_bk_n2 >> 16) & 255 ))
	[ "$_bk_tag" -eq 48 ] || return 1                 # 0x30: SEQUENCE
	if [ "$_bk_len" -lt 128 ]; then _bk_total=$(( 2 + _bk_len ))
	elif [ "$_bk_len" -eq 129 ]; then _bk_total=$(( 3 + _bk_b2 ))
	elif [ "$_bk_len" -eq 130 ]; then _bk_total=$(( 4 + (_bk_b2 << 8) + _bk_b3 ))
	else return 1
	fi
	_bk_pad=0
	case "$1" in *==) _bk_pad=2 ;; *=) _bk_pad=1 ;; esac
	[ "$(( ${#1} / 4 * 3 - _bk_pad ))" -eq "$_bk_total" ]
}

# --- locate + read the seed --------------------------------------------------
# The seed FAT is mounted read-only at $SEED_MNT by run-rasputin\x2dseed.mount
# (Wants'd by rasputin-firstboot.service), matched by filesystem label
# RASPUTIN-OS — common to both boards even though the GPT partition name
# differs (n100 "esp", cm5 "firmware"). If the mount failed we fall through
# to the cmdline/defaults below.
ROLE=""
NODE_ID=""
# Where the node id came from, for the error message if it is not a valid DNS
# label. Empty = no node id was supplied, which fails provisioning below.
NODE_ID_FROM=""
# The cluster's name. ADR-0003 makes this the source of the node's identity —
# mDNS hostname, NATS URL, Headscale server_url, leaf SANs, WebAuthn RP ID —
# and defaults it to "rasputin" so every installation that predates the change
# is grandfathered untouched. Pre-set here (not just inside the seed branch)
# because this script runs under `set -eu`: a node booting with NO seed must
# still have a value, and that path is the bootstrap case.
CLUSTER_ID="rasputin"
NATS_URL=""
JOIN_TOKEN=""
BUS_AUTH=""
RELEASE_CHANNEL=""
SSH_KEY=""
NTP_SERVER=""
BMC_HOST=""
# Two variables, because "set but empty" is meaningful here: it is how an
# operator turns the controlplane fallback address OFF, as distinct from never
# having mentioned it (which takes the built-in default). See
# usr/lib/rasputin/netfallback/.
FALLBACK_ADDRESS=""
FALLBACK_ADDRESS_SET=""
BUS_PIN=""
BUS_KEY=""

if [ -f "$SEED_FILE" ]; then
	log "reading seed $SEED_FILE"
	# shellcheck disable=SC1090
	. "$SEED_FILE"
	ROLE="${RASPUTIN_NODE_ROLE:-}"
	NODE_ID="${RASPUTIN_NODE_ID:-}"
	[ -n "$NODE_ID" ] && NODE_ID_FROM="RASPUTIN_NODE_ID in $SEED_FILE"
	CLUSTER_ID="${RASPUTIN_CLUSTER_ID:-rasputin}"
	NATS_URL="${RASPUTIN_NATS_URL:-}"
	JOIN_TOKEN="${RASPUTIN_CP_JOIN_TOKEN:-}"
	BUS_AUTH="${RASPUTIN_BUS_AUTH:-}"
	RELEASE_CHANNEL="${RASPUTIN_RELEASE_CHANNEL:-}"
	SSH_KEY="${RASPUTIN_SSH_AUTHORIZED_KEY:-}"
	NTP_SERVER="${RASPUTIN_NTP_SERVER:-}"
	BMC_HOST="${RASPUTIN_BMC_HOST:-}"
	BUS_PIN="${RASPUTIN_BUS_PIN:-}"
	BUS_KEY="${RASPUTIN_BUS_KEY:-}"
	if [ -n "${RASPUTIN_FALLBACK_ADDRESS+set}" ]; then
		FALLBACK_ADDRESS_SET=1
		FALLBACK_ADDRESS="$RASPUTIN_FALLBACK_ADDRESS"
	fi
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
	if printf '%s\n' "$SSH_KEY" | "$LIBDIR/dropbear/merge-authorized-keys.sh"; then
		log "merged seed SSH authorized key into /var/lib/rasputin/dropbear/authorized_keys"
	else
		log "WARNING: failed to merge seed SSH authorized key (continuing)"
	fi
fi

# --- kernel cmdline override (escape hatch) ----------------------------------
for tok in $(cat "$CMDLINE"); do
	case "$tok" in
		rasputin.role=*) ROLE="${tok#rasputin.role=}" ;;
		rasputin.id=*)   NODE_ID="${tok#rasputin.id=}"; NODE_ID_FROM="rasputin.id= on the kernel command line" ;;
		rasputin.nats=*) NATS_URL="${tok#rasputin.nats=}" ;;
	esac
done

# Lowercase + trim an operator-supplied id, exactly as rasputin-provision does;
# a value that is only whitespace (or a bare CR from a Windows-saved seed)
# counts as blank. Validity is checked below, with the other fail-loud checks.
NODE_ID_RAW=$NODE_ID
NODE_ID=$(rasputin_label_canon "$NODE_ID")
[ -n "$NODE_ID" ] || NODE_ID_FROM=""

# --- require a real provisioning signal --------------------------------------
# ROLE must come from the seed or the kernel cmdline. A blank/absent role means
# the node was never provisioned — the seed template ships every field empty.
# Do NOT invent an identity and half-join: that strands the node as a zombie
# that never reaches the bus — it looks "up" but never appears in inventory. Found 2026-06-22 on the bench, when
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

# Every seed must NAME the node; nothing derives an id on the node any more.
# Every real provisioning path (rasputin-provision, the Add-node wizard) always
# writes RASPUTIN_NODE_ID, so a seed without one is a hand-written/botched seed.
#   - Any node with a join token: the token is bound to a node id, and the bus
#     refuses a token presented under any other id (an unbound token no longer
#     exists — rasputin-control-plane #318, geekdojo/geekdojo-brain#423). An id
#     derived here from the SoC/DMI serial could never match, so the node would
#     boot "up" and never join. Every non-controlplane role carries a token
#     (checked above), so this covers them all.
#   - The controlplane: its id is the cluster's identity anchor — its mesh
#     hostname, the setup wizard's self-enroll target, its inventory row (bit
#     rasputin-local 2026-07-12: a leftover OTA-test hand-seed left the CP named
#     node-9bbaa24a — and, unnoticed alongside it, unenforced).
# Fail loud like the role/token checks above, before anything is written or
# stamped, so firstboot re-runs once the seed is fixed and the node rebooted.
if [ -z "$NODE_ID" ]; then
	if [ "$ROLE" = "controlplane" ]; then
		log "ERROR: role=controlplane seed carries no RASPUTIN_NODE_ID — the controlplane must be named."
	else
		log "ERROR: role=$ROLE seed carries a join token but no RASPUTIN_NODE_ID — the token is bound to a node id, so this node cannot join without it."
	fi
	log "Re-generate the seed (rasputin-provision / Add node) or add RASPUTIN_NODE_ID, then reboot."
	exit 1
fi

# The node id must be a DNS label: it becomes this node's mDNS
# hostname and the username the agent presents to the bus, which accepts
# nothing else. It is deliberately NOT rewritten into a valid one — the join
# token is bound to the id the operator chose, so a substituted id could never
# join and would hide why. Fail loud like the checks above: the unit shows
# failed, rasputin-agent (Requires= this unit) does not start, and .provisioned
# stays unset so firstboot re-runs after the seed is fixed and the node rebooted.
if ! rasputin_label_valid "$NODE_ID"; then
	log "ERROR: node id '$NODE_ID_RAW' ($NODE_ID_FROM) is not a valid node id."
	log "A node id must be 1-63 characters of a-z, 0-9 and -, and must not start or end with -."
	log "Fix it to match the id the join token was issued for (or re-generate the seed with rasputin-provision / Add node), then reboot."
	exit 1
fi

# --- bus TLS values must be exactly right, or nothing is written ---------------
# Checked with the other fail-loud checks, BEFORE anything reaches node.env or
# the bus directory, and before the BMC reboot below. Both failures would
# otherwise be stamped in: .provisioned stops firstboot re-running, so a bad
# pin could no longer be fixed by editing the seed, and a bad key would be
# written and then scrubbed from the seed. A bad key is the worse of the two —
# the api would run the bus plaintext-only and refuse to replace the file, and
# every node in the matched set pins the key the seed was meant to carry.
# The key's value is never logged.
BUS_PIN=$(bus_trim "$BUS_PIN")
if [ -n "$BUS_PIN" ] && ! bus_pin_valid "$BUS_PIN"; then
	log "ERROR: RASPUTIN_BUS_PIN '$BUS_PIN' is not a valid bus pin."
	log "It must be sha256/ followed by 44 characters of standard base64 (51 characters in all), exactly as rasputin-provision / Add node wrote it."
	log "Fix it (or remove the line to join without TLS until the controlplane delivers the pin), then reboot."
	exit 1
fi
BUS_KEY_IN_SEED=""
[ -n "$BUS_KEY" ] && BUS_KEY_IN_SEED=1
BUS_KEY=$(bus_trim "$BUS_KEY")
if [ "$ROLE" = "controlplane" ] && [ -n "$BUS_KEY_IN_SEED" ] && ! bus_key_valid "$BUS_KEY"; then
	log "ERROR: RASPUTIN_BUS_KEY in the seed is not a usable bus key (value not shown: it is secret)."
	log "It must be the one-line base64 PKCS#8 key rasputin-provision wrote, complete and unwrapped. Nothing was written."
	log "Copy the controlplane seed from the matched set again, then reboot."
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
	"$LIBDIR/bmc/strip-serial-console.sh"
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
RASPUTIN_CLUSTER_ID=$CLUSTER_ID
RASPUTIN_NATS_URL=$NATS_URL
EOF
# The bus pin — ALL roles, the controlplane included: its own agent dials
# 127.0.0.1 and pins the key too. Public, so it stays in the seed. Validated
# above, so its alphabet is A-Z a-z 0-9 + / = and it needs no quoting. No pin
# line means the agent dials in plaintext until the controlplane delivers one
# into its state dir (/var/lib/rasputin/agent-state/bus/pin, persistent).
if [ -n "$BUS_PIN" ]; then
	echo "RASPUTIN_BUS_PIN=$BUS_PIN" >> "$NODE_ENV"
fi
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
# Optional controlplane fallback address (CIDR) for a LAN with no DHCP server.
# Written whenever the seed MENTIONED the key, empty value included -- an empty
# value is the operator's explicit "do not take a fallback address", and
# dropping the line would silently restore the default instead.
# rasputin-fallback-address.service reads it; on a compute node the key is inert
# (that unit is controlplane-gated). An older cluster that never gets this key
# simply keeps the built-in default, so there is nothing to strand (#84).
if [ -n "$FALLBACK_ADDRESS_SET" ]; then
	FALLBACK_ADDRESS=$(printf '%s' "$FALLBACK_ADDRESS" | tr -cd '0-9./')
	echo "RASPUTIN_FALLBACK_ADDRESS=$FALLBACK_ADDRESS" >> "$NODE_ENV"
fi
# The controlplane needs to know its own id for the system.update self-skip
# and the BMC host default (see control-plane/updates.md, bmc.md).
if [ "$ROLE" = "controlplane" ]; then
	echo "RASPUTIN_SELF_NODE_ID=$NODE_ID" >> "$NODE_ENV"
	# A provisioned matched set ships enforce on (bus auth required), carried in
	# the seed so a pre-paired cluster comes up enforced with no manual flip.
	# Absent → the api's default (enforce). Only the controlplane's api reads this.
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
	# The bus key from a matched set (geekdojo/geekdojo-brain#448). Written
	# verbatim, one line, to the file the api serves TLS on :4222 with
	# (<RASPUTIN_DATA_DIR>/bus/bus.key). Never into node.env: the api does not
	# read it from the environment, and node.env is sourced by other units.
	#
	# NEVER over an existing bus.key: every node pins that key, and replacing it
	# strands the fleet. `ln` refuses to replace an existing name, so the check
	# and the write are one atomic step. A write that fails for any other
	# reason fails provisioning — carrying on would let the api generate a
	# different key than the one this matched set's nodes pin.
	if [ -n "$BUS_KEY" ]; then
		BUS_DIR="$PERSIST/bus"
		BUS_KEY_FILE="$BUS_DIR/bus.key"
		if ! { mkdir -p "$BUS_DIR" && chmod 700 "$BUS_DIR"; }; then
			log "ERROR: could not create $BUS_DIR for the bus key — provisioning stopped so the api does not generate a key the nodes do not pin."
			exit 1
		fi
		if [ -e "$BUS_KEY_FILE" ] || [ -L "$BUS_KEY_FILE" ]; then
			if [ "$(bus_trim "$(cat "$BUS_KEY_FILE" 2>/dev/null || true)")" = "$BUS_KEY" ]; then
				log "bus key already in place at $BUS_KEY_FILE (same key as the seed)"
			else
				log "WARNING: $BUS_KEY_FILE already exists and differs from the seed's RASPUTIN_BUS_KEY; keeping the existing key (nodes pin it). The seed's key was NOT written."
			fi
		else
			bus_tmp="$BUS_DIR/.bus.key.$$"
			rm -f "$bus_tmp"
			if (umask 077 && printf '%s\n' "$BUS_KEY" > "$bus_tmp") \
				&& chmod 600 "$bus_tmp" \
				&& ln "$bus_tmp" "$BUS_KEY_FILE" 2>/dev/null; then
				rm -f "$bus_tmp"
				# Flush before .provisioned is stamped and the seed scrubbed: a
				# power cut that left an empty bus.key would be a file the api
				# refuses to use and never replaces.
				sync
				log "wrote the bus key from the seed to $BUS_KEY_FILE"
			else
				rm -f "$bus_tmp"
				log "ERROR: could not write the bus key to $BUS_KEY_FILE — provisioning stopped so the api does not generate a key the nodes do not pin."
				exit 1
			fi
		fi
	elif [ -n "$BUS_PIN" ] && [ ! -e "$PERSIST/bus/bus.key" ]; then
		# Legitimate on a controlplane that will be restored from an identity
		# backup (which puts bus/bus.key back); otherwise the api generates a
		# key whose pin is not this one, and nothing pinned can join.
		log "WARNING: controlplane seed carries RASPUTIN_BUS_PIN but no RASPUTIN_BUS_KEY, and there is no bus key yet; unless an identity backup is restored, the api will generate a key this pin does not match."
	fi
else
	rm -f "$PERSIST/role.controlplane"
	# The bus private key belongs in the controlplane seed only. On any other
	# role it is a seed rendered wrong: never written, and scrubbed below like
	# a consumed secret — the fleet's key must not sit on this node's FAT. Not a
	# provisioning failure: this node needs nothing from the key.
	if [ -n "$BUS_KEY_IN_SEED" ]; then
		log "WARNING: role=$ROLE seed carries RASPUTIN_BUS_KEY, which belongs only in the controlplane seed; ignored and scrubbed. Treat that key as exposed."
	fi
fi

# --- stamp provisioned -------------------------------------------------------
date -u +%Y-%m-%dT%H:%M:%SZ > "$PERSIST/.provisioned"

# Scrub the consumed secrets — the one-time join token and the bus private key —
# from the seed FAT so they aren't left in plaintext at rest. Best-effort, and
# only on this successful path: we've already stamped .provisioned (firstboot
# won't re-run and re-need them), the token now lives in node.env on the
# root-only persistent partition for the agent, and the key in bus/bus.key. A
# read-only/degraded seed mount just leaves them — the token is node-bound +
# single-use. Never let a scrub hiccup fail an otherwise-successful provision.
# The bus pin is public and stays.
if { [ -n "$JOIN_TOKEN" ] || [ -n "$BUS_KEY_IN_SEED" ]; } && [ -f "$SEED_FILE" ] && "$MOUNT" -o remount,rw "$SEED_MNT" 2>/dev/null; then
	scrub="$PERSIST/.seed-scrub.$$"
	if sed -e 's#^RASPUTIN_CP_JOIN_TOKEN=.*#RASPUTIN_CP_JOIN_TOKEN=#' \
		-e 's#^RASPUTIN_BUS_KEY=.*#RASPUTIN_BUS_KEY=#' "$SEED_FILE" > "$scrub" 2>/dev/null; then
		cat "$scrub" > "$SEED_FILE" 2>/dev/null && sync && log "scrubbed consumed secrets (join token, bus key) from seed FAT" || true
	fi
	rm -f "$scrub"
	"$MOUNT" -o remount,ro "$SEED_MNT" 2>/dev/null || true
fi

log "provisioning complete"
