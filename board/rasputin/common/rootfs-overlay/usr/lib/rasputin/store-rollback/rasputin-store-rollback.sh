#!/bin/sh
#
# rasputin-store-rollback.sh — the secrets store's version gate
# (geekdojo/geekdojo-brain#801; ADR-0010). openbao.service runs it as its
# second ExecStartPre=, after the staged-restore step and before the self-init
# hook's pre, with `+` (root, outside the store's sandbox) and WITHOUT `-`: a
# refused or failed gate fails the store's start, so bao never runs.
#
# WHY. A RAUC fallback puts the previous slot's store binary back on data the
# newer binary may already have written. An older store on newer data is not a
# state anyone has tested, so this gate compares the data's version with the
# binary's on every start. It does nothing when the data is not newer. When
# the data is newer and #800's pre-update copy is at this binary's version, it
# puts that copy back before bao starts. Otherwise it holds the store stopped
# and writes nothing into the data directory.
#
# THE MARKER AND THE HOLD. The store cannot report its version before it
# unseals, so this gate writes it on the store's behalf, before bao starts:
#   /var/lib/rasputin/openbao-version       the version that last wrote the
#                                           data, one line X.Y.Z, 0600 root
#   /var/lib/rasputin/openbao-version-hold  a staged backup's version, newer
#                                           than this binary, 0600 root
# The marker is beside the data directory, not in it: the data directory is
# bao's and is copied as-is into backups and the pre-update copy. Written
# before bao starts, the marker can overstate the version that wrote the data
# but never understate it. While the hold exists the pre-update copy is never
# used: that data came from a backup, not from an update, so the copy predates
# it. The first start that finds the data not newer than the binary removes
# the hold.
#
# THE DECISION, in order. Each step ends in exactly one outcome:
#   1  the binary's version, from the first line of `bao version`
#      ("OpenBao vX.Y.Z (...)"); unreadable or unparseable: failed
#   2  work directories: a leftover .rasputin-rollback-new alone is removed.
#      A leftover .rasputin-rollback-old with a marker newer than the binary
#      is an interrupted swap: failed, nothing changed. With any other marker
#      the commit had happened (it writes the binary's version), so both are
#      removed and the gate goes on
#   3  the data directory, listed with `ls -A`: unlistable is failed; empty
#      is current, with the marker written as the binary's version
#   4  a staged backup just applied (restore-pending/store/applied): its
#      openbao-version unparseable is failed; not newer is current with the
#      marker as the binary's version; newer writes the marker and the hold as
#      the staged version and is refused
#   5  data and no marker: data last written by a release without this gate,
#      all of which pin the same store version; adopted, current
#   6  the marker unparseable: failed
#   7  equal: current. Older: the marker updated, current. Newer with the
#      hold: refused. Newer without it: step 8
#   8  #800's copy, /var/lib/rasputin/openbao-preupdate.tar, read with
#      tar -xOf store/openbao-version: missing, unusable, or another version
#      is refused; this binary's version is restored, as below
# Versions are three dot-separated decimal components of 1 to 9 digits,
# compared numerically; any test that errors fails closed.
#
# THE RESTORE. The live data is first written aside to
# openbao-rolled-back.tar (a .partial, synced, then renamed); the copy is
# unpacked into openbao/.rasputin-rollback-new, given the data directory's
# owner and synced; then the shared same-mount swap (store-swap/swap.sh) moves
# every live entry into .rasputin-rollback-old and every entry of the copy's
# store/data into place, and the marker is committed as the copy's version.
# A failed rename puts everything back. The work directories are removed
# last. The copy itself is never modified or deleted.
#
# STABLE CONTRACT. Readers depend on these; they do not change without them:
#
#   The journal and console line, one per run (read by the bench skill and
#   by test/store-unit-functional.sh):
#     rasputin-store-rollback: outcome=<current|restored|refused|failed> reason="<sentence>"
#   on stdout with a syslog priority prefix (<6> current, <4> restored, <2>
#   refused, <3> failed, <2> a failed swap whose rollback failed too), and the
#   same line on /dev/kmsg. A cleanup that fails after the commit is an extra
#   <4> line. Lines carry versions, paths and sentences, never store contents.
#
#   The outcome record (read by the api's outcome reader, #833):
#     /run/rasputin-store-rollback/outcome   0600 root, tmpfs: THIS BOOT ONLY
#   exactly three lines, each KEY=VALUE, the value everything after the first =:
#     outcome=<current|restored|refused|failed>
#     boot_id=<the kernel's boot_id for this boot, or - if unreadable>
#     reason=<one English sentence, starting with a capital, ending with ".">
#   written to a temp file and renamed. current is written only when no
#   record exists yet this boot, so a later start in the same boot never
#   clears a restored, refused or failed record; those three always overwrite.
#
# EXIT STATUS. 0 for current and restored; 1 for refused and failed.
#
# COLLABORATORS arrive as environment variables with production defaults, so
# the tests can point every one at a scratch tree. The unit sets none.
set -u

