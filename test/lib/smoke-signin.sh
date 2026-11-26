#!/bin/sh
#
# smoke-signin.sh — the smokes' sign-in through the console: the boot smoke's
# first-run sign-in (geekdojo/geekdojo-brain#993) and the update smoke's move
# of the pre-update operator (geekdojo/geekdojo-brain#1012). The wrapper
# around test/lib/signin.py, the step sequence both run it in, and the facts
# their sign-ins wait on. Sourced, never run.
#
# The caller sets, before any call:
#   SS_SIGNIN   the path of signin.py, run as python3 -I
#   SS_STATE    signin.py's 0700 state directory
#   SS_DOORS    the doors file
#   SS_CA       the CA the console's and the doors' leaves chain to
#   SS_CONNECT  ADDR:PORT every connection goes to
#   SS_LABEL    the account label
#
#   smoke_signin VERB [ARG...]
#       One signin.py run: VERB and its ARGs (a WHAT, --jar FILE), with the
#       options above and --timeout 20. Sets SS_LINE to signin.py's stdout
#       line and returns its exit status. On any status but 0 it prints one
#       ::error:: line naming the fact (signin.py's fact=<name>, or
#       "inconclusive" for exit 2), the verb and signin.py's sentence, then
#       signin.py's stderr indented. Exit 2 is a failure here, never a pass.
#   ss_wait FACT TRIES INTERVAL PROBE ALIVE
#       Each round runs ALIVE with FACT, then PROBE (a function name, called
#       with no argument), which prints the state it saw on one line and
#       returns 0 once FACT holds. Returns 0 the moment it
#       does; otherwise, once TRIES rounds INTERVAL seconds apart have run,
#       prints one ::error:: naming FACT, the seconds and the last state, and
#       returns 1. An ALIVE that returns non-zero (what the wait is on is
#       gone, or has failed for good) ends the wait at once as a failure:
#       one ::error:: naming FACT and the last state, no further PROBE, and
#       1. Sets SS_LAST to the last state and SS_SECONDS to the time it ran.
#   ss_door_probe
#       PROBE for the door: signin.py door-page passes only on the door's
#       themed registration form, reached through the console's
#       /api/auth/signup, which is the fact that converge has applied the
#       console client's redirect URI and opened registration.
#   ss_sync_probe RUNNER
#       PROBE for the authenticator app: RUNNER SS_SYNC_GUEST (ssh_guest on
#       the smoke) prints marker=<yes|no> totp=<true|false|unknown>. First the
#       clock-sync marker /run/systemd/timesync/synchronized, then the realm's
#       CONFIGURE_TOTP read back as enabled: converge enables it only on a run
#       that read the marker, so that is the converge after the marker.
#   ss_grant_probe FETCH
#       PROBE for the grant: FETCH prints the HTTP status GET /api/auth/me
#       answers on the session the authenticator app's enrolment began with.
#       The grant ends the account's sessions (C23), so 401 is the fact it ran.
#
# The step sequence, which both smokes run (moved unchanged from
# boot-smoke.sh for #1012):
#   sg STEP...      one smoke_signin step, run only while SG_FAIL is empty; a
#                   step that does not pass sets SG_FAIL and returns 1, so
#                   the first failure stops every later step.
#   sg_fail SENTENCE  the first failure, kept in SG_FAIL; later ones are not.
#   sg_field KEY    KEY's value in the last signin.py line (rp_id, roles).
#   me_status HOST PORT CA JAR
#       The HTTP status GET https://HOST/api/auth/me answers on the cookie
#       jar JAR, sent to 127.0.0.1:PORT and checked against CA; 000 when
#       nothing answers.
#   ss_doors_file CONSOLE_HOST APP_HOST OUT
#       Writes signin.py's doors file to OUT: the home door
#       https://sso-CONSOLE_HOST through the console https://CONSOLE_HOST,
#       and the app door https://APP_HOST (signin.<cid>.internal), named only
#       as the negatives' other origin and RP ID.
#
# The update smoke's facts (geekdojo/geekdojo-brain#1012). Their FETCH is a
# function called with a body file: it writes the body of one
# GET /api/auth/status there and prints the HTTP status (000, or nothing,
# when nothing answered).
#   ss_status_line FETCH BODY
#       One read, printed as one line: `noanswer` (no HTTP answer),
#       `200 firstRun=<true|false> ready=<true|false|unknown>`, `unparsed`
#       (a 200 whose body is not a JSON object with a boolean firstRun,
#       never counted as closed), or the status of any other answer.
#   ss_status_record FETCH OUT STOP TRIES INTERVAL
#       Issue TC-01's record: one ss_status_line appended to OUT every
#       INTERVAL seconds, from before the guest can answer, until the file
#       STOP exists or TRIES reads have run. Run in the background.
#   ss_status_verdict OUT
#       Prints the record's counts, `reads=N noanswer=N closed=N open=N
#       unparsed=N other=N`, and returns 0 only when no read said
#       firstRun:true, at least one 200 said firstRun:false, and a
#       `noanswer` came before the first 200: the record began before the
#       api could answer, so a first run left open would have been seen. On
#       1 a second line, `why: ...`, says which.
#   ss_status_probe FETCH OUT
#       PROBE for sign-in being ready: one ss_status_line, appended to OUT
#       (so the record keeps it, though ss_wait runs the probe in a command
#       substitution) and printed; 0 only on `200 firstRun=false ready=true`.
#   ss_base_ceremony FETCH
#       Which sign-in the base image runs, from the shape of its
#       /api/auth/status: prints `old` (hasUsers: the pre-identity console),
#       `identity` (firstRun) or `unknown` (anything else, no answer
#       included), and returns 0 for old and identity, 1 for unknown.
#   ss_move_probe RUNNER
#       PROBE for the move: RUNNER 'journalctl -u rasputin-api -b ...'
#       (ssh_guest on the smoke) gives this boot's api journal. 0 once the
#       move Job's last step logged SS_MOVE_RECORDED; 1 while it has not, or
#       when no journal came back; 2, printing `failed cause=<cause>`, once
#       an SS_MOVE_FAILED line has a cause other than not_ready (the one
#       failure the move retries, at the next readiness), whatever follows.
#   ss_move_alive RUNNER
#       ALIVE for the move wait: 0, unless ss_move_probe has seen a failure
#       other than not_ready; then it prints that failure and returns 1.

