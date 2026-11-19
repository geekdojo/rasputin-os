#!/bin/sh
#
# rasputin-store-migrate.sh — the root step of a secrets store's roll-forward
# (geekdojo/geekdojo-brain#1132; ADR-0010). openbao.service runs it as its
# third ExecStartPre=, after the version gate and before the self-init hook's
# pre, with `+` (root, outside the store's sandbox) and WITHOUT `-`: a
# put-back that cannot finish fails the store's start, so bao never runs on a
# half-restored tree.
#
# WHY. A store initialised before release 2026.11.3 has no rasputin-author
# role, and nothing can add one: there is no root token and no recovery key
# (ADR-0010 S9). The api rolls such a store forward instead. It reads every
# secret it can reach again into memory, asks this step to move the old tree
# aside, restarts the store so it initialises itself from this image's
# init.json, writes every secret back, verifies each, and commits. This step
# owns only the files: it never reads or writes a secret.
#
# STATE, in /var/lib/rasputin/store-migrate/ (root, 0700; files 0600):
#   request          written by the api: boot_id=<this boot> and job_id=<id>
#   aside.tar        the old tree, written here; the authority until commit
#   aside.tar.partial  aside.tar while it is being written
#   attempt          request, renamed once the old tree is aside, so the job
#                    id survives beside aside.tar
#   commit           written by the api once every secret is written back
# and two work directories inside the data directory, because in the unit's
# mount namespace the data directory is a bind mount that cannot be renamed
# (store-swap/swap.sh): .rasputin-migrate-new (the data directory's owner) and
# .rasputin-migrate-old (root).
#
# THE DECISION. A stray aside.tar.partial is removed first: only this step
# writes it, and the step runs alone. Then the first match wins:
#   1  commit: finished. aside.tar, attempt, request and the work directories
#      are removed, then commit last, so an interrupted clean-up repeats. Before
#      2, so a restore after a finished migration is not misread (F-1132-11).
#   2  restore-pending/store/applied and any migration state: superseded. The
#      restore step ran first and its data is live; the migration state and the
#      work directories are removed.
#   3  aside.tar: the put-back, restored. Nothing in the data directory is
#      worth keeping before the commit, and aside.tar is the authority, so it
#      clears both work directories, unpacks aside.tar into
#      .rasputin-migrate-new with the data directory's owner, moves the live
#      entries into .rasputin-migrate-old and the unpacked ones into place,
#      syncs, then removes request, aside.tar, attempt and the work
#      directories. Each start rebuilds from aside.tar alone, so a put-back
#      interrupted at any point converges on the next one (F-1132-01). A
#      failure exits 1 and the store is held stopped until a start completes.
#   4  request naming this boot: the move-aside, moved. aside.tar is written
#      (tar_aside), the live entries are moved into .rasputin-migrate-old and
#      removed, the data directory must then be empty, and request is renamed
#      to attempt. A failure before aside.tar exists removes request and the
#      store starts on its old data (failed). A failed rename puts the entries
#      back by rename (roll_back) and removes request and aside.tar (failed);
#      when that fails too, request and aside.tar are left, the step exits 1,
#      and the next start runs 3. A failure after the entries left the data
#      directory runs 3's put-back at once (failed), since a part-removed tree
#      cannot be renamed back. A crash anywhere after aside.tar exists also
#      leads the next start to 3.
#   5  request naming another boot: failed. request is removed and the data
#      directory is unchanged.
#   6  only attempt or work directories left: removed, one <4> line, no record.
#   7  nothing: silent, exit 0.
#
# STABLE CONTRACT. Readers depend on these; they do not change without them:
#
#   The journal and console line, one per recorded outcome:
#     rasputin-store-migrate: outcome=<moved|finished|restored|superseded|failed> reason="<sentence>"
#   on stdout with a syslog priority prefix (<6> moved and finished, <4>
#   restored and superseded, <3> failed, <2> a put-back or roll-back that
#   could not finish, its reason naming aside.tar), and the same line on
#   /dev/kmsg. Lines name paths, never contents: no store byte is read into
#   the shell.
#
#   The outcome record (read by the api, its os.store_migrate source):
#     /run/rasputin-store-migrate/outcome   0600 root, tmpfs: THIS BOOT ONLY
#   exactly four lines, each KEY=VALUE, the value everything after the first =:
#     outcome=<moved|finished|restored|superseded|failed>
#     boot_id=<the kernel's boot_id for this boot, or - if unreadable>
#     run_id=<the store run's INVOCATION_ID, or - if unset>
#     reason=<one English sentence, starting with a capital, ending with ".">
#   written to a temp file and renamed, on every run that is not silent;
#   decision 6 writes none.
#
# EXIT STATUS. 0, except 1 for a put-back or roll-back that could not finish.
#
# COLLABORATORS arrive as environment variables with production defaults, so
# the tests can point every one at a scratch tree. The unit sets none.
set -u

