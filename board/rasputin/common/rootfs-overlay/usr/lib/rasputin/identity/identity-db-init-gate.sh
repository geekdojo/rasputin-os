#!/bin/sh
#
# identity-db-init-gate.sh — whether this start of keycloak-db.service may
# create the identity database, and the outcome record of that decision
# (geekdojo/geekdojo-brain#975, Identity 2.7; platform.md §3.2, §4.1). Runs as
# root outside the unit's sandbox (`+`), twice per start:
#
#   pre    before identity-db-init.sh: decides, and prepares the staging
#          directory when creating is permitted.
#   post   after it: records `created` when this start was permitted and the
#          data directory now holds the cluster.
#
# THE FACTS IT USES. No timer decides anything here (ARCH-FACTS):
#   * The data directory's listing. tmpfiles recreates it empty on every boot,
#     so "no data" means it lists nothing or is absent. identity-db-init.sh
#     builds the cluster in data.init and renames it into place only once
#     initdb and the bootstrap SQL have both finished, so a data directory
#     that lists anything is a finished cluster.
#   * `armed` in the identity directory, read through armed.sh. Present (or
#     unreadable) with no data means sign-in was set up on this system and its
#     data is gone: creating an empty database would hand the cluster a blank
#     identity, so the start is refused.
#   * The pending marker this script writes in pre, which post reads.
#
# ROOT IN ANOTHER UID'S DIRECTORY. identity-db/ is the postgres uid's. During
# ExecStartPre= no process of the unit's uid runs (systemd empties the cgroup
# before a start), so these static rules are enough: data that is a symlink
# or not a directory is refused; data.init is removed with `rm -rf`, which
# unlinks a top-level symlink and never follows it; only the name this run
# just removed is created; and `chown -h` touches only what this run created.
#
# STABLE CONTRACT (#979, read by the api's outcome reader as
# os.identity_db_init; it does not change without it):
#   /run/rasputin-identity-db-init/outcome   0600 root, in a 0700 root
#   directory, exactly three lines:
#     outcome=<created|untouched|refused>
#     boot_id=<the kernel's boot_id for this boot, or - if unreadable>
#     reason=<one sentence, starting with a capital, ending with ".">
#   written to a temp file and renamed. `created` and `refused` always
#   overwrite. `untouched` is written only when there is no record or the
#   record reads `refused`: it clears a refusal once the data is restored in
#   the same boot, and never hides a `created` before the api has read it.
#   The journal and console line, one per outcome:
#     identity-db-init-gate: outcome=<…> reason="<sentence>"
#   with priority <6> for created and untouched, <2> for refused. The reasons
#   reach operators through the api's alert, so none names a vendor or a tool.
#
# EXIT STATUS. 0 to go on, 1 on every refusal (no `-` in the unit, so the
# start fails, and Restart= with systemd's start limit holds the database and
# the identity service with it through Requires=), 2 for an unknown phase.
#
# COLLABORATORS arrive as environment variables with production defaults, so
# the tests can point every one at a scratch tree. The unit sets none.
set -u

DB="${RASPUTIN_IDDBGATE_DB:-/var/lib/rasputin/identity-db}"
IDENTITY="${RASPUTIN_IDDBGATE_IDENTITY:-/var/lib/rasputin/identity}"
RUN="${RASPUTIN_IDDBGATE_RUN:-/run/rasputin-identity-db-init}"
BOOTID_SRC="${RASPUTIN_IDDBGATE_BOOTID:-/proc/sys/kernel/random/boot_id}"
# Numbers, as in tmpfiles: the postgres user and group.
OWNER="${RASPUTIN_IDDBGATE_OWNER:-992:992}"
DATA="$DB/data"
STAGE="$DB/data.init"
PENDING="$RUN/pending"
RECORD="$RUN/outcome"
RECORD_TMP="$RUN/.outcome.new"

umask 077

OUTCOME_TAG=identity-db-init-gate
OUTCOME_KMSG="${RASPUTIN_IDDBGATE_KMSG:-/dev/kmsg}"
# shellcheck source=SCRIPTDIR/../outcome/outcome.sh
. "$(dirname "$0")/../outcome/outcome.sh"
# shellcheck source=SCRIPTDIR/armed.sh
. "$(dirname "$0")/armed.sh"

