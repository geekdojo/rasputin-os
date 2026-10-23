#!/bin/sh
#
# rasputin-store-restore.sh — apply a staged secrets-store restore before the
# store starts (geekdojo/geekdojo-brain#766; ADR-0010 S15). openbao.service
# runs it as its first ExecStartPre=, with `+` (root, outside the store's
# sandbox) and WITHOUT `-`: a refused or failed apply fails the store's start.
#
# WHAT IT DOES. The api's restore stages the archive's store under
# restore-pending/store/ (data/, seal-key, seal.hcl), stops the store and
# restarts itself; that restart pulls the store's start in ahead of the api's
# (Wants= and Before=), and this step runs first in it. It swaps the staged
# data, seal key and seal fragment in for the live ones, then writes
# restore-pending/store/applied. The api refuses to start on a staged store
# without that marker (#765), so the marker is the gate and the commit point.
#
# HOW, and why this shape. In the unit's mount namespace the data directory
# is a ReadWritePaths= bind mount: it cannot be renamed, and a move into it
# from restore-pending/ is a copy, not a rename. So the staged tree is first
# copied beside the live one, into a work directory inside each target, and
# then swapped by renames that never leave their directory:
#   1  nothing staged: exit 0, silently (every ordinary start)
#   2  marker present: applied by an earlier start; remove any work directory
#      left behind and exit 0, silently
#   3  a .rasputin-restore-old work directory without the marker: an earlier
#      swap was interrupted; refuse and touch nothing
#   4  a staged member missing, of the wrong type, or a symbolic link: refuse
#      and touch nothing
#   5  copy: data/ into openbao/.rasputin-restore-new (owned as the data
#      directory is, read with ls -ldn), the two seal files into
#      openbao-seal/.rasputin-restore-new, then sync; on a failure both copies
#      are removed and the live store is untouched
#   6  swap: phase A moves every live entry into .rasputin-restore-old, phase
#      B every new entry into place; the data first, then the seal. Only
#      seal-key and seal.hcl move in the seal directory, never rotation/. On a
#      failed rename the phase reached says exactly what to move back
#   7  commit: sync, the marker through a temp file and mv, sync
#   8  clean up the work directories, and log applied
# It never moves or deletes anything the api staged: restore-pending/ stays
# whole for the api to rename, trust/store-ca.* and store/openbao-version
# included.
#
# STABLE CONTRACT. One line per outcome, on stdout (the journal) and on the
# console, read by the bench and the functional test:
#   rasputin-store-restore: outcome=<applied|refused|failed> reason="<sentence>"
# with <6> applied, <3> refused or failed, and <2> for a failed swap whose
# rollback failed too. A cleanup that fails after the commit is a <4> line and
# exit 0. Lines name paths, never contents: no key byte is read into the shell.
#
# EXIT STATUS. 0 for nothing staged, already applied, or applied; 1 otherwise.
#
# COLLABORATORS arrive as environment variables with production defaults, so
# the tests can point every one at a scratch tree. The unit sets none.
set -u

PENDING="${RASPUTIN_STORERESTORE_PENDING:-/var/lib/rasputin/restore-pending/store}"
DATA="${RASPUTIN_STORERESTORE_DATA:-/var/lib/rasputin/openbao}"
SEAL="${RASPUTIN_STORERESTORE_SEAL:-/var/lib/rasputin/openbao-seal}"

umask 077

OUTCOME_TAG=rasputin-store-restore
OUTCOME_KMSG="${RASPUTIN_STORERESTORE_KMSG:-/dev/kmsg}"
. "$(dirname "$0")/../outcome/outcome.sh"

MARK="$PENDING/applied"
MARK_TMP="$PENDING/.applied.new"
DNEW="$DATA/.rasputin-restore-new"
DOLD="$DATA/.rasputin-restore-old"
SNEW="$SEAL/.rasputin-restore-new"
SOLD="$SEAL/.rasputin-restore-old"
REFLASH="Reflash the control plane and restore again from the backup disk, whose archive is untouched."

present() { [ -e "$1" ] || [ -L "$1" ]; }

# remove_work — after the commit, remove every work directory; a <4> line
# names each one left.
remove_work() {
	for _w in "$DNEW" "$DOLD" "$SNEW" "$SOLD"; do
		present "$_w" || continue
		rm -rf "$_w" 2>/dev/null
		present "$_w" && outcome_log 4 "The work directory $_w is left from an applied restore and could not be removed, so the next start of the store tries again."
	done
	return 0
}

# move_entries KIND FROM TO — move entries of FROM into TO by rename. KIND
# data moves every entry but the work directories; KIND seal moves seal-key
# and seal.hcl only. Stops at the first failure and returns 1.
move_entries() {
	_from=$2 _to=$3
	if [ "$1" = seal ]; then
		set -- "$_from/seal-key" "$_from/seal.hcl"
	else
		set -- "$_from"/* "$_from"/.[!.]* "$_from"/..?*
	fi
	for _p in "$@"; do
		present "$_p" || continue
		case "${_p##*/}" in .rasputin-restore-new|.rasputin-restore-old) continue ;; esac
		mv -f "$_p" "$_to/" || return 1
	done
	return 0
}

# roll_back KIND DIR NEW OLD PHASE — undo one directory's swap. In phase B
# every live entry goes back to NEW, then OLD's entries go back to DIR; in
# phase A only OLD's go back. Returns 1 at the first failed rename.
roll_back() {
	if [ "$5" = B ]; then
		move_entries "$1" "$2" "$3" || return 1
	fi
	move_entries "$1" "$4" "$2"
}