# The ceilings of the waits both smokes run, each polled 2s apart and ended
# the moment its fact holds:
#   DOOR_TRIES  the console's /api/auth/signup reaching the door's themed
#               registration form: converge has applied the console client's
#               redirect URI and opened registration. Converge is submitted at
#               a scheduler check every 60s once migrations are applied, so
#               the ceiling is 60 reads, 120s: one check interval, the run and
#               a margin. The update smoke's move wait uses it too: the move
#               is submitted the same way, at the scheduler's identity.move
#               check every 60s once sign-in is ready (the local run on
#               2026.11.4-dev.236 saw the check before readiness pass, and the
#               next one 60s later).
#   GRANT_TRIES GET /api/auth/me on the enrolment's session answering 401:
#               the grant ends the account's sessions (C23). 30 reads, 60s,
#               normally within a few.
DOOR_TRIES=60
GRANT_TRIES=30

# The move's journal facts: rasputin-control-plane e8f75376
# api/internal/identity/move/move.go:199 and :227, logged through logkit's
# slog.TextHandler, so each attribute is key=value, in that order.
SS_MOVE_RECORDED='event=identity.move.step step=record outcome=recorded'
SS_MOVE_FAILED='event=identity.move.failed'

# The guest's half of ss_sync_probe, run as root over SSH. The Admin API is
# read with the api's own identity client leaf, as converge reads it; the
# token stays in this shell and only the two words leave the guest.
# shellcheck disable=SC2016 # expanded in the guest, not here
SS_SYNC_GUEST='m=no; [ -e /run/systemd/timesync/synchronized ] && m=yes
e=unknown
if [ "$m" = yes ]; then
C=/var/lib/rasputin/trust/identity-ca.pem L=/var/lib/rasputin/tls/identity-api-client/leaf
t=$(curl -s --max-time 10 --cacert "$C" --cert "$L.pem" --key "$L.key" -d grant_type=client_credentials -d client_id=rasputin-admin https://127.0.0.1:8543/realms/rasputin/protocol/openid-connect/token 2>/dev/null | sed -n "s/.*\"access_token\":\"\([^\"]*\)\".*/\1/p")
[ -n "$t" ] && e=$(curl -s --max-time 10 --cacert "$C" --cert "$L.pem" --key "$L.key" -H "Authorization: Bearer $t" https://127.0.0.1:8543/admin/realms/rasputin/authentication/required-actions/CONFIGURE_TOTP 2>/dev/null | grep -o "\"enabled\":[a-z]*" | head -1 | cut -d: -f2)
fi
echo "marker=$m totp=${e:-unknown}"'

smoke_signin() {
	_ss_verb=$1
	_ss_err=$(mktemp) || { SS_LINE=""; echo "::error::signin $_ss_verb: no scratch file for its stderr"; return 2; }
	SS_LINE=$(python3 -I "$SS_SIGNIN" "$@" --state "$SS_STATE" --doors "$SS_DOORS" --ca "$SS_CA" \
		--connect "$SS_CONNECT" --label "$SS_LABEL" --timeout 20 2>"$_ss_err")
	_ss_rc=$?
	echo "${SS_LINE:-signin $_ss_verb printed no verdict}"
	if [ "$_ss_rc" != 0 ]; then
		_ss_said=${SS_LINE#signin * * }
		case "$_ss_said" in
			fact=*:*) _ss_fact=${_ss_said%%:*}; _ss_fact=${_ss_fact#fact=}; _ss_said=${_ss_said#*: } ;;
			*) _ss_fact=inconclusive ;;
		esac
		[ -n "$SS_LINE" ] || _ss_said="signin.py printed no verdict (exit $_ss_rc)"
		echo "::error::the first-run sign-in failed on the fact '$_ss_fact' at signin.py $*: $_ss_said"
		sed 's/^/    signin: /' "$_ss_err"
	fi
	rm -f "$_ss_err"
	return "$_ss_rc"
}

ss_wait() {
	_sw_fact=$1 _sw_tries=$2 _sw_interval=$3 _sw_probe=$4 _sw_alive=$5
	SS_LAST="" _sw_i=0 _sw_start=$(date +%s)
	while [ "$_sw_i" -lt "$_sw_tries" ]; do
		if ! "$_sw_alive" "$_sw_fact"; then
			SS_SECONDS=$(($(date +%s) - _sw_start))
			echo "::error::$_sw_fact: stopped after $SS_SECONDS seconds, because what it waits on is gone or has failed; last: ${SS_LAST:-nothing}"
			return 1
		fi
		if SS_LAST=$("$_sw_probe"); then
			SS_SECONDS=$(($(date +%s) - _sw_start))
			echo "$_sw_fact: held after $SS_SECONDS seconds ($SS_LAST)"
			return 0
		fi
		_sw_i=$((_sw_i + 1))
		[ "$_sw_i" -lt "$_sw_tries" ] && sleep "$_sw_interval"
	done
	SS_SECONDS=$(($(date +%s) - _sw_start))
	echo "::error::$_sw_fact never held in $SS_SECONDS seconds ($_sw_tries reads); last: ${SS_LAST:-nothing}"
	return 1
}

ss_door_probe() {
	_sd_line=$(python3 -I "$SS_SIGNIN" door-page --state "$SS_STATE" --doors "$SS_DOORS" --ca "$SS_CA" \
		--connect "$SS_CONNECT" --label "$SS_LABEL" --timeout 20 2>/dev/null)
	_sd_rc=$?
	echo "${_sd_line#signin door-page * }"
	return "$_sd_rc"
}

ss_sync_probe() {
	_sy_line=$("$1" "$SS_SYNC_GUEST" 2>/dev/null | tr -d '\r' | grep '^marker=' | tail -1)
	case "$_sy_line" in
		"marker=yes totp=true") echo "the clock-sync marker exists and the realm offers CONFIGURE_TOTP"; return 0 ;;
		"marker=yes "*) echo "the clock-sync marker exists, and the realm's CONFIGURE_TOTP reads ${_sy_line#marker=yes totp=}"; return 1 ;;
		"marker=no "*) echo "the clock-sync marker /run/systemd/timesync/synchronized is absent"; return 1 ;;
		*) echo "the guest did not answer"; return 1 ;;
	esac
}

