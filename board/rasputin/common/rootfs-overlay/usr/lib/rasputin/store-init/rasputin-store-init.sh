#!/bin/sh
#
# rasputin-store-init.sh — record whether the secrets store's self-init
# succeeded or failed (geekdojo/geekdojo-brain#804; ADR-0010 S9). It reports;
# it never gates: openbao.service runs it with the `-` prefix, so nothing it
# does fails the store.
#
# WHAT SELF-INIT IS. bao runs the init.json stanzas once, on a store whose
# core is not initialised, and on a failure exits before READY. A failure after
# its self-init marker leaves a store that refuses to unseal on every later
# start (#680 Q1, Q8). bao itself logs the failure at ERROR; this script turns
# the start into one outcome line on the console and one record a reader can
# parse, because nothing else in the image says it happened.
#
# THE FACTS IT USES, in openbao.service's order. No timer, no journal parse:
#   pre      ExecStartPre=-+…  The data directory is listed with `ls -A` (its
#            exit status checked, as rasputin-seal-key.sh does). Empty: this
#            start will self-init, so the pending marker is written. Not
#            empty: any stale marker is removed and nothing is written.
#   started  ExecStartPost=-+…  Runs after READY. On a store that started
#            empty, READY comes only after self-init has finished, so a pending
#            marker here means it succeeded: outcome=initialised.
#   stopped  ExecStopPost=-+…  A pending marker still there means the start
#            that began empty ended before READY: outcome=failed, naming
#            systemd's SERVICE_RESULT and EXIT_STATUS.
# Without a pending marker, started and stopped write nothing. So a start on an
# already initialised store prints no rasputin-store-init: line at all, which
# is the bench's "already initialised" fact (rasputin-secrets-store-test).
#
# STABLE CONTRACT. Readers depend on these; they do not change without them:
#
#   The journal and console line, one per recorded outcome (read by the bench
#   skill, and by test/boot-smoke.sh from the serial console):
#     rasputin-store-init: outcome=<initialised|failed> reason="<sentence>"
#   on stdout with a syslog priority prefix (<6> initialised, <3> failed), and
#   the same line on /dev/kmsg so it reaches every console.
#
#   The outcome record (read by the api's outcome reader, #833):
#     /run/rasputin-store-init/outcome   0600 root, tmpfs: THIS BOOT ONLY
#   exactly three lines, each KEY=VALUE, the value everything after the first =:
#     outcome=<initialised|failed>
#     boot_id=<the kernel's boot_id for this boot, or - if unreadable>
#     reason=<one English sentence, starting with a capital, ending with ".">
#   written to a temp file and renamed, so a reader never sees half of it.
#   A failed record is not overwritten by a later start in the same boot
#   unless that start again finds the data directory empty and initialises.
#
# EXIT STATUS. 0, or 2 for an unknown phase. The unit ignores both.
#
# COLLABORATORS arrive as environment variables with production defaults, so
# the tests can point every one at a scratch tree. The unit sets none.
set -u

RUN="${RASPUTIN_STOREINIT_RUN:-/run/rasputin-store-init}"
DATA="${RASPUTIN_STOREINIT_DATA:-/var/lib/rasputin/openbao}"
BOOTID_SRC="${RASPUTIN_STOREINIT_BOOTID:-/proc/sys/kernel/random/boot_id}"
PENDING="$RUN/pending"
RECORD="$RUN/outcome"
RECORD_TMP="$RUN/.outcome.new"

umask 077

# The log line and the record writer, shared with rasputin-seal-key.sh:
# /usr/lib/rasputin/outcome/outcome.sh, found beside this script's directory so
# a test runs the overlay's copy.
OUTCOME_TAG=rasputin-store-init
OUTCOME_KMSG="${RASPUTIN_STOREINIT_KMSG:-/dev/kmsg}"
. "$(dirname "$0")/../outcome/outcome.sh"

# record OUTCOME PRIORITY REASON — write the record, clear the marker, log the
# line. A failed record write is logged by outcome_record; the line still goes
# out. A marker that cannot be removed is said, because a later stop would
# record a second outcome for this start.
record() {
	outcome_record "$RECORD" "$RECORD_TMP" "outcome=$1" \
		"boot_id=$(outcome_boot_id "$BOOTID_SRC")" "reason=$3" || :
	if ! rm -f "$PENDING" 2>/dev/null || [ -e "$PENDING" ]; then
		outcome_log 4 "The marker $PENDING could not be removed, so a later stop of the store may record a second outcome for this start."
	fi
	outcome_log "$2" "outcome=$1 reason=\"$3\""
}

case "${1:-}" in
	pre)
		# The unit gives this script no RuntimeDirectory= (the store's own
		# runtime directory would be the store user's); by hand or in a test it
		# may not exist either.
		mkdir -p "$RUN" 2>/dev/null
		if ! entries=$(ls -A -- "$DATA" 2>/dev/null); then
			rm -f "$PENDING" 2>/dev/null
			outcome_log 4 "The store's data directory $DATA could not be listed, so whether this start initialises the store will not be recorded."
			exit 0
		fi
		if [ -n "$entries" ]; then
			# Best effort, its error dropped on purpose: a stale marker can only
			# come from a stop hook that could not remove it, which logged that.
			rm -f "$PENDING" 2>/dev/null
			exit 0
		fi
		# A subshell, because a failed redirection on a special built-in ends a
		# non-interactive shell (as in rasputin-seal-key.sh).
		if ! (: > "$PENDING") 2>/dev/null; then
			outcome_log 4 "The marker $PENDING could not be written, so whether this start initialises the store will not be recorded."
		fi
		;;
	started)
		[ -e "$PENDING" ] || exit 0
		record initialised 6 "The secrets store initialised itself on its first start, from the image's configuration."
		;;
	stopped)
		[ -e "$PENDING" ] || exit 0
		_why="service result ${SERVICE_RESULT:-unknown}, status ${EXIT_STATUS:-unknown}"
		# Still listable and empty: bao never wrote its marker, so the next start
		# self-inits again. Anything else, unlistable included, is the case
		# that refuses to unseal, which is the one an operator must act on.
		if entries=$(ls -A -- "$DATA" 2>/dev/null) && [ -z "$entries" ]; then
			record failed 3 "The secrets store's first start ended before it was initialised ($_why). Its data directory is still empty, so the next start initialises it again."
		else
			record failed 3 "The secrets store's first start ended before it was initialised ($_why), and it will refuse to unseal until its data directory is cleared."
		fi
		;;
	*)
		outcome_log 3 "rasputin-store-init.sh was run with '${1:-}' instead of pre, started or stopped, so nothing was recorded."
		exit 2
		;;
esac
exit 0
