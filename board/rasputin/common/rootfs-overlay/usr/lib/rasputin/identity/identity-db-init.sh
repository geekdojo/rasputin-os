#!/bin/sh
#
# identity-db-init.sh — create the identity database's cluster, once
# (geekdojo/geekdojo-brain#975, Identity 2.7; platform.md §3.2). Runs as the
# postgres uid inside keycloak-db.service's sandbox (no `+`), between the two
# phases of identity-db-init-gate.sh, which decides and records.
#
#   1. The data directory lists anything: there is a cluster; exit 0.
#   2. The gate permits a creation by leaving data.init present and empty.
#      Anything else is not permitted: exit 1.
#   3. initdb into data.init: builtin C.UTF-8 locale, data checksums on, the
#      postgres superuser with every connection rejected (no password, and the
#      generated pg_hba.conf is `reject`-only; the unit's config names the
#      baked one).
#   4. The bootstrap SQL in single-user mode: the keycloak login role and its
#      database, then a check that prints a fixed token only when both exist
#      as wanted. A non-zero exit, an ERROR line or a missing token fails.
#   5. rmdir data (tmpfiles' empty one, if there), mv data.init data, sync.
#      Only now does the data directory list anything, so a reboot at any
#      earlier point leaves it empty or absent and the next start begins again
#      from that fact (ARCH-FACTS).
#
# EXIT STATUS. 0 when the data directory holds a cluster, 1 otherwise. The
# unit has no `-`, so 1 fails the start. Each failure logs a <3> line naming
# the step; this step writes no record (the gate's post does).
#
# No credential exists on this path (LOG-SECRETS).
#
# COLLABORATORS arrive as environment variables with production defaults, so
# the tests can point every one at a scratch tree. The unit sets none.
set -u

DB="${RASPUTIN_IDDBINIT_DB:-/var/lib/rasputin/identity-db}"
INITDB="${RASPUTIN_IDDBINIT_INITDB:-/usr/bin/initdb}"
POSTGRES="${RASPUTIN_IDDBINIT_POSTGRES:-/usr/bin/postgres}"
DATA="$DB/data"
STAGE="$DB/data.init"
TOKEN='rasputin_bootstrap = "ok"'

umask 077

OUTCOME_TAG=identity-db-init
# The sandbox's private /dev has no kmsg node; the gate's line reaches the
# console.
OUTCOME_KMSG="${RASPUTIN_IDDBINIT_KMSG:-/dev/null}"
# shellcheck source=SCRIPTDIR/../outcome/outcome.sh
. "$(dirname "$0")/../outcome/outcome.sh"

fail() {
	outcome_log 3 "$1"
	exit 1
}

if _entries=$(ls -A -- "$DATA" 2>/dev/null) && [ -n "$_entries" ]; then
	exit 0
fi

if [ -L "$STAGE" ] || [ ! -d "$STAGE" ] || ! _staged=$(ls -A -- "$STAGE" 2>/dev/null) || [ -n "$_staged" ]; then
	fail "The identity database's staging directory $STAGE is missing or not empty, so creating the database is not permitted on this start."
fi

"$INITDB" -D "$STAGE" -U postgres -A reject --no-instructions -E UTF8 \
	--locale-provider=builtin --builtin-locale=C.UTF-8 --locale=C --data-checksums
_rc=$?
[ "$_rc" -eq 0 ] || fail "initdb exited with status $_rc, so the identity database was not created."

# Single-user mode ends each statement at a newline, so each is one line.
_out=$("$POSTGRES" --single -D "$STAGE" postgres 2>&1 <<'EOF'
CREATE ROLE keycloak LOGIN;
CREATE DATABASE keycloak OWNER keycloak;
SELECT 'ok' AS rasputin_bootstrap FROM pg_database d JOIN pg_roles r ON r.oid = d.datdba WHERE d.datname = 'keycloak' AND r.rolname = 'keycloak' AND r.rolcanlogin;
EOF
)
_rc=$?
if [ "$_rc" -ne 0 ] || printf '%s\n' "$_out" | grep -q 'ERROR:' \
	|| ! printf '%s\n' "$_out" | grep -qF "$TOKEN"; then
	printf '%s\n' "$_out"
	fail "The bootstrap SQL in postgres single-user mode did not finish (status $_rc), so the identity database was not created."
fi

if [ -e "$DATA" ] || [ -L "$DATA" ]; then
	rmdir "$DATA" || fail "The empty data directory $DATA could not be removed, so the identity database was not put in place."
fi
mv "$STAGE" "$DATA" || fail "The staging directory $STAGE could not be renamed to $DATA, so the identity database was not put in place."
sync || fail "sync failed after the identity database was put in place in $DATA."

outcome_log 6 "The identity database was created in $DATA."
exit 0
