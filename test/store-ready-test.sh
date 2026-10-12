#!/bin/sh
#
# Tests for the boot smoke's check that the api reports the secrets store ready
# (geekdojo/geekdojo-brain#834): the readiness verdict, the wait and the
# post-kill report in test/lib/store-ready.sh, the first-run sign-in in
# test/lib/api-session.sh, and the soft passkey in test/lib/soft-passkey.py.
#
# Why. The boot smoke runs only on a release build, so a wrong verdict, a
# sign-in that reports itself as "not ready", or a message that names the
# wrong fact would first show up on the one run where it costs the most. Every
# branch runs here against stubbed collaborators: the HTTP POST, the alerts
# fetch and the liveness check are passed in as functions, and the interval is
# 0. The soft passkey's output is decoded with base64, jq, od and sha256sum,
# never with the helper itself. The real api's side is the pre-cut run recorded
# on the issue, and the QEMU smoke at the store-arming cut.
#
# Shells. The cases run under each shell in TEST_SHELLS (default: whichever of
# sh, dash and bash are installed), each sourcing the libs itself.
#
# Fails closed: a missing lib, jq, python3 or openssl is one FAILED line and a
# non-zero exit, and no case runs.
#
# Run:  sh test/store-ready-test.sh
set -u
LC_ALL=C
export LC_ALL

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SR_LIB="$ROOT/test/lib/store-ready.sh"
AS_LIB="$ROOT/test/lib/api-session.sh"
HELPER="$ROOT/test/lib/soft-passkey.py"
CHECKS="$ROOT/test/lib/checks.sh"
for f in "$CHECKS" "$SR_LIB" "$AS_LIB" "$HELPER"; do
	[ -f "$f" ] || { echo "FAILED: the file $f is missing."; exit 1; }
done
for t in jq python3 openssl; do
	command -v "$t" >/dev/null 2>&1 || { echo "FAILED: $t is not installed, and this suite needs it."; exit 1; }
done

# shellcheck source=SCRIPTDIR/lib/checks.sh
. "$CHECKS"

# matches REGEX TEXT — every line of TEXT matches the basic REGEX.
matches() { ! printf '%s\n' "$2" | grep -qv -- "$1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------------ outer ----
# Runs the cases once per shell, then the cases about the suite itself.
if [ -z "${SR_TEST_SHELL:-}" ]; then
	if [ -z "${TEST_SHELLS:-}" ]; then
		TEST_SHELLS=""
		for s in sh dash bash; do
			command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"
		done
	fi
	TRACE="$TMP/trace"
	mkdir -p "$TRACE"
	for s in $TEST_SHELLS; do
		echo "== cases under $s"
		SR_TEST_SHELL=$s SR_TRACE_DIR=$TRACE "$s" "$0" || fails=$((fails + 1))
	done

	# TC-834-23: the suite fails closed. With the readiness lib absent from a
	# scratch tree, and with jq, python3 or openssl absent from a scratch PATH,
	# it prints one FAILED line naming what is missing, runs no case, and exits
	# non-zero.
	echo "== the suite fails closed (TC-834-23)"
	mkdir -p "$TMP/tree/test/lib"
	cp "$0" "$TMP/tree/test/store-ready-test.sh"
	cp "$CHECKS" "$AS_LIB" "$HELPER" "$TMP/tree/test/lib/"
	for s in $TEST_SHELLS; do
		shp=$(command -v "$s")
		for gone in store-ready.sh jq python3 openssl; do
			bin="$TMP/bin-$gone"
			rm -rf "$bin"; mkdir -p "$bin"
			for t in dirname jq python3 openssl; do
				[ "$t" = "$gone" ] || ln -s "$(command -v "$t")" "$bin/$t"
			done
			if [ "$gone" = store-ready.sh ]; then
				out=$(PATH="$bin" "$shp" "$TMP/tree/test/store-ready-test.sh" 2>&1); rc=$?
			else
				out=$(PATH="$bin" SR_TEST_SHELL='' "$shp" "$0" 2>&1); rc=$?
			fi
			l="TC-834-23 [$s] $gone absent"
			check "$l: exits non-zero" "$(yes_if test "$rc" != 0)" "rc=$rc"
			check "$l: prints exactly one line" "$(yes_if test "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1)" "$out"
			check "$l: the line is a FAILED: sentence" "$(yes_if matches '^FAILED: .*\.$' "$out")" "$out"
			check "$l: the line names $gone" "$(yes_if contains "$gone" "$out")" "$out"
		done
	done

	# TC-834-24: the cases above ran the helper under python3 -m trace as well;
	# at least 70% of its lines ran.
	echo "== soft-passkey.py line coverage (TC-834-24)"
	cover="$TRACE/soft-passkey.cover"
	if [ -f "$cover" ]; then
		hit=$(grep -cE '^ *[0-9]+: ' "$cover")
		miss=$(grep -c '^>>>>>> ' "$cover")
		pct=$((hit * 100 / (hit + miss)))
		echo "  soft-passkey.py: $hit of $((hit + miss)) lines ran ($pct%)"
		check "TC-834-24 soft-passkey.py line coverage is at least 70%" "$(yes_if test "$pct" -ge 70)" "$pct%"
		echo "  the lines that never ran:"
		grep -n '^>>>>>> ' "$cover" | sed 's/^/       /'
	else
		check "TC-834-24 the trace wrote soft-passkey.cover" 1 "$(ls -A "$TRACE")"
	fi

	if [ "$fails" -ne 0 ]; then
		echo "store-ready-test: $fails failed"
		exit 1
	fi
	echo "store-ready-test: all passed"
	exit 0
