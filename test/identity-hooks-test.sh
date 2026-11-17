#!/bin/sh
#
# Tests for rasputin-keycloak-hooks.sh, keycloak.service's three hooks
# (geekdojo/geekdojo-brain#973, TC-973-07 to TC-973-14): the start-failure
# hold, the start wait and the exit records, held to the #979 file contract
# the api's identity monitor reads.
#
# Why. The hold decides whether the sign-in service may start at all, the wait
# decides when it reads `active`, and the records are the only way the api
# learns why a start failed. A wrong count, a hold record that loses its cause
# (F-973-01), a wait that exits 1 on a stop (F-973-02) or a record outside the
# contract is a failure nobody sees until a node is held. So every branch runs
# against a scratch tree, with a fake systemctl and a fake curl, and each run's
# files, modes, exit status and log lines are checked.
#
# How. The real script runs with every collaborator pointed at scratch files
# through RASPUTIN_KCHOOK_*. No root, no systemd, no network: what systemd does
# with the hooks is test/identity-unit-functional.sh.
#
# Shells. Every case runs under each shell in TEST_SHELLS (default: whichever
# of sh, dash and bash are installed), under `busybox sh`, and under
# `busybox sh` with busybox's own applets ahead of PATH, so the image's ls,
# rm, mv, chmod, cat, mkdir, sed, grep, head and tail are the ones exercised.
# REQUIRE_BUSYBOX=1 (CI sets it) makes a missing busybox a failure.
#
# Root. The suite refuses to run as root, with a failure and not a skip: root
# writes into a mode-0500 directory, so the fail-closed cases would pass over
# nothing.
#
# Run:  sh test/identity-hooks-test.sh
set -u
LC_ALL=C
export LC_ALL

if [ "$(id -u)" = 0 ]; then
	echo "FAILED: this suite must not run as root, because root writes into a mode-0500 directory and the fail-closed cases would prove nothing." >&2
	exit 1
fi
if [ "${REQUIRE_BUSYBOX:-0}" = "1" ] && ! command -v busybox >/dev/null 2>&1; then
	echo "FAILED: REQUIRE_BUSYBOX=1 but busybox is not installed." >&2
	exit 1
fi

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
SCRIPT="$OVERLAY/usr/lib/rasputin/identity/rasputin-keycloak-hooks.sh"
LIB="$OVERLAY/usr/lib/rasputin/outcome/outcome.sh"
for f in "$SCRIPT" "$LIB"; do
	[ -f "$f" ] || { echo "FAILED: the file $f is missing." >&2; exit 1; }
done

if [ -z "${TEST_SHELLS:-}" ]; then
	TEST_SHELLS=""
	for s in sh dash bash; do
		command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"
	done
fi

TMP=$(mktemp -d)
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

BUSYBOX_DIR=""
if command -v busybox >/dev/null 2>&1; then
	BUSYBOX_DIR="$TMP/busybox-applets"
	mkdir -p "$BUSYBOX_DIR"
	for applet in ls mv chmod rm cat mkdir dirname sed grep head tail sleep; do
		printf '#!/bin/sh\nexec busybox %s "$@"\n' "$applet" > "$BUSYBOX_DIR/$applet"
		chmod 0755 "$BUSYBOX_DIR/$applet"
	done
	TEST_SHELLS="$TEST_SHELLS busybox_sh busybox_applets"
fi

pass=0
fail=0
SH=""

ok() {
	if [ "$2" = 0 ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf '  FAIL [%s] %s\n' "$SH" "$1" >&2
		[ -n "${3:-}" ] && printf '       %s\n' "$3" | head -20 >&2
	fi
	return 0
}
yes_if() { if "$@"; then echo 0; else echo 1; fi; }
perms() { ls -ld "$1" 2>/dev/null | cut -c1-10; }
TAG=rasputin-keycloak-hooks
BOOT_ID="b00710d0-0000-4000-8000-000000000973"
ID_A=0123456789abcdef0123456789abcdef
ID_B=fedcba9876543210fedcba9876543210

# The fakes. systemctl answers `show -P NRestarts` from $F/nrestarts (failing
# when that file is absent) and `show -P MainPID` from $F/mainpid, one line per
# call, the last line repeating. curl records its argv, one word per line, in
# $F/argv.<call>, counts its calls in $F/calls, and answers from $F/answers,
# one "RC CODE BODY" line per call, the last repeating: it prints BODY, a
# newline and CODE (as `-w '\n%{http_code}'` does) and exits RC.
FAKES="$TMP/fakes"
mkdir -p "$FAKES"
cat > "$FAKES/systemctl" <<'EOF'
#!/bin/sh
F=$FAKE_DIR
pop() {
	_v=$(head -n 1 "$1")
	[ "$(grep -c . "$1")" -gt 1 ] && { tail -n +2 "$1" > "$1.n"; mv "$1.n" "$1"; }
	printf '%s\n' "$_v"
}
case "$3" in
	NRestarts) [ -f "$F/nrestarts" ] || exit 1; cat "$F/nrestarts" ;;
	MainPID) pop "$F/mainpid" ;;
	*) exit 1 ;;