PERSIST="${RASPUTIN_STOREMIGRATE_PERSIST:-/var/lib/rasputin}"
RUN="${RASPUTIN_STOREMIGRATE_RUN:-/run/rasputin-store-migrate}"
BOOTID_SRC="${RASPUTIN_STOREMIGRATE_BOOTID:-/proc/sys/kernel/random/boot_id}"

umask 077

# Both read by outcome.sh.
# shellcheck disable=SC2034
OUTCOME_TAG=rasputin-store-migrate
# shellcheck disable=SC2034
OUTCOME_KMSG="${RASPUTIN_STOREMIGRATE_KMSG:-/dev/kmsg}"
. "$(dirname "$0")/../outcome/outcome.sh"
# present, move_entries, roll_back, tar_aside and data_owner, shared with
# rasputin-store-restore.sh and rasputin-store-rollback.sh.
. "$(dirname "$0")/../store-swap/swap.sh"

DATA="$PERSIST/openbao"
STATE="$PERSIST/store-migrate"
REQUEST="$STATE/request"
ATTEMPT="$STATE/attempt"
ASIDE="$STATE/aside.tar"
PARTIAL="$ASIDE.partial"
COMMIT="$STATE/commit"
APPLIED="$PERSIST/restore-pending/store/applied"
MNEW="$DATA/.rasputin-migrate-new"
MOLD="$DATA/.rasputin-migrate-old"
RECORD="$RUN/outcome"
RECORD_TMP="$RUN/.outcome.new"
HELD="The store is held stopped until a start puts the old data back from $ASIDE, which is kept: the store's next restart, or the next boot."

# finish OUTCOME PRIORITY REASON [STATUS] — the record, the line, and exit
# STATUS (0 by default). A failed record write is logged by outcome_record;
# the line still goes out.
finish() {
	mkdir -p "$RUN" 2>/dev/null
	outcome_record "$RECORD" "$RECORD_TMP" "outcome=$1" \
		"boot_id=$(outcome_boot_id "$BOOTID_SRC")" "run_id=${INVOCATION_ID:--}" "reason=$3" || :
	outcome_log "$2" "outcome=$1 reason=\"$3\""
	exit "${4:-0}"
}

# remove_files PATH... — removes each file and work directory; prints the
# ones still present, so the caller can say so.
remove_files() {
	for _rf in "$@"; do
		present "$_rf" || continue
		rm -rf "$_rf" 2>/dev/null
		present "$_rf" && printf '%s ' "$_rf"
	done
	return 0
}

# any_present PATH... — true when any PATH exists.
any_present() {
	for _ap in "$@"; do
		present "$_ap" && return 0
	done
	return 1
}

# tidy WHAT PATH... — remove_files, and a <4> line naming what is left of
# WHAT, which the next start of the store tries again.
tidy() {
	_td=$1
	shift
	_left=$(remove_files "$@")
	[ -z "$_left" ] \
		|| outcome_log 4 "The leftovers $_left of $_td could not be removed, so the next start of the store tries again."
	return 0
}

# put_back — decision 3's steps: the data directory rebuilt from aside.tar
# alone, then the migration state removed. Returns 1 at the first failure,
# with aside.tar untouched; every step before the removals can be repeated.
put_back() {
	[ -z "$(remove_files "$MNEW" "$MOLD")" ] || return 1
	_owner=$(data_owner "$DATA") || return 1
	mkdir "$MNEW" && tar -xf "$ASIDE" -C "$MNEW" && chown -R "$_owner" "$MNEW" || return 1
	mkdir "$MOLD" || return 1
	move_entries data "$DATA" "$MOLD" || return 1
	move_entries data "$MNEW" "$DATA" || return 1
	sync || return 1
	# request first: with aside.tar still there, a crash here repeats this
	# put-back; aside.tar gone with request left would read as a new request.
	rm -f "$REQUEST" && rm -f "$ASIDE" || return 1
	tidy "a put-back" "$ATTEMPT" "$MNEW" "$MOLD"
	sync
	return 0
}

# put_back_or_hold OUTCOME PRIORITY REASON — put_back, then finish with
# OUTCOME; when put_back fails, a <2> failed line naming aside.tar, exit 1.
put_back_or_hold() {
	put_back || finish failed 2 "Putting the old secrets store data back from $ASIDE failed. $HELD" 1
	finish "$1" "$2" "$3"
}

# --- a stray partial archive --------------------------------------------------
if present "$PARTIAL"; then
	rm -f "$PARTIAL" 2>/dev/null
	present "$PARTIAL" \
		&& outcome_log 4 "The partial archive $PARTIAL is left from an interrupted move-aside and could not be removed."
