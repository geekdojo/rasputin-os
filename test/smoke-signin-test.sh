#!/bin/sh
# Tests for test/lib/smoke-signin.sh, the boot smoke's first-run sign-in
# wrapper and its fact polls (geekdojo/geekdojo-brain#993, TC-993-22).
#
# How. smoke_signin runs a stub signin.py (a python3 script that prints the
# line and exits with the status the case puts in its environment, and writes
# a line to stderr); ss_wait runs stub probes and a recording ALIVE with an
# interval of 0, so nothing waits on a clock; the three probes run against
# stub collaborators. What the real signin.py, the guest and the console
# answer is the amd64 boot smoke's (TC-993-13 to TC-993-19).
#
# Run:  sh test/smoke-signin-test.sh
set -u
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
LIB="$ROOT/test/lib"
for f in "$LIB/checks.sh" "$LIB/smoke-signin.sh"; do
	[ -f "$f" ] || { echo "FAILED: the file $f is missing."; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo "FAILED: this test needs python3, and it is not on PATH."; exit 1; }
# shellcheck source=test/lib/checks.sh
. "$LIB/checks.sh"
# shellcheck source=test/lib/smoke-signin.sh
. "$LIB/smoke-signin.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

# The stub signin.py: prints STUB_LINE (nothing when it is empty), writes one
# stderr line, records its arguments and exits STUB_RC.
cat >"$TMP/signin.py" <<'EOF'
import os, sys
with open(os.environ["STUB_ARGS"], "w") as f:
    f.write("\n".join(sys.argv[1:]) + "\n")
if os.environ.get("STUB_LINE"):
    print(os.environ["STUB_LINE"])
print("level=error event=end exit=" + os.environ["STUB_RC"], file=sys.stderr)
sys.exit(int(os.environ["STUB_RC"]))
EOF
SS_SIGNIN="$TMP/signin.py" SS_STATE="$TMP/state" SS_DOORS="$TMP/doors.json" SS_CA="$TMP/ca.pem"
SS_CONNECT="127.0.0.1:18443" SS_LABEL=owner
export STUB_ARGS="$TMP/args"

# signin RC LINE VERB... — smoke_signin against the stub; sets OUT and RC.
signin() {
	_rc=$1 _line=$2; shift 2
	OUT=$(STUB_RC=$_rc STUB_LINE=$_line smoke_signin "$@"); RC=$?
}
errors() { printf '%s\n' "$OUT" | grep -c '^::error::'; }

echo "== smoke_signin"
signin 0 "signin enrol PASS rp_id=sso-smoke1.local; pages=login-login" enrol passkey
check "a pass returns 0" "$(yes_if test "$RC" = 0)" "rc=$RC"
check "a pass prints signin.py's line and no ::error::" \
	"$(yes_if test "$OUT" = "signin enrol PASS rp_id=sso-smoke1.local; pages=login-login")" "$OUT"
check "the verb, its argument and the fixed options reach signin.py" \
	"$(yes_if test "$(tr '\n' ' ' <"$TMP/args")" = "enrol passkey --state $TMP/state --doors $TMP/doors.json --ca $TMP/ca.pem --connect 127.0.0.1:18443 --label owner --timeout 20 ")" \
	"$(tr '\n' ' ' <"$TMP/args")"

signin 1 "signin enrol FAIL fact=clock: The console refused authenticator_app with HTTP 409: Try again later." enrol totp --jar "$TMP/j"
check "exit 1 is a failure (rc 1)" "$(yes_if test "$RC" = 1)" "rc=$RC"
check "exit 1: exactly one ::error:: line" "$(yes_if test "$(errors)" = 1)" "$OUT"
check "exit 1: it names the fact, the verb and the sentence" \
	"$(yes_if contains "::error::the first-run sign-in failed on the fact 'clock' at signin.py enrol totp --jar $TMP/j: The console refused authenticator_app with HTTP 409: Try again later." "$OUT")" "$OUT"
check "exit 1: signin.py's stderr is indented under it" "$(yes_if contains "    signin: level=error event=end exit=1" "$OUT")" "$OUT"

signin 2 "signin door-page INCONCLUSIVE The page login-error is not login-register." create-account
check "exit 2 is a failure, never a pass (rc 2)" "$(yes_if test "$RC" = 2)" "rc=$RC"
check "exit 2: exactly one ::error:: naming the fact inconclusive" \
	"$(yes_if test "$(errors)" = 1 -a "$(printf '%s\n' "$OUT" | grep -c "fact 'inconclusive' at signin.py create-account: The page login-error")" = 1)" "$OUT"

signin 3 "" sign-in passkey
check "no verdict line: a failure (rc 3)" "$(yes_if test "$RC" = 3)" "rc=$RC"
check "no verdict line: one ::error:: saying signin.py printed none" \
	"$(yes_if test "$(errors)" = 1 -a "$(printf '%s\n' "$OUT" | grep -c 'printed no verdict (exit 3)')" -ge 1)" "$OUT"

