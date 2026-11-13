#!/bin/sh
#
# identity-guest-checks.sh — the identity service's facts, checked ON THE
# GUEST as root (geekdojo/geekdojo-brain#967). Copied to the guest with
# listen-sockets.sh and secret-scan.sh beside it, and run; never sourced.
#
#   sh identity-guest-checks.sh checks   one PASS|FAIL|INCONCLUSIVE line per fact
#   sh identity-guest-checks.sh scan     the needles, on stdin, looked for on
#                                        the persistent partition and in the
#                                        journal; counts only
#
# checks:
#   listen     on each of KC_HTTPS_PORT, KC_MGMT_PORT and DB_PORT at least one
#              LISTEN row exists, and every one is 127.0.0.1 or [::1]
#   kc-tls     on KC_HTTPS_PORT and on KC_MGMT_PORT, a read with no client
#              certificate gets no HTTP status, and the control, a read with
#              CLIENT_LEAF, gets one (F-967-05)
#   pg-tls     sslmode=disable is refused with the server's own
#              "no pg_hba.conf entry ... no encryption" line; a connection or
#              a password refusal (plaintext reached a host line) is FAIL; any
#              other failure is INCONCLUSIVE. The control, sslmode=verify-ca
#              with DB_CA and DB_CLIENT_LEAF (the design's hostssl ... cert
#              line), must connect (F-967-01)
#   pg-socket  /proc/net/unix lists no path holding .s.PGSQL. (platform.md:
#              unix_socket_directories='')
#   at-rest    ATREST_CMD's last `rasputin-atrest:` line is PASS checked=N,
#              N > 0 (F-967-04)
#
# scan: stdin goes to a 0600 needles file in OUT, removed on every path; then
# scan_tree PERSIST (but DB_DATA, where PostgreSQL keeps what it was given to
# keep) and scan_journal. Either reading nothing is INCONCLUSIVE (F-967-02).
#
# Inputs, every one required: no default is guessed, because the image's
# values come from the identity units. A missing one prints
# `INCONCLUSIVE missing=<VAR>` and exits 2.
#   KC_HTTPS_PORT KC_MGMT_PORT DB_PORT  the three listeners
#   DB_NAME DB_USER                     the database and role the leaf maps to
#   CA                                  the CA Keycloak's server leaf chains to
#   CLIENT_LEAF                         a client leaf Keycloak accepts,
#                                       <CLIENT_LEAF>.pem and .key
#   DB_CA DB_CLIENT_LEAF                the same for PostgreSQL
#   PSQL                                the psql binary
#   ATREST_CMD                          the at-rest audit command
#   PERSIST DB_DATA                     the persistent partition, and
#                                       PostgreSQL's data directory in it
#   OUT                                 a tmpfs directory for scratch files
# Optional: KC_SERVER_NAME, the name Keycloak's leaf carries (default
# 127.0.0.1); PROC_ROOT, /proc unless a test sets it.
#
# Exit status: 0 every line PASS; 1 any FAIL; 2 any INCONCLUSIVE and no FAIL.
#
# Needs on the guest: awk, grep, find, sed, curl, the psql named, journalctl.
set -u
umask 077

HERE=$(dirname "$0")
for _lib in listen-sockets.sh secret-scan.sh; do
	[ -f "$HERE/$_lib" ] || { echo "INCONCLUSIVE missing=$_lib"; exit 2; }
done
. "$HERE/listen-sockets.sh"
. "$HERE/secret-scan.sh"

for _var in KC_HTTPS_PORT KC_MGMT_PORT DB_PORT DB_NAME DB_USER CA CLIENT_LEAF DB_CA DB_CLIENT_LEAF \
	PSQL ATREST_CMD PERSIST DB_DATA OUT; do
	eval "_val=\${$_var:-}"
	[ -n "$_val" ] || { echo "INCONCLUSIVE missing=$_var"; exit 2; }
done
PROC_ROOT=${PROC_ROOT:-/proc}
KC_SERVER_NAME=${KC_SERVER_NAME:-127.0.0.1}

FAILS=0 UNSURE=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
unsure() { echo "INCONCLUSIVE $*"; UNSURE=$((UNSURE + 1)); }
one() { tr -d '\r' | tr '\n' ' ' | sed 's/  */ /g; s/ $//'; }

check_listen() {
	_rows=$(cat "$PROC_ROOT/net/tcp" "$PROC_ROOT/net/tcp6" 2>/dev/null | listening_sockets)
	for _port in "$KC_HTTPS_PORT" "$KC_MGMT_PORT" "$DB_PORT"; do
		_on=$(printf '%s\n' "$_rows" | grep ":$_port\$" | tr '\n' ' ' | sed 's/ $//')
		_wide=$(printf '%s\n' "$_rows" | grep ":$_port\$" | grep -v -e '^127\.0\.0\.1:' -e '^\[::1\]:' | tr '\n' ' ' | sed 's/ $//')
		if [ -z "$_on" ]; then
			fail "listen port=$_port: nothing listens on it"
		elif [ -n "$_wide" ]; then
			fail "listen port=$_port: listens beyond loopback on $_wide"
		else
			pass "listen port=$_port on $_on"
		fi
	done
}