fi

# ------------------------------------------------------------------ inner ----
# The cases, in the shell this file was started with.
SH=$SR_TEST_SHELL
# shellcheck source=SCRIPTDIR/lib/store-ready.sh
. "$SR_LIB"
# shellcheck source=SCRIPTDIR/lib/api-session.sh
. "$AS_LIB"

T="$TMP/t"
mkdir -p "$T"
lines() { printf '%s\n' "$1" | wc -l | tr -d ' '; }
# jq_true FILTER FILE — jq -e, its output dropped so yes_if reads only the status.
jq_true() { jq -e "$1" "$2" >/dev/null 2>&1; }

# ------------------------------------------------------------ the verdict ----
verdict() {
	printf '%s' "$2" > "$T/body"
	OUT=$(store_ready_verdict "$1" "$T/body"); RC=$?
}

# TC-834-01: 200 and [] is ready, one line, rc 0.
verdict 200 '[]'
check "TC-834-01 [$SH] 200 [] prints exactly 'ready'" "$(yes_if test "$OUT" = ready -a "$(lines "$OUT")" = 1)" "$OUT"
check "TC-834-01 [$SH] 200 [] returns 0" "$(yes_if test "$RC" = 0)" "rc=$RC"

# TC-834-02: alerts from outside the store do not block, and the match is on
# the prefix, not a substring.
verdict 200 '[{"id":"job-failed:x"},{"id":"bus-session:y"},{"id":"job-failed:secret-store:z"}]'
check "TC-834-02 [$SH] other alerts and an embedded secret-store: read ready" "$(yes_if test "$OUT" = ready -a "$RC" = 0)" "rc=$RC $OUT"

# TC-834-03: each not-ready state is named.
for st in sealed uninitialised unreachable audit-blocked quiesced; do
	verdict 200 "[{\"id\":\"secret-store:$st\",\"title\":\"x\"}]"
	check "TC-834-03 [$SH] secret-store:$st reads not-ready naming it" "$(yes_if test "$OUT" = "not-ready: secret-store:$st")" "$OUT"
	check "TC-834-03 [$SH] secret-store:$st returns non-zero" "$(yes_if test "$RC" != 0)" "rc=$RC"
done