esac
EOF
cat > "$FAKES/curl" <<'EOF'
#!/bin/sh
F=$FAKE_DIR
n=$(( $(cat "$F/calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$F/calls"
for a in "$@"; do printf '%s\n' "$a"; done > "$F/argv.$n"
line=$(head -n 1 "$F/answers")
[ "$(grep -c . "$F/answers")" -gt 1 ] && { tail -n +2 "$F/answers" > "$F/answers.n"; mv "$F/answers.n" "$F/answers"; }
rc=${line%% *}; rest=${line#* }; code=${rest%% *}; body=${rest#* }
printf '%s\n%s' "$body" "$code"
exit "$rc"
EOF
chmod 0755 "$FAKES/systemctl" "$FAKES/curl"

# setup — a fresh scratch tree: the count's directory (0700), no hold or exits
# directory yet (the script makes them), PKI files, a boot id and a console.
setup() {
	W=$(mktemp -d "$TMP/w.XXXXXX")
	F="$W/fake"
	mkdir -p "$F" "$W/identity" "$W/pki"
	chmod 0700 "$W/identity"
	COUNT="$W/identity/start-failures"
	HOLD_DIR="$W/hold"
	HOLD="$HOLD_DIR/outcome"
	EXITS="$W/exits"
	printf '%s\n' "$BOOT_ID" > "$W/bootid"
	: > "$W/kmsg"
	printf 'CA\n' > "$W/pki/ca.pem"
	printf 'CERT\n' > "$W/pki/leaf.pem"
	printf 'KEY-BYTES-MUST-NOT-LEAK\n' > "$W/pki/leaf.key"
	chmod 0600 "$W/pki/leaf.key"
	CURL_BIN="$FAKES/curl"
}

# launch PHASE [VAR=VALUE ...] — exec the script under $SH, with the given
# extra environment. Called in a subshell, so its process is the script's.
launch() {
	_phase=$1; shift
	case "$SH" in
		busybox_sh|busybox_applets) _cmd="busybox sh" ;;
		*) _cmd=$SH ;;
	esac
	_path=$PATH
	[ "$SH" = busybox_applets ] && _path="$BUSYBOX_DIR:$PATH"
	# shellcheck disable=SC2086 # _cmd is "busybox sh" on purpose
	exec env PATH="$_path" FAKE_DIR="$F" \
		RASPUTIN_KCHOOK_SYSTEMCTL="$FAKES/systemctl" RASPUTIN_KCHOOK_CURL="$CURL_BIN" \
		RASPUTIN_KCHOOK_UNIT=keycloak.service RASPUTIN_KCHOOK_COUNT="$COUNT" \
		RASPUTIN_KCHOOK_HOLD_DIR="$HOLD_DIR" RASPUTIN_KCHOOK_EXITS_DIR="$EXITS" \
		RASPUTIN_KCHOOK_CA="$W/pki/ca.pem" RASPUTIN_KCHOOK_CERT="$W/pki/leaf.pem" \
		RASPUTIN_KCHOOK_KEY="$W/pki/leaf.key" RASPUTIN_KCHOOK_URL=https://127.0.0.1:8544/health/started \
		RASPUTIN_KCHOOK_BOOTID="$W/bootid" RASPUTIN_KCHOOK_KMSG="$W/kmsg" RASPUTIN_KCHOOK_RECHECK=0 "$@" \
		$_cmd "$SCRIPT" "$_phase"
}
# run PHASE [VAR=VALUE ...] — launch it and wait; stdout, stderr and status
# apart.
run() {
	(launch "$@") > "$W/stdout" 2> "$W/stderr"
	RC=$?
	OUT=$(cat "$W/stdout")
}
# logged PRIORITY TEXT — stdout (the journal) has a <PRIORITY>TAG: line
# containing TEXT.
logged() { printf '%s\n' "$OUT" | grep "^<$1>$TAG: " | grep -qF -- "$2"; }
# console_same — the console sink holds stdout's last line, identical
# (outcome_log opens the sink afresh for each line, as /dev/kmsg is).
console_same() { test -n "$OUT" && test "$(cat "$W/kmsg")" = "$(printf '%s\n' "$OUT" | tail -n 1)"; }
# exit_rec ID OUTCOME CODE STATUS — an exit record as the exit phase writes it.
exit_rec() {
	mkdir -p "$EXITS"
	printf 'outcome=%s\ninvocation_id=%s\nexit_code=%s\nexit_status=%s\n' "$2" "$1" "$3" "$4" > "$EXITS/$1"
}
# records — how many record names (32 lowercase hex characters) $EXITS holds.
records() { find "$EXITS" -type f -name '????????????????????????????????' | grep -cE '/[0-9a-f]{32}$'; }
hold_reason() { sed -n 's/^reason=//p' "$HOLD" 2>/dev/null; }
# has_word WORD LIST — one line of LIST is exactly WORD.
has_word() { printf '%s\n' "$2" | grep -qxF -- "$1"; }
contains_mem() { hold_reason | grep -qF '(its last start ran out of memory)'; }

for SH in $TEST_SHELLS; do

	# --- hold -------------------------------------------------------------------
	# TC-973-07: NRestarts=0 is a start that was asked for: the hold re-arms.
	setup
	printf '3\n' > "$COUNT"
	mkdir -p "$HOLD_DIR"
	printf 'outcome=refused\nboot_id=%s\nreason=Held.\n' "$BOOT_ID" > "$HOLD"
	echo 0 > "$F/nrestarts"
	run hold
	ok "TC-973-07 a re-arm exits 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT"
	ok "TC-973-07 a re-arm removes the hold record" "$(yes_if test ! -e "$HOLD")"
	ok "TC-973-07 a re-arm counts this start as 1" "$(yes_if test "$(cat "$COUNT")" = 1)" "$(cat "$COUNT")"
	ok "TC-973-07 the count is 0600" "$(yes_if test "$(perms "$COUNT")" = "-rw-------")" "$(perms "$COUNT")"
	ok "TC-973-07 a <6> re-armed line" "$(yes_if logged 6 re-armed)" "$OUT"
	ok "TC-973-07 the console got the same line" "$(yes_if console_same)" "$(cat "$W/kmsg")"
	# A re-arm with nothing to clear says nothing.
	setup
	echo 0 > "$F/nrestarts"
	run hold
	ok "TC-973-07 a first start counts 1 and logs no re-arm" \
		"$(yes_if test "$RC" = 0 -a "$(cat "$COUNT")" = 1 -a -z "$OUT")" "rc=$RC count=$(cat "$COUNT") $OUT"

	# TC-973-08: count, then refusal, the cause from the record `last` names.
	setup
	exit_rec "$ID_A" exit-code exited 137
	printf '%s\n' "$ID_A" > "$EXITS/last"
	for n in 1 2 3; do
		echo "$n" > "$F/nrestarts"
		run hold
		ok "TC-973-08 NRestarts=$n: exit 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT"
		ok "TC-973-08 NRestarts=$n: the count is $n" "$(yes_if test "$(cat "$COUNT")" = "$n")" "$(cat "$COUNT")"
	done
	ok "TC-973-08 no hold record before the refusal" "$(yes_if test ! -e "$HOLD")"
	echo 4 > "$F/nrestarts"
	run hold
	ok "TC-973-08 NRestarts=4: refused, exit 1" "$(yes_if test "$RC" = 1)" "rc=$RC $OUT"
	want_reason="The sign-in service did not finish starting three times in a row (its last start ended with exit-code, status 137), so it is held stopped until it is restarted, its certificate is renewed or the system is updated."
	want="outcome=refused
boot_id=$BOOT_ID
reason=$want_reason"
	ok "TC-973-08 the hold record is exactly outcome, boot_id and the reason naming status 137" \
		"$(yes_if test "$(cat "$HOLD")" = "$want")" "$(cat "$HOLD" 2>&1)"
	ok "TC-973-08 the record is 0600" "$(yes_if test "$(perms "$HOLD")" = "-rw-------")" "$(perms "$HOLD")"
	ok "TC-973-08 its directory is 0700" "$(yes_if test "$(perms "$HOLD_DIR")" = "drwx------")" "$(perms "$HOLD_DIR")"
	ok "TC-973-08 a <3> line with the reason" "$(yes_if logged 3 "status 137")" "$OUT"
	ok "TC-973-08 the console got the same line" "$(yes_if console_same)" "$(cat "$W/kmsg")"
	ok "TC-973-08 the count stays 3" "$(yes_if test "$(cat "$COUNT")" = 3)"
	first_reason=$(hold_reason)

	# TC-973-09 (F-973-01): the refusal's own exit record, with no exit code or
	# status, becomes `last`; later refusals keep the first cause.
	for n in 5 6; do
		run exit INVOCATION_ID="$(printf '%032d' "$n")" SERVICE_RESULT=exit-code
		echo "$n" > "$F/nrestarts"
		run hold
		ok "TC-973-09 NRestarts=$n: still refused, exit 1" "$(yes_if test "$RC" = 1)" "rc=$RC"
		ok "TC-973-09 NRestarts=$n: a <3> line naming the record" "$(yes_if logged 3 "still held")" "$OUT"
	done
	ok "TC-973-09 \`last\` now names a refusal's record, with empty exit fields" \
		"$(yes_if grep -qx 'exit_status=' "$EXITS/$(cat "$EXITS/last")")"
	ok "TC-973-09 after the third refusal the reason is the first refusal's, naming status 137" \
		"$(yes_if test "$(hold_reason)" = "$first_reason")" "got: $(hold_reason)"

	# TC-973-08: status 3 and oom-kill are worded as out of memory.
	for rec in "exited 3 exit-code" "killed KILL oom-kill"; do
		# shellcheck disable=SC2086 # the three words of rec, on purpose
		set -- $rec
		setup
		exit_rec "$ID_A" "$3" "$1" "$2"
		printf '%s\n' "$ID_A" > "$EXITS/last"
		echo 3 > "$COUNT"
		echo 4 > "$F/nrestarts"
		run hold
		ok "TC-973-08 a last start with $3/$1/$2: the reason names out of memory" \
			"$(yes_if contains_mem)" "$(hold_reason)"
	done

	# TC-973-10: failure paths.
	for bad in abc '' -1 'two
lines'; do
		setup
		printf '%s\n' "$bad" > "$COUNT"
		[ -z "$bad" ] && : > "$COUNT"
		echo 2 > "$F/nrestarts"
		run hold
		ok "TC-973-10 a count of '$bad': refused, exit 1" "$(yes_if test "$RC" = 1)" "rc=$RC"
		ok "TC-973-10 a count of '$bad': a <3> line naming the count" "$(yes_if logged 3 "$COUNT")" "$OUT"
	done
	setup
	chmod 0500 "$W/identity"
	echo 1 > "$F/nrestarts"
	run hold
	ok "TC-973-10 an unwritable count directory: exit 1" "$(yes_if test "$RC" = 1)" "rc=$RC"
	ok "TC-973-10 an unwritable count directory: a <3> line naming the path" "$(yes_if logged 3 "$COUNT")" "$OUT"
	ok "TC-973-10 an unwritable count directory: no hold record" "$(yes_if test ! -e "$HOLD")"
	chmod 0700 "$W/identity"
	setup
	echo 1 > "$COUNT"
	run hold
	ok "TC-973-10 NRestarts unreadable: a <4> line" "$(yes_if logged 4 "restart count")" "$OUT"
	ok "TC-973-10 NRestarts unreadable: the start is counted (2), exit 0" \
		"$(yes_if test "$RC" = 0 -a "$(cat "$COUNT")" = 2)" "rc=$RC count=$(cat "$COUNT")"
	unknown="The sign-in service did not finish starting three times in a row, and the cause is unknown, so it is held stopped until it is restarted, its certificate is renewed or the system is updated."
	for case in "no last" "last names a missing record"; do
		setup
		echo 3 > "$COUNT"
		echo 4 > "$F/nrestarts"
		[ "$case" = "no last" ] || { mkdir -p "$EXITS"; printf '%s\n' "$ID_B" > "$EXITS/last"; }
		run hold
		ok "TC-973-10 $case: refused, exit 1" "$(yes_if test "$RC" = 1)" "rc=$RC"
		ok "TC-973-10 $case: the reason says the cause is unknown" "$(yes_if test "$(hold_reason)" = "$unknown")" "$(hold_reason)"
	done
	setup
	echo 3 > "$COUNT"
	echo 4 > "$F/nrestarts"
	mkdir -p "$HOLD_DIR"
	chmod 0500 "$HOLD_DIR"
	run hold
	ok "TC-973-10 an unwritable hold directory: still refused, exit 1" "$(yes_if test "$RC" = 1)" "rc=$RC"
	ok "TC-973-10 an unwritable hold directory: outcome_record's <3> line" "$(yes_if logged 3 "could not be written")" "$OUT"
	chmod 0700 "$HOLD_DIR"

	# --- wait -------------------------------------------------------------------
	# TC-973-11: 503, then 200 without UP, then 200 with UP.
	setup
	echo 2 > "$COUNT"
	printf '0 503 {"status": "DOWN"}\n0 200 {"status": "DOWN"}\n0 200 {"status": "UP", "checks": []}\n' > "$F/answers"
	echo 4242 > "$F/mainpid"
	run wait MAINPID=4242
	ok "TC-973-11 UP: exit 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT"
	ok "TC-973-11 UP after the third call" "$(yes_if test "$(cat "$F/calls")" = 3)" "calls=$(cat "$F/calls")"
	ok "TC-973-11 UP removes the count" "$(yes_if test ! -e "$COUNT")"
	argv=$(cat "$F/argv.3")
	for want in --tlsv1.3 "$W/pki/ca.pem" "$W/pki/leaf.pem" "$W/pki/leaf.key" https://127.0.0.1:8544/health/started; do
		ok "TC-973-11 curl's argv holds $want" "$(yes_if has_word "$want" "$argv")" "$argv"
	done
	ok "TC-973-11 curl's argv holds --cacert, --cert and --key before their paths" \
		"$(yes_if test "$(printf '%s\n' "$argv" | grep -A1 -x -e --cacert -e --cert -e --key | grep -v -e '^--' | tr '\n' ' ')" = "$W/pki/ca.pem $W/pki/leaf.pem $W/pki/leaf.key ")" "$argv"
	ok "TC-973-11 no byte of the key file's contents in any argv" \
		"$(yes_if test -z "$(cat "$F"/argv.* | grep -F KEY-BYTES-MUST-NOT-LEAK)")"
	ok "TC-973-11 one line only, the <6> started line: no per-tick line" \
		"$({ test "$(printf '%s\n' "$OUT" | grep -c .)" = 1 && logged 6 "answered UP"; } && echo 0 || echo 1)" "$OUT"
	ok "TC-973-11 nothing on stderr" "$(yes_if test ! -s "$W/stderr")" "$(cat "$W/stderr")"

	# TC-973-12: the inputs, each before any curl call.
	for case in mainpid curl ca cert key; do
		setup
		echo '0 200 {"status": "UP"}' > "$F/answers"
		echo 4242 > "$F/mainpid"
		set -- MAINPID=4242
		case "$case" in
			mainpid) set -- ;;
			curl) CURL_BIN="$W/no-curl" ;;
			ca) rm -f "$W/pki/ca.pem" ;;
			cert) rm -f "$W/pki/leaf.pem" ;;
			key) chmod 0000 "$W/pki/leaf.key" ;;
		esac
		run wait "$@"
		ok "TC-973-12 $case missing: exit 1" "$(yes_if test "$RC" = 1)" "rc=$RC $OUT"
		ok "TC-973-12 $case missing: no curl call" "$(yes_if test ! -e "$F/calls")"
		case "$case" in
			mainpid) want="main process ID" ;;
			curl) want="$W/no-curl is missing" ;;
			ca) want="$W/pki/ca.pem cannot be read" ;;
			cert) want="$W/pki/leaf.pem cannot be read" ;;
			key) want="$W/pki/leaf.key cannot be read" ;;
		esac
		ok "TC-973-12 $case missing: a <3> sentence naming it" "$(yes_if logged 3 "$want")" "$OUT"
	done
	# MainPID changes to 0 mid-wait: exit 1 on that tick, with the last answer.
	setup
	echo '0 503 {"status": "DOWN"}' > "$F/answers"
	printf '4242\n0\n' > "$F/mainpid"
	run wait MAINPID=4242
	ok "TC-973-12 the main process gone: exit 1" "$(yes_if test "$RC" = 1)" "rc=$RC"
	ok "TC-973-12 the main process gone: on the tick it changed (the second call)" "$(yes_if test "$(cat "$F/calls")" = 2)" "calls=$(cat "$F/calls")"
	ok "TC-973-12 the main process gone: a <3> line with the last HTTP code" "$(yes_if logged 3 "last answer: HTTP 503")" "$OUT"
	setup
	echo '7 000 ' > "$F/answers"
	echo 0 > "$F/mainpid"
	run wait MAINPID=4242
	ok "TC-973-12 the main process gone: a <3> line with curl's exit" "$(yes_if logged 3 "last answer: curl exit 7")" "$OUT"
	# The count unremovable after UP: exit 0, <3>.
	setup
	echo 2 > "$COUNT"
	chmod 0500 "$W/identity"
	echo '0 200 {"status": "UP"}' > "$F/answers"
	echo 4242 > "$F/mainpid"
	run wait MAINPID=4242
	ok "TC-973-12 the count unremovable after UP: exit 0" "$(yes_if test "$RC" = 0)" "rc=$RC"
	ok "TC-973-12 the count unremovable after UP: a <3> line" "$(yes_if logged 3 "a later start may be held early")" "$OUT"
	chmod 0700 "$W/identity"

	# TC-973-13 (F-973-02): TERM in the loop exits 143 with a <4> line.
	setup
	echo '0 503 {"status": "DOWN"}' > "$F/answers"
	echo 4242 > "$F/mainpid"
	(launch wait MAINPID=4242 RASPUTIN_KCHOOK_RECHECK=1) > "$W/stdout" 2> "$W/stderr" &
	bg=$!
	# The fact to wait on: the loop has made its first call. The bound is the
	# test's, never the script's.
	i=0
	while [ ! -s "$F/calls" ] && [ "$i" -lt 400 ]; do sleep 0.05; i=$((i + 1)); done
	kill -TERM "$bg" 2>/dev/null
	wait "$bg"
	TERM_RC=$?
	OUT=$(cat "$W/stdout")
	ok "TC-973-13 TERM in the loop: a <4> line with the last answer" "$(yes_if logged 4 "stopped before /health/started answered UP (last answer: HTTP 503)")" "$OUT"
	ok "TC-973-13 TERM in the loop: exit 143, never 1" "$(yes_if test "$TERM_RC" = 143)" "rc=$TERM_RC"

	# --- exit -------------------------------------------------------------------
	# TC-973-14: the record, `last`, modes.
	setup
	run exit INVOCATION_ID="$ID_A" SERVICE_RESULT=success EXIT_CODE=exited EXIT_STATUS=143
	want="outcome=success
