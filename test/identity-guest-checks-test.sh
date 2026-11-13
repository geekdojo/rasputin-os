#!/bin/sh
#
# Tests for test/lib/identity-guest-checks.sh, the identity service's facts
# checked on the guest (geekdojo/geekdojo-brain#967, TC-967-11 to TC-967-15;
# F-967-01, F-967-02, F-967-04, F-967-05).
#
# How. The real script runs with listen-sockets.sh and secret-scan.sh beside
# it, as on the guest, against a fake /proc (PROC_ROOT), and with a fake curl,
# psql (PSQL), journalctl and at-rest command (ATREST_CMD) that answer from
# environment variables. Each case changes one answer from an all-PASS
# baseline. Needles are made at run time; none is a literal here. What real
# Keycloak, PostgreSQL and listeners do is TC-967-16, on the spike guest.
#
# Shells: each of TEST_SHELLS (default: dash and bash where installed, and
# `busybox sh` when busybox is installed). REQUIRE_BUSYBOX=1 (CI sets it)
# makes a missing busybox a failure.
#
# Run:  sh test/identity-guest-checks-test.sh
set -u
LC_ALL=C
export LC_ALL

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
LIB="$ROOT/test/lib"
. "$LIB/checks.sh"
for f in identity-guest-checks.sh listen-sockets.sh secret-scan.sh; do
	[ -f "$LIB/$f" ] || { echo "FAILED: the file $LIB/$f is missing."; exit 1; }
done
if [ "${REQUIRE_BUSYBOX:-0}" = 1 ] && ! command -v busybox >/dev/null 2>&1; then
	echo "FAILED: REQUIRE_BUSYBOX=1 but busybox is not installed."
	exit 1
fi
if [ -z "${TEST_SHELLS:-}" ]; then
	TEST_SHELLS=""
	for s in dash bash; do command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"; done
	command -v busybox >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS busybox_sh"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
G="$TMP/guest"
mkdir -p "$G" "$TMP/bin" "$TMP/proc/net"
cp "$LIB/identity-guest-checks.sh" "$LIB/listen-sockets.sh" "$LIB/secret-scan.sh" "$G/"

# The fakes. curl answers CURL_<BARE|LEAF>_<port> (an HTTP status, 000 for
# none); psql answers PSQL_PLAIN_ERR and PSQL_PLAIN_RC for sslmode=disable
# and PSQL_CTL_RC for the verify-ca control; journalctl prints FAKE_JOURNAL.
cat >"$TMP/bin/curl" <<'EOF'
#!/bin/sh
mode=BARE port=""
for a in "$@"; do
	case "$a" in
		--cert) mode=LEAF ;;
		https://*) port=${a##*:}; port=${port%/} ;;
	esac
done
eval "printf '%s' \"\${CURL_${mode}_${port}:-000}\""
EOF
cat >"$TMP/bin/psql" <<'EOF'
#!/bin/sh
case "$*" in
	*sslmode=disable*) printf '%s\n' "$PSQL_PLAIN_ERR" >&2; exit "$PSQL_PLAIN_RC" ;;
	*sslmode=verify-ca*sslrootcert=*sslcert=*sslkey=*) exit "$PSQL_CTL_RC" ;;
esac
exit 3
EOF
cat >"$TMP/bin/journalctl" <<'EOF'
#!/bin/sh
cat "$FAKE_JOURNAL"
EOF
chmod +x "$TMP/bin/curl" "$TMP/bin/psql" "$TMP/bin/journalctl"
PATH="$TMP/bin:$PATH"
export PATH