fi

# --- 1. commit: finished ------------------------------------------------------
if present "$COMMIT"; then
	_left=$(remove_files "$ASIDE" "$ATTEMPT" "$REQUEST" "$MNEW" "$MOLD")
	if [ -z "$_left" ]; then
		_left=$(remove_files "$COMMIT")
	fi
	sync
	[ -z "$_left" ] \
		|| outcome_log 4 "The leftovers $_left of a finished secrets store upgrade could not be removed, so the next start of the store tries again."
	finish finished 6 "The secrets store upgrade was committed, so the old data kept in $ASIDE was deleted."
fi

# --- 2. a restore supersedes --------------------------------------------------
if present "$APPLIED" && any_present "$REQUEST" "$ATTEMPT" "$ASIDE" "$MNEW" "$MOLD"; then
	tidy "a superseded secrets store upgrade" "$REQUEST" "$ATTEMPT" "$ASIDE" "$MNEW" "$MOLD"
	sync
	finish superseded 4 "A restored backup was applied to the secrets store before its upgrade was committed, so the upgrade was cancelled and the restored data is kept."
fi

# --- 3. aside.tar without a commit: the put-back -------------------------------
if present "$ASIDE"; then
	put_back_or_hold restored 4 "The secrets store upgrade was not committed, so the old data was put back from $ASIDE and the store starts on it."
fi

# --- 4 and 5. a request -------------------------------------------------------
if present "$REQUEST"; then
	_want=$(sed -n 's/^boot_id=//p' "$REQUEST" 2>/dev/null | sed -n 1p)
	_boot=$(outcome_boot_id "$BOOTID_SRC")
	if [ -z "$_want" ] || [ "$_boot" = - ] || [ "$_want" != "$_boot" ]; then
		tidy "a stale secrets store upgrade request" "$REQUEST" "$ATTEMPT" "$MNEW" "$MOLD"
		finish failed 3 "The secrets store upgrade request in $REQUEST was not made in this boot, so it was removed and the store starts on its data unchanged."
	fi

	# 4a. The old tree, aside. Nothing has moved yet, so a failure here leaves
	# the store to start on its old data.
	if [ -n "$(remove_files "$MNEW" "$MOLD")" ] || ! tar_aside "$DATA" "$ASIDE"; then
		tidy "a secrets store upgrade that did not start" "$ASIDE" "$REQUEST"
		finish failed 3 "Writing the old secrets store data aside to $ASIDE failed, so the upgrade was not started and the store starts on its old data."
	fi

	# 4b. The live entries out of the data directory. A failed rename leaves
	# them whole, so they go back by rename.
	if ! mkdir "$MOLD" || ! move_entries data "$DATA" "$MOLD"; then
		if roll_back data "$DATA" "" "$MOLD" A && [ -z "$(remove_files "$MOLD")" ]; then
			tidy "a secrets store upgrade that did not start" "$REQUEST" "$ASIDE"
			finish failed 3 "Moving the old secrets store data aside failed, so the upgrade was not started and the old data was put back by rename; the store starts on it."
		fi
		finish failed 2 "Moving the old secrets store data aside failed, and putting it back by rename failed too. $HELD" 1
	fi
	# Removing it can stop part way, so from here on aside.tar is the only
	# whole copy, and a failure puts the old tree back from it.
	_entries=$(rm -rf "$MOLD" 2>/dev/null; ls -A -- "$DATA" 2>/dev/null) && [ -z "$_entries" ] \
		|| put_back_or_hold failed 3 "Emptying the secrets store's data directory failed, so the upgrade was not started and the old data was put back from $ASIDE; the store starts on it."

	# 4c. The request becomes the attempt.
	{ mv -f "$REQUEST" "$ATTEMPT" && sync; } \
		|| put_back_or_hold failed 3 "Recording the secrets store upgrade attempt in $ATTEMPT failed, so the upgrade was not started and the old data was put back from $ASIDE; the store starts on it."
	finish moved 6 "The old secrets store data was moved aside to $ASIDE for an upgrade, so the store starts empty and initialises itself."
fi

# --- 6. leftovers --------------------------------------------------------------
if any_present "$ATTEMPT" "$MNEW" "$MOLD"; then
	_left=$(remove_files "$ATTEMPT" "$MNEW" "$MOLD")
	if [ -z "$_left" ]; then
		outcome_log 4 "The leftovers of an earlier secrets store upgrade were removed."
	else
		outcome_log 4 "The leftovers $_left of an earlier secrets store upgrade could not be removed, so the next start of the store tries again."
	fi
	exit 0
fi

# --- 7. nothing ----------------------------------------------------------------
exit 0
