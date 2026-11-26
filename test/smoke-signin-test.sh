#!/bin/sh
# Tests for test/lib/smoke-signin.sh, the boot smoke's first-run sign-in
# wrapper and its fact polls (geekdojo/geekdojo-brain#993, TC-993-22), and
# the update smoke's move facts and the step sequence both smokes share
# (geekdojo/geekdojo-brain#1012, TC-1012-08 to -11, -16 and -19).
#
# How. smoke_signin runs a stub signin.py (a python3 script that prints the
# line and exits with the status the case puts in its environment, and writes
# a line to stderr); ss_wait runs stub probes and a recording ALIVE with an
# interval of 0, so nothing waits on a clock; the three probes run against
# stub collaborators. What the real signin.py, the guest and the console
# answer is the amd64 boot smoke's (TC-993-13 to TC-993-19). The move's
# facts run against stub FETCHes and RUNNERs (journals in the api's own
# key=value form); the real api's are the update smoke's (TC-1012-01 to -07).
#
# Shells. The cases run under each shell in TEST_SHELLS (default: whichever
# of sh, dash and bash are installed), each sourcing the lib itself.
#
# Run:  sh test/smoke-signin-test.sh
set -u
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
LIB="$ROOT/test/lib"
for f in "$LIB/checks.sh" "$LIB/smoke-signin.sh" "$ROOT/test/fixtures/smoke-signin/doors-c1.json"; do
	[ -f "$f" ] || { echo "FAILED: the file $f is missing."; exit 1; }
done
for t in python3 jq; do
	command -v "$t" >/dev/null 2>&1 || { echo "FAILED: this test needs $t, and it is not on PATH."; exit 1; }
done
if [ -z "${SS_TEST_SHELL:-}" ]; then
	if [ -z "${TEST_SHELLS:-}" ]; then
		for s in sh dash bash; do
			command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="${TEST_SHELLS:-} $s"
		done
	fi
	rc=0
	for s in $TEST_SHELLS; do
		echo "== cases under $s"
		SS_TEST_SHELL=$s "$s" "$0" || rc=1
	done
	exit "$rc"
fi
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


# holds EXPR — 0 when the shell expression EXPR holds, else 1: check's STATUS
# for a check of more than one command.
holds() { if eval "$1"; then echo 0; else echo 1; fi; }

echo "== ss_wait honours ALIVE (TC-1012-10)"
# An ALIVE that returns non-zero on round $DEAD_AT (0: never).
dying() { _k=$(($(cat "$TMP/k") + 1)); echo "$_k" >"$TMP/k"; [ "$DEAD_AT" = 0 ] || [ "$_k" -lt "$DEAD_AT" ]; }
dead_run() {
	echo 0 >"$TMP/n"; echo 0 >"$TMP/k"; : >"$TMP/order"
	OUT=$(HOLD_AT=$1 DEAD_AT=$2 ss_wait "the move recording" 5 0 probe dying); RC=$?
	N=$(cat "$TMP/n")
}
dead_run 0 3
check "TC-1012-10 ALIVE failing on round 3: rc 1" "$(yes_if test "$RC" = 1)" "rc=$RC"
check "TC-1012-10 ALIVE failing on round 3: the probe ran only rounds 1 and 2" "$(yes_if test "$N" = 2)" "n=$N"
check "TC-1012-10 ALIVE failing on round 3: exactly one ::error::" "$(yes_if test "$(errors)" = 1)" "$OUT"
check "TC-1012-10 ALIVE failing: the ::error:: names the fact and the last state" \
	"$(yes_if contains "::error::the move recording: stopped after" "$OUT")" "$OUT"
check "TC-1012-10 ALIVE failing: the last state is the probe's" \
	"$(yes_if contains "has failed; last: last /api/auth/me 200" "$OUT")" "$OUT"
dead_run 0 1
check "TC-1012-10 ALIVE failing on round 1: no probe ran, last nothing" \
	"$(yes_if test "$RC:$N" = 1:0)" "rc=$RC n=$N $OUT"
