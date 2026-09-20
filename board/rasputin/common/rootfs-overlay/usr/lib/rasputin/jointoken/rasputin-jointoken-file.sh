#!/bin/sh
#
# rasputin-jointoken-file.sh — move a node's bus join token out of node.env
# and into its own 0600 file (geekdojo/geekdojo-brain#537, auth methodology
# §5.2 "node->CP client auth, NATS" and §7 4.1).
#
# WHY. The join token is the credential a node presents to the bus auth
# callout. Until this change it was written into /var/lib/rasputin/node.env as
# RASPUTIN_CP_JOIN_TOKEN, which made it an ENVIRONMENT VALUE: systemd hands
# node.env to rasputin-agent, every child process the agent spawns inherits it,
# and it is readable through /proc to anything running as the same user. The
# canonical form is one file the owner alone can read, named by
# RASPUTIN_CP_JOIN_TOKEN_FILE — which the agent re-reads on EVERY connect
# attempt, so a token that is rotated or re-minted on disk reaches a running
# agent on its next reconnect rather than its next restart. An environment
# variable cannot change under a running process; that is the other half of
# why this is a file.
#
# WHY EVERY BOOT, AND NOT IN FIRSTBOOT. firstboot is run-once (guarded by
# .provisioned) and writes the new form itself. But an OS update swaps the
# rootfs and KEEPS the persistent partition, so an already-provisioned node
# keeps the node.env it was provisioned with and firstboot never runs again —
# which is exactly the node this migration exists for. Same shape, and the
# same unit ordering, as rasputin-clusterid-backfill.sh.
#
# IDEMPOTENT. A node with no inline token (already migrated, or a controlplane,
# whose api mints its agent's token into bus/agent.token) is a no-op. A dev box
# has no node.env and the unit is condition-skipped.
#
# FAIL-SAFE ORDER. node.env is rewritten only after the token file is in place
# and reads back non-empty. Any failure before that leaves node.env exactly as
# it was, so the node keeps the credential it has and the next boot retries:
# a node is never left with neither form.
set -eu

PERSIST="${RASPUTIN_JOINTOKEN_PERSIST:-/var/lib/rasputin}"
NODE_ENV="$PERSIST/node.env"
# The default destination when node.env does not already name one. Beside
# bus.key and the controlplane's agent.token, on the persistent partition.
DEFAULT_FILE="$PERSIST/bus/join.token"
KMSG="${RASPUTIN_JOINTOKEN_KMSG:-/dev/kmsg}"

# Log to stdout (the journal) and to /dev/kmsg, as firstboot does: printk
# always reaches every console= device, so a boot-time decision is visible on
# serial/HDMI even after journald stops mirroring unit output.
log() {
	echo "rasputin-jointoken-file: $*"
	echo "rasputin-jointoken-file: $*" > "$KMSG" 2>/dev/null || true
}

# The unit already gates on this file existing; re-check so the script is safe
# to run by hand.
[ -f "$NODE_ENV" ] || exit 0

# The FIRST inline token line wins, and everything after the first "=" is the
# value — the token alphabet (A-Z a-z 0-9 + / =) means a token can itself end
# in "=" padding. "^RASPUTIN_CP_JOIN_TOKEN=" cannot match the _FILE key,
# because the "=" follows the name immediately.
TOKEN=$(sed -n 's/^RASPUTIN_CP_JOIN_TOKEN=//p' "$NODE_ENV" | head -n 1)
if [ -z "$TOKEN" ]; then
	# No inline token: already migrated, or a controlplane (its seed carries
	# none — the api mints its agent's token into bus/agent.token), or an
	# unprovisioned node. Nothing to do, including no line to delete: a blank
	# RASPUTIN_CP_JOIN_TOKEN= line is not a credential.
	exit 0
fi