# row HEXADDR PORT — one LISTEN row of /proc/net/tcp{,6}.
row() { printf '   0: %s:%04X 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1 1\n' "$1" "$2"; }
V4_LO=0100007F V4_ANY=00000000
V6_LO=00000000000000000000000001000000 V6_ANY=00000000000000000000000000000000
HDR='  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode'
# tables TCP4ROWS TCP6ROWS — the fake /proc/net/tcp and tcp6.
tables() {
	{ echo "$HDR"; printf '%s' "$1"; } >"$TMP/proc/net/tcp"
	{ echo "$HDR"; printf '%s' "$2"; } >"$TMP/proc/net/tcp6"
}
good_tables() { tables "$(row $V4_LO 8543; row $V4_LO 8544)" "$(row $V6_LO 8543; row $V6_LO 5432)"; }

baseline() {
	export KC_HTTPS_PORT=8543 KC_MGMT_PORT=8544 DB_PORT=5432 DB_NAME=keycloak DB_USER=keycloak
	export CA="$TMP/ca.pem" CLIENT_LEAF="$TMP/kc-client" DB_CA="$TMP/db-ca.pem" DB_CLIENT_LEAF="$TMP/db-client"
	export PSQL="$TMP/bin/psql" PERSIST="$TMP/persist" DB_DATA="$TMP/persist/postgresql" OUT="$TMP/out"
	export PROC_ROOT="$TMP/proc" FAKE_JOURNAL="$TMP/journal"
	export ATREST_CMD='printf "%s\n" "rasputin-atrest: starting" "$ATREST_LINE"'
	export ATREST_LINE="rasputin-atrest: PASS checked=3"
	export CURL_BARE_8543=000 CURL_LEAF_8543=200 CURL_BARE_8544=000 CURL_LEAF_8544=404
	export PSQL_PLAIN_ERR='psql: error: connection to server at "127.0.0.1", port 5432 failed: FATAL:  no pg_hba.conf entry for host "127.0.0.1", user "keycloak", database "keycloak", no encryption'
	export PSQL_PLAIN_RC=2 PSQL_CTL_RC=0
	printf '%s\n' 'p 1 0 0 0 0 0 /run/systemd/journal/stdout' >"$TMP/proc/net/unix"
	good_tables
}

shell_run() {
	case "$SH" in
		busybox_sh) busybox sh "$@" ;;
		*) "$SH" "$@" ;;
	esac
}
# checks — the checks under $SH: output in RES, status in RC.
checks() { RES=$(shell_run "$G/identity-guest-checks.sh" checks 2>&1); RC=$?; }
has() { printf '%s\n' "$RES" | grep -q -F -- "$1"; }
# line PREFIX — the output's lines starting with PREFIX.
line() { printf '%s\n' "$RES" | grep -F -- "$1"; }

