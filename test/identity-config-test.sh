#!/bin/sh
# Static assertions on the identity service's baked configuration
# (geekdojo/geekdojo-brain#974, Identity 2.6; platform.md §3.5):
# etc/rasputin/identity/keycloak.conf, postgresql.conf and pg_hba.conf.
#
# Why. Each way to get one of these wrong is silent until a node runs it, and
# some never show at all:
#   - a build option in keycloak.conf makes `start --optimized` refuse the
#     drift on every control plane;
#   - debug opens a debugger port, http-accept-non-normalized-paths=true turns
#     Keycloak's own path filter off behind the door, and an
#     spi-x509cert-lookup provider reads a client certificate from a header
#     instead of the TLS session (accounts-and-sign-in.md §7.2);
#   - a credential path that is not one of the unit's own LoadCredential=
#     names fails the start, or reads a file the unit's uid cannot;
#   - a literal /run/credentials/keycloak.service/ path in keycloak.conf is
#     absent in the admin recovery's transient unit, so its kc.sh cannot
#     reach the database (geekdojo/geekdojo-brain#1131): keycloak.conf names
#     them through ${CREDENTIALS_DIRECTORY};
#   - wal_level, the pg_hba line, the TLS floor and the statement logging are
#     each one word from a weaker database.
# So keycloak.conf holds exactly its runtime keys at their values, each once;
# every other key is refused by name; postgresql.conf holds exactly its keys
# and values; its hba_file names the baked pg_hba.conf, which is one line.
# Both conf files are read by package/keycloak/kc-conf.sh, the one parser of
# the key=value grammar (F-974-09).
#
# Negative controls run this same script over scratch copies of the tree with
# IDENTITY_CONFIG_TREE_ONLY=1, which checks that tree and nothing else.
#
# Fails closed (TC-974-01): a missing or unreadable input, a conf line that is
# not key=value, or a missing parser prints one line starting FAILED: and
# exits non-zero before any case runs.
#
# This is a static test: whether Keycloak and PostgreSQL accept the files is
# test/identity-unit-functional.sh, which starts both on them.
#
# Run:  sh test/identity-config-test.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
IDDIR="$OVERLAY/etc/rasputin/identity"
KC_CONF="$IDDIR/keycloak.conf"
PG_CONF="$IDDIR/postgresql.conf"
HBA="$IDDIR/pg_hba.conf"
KC_UNIT="$OVERLAY/etc/systemd/system/keycloak.service"
DB_UNIT="$OVERLAY/etc/systemd/system/keycloak-db.service"
KC_LIB="$ROOT/package/keycloak/kc-conf.sh"
RECOVER="$OVERLAY/usr/lib/rasputin/identity/rasputin-keycloak-recover-admin.sh"
LIB="$ROOT/test/lib"

# --- fail closed, before any case (TC-974-01) --------------------------------------
for f in "$KC_LIB" "$LIB/checks.sh" "$LIB/unit-directives.sh" "$KC_UNIT" "$DB_UNIT" "$KC_CONF" "$PG_CONF" "$HBA" "$RECOVER"; do
	[ -f "$f" ] || { echo "FAILED: the file $f is missing, so the identity configuration cannot be checked."; exit 1; }
	[ -r "$f" ] || { echo "FAILED: the file $f cannot be read, so the identity configuration cannot be checked."; exit 1; }
done

# shellcheck source=package/keycloak/kc-conf.sh
. "$KC_LIB"
. "$LIB/checks.sh"
. "$LIB/unit-directives.sh"

PARSE=$(mktemp -d) || { echo "FAILED: a scratch directory could not be created."; exit 1; }
trap 'rm -rf "$PARSE"' EXIT INT TERM
for f in "$KC_CONF" "$PG_CONF"; do
	kc_conf_lines "$f" "$PARSE/bad" >"$PARSE/$(basename "$f")" \
		|| { echo "FAILED: line $(cat "$PARSE/bad") of $f is not blank, a # comment or key=value, so the identity configuration cannot be checked."; exit 1; }
done
KC_LINES=$(cat "$PARSE/keycloak.conf")
PG_LINES=$(cat "$PARSE/postgresql.conf")