# Where the token should live. An existing RASPUTIN_CP_JOIN_TOKEN_FILE line is
# authoritative — firstboot wrote it, and on a controlplane it names the file
# the api owns, which this script must not invent a value for.
TOKEN_FILE=$(sed -n 's/^RASPUTIN_CP_JOIN_TOKEN_FILE=//p' "$NODE_ENV" | head -n 1)
[ -n "$TOKEN_FILE" ] || TOKEN_FILE="$DEFAULT_FILE"

if [ -s "$TOKEN_FILE" ]; then
	# A file is already there and is not empty. It wins: the agent prefers it,
	# whatever wrote it wrote it later than the seed did, and on a controlplane
	# the api re-mints it. Do not overwrite it with the inline value.
	log "$TOKEN_FILE already holds a token; keeping it and dropping the inline RASPUTIN_CP_JOIN_TOKEN"
else
	TOKEN_DIR=$(dirname "$TOKEN_FILE")
	if ! { mkdir -p "$TOKEN_DIR" && chmod 700 "$TOKEN_DIR"; }; then
		log "WARNING: could not create $TOKEN_DIR; node.env is unchanged and this node keeps its inline token. Retrying next boot."
		exit 0
	fi
	# Atomic: write a 0600 temp beside it and rename. A half-written token file
	# next to a node.env that no longer carries the inline copy is the one
	# outcome that would take the node off the bus.
	jt_tmp="$TOKEN_DIR/.join.token.$$"
	rm -f "$jt_tmp"
	if ! { (umask 077 && printf '%s\n' "$TOKEN" > "$jt_tmp") \
		&& chmod 600 "$jt_tmp" \
		&& mv -f "$jt_tmp" "$TOKEN_FILE"; }; then
		rm -f "$jt_tmp"
		log "WARNING: could not write the join token to $TOKEN_FILE; node.env is unchanged and this node keeps its inline token. Retrying next boot."
		exit 0
	fi
	sync
	log "wrote the join token from node.env to $TOKEN_FILE (0600)"
fi

# Prove it reads back before node.env loses the inline copy.
if [ ! -s "$TOKEN_FILE" ] || [ -z "$(cat "$TOKEN_FILE" 2>/dev/null || true)" ]; then
	log "WARNING: $TOKEN_FILE does not read back; node.env is unchanged and this node keeps its inline token. Retrying next boot."
	exit 0
fi

# Rewrite node.env: drop every inline token line, and name the file exactly
# once. Written as a 0600 temp and renamed, so a power cut leaves the old
# node.env whole rather than a truncated one.
env_tmp="$PERSIST/.node.env.jointoken.$$"
rm -f "$env_tmp"
# `grep -v` exits 1 when it prints nothing, which is not an error here, so its
# status is taken explicitly rather than left to `set -e`.
(
	umask 077
	grep -v '^RASPUTIN_CP_JOIN_TOKEN=' "$NODE_ENV" > "$env_tmp" || true
	if ! grep -q '^RASPUTIN_CP_JOIN_TOKEN_FILE=' "$env_tmp"; then
		echo "RASPUTIN_CP_JOIN_TOKEN_FILE=$TOKEN_FILE" >> "$env_tmp"
	fi
) || true
# node.env always carries the role, the id and the cluster id, so a rewrite
# that produced an empty or missing file is a failed rewrite, not a node.env
# with nothing left in it. Never rename that over the real one.
if [ ! -s "$env_tmp" ] || ! grep -q '^RASPUTIN_NODE_ID=' "$env_tmp"; then
	rm -f "$env_tmp"
	log "WARNING: the rewritten $NODE_ENV did not come out intact; it is unchanged and this node keeps its inline token. Retrying next boot."
	exit 0
fi
if ! { chmod 600 "$env_tmp" && mv -f "$env_tmp" "$NODE_ENV"; }; then
	rm -f "$env_tmp"
	log "WARNING: could not replace $NODE_ENV; the token file is in place and the inline token stays for now. Retrying next boot."
	exit 0
fi
sync
log "node.env now names $TOKEN_FILE and no longer carries the token itself"