check "TC-1012-10 ALIVE failing on round 1: its ::error:: says nothing was seen" "$(yes_if contains "last: nothing" "$OUT")" "$OUT"
dead_run 2 0
check "TC-1012-10 an ALIVE that always returns 0: the wait holds as before" "$(yes_if test "$RC:$N:$(errors)" = 0:2:0)" "rc=$RC n=$N $OUT"

echo "== the TC-01 record (TC-1012-08)"
# A FETCH that answers from a script: one "CODE BODY" line per call, from
# $TMP/answers (the last line repeats); CODE "-" is no answer.
fetch_script() {
	_c=$(($(cat "$TMP/calls") + 1)); echo "$_c" >"$TMP/calls"
	_a=$(sed -n "${_c}p" "$TMP/answers"); [ -n "$_a" ] || _a=$(tail -1 "$TMP/answers")
	_code=${_a%% *} _body=${_a#* }
	[ "$_code" = - ] && return 7
	printf '%s' "$_body" >"$1"
	printf '%s' "$_code"
}
answers() { printf '%s\n' "$@" >"$TMP/answers"; echo 0 >"$TMP/calls"; }
for c in '200 {"firstRun":false,"ready":true}|200 firstRun=false ready=true' \
	'200 {"firstRun":false,"ready":false}|200 firstRun=false ready=false' \
	'200 {"firstRun":true,"ready":true}|200 firstRun=true ready=true' \
	'200 {"firstRun":false}|200 firstRun=false ready=unknown' \
	'200 |unparsed' '200 not json|unparsed' '200 {"hasUsers":true}|unparsed' '200 {"firstRun":"no"}|unparsed' \
	'200 [1]|unparsed' '503 {"error":"x"}|503' '000 |noanswer' '- |noanswer'; do
	answers "${c%%|*}"
	OUT=$(ss_status_line fetch_script "$TMP/body")
	check "TC-1012-08 a read '${c%%|*}' is recorded as '${c#*|}'" "$(yes_if test "$OUT" = "${c#*|}")" "$OUT"
done
check "TC-1012-08 the read leaves no body file behind" "$(yes_if test ! -e "$TMP/body")" "$(ls "$TMP")"

R="$TMP/status.log"
probe_status() { ss_status_probe fetch_script "$R"; }
for c in '{"firstRun":false,"ready":true}|0' '{"firstRun":false,"ready":false}|1' '{"firstRun":true,"ready":true}|1' \
	'|1' 'not json|1' '{"ready":true}|1'; do
	: >"$R"; answers "200 ${c%|*}"
	OUT=$(probe_status); RC=$?
	want=${c##*|}
	[ "$want" = 0 ] || want=nonzero
	got=$RC; [ "$got" = 0 ] || got=nonzero
	check "TC-1012-08 ss_status_probe on '${c%|*}': $want" "$(yes_if test "$got" = "$want")" "rc=$RC $OUT"
	check "TC-1012-08 ss_status_probe on '${c%|*}' appends its read to the record" "$(yes_if test "$(wc -l <"$R" | tr -d ' ')" = 1)" "$(cat "$R")"
done
: >"$R"; answers '200 {"firstRun":true,"ready":false}' '200 {"firstRun":false,"ready":true}'
OUT=$(ss_wait "sign-in ready" 3 0 probe_status alive); RC=$?
check "TC-1012-08 a firstRun:true read survives ss_wait's command substitution in the record" \
	"$(yes_if test "$RC:$(head -1 "$R")" = "0:200 firstRun=true ready=false")" "rc=$RC $(cat "$R")"
{ echo noanswer; cat "$R"; } >"$R.v"
OUT=$(ss_status_verdict "$R.v"); RC=$?
check "TC-1012-08 ... and the verdict on it fails, naming it" \
	"$(holds '[ "$RC" = 1 ] && contains "why: a read said firstRun:true" "$OUT"')" "rc=$RC $OUT"

# The background record: it stops on the stop file, or after TRIES reads.
: >"$R"; rm -f "$TMP/stop"
answers '- ' '- ' '200 {"firstRun":false,"ready":true}'
ss_status_record fetch_script "$R" "$TMP/stop" 5 0
check "TC-1012-08 ss_status_record makes TRIES reads and no more" \
	"$(yes_if test "$(tr '\n' '|' <"$R")" = "noanswer|noanswer|200 firstRun=false ready=true|200 firstRun=false ready=true|200 firstRun=false ready=true|")" "$(tr '\n' '|' <"$R")"
: >"$R"; : >"$TMP/stop"
ss_status_record fetch_script "$R" "$TMP/stop" 5 0
check "TC-1012-08 ss_status_record reads nothing once the stop file is there" "$(yes_if test ! -s "$R")" "$(cat "$R")"
: >"$R"; rm -f "$TMP/stop"; answers '- '
stopper() { _c=$(($(cat "$TMP/calls") + 1)); echo "$_c" >"$TMP/calls"; [ "$_c" -lt 2 ] || : >"$TMP/stop"; return 7; }
ss_status_record stopper "$R" "$TMP/stop" 50 0
check "TC-1012-08 ss_status_record ends on the stop file made during a read" "$(yes_if test "$(wc -l <"$R" | tr -d ' ')" = 2)" "$(cat "$R")"

# The verdict, on records written by hand.
verdict() { printf '%s\n' "$@" >"$R"; OUT=$(ss_status_verdict "$R"); RC=$?; }
verdict noanswer noanswer "200 firstRun=false ready=false" noanswer "200 firstRun=false ready=true"
check "TC-1012-08 verdict: no-answers, then closed 200s, passes with its counts" \
	"$(yes_if test "$RC:$OUT" = "0:reads=5 noanswer=3 closed=2 open=0 unparsed=0 other=0")" "rc=$RC $OUT"
verdict noanswer "200 firstRun=false ready=false" "200 firstRun=true ready=true"
check "TC-1012-08 verdict: any firstRun:true fails, named" "$(holds '[ "$RC" = 1 ] && contains "why: a read said firstRun:true" "$OUT"')" "rc=$RC $OUT"
verdict noanswer noanswer 503 unparsed
check "TC-1012-08 verdict: no closed 200 (unparsed is never closed) fails" "$(holds '[ "$RC" = 1 ] && contains "why: no read was a 200 saying firstRun:false" "$OUT"')" "rc=$RC $OUT"
verdict "200 firstRun=false ready=true" noanswer "200 firstRun=false ready=true"
check "TC-1012-08 verdict: no no-answer before the first 200 fails" "$(holds '[ "$RC" = 1 ] && contains "why: no read went unanswered before the first 200" "$OUT"')" "rc=$RC $OUT"
# F-1012-11: an unparsed 200 is an answer, so a no-answer after it is not
# "before the first 200".
verdict unparsed noanswer "200 firstRun=false ready=true"
check "TC-1012-08 verdict: an unparsed read before the first no-answer fails (the record began after the api answered)" \
	"$(holds '[ "$RC" = 1 ] && contains "why: no read went unanswered before the first 200" "$OUT"')" "rc=$RC $OUT"
verdict noanswer unparsed "200 firstRun=false ready=true"
check "TC-1012-08 verdict: an unparsed 200 counts as the first answer, not as closed" \
	"$(yes_if test "$RC:$OUT" = "0:reads=3 noanswer=1 closed=1 open=0 unparsed=1 other=0")" "rc=$RC $OUT"
: >"$R"; OUT=$(ss_status_verdict "$R"); RC=$?
check "TC-1012-08 verdict: an empty record fails" "$(yes_if test "$RC" = 1)" "rc=$RC $OUT"

echo "== ss_move_probe and ss_move_alive (TC-1012-09)"
REC="time=t level=INFO msg=\"record: recorded\" job_id=j1 event=identity.move.step step=record outcome=recorded mode=system"
NR="time=t level=ERROR msg=\"check: failed\" job_id=j1 event=identity.move.failed step=check mode=system cause=not_ready"
BAD="time=t level=ERROR msg=\"import: failed\" job_id=j2 event=identity.move.failed step=import mode=system cause=admin_api status=500 kind=server"
NOCAUSE="time=t level=ERROR msg=\"check: failed\" job_id=j3 event=identity.move.failed step=check mode=system"
# F-1012-12: the move's earlier steps log identity.move.step too; only the
# record step's recorded outcome is the fact.
CHECKED="time=t level=INFO msg=\"check: due\" job_id=j1 event=identity.move.step step=check outcome=due mode=system"
IMPORTED="time=t level=INFO msg=\"import: imported\" job_id=j1 event=identity.move.step step=import outcome=imported mode=system accounts=1 renamed=0 left_out=0"
journal() { printf '%s\r\n' "$JOURNAL"; [ "$1" = 'journalctl -u rasputin-api -b -o cat --no-pager' ]; }
silent() { return 255; }
for c in "$REC|0|the move recorded its last step (0 not_ready" \
	"$NR|1|no record step yet (1 not_ready failures so far)" \
	"$NR
$REC|0|the move recorded its last step (1 not_ready" \
	"$NR
$BAD|2|failed cause=admin_api" \
	"$BAD
$REC|2|failed cause=admin_api" \
	"$NOCAUSE|2|failed cause=none" \
	"$CHECKED
$IMPORTED|1|no record step yet (0 not_ready failures so far)" \
	"$CHECKED
$IMPORTED
$REC|0|the move recorded its last step (0 not_ready" \
	"level=INFO msg=hello|1|no record step yet (0 not_ready"; do
	JOURNAL=${c%%|*} rest=${c#*|}
	want=${rest%%|*} said=${rest#*|}
	OUT=$(ss_move_probe journal); RC=$?
	check "TC-1012-09 journal ending '$(printf '%s' "$JOURNAL" | tail -1 | sed 's/.*event=//')': rc $want, '$said'" \
		"$(holds '[ "$RC" = "$want" ] && contains "$said" "$OUT"')" "rc=$RC $OUT"
	OUT=$(ss_move_alive journal); RC=$?
	alive_want=0; [ "$want" = 2 ] && alive_want=1
	check "TC-1012-09 ss_move_alive on it: rc $alive_want" "$(yes_if test "$RC" = "$alive_want")" "rc=$RC $OUT"
done
OUT=$(ss_move_probe silent); RC=$?
check "TC-1012-09 no answer from RUNNER: waiting (1), named" \
	"$(yes_if test "$RC" = 1 -a "$OUT" = "the api's journal did not answer")" "rc=$RC $OUT"
mp() { ss_move_probe journal; }
ma() { ss_move_alive journal; }
JOURNAL="$NR
$BAD
$REC"
echo 0 >"$TMP/n"
OUT=$(ss_wait "the move recording" 5 0 mp ma); RC=$?
check "TC-1012-09 a failure other than not_ready ends the wait at once, though a recorded line follows" \
	"$(holds '[ "$RC" = 1 ] && [ "$(errors)" = 1 ] && contains "the move failed for good: failed cause=admin_api" "$OUT"')" "rc=$RC $OUT"
JOURNAL="$NR"
OUT=$(ss_wait "the move recording" 3 0 mp ma); RC=$?
check "TC-1012-09 not_ready alone keeps waiting until the ceiling" \
	"$(holds '[ "$RC" = 1 ] && contains "never held in" "$OUT" && contains "(3 reads)" "$OUT"')" "rc=$RC $OUT"

echo "== ss_base_ceremony (TC-1012-11)"
for c in '200 {"hasUsers":true,"userCount":1}|old|0' '200 {"hasUsers":false,"userCount":0}|old|0' \
	'200 {"firstRun":false,"ready":true}|identity|0' '200 {}|unknown|1' '200 not json|unknown|1' \
	'200 |unknown|1' '200 [1]|unknown|1' '503 {"hasUsers":true}|unknown|1' '- |unknown|1'; do
	answers "${c%%|*}"; rest=${c#*|}
	OUT=$(ss_base_ceremony fetch_script); RC=$?
	check "TC-1012-11 '${c%%|*}' is '${rest%|*}', rc ${rest#*|}" "$(yes_if test "$OUT:$RC" = "${rest%|*}:${rest#*|}")" "$OUT rc=$RC"
done

echo "== ss_doors_file (TC-1012-16)"
ss_doors_file c1.local signin.c1.internal "$TMP/doors.json"
check "TC-1012-16 the doors file equals #240's boot-smoke heredoc for the same hosts, after jq -S" \
	"$(yes_if test "$(jq -S . "$TMP/doors.json")" = "$(jq -S . "$ROOT/test/fixtures/smoke-signin/doors-c1.json")")" \
	"$(jq -S -c . "$TMP/doors.json")"

echo "== the step sequence (TC-1012-19)"
# A stub signin.py that fails step $FAIL_AT and logs every step it ran.
cat >"$TMP/steps.py" <<'EOF'
import os, sys
log = os.environ["STEP_LOG"]
with open(log, "a") as f:
    f.write(sys.argv[1] + "\n")
n = sum(1 for _ in open(log))
bad = n == int(os.environ["FAIL_AT"])
print(f"signin {sys.argv[1]} {'FAIL fact=page: no' if bad else 'PASS roles=admin; rp_id=sso-c1.local;'}")
sys.exit(1 if bad else 0)
EOF
# steps — a stand-in sequence of four sg steps; wrapped — it, and then
# update-smoke.sh's report of it (one fail for a set SG_FAIL).
steps() { sg sign-in; sg enrol; SG_RP=$(sg_field rp_id); sg sign-out; sg negative; }
wrapped() {
	FAILS=0 SG_FAIL="" SG_RP=""
	fail() { FAILS=$((FAILS + 1)); echo "FAIL: $*"; }
	steps
	if [ -n "$SG_FAIL" ]; then fail "the move stopped: $SG_FAIL"; fi
	echo "SG_FAIL=$SG_FAIL FAILS=$FAILS RP=$SG_RP"
}
for k in 1 3 0; do
	: >"$TMP/steps.log"
	OUT=$(SS_SIGNIN="$TMP/steps.py" STEP_LOG="$TMP/steps.log" FAIL_AT=$k wrapped)
	ran=$(tr '\n' ' ' <"$TMP/steps.log")
	case $k in
		1) want_ran="sign-in " want="SG_FAIL=signin.py sign-in did not pass FAILS=1 RP=" ;;
		3) want_ran="sign-in enrol sign-out " want="SG_FAIL=signin.py sign-out did not pass FAILS=1 RP=sso-c1.local" ;;
		0) want_ran="sign-in enrol sign-out negative " want="SG_FAIL= FAILS=0 RP=sso-c1.local" ;;
	esac
	check "TC-1012-19 failing step $k: the steps after it do not run" "$(yes_if test "$ran" = "$want_ran")" "$ran"
	want_fails=1; [ "$k" = 0 ] && want_fails=0
	check "TC-1012-19 failing step $k: SG_FAIL names it, and the wrapper makes it $want_fails fail" \
		"$(holds '[ "$(printf "%s\n" "$OUT" | tail -1)" = "$want" ] && [ "$(printf "%s\n" "$OUT" | grep -c "^FAIL: the move stopped: ")" = "$want_fails" ]')" "$OUT"
done

if [ "$fails" -ne 0 ]; then
	echo "smoke-signin-test ($SS_TEST_SHELL): $fails failed"
	exit 1
fi
echo "smoke-signin-test ($SS_TEST_SHELL): all passed"