# keycloak.conf names its credentials through ${CREDENTIALS_DIRECTORY}, which
# systemd sets in keycloak.service and in the admin recovery's transient unit
# (geekdojo/geekdojo-brain#1131); Keycloak expands it.
# shellcheck disable=SC2016 # the literal text keycloak.conf holds
KC_CREDS='${CREDENTIALS_DIRECTORY}'
DB_CREDS=/run/credentials/keycloak-db.service
# keycloak.conf's runtime options, exactly (platform.md §3.5; signin-origin.md
# §4). hostname is deliberately absent.
WANT_KC="hostname-strict=false
hostname-backchannel-dynamic=false
proxy-headers=xforwarded
proxy-trusted-addresses=127.0.0.1/32
http-enabled=false
http-host=127.0.0.1
https-port=8543
https-protocols=TLSv1.3
https-certificate-file=$KC_CREDS/server.pem
https-certificate-key-file=$KC_CREDS/server.key
https-trust-store-file=$KC_CREDS/identity-ca.pem
https-certificates-reload-period=-1
http-management-host=127.0.0.1
http-management-port=8544
truststore-paths=$KC_CREDS/mesh-ca.pem
cache=local
vault-dir=/run/rasputin-identity-vault
db-url-host=127.0.0.1
db-url-port=5432
db-url-database=keycloak
db-username=keycloak
db-url-properties=?sslmode=verify-full&sslrootcert=$KC_CREDS/identity-ca.pem&sslcert=$KC_CREDS/db-client.pem&sslkey=$KC_CREDS/db-client.pk8
db-pool-max-size=8
log=console
spi-password-policy--password-blacklist--false-positive-probability=1e-9"
# The build options the api tarball's identity/keycloak-build.conf sets at the
# pin, and the build-time siblings most often mistaken for runtime ones. A key
# here is refused as a build option; any other unlisted key as unknown.
BUILD_KEYS="db transaction-xa-enabled health-enabled metrics-enabled event-metrics-user-enabled https-client-auth vault features features-disabled cache-stack http-relative-path"
WANT_PG="listen_addresses='127.0.0.1'
port=5432
unix_socket_directories=''
hba_file='/etc/rasputin/identity/pg_hba.conf'
ssl=on
ssl_min_protocol_version='TLSv1.3'
ssl_cert_file='$DB_CREDS/server.pem'
ssl_key_file='$DB_CREDS/server.key'
ssl_ca_file='$DB_CREDS/identity-ca.pem'
max_connections=12
shared_buffers=32MB
work_mem=2MB
max_wal_size=64MB
min_wal_size=32MB
wal_level=minimal
max_wal_senders=0
fsync=on
full_page_writes=on
log_destination='stderr'
log_min_error_statement=panic
log_error_verbosity=terse
log_statement=none"
WANT_HBA='hostssl keycloak keycloak 127.0.0.1/32 cert'

# key_values LINES KEY — every value KEY has in LINES, one per line.
key_values() { printf '%s\n' "$1" | awk -v k="$2=" 'index($0, k) == 1 { print substr($0, length(k) + 1) }'; }
keys_of() { printf '%s\n' "$1" | sed -n 's/=.*//p'; }
mode() { ls -l "$1" 2>/dev/null | cut -c1-10; }

