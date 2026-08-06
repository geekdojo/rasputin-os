#!/bin/sh
#
# rasputin-clusterid-backfill.sh — one-time migration for clusters provisioned
# before per-cluster naming (2026-08-02: rasputin-os 4558b6e "firstboot: carry
# RASPUTIN_CLUSTER_ID …" + control-plane 8f03311, "E2").
#
# The api derives its public identity — public-base-url and the WebAuthn
# RP-ID/origins — from RASPUTIN_CLUSTER_ID in node.env. firstboot writes that
# key, but only since 4558b6e, and firstboot is run-once (guarded by
# .provisioned), so an OS UPDATE never re-runs it and node.env on the
# persistent partition is never rewritten. A cluster provisioned before that
# carries a node.env with NO cluster-id; on the E2 image the api then falls back
# to its dev default public-base-url=http://localhost:8080 and every node.update
# tells the node to fetch its own loopback -> "connection refused". The same
# gap drops the RP-ID to "localhost", so fresh passkey logins fail too. See
# control-plane #75.
#
# This runs every boot (multi-user.target.wants), after firstboot has ensured
# node.env exists and before the agent/api/hostname read it. It appends the
# documented default cluster-id ("rasputin") ONLY when the key is absent:
#   - fresh >=E2 installs already have the key  -> no-op
#   - dev boxes have no node.env (unit ConditionPathExists gate) -> never runs
#   - already-migrated nodes have the key       -> no-op (idempotent)
#
# "rasputin" is provably the right value, not just a safe guess: per-cluster
# naming SHIPPED in E2, so no pre-E2 cluster ever had a non-default name — every
# one of them has always resolved as rasputin.local (the name the pre-E2 image
# hardcoded in rasputin-api.service). This restores exactly that identity. An
# operator who later wants a real name sets RASPUTIN_CLUSTER_ID in the seed and
# reprovisions; this only fills the historical default.
set -eu

NODE_ENV=/var/lib/rasputin/node.env

# The unit already gates on this file existing; re-check for a direct/manual
# invocation so the script is safe to run on its own.
[ -f "$NODE_ENV" ] || exit 0

# firstboot writes RASPUTIN_CLUSTER_ID with a non-empty value (default
# "rasputin"), so its PRESENCE is a faithful "already has an id" signal.
if grep -q '^RASPUTIN_CLUSTER_ID=' "$NODE_ENV"; then
	exit 0
fi

# Append; >> keeps the file's existing 0600 perms (firstboot wrote it umask
# 077). Match firstboot's default exactly (see rasputin-firstboot.sh).
printf 'RASPUTIN_CLUSTER_ID=%s\n' 'rasputin' >> "$NODE_ENV"

echo "rasputin-clusterid-backfill: node.env had no RASPUTIN_CLUSTER_ID; backfilled the default 'rasputin' (pre-E2 provisioning; control-plane #75)" > /dev/kmsg 2>/dev/null || true