R_CREATED="The sign-in service's database was created on its first start."
R_UNTOUCHED="The sign-in service's database already holds data, so it was left as it is."
R_ARMED="The sign-in service's data is missing on a system where sign-in was already set up, so its database is held stopped rather than started empty. Restore the sign-in data from a backup of this cluster, through a repair session if nobody can sign in."
R_UNKNOWN="Whether sign-in was already set up on this system could not be read, so the sign-in service's database is held stopped."
R_UNREADABLE="The sign-in service's data could not be read, so its database is held stopped."
R_PREPARE="The sign-in service's database could not be prepared for its first start, so it is held stopped until the next start."
R_NOT_CREATED="The sign-in service's database was not created on its first start, so it is held stopped."

# finish OUTCOME PRIORITY REASON — write the record under the rule above, log
# the line, exit 1 for refused and 0 otherwise. A failed record write is
# logged by outcome_record; the line still goes out and the exit is the same.
finish() {
	mkdir -p "$RUN" 2>/dev/null
	_write=1
	if [ "$1" = untouched ] && [ -e "$RECORD" ] \
		&& [ "$(sed -n 's/^outcome=//p' "$RECORD" 2>/dev/null | head -n 1)" != refused ]; then
		_write=""
	fi
	if [ -n "$_write" ]; then
		outcome_record "$RECORD" "$RECORD_TMP" "outcome=$1" \
			"boot_id=$(outcome_boot_id "$BOOTID_SRC")" "reason=$3" || :
	fi
	outcome_log "$2" "outcome=$1 reason=\"$3\""
	[ "$1" = refused ] && exit 1
	exit 0
}
refuse() {
	# Best effort, its error dropped on purpose: a stale marker only makes a
	# later post refuse, which is the outcome already being recorded.
	rm -f "$PENDING" 2>/dev/null
	finish refused 2 "$1"
}

# has_data — the data directory lists something. Refuses (exits) when it is a
# symlink, not a directory, or cannot be listed. Absent is no data.
has_data() {
	if [ -L "$DATA" ] || { [ -e "$DATA" ] && [ ! -d "$DATA" ]; }; then
		refuse "$R_UNREADABLE"
	fi
	[ -d "$DATA" ] || return 1
	_entries=$(ls -A -- "$DATA" 2>/dev/null) || refuse "$R_UNREADABLE"
	[ -n "$_entries" ]
}

case "${1:-}" in
	pre)
		if has_data; then
			# Best effort, its error dropped on purpose: post only reads the
			# marker after a permitted pre, which rewrites it.
			rm -f "$PENDING" 2>/dev/null
			finish untouched 6 "$R_UNTOUCHED"
		fi
		case "$(identity_armed "$IDENTITY")" in
			armed) refuse "$R_ARMED" ;;
			unknown) refuse "$R_UNKNOWN" ;;
		esac
		mkdir -p "$RUN" 2>/dev/null
		# A subshell, because a failed redirection on a special built-in ends a
		# non-interactive shell.
		if ! { rm -rf "$STAGE" && mkdir -m 0700 "$STAGE" && chown -h "$OWNER" "$STAGE" \
			&& (: > "$PENDING"); } 2>/dev/null; then
			refuse "$R_PREPARE"
		fi
		outcome_log 6 "The sign-in service's database has no data and sign-in is not set up yet, so this start may create it."
		exit 0
		;;
	post)
		[ -e "$PENDING" ] || exit 0
		if has_data; then
			if ! rm -f "$PENDING" 2>/dev/null || [ -e "$PENDING" ]; then
				outcome_log 4 "The marker $PENDING could not be removed, so a later start may record a second outcome for this one."
			fi
			finish created 6 "$R_CREATED"
		fi
		refuse "$R_NOT_CREATED"
		;;
	*)
		outcome_log 3 "identity-db-init-gate.sh was run with '${1:-}' instead of pre or post, so nothing was decided."
		exit 2
		;;
esac