invocation_id=$ID_A
exit_code=exited
exit_status=143"
	ok "TC-973-14 exit 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT"
	ok "TC-973-14 the record is exactly the four lines, in order" "$(yes_if test "$(cat "$EXITS/$ID_A")" = "$want")" "$(cat "$EXITS/$ID_A" 2>&1)"
	ok "TC-973-14 the record is 0600" "$(yes_if test "$(perms "$EXITS/$ID_A")" = "-rw-------")" "$(perms "$EXITS/$ID_A")"
	ok "TC-973-14 the directory is 0700" "$(yes_if test "$(perms "$EXITS")" = "drwx------")" "$(perms "$EXITS")"
	ok "TC-973-14 last holds the id" "$(yes_if test "$(cat "$EXITS/last")" = "$ID_A")" "$(cat "$EXITS/last")"
	ok "TC-973-14 no temp file is left" "$(yes_if test -z "$(find "$EXITS" -name '*.tmp')")" "$(ls "$EXITS")"
	ok "TC-973-14 nothing is logged" "$(yes_if test -z "$OUT")" "$OUT"
	run exit INVOCATION_ID="$ID_B" SERVICE_RESULT=exit-code
	ok "TC-973-14 unset EXIT_CODE and EXIT_STATUS give empty values" \
		"$(yes_if test "$(cat "$EXITS/$ID_B")" = "outcome=exit-code