# TC-834-04: several store alerts, one line, and only the store's.
verdict 200 '[{"id":"secret-store:sealed"},{"id":"secret-store:audit-blocked"},{"id":"job-failed:x"}]'
check "TC-834-04 [$SH] one not-ready line" "$(yes_if test "$(lines "$OUT")" = 1 -a "${OUT#not-ready: }" != "$OUT")" "$OUT"
check "TC-834-04 [$SH] names secret-store:sealed" "$(yes_if contains secret-store:sealed "$OUT")" "$OUT"
check "TC-834-04 [$SH] names secret-store:audit-blocked" "$(yes_if contains secret-store:audit-blocked "$OUT")" "$OUT"
check "TC-834-04 [$SH] does not name job-failed" "$(yes_if test "$(contains job-failed "$OUT"; echo $?)" = 1)" "$OUT"
check "TC-834-04 [$SH] returns non-zero" "$(yes_if test "$RC" != 0)" "rc=$RC"

# TC-834-05: the status code is read before the body; no answer is not a
# refusal.
for code in 401 403 500; do
	verdict "$code" '[]'
	check "TC-834-05 [$SH] HTTP $code with [] reads 'refused: HTTP $code'" "$(yes_if test "$OUT" = "refused: HTTP $code" -a "$RC" != 0)" "rc=$RC $OUT"
done
for code in 000 ''; do
	verdict "$code" '[]'
	check "TC-834-05 [$SH] code '$code' reads 'no-answer', not refused" "$(yes_if test "$OUT" = no-answer -a "$RC" != 0)" "rc=$RC $OUT"
done

# TC-834-06: an unreadable answer fails closed.
for b in '' 'not json' '{}' 'null' '"x"' '[{"title":"no id"}]' '[{"id":5}]'; do
	verdict 200 "$b"
	check "TC-834-06 [$SH] body '$b' reads unreadable" "$(yes_if test "${OUT#unreadable: }" != "$OUT" -a "$OUT" != "unreadable: " -a "$RC" != 0)" "rc=$RC $OUT"
done
OUT=$(store_ready_verdict 200 "$T/no-such-body"); RC=$?
check "TC-834-06 [$SH] a missing body file reads unreadable" "$(yes_if test "${OUT#unreadable: }" != "$OUT" -a "$RC" != 0)" "rc=$RC $OUT"

# ---------------------------------------------------------------- the wait ----
# stub_fetch answers ans.N on its Nth call; stub_alive records its argument;
# both log their order. The counters live in files because FETCH runs in a
# command substitution.
wait_setup() {
	rm -f "$T"/ans.* "$T/order" "$T/alive.args"
	echo 0 > "$T/fetch.n"
	echo 0 > "$T/alive.n"
	_n=0
	for a in "$@"; do _n=$((_n + 1)); printf '%s' "$a" > "$T/ans.$_n"; done
}
stub_fetch() {
	_f=$(($(cat "$T/fetch.n") + 1)); echo "$_f" > "$T/fetch.n"
	echo fetch >> "$T/order"
	cp "$T/ans.$_f" "$T/fetch.body"
	printf '200 %s\n' "$T/fetch.body"
}
stub_alive() {
	_a=$(($(cat "$T/alive.n") + 1)); echo "$_a" > "$T/alive.n"
	echo alive >> "$T/order"
	printf '%s\n' "$1" >> "$T/alive.args"
}
stub_alive_dies() {
	stub_alive "$1"
	[ "$(cat "$T/alive.n")" = 2 ] && exit 7
	return 0
}
SEALED='[{"id":"secret-store:sealed"}]'
UNREACHABLE='[{"id":"secret-store:unreachable"}]'

# TC-834-07: the deadline, and SR_LAST is the last verdict.
wait_setup "$SEALED" "$SEALED" "$UNREACHABLE"
store_ready_wait 3 0 stub_fetch stub_alive; RC=$?
check "TC-834-07 [$SH] the wait returns 1 when the tries run out" "$(yes_if test "$RC" = 1)" "rc=$RC"
check "TC-834-07 [$SH] FETCH ran exactly 3 times" "$(yes_if test "$(cat "$T/fetch.n")" = 3)" "$(cat "$T/fetch.n")"
check "TC-834-07 [$SH] SR_LAST is the last verdict" "$(yes_if test "$SR_LAST" = "not-ready: secret-store:unreachable")" "$SR_LAST"
WAIT_LAST=$SR_LAST

# TC-834-07: FETCH prints a bare code with no body path (curl got no answer),
# and the wait still runs out with SR_LAST naming it.
echo 0 > "$T/fetch.n"
stub_fetch_bare() {
	_f=$(($(cat "$T/fetch.n") + 1)); echo "$_f" > "$T/fetch.n"
	printf '000\n'
}
store_ready_wait 2 0 stub_fetch_bare stub_alive; RC=$?
check "TC-834-07 [$SH] a bare 000 from FETCH: the wait returns 1" "$(yes_if test "$RC" = 1)" "rc=$RC"
check "TC-834-07 [$SH] a bare 000 from FETCH: FETCH ran exactly 2 times" "$(yes_if test "$(cat "$T/fetch.n")" = 2)" "$(cat "$T/fetch.n")"
check "TC-834-07 [$SH] a bare 000 from FETCH: SR_LAST is no-answer" "$(yes_if test "$SR_LAST" = "no-answer")" "$SR_LAST"

# TC-834-08: the wait stops on the fact, and ALIVE runs before FETCH.
wait_setup "$SEALED" "$SEALED" '[]' '[]' '[]'
store_ready_wait 10 0 stub_fetch stub_alive; RC=$?
check "TC-834-08 [$SH] the wait returns 0 once ready" "$(yes_if test "$RC" = 0)" "rc=$RC"
check "TC-834-08 [$SH] FETCH ran exactly 3 times" "$(yes_if test "$(cat "$T/fetch.n")" = 3)" "$(cat "$T/fetch.n")"
check "TC-834-08 [$SH] ALIVE ran exactly 3 times" "$(yes_if test "$(cat "$T/alive.n")" = 3)" "$(cat "$T/alive.n")"
check "TC-834-08 [$SH] ALIVE ran before FETCH in every round" \
	"$(yes_if test "$(tr '\n' ' ' < "$T/order")" = "alive fetch alive fetch alive fetch ")" "$(tr '\n' ' ' < "$T/order")"
check "TC-834-08 [$SH] ALIVE was told the fact, every round" \
	"$(yes_if test "$(sort -u "$T/alive.args")" = "the api to report the secrets store ready" -a "$(lines "$(cat "$T/alive.args")")" = 3)" "$(cat "$T/alive.args")"

# TC-834-09: a dead dependency ends the wait.
wait_setup "$SEALED" "$SEALED" "$SEALED"
(store_ready_wait 5 0 stub_fetch stub_alive_dies); RC=$?
check "TC-834-09 [$SH] the subshell exits with ALIVE's 7" "$(yes_if test "$RC" = 7)" "rc=$RC"
check "TC-834-09 [$SH] FETCH ran exactly once" "$(yes_if test "$(cat "$T/fetch.n")" = 1)" "$(cat "$T/fetch.n")"

# -------------------------------------------------------------- the report ----
# TC-834-10: the store never reads ready.
OUT=$(store_ready_report wait "" 1 "$WAIT_LAST" 60); RC=$?
check "TC-834-10 [$SH] the never-ready sentence names the last answer" \
	"$(yes_if test "$OUT" = '::error::The api never reported the secrets store ready on a fresh control plane in 60 seconds; its last answer to GET /api/alerts was "not-ready: secret-store:unreachable".')" "$OUT"
check "TC-834-10 [$SH] returns non-zero" "$(yes_if test "$RC" != 0)" "rc=$RC"

# TC-834-11: a sign-in failure is reported as itself.
R="The api's register/finish answered HTTP 400."
OUT=$(store_ready_report signin "$R" "" "" 12); RC=$?
check "TC-834-11 [$SH] the sign-in sentence carries the reason" \
	"$(yes_if test "$OUT" = "::error::The smoke could not sign in to read the api's report of the secrets store. $R")" "$OUT"
check "TC-834-11 [$SH] it does not say never reported" "$(yes_if test "$(contains "never reported" "$OUT"; echo $?)" = 1)" "$OUT"
check "TC-834-11 [$SH] returns non-zero" "$(yes_if test "$RC" != 0)" "rc=$RC"

# TC-834-12: the poll never ran, under set -u with every argument empty.
(set -u; store_ready_report "" "" "" "" "") > "$T/r12.out" 2> "$T/r12.err"; RC=$?
OUT=$(cat "$T/r12.out")
check "TC-834-12 [$SH] only the never-checked sentence" \
	"$(yes_if test "$OUT" = "::error::The smoke never checked whether the api reports the secrets store ready, because the store's self-init line had not reached the serial console when that check was due.")" "$OUT"
check "TC-834-12 [$SH] nothing on stderr" "$(yes_if test ! -s "$T/r12.err")" "$(cat "$T/r12.err")"
check "TC-834-12 [$SH] returns non-zero" "$(yes_if test "$RC" != 0)" "rc=$RC"

# TC-834-13: success.
OUT=$(store_ready_report wait "" 0 ready 42); RC=$?
check "TC-834-13 [$SH] exactly the success line" \
	"$(yes_if test "$OUT" = "The api reports the secrets store ready: GET /api/alerts holds no secret-store alert after 42 seconds.")" "$OUT"
check "TC-834-13 [$SH] returns 0" "$(yes_if test "$RC" = 0)" "rc=$RC"

# ---------------------------------------------------------------- sign-in ----
# stub_post answers from $T/<step>.code, .resp and .jar, where step is begin
# or finish, logs each call and keeps a copy of what was posted.
CHALLENGE="q1w2e3r4t5y6u7i8o9p0ASDFGHJKLzxcvbnm-_QWE"
BEGIN_OK='{"publicKey":{"challenge":"'$CHALLENGE'","rp":{"id":"smoke1.local","name":"Rasputin"},"user":{"id":"dXNlcg","name":"smoke","displayName":"Smoke Test"},"pubKeyCredParams":[{"type":"public-key","alg":-7}],"timeout":300000}}'
TAB=$(printf '\t')
PENDING_VALUE="pendingVALUEnotToLeak42"
SESSION_VALUE="sessionVALUEnotToLeak42"
PENDING_LINE="127.0.0.1${TAB}FALSE${TAB}/${TAB}TRUE${TAB}0${TAB}rasputin-pending${TAB}$PENDING_VALUE"
SESSION_LINE="#HttpOnly_127.0.0.1${TAB}FALSE${TAB}/${TAB}TRUE${TAB}0${TAB}rasputin-session${TAB}$SESSION_VALUE"
BASE="https://127.0.0.1:18443"

stub_post() {
	case "$1" in
		*/api/auth/register/begin) _k=begin ;;
		*/api/auth/register/finish) _k=finish ;;
		*) _k=other ;;
	esac
	printf '%s %s\n' "$_k" "$1" >> "$T/post.log"
	cp "$2" "$T/posted.$_k"
	[ -f "$T/$_k.resp" ] && cp "$T/$_k.resp" "$3"
	[ -f "$T/$_k.jar" ] && printf '%s\n' "$(cat "$T/$_k.jar")" >> "$4"
	cat "$T/$_k.code"
}
# session_setup BEGIN_CODE BEGIN_RESP FINISH_CODE FINISH_RESP FINISH_COOKIE
session_setup() {
	rm -rf "$T/work" "$T/jar" "$T"/begin.* "$T"/finish.* "$T"/posted.* "$T/post.log"
	mkdir -p "$T/work"
	printf '# Netscape HTTP Cookie File\n' > "$T/jar"
	printf '%s' "$1" > "$T/begin.code"
	printf '%s' "$2" > "$T/begin.resp"
	printf '%s' "$PENDING_LINE" > "$T/begin.jar"
	printf '%s' "$3" > "$T/finish.code"
	printf '%s' "$4" > "$T/finish.resp"
	[ -n "$5" ] && printf '%s' "$5" > "$T/finish.jar"
	: > "$T/post.log"
}
# session [PATH-PREFIX] — api_session with the stub, its stdout and stderr apart.
session() {
	OUT=$(
		[ -n "${1:-}" ] && PATH="$1:$PATH"
		api_session stub_post "$BASE" "https://smoke1.local" "$T/jar" "$T/work" "$HELPER" 2> "$T/session.err"
	); RC=$?
	ERR=$(cat "$T/session.err")
}
posted() { grep -c "^$1 " "$T/post.log"; }
work_empty() {
	check "$1: nothing is left under WORK (no DER, no body)" "$(yes_if test -z "$(ls -A "$T/work")")" "$(ls -A "$T/work")"
}
one_reason() {
	check "$1: the reason is exactly: $2" "$(yes_if test "$OUT" = "$2")" "$OUT"
	check "$1: returns 1" "$(yes_if test "$RC" = 1)" "rc=$RC"
	check "$1: nothing on stderr" "$(yes_if test -z "$ERR")" "$ERR"
}

