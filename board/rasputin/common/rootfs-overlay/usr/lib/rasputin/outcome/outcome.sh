#!/bin/sh
#
# outcome.sh — the log line and the outcome record the boot-time outcome
# scripts share: rasputin-seal-key.sh (geekdojo/geekdojo-brain#803) and
# rasputin-store-init.sh (#804). Sourced, never run. Extracted from
# rasputin-seal-key.sh's log and finish, so each script keeps only its own
# decision and its own record's fields.
#
# The caller sets, before calling anything here:
#   OUTCOME_TAG    the line's tag, for example rasputin-seal-key
#   OUTCOME_KMSG   the console sink, /dev/kmsg on a node
#
#   outcome_log PRIORITY LINE
#       Prints "<PRIORITY>TAG: LINE" on stdout (the journal, where systemd turns
#       the <N> prefix into PRIORITY) and the same line on OUTCOME_KMSG (every
#       console= device). The line on stdout is in the journal either way, so a
#       console that cannot be written changes nothing else: a <4> sentence on
#       stderr (also the journal) says the console missed it.
#
#   outcome_boot_id SRC
#       Prints the boot id read from SRC, or - when it cannot be read or is
#       empty.
#
#   outcome_record RECORD TMP LINE...
#       Writes each LINE, one per line, to TMP at mode 0600 and renames it to
#       RECORD, so a reader never sees half a record. On any failure it removes
#       TMP, logs a <3> sentence that only the journal line carries the outcome,
#       and returns 1. The caller still logs its outcome line.
#
# The caller sets its own umask; these functions create nothing but TMP.

outcome_log() {
	printf '<%s>%s: %s\n' "$1" "$OUTCOME_TAG" "$2"
	# 2>/dev/null first: a redirection that fails reports on the stderr in force
	# when it is tried, and the sentence below already says what happened.
	printf '<%s>%s: %s\n' "$1" "$OUTCOME_TAG" "$2" 2>/dev/null > "$OUTCOME_KMSG" \
		|| printf '<4>%s: The log line could not be written to %s, so the console did not get it.\n' "$OUTCOME_TAG" "$OUTCOME_KMSG" >&2
}

outcome_boot_id() {
	_ob_id=$(cat "$1" 2>/dev/null) || _ob_id=""
	[ -n "$_ob_id" ] || _ob_id=-
	printf '%s\n' "$_ob_id"
}

outcome_record() {
	_or_rec=$1 _or_tmp=$2
	shift 2
	if ! { rm -f "$_or_tmp" \
		&& printf '%s\n' "$@" > "$_or_tmp" \
		&& chmod 600 "$_or_tmp" \
		&& mv -f "$_or_tmp" "$_or_rec"; } 2>/dev/null; then
		# Best effort, its error dropped on purpose: the failure is logged on the
		# next line, no reader opens the temp name (only the record's), it is on
		# tmpfs, and the next write starts by removing it.
		rm -f "$_or_tmp" 2>/dev/null
		outcome_log 3 "The outcome record $_or_rec could not be written, so only this journal line carries the outcome."
		return 1
	fi
	return 0
}