# exact NAME LINES WANT — each key of WANT is set exactly once in LINES, at its
# value, one ok line per key.
exact() {
	# A for loop over lines, not a pipe: check counts into this shell's $fails.
	set -f
	_ifs=$IFS
	IFS='
'
	for _w in $3; do
		IFS=$_ifs
		_k=${_w%%=*} _v=${_w#*=}
		_got=$(key_values "$2" "$_k")
		_n=0; [ -n "$_got" ] && _n=$(printf '%s\n' "$_got" | grep -c '')
		_st=1
		[ "$_n" -eq 1 ] && [ "$_got" = "$_v" ] && _st=0
		check "$1 sets $_k=$_v, once" "$_st" "$1 sets $_k $_n time(s): $(printf '%s' "$_got" | tr '\n' '|')"
		IFS='
'
	done
	IFS=$_ifs
	set +f
}

# kc_extra — keycloak.conf's keys outside the runtime list, each refused by
# name with its reason (TC-974-03). http-accept-non-normalized-paths=false is
# the one key allowed beyond the list: false is Keycloak's own default.
kc_extra() {
	_bad=0
	for _k in $(keys_of "$KC_LINES" | LC_ALL=C sort -u); do
		key_values "$WANT_KC" "$_k" | grep -q . && continue
		_vals=$(key_values "$KC_LINES" "$_k" | tr '\n' ' ' | sed 's/ $//')
		case "$_k" in
			http-accept-non-normalized-paths)
				[ "$_vals" = false ] && continue
				_why="http-accept-non-normalized-paths=$_vals turns Keycloak's own path filter off behind the door; only false or absent passes" ;;
			debug*) _why="$_k=$_vals: debug never ships (it opens a debugger port)" ;;
			spi-x509cert-lookup*) _why="$_k=$_vals: the client-certificate lookup stays Keycloak's default, which reads the TLS session and never a header" ;;
			*)
				case " $BUILD_KEYS " in
					*" $_k "*) _why="$_k=$_vals is a build option, frozen at image build by the api's keycloak-build.conf; --optimized refuses the drift" ;;
					*) _why="$_k=$_vals is not one of keycloak.conf's runtime options: an unknown key" ;;
				esac ;;
		esac
		check "keycloak.conf sets no key outside its runtime options: $_k" 1 "$_why"
		_bad=1
	done
	[ "$_bad" = 1 ] || check "keycloak.conf sets no key outside its runtime options" 0
}

# pg_extra — postgresql.conf's keys outside its list, each refused by name.
pg_extra() {
	_bad=0
	for _k in $(keys_of "$PG_LINES" | LC_ALL=C sort -u); do
		key_values "$WANT_PG" "$_k" | grep -q . && continue
		check "postgresql.conf sets no key outside its list: $_k" 1 "$_k=$(key_values "$PG_LINES" "$_k" | tr '\n' ' ')is not one of postgresql.conf's settings"
		_bad=1
	done
	[ "$_bad" = 1 ] || check "postgresql.conf sets no key outside its list" 0
}

# kc_creds — every ${CREDENTIALS_DIRECTORY}/<name> in keycloak.conf is one of
# keycloak.service's LoadCredential= names, and no /run/credentials/ literal
# is left (TC-1131-11).
kc_creds() {
	_names=$(values "$(directives "$KC_UNIT")" Service LoadCredential | sed 's/:.*//')
	_paths=$(printf '%s\n' "$KC_LINES" | grep -oE '[$][{]CREDENTIALS_DIRECTORY[}]/[^&]*' | LC_ALL=C sort -u)
	[ -n "$_paths" ] || { check "keycloak.conf names credentials under $KC_CREDS/" 1 "it names none"; return; }
	for _p in $_paths; do
		_st=1
		printf '%s\n' "$_names" | grep -qxF "${_p##*/}" && _st=0
		check "keycloak.conf credential $_p is one of keycloak.service's own LoadCredential= names" "$_st" \
			"$_p: keycloak.service's LoadCredential= names are $(printf '%s' "$_names" | tr '\n' ' ')"
	done
	_lit=$(grep -n '/run/credentials/' "$KC_CONF" || true)
	check "keycloak.conf holds no /run/credentials/ literal" "$(yes_if [ -z "$_lit" ])" "$(printf '%s' "$_lit" | tr '\n' '|')"
}