for SH in $TEST_SHELLS; do
	echo "== under $SH"
	baseline
	checks
	check "[$SH] the baseline is every line PASS and exit 0" \
		"$(yes_if test "$RC" = 0 -a "$(printf '%s\n' "$RES" | grep -c -v '^PASS ')" = 0)" "rc=$RC $RES"

	# TC-967-11: loopback-only listeners.
	tables "$(row $V4_ANY 8543; row $V4_LO 8544)" "$(row $V6_LO 5432)"
	checks
	check "TC-967-11 [$SH] 0.0.0.0:8543 is FAIL naming the port, exit 1" \
		"$(yes_if test "$RC" = 1 -a "$(line 'listen port=8543')" = "FAIL listen port=8543: listens beyond loopback on 0.0.0.0:8543")" "rc=$RC $RES"
	tables "$(row $V4_LO 8543; row $V4_LO 8544)" "$(row $V6_ANY 5432)"
	checks
	check "TC-967-11 [$SH] [::]:5432 is FAIL naming the port, exit 1" \
		"$(yes_if test "$RC" = 1 -a "$(line 'listen port=5432')" = "FAIL listen port=5432: listens beyond loopback on [::]:5432")" "rc=$RC $RES"
	tables "$(row $V4_LO 8543)" "$(row $V6_LO 5432)"
	checks
	check "TC-967-11 [$SH] no row for 8544 is FAIL naming the port, exit 1" \
		"$(yes_if test "$RC" = 1 -a "$(line 'listen port=8544')" = "FAIL listen port=8544: nothing listens on it")" "rc=$RC $RES"
	good_tables
	checks
	check "TC-967-11 [$SH] every port only on 127.0.0.1 or [::1] is PASS for each, exit 0" \
		"$(yes_if test "$RC" = 0 -a "$(line ' listen port=' | grep -c '^PASS ')" = 3)" "rc=$RC $RES"

	# TC-967-12: Keycloak TLS on both ports (F-967-05).
	for p in 8543 8544; do
		baseline
		eval "export CURL_BARE_$p=401"
		checks
		check "TC-967-12 [$SH] port $p answering with no client certificate is FAIL" \
			"$(yes_if test "$RC" = 1 -a "$(line "kc-tls port=$p" | cut -c1-5)" = "FAIL ")" "$RES"
		baseline
		eval "export CURL_LEAF_$p=000"
		checks
		check "TC-967-12 [$SH] port $p: the control failing (no status with the leaf) is FAIL, never PASS" \
			"$(yes_if test "$RC" = 1 && has "FAIL kc-tls port=$p: control")" "$RES"
		baseline
		checks
		check "TC-967-12 [$SH] port $p: no status bare, a status with the leaf is PASS" \
			"$(yes_if has "PASS kc-tls port=$p:")" "$RES"
	done

	# TC-967-13: TLS-only PostgreSQL by refusal reason (F-967-01).
	baseline
	checks
	check "TC-967-13 [$SH] refused for no encryption and the verify-ca control connecting is PASS" \
		"$(yes_if has "PASS pg-tls: sslmode=disable refused by pg_hba (no encryption)")" "$RES"
	baseline
	export PSQL_PLAIN_RC=0 PSQL_PLAIN_ERR=''
	checks
	check "TC-967-13 [$SH] sslmode=disable connecting is FAIL" "$(yes_if test "$RC" = 1 && has "FAIL pg-tls: sslmode=disable connected")" "$RES"
	for why in 'FATAL:  password authentication failed for user "keycloak"' 'fe_sendauth: no password supplied'; do
		baseline
		export PSQL_PLAIN_ERR="$why"
		checks
		check "TC-967-13 [$SH] a password refusal ($why) is FAIL, never PASS" \
			"$(yes_if test "$RC" = 1 && has "FAIL pg-tls: sslmode=disable reached a password line")" "$RES"
	done
	baseline
	export PSQL_PLAIN_ERR='psql: error: connection to server at "127.0.0.1", port 5432 failed: Connection refused'
	checks
	check "TC-967-13 [$SH] another failure (connection refused) is INCONCLUSIVE, exit 2" \
		"$(yes_if test "$RC" = 2 && has "INCONCLUSIVE pg-tls: sslmode=disable failed for another reason")" "$RES"
	baseline
	export PSQL_CTL_RC=2
	checks
	check "TC-967-13 [$SH] the verify-ca control refused is FAIL" \
		"$(yes_if test "$RC" = 1 && has "FAIL pg-tls: control: sslmode=verify-ca")" "$RES"
	baseline
	printf '%s\n' 'p 1 0 0 0 0 0 /run/postgresql/.s.PGSQL.5432' >>"$TMP/proc/net/unix"
	checks
	check "TC-967-13 [$SH] a PostgreSQL Unix socket is FAIL" \
		"$(yes_if test "$RC" = 1 && has "FAIL pg-socket: a PostgreSQL Unix socket exists: /run/postgresql/.s.PGSQL.5432")" "$RES"

	# TC-967-14: the at-rest verdict, N > 0 (F-967-04).
	for c in "rasputin-atrest: PASS checked=3|PASS" "rasputin-atrest: PASS checked=0|FAIL" \
		"rasputin-atrest: FAIL failures=1 checked=3 first=/var/lib/rasputin/x|FAIL" "|FAIL"; do
		baseline
		export ATREST_LINE="${c%|*}"
		checks
		check "TC-967-14 [$SH] '${c%|*}' is ${c#*|}" "$(yes_if test "$(line 'at-rest:' | cut -d' ' -f1)" = "${c#*|}")" "$RES"
	done

	# TC-967-15: the scan and its inputs (F-967-02).
	baseline
	mkdir -p "$DB_DATA" "$PERSIST/other"
	n1=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n') n2=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
	printf 'clean\n' >"$PERSIST/other/f"
	printf 'row %s\n' "$n1" >"$DB_DATA/base"
	printf 'boot\nend\n' >"$FAKE_JOURNAL"
	# scan_with NEEDLES — the scan, the needles on its stdin.
	scan_with() { RES=$(printf '%s' "$1" | shell_run "$G/identity-guest-checks.sh" scan 2>&1); RC=$?; }
	scan_with "$(printf '%s\n%s\n' "$n1" "$n2")"
	check "TC-967-15 [$SH] a needle only under DB_DATA is PASS, exit 0" \
		"$(yes_if test "$RC" = 0 && has "PASS scan tree: files=1 files_exact=0" && has "PASS scan journal: journal_lines=2 journal_exact=0")" "rc=$RC $RES"
	check "TC-967-15 [$SH] the needles file is gone after the scan" "$(yes_if test ! -e "$TMP/out/identity-needles" -a -z "$(ls -A "$TMP/out")")" "$(ls -A "$TMP/out")"
	check "TC-967-15 [$SH] the scan prints no needle" "$(yes_if test "$(printf '%s\n' "$RES" | grep -c -e "$n1" -e "$n2")" = 0)"
	printf 'leak %s\n' "$n2" >"$PERSIST/other/g"
	scan_with "$(printf '%s\n%s\n' "$n1" "$n2")"
	check "TC-967-15 [$SH] a needle outside DB_DATA is FAIL, exit 1" \
		"$(yes_if test "$RC" = 1 && has "FAIL scan tree: a needle was found: files=2 files_exact=1")" "rc=$RC $RES"
	rm "$PERSIST/other/g"
	printf 'boot\nsession %s\n' "$n2" >"$FAKE_JOURNAL"
	scan_with "$(printf '%s\n' "$n2")"
	check "TC-967-15 [$SH] a needle in the journal is FAIL, exit 1" \
		"$(yes_if test "$RC" = 1 && has "FAIL scan journal: a needle was found: journal_lines=2 journal_exact=1")" "rc=$RC $RES"
	scan_with ""
	check "TC-967-15 [$SH] an empty needles file is INCONCLUSIVE, exit 2" \
		"$(yes_if test "$RC" = 2 && has "INCONCLUSIVE scan tree: INCONCLUSIVE needles=0")" "rc=$RC $RES"
	check "TC-967-15 [$SH] the needles file is gone after an empty scan" "$(yes_if test -z "$(ls -A "$TMP/out")")"
	for v in KC_HTTPS_PORT KC_MGMT_PORT DB_PORT DB_NAME DB_USER CA CLIENT_LEAF DB_CA DB_CLIENT_LEAF \
		PSQL ATREST_CMD PERSIST DB_DATA OUT; do
		baseline
		RES=$(unset "$v"; shell_run "$G/identity-guest-checks.sh" checks 2>&1); RC=$?
		check "TC-967-15 [$SH] $v unset is INCONCLUSIVE missing=$v, exit 2" \
			"$(yes_if test "$RC" = 2 -a "$RES" = "INCONCLUSIVE missing=$v")" "rc=$RC $RES"
	done
	rm -rf "$PERSIST" "$TMP/out"
done

case "$TEST_SHELLS" in *busybox_sh*) ;; *) echo "  note: busybox is not installed; the busybox rows did not run" ;; esac
if [ "$fails" -ne 0 ]; then
	echo "identity-guest-checks-test: $fails failed"
	exit 1
fi
echo "identity-guest-checks-test: all passed"
