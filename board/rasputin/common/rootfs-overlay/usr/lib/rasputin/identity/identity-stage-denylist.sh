#!/bin/sh
#
# identity-stage-denylist.sh — stage the password deny list the api tarball
# ships into the identity service's persistent data directory
# (geekdojo/geekdojo-brain#1145). Runs as root outside keycloak.service's
# sandbox (`+`), after the start-failure hold and before the realm staging.
#
# The realm's password policy names the list (passwordBlacklist(<name>)), and
# Keycloak reads it from <data>/password-blacklists/<name>. Once the realm
# stores that policy, a missing file makes the realm unloadable, so the copy
# lives in the persistent data directory, not the slot: a fallback to an
# earlier slot keeps both the database and the file.
#
# On every start it copies each regular file in the release's
# /usr/share/rasputin/identity/password-blacklists/ into
# keycloak/data/password-blacklists/ (created at 0700, owned by the keycloak
# uid), each at 0600 by a temp file and a rename. No process of the unit's uid
# runs during ExecStartPre=, so a copy cannot race a reload.
#
#   source absent   an api tarball from before the list shipped: one <6>
#                   line, exit 0, an existing copy left as it is.
#   anything else   staged, or refused with a <3> line and exit 1.
#
# ROOT IN ANOTHER UID'S DIRECTORY: the rules are kcdata-stage.sh's, shared with
# identity-stage-import.sh. It refuses when keycloak/data is not a real
# directory, password-blacklists is present and not a real directory, or a
# name it would replace is present and not a regular file.
#
# EXIT STATUS. 0 to go on, 1 on any refusal or failure (no `-` in the unit, so
# Keycloak does not start), each with a <3> line.
#
# COLLABORATORS arrive as environment variables with production defaults, so
# the tests can point every one at a scratch tree. The unit sets none.
set -u

SOURCE="${RASPUTIN_KCDENY_SOURCE:-/usr/share/rasputin/identity/password-blacklists}"
KCDATA="${RASPUTIN_KCDENY_DATA:-/var/lib/rasputin/keycloak/data}"
# Numbers, as in tmpfiles: the keycloak user and group.
OWNER="${RASPUTIN_KCDENY_OWNER:-991:991}"
TARGET="$KCDATA/password-blacklists"

umask 077

OUTCOME_TAG=identity-stage-denylist
OUTCOME_KMSG="${RASPUTIN_KCDENY_KMSG:-/dev/kmsg}"
# shellcheck source=SCRIPTDIR/../outcome/outcome.sh
. "$(dirname "$0")/../outcome/outcome.sh"
# shellcheck source=SCRIPTDIR/kcdata-stage.sh
. "$(dirname "$0")/kcdata-stage.sh"

fail() {
	outcome_log 3 "$1"
	exit 1
}

if [ ! -e "$SOURCE" ] && [ ! -L "$SOURCE" ]; then
	outcome_log 6 "This release ships no password deny list at $SOURCE, so none was staged and any earlier copy in $TARGET was left as it is."
	exit 0
fi
if [ ! -d "$SOURCE" ] || [ ! -r "$SOURCE" ] || [ ! -x "$SOURCE" ]; then
	fail "The password deny list directory $SOURCE cannot be read, so the list was not staged."
fi
if ! kcdata_real_dir "$KCDATA"; then
	fail "The identity service's data directory $KCDATA is missing or not a real directory, so the password deny list was not staged."
fi
if ! kcdata_dir_ok "$TARGET"; then
	fail "$TARGET is not a real directory, so the password deny list was not staged."
fi

# Every check on every file before the first write.
for f in "$SOURCE"/*; do
	[ -f "$f" ] || continue
	[ -r "$f" ] || fail "The password deny list $f cannot be read, so the list was not staged."
	kcdata_file_ok "$TARGET/${f##*/}" \
		|| fail "$TARGET/${f##*/} is not a regular file, so the password deny list was not staged."
done

if [ ! -e "$TARGET" ]; then
	kcdata_mkdir "$TARGET" "$OWNER" \
		|| fail "The directory $TARGET could not be created, so the password deny list was not staged."
fi
for f in "$SOURCE"/*; do
	[ -f "$f" ] || continue
	kcdata_install "$f" "$TARGET/${f##*/}" "$OWNER" \
		|| fail "The password deny list could not be staged as $TARGET/${f##*/}."
done
outcome_log 6 "The password deny list was staged in $TARGET for the identity service."
exit 0