# refuse REASON — a <3> refused line, exit 1. Nothing has been changed.
refuse() {
	outcome_log 3 "outcome=refused reason=\"$1\""
	exit 1
}

# copy_failed STEP — remove both copies, a <3> failed line, exit 1.
copy_failed() {
	rm -rf "$DNEW" "$SNEW" 2>/dev/null
	outcome_log 3 "outcome=failed reason=\"Copying the staged restore failed at the step that $1, so the restore was not applied; the store's data and seal key were not changed.\""
	exit 1
}

# swap_failed WHAT DATA_PHASE SEAL_PHASE — roll back what the swap reached,
# then a failed line and exit 1. A phase is -, A or B.
swap_failed() {
	rm -f "$MARK_TMP" 2>/dev/null
	_ok=0
	if [ "$3" != - ]; then
		roll_back seal "$SEAL" "$SNEW" "$SOLD" "$3" || _ok=1
	fi
	if [ "$_ok" = 0 ] && [ "$2" != - ]; then
		roll_back data "$DATA" "$DNEW" "$DOLD" "$2" || _ok=1
	fi
	if [ "$_ok" = 0 ]; then
		rm -rf "$DNEW" "$DOLD" "$SNEW" "$SOLD" 2>/dev/null
		outcome_log 3 "outcome=failed reason=\"$1 failed, so the restore was not applied; the old data and seal key were put back.\""
	else
		outcome_log 2 "outcome=failed reason=\"$1 failed, and putting the old data and seal key back failed too, so the work directories $DOLD and $SOLD are left and the store will not start. $REFLASH\""
	fi
	exit 1
}

# --- 1. nothing staged --------------------------------------------------------
present "$PENDING" || exit 0

# --- 2. already applied -------------------------------------------------------
if present "$MARK"; then
	remove_work
	exit 0
fi

# --- 3. an interrupted swap ---------------------------------------------------
for _w in "$DOLD" "$SOLD"; do
	present "$_w" && refuse "An earlier apply of the staged restore was interrupted and left $_w, so nothing was changed and the store will not start. $REFLASH"
done

# --- 4. the staged members ----------------------------------------------------
if [ -L "$PENDING/data" ]; then
	refuse "The staged member $PENDING/data is a symbolic link, so the restore was not applied and nothing was changed."
elif ! present "$PENDING/data"; then
	refuse "The staged member $PENDING/data is missing, so the restore was not applied and nothing was changed."
elif [ ! -d "$PENDING/data" ]; then
	refuse "The staged member $PENDING/data is not a directory, so the restore was not applied and nothing was changed."
fi
for _m in seal-key seal.hcl; do
	if [ -L "$PENDING/$_m" ]; then
		refuse "The staged member $PENDING/$_m is a symbolic link, so the restore was not applied and nothing was changed."
	elif ! present "$PENDING/$_m"; then
		refuse "The staged member $PENDING/$_m is missing, so the restore was not applied and nothing was changed."
	elif [ ! -f "$PENDING/$_m" ]; then
		refuse "The staged member $PENDING/$_m is not a regular file, so the restore was not applied and nothing was changed."
	fi
done

# --- 5. copy in ---------------------------------------------------------------
# The data directory's own owner, read the way the at-rest audit reads it, so
# no id is written here.
_owner=$(ls -ldn "$DATA" 2>/dev/null | awk 'NR == 1 { print $3 ":" $4 }')
case "$_owner" in
	[0-9]*:[0-9]*) ;;
	*) copy_failed "reads the owner of $DATA" ;;
esac
rm -rf "$DNEW" "$SNEW" 2>/dev/null
present "$DNEW" && copy_failed "removes the leftover $DNEW"
present "$SNEW" && copy_failed "removes the leftover $SNEW"
# The directory itself is copied, not its entries, so its dotfiles come too.
cp -R -p "$PENDING/data" "$DNEW" || copy_failed "copies the data into $DNEW"
chown -R "$_owner" "$DNEW" || copy_failed "gives $DNEW the owner of $DATA"
{ mkdir "$SNEW" && cp -p "$PENDING/seal-key" "$PENDING/seal.hcl" "$SNEW/"; } \
	|| copy_failed "copies the seal key and fragment into $SNEW"
sync || copy_failed "syncs the copies to disk"

# --- 6. swap ------------------------------------------------------------------
mkdir "$DOLD" || swap_failed "Making the work directory $DOLD" - -
move_entries data "$DATA" "$DOLD" || swap_failed "Moving the old data aside into $DOLD" A -
move_entries data "$DNEW" "$DATA" || swap_failed "Moving the restored data into $DATA" B -
mkdir "$SOLD" || swap_failed "Making the work directory $SOLD" B -
move_entries seal "$SEAL" "$SOLD" || swap_failed "Moving the old seal key and fragment aside into $SOLD" B A
move_entries seal "$SNEW" "$SEAL" || swap_failed "Moving the restored seal key and fragment into $SEAL" B B

# --- 7. commit ----------------------------------------------------------------
# A subshell, because a failed redirection on a special built-in ends a
# non-interactive shell.
{ sync && (: > "$MARK_TMP") 2>/dev/null && chmod 600 "$MARK_TMP" && mv -f "$MARK_TMP" "$MARK" && sync; } \
	|| swap_failed "Writing the marker $MARK" B B

# --- 8. clean up --------------------------------------------------------------
remove_work
outcome_log 6 "outcome=applied reason=\"The restored store data, seal key and seal fragment are in place, so the store starts on them.\""
exit 0
