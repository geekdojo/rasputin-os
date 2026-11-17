#!/bin/sh
#
# rasputin-keycloak-hooks.sh — keycloak.service's three hooks
# (geekdojo/geekdojo-brain#973), written to the #979 file contract the api's
# identity monitor reads. Each runs as root outside the unit's sandbox (`+`).
#
#   hold   ExecStartPre=+   The start-failure hold. Counts the starts that
#                           never reached /health/started and refuses the
#                           fourth in a row, writing the hold record.
#   wait   ExecStartPost=+  The start wait. Ends the start when
#                           /health/started answers UP over mutual TLS, so
#                           `active` means Keycloak has started.
#   exit   ExecStopPost=-+  The exit record of every invocation that ran.
#
# THE FACTS IT USES. No timer decides anything here (ARCH-FACTS):
#   * NRestarts=0 at hold means this start was asked for, not an automatic
#     restart: systemd clears the counter on every non-automatic start and on
#     reset-failed, and raises it on each automatic restart (systemd 258.7
#     service.c:2990-2991, :5263, :2664). That fact re-arms the hold.
#   * /health/started answering UP ends the wait with success; MainPID no
#     longer being the $MAINPID systemd handed the wait ends it with failure.
#     The 1 s tick between asks only re-asks (Keycloak pushes nothing); the
#     unit's TimeoutStartSec= is the outer bound on the whole start.
#
# EVERY SOURCE OF A RE-ARM (F-973-04). Any non-automatic start re-arms the
# hold, because NRestarts reads 0 at its ExecStartPre=:
#   * a boot, an update's reboot included;
#   * the api's reset-failed and restart on a new identity leaf;
#   * identity.restart;
#   * identity.recover after a full disk (#979);
#   * the backup's and the update copy's `systemctl stop keycloak-db.service`,
#     then `systemctl start keycloak.service`;
#   * a Wants=keycloak.service pull from the api's own start, once Identity 2.6
#     adds one;
#   * a restart that Requires= propagates from a database restart, the
#     database's own automatic restart included (service.c:2643-2654).
# The cost of each under a persistent fault: at most three more JVM starts
# (11 to 80 s each, as measured by #957), and the hold record is removed and
# comes back on the third failure, so #979's held alert clears and returns
# around each such start. Bounded and stated, not prevented. A manual start
# inside systemd's 100 ms automatic-restart window counts as an automatic
# restart, not a re-arm (service.c:2966-2972).
#
# STABLE CONTRACT (#979, read by the api; it does not change without it):
#   /var/lib/rasputin/identity/start-failures   0600 root, one decimal line:
#       the starts in a row that have not reached /health/started. Only this
#       script writes or removes it.
#   /run/rasputin-identity-start-hold/outcome   0600 root, in a 0700 root
#       directory, exactly three lines: outcome=refused, boot_id=<this boot>,
#       reason=<one sentence>. Written once per hold, from the exit record of
#       the last start that ran the JVM; only a re-arm removes it.
#   /run/rasputin-identity-exits/<INVOCATION_ID>   0600 root, in a 0700 root
#       directory, exactly outcome=, invocation_id=, exit_code=, exit_status=.
#       Written to <id>.tmp and renamed, then `last` (the id) the same way. At
#       most 256 records: the oldest written are removed first, never the one
#       `last` names, never `last` or a .tmp file.
#
# EXIT STATUS. hold: 0 to start, 1 to refuse. wait: 0 on UP, 1 on a missing
# input or the main process gone, 143 on SIGTERM, which the unit's
# SuccessExitStatus=143 counts as clean for a control command too
# (service.c:4022-4029), so a stop during start-post ends `success`
# (F-973-02). exit: always 0 (the unit ignores it anyway). 2 for an unknown
# phase.
#
# COLLABORATORS arrive as environment variables with production defaults, so
# the tests can point every one at a scratch tree. The unit sets none.
# No key byte and no /health response body is ever logged (LOG-SECRETS): curl
# gets paths only.
set -u

SYSTEMCTL="${RASPUTIN_KCHOOK_SYSTEMCTL:-/usr/bin/systemctl}"
CURL="${RASPUTIN_KCHOOK_CURL:-/usr/bin/curl}"
UNIT="${RASPUTIN_KCHOOK_UNIT:-keycloak.service}"
COUNT="${RASPUTIN_KCHOOK_COUNT:-/var/lib/rasputin/identity/start-failures}"
HOLD_DIR="${RASPUTIN_KCHOOK_HOLD_DIR:-/run/rasputin-identity-start-hold}"
EXITS_DIR="${RASPUTIN_KCHOOK_EXITS_DIR:-/run/rasputin-identity-exits}"
CA="${RASPUTIN_KCHOOK_CA:-/var/lib/rasputin/trust/identity-ca.pem}"
CERT="${RASPUTIN_KCHOOK_CERT:-/var/lib/rasputin/tls/identity-db-client/leaf.pem}"
KEY="${RASPUTIN_KCHOOK_KEY:-/var/lib/rasputin/tls/identity-db-client/leaf.key}"
URL="${RASPUTIN_KCHOOK_URL:-https://127.0.0.1:8544/health/started}"
BOOTID_SRC="${RASPUTIN_KCHOOK_BOOTID:-/proc/sys/kernel/random/boot_id}"
RECHECK="${RASPUTIN_KCHOOK_RECHECK:-1}"
HOLD="$HOLD_DIR/outcome"
# The most starts in a row that may fail before the hold refuses the next.
LIMIT=3
# The most exit records kept (#979 contract §3).
CAP=256

