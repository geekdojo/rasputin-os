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
# ROOT IN ANOTHER UID'S DIRECTORY. keycloak/data is the keycloak uid's; the
# rules for writing in it are kcdata-stage.sh's, shared with
# identity-stage-denylist.sh. Before touching anything it refuses when
# keycloak/data is not a real directory, import is present and not a real
# directory, or the staged name is present and not a regular file.
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

umask 077

OUTCOME_TAG=identity-stage-import
OUTCOME_KMSG="${RASPUTIN_KCSTAGE_KMSG:-/dev/kmsg}"
# shellcheck source=SCRIPTDIR/../outcome/outcome.sh
. "$(dirname "$0")/../outcome/outcome.sh"
# shellcheck source=SCRIPTDIR/armed.sh
. "$(dirname "$0")/armed.sh"
# shellcheck source=SCRIPTDIR/kcdata-stage.sh
. "$(dirname "$0")/kcdata-stage.sh"

fail() {
	outcome_log 3 "$1"
	exit 1
}

if ! kcdata_real_dir "$KCDATA"; then
	fail "The identity service's data directory $KCDATA is missing or not a real directory, so the realm baseline was not staged."
fi
if ! kcdata_dir_ok "$IMPORT"; then
	fail "$IMPORT is not a real directory, so the identity service's import directory was not touched."
fi
if ! kcdata_file_ok "$STAGED"; then
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
	kcdata_mkdir "$IMPORT" "$OWNER" \
		|| fail "The import directory $IMPORT could not be created, so the realm baseline was not staged."
fi
kcdata_install "$BASELINE" "$STAGED" "$OWNER" \
	|| fail "The realm baseline could not be staged as $STAGED."
outcome_log 6 "The realm baseline was staged as $STAGED for the identity service's import."
exit 0