PERSIST="${RASPUTIN_STOREROLLBACK_PERSIST:-/var/lib/rasputin}"
RUN="${RASPUTIN_STOREROLLBACK_RUN:-/run/rasputin-store-rollback}"
BAO="${RASPUTIN_STOREROLLBACK_BAO:-/usr/bin/bao}"
BOOTID_SRC="${RASPUTIN_STOREROLLBACK_BOOTID:-/proc/sys/kernel/random/boot_id}"

umask 077

OUTCOME_TAG=rasputin-store-rollback
OUTCOME_KMSG="${RASPUTIN_STOREROLLBACK_KMSG:-/dev/kmsg}"
. "$(dirname "$0")/../outcome/outcome.sh"
# present, move_entries and roll_back, shared with rasputin-store-restore.sh.
. "$(dirname "$0")/../store-swap/swap.sh"

DATA="$PERSIST/openbao"
MARKER="$PERSIST/openbao-version"
MARKER_TMP="$PERSIST/.openbao-version.new"
HOLD="$PERSIST/openbao-version-hold"
HOLD_TMP="$PERSIST/.openbao-version-hold.new"
COPY="$PERSIST/openbao-preupdate.tar"
ASIDE="$PERSIST/openbao-rolled-back.tar"
ASIDE_TMP="$ASIDE.partial"
STAGED="$PERSIST/restore-pending/store"
DNEW="$DATA/.rasputin-rollback-new"
DOLD="$DATA/.rasputin-rollback-old"
RECORD="$RUN/outcome"
RECORD_TMP="$RUN/.outcome.new"
NL='
'
TRANSIENT="The store starts once the cause is fixed and the store is restarted, or on the next reboot."

# finish OUTCOME PRIORITY REASON — write the record (current only when none
# exists this boot), log the line, and exit 0 for current and restored, 1
# otherwise. A failed record write is logged by outcome_record; the line still
# goes out.
finish() {
	mkdir -p "$RUN" 2>/dev/null
	if [ "$1" != current ] || ! present "$RECORD"; then
		outcome_record "$RECORD" "$RECORD_TMP" "outcome=$1" \
			"boot_id=$(outcome_boot_id "$BOOTID_SRC")" "reason=$3" || :
	fi
	outcome_log "$2" "outcome=$1 reason=\"$3\""
	case "$1" in current|restored) exit 0 ;; esac
	exit 1
}
failed() { finish failed 3 "$1"; }

# valid_version STRING — STRING is X.Y.Z, each 1 to 9 decimal digits. A
# second line, a sign, a v prefix or a fourth component is refused.
valid_version() {
	case "$1" in
		'' | *[!0-9.]* | .* | *. | *..*) return 1 ;;
	esac
	_vv_ifs=$IFS
	IFS=.
	# shellcheck disable=SC2086 # split on the dots, on purpose; digits only
	set -- $1
	IFS=$_vv_ifs
	[ "$#" -eq 3 ] || return 1
	for _vv_c in "$@"; do
		[ "${#_vv_c}" -le 9 ] || return 1
	done
	return 0
}