# kc_status PORT [CURL ARGS] — the HTTP status curl got, 000 for none.
kc_status() {
	_p=$1
	shift
	_s=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$CA" \
		--resolve "$KC_SERVER_NAME:$_p:127.0.0.1" "$@" "https://$KC_SERVER_NAME:$_p/" 2>/dev/null)
	echo "${_s:-000}"
}

check_kc_tls() {
	for _port in "$KC_HTTPS_PORT" "$KC_MGMT_PORT"; do
		_bare=$(kc_status "$_port")
		_leaf=$(kc_status "$_port" --cert "$CLIENT_LEAF.pem" --key "$CLIENT_LEAF.key")
		if [ "$_bare" != 000 ]; then
			fail "kc-tls port=$_port: a read with no client certificate got HTTP $_bare"
		elif [ "$_leaf" = 000 ]; then
			fail "kc-tls port=$_port: control: the read with the client leaf got no HTTP status either"
		else
			pass "kc-tls port=$_port: no client certificate, no HTTP status; the client leaf got HTTP $_leaf"
		fi
	done
}

check_pg() {
	_plain=$(PGPASSWORD='' "$PSQL" -w -X -A -t -c 'select 1' \
		"host=127.0.0.1 port=$DB_PORT dbname=$DB_NAME user=$DB_USER sslmode=disable connect_timeout=10" 2>&1)
	_rc=$?
	_plain=$(printf '%s\n' "$_plain" | one)
	if [ "$_rc" = 0 ]; then
		fail "pg-tls: sslmode=disable connected"
	else
		case "$_plain" in
			*"no pg_hba.conf entry"*"no encryption"*)
				if _ctl=$("$PSQL" -w -X -A -t -c 'select 1' "host=127.0.0.1 port=$DB_PORT dbname=$DB_NAME user=$DB_USER sslmode=verify-ca sslrootcert=$DB_CA sslcert=$DB_CLIENT_LEAF.pem sslkey=$DB_CLIENT_LEAF.key connect_timeout=10" 2>&1); then
					pass "pg-tls: sslmode=disable refused by pg_hba (no encryption); sslmode=verify-ca with the client leaf connected"
				else
					fail "pg-tls: control: sslmode=verify-ca with the client leaf did not connect: $(printf '%s\n' "$_ctl" | one)"
				fi
				;;
			*"password authentication failed"* | *"no password supplied"*)
				fail "pg-tls: sslmode=disable reached a password line, so plaintext is accepted: $_plain" ;;
			*) unsure "pg-tls: sslmode=disable failed for another reason: ${_plain:-<no output>}" ;;
		esac
	fi
	if [ ! -r "$PROC_ROOT/net/unix" ]; then
		unsure "pg-socket: $PROC_ROOT/net/unix could not be read"
	elif grep -q '\.s\.PGSQL\.' "$PROC_ROOT/net/unix"; then
		fail "pg-socket: a PostgreSQL Unix socket exists: $(grep '\.s\.PGSQL\.' "$PROC_ROOT/net/unix" | awk '{ print $NF }' | one)"
	else
		pass "pg-socket: no PostgreSQL Unix socket"
	fi
}

check_atrest() {
	_ar=$(sh -c "$ATREST_CMD" 2>/dev/null | tr -d '\r' | grep '^rasputin-atrest: ' | tail -1)
	case "$_ar" in
		"rasputin-atrest: PASS checked="[1-9]*) pass "at-rest: $_ar" ;;
		*) fail "at-rest: want 'rasputin-atrest: PASS checked=N' with N > 0, got '${_ar:-<nothing>}'" ;;
	esac
}

do_scan() {
	mkdir -p "$OUT"
	_needles="$OUT/identity-needles"
	trap 'rm -f "$_needles"' EXIT INT TERM
	cat >"$_needles"
	_t=$(scan_tree "$PERSIST" "$_needles" "$DB_DATA"); _trc=$?
	_j=$(scan_journal "$_needles"); _jrc=$?
	rm -f "$_needles"
	scan_verdict tree "$_trc" "$_t"
	scan_verdict journal "$_jrc" "$_j"
}

# scan_verdict WHAT STATUS COUNTS — the line for one scan's status.
scan_verdict() {
	_counts=$(printf '%s\n' "$3" | one)
	case "$2" in
		0) pass "scan $1: $_counts" ;;
		1) fail "scan $1: a needle was found: $_counts" ;;
		*) unsure "scan $1: $_counts" ;;
	esac
}

case "${1:-}" in
	checks) check_listen; check_kc_tls; check_pg; check_atrest ;;
	scan) do_scan ;;
	*) echo "usage: identity-guest-checks.sh checks|scan" >&2; exit 2 ;;
esac
[ "$FAILS" = 0 ] || exit 1
[ "$UNSURE" = 0 ] || exit 2
exit 0