invocation_id=$ID_B
exit_code=
exit_status=")" "$(cat "$EXITS/$ID_B")"
	ok "TC-973-14 last names the newer record" "$(yes_if test "$(cat "$EXITS/last")" = "$ID_B")"
	# A record that cannot be written leaves `last` unchanged.
	chmod 0500 "$EXITS"
	run exit INVOCATION_ID=00000000000000000000000000000001 SERVICE_RESULT=success
	chmod 0700 "$EXITS"
	ok "TC-973-14 a failed record write: exit 0" "$(yes_if test "$RC" = 0)" "rc=$RC"
	ok "TC-973-14 a failed record write: <3>" "$(yes_if logged 3 "could not be written")" "$OUT"
	ok "TC-973-14 a failed record write: last unchanged" "$(yes_if test "$(cat "$EXITS/last")" = "$ID_B")" "$(cat "$EXITS/last")"
	# Bad ids write nothing.
	for bad in "0123456789ABCDEF0123456789ABCDEF" "0123456789abcdef0123456789abcde" \
		"0123456789abcdef/123456789abcdef" "0123456789abcdef..3456789abcdef0" ""; do
		setup
		run exit INVOCATION_ID="$bad" SERVICE_RESULT=success
		ok "TC-973-14 the id '$bad': exit 0" "$(yes_if test "$RC" = 0)" "rc=$RC"
		ok "TC-973-14 the id '$bad': nothing written" "$(yes_if test ! -e "$EXITS")" "$(ls -R "$EXITS" 2>&1)"
		ok "TC-973-14 the id '$bad': a <3> line" "$(yes_if logged 3 "not 32 lowercase hex")" "$OUT"
	done
	# The cap: 300 records, the oldest by mtime removed until 256 remain.
	setup
	mkdir -p "$EXITS"
	i=0
	while [ "$i" -lt 300 ]; do
		id=$(printf '%032x' $((i + 1000)))
		exit_rec "$id" success exited 143
		touch -t "$(printf '202601%02d%02d%02d.00' $((i / 1440 + 1)) $((i / 60 % 24)) $((i % 60)))" "$EXITS/$id"
		i=$((i + 1))
	done
	oldest=$(printf '%032x' 1000)
	printf '%s\n' "$oldest" > "$EXITS/last"
	: > "$EXITS/0000000000000000000000000000000a.tmp"
	touch -t 202501010000.00 "$EXITS/0000000000000000000000000000000a.tmp" "$EXITS/last"
	# `last` cannot be rewritten (last.tmp is a directory), so it still names
	# the oldest record when the cap runs.
	mkdir "$EXITS/last.tmp"
	run exit INVOCATION_ID="$ID_A" SERVICE_RESULT=success EXIT_CODE=exited EXIT_STATUS=143
	n=$(records)
	ok "TC-973-14 the cap leaves exactly 256 records" "$(yes_if test "$n" = 256)" "n=$n"
	ok "TC-973-14 the record last names is kept though it is the oldest" "$(yes_if test -f "$EXITS/$oldest")"
	ok "TC-973-14 the new record is kept" "$(yes_if test -f "$EXITS/$ID_A")"
	ok "TC-973-14 the next oldest 45 are gone, the 46th kept" \
		"$(yes_if test ! -e "$EXITS/$(printf '%032x' 1001)" -a ! -e "$EXITS/$(printf '%032x' 1045)" -a -e "$EXITS/$(printf '%032x' 1046)")"
	ok "TC-973-14 last and the .tmp files are never removed" \
		"$(yes_if test -f "$EXITS/last" -a -f "$EXITS/0000000000000000000000000000000a.tmp" -a -d "$EXITS/last.tmp")"
	rmdir "$EXITS/last.tmp"
	run exit INVOCATION_ID="$ID_B" SERVICE_RESULT=success
	n=$(records)
	ok "TC-973-14 a normal write at the cap keeps 256, the newest named by last" \
		"$(yes_if test "$n" = 256 -a "$(cat "$EXITS/last")" = "$ID_B")" "n=$n last=$(cat "$EXITS/last")"

	# --- unknown phase ----------------------------------------------------------
	setup
	run bogus
	ok "an unknown phase exits 2 with a <3> line" "$({ test "$RC" = 2 && logged 3 "instead of hold, wait or exit"; } && echo 0 || echo 1)" "rc=$RC $OUT"
done

echo "identity-hooks-test: $pass passed, $fail failed (shells:$TEST_SHELLS)"
[ "$fail" -eq 0 ]
