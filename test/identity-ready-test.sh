#!/bin/sh
# Tests for test/lib/identity-ready.sh, the smokes' identity readiness check
# (geekdojo/geekdojo-brain#974, TC-974-11): the realm rounds and the identity
# report's verdicts.
#
# How. identity_realm_wait runs with a stub guest runner that answers from a
# script of lines, one per round, and stub ALIVE collaborators; the interval
# is 0, so nothing waits on a clock. identity_report_verdict runs on fixture
# bodies. What the guest's curl and systemctl really print is the amd64 boot
# smoke's (TC-974-20).
#
# Run:  sh test/identity-ready-test.sh
set -u
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
LIB="$ROOT/test/lib"
for f in "$LIB/checks.sh" "$LIB/store-ready.sh" "$LIB/identity-ready.sh"; do
	[ -f "$f" ] || { echo "FAILED: the file $f is missing."; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "FAILED: this test needs jq, and it is not on PATH."; exit 1; }
. "$LIB/checks.sh"
. "$LIB/store-ready.sh"
. "$LIB/identity-ready.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

# The stub runner: answers the next line of $TMP/script on each call, counts
# calls, and records the command it was given.
runner() {
	_n=$(($(cat "$TMP/calls") + 1)); echo "$_n" >"$TMP/calls"
	printf '%s' "$1" >"$TMP/cmd"
	sed -n "${_n}p" "$TMP/script"
}
alive() { return 0; }
# script LINE... — the runner's answers, one per round.
script() { printf '%s\n' "$@" >"$TMP/script"; echo 0 >"$TMP/calls"; }
# wait_run [ALIVE] — the wait, in a subshell; sets OUT, RC, CALLS and LAST.
wait_run() {
	OUT=$( (identity_realm_wait 0 runner "${1:-alive}"; _rc=$?; echo "LAST=$IR_LAST"; exit "$_rc") 2>&1); RC=$?
	CALLS=$(cat "$TMP/calls")
	LAST=$(printf '%s\n' "$OUT" | sed -n 's/^LAST=//p')
}
UP='code=200 kc=active db=active hold=no'

echo "1. the realm rounds (TC-974-11)"
script 'code=000 kc=activating db=active hold=no' 'code=404 kc=active db=active hold=no' "$UP"
wait_run
check "TC-974-11 000 then 404 continue, and 200 ends the wait as ready (rc=$RC, $CALLS rounds)" \
	"$({ [ "$RC" = 0 ] && [ "$CALLS" = 3 ] && [ "$LAST" = ready ]; } && echo 0 || echo 1)" "$OUT"
check "TC-974-11 the wait logs the seconds it took" "$(yes_if contains 'realm rasputin answered 200 after ' "$OUT")" "$OUT"
check "TC-974-11 the round asks realm rasputin's discovery document" \
	"$(yes_if contains 'https://127.0.0.1:8543/realms/rasputin/.well-known/openid-configuration' "$(cat "$TMP/cmd")")"
check "TC-974-11 the round's curl presents the api's identity client leaf and trusts the identity CA" \
	"$({ contains '--cert /var/lib/rasputin/tls/identity-api-client/leaf.pem' "$(cat "$TMP/cmd")" \
		&& contains '--cacert /var/lib/rasputin/trust/identity-ca.pem' "$(cat "$TMP/cmd")"; } && echo 0 || echo 1)"
check "TC-974-11 the round's curl prints only the status code" \
	"$({ contains '-o /dev/null -w "%{http_code}"' "$(cat "$TMP/cmd")" && ! contains ' -v' "$(cat "$TMP/cmd")"; } && echo 0 || echo 1)"
script '' 'garbage' "$UP"
wait_run
check "TC-974-11 a guest that does not answer continues (rc=$RC, $CALLS rounds)" \
	"$({ [ "$RC" = 0 ] && [ "$CALLS" = 3 ]; } && echo 0 || echo 1)" "$OUT"
for u in keycloak.service keycloak-db.service; do
	case "$u" in keycloak.service) l='code=000 kc=failed db=active hold=no' ;; *) l='code=000 kc=inactive db=failed hold=no' ;; esac
	script "$l" "$UP"
	wait_run
	check "TC-974-11 $u ActiveState=failed stops the wait at once, naming the unit (rc=$RC, $CALLS round)" \
		"$({ [ "$RC" = 1 ] && [ "$CALLS" = 1 ] && [ "$LAST" = "stopped: $u is failed" ]; } && echo 0 || echo 1)" "$OUT"
done
script 'code=000 kc=inactive db=active hold=yes' "$UP"
wait_run
check "TC-974-11 a start-hold record stops the wait at once, naming the hold (rc=$RC, $CALLS round)" \
	"$({ [ "$RC" = 1 ] && [ "$CALLS" = 1 ] && contains 'start-hold record' "$LAST"; } && echo 0 || echo 1)" "$OUT"
# An ALIVE that ends the caller, as die_if_qemu_gone does.
dead_exit() { echo "ALIVE: qemu gone while waiting for $1"; exit 7; }
script "$UP"
wait_run dead_exit
check "TC-974-11 an ALIVE that ends the caller ends the wait, naming 'realm rasputin answering 200' (rc=$RC, $CALLS rounds)" \
	"$({ [ "$RC" = 7 ] && [ "$CALLS" = 0 ] && contains 'waiting for realm rasputin answering 200' "$OUT"; } && echo 0 || echo 1)" "$OUT"
# An ALIVE that returns non-zero, as update-smoke's does.
dead_return() { return 1; }
script "$UP"
wait_run dead_return
check "TC-974-11 an ALIVE that returns non-zero ends the wait, naming 'realm rasputin' (rc=$RC, $CALLS rounds)" \
	"$({ [ "$RC" = 1 ] && [ "$CALLS" = 0 ] && contains 'realm rasputin never answered 200' "$LAST"; } && echo 0 || echo 1)" "$OUT"

echo
echo "2. the identity report's verdicts (TC-974-11)"
# verdict LABEL WANT CODE BODY — identity_report_verdict's label and status.
verdict() {
	printf '%s' "$4" >"$TMP/body"
	_got=$(identity_report_verdict "$3" "$TMP/body"); _rc=$?
	_wrc=1; [ "$2" = ready ] && _wrc=0
	check "TC-974-11 $1: '$2'" "$({ [ "$_got" = "$2" ] && [ "$_rc" = "$_wrc" ]; } && echo 0 || echo 1)" "got '$_got' rc=$_rc"
}
verdict "a 200 array with no identity: id" ready 200 '[{"id":"secret-store:sealed"},{"id":"node:x"}]'
verdict "an empty 200 array" ready 200 '[]'
verdict "identity:starting" "not-ready: identity:starting" 200 '[{"id":"identity:starting"},{"id":"node:x"}]'
verdict "a non-200" "refused: HTTP 401" 401 '{"error":"no session"}'
verdict "no answer" no-answer 000 ''
verdict "a non-JSON body" "unreadable: the body is not JSON" 200 'not json'
verdict "an element without a string id" "unreadable: an alert has no string id" 200 '[{"id":3}]'

echo
if [ "$fails" -ne 0 ]; then echo "identity-ready-test: $fails check(s) FAILED"; exit 1; fi
echo "identity-ready-test: all checks passed"