umask 077

OUTCOME_TAG=rasputin-keycloak-hooks
OUTCOME_KMSG="${RASPUTIN_KCHOOK_KMSG:-/dev/kmsg}"
# shellcheck source=SCRIPTDIR/../outcome/outcome.sh
. "$(dirname "$0")/../outcome/outcome.sh"

# write_count N — N to the count file, through a temp file and a rename, 0600.
# A subshell, because a failed redirection ends a non-interactive shell.
write_count() {
	(printf '%s\n' "$1" > "$COUNT.tmp") 2>/dev/null \
		&& chmod 600 "$COUNT.tmp" 2>/dev/null \
		&& mv -f "$COUNT.tmp" "$COUNT" 2>/dev/null && return 0
	# Best effort, its error dropped on purpose: the failure is logged next.
	rm -f "$COUNT.tmp" 2>/dev/null
	outcome_log 3 "The start count $COUNT could not be written, so this start of the sign-in service is refused."
	return 1
}

# field FILE KEY — KEY's value in the KEY=VALUE record FILE.
field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }

# reason — the hold record's sentence, from the exit record `last` names: the
# last start that ran the JVM, because a refusal's own record comes later and
# the hold record is never rewritten from it (F-973-01).
reason() {
	_held="so it is held stopped until it is restarted, its certificate is renewed or the system is updated."
	_id=$(cat "$EXITS_DIR/last" 2>/dev/null) || _id=""
	case "$_id" in
		*[!0-9a-f]*|'') _id="" ;;
	esac
	if [ "${#_id}" -ne 32 ] || [ ! -f "$EXITS_DIR/$_id" ]; then
		echo "The sign-in service did not finish starting three times in a row, and the cause is unknown, $_held"
		return
	fi
	_out=$(field "$EXITS_DIR/$_id" outcome)
	_code=$(field "$EXITS_DIR/$_id" exit_code)
	_status=$(field "$EXITS_DIR/$_id" exit_status)
	# Only systemd's own words reach the sentence.
	case "$_out" in *[!a-z-]*|'') _out=unknown ;; esac
	case "$_status" in *[!A-Za-z0-9+]*|'') _status=unknown ;; esac
	if [ "$_out" = oom-kill ] || { [ "$_code" = exited ] && [ "$_status" = 3 ]; }; then
		echo "The sign-in service did not finish starting three times in a row (its last start ran out of memory), $_held"
	else
		echo "The sign-in service did not finish starting three times in a row (its last start ended with $_out, status $_status), $_held"
	fi
}

# rearm — remove the count and the hold record; say so if either existed.
rearm() {
	_had=""
	[ -e "$COUNT" ] && _had=1
	[ -e "$HOLD" ] && _had=1
	# Errors dropped on purpose: the count is rewritten next, which logs a
	# failure, and a hold record that stays is named below.
	rm -f "$COUNT" "$HOLD" 2>/dev/null
	if [ -e "$HOLD" ]; then
		outcome_log 3 "The hold record $HOLD could not be removed, so the sign-in service may still read as held."
	fi
	[ -n "$_had" ] && outcome_log 6 "This start was asked for, so the start-failure hold is re-armed."
	return 0
}

hold() {
	if _n=$("$SYSTEMCTL" show -P NRestarts "$UNIT" 2>/dev/null) && [ -n "$_n" ]; then
		:
	else
		_n=""
		outcome_log 4 "The restart count of $UNIT could not be read, so this start is counted as a repeat."
	fi
	if [ "$_n" = 0 ]; then
		rearm
		write_count 1 || return 1
		return 0
	fi
	_c=0
	if [ -e "$COUNT" ]; then
		_c=$(cat "$COUNT" 2>/dev/null) || _c=""
		case "$_c" in
			''|*[!0-9]*)
				outcome_log 3 "The start count $COUNT does not hold one whole number, so this start of the sign-in service is refused."
				return 1
				;;
		esac
	fi
	if [ "$_c" -lt "$LIMIT" ]; then
		write_count $((_c + 1)) || return 1
		return 0
	fi
	# At the limit: refuse. The hold record is written once per hold, so the
	# cause stays the last start that ran the JVM.
	if [ "$(field "$HOLD" outcome)" = refused ]; then
		outcome_log 3 "The sign-in service is still held after three failed starts in a row; its record is $HOLD."
		return 1
	fi
	mkdir -p "$HOLD_DIR" 2>/dev/null
	_why=$(reason)
	outcome_record "$HOLD" "$HOLD.tmp" "outcome=refused" \
		"boot_id=$(outcome_boot_id "$BOOTID_SRC")" "reason=$_why" || :
	outcome_log 3 "$_why"
	return 1
}