# TC-834-14: begin is refused.
session_setup 503 '{"error":"down"}' 200 '{}' ""
session
l="TC-834-14 [$SH] begin answers 503"
one_reason "$l" "The api's register/begin answered HTTP 503."
check "$l: finish was never posted" "$(yes_if test "$(posted finish)" = 0)" "$(cat "$T/post.log")"
work_empty "$l"

# TC-834-15: options with no challenge, or no rp.id.
session_setup 200 '{"publicKey":{"rp":{"id":"smoke1.local"}}}' 200 '{}' ""
# A python3 that only records that it ran: the helper must not be reached.
mkdir -p "$T/py-spy"
printf '#!/bin/sh\necho ran >> "%s"\nexit 0\n' "$T/helper.ran" > "$T/py-spy/python3"
chmod 0755 "$T/py-spy/python3"
rm -f "$T/helper.ran"
session "$T/py-spy"
l="TC-834-15 [$SH] begin options with no challenge"
one_reason "$l" "The registration options from register/begin carry no challenge."
check "$l: finish was never posted" "$(yes_if test "$(posted finish)" = 0)" "$(cat "$T/post.log")"
check "$l: the helper never ran" "$(yes_if test ! -e "$T/helper.ran")"
work_empty "$l"
session_setup 200 '{"publicKey":{"challenge":"'$CHALLENGE'","rp":{"name":"Rasputin"}}}' 200 '{}' ""
session "$T/py-spy"
l="TC-834-15 [$SH] begin options with no rp.id"
one_reason "$l" "The registration options from register/begin carry no rp.id."
check "$l: finish was never posted" "$(yes_if test "$(posted finish)" = 0)" "$(cat "$T/post.log")"
check "$l: the helper never ran" "$(yes_if test ! -e "$T/helper.ran")"
work_empty "$l"