ss_grant_probe() {
	_sg_code=$("$1")
	echo "last /api/auth/me ${_sg_code:-000}"
	[ "$_sg_code" = 401 ]
}

# ----------------------------------------------------- the step sequence ----

sg_fail() { [ -n "$SG_FAIL" ] || SG_FAIL=$1; }

sg() { [ -z "$SG_FAIL" ] || return 1; smoke_signin "$@" || { sg_fail "signin.py $* did not pass"; return 1; }; }

sg_field() { printf '%s\n' "$SS_LINE" | tr ' ' '\n' | sed -n "s/^$1=\\(.*\\);\$/\\1/p" | head -1; }

me_status() {
	curl -s -o /dev/null -w '%{http_code}' --connect-to "$1:443:127.0.0.1:$2" \
		--cacert "$3" -b "$4" --max-time 5 "https://$1/api/auth/me" || true
}

ss_doors_file() {
	cat >"$3" <<EOF
{"home": {"origin": "https://sso-$1", "realm": "rasputin", "client_id": "rasputin-console",
          "redirect_uri": "https://$1/api/auth/callback",
          "console": {"origin": "https://$1", "methods_route": "/api/me/sign-in-methods",
                      "methods": {"totp": "authenticator_app", "passkey": "passkey",
                                  "passkey-2fa": "security_key", "recovery-codes": "recovery_codes"}}},
 "app": {"origin": "https://$2", "realm": "rasputin", "client_id": "no-app-client-until-1027",
         "redirect_uri": "https://app.${2#signin.}/callback"}}
EOF
}