wait_started() {
	_last="no answer yet"
	trap 'outcome_log 4 "The sign-in service was stopped before /health/started answered UP (last answer: $_last)."; exit 143' TERM
	if [ -z "${MAINPID:-}" ]; then
		outcome_log 3 "The start wait has no main process ID from systemd, so it cannot tell whether the sign-in service is still running."
		return 1
	fi
	if [ ! -x "$CURL" ]; then
		outcome_log 3 "The start wait cannot ask the sign-in service whether it has started, because $CURL is missing."
		return 1
	fi
	for _f in "$CA" "$CERT" "$KEY"; do
		if [ ! -r "$_f" ]; then
			outcome_log 3 "The start wait cannot ask the sign-in service whether it has started, because $_f cannot be read."
			return 1
		fi
	done
	while :; do
		# The body and the code, the code on its own last line. curl's own
		# messages are dropped: an answer is the code or curl's exit status.
		_resp=$("$CURL" -s --tlsv1.3 --max-time 10 --cacert "$CA" --cert "$CERT" --key "$KEY" \
			-w '\n%{http_code}' "$URL" 2>/dev/null)
		_rc=$?
		_code=$(printf '%s\n' "$_resp" | tail -n 1)
		if [ "$_rc" -ne 0 ]; then
			_last="curl exit $_rc"
		else
			_last="HTTP $_code"
		fi
		if [ "$_rc" -eq 0 ] && [ "$_code" = 200 ] \
			&& printf '%s\n' "$_resp" | grep -q '"status"[[:space:]]*:[[:space:]]*"UP"'; then
			if ! rm -f "$COUNT" 2>/dev/null || [ -e "$COUNT" ]; then
				outcome_log 3 "The sign-in service has started, but the start count $COUNT could not be removed, so a later start may be held early."
			else
				outcome_log 6 "The sign-in service has started: /health/started answered UP."
			fi
			return 0
		fi
		_pid=$("$SYSTEMCTL" show -P MainPID "$UNIT" 2>/dev/null) || _pid=""
		if [ "$_pid" != "$MAINPID" ]; then
			outcome_log 3 "The sign-in service's main process ended before /health/started answered UP (last answer: $_last)."
			return 1
		fi
		sleep "$RECHECK"
	done
}

# cap ID — while the directory holds more than CAP records, remove the oldest
# written first (ls -tr: by mtime), never ID and never the record `last`
# names. Record names are 32 lowercase hex characters, so `last` and every
# .tmp file never match and are never removed.
cap() {
	_keep=$(cat "$EXITS_DIR/last" 2>/dev/null) || _keep=""
	# shellcheck disable=SC2010 # mtime order needs ls -t; the names are filtered to 32 hex characters
	_names=$(ls -tr "$EXITS_DIR" 2>/dev/null | grep -E '^[0-9a-f]{32}$')
	_over=$(( $(printf '%s\n' "$_names" | grep -c .) - CAP ))
	for _old in $_names; do
		[ "$_over" -gt 0 ] || break
		[ "$_old" = "$1" ] || [ "$_old" = "$_keep" ] && continue
		if rm -f "$EXITS_DIR/$_old" 2>/dev/null; then
			_over=$((_over - 1))
		else
			outcome_log 4 "The old exit record $EXITS_DIR/$_old could not be removed, so the exit records are over their cap of $CAP."
		fi
	done
	return 0
}

exit_record() {
	_id="${INVOCATION_ID:-}"
	case "$_id" in
		*[!0-9a-f]*|'') _bad=1 ;;
		*) _bad="" ;;
	esac
	if [ -n "$_bad" ] || [ "${#_id}" -ne 32 ]; then
		outcome_log 3 "The exit record was not written, because the invocation ID '$_id' is not 32 lowercase hex characters."
		return 0
	fi
	mkdir -p "$EXITS_DIR" 2>/dev/null
	outcome_record "$EXITS_DIR/$_id" "$EXITS_DIR/$_id.tmp" "outcome=${SERVICE_RESULT:-}" \
		"invocation_id=$_id" "exit_code=${EXIT_CODE:-}" "exit_status=${EXIT_STATUS:-}" || return 0
	# A `last` that cannot be written is logged by outcome_record and keeps
	# naming the record before; the cap still runs, and still keeps that one.
	outcome_record "$EXITS_DIR/last" "$EXITS_DIR/last.tmp" "$_id" || :
	cap "$_id"
	return 0
}

case "${1:-}" in
	hold) hold; exit $? ;;
	wait) wait_started; exit $? ;;
	exit) exit_record; exit 0 ;;
	*)
		outcome_log 3 "rasputin-keycloak-hooks.sh was run with '${1:-}' instead of hold, wait or exit, so it did nothing."
		exit 2
		;;
esac