# part_cmp A B — newer, older or equal for one component; error when the
# test itself fails, so nothing undecided reads as equal.
part_cmp() {
	if [ "$1" -gt "$2" ] 2>/dev/null; then
		echo newer
	elif [ "$1" -lt "$2" ] 2>/dev/null; then
		echo older
	elif [ "$1" -eq "$2" ] 2>/dev/null; then
		echo equal
	else
		echo error
	fi
}

# ver_cmp A B — whether version A is newer, older or equal to B, or error.
# Both have passed valid_version.
ver_cmp() {
	_vc_ifs=$IFS
	IFS=.
	# shellcheck disable=SC2086 # split on the dots, on purpose; digits only
	set -- $1 $2
	IFS=$_vc_ifs
	[ "$#" -eq 6 ] || { echo error; return 0; }
	for _vc_r in "$(part_cmp "$1" "$4")" "$(part_cmp "$2" "$5")" "$(part_cmp "$3" "$6")"; do
		[ "$_vc_r" = equal ] || { echo "$_vc_r"; return 0; }
	done
	echo equal
}

# write_version FILE TMP VALUE — FILE holds the one line VALUE, through TMP,
# mv and sync. A FILE already holding VALUE is left alone. Returns 1 on any
# failure, with TMP removed. A subshell for the redirection, because a failed
# redirection on a special built-in ends a non-interactive shell.
write_version() {
	if [ -f "$1" ] && [ "$(cat "$1" 2>/dev/null)" = "$3" ]; then
		return 0
	fi
	if ! { rm -f "$2" && (printf '%s\n' "$3" > "$2") && chmod 600 "$2" && mv -f "$2" "$1" && sync; } 2>/dev/null; then
		rm -f "$2" 2>/dev/null
		return 1
	fi
	return 0
}

# set_marker VALUE — the marker holds VALUE, or the run is failed.
set_marker() {
	write_version "$MARKER" "$MARKER_TMP" "$1" \
		|| failed "Writing the secrets store's version marker $MARKER failed, so it was not changed and the store will not start. $TRANSIENT"
}

# drop_hold — no hold is left, or the run is failed.
drop_hold() {
	present "$HOLD" || return 0
	rm -f "$HOLD" 2>/dev/null
	present "$HOLD" \
		&& failed "Removing the secrets store's version hold $HOLD failed, so nothing else was changed and the store will not start. $TRANSIENT"
	return 0
}

# refuse_staged V — a staged backup's data, version V, is newer than this
# binary: held stopped.
refuse_staged() {
	finish refused 2 "The restored backup's secrets store data was written by version $1, newer than this image's $B, so the store was not started and the restored data was left untouched. Reflash with a release whose secrets store is version $1 or later and restore this backup again, or restore a backup taken on this release."
}

# refuse_copy WHY — the data is newer than this binary and there is no usable
# copy; WHY names which.
refuse_copy() {
	finish refused 2 "The secrets store's data was written by version $V, newer than this image's $B, and there is no usable copy for $B ($1), so the store was not started and its data was left untouched. Reflash this control plane with a release whose secrets store is version $V or later, then restore the latest backup."
}

# swap_failed WHAT PHASE — roll the swap back from PHASE (-, A or B), then a
# failed line: <3> when everything was put back, <2> when it was not.
swap_failed() {
	rm -f "$MARKER_TMP" 2>/dev/null
	if [ "$2" = - ] || roll_back data "$DATA" "$DNEW/store/data" "$DOLD" "$2"; then
		rm -rf "$DNEW" "$DOLD" 2>/dev/null
		finish failed 3 "$1 failed, so the secrets store's data was not rolled back; the newer data was put back and nothing else was changed. $TRANSIENT"
	fi
	finish failed 2 "$1 failed, and putting the newer data back failed too, so the work directories $DNEW and $DOLD are left and the store will not start. Reflash this control plane and restore the latest backup; the data from before the rollback is in $ASIDE."
}