# creds NAME LINES OWNUNIT UNITFILE — every /run/credentials/<unit>/<name> in
# LINES names OWNUNIT and one of UNITFILE's LoadCredential= names (TC-974-04).
creds() {
	_names=$(values "$(directives "$4")" Service LoadCredential | sed 's/:.*//')
	_paths=$(printf '%s\n' "$2" | grep -o "/run/credentials/[^/&' ]*/[^&' ]*" | LC_ALL=C sort -u)
	[ -n "$_paths" ] || { check "$1 names credentials under /run/credentials/$3/" 1 "it names none"; return; }
	for _p in $_paths; do
		_u=${_p#/run/credentials/}; _u=${_u%%/*}
		_n=${_p##*/}
		_st=1
		[ "$_u" = "$3" ] && printf '%s\n' "$_names" | grep -qxF "$_n" && _st=0
		check "$1 credential $_p is one of $3's own LoadCredential= names" "$_st" \
			"$_p: $3's LoadCredential= names are $(printf '%s' "$_names" | tr '\n' ' ')"
	done
}

echo "1. keycloak.conf's runtime options (TC-974-02)"
exact keycloak.conf "$KC_LINES" "$WANT_KC"
check "keycloak.conf sets no hostname (signin-origin.md §4)" "$(yes_if [ -z "$(key_values "$KC_LINES" hostname)" ])"
check "keycloak.conf is 0644 in the overlay (got $(mode "$KC_CONF"))" "$(yes_if [ "$(mode "$KC_CONF")" = -rw-r--r-- ])"
check "TC-1131-11 the recovery launcher is 0755 in the overlay (got $(mode "$RECOVER"))" "$(yes_if [ "$(mode "$RECOVER")" = -rwxr-xr-x ])"

echo
echo "2. no other key in keycloak.conf (TC-974-03)"
kc_extra

echo
echo "3. credential paths tied to LoadCredential= (TC-974-04)"
kc_creds
creds postgresql.conf "$PG_LINES" keycloak-db.service "$DB_UNIT"

echo
echo "4. postgresql.conf and pg_hba.conf (TC-974-05)"
exact postgresql.conf "$PG_LINES" "$WANT_PG"
pg_extra
_hba=$(key_values "$PG_LINES" hba_file | head -1 | tr -d "'")
check "postgresql.conf's hba_file ${_hba:-<unset>} exists in the overlay" \
	"$({ [ -n "$_hba" ] && [ -f "$OVERLAY$_hba" ]; } && echo 0 || echo 1)" "no file $OVERLAY${_hba:-<unset>}"
_hba_text=$(cat "$HBA")
_hba_n=$(grep -c '' "$HBA")
check "pg_hba.conf is exactly one line, '$WANT_HBA'" "$({ [ "$_hba_n" = 1 ] && [ "$_hba_text" = "$WANT_HBA" ]; } && echo 0 || echo 1)" \
	"pg_hba.conf has $_hba_n line(s): $(printf '%s' "$_hba_text" | tr '\n' '|')"
for f in "$PG_CONF" "$HBA"; do
	check "$(basename "$f") is 0644 in the overlay (got $(mode "$f"))" "$(yes_if [ "$(mode "$f")" = -rw-r--r-- ])"
done

if [ "${IDENTITY_CONFIG_TREE_ONLY:-0}" = 1 ]; then
	if [ "$fails" -ne 0 ]; then echo "identity-config-test: $fails check(s) FAILED"; exit 1; fi
	echo "identity-config-test: all checks passed"
	exit 0
fi

# --- the controls: this script over scratch copies of the tree ------------------------
SCRATCH=$(mktemp -d)
trap 'rm -rf "$PARSE" "$SCRATCH"' EXIT INT TERM
SH_BIN=$(command -v sh)
REL_ID=board/rasputin/common/rootfs-overlay/etc/rasputin/identity
REL_SYSD=board/rasputin/common/rootfs-overlay/etc/systemd/system
REL_KC=$REL_ID/keycloak.conf
REL_PG=$REL_ID/postgresql.conf
REL_HBA=$REL_ID/pg_hba.conf
REL_RECOVER=board/rasputin/common/rootfs-overlay/usr/lib/rasputin/identity/rasputin-keycloak-recover-admin.sh
N=0
# tree — a fresh scratch root holding this script, its libraries, the parser,
# the three configs and the two units. Sets T.
tree() {
	N=$((N + 1))
	T="$SCRATCH/t$N"
	mkdir -p "$T/test/lib" "$T/$REL_ID" "$T/$REL_SYSD" "$T/package/keycloak"
	cp "$0" "$T/test/identity-config-test.sh"
	cp "$LIB/checks.sh" "$LIB/unit-directives.sh" "$T/test/lib/"
	cp "$KC_LIB" "$T/package/keycloak/"
	cp "$KC_CONF" "$PG_CONF" "$HBA" "$T/$REL_ID/"
	cp "$KC_UNIT" "$DB_UNIT" "$T/$REL_SYSD/"
	mkdir -p "$T/${REL_RECOVER%/*}"
	cp -p "$RECOVER" "$T/$REL_RECOVER"
}
# edit FILE MODE LINE — "after:L" puts LINE after the line L, "replace:L" in
# its place (an empty LINE deletes L). The copy must change.
edit() {
	_f=$1 _mode=${2%%:*} _anchor=${2#*:} _line=$3
	cp "$_f" "$_f.orig"
	awk -v m="$_mode" -v a="$_anchor" -v l="$_line" '
		$0 == a && m == "replace" { if (l != "") print l; next }
		{ print }
		$0 == a && m == "after" { print l }
	' "$_f.orig" >"$_f"
	if cmp -s "$_f" "$_f.orig"; then
		check "the control's edit changed $(basename "$_f") ($2)" 1 "the anchor line is not in the file"
		rm -f "$_f.orig"
		return 1
	fi
	rm -f "$_f.orig"
}
run_tree() { OUT=$(env IDENTITY_CONFIG_TREE_ONLY=1 "$SH_BIN" "$T/test/identity-config-test.sh" 2>&1); RC=$?; }
# refused LABEL NEEDLE... — the run failed and a FAIL line, or the line under
# it, names every NEEDLE.
refused() {
	_label=$1; shift
	_fail_text=$(printf '%s\n' "$OUT" | grep -A1 '^  FAIL')
	_st=0
	[ "$RC" -ne 0 ] || _st=1
	for _needle in "$@"; do contains "$_needle" "$_fail_text" || _st=1; done
	check "$_label: refused, naming $*" "$_st" "rc=$RC; output: $(printf '%s' "$OUT" | tr '\n' '|')"
	[ -n "$_fail_text" ] && printf '         checker said: %s\n' "$(printf '%s' "$_fail_text" | sed 's/^[[:space:]]*//' | tr '\n' ' ')"
}
passes() { check "$1: passes" "$(yes_if [ "$RC" -eq 0 ])" "rc=$RC; output: $(printf '%s' "$OUT" | tr '\n' '|')"; }
# failed_closed LABEL NEEDLE — exit non-zero, exactly one line, starting
# FAILED: and naming NEEDLE, and no case run.
failed_closed() {
	_lines=$(printf '%s\n' "$OUT" | grep -c '')
	_st=1
	[ "$RC" -ne 0 ] && [ "$_lines" -eq 1 ] && contains "$2" "$OUT" \
		&& printf '%s\n' "$OUT" | grep -q '^FAILED: .*\.$' \
		&& ! printf '%s\n' "$OUT" | grep -qE '^  (ok|FAIL) ' && _st=0
	check "$1: exit $RC, one FAILED: sentence naming '$2', no case run" "$_st" "output: $(printf '%s' "$OUT" | tr '\n' '|')"
	printf '         it said: %s\n' "$OUT"
}

echo
echo "5. the checker refuses each wrong keycloak.conf (TC-974-03)"
tree; run_tree; passes "positive control, the shipped tree"
for inj in db=postgres https-client-auth=required vault=file features-disabled=account debug=true \
	http-accept-non-normalized-paths=true spi-x509cert-lookup-provider=nginx rasputin-unknown-key=1; do
	tree; edit "$T/$REL_KC" after:log=console "$inj" \
		&& { run_tree; refused "TC-974-03 $inj added" "${inj%%=*}"; }
done
tree; edit "$T/$REL_KC" after:log=console 'https-port=8545' \
	&& { run_tree; refused "TC-974-03 https-port repeated with another value" 'https-port' '2 time(s)'; }
tree; edit "$T/$REL_KC" after:log=console 'http-accept-non-normalized-paths=false' \
	&& { run_tree; passes "TC-974-03 http-accept-non-normalized-paths=false"; }
tree; run_tree; passes "TC-974-03 http-accept-non-normalized-paths absent"
tree; edit "$T/$REL_KC" replace:http-enabled=false 'http-enabled=true' \
	&& { run_tree; refused "TC-974-02 http-enabled=true" 'http-enabled=false'; }
tree; edit "$T/$REL_KC" replace:cache=local '' \
	&& { run_tree; refused "TC-974-02 cache=local removed" 'cache=local'; }
tree; edit "$T/$REL_KC" after:log=console 'hostname=rasputin.local' \
	&& { run_tree; refused "TC-974-02 hostname set" 'hostname'; }
FPP=spi-password-policy--password-blacklist--false-positive-probability
tree; edit "$T/$REL_KC" "replace:$FPP=1e-9" "$FPP=1.0E-4" \
	&& { run_tree; refused "F-1145-40 the deny list's false-positive probability at Keycloak's default" "$FPP=1e-9"; }

echo
echo "6. the checker refuses each wrong credential path (TC-974-04)"
tree; edit "$T/$REL_KC" "replace:https-certificate-key-file=$KC_CREDS/server.key" "https-certificate-key-file=$KC_CREDS/db-client.key" \
	&& { run_tree; refused "TC-974-04 keycloak.conf naming db-client.key, not a credential" "$KC_CREDS/db-client.key"; }
tree; edit "$T/$REL_KC" "replace:https-trust-store-file=$KC_CREDS/identity-ca.pem" "https-trust-store-file=/run/credentials/keycloak.service/identity-ca.pem" \
	&& { run_tree; refused "TC-1131-11 keycloak.conf with one literal /run/credentials/keycloak.service path restored" '/run/credentials/'; }
tree; chmod 0644 "$T/$REL_RECOVER"; run_tree
refused "TC-1131-11 the recovery launcher at 0644" 'recovery launcher is 0755'

echo
echo "7. the checker refuses each wrong postgresql.conf or pg_hba.conf (TC-974-05)"
tree; edit "$T/$REL_PG" replace:wal_level=minimal 'wal_level=replica' \
	&& { run_tree; refused "TC-974-05 wal_level=replica" 'wal_level=minimal'; }
tree; edit "$T/$REL_PG" "replace:hba_file='/etc/rasputin/identity/pg_hba.conf'" '' \
	&& { run_tree; refused "TC-974-05 no hba_file" 'hba_file'; }
tree; edit "$T/$REL_PG" "replace:hba_file='/etc/rasputin/identity/pg_hba.conf'" "hba_file='/etc/rasputin/identity/pg_hba.missing'" \
	&& { run_tree; refused "TC-974-05 an hba_file naming a missing file" 'pg_hba.missing exists in the overlay'; }
tree; printf '%s\n' 'hostssl all all 127.0.0.1/32 cert' >>"$T/$REL_HBA"; run_tree
refused "TC-974-05 a second pg_hba line" 'exactly one line' '2 line(s)'
tree; edit "$T/$REL_HBA" "replace:$WANT_HBA" 'host keycloak keycloak 127.0.0.1/32 cert' \
	&& { run_tree; refused "TC-974-05 host in place of hostssl" 'host keycloak keycloak 127.0.0.1/32 cert'; }
tree; edit "$T/$REL_PG" replace:log_statement=none 'log_statement=all' \
	&& { run_tree; refused "TC-974-05 log_statement=all" 'log_statement=none'; }
tree; edit "$T/$REL_PG" after:log_statement=none 'archive_mode=on' \
	&& { run_tree; refused "TC-974-05 a key outside the list" 'archive_mode'; }

echo
echo "8. the test fails closed (TC-974-01)"
tree; rm -f "$T/$REL_KC"; run_tree; failed_closed "TC-974-01 keycloak.conf missing" 'keycloak.conf is missing'
tree; chmod 000 "$T/$REL_KC"; run_tree; chmod 644 "$T/$REL_KC"
failed_closed "TC-974-01 keycloak.conf unreadable (run unprivileged)" 'keycloak.conf cannot be read'
tree; edit "$T/$REL_KC" after:log=console 'not an option' \
	&& { run_tree; failed_closed "TC-974-01 a keycloak.conf line that is not key=value" 'keycloak.conf is not blank, a # comment or key=value'; }
tree; rm -f "$T/$REL_PG"; run_tree; failed_closed "TC-974-01 postgresql.conf missing" 'postgresql.conf is missing'
tree; rm -f "$T/$REL_HBA"; run_tree; failed_closed "TC-974-01 pg_hba.conf missing" 'pg_hba.conf is missing'
tree; rm -f "$T/package/keycloak/kc-conf.sh"; run_tree; failed_closed "TC-974-01 package/keycloak/kc-conf.sh missing" 'kc-conf.sh is missing'

echo
if [ "$fails" -ne 0 ]; then echo "identity-config-test: $fails check(s) FAILED"; exit 1; fi
echo "identity-config-test: all checks passed"