echo "== ss_wait"
# A probe that holds from round $HOLD_AT (0: never), counting its calls; an
# ALIVE that records, in order with the probe, that it ran first.
probe() {
	_n=$(($(cat "$TMP/n") + 1)); echo "$_n" >"$TMP/n"; echo probe >>"$TMP/order"
	echo "last /api/auth/me 200"
	[ "$HOLD_AT" != 0 ] && [ "$_n" -ge "$HOLD_AT" ]
}
alive() { echo "alive $1" >>"$TMP/order"; }
wait_run() {
	echo 0 >"$TMP/n"; : >"$TMP/order"
	OUT=$(HOLD_AT=$1 ss_wait "the grant ending the session" 3 0 probe alive); RC=$?
	N=$(cat "$TMP/n")
}
wait_run 0
check "a fact that never holds: rc 1" "$(yes_if test "$RC" = 1)" "rc=$RC"
check "a fact that never holds: the probe ran exactly TRIES times" "$(yes_if test "$N" = 3)" "n=$N"
check "a fact that never holds: exactly one ::error::" "$(yes_if test "$(errors)" = 1)" "$OUT"
check "a fact that never holds: it names the fact and the last state" \
	"$(yes_if contains "::error::the grant ending the session never held in" "$OUT")" "$OUT"
check "a fact that never holds: the last state is the probe's" \
	"$(yes_if contains "3 reads); last: last /api/auth/me 200" "$OUT")" "$OUT"
check "ALIVE ran before the probe each round, told the fact" \
	"$(yes_if test "$(tr '\n' '|' <"$TMP/order")" = "alive the grant ending the session|probe|alive the grant ending the session|probe|alive the grant ending the session|probe|")" \
	"$(tr '\n' '|' <"$TMP/order")"
wait_run 2
check "a fact that holds: rc 0 on the round it holds" "$(yes_if test "$RC" = 0 -a "$N" = 2)" "rc=$RC n=$N"
check "a fact that holds: no ::error::" "$(yes_if test "$(errors)" = 0)" "$OUT"

echo "== the probes"
fetch_200() { echo 200; }
fetch_401() { echo 401; }
fetch_none() { :; }
OUT=$(ss_grant_probe fetch_200); RC=$?
check "grant: 200 is waiting, named" "$(yes_if test "$RC" = 1 -a "$OUT" = "last /api/auth/me 200")" "rc=$RC $OUT"
OUT=$(ss_grant_probe fetch_401); RC=$?
check "grant: 401 holds" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT"
OUT=$(ss_grant_probe fetch_none); RC=$?
check "grant: no answer is waiting, named 000" "$(yes_if test "$RC" = 1 -a "$OUT" = "last /api/auth/me 000")" "rc=$RC $OUT"

guest() { printf '%s\r\n' "$GUEST_SAYS"; }
for case in "marker=no totp=unknown|1|marker /run/systemd/timesync/synchronized is absent" \
	"marker=yes totp=false|1|CONFIGURE_TOTP reads false" \
	"marker=yes totp=unknown|1|CONFIGURE_TOTP reads unknown" \
	"marker=yes totp=true|0|the realm offers CONFIGURE_TOTP" \
	"|1|the guest did not answer"; do
	says=${case%%|*} rest=${case#*|}
	want=${rest%%|*} text=${rest#*|}
	OUT=$(GUEST_SAYS=$says ss_sync_probe guest); RC=$?
	check "sync: '$says' is rc $want, saying '$text'" "$(yes_if test "$RC" = "$want")" "rc=$RC $OUT"
	check "sync: '$says' names its state" "$(yes_if contains "$text" "$OUT")" "$OUT"
done

OUT=$(STUB_RC=0 STUB_LINE="signin door-page PASS the door shows its registration form; pages=login-register" ss_door_probe); RC=$?
check "door: door-page's pass holds" "$(yes_if test "$RC" = 0 -a "$OUT" = "the door shows its registration form; pages=login-register")" "rc=$RC $OUT"
OUT=$(STUB_RC=2 STUB_LINE="signin door-page INCONCLUSIVE The door answered account creation with login-error, not login-register." ss_door_probe); RC=$?
check "door: door-page's exit 2 is waiting, its sentence the state" \
	"$(yes_if test "$RC" = 2 -a "$OUT" = "The door answered account creation with login-error, not login-register.")" "rc=$RC $OUT"
check "door: the probe asked door-page with the fixed options" \
	"$(yes_if test "$(head -1 "$TMP/args")" = door-page)" "$(head -1 "$TMP/args")"

if [ "$fails" -ne 0 ]; then
	echo "smoke-signin-test: $fails failed"
	exit 1
fi
echo "smoke-signin-test: all passed"