# --- 1. the binary's version --------------------------------------------------
_bv=$("$BAO" version 2>/dev/null) \
	|| failed "The secrets store binary's version could not be read, so nothing was changed and the store will not start."
_line=${_bv%%"$NL"*}
case "$_line" in
	"OpenBao v"*) B=${_line#OpenBao v}; B=${B%% *} ;;
	*) B="" ;;
esac
valid_version "$B" \
	|| failed "The secrets store binary printed a version that could not be parsed, so nothing was changed and the store will not start."

# The marker, read once. $(cat) drops a trailing newline, present or not.
M=""
M_PRESENT=0
if present "$MARKER"; then
	M_PRESENT=1
	M=$(cat "$MARKER" 2>/dev/null) || M=""
fi

# --- 2. work directories -------------------------------------------------------
if present "$DOLD"; then
	if [ "$M_PRESENT" = 1 ] && valid_version "$M" && [ "$(ver_cmp "$M" "$B")" = newer ]; then
		failed "An earlier rollback of the secrets store's data was interrupted and left $DOLD, so nothing was changed and the store will not start. Reflash this control plane and restore the latest backup; the data from before the rollback is in $ASIDE."
	fi
	rm -rf "$DNEW" "$DOLD" 2>/dev/null
	if present "$DNEW" || present "$DOLD"; then
		failed "Removing the work directories $DNEW and $DOLD left by a completed rollback failed, so nothing else was changed and the store will not start. $TRANSIENT"
	fi
fi
if present "$DNEW"; then
	rm -rf "$DNEW" 2>/dev/null
	present "$DNEW" \
		&& failed "Removing the work directory $DNEW left by an earlier rollback failed, so nothing else was changed and the store will not start. $TRANSIENT"
fi

# --- 3. data present? ----------------------------------------------------------
_entries=$(ls -A -- "$DATA" 2>/dev/null) \
	|| failed "The secrets store's data directory $DATA could not be listed, so nothing was changed and the store will not start. $TRANSIENT"
if [ -z "$_entries" ]; then
	set_marker "$B"
	drop_hold
	finish current 6 "The secrets store's data directory is empty, so the store initialises itself at version $B."
fi

# --- 4. a staged backup just applied ------------------------------------------
if present "$STAGED/applied"; then
	S=$(cat "$STAGED/openbao-version" 2>/dev/null) || S=""
	valid_version "$S" \
		|| failed "The restored backup's secrets store version in $STAGED/openbao-version could not be read or parsed, so nothing was changed and the store will not start."
	case "$(ver_cmp "$S" "$B")" in
		newer)
			set_marker "$S"
			write_version "$HOLD" "$HOLD_TMP" "$S" \
				|| failed "Writing the secrets store's version hold $HOLD failed, so the store will not start. $TRANSIENT"
			refuse_staged "$S"
			;;
		equal | older)
			set_marker "$B"
			drop_hold
			finish current 6 "The restored backup's secrets store data was written by version $S, not newer than this image's $B, so the store starts on it."
			;;
		*) failed "Comparing the restored backup's secrets store version with this image's failed, so nothing was changed and the store will not start." ;;
	esac
fi

# --- 5. data, and no marker ----------------------------------------------------
if [ "$M_PRESENT" = 0 ]; then
	set_marker "$B"
	finish current 6 "The secrets store's data has no version marker, so it was last written by a release without this check, and it is recorded as version $B."
fi

# --- 6. the data's version -----------------------------------------------------
valid_version "$M" \
	|| failed "The secrets store's version marker $MARKER could not be read or parsed, so nothing was changed and the store will not start."