# TC-834-16: finish is refused, and nothing secret leaks.
session_setup 200 "$BEGIN_OK" 400 '{"error":"verification failed: BODYdetailNotToLeak"}' ""
session
l="TC-834-16 [$SH] finish answers 400"
one_reason "$l" "The api's register/finish answered HTTP 400."
check "$l: the jar does hold the pending cookie the output must not show" "$(yes_if grep -q "$PENDING_VALUE" "$T/jar")"
for secret in "$CHALLENGE" BODYdetailNotToLeak "$PENDING_VALUE"; do
	check "$l: the output does not contain $secret" "$(yes_if test "$(contains "$secret" "$OUT$ERR"; echo $?)" = 1)" "$OUT$ERR"
done
work_empty "$l"

# TC-834-17: 200 with no session cookie.
session_setup 200 "$BEGIN_OK" 200 '{"id":"x"}' ""
session
l="TC-834-17 [$SH] finish answers 200 with no session cookie"
one_reason "$l" "The api's register/finish answered 200 but issued no session cookie."
work_empty "$l"

# TC-834-18: the happy path.
session_setup 200 "$BEGIN_OK" 200 '{"id":"x"}' "$SESSION_LINE"
session
l="TC-834-18 [$SH] the happy path"
check "$l: returns 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT"
check "$l: prints nothing" "$(yes_if test -z "$OUT$ERR")" "$OUT$ERR"
check "$l: begin and finish went to BASE's register routes, in order" \
	"$(yes_if test "$(cut -d' ' -f2 "$T/post.log" | tr '\n' ' ')" = "$BASE/api/auth/register/begin $BASE/api/auth/register/finish ")" "$(cat "$T/post.log")"
