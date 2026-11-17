#!/bin/sh
#
# identity-stage-import.sh — stage the frozen realm baseline for Keycloak's
# import, only while sign-in is not set up (geekdojo/geekdojo-brain#975,
# Identity 2.7; platform.md §4.1). Runs as root outside keycloak.service's
# sandbox (`+`), after the start-failure hold.
#
#   unarmed   copy /usr/share/rasputin/identity/realm-baseline.json to
#             keycloak/data/import/realm-baseline.json, 0600 991:991.
#             `--import-realm` imports it on the first start and skips a realm
#             that exists on every later one.
#   armed     remove a staged copy, so nothing is imported once sign-in is set
#             up.
#   unknown   refuse: whether sign-in was set up cannot be read.
# The fact is `armed`, read through armed.sh as the database gate reads it.
#
# ROOT IN ANOTHER UID'S DIRECTORY. keycloak/data is the keycloak uid's. During
# ExecStartPre= no process of the unit's uid runs (systemd empties the cgroup
# before a start), so these static rules are enough. Before touching anything
# it refuses when keycloak/data is not a real directory, import is present and
# not a real directory, or the staged name is present and not a regular file
# (a symlink is none of these). It removes names only with `rm -f`, which
# unlinks a symlink and never follows it; creates only names it has just
# removed or found absent; and runs `chown -h` only on what it created. The
# copy goes in by a rename, which replaces the name and never writes through
# it.
#
# EXIT STATUS. 0 to go on, 1 on any refusal or failure (no `-` in the unit, so
# Keycloak does not start), each with a <3> line.
#
# COLLABORATORS arrive as environment variables with production defaults, so
# the tests can point every one at a scratch tree. The unit sets none.
set -u

IDENTITY="${RASPUTIN_KCSTAGE_IDENTITY:-/var/lib/rasputin/identity}"
BASELINE="${RASPUTIN_KCSTAGE_BASELINE:-/usr/share/rasputin/identity/realm-baseline.json}"
KCDATA="${RASPUTIN_KCSTAGE_DATA:-/var/lib/rasputin/keycloak/data}"
# Numbers, as in tmpfiles: the keycloak user and group.
OWNER="${RASPUTIN_KCSTAGE_OWNER:-991:991}"
IMPORT="$KCDATA/import"
STAGED="$IMPORT/realm-baseline.json"
STAGED_TMP="$STAGED.tmp"

umask 077

OUTCOME_TAG=identity-stage-import
OUTCOME_KMSG="${RASPUTIN_KCSTAGE_KMSG:-/dev/kmsg}"
# shellcheck source=SCRIPTDIR/../outcome/outcome.sh
. "$(dirname "$0")/../outcome/outcome.sh"
# shellcheck source=SCRIPTDIR/armed.sh
. "$(dirname "$0")/armed.sh"

fail() {
	outcome_log 3 "$1"
	exit 1
}

if [ -L "$KCDATA" ] || [ ! -d "$KCDATA" ]; then
	fail "The identity service's data directory $KCDATA is missing or not a real directory, so the realm baseline was not staged."
fi
if [ -L "$IMPORT" ] || { [ -e "$IMPORT" ] && [ ! -d "$IMPORT" ]; }; then
	fail "$IMPORT is not a real directory, so the identity service's import directory was not touched."
fi
if [ -L "$STAGED" ] || { [ -e "$STAGED" ] && [ ! -f "$STAGED" ]; }; then
	fail "$STAGED is not a regular file, so the staged realm baseline was not touched."
fi

case "$(identity_armed "$IDENTITY")" in
	unknown)
		fail "Whether sign-in was already set up could not be read from $IDENTITY, so the realm baseline was neither staged nor removed."
		;;
	armed)
		if [ -e "$STAGED" ]; then
			rm -f "$STAGED" || fail "The staged realm baseline $STAGED could not be removed on a system where sign-in is set up."
			outcome_log 6 "Sign-in is set up, so the staged realm baseline $STAGED was removed."
		fi
		exit 0
		;;
esac

if [ ! -f "$BASELINE" ] || [ ! -r "$BASELINE" ]; then
	fail "The realm baseline $BASELINE cannot be read, so it was not staged."
fi
if [ ! -e "$IMPORT" ]; then
	{ mkdir -m 0700 "$IMPORT" && chown -h "$OWNER" "$IMPORT"; } \
		|| fail "The import directory $IMPORT could not be created, so the realm baseline was not staged."
fi
if ! { rm -f "$STAGED_TMP" && cp "$BASELINE" "$STAGED_TMP" && chmod 0600 "$STAGED_TMP" \
	&& chown -h "$OWNER" "$STAGED_TMP" && mv -f "$STAGED_TMP" "$STAGED"; }; then
	# Best effort, its error dropped on purpose: the failure is logged next, and
	# the next start begins by removing it.
	rm -f "$STAGED_TMP" 2>/dev/null
	fail "The realm baseline could not be staged as $STAGED."
fi
outcome_log 6 "The realm baseline was staged as $STAGED for the identity service's import."
exit 0