V=$M

# --- 7. compare ----------------------------------------------------------------
case "$(ver_cmp "$V" "$B")" in
	equal)
		drop_hold
		finish current 6 "The secrets store's data was written by version $V, this image's version, so nothing was changed."
		;;
	older)
		set_marker "$B"
		drop_hold
		finish current 6 "The secrets store's data was written by version $V, older than this image's $B, so the store starts on it and the marker now says $B."
		;;
	newer)
		present "$HOLD" && refuse_staged "$V"
		;;
	*) failed "Comparing the secrets store's data version with this image's failed, so nothing was changed and the store will not start." ;;
esac

# --- 8. the pre-update copy ----------------------------------------------------
present "$COPY" || refuse_copy "$COPY does not exist"
[ -r "$COPY" ] || refuse_copy "$COPY cannot be read"
tar -tf "$COPY" > /dev/null 2>&1 || refuse_copy "$COPY is not a readable archive"
_cv=$(tar -xOf "$COPY" store/openbao-version 2>/dev/null) \
	|| refuse_copy "$COPY has no store/openbao-version"
valid_version "$_cv" || refuse_copy "the version in $COPY could not be parsed"
[ "$_cv" = "$B" ] || refuse_copy "$COPY is for version $_cv"

# --- restore 1. keep the newer data aside ---------------------------------------
# Only a complete new aside copy ever replaces the previous one.
if ! { rm -f "$ASIDE_TMP" && tar -cf "$ASIDE_TMP" -C "$DATA" . && sync && mv -f "$ASIDE_TMP" "$ASIDE" && sync; }; then
	rm -f "$ASIDE_TMP" 2>/dev/null
	failed "Writing the newer secrets store data aside to $ASIDE failed, so the data was not rolled back and nothing was changed. $TRANSIENT"
fi

# --- restore 2. unpack the copy ---------------------------------------------------
# The data directory's own owner, read the way the at-rest audit reads it, so
# no id is written here. The copy has no directory members; tar makes the
# leading directories itself.
_owner=$(ls -ldn "$DATA" 2>/dev/null | awk 'NR == 1 { print $3 ":" $4 }')
case "$_owner" in
	[0-9]*:[0-9]*) ;;
	*) failed "Reading the owner of $DATA failed, so the data was not rolled back; the newer data is kept in $ASIDE and nothing else was changed. $TRANSIENT" ;;
esac
if ! { mkdir "$DNEW" && tar -xf "$COPY" -C "$DNEW" && [ -d "$DNEW/store/data" ] && chown -R "$_owner" "$DNEW" && sync; }; then
	rm -rf "$DNEW" 2>/dev/null
	failed "Unpacking the copy $COPY into $DNEW failed, so the data was not rolled back; the newer data is kept in $ASIDE and nothing else was changed. $TRANSIENT"
fi

# --- restore 3. swap -------------------------------------------------------------
mkdir "$DOLD" || swap_failed "Making the work directory $DOLD" -
move_entries data "$DATA" "$DOLD" || swap_failed "Moving the newer data aside into $DOLD" A
move_entries data "$DNEW/store/data" "$DATA" || swap_failed "Moving the copy's data into $DATA" B

# --- restore 4. commit -------------------------------------------------------------
write_version "$MARKER" "$MARKER_TMP" "$_cv" || swap_failed "Writing the version marker $MARKER" B

# --- restore 5. clean up -----------------------------------------------------------
rm -rf "$DNEW" "$DOLD" 2>/dev/null
if present "$DNEW" || present "$DOLD"; then
	outcome_log 4 "The work directories $DNEW and $DOLD are left from a completed rollback and could not be removed, so the next start of the store removes them."
fi
finish restored 4 "The secrets store's data was written by version $V, newer than this image's $B, so the copy taken before the update was put back. Secrets written since that update are gone from the store; the newer data is kept in $ASIDE."