check "$l: the body posted to begin is JSON with a non-empty name" \
	"$(yes_if jq_true '.name | type == "string" and length > 0' "$T/posted.begin")" "$(cat "$T/posted.begin")"
# b64u_dec — unpadded base64url to bytes, with tr and base64 -d rather than the helper.
b64u_dec() {
	_s=$(printf '%s' "$1" | tr '_-' '/+')
	case $((${#_s} % 4)) in 2) _s="$_s==" ;; 3) _s="$_s=" ;; esac
	printf '%s' "$_s" | base64 -d
}
b64u_dec "$(jq -r '.response.clientDataJSON' "$T/posted.finish")" > "$T/cd18.json"
check "$l: the finish body's clientDataJSON has origin https://smoke1.local" \
	"$(yes_if test "$(jq -r .origin "$T/cd18.json")" = https://smoke1.local)" "$(cat "$T/cd18.json")"
check "$l: the finish body's clientDataJSON has the begin challenge" \
	"$(yes_if test "$(jq -r .challenge "$T/cd18.json")" = "$CHALLENGE")" "$(cat "$T/cd18.json")"
check "$l: the finish body's clientDataJSON has type webauthn.create" \
	"$(yes_if test "$(jq -r .type "$T/cd18.json")" = webauthn.create)" "$(cat "$T/cd18.json")"
work_empty "$l"

# TC-834-27: no HTTP answer, at begin and at finish.
session_setup 000 '' 200 '{}' ""
session
l="TC-834-27 [$SH] begin gives no answer"
one_reason "$l" "The api's register/begin gave no HTTP answer."
check "$l: finish was never posted" "$(yes_if test "$(posted finish)" = 0)" "$(cat "$T/post.log")"
work_empty "$l"
session_setup 200 "$BEGIN_OK" 000 '' ""
session
l="TC-834-27 [$SH] finish gives no answer"
one_reason "$l" "The api's register/finish gave no HTTP answer."
check "$l: does not say answered HTTP 000" "$(yes_if test "$(contains "answered HTTP 000" "$OUT"; echo $?)" = 1)" "$OUT"
work_empty "$l"

# TC-834-28: openssl cannot make the key.
mkdir -p "$T/no-openssl"
printf '#!/bin/sh\nexit 1\n' > "$T/no-openssl/openssl"
chmod 0755 "$T/no-openssl/openssl"
session_setup 200 "$BEGIN_OK" 200 '{}' "$SESSION_LINE"
session "$T/no-openssl"
l="TC-834-28 [$SH] openssl fails"
one_reason "$l" "OpenSSL could not make a P-256 public key."
check "$l: the reason is a sentence with a capital" "$(yes_if matches '^[A-Z].*\.$' "$OUT")" "$OUT"
check "$l: finish was never posted" "$(yes_if test "$(posted finish)" = 0)" "$(cat "$T/post.log")"
work_empty "$l"

# TC-834-29: the soft passkey cannot encode.
mkdir -p "$T/bad-python"
printf '#!/bin/sh\necho "The options are not JSON." >&2\nexit 2\n' > "$T/bad-python/python3"
chmod 0755 "$T/bad-python/python3"
session_setup 200 "$BEGIN_OK" 200 '{}' "$SESSION_LINE"
session "$T/bad-python"
l="TC-834-29 [$SH] the soft passkey fails"
one_reason "$l" "The soft passkey could not encode the registration: The options are not JSON."
check "$l: finish was never posted" "$(yes_if test "$(posted finish)" = 0)" "$(cat "$T/post.log")"
work_empty "$l"

# ------------------------------------------------------------ soft passkey ----
# passkey OPTIONS-FILE ARG... — the helper under python3 -I, stdout, stderr and
# status apart. With SR_TRACE_DIR set it runs a second time under
# python3 -m trace, output discarded, for TC-834-24's line count: trace
# swallows the helper's exit status, so the asserted run is the untraced one.
passkey() {
	_in=$1; shift
	python3 -I "$HELPER" "$@" < "$_in" > "$T/pk.out" 2> "$T/pk.err"; PRC=$?
	if [ -n "${SR_TRACE_DIR:-}" ]; then
		python3 -I -m trace --count --missing --file "$SR_TRACE_DIR/counts" \
			--coverdir "$SR_TRACE_DIR" "$HELPER" "$@" < "$_in" > /dev/null 2>&1
	fi
	return 0
}
# hex FILE — the file's bytes as one lowercase hex string, with od.
hex() { od -An -tx1 -v "$1" | tr -d ' \n'; }
# bytes HEX FROM N — N bytes of HEX starting at byte FROM.
bytes() { printf '%s' "$1" | cut -c "$(($2 * 2 + 1))-$((($2 + $3) * 2))"; }
# hex_to_bin HEX — bytes from hex, with printf octal escapes.
hex_to_bin() {
	_h=$1
	while [ -n "$_h" ]; do
		_p=${_h%"${_h#??}"}; _h=${_h#??}
		# shellcheck disable=SC2059 # the format is the octal escape being built
		printf "\\$(printf '%03o' "0x$_p")"
	done
}

openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null | openssl ec -pubout -outform DER > "$T/p256.der" 2>/dev/null
openssl ecparam -name secp384r1 -genkey -noout 2>/dev/null | openssl ec -pubout -outform DER > "$T/p384.der" 2>/dev/null
head -c 60 "$T/p256.der" > "$T/short.der"
printf '%s' "$BEGIN_OK" > "$T/opts.json"
CID=fbff00112233445566778899aabbccdd

# TC-834-19: client data, decoded independently. No --credential-id, so main
# draws the id itself.
passkey "$T/opts.json" --origin https://smoke1.local --pubkey-der "$T/p256.der"
l="TC-834-19 [$SH] clientDataJSON"
check "$l: the helper exits 0" "$(yes_if test "$PRC" = 0)" "rc=$PRC $(cat "$T/pk.err")"
b64u_dec "$(jq -r '.response.clientDataJSON' "$T/pk.out")" > "$T/cd19.json"
check "$l: holds exactly type, challenge and origin" \
	"$(yes_if test "$(jq -c 'keys' "$T/cd19.json")" = '["challenge","origin","type"]')" "$(cat "$T/cd19.json")"
check "$l: type is webauthn.create" "$(yes_if test "$(jq -r .type "$T/cd19.json")" = webauthn.create)" "$(cat "$T/cd19.json")"
check "$l: challenge is the options' challenge, byte for byte" "$(yes_if test "$(jq -r .challenge "$T/cd19.json")" = "$CHALLENGE")" "$(cat "$T/cd19.json")"
check "$l: origin is https://smoke1.local" "$(yes_if test "$(jq -r .origin "$T/cd19.json")" = https://smoke1.local)" "$(cat "$T/cd19.json")"

# TC-834-20: the attestation object and authData against the WebAuthn spec,
# with a pinned credential id.
passkey "$T/opts.json" --origin https://smoke1.local --pubkey-der "$T/p256.der" --credential-id "$CID"
l="TC-834-20 [$SH] attestationObject"
check "$l: the helper exits 0" "$(yes_if test "$PRC" = 0)" "rc=$PRC $(cat "$T/pk.err")"
b64u_dec "$(jq -r '.response.attestationObject' "$T/pk.out")" > "$T/att.bin"
ATT=$(hex "$T/att.bin")
# map(3) "fmt" "none" "attStmt" map(0) "authData" bytes(0x94 = 148)
HEAD="a3""63666d74""646e6f6e65""6761747453746d74""a0""686175746844617461""5894"
check "$l: fmt is none, attStmt is an empty map, authData is 148 bytes" "$(yes_if test "$(bytes "$ATT" 0 30)" = "$HEAD")" "$(bytes "$ATT" 0 30)"
AD=$(bytes "$ATT" 30 148)
check "$l: the attestation object ends with authData" "$(yes_if test "${#ATT}" = $(((30 + 148) * 2)))" "${#ATT}"
RPHASH=$(printf '%s' smoke1.local | sha256sum | cut -d' ' -f1)
check "$l: authData 0-31 is sha256(smoke1.local)" "$(yes_if test "$(bytes "$AD" 0 32)" = "$RPHASH")" "$(bytes "$AD" 0 32)"
check "$l: the flags byte is 0x45" "$(yes_if test "$(bytes "$AD" 32 1)" = 45)" "$(bytes "$AD" 32 1)"
check "$l: the sign count is 4 zero bytes" "$(yes_if test "$(bytes "$AD" 33 4)" = 00000000)" "$(bytes "$AD" 33 4)"
check "$l: the AAGUID is 16 zero bytes" "$(yes_if test "$(bytes "$AD" 37 16)" = 00000000000000000000000000000000)" "$(bytes "$AD" 37 16)"
check "$l: the credential id length is 0x0010" "$(yes_if test "$(bytes "$AD" 53 2)" = 0010)" "$(bytes "$AD" 53 2)"
check "$l: the credential id is the pinned one" "$(yes_if test "$(bytes "$AD" 55 16)" = "$CID")" "$(bytes "$AD" 55 16)"
# COSE: map(5) 1:2 (kty EC2) 3:-7 (alg ES256) -1:1 (crv P-256) -2:bytes(32) x -3:bytes(32) y
DER=$(hex "$T/p256.der")
XY=$(bytes "$DER" 27 64)
check "$l: COSE kty 2, alg -7, crv 1, then x" "$(yes_if test "$(bytes "$AD" 71 10)" = "a50102032620012158""20")" "$(bytes "$AD" 71 10)"
check "$l: COSE x is the DER's x" "$(yes_if test "$(bytes "$AD" 81 32)" = "$(bytes "$XY" 0 32)")" "$(bytes "$AD" 81 32)"
check "$l: COSE -3 is a 32-byte y" "$(yes_if test "$(bytes "$AD" 113 3)" = 225820)" "$(bytes "$AD" 113 3)"
check "$l: COSE y is the DER's y" "$(yes_if test "$(bytes "$AD" 116 32)" = "$(bytes "$XY" 32 32)")" "$(bytes "$AD" 116 32)"

# TC-834-21: the PublicKeyCredential envelope.
CID_B64U=$(hex_to_bin "$CID" | base64 | tr '+/' '-_' | tr -d '=\n')
l="TC-834-21 [$SH] the envelope"
check "$l: type is public-key" "$(yes_if test "$(jq -r .type "$T/pk.out")" = public-key)" "$(cat "$T/pk.out")"
check "$l: id is the credential id, unpadded base64url" "$(yes_if test "$(jq -r .id "$T/pk.out")" = "$CID_B64U")" "$(jq -r .id "$T/pk.out") want $CID_B64U"
check "$l: rawId equals id" "$(yes_if test "$(jq -r .rawId "$T/pk.out")" = "$CID_B64U")" "$(jq -r .rawId "$T/pk.out")"
check "$l: response carries clientDataJSON and attestationObject" \
	"$(yes_if jq_true '.response | (.clientDataJSON | type == "string") and (.attestationObject | type == "string")' "$T/pk.out")" "$(cat "$T/pk.out")"

# TC-834-22: bad input fails closed.
printf '%s' '{"publicKey":{"rp":{"id":"smoke1.local"}}}' > "$T/no-challenge.json"
printf '%s' '{"publicKey":{"challenge":"'$CHALLENGE'","rp":{}}}' > "$T/no-rpid.json"
printf '%s' 'not json' > "$T/not-json.json"
printf '%s' '{"rp":{"id":"smoke1.local"},"challenge":"'$CHALLENGE'"}' > "$T/no-publickey.json"
printf '%s' '{"publicKey":"'$CHALLENGE'"}' > "$T/publickey-not-object.json"
# fails_closed LABEL — the TC-834-22 assertions on the last passkey run.
fails_closed() {
	check "$1: exits 2" "$(yes_if test "$PRC" = 2)" "rc=$PRC"
	check "$1: nothing on stdout" "$(yes_if test ! -s "$T/pk.out")" "$(cat "$T/pk.out")"
	check "$1: one sentence on stderr" \
		"$(yes_if test "$(wc -l < "$T/pk.err" | tr -d ' ')" = 1 -a "$(grep -c '^[A-Z].*\.$' "$T/pk.err")" = 1)" "$(cat "$T/pk.err")"
}
for row in "no-challenge.json p256.der" "no-rpid.json p256.der" "not-json.json p256.der" \
	"opts.json absent.der" "opts.json short.der" "opts.json p384.der" \
	"no-publickey.json p256.der" "publickey-not-object.json p256.der"; do
	in=${row%% *}; der=${row#* }
	passkey "$T/$in" --origin https://smoke1.local --pubkey-der "$T/$der"
	fails_closed "TC-834-22 [$SH] $in with $der"
done
# TC-834-22: a --credential-id that is not hex.
passkey "$T/opts.json" --origin https://smoke1.local --pubkey-der "$T/p256.der" --credential-id not-hex
fails_closed "TC-834-22 [$SH] --credential-id not-hex"

if [ "$fails" -ne 0 ]; then
	echo "store-ready-test [$SH]: $fails failed"
	exit 1
fi
echo "store-ready-test [$SH]: all passed"
