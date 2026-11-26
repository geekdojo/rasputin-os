#!/bin/sh
#
# smoke-signin.sh — the boot smoke's first-run sign-in through the console
# (geekdojo/geekdojo-brain#993): the wrapper around test/lib/signin.py and the
# three facts the sign-in waits on. Sourced, never run.
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
#       returns 1. Sets SS_LAST to the last state and SS_SECONDS to the time
#       it ran.
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
		"$_sw_alive" "$_sw_fact"
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