# ------------------------------------------------ the update smoke's facts --

ss_status_line() {
	rm -f "$2"
	_sl_code=$("$1" "$2" 2>/dev/null)
	case "$_sl_code" in
		"" | 000) echo noanswer ;;
		200)
			_sl_v=$(jq -r 'if type == "object" and (.firstRun | type) == "boolean"
				then "firstRun=\(.firstRun) ready=\(if (.ready | type) == "boolean" then .ready else "unknown" end)"
				else empty end' "$2" 2>/dev/null)
			if [ -n "$_sl_v" ]; then echo "200 $_sl_v"; else echo unparsed; fi
			;;
		*) echo "$_sl_code" ;;
	esac
	rm -f "$2"
}

ss_status_record() {
	_sr_i=0
	while [ "$_sr_i" -lt "$4" ] && [ ! -e "$3" ]; do
		ss_status_line "$1" "$2.body" >>"$2"
		_sr_i=$((_sr_i + 1))
		[ -e "$3" ] || sleep "$5"
	done
}

ss_status_verdict() {
	awk '
		{ n++ }
		$0 == "noanswer" { na++; if (!seen200) early++; next }
		/^200 firstRun=false / { closed++; seen200 = 1; next }
		/^200 firstRun=true / { open++; seen200 = 1; next }
		$0 == "unparsed" { unparsed++; seen200 = 1; next }
		{ other++ }
		END {
			printf "reads=%d noanswer=%d closed=%d open=%d unparsed=%d other=%d\n", n, na, closed, open, unparsed, other
			if (open > 0) { print "why: a read said firstRun:true, so first run was open"; exit 1 }
			if (closed == 0) { print "why: no read was a 200 saying firstRun:false"; exit 1 }
			if (early == 0) { print "why: no read went unanswered before the first 200, so the record began after the api could answer"; exit 1 }
		}' "$1"
}

ss_status_probe() {
	_sp_line=$(ss_status_line "$1" "$2.probe-body")
	echo "$_sp_line" >>"$2"
	echo "GET /api/auth/status: $_sp_line"
	[ "$_sp_line" = "200 firstRun=false ready=true" ]
}

ss_base_ceremony() {
	_sb_body=$(mktemp) || { echo unknown; return 1; }
	_sb_code=$("$1" "$_sb_body" 2>/dev/null)
	_sb_kind=unknown
	if [ "$_sb_code" = 200 ]; then
		_sb_kind=$(jq -r 'if type != "object" then "unknown" elif has("hasUsers") then "old"
			elif has("firstRun") then "identity" else "unknown" end' "$_sb_body" 2>/dev/null)
	fi
	rm -f "$_sb_body"
	echo "${_sb_kind:-unknown}"
	[ "${_sb_kind:-unknown}" != unknown ]
}

ss_move_probe() {
	_mp_j=$("$1" 'journalctl -u rasputin-api -b -o cat --no-pager' 2>/dev/null | tr -d '\r')
	if [ -z "$_mp_j" ]; then
		echo "the api's journal did not answer"
		return 1
	fi
	_mp_failed=$(printf '%s\n' "$_mp_j" | grep -F "$SS_MOVE_FAILED")
	_mp_cause=$(printf '%s\n' "$_mp_failed" | sed -n 's/.* cause=\([^ ]*\).*/\1/p' | grep -vx not_ready | head -1)
	# A failure line with no cause at all is not a not_ready one either.
	[ -n "$_mp_cause" ] || ! printf '%s\n' "$_mp_failed" | grep . | grep -qv ' cause=' || _mp_cause=none
	_mp_nr=$(printf '%s\n' "$_mp_failed" | grep -c ' cause=not_ready')
	if [ -n "$_mp_cause" ]; then
		echo "failed cause=$_mp_cause"
		return 2
	fi
	if printf '%s\n' "$_mp_j" | grep -qF "$SS_MOVE_RECORDED"; then
		echo "the move recorded its last step ($_mp_nr not_ready failures before it)"
		return 0
	fi
	echo "no record step yet ($_mp_nr not_ready failures so far)"
	return 1
}

ss_move_alive() {
	_ma_said=$(ss_move_probe "$1")
	[ $? = 2 ] || return 0
	echo "the move failed for good: $_ma_said"
	return 1
}
