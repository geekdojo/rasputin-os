#!/bin/sh
#
# store-ready.sh — the boot smoke's check that the api reports the secrets
# store ready (geekdojo/geekdojo-brain#834). Sourced, never run.
#
# The api's only report of the store's readiness is its alerts list
# (rasputin-control-plane #760): every state other than ready raises an alert
# whose id starts "secret-store:", and GET /api/alerts, behind a session,
# returns the list as a bare JSON array. So "ready" is a 200 whose array holds
# no such id. Signing in to read it is test/lib/api-session.sh.
#
#   store_ready_verdict CODE BODYFILE
#       Prints one label and returns 0 only for "ready". The status code is
#       read before the body:
#         ready                 200, an array of objects with string ids, none
#                               starting "secret-store:"
#         not-ready: ID[, ID]   the store's alerts, and only those
#         refused: HTTP CODE    any other status curl got an answer with
#         no-answer             code 000 or empty: no HTTP answer at all
#         unreadable: REASON    an empty, missing, non-JSON or non-array body,
#                               or an element with no string id
#   store_ready_wait TRIES INTERVAL FETCH ALIVE
#       Each round runs ALIVE with the fact being waited for, then FETCH, which
#       prints "CODE BODYFILE", then the verdict. Returns 0 the moment the
#       verdict is ready. Otherwise sets SR_LAST to the last verdict and
#       returns 1 once TRIES rounds have run, INTERVAL seconds apart. ALIVE is
#       run in this shell, so a dead dependency can end the caller.
#   store_ready_report STAGE REASON WAIT_RC LAST SECONDS
#       The post-kill decision, one line. STAGE is empty when the check never
#       ran, "signin" when the sign-in failed with REASON, and "wait" once the
#       wait ran and returned WAIT_RC. Returns 0 only for a wait that returned 0.

store_ready_verdict() {
	_sr_code=$1
	_sr_body=$2
	case "$_sr_code" in
		'' | 000) echo "no-answer"; return 1 ;;
		200) ;;
		*) echo "refused: HTTP $_sr_code"; return 1 ;;
	esac
	if [ ! -s "$_sr_body" ]; then
		echo "unreadable: the body is empty or missing"; return 1
	fi
	if ! jq empty "$_sr_body" >/dev/null 2>&1; then
		echo "unreadable: the body is not JSON"; return 1
	fi
	if ! jq -e 'type == "array"' "$_sr_body" >/dev/null 2>&1; then
		echo "unreadable: the body is not a JSON array"; return 1
	fi
	if ! jq -e 'all(.[]; type == "object" and (.id | type) == "string")' "$_sr_body" >/dev/null 2>&1; then
		echo "unreadable: an alert has no string id"; return 1
	fi
	_sr_ids=$(jq -r '[.[] | .id | select(startswith("secret-store:"))] | join(", ")' "$_sr_body")
	if [ -n "$_sr_ids" ]; then
		echo "not-ready: $_sr_ids"; return 1
	fi
	echo "ready"
}

store_ready_wait() {
	_sr_tries=$1
	_sr_interval=$2
	_sr_fetch=$3
	_sr_alive=$4
	SR_LAST=""
	_sr_i=0
	while [ "$_sr_i" -lt "$_sr_tries" ]; do
		"$_sr_alive" "the api to report the secrets store ready"
		_sr_got=$("$_sr_fetch")
		case "$_sr_got" in
			*" "*) _sr_c=${_sr_got%% *}; _sr_b=${_sr_got#* } ;;
			*) _sr_c=$_sr_got; _sr_b="" ;;
		esac
		# shellcheck disable=SC2034 # read by the caller
		SR_LAST=$(store_ready_verdict "$_sr_c" "$_sr_b") && return 0
		_sr_i=$((_sr_i + 1))
		[ "$_sr_i" -lt "$_sr_tries" ] && sleep "$_sr_interval"
	done
	return 1
}

store_ready_report() {
	case "$1" in
		signin)
			echo "::error::The smoke could not sign in to read the api's report of the secrets store. $2"
			return 1 ;;
		wait)
			if [ "$3" = 0 ]; then
				echo "The api reports the secrets store ready: GET /api/alerts holds no secret-store alert after $5 seconds."
				return 0
			fi
			echo "::error::The api never reported the secrets store ready on a fresh control plane in $5 seconds; its last answer to GET /api/alerts was \"$4\"."
			return 1 ;;
		*)
			echo "::error::The smoke never checked whether the api reports the secrets store ready, because the store's self-init line had not reached the serial console when that check was due."
			return 1 ;;
	esac
}
