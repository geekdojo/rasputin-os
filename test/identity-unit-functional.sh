#!/bin/sh
# Functional test for the identity service's units, keycloak.service and
# keycloak-db.service, and keycloak.service's hooks
# (geekdojo/geekdojo-brain#973), against REAL systemd 258.7 as PID 1 (the
# release Buildroot 2026.08 builds into the image) with the REAL pinned
# Keycloak and Java runtime, each downloaded for this machine's architecture
# and checked against its package's .hash file, and Keycloak built with the
# pinned api tarball's identity/keycloak-build.conf as package/keycloak builds
# it.
#
# WHY THIS EXISTS. The units are systemd configuration around two third-party
# daemons, and the hooks are a contract with systemd's own state machine. What
# matters is what systemd, postgres and the JVM do with them together: whether
# Keycloak runs at all as 991 inside a read-only filesystem with no address
# but loopback, whether `active` waits for /health/started, whether a stop in
# start-post is orderly, whether a JVM that dies there ends the start at once,
# and whether three failed starts hold the unit with its cause. A static test
# or a stub ExecStart cannot show any of that.
#
# Scenarios, in one container, in this order:
#   0   the test fails closed: no docker, a failed download and a tarball that
#       does not match its .hash file each stop it with a sentence
#   28  before Identity 2.6, leaves present and no config: the api's exact
#       reset-failed and restart sequence leaves both units skipped
#   15  each condition's input removed in turn: that unit is skipped, not
#       failed, with no restart and no exit record; without mesh-ca.pem the
#       identity service fails
#   16  the start chain: the database reaches READY first, the service reads
#       start-post until /health/started answers UP over mutual TLS with the
#       db-client leaf, then active, and the start count is gone
#   17  each unit's processes: uid and gid, no capabilities, no core
#   18  each uid reads only its own credentials
#   19  writes confined to each unit's own directory (the K-P3 writes cell)
#   20  IPAddressDeny holds inside each unit's cgroup, with a control outside
#   26  the real at-rest audit over the live tree's identity rows
#   21  a TERM stop of the active service is success, exit 143, on record
#   22  a stop during start-post is success, by the service and by the
#       database
#   23  a JVM killed during start-post ends the start within two ticks, on
#       record as exited 137, and the unit restarts
#   24  three such starts in a row hold the unit, the record naming status 137,
#       read after `failed`; reset-failed and restart re-arm and start it
#   27  no key and no /health body in either unit's journal or the hooks'
#       lines, and the start wait's curl carries paths only
#   25  a database that exits at once on every start reaches systemd's start limit,
#       and starts again once the fault is gone
#
# TEST HARNESS, not from the image, and labelled where it is done:
#   * the keycloak (991) and postgres (992) users, which mkusers creates on the
#     image from RASPUTIN_IDENTITY_DB_USERS (Fedora's postgres user is moved to
#     992);
#   * Fedora 43's PostgreSQL 18.6 and curl, standing in for the carried
#     PostgreSQL 18 (#972) and Buildroot's curl;
#   * the Keycloak dist and the JRE extracted whole, where the packages
#     install a subset, and kc.sh build run in the container with the api
#     tarball's build conf, as keycloak.mk runs it at image build;
#   * Identity 2.6's keycloak.conf, postgresql.conf and pg_hba.conf, written
#     here from #957's probe configs with their paths moved to the units'
#     credentials;
#   * Identity 2.7's initdb and bootstrap SQL, run here once;
#   * a throwaway identity CA and its leaves (test/lib/test-pki.sh) standing
#     in for the ones the api mints (#977), and a mesh CA;
#   * a drop-in Environment= pointing the hooks' console line at a file,
#     because in a privileged container /dev/kmsg is the host's;
#   * scenario 20's UDP listeners and probe, scenario 27's curl recorder (a
#     drop-in RASPUTIN_KCHOOK_CURL for one start, which copies its own argv
#     from /proc and execs /usr/bin/curl), and scenario 25's bad setting;
#   * `mount --make-rshared /`, which a booted image gets from systemd's
#     mount-setup and a container does not.
#
# NOT COVERED: the shipped configuration (Identity 2.6), sign-in flows under
# the sandbox (the bench's TC-973-30 and TC-973-31, IDT-05), Buildroot's own
# curl and PostgreSQL builds (the image smoke's facts), TimeoutStartSec
# expiring (pinned statically only), start at boot, the runtime OOM kill
# order, and the other architecture: CI runs this on amd64.
#
# Needs: docker with privileged containers, openssl, GNU make, curl, tar,
# network access to Maven Central, Adoptium and the control-plane releases.
# Linux runner or Docker Desktop. RASPUTIN_API_TARBALL is
# test/lib/api-tarball.sh's test-only override; CI never sets it.
# Run:   sh test/identity-unit-functional.sh
#
# Every wait has a deadline and fails naming the fact that never became true.
# The deadlines bound the test; the units under test choose none.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
SYSD="$OVERLAY/etc/systemd/system"
HOOK_REL=usr/lib/rasputin/identity/rasputin-keycloak-hooks.sh
KCPKG="$ROOT/package/keycloak"
JREPKG="$ROOT/package/temurin-jre"
BASE=rasputin-identity-unit-functional:f43-systemd-258.7
IMAGE=rasputin-identity-unit-functional:harness
CTR_DEADLINE="${IDENTITY_UNIT_TEST_DEADLINE:-300}"
V=/var/lib/rasputin
KC=keycloak.service
DB=keycloak-db.service
KCCREDS=/run/credentials/$KC
DBCREDS=/run/credentials/$DB
PROBE_PORT=9973
HOLD=/run/rasputin-identity-start-hold/outcome
EXITS=/run/rasputin-identity-exits
COUNT=$V/identity/start-failures

# --- fail closed (scenario 0 checks this) ------------------------------------
command -v docker >/dev/null 2>&1 || { echo "FAILED: this test needs docker, and docker is not on PATH."; exit 1; }
for t in openssl make curl tar; do
	command -v "$t" >/dev/null 2>&1 || { echo "FAILED: this test needs $t, and it is not on PATH."; exit 1; }
done
for f in "$SYSD/$KC" "$SYSD/$DB" "$OVERLAY/$HOOK_REL" "$OVERLAY/usr/lib/rasputin/outcome/outcome.sh" \
	"$OVERLAY/usr/lib/tmpfiles.d/rasputin.conf" "$OVERLAY/usr/lib/rasputin/atrest/inventory" \
	"$OVERLAY/usr/lib/rasputin/atrest/rasputin-atrest-audit.sh" "$KCPKG/keycloak.mk" "$KCPKG/keycloak.hash" \
	"$JREPKG/temurin-jre.mk" "$JREPKG/temurin-jre.hash"; do
	[ -f "$f" ] || { echo "FAILED: the file $f is missing."; exit 1; }
done

. "$ROOT/test/lib/checks.sh"
. "$ROOT/test/lib/mk-var.sh"
. "$ROOT/test/lib/f43-systemd.sh"
. "$ROOT/test/lib/container-systemd.sh"
. "$ROOT/test/lib/test-pki.sh"
. "$ROOT/test/lib/api-tarball.sh"
neither() { ! contains "$1" "$3" && ! contains "$2" "$3"; }

SCRATCH=$(mktemp -d)
cleanup() { ctr_cleanup; rm -rf "$SCRATCH"; }
trap cleanup EXIT INT TERM

case "$(docker info --format '{{.Architecture}}' 2>/dev/null)" in
	aarch64|arm64) BR_ARCH=BR2_aarch64 HOSTARCH=aarch64 ;;
	x86_64|amd64) BR_ARCH=BR2_x86_64 HOSTARCH=x86_64 ;;
	*) echo "FAILED: docker reports an architecture this test has no JRE for: '$(docker info --format '{{.Architecture}}' 2>/dev/null)'."; exit 1 ;;
esac

# fetch SITE SOURCE HASHFILE — download SITE/SOURCE into SCRATCH and check it
# against its sha256 line in HASHFILE.
fetch() {
	_want=$(awk -v s="$2" '$1 == "sha256" && $3 == s { print $2 }' "$3")
	[ -n "$_want" ] || { echo "FAILED: $3 has no sha256 line for $2."; return 1; }
	echo "downloading $1/$2"
	curl -fsSL -o "$SCRATCH/$2" "$1/$2" \
		|| { echo "FAILED: the download of $1/$2 failed."; return 1; }
	_got=$(openssl dgst -sha256 -r "$SCRATCH/$2" | cut -d' ' -f1)
	[ "$_got" = "$_want" ] \
		|| { echo "FAILED: $2 does not match $(basename "$3") (got $_got, want $_want)."; return 1; }
	echo "  $2 matches $(basename "$3")"
}

# The pins, read the way Buildroot reads them. No version or URL is written in
# this file.
KC_SITE=$(mk_var "$KCPKG/keycloak.mk" KEYCLOAK_SITE) || exit 1
KC_SOURCE=$(mk_var "$KCPKG/keycloak.mk" KEYCLOAK_SOURCE) || exit 1
KC_VERSION=$(mk_var "$KCPKG/keycloak.mk" KEYCLOAK_VERSION) || exit 1
JRE_SITE=$(mk_var "$JREPKG/temurin-jre.mk" TEMURIN_JRE_SITE) || exit 1
JRE_SOURCE=$(mk_var "$JREPKG/temurin-jre.mk" TEMURIN_JRE_SOURCE BR2_PACKAGE_TEMURIN_JRE=y "$BR_ARCH=y" HOSTARCH="$HOSTARCH") || exit 1

echo
echo "0. the test fails closed"
SH_BIN=$(command -v sh)
mkdir -p "$SCRATCH/nodocker"
ln -s "$(command -v dirname)" "$SCRATCH/nodocker/dirname"
out=$(PATH="$SCRATCH/nodocker" "$SH_BIN" "$0" 2>&1); rc=$?
check "with no docker the test exits non-zero" "$(yes_if [ "$rc" -ne 0 ])" "exit=$rc"
check "with no docker the message names docker" "$(yes_if contains 'needs docker' "$out")" "$out"
check "with no docker nothing reports success or a skip" "$(yes_if neither passed skip "$out")" "$out"
out=$(fetch http://127.0.0.1:9 "$KC_SOURCE" "$KCPKG/keycloak.hash" 2>&1); rc=$?
check "a failed download is refused, named as one" "$({ [ "$rc" -ne 0 ] && contains 'the download of' "$out"; } && echo 0 || echo 1)" "$out"
mkdir -p "$SCRATCH/badsite"
echo "not the pinned tarball" >"$SCRATCH/badsite/$KC_SOURCE"
out=$(fetch "file://$SCRATCH/badsite" "$KC_SOURCE" "$KCPKG/keycloak.hash" 2>&1); rc=$?
check "a tarball that does not match keycloak.hash is refused, naming it" \
	"$({ [ "$rc" -ne 0 ] && contains 'does not match keycloak.hash' "$out"; } && echo 0 || echo 1)" "$out"
rm -f "$SCRATCH/$KC_SOURCE"

# --- the pinned Keycloak, JRE and build options -----------------------------------
fetch "$KC_SITE" "$KC_SOURCE" "$KCPKG/keycloak.hash" || exit 1
fetch "$JRE_SITE" "$JRE_SOURCE" "$JREPKG/temurin-jre.hash" || exit 1
mkdir -p "$SCRATCH/kc" "$SCRATCH/jre"
tar -xzf "$SCRATCH/$KC_SOURCE" -C "$SCRATCH/kc" --strip-components=1 \
	|| { echo "FAILED: $KC_SOURCE could not be extracted."; exit 1; }
tar -xzf "$SCRATCH/$JRE_SOURCE" -C "$SCRATCH/jre" --strip-components=1 \
	|| { echo "FAILED: $JRE_SOURCE could not be extracted."; exit 1; }
rm -f "$SCRATCH/$KC_SOURCE" "$SCRATCH/$JRE_SOURCE"
api_dir_fetch "$ROOT" "$BR_ARCH" "$SCRATCH/api" identity "the identity build options" || exit 1
[ -f "$API_DIR/keycloak-build.conf" ] || { echo "FAILED: api $API_VERSION's identity/ has no keycloak-build.conf."; exit 1; }

# --- the test PKI (TEST HARNESS: stands in for the identity CA and leaves) ---
P="$SCRATCH/pki"
mkdir -p "$P"
{
	mint_ca "$P/ca.key" "$P/identity-ca.pem" identity-unit-test-ca &&
	mint_leaf "$P/server.key" "$P/server.pem" "rasputin identity service" "$P/identity-ca.pem" "$P/ca.key" serverAuth IP:127.0.0.1 &&
	mint_leaf "$P/dbserver.key" "$P/dbserver.pem" "rasputin identity database" "$P/identity-ca.pem" "$P/ca.key" serverAuth IP:127.0.0.1 &&
	mint_leaf "$P/dbclient.key" "$P/dbclient.pem" keycloak "$P/identity-ca.pem" "$P/ca.key" clientAuth &&
	mint_ca "$P/mesh.key" "$P/mesh-ca.pem" identity-unit-test-mesh-ca &&
	(umask 077 && openssl pkcs8 -topk8 -nocrypt -outform DER -in "$P/dbclient.key" -out "$P/dbclient.pk8") 2>/dev/null
} || { echo "FAILED: openssl could not make the test PKI."; exit 1; }
rm -f "$P/ca.key" "$P/mesh.key"

# --- TEST HARNESS: Identity 2.6's configs, from #957's probe configs ---------
mkdir -p "$SCRATCH/conf"
cat >"$SCRATCH/conf/keycloak.conf" <<EOF
hostname-strict=false
hostname-backchannel-dynamic=false
proxy-headers=xforwarded
proxy-trusted-addresses=127.0.0.1/32
http-enabled=false
http-host=127.0.0.1
https-port=8543
https-protocols=TLSv1.3
https-certificate-file=$KCCREDS/server.pem
https-certificate-key-file=$KCCREDS/server.key
https-trust-store-file=$KCCREDS/identity-ca.pem
https-certificates-reload-period=-1
http-management-port=8544
cache=local
vault-dir=/run/rasputin-identity-vault
db-url-host=127.0.0.1
db-url-port=5432
db-url-database=keycloak
db-username=keycloak
db-url-properties=?sslmode=verify-full&sslrootcert=$KCCREDS/identity-ca.pem&sslcert=$KCCREDS/db-client.pem&sslkey=$KCCREDS/db-client.pk8
db-pool-max-size=8
log=console
EOF
cat >"$SCRATCH/conf/postgresql.conf" <<EOF
listen_addresses = '127.0.0.1'
port = 5432
unix_socket_directories = ''
hba_file = '/etc/rasputin/identity/pg_hba.conf'
ssl = on
ssl_min_protocol_version = 'TLSv1.3'
ssl_cert_file = '$DBCREDS/server.pem'
ssl_key_file = '$DBCREDS/server.key'
ssl_ca_file = '$DBCREDS/identity-ca.pem'
max_connections = 12
shared_buffers = 32MB
wal_level = minimal
max_wal_senders = 0
log_destination = 'stderr'
EOF
printf 'hostssl keycloak keycloak 127.0.0.1/32 cert\n' >"$SCRATCH/conf/pg_hba.conf"
printf 'CREATE ROLE keycloak LOGIN;\nCREATE DATABASE keycloak OWNER keycloak;\n' >"$SCRATCH/conf/bootstrap.sql"
# TEST HARNESS: scenario 27's curl recorder.
cat >"$SCRATCH/conf/curl-recorder" <<'EOF'
#!/bin/sh
tr '\0' '\n' </proc/$$/cmdline >>/run/curl-argv
echo -- >>/run/curl-argv
exec /usr/bin/curl "$@"
EOF

# --- the container ---------------------------------------------------------------
f43_systemd_image "$BASE" || exit 1
docker build -q -t "$IMAGE" - >/dev/null <<DOCKERFILE || { echo "FAILED: the harness image could not be built."; exit 1; }
FROM $BASE
RUN dnf -y install --setopt=install_weak_deps=False postgresql-server curl openssl nmap-ncat iproute procps-ng \
 && dnf clean all \
 && ! getent passwd 991 && ! getent passwd 992 && ! getent group 991 && ! getent group 992 \
 && groupmod -g 992 postgres && usermod -u 992 -g 992 postgres \
 && groupadd -g 991 keycloak && useradd -u 991 -g 991 -d / -s /sbin/nologin -M keycloak
DOCKERFILE

ctr_boot "the identity units" "$IMAGE" -v "$OVERLAY:/overlay:ro" || exit 1
echo "in the container: $(inside 'systemctl --version | head -1')"
if ! { docker cp "$SCRATCH/kc" "$CID:/usr/lib/keycloak" >/dev/null && docker cp "$SCRATCH/jre" "$CID:/usr/lib/temurin-jre" >/dev/null \
	&& docker cp "$P" "$CID:/pki" >/dev/null && docker cp "$SCRATCH/conf" "$CID:/harness" >/dev/null \
	&& docker cp "$API_DIR/keycloak-build.conf" "$CID:/harness/keycloak-build.conf" >/dev/null; }; then
	echo "FAILED: could not copy Keycloak, the JRE, the test PKI and the harness configs into the container."; exit 1
fi

inside "
set -e
# TEST HARNESS: a booted image gets a shared root from systemd's mount-setup.
mount --make-rshared /
chown -R 0:0 /usr/lib/keycloak /usr/lib/temurin-jre /pki /harness
# keycloak.mk's install: the data link and the theme link.
ln -sfn $V/keycloak/data /usr/lib/keycloak/data
ln -sfn /usr/share/rasputin/identity/theme /usr/lib/keycloak/themes/rasputin
# The image's tmpfiles.d creates the persistent tree, as on a node. Lines this
# container cannot satisfy (the console master copy, the baked root CA) are
# not this test's.
mkdir -p $V && chmod 0755 $V
install -D -m 0644 /overlay/usr/lib/tmpfiles.d/rasputin.conf /usr/lib/tmpfiles.d/rasputin.conf
systemd-tmpfiles --create /usr/lib/tmpfiles.d/rasputin.conf >/dev/null 2>&1 || true
# The units, the hook and its library, verbatim from the overlay.
install -m 0644 /overlay/etc/systemd/system/$KC /etc/systemd/system/$KC
install -m 0644 /overlay/etc/systemd/system/$DB /etc/systemd/system/$DB
install -D -m 0755 /overlay/$HOOK_REL /$HOOK_REL
install -D -m 0644 /overlay/usr/lib/rasputin/outcome/outcome.sh /usr/lib/rasputin/outcome/outcome.sh
install -D -m 0755 /overlay/usr/lib/rasputin/atrest/rasputin-atrest-audit.sh /usr/lib/rasputin/atrest/audit.sh
install -m 0755 /harness/curl-recorder /usr/local/bin/curl-recorder
# TEST HARNESS: in a privileged container /dev/kmsg is the host's.
mkdir -p /etc/systemd/system/$KC.d
printf '[Service]\nEnvironment=RASPUTIN_KCHOOK_KMSG=/run/kchook-console\n' >/etc/systemd/system/$KC.d/harness-console.conf
systemctl daemon-reload
" || { echo "FAILED: could not install the units, the hook and the harness into the container."; exit 1; }

# TEST HARNESS: kc.sh build with the api tarball's options, as keycloak.mk runs
# it at image build.
echo "kc.sh build with api $API_VERSION's keycloak-build.conf (Keycloak $KC_VERSION)"
inside "JAVA_HOME=/usr/lib/temurin-jre /usr/lib/keycloak/bin/kc.sh --config-file=/harness/keycloak-build.conf build >/tmp/kc-build.log 2>&1" \
	|| { inside 'tail -20 /tmp/kc-build.log'; echo "FAILED: kc.sh build failed on the api's build options."; exit 1; }

# put_* — the credential sources, written as their writers would.
put_role() { inside "touch $V/role.controlplane"; }
put_ca() { inside "install -m 0644 /pki/identity-ca.pem $V/trust/identity-ca.pem"; }
put_mesh() { inside "install -m 0644 /pki/mesh-ca.pem $V/trust/mesh-ca.pem"; }
put_leaves() {
	inside "install -m 0644 /pki/server.pem $V/tls/identity-server/leaf.pem && install -m 0600 /pki/server.key $V/tls/identity-server/leaf.key &&
		install -m 0644 /pki/dbserver.pem $V/tls/identity-db-server/leaf.pem && install -m 0600 /pki/dbserver.key $V/tls/identity-db-server/leaf.key &&
		install -m 0644 /pki/dbclient.pem $V/tls/identity-db-client/leaf.pem && install -m 0600 /pki/dbclient.key $V/tls/identity-db-client/leaf.key &&
		install -m 0600 /pki/dbclient.pk8 $V/tls/identity-db-client/leaf.pk8"
}
put_confs() {
	inside "install -D -m 0644 /harness/keycloak.conf /etc/rasputin/identity/keycloak.conf &&
		install -m 0644 /harness/postgresql.conf /etc/rasputin/identity/postgresql.conf &&
		install -m 0644 /harness/pg_hba.conf /etc/rasputin/identity/pg_hba.conf"
}
show() { inside "systemctl show -P $2 $1"; }
# settled UNIT — no job queued for UNIT.
settled() { wait_for "$1 has no job" "[ -z \"\$(systemctl show -P Job $1)\" ]"; }
# cursor — the journal's cursor now, so a check reads only what came after.
cursor() { inside "journalctl -n 0 --show-cursor | sed -n 's/^-- cursor: //p'"; }
desc() { case "$1" in "$KC") echo 'Rasputin identity service' ;; *) echo 'Rasputin identity database' ;; esac; }
# skipped LABEL UNIT CURSOR PATH — after CURSOR, systemd's journal line for
# UNIT's start skipped on the unmet ConditionPathExists=PATH, and UNIT is
# ConditionResult=no, inactive, MainPID 0, no restarts and not failed. The
# journal line is the proof the condition was what stopped it: systemd 258.7
# unloads a unit nothing references once its start is skipped, so the state
# read afterwards is a freshly loaded unit's.
skipped() {
	_line="$2 - $(desc "$2") skipped, unmet condition check ConditionPathExists=$4"
	check "$1: the journal says '$_line'" \
		"$(yes_if inside "journalctl --after-cursor='$3' -u $2 -o cat --no-pager | grep -qxF '$_line'")" \
		"$(inside "journalctl --after-cursor='$3' -u $2 -o cat --no-pager")"
	_s="$(show "$2" ConditionResult) $(show "$2" ActiveState) $(show "$2" MainPID) $(show "$2" NRestarts)"
	check "$1: $2 is ConditionResult=no, inactive, MainPID=0, NRestarts=0 (got '$_s')" "$(yes_if [ "$_s" = "no inactive 0 0" ])"
	_f=$(inside "systemctl --failed --no-legend --plain" | grep -e "$KC" -e "$DB" || true)
	check "$1: neither unit is in systemctl --failed" "$(yes_if [ -z "$_f" ])" "$_f"
}
no_exits() { check "$1: no exit record is written" "$(yes_if [ -z "$(inside "ls -A $EXITS 2>/dev/null")" ])" "$(inside "ls -A $EXITS 2>&1")"; }
# reset — both units stopped and reset, and the hooks' state cleared.
reset() {
	inside "systemctl stop $KC $DB; systemctl reset-failed $KC $DB; rm -rf $EXITS ${HOLD%/*} $COUNT /run/kchook-console" >/dev/null 2>&1
}
# last_rec — the exit record `last` names.
last_rec() { inside "cat $EXITS/\$(cat $EXITS/last)"; }
# in_start_post — wait until keycloak.service reads activating/start-post with
# its JVM running.
in_start_post() {
	wait_for "$KC reads activating/start-post with its JVM running" \
		"[ \"\$(systemctl show -P ActiveState $KC)/\$(systemctl show -P SubState $KC)\" = activating/start-post ] && pgrep -P \$(systemctl show -P MainPID $KC) java"
}
active_kc() { wait_for "$KC is active" "[ \"\$(systemctl show -P ActiveState $KC)\" = active ]"; }

echo
echo "28. before Identity 2.6: leaves present, no config, the api's sequence (TC-973-28)"
{ put_role && put_ca && put_mesh && put_leaves; } || { echo "FAILED: the credential sources could not be written."; exit 1; }
c=$(cursor)
# Each call's exit status and its stderr, kept apart.
out=$(inside "rc=''; for c in 'reset-failed $DB $KC' 'restart $DB' 'reset-failed $DB $KC' 'restart $KC'; do
		systemctl \$c 2>>/tmp/api-seq.err; rc=\"\$rc \$?\"; done; echo \$rc")
err=$(inside 'cat /tmp/api-seq.err')
printf '    statuses:%s\n' "$out"
printf '%s\n' "$err" | sed 's/^/    /'
check "TC-973-28 both restarts in the api's sequence exit 0 (statuses:$out)" \
	"$(yes_if [ "$(echo $out | cut -d' ' -f2,4)" = "0 0" ])"
# systemd 258.7 keeps no unit loaded that nothing references: these units have
# no [Install] and nothing wants them before Identity 2.6, and a skipped start
# leaves them unloaded again, so `reset-failed` on them exits 1 naming that.
# Pinned here as what the api meets, not hidden (reported against TC-973-28).
bad_err=$(printf '%s\n' "$err" | grep -v -e "^Failed to reset failed state of unit $DB: Unit $DB not loaded\.$" \
	-e "^Failed to reset failed state of unit $KC: Unit $KC not loaded\.$" | grep . || true)
check "TC-973-28 each reset-failed exits 0, or 1 saying only that the unit is not loaded (statuses:$out)" \
	"$({ [ -z "$bad_err" ] && for r in $(echo $out | cut -d' ' -f1,3); do [ "$r" = 0 ] || [ "$r" = 1 ] || exit 1; done; } && echo 0 || echo 1)" "$bad_err"
skipped "TC-973-28" "$DB" "$c" /etc/rasputin/identity/postgresql.conf
skipped "TC-973-28" "$KC" "$c" /etc/rasputin/identity/keycloak.conf
no_exits "TC-973-28"

echo
echo "15. each input removed in turn: skipped, not failed (TC-973-15)"
put_confs || { echo "FAILED: the harness configs could not be written."; exit 1; }
# TEST HARNESS: Identity 2.7's initdb and bootstrap SQL, as postgres.
inside "setpriv --reuid=992 --regid=992 --clear-groups /usr/bin/initdb -D $V/identity-db/data -E UTF8 \
		--locale-provider=builtin --builtin-locale=C.UTF-8 --locale=C -U postgres -A reject --no-instructions >/tmp/initdb.log 2>&1 &&
	setpriv --reuid=992 --regid=992 --clear-groups /usr/bin/postgres --single -D $V/identity-db/data postgres </harness/bootstrap.sql >/tmp/bootstrap.log 2>&1" \
	|| { inside 'cat /tmp/initdb.log /tmp/bootstrap.log | tail -20'; echo "FAILED: initdb or the bootstrap SQL failed."; exit 1; }
# Each removal: the input, the unit started, and the unit that skips.
while IFS='|' read -r what start; do
	reset
	inside "mv $what /tmp/held-aside"
	c=$(cursor)
	inside "systemctl start $start" >/dev/null 2>&1
	settled "$start"
	skipped "TC-973-15 without $what" "$start" "$c" "$what"
	no_exits "TC-973-15 without $what"
	inside "mv /tmp/held-aside $what"
done <<EOF_INPUTS
$V/role.controlplane|$KC
$V/trust/identity-ca.pem|$KC
$V/tls/identity-server/leaf.pem|$KC
$V/tls/identity-server/leaf.key|$KC
$V/tls/identity-db-client/leaf.pem|$KC
$V/tls/identity-db-client/leaf.pk8|$KC
/etc/rasputin/identity/keycloak.conf|$KC
$V/role.controlplane|$DB
$V/trust/identity-ca.pem|$DB
$V/tls/identity-db-server/leaf.pem|$DB
$V/tls/identity-db-server/leaf.key|$DB
/etc/rasputin/identity/postgresql.conf|$DB
EOF_INPUTS
reset
inside "mv $V/trust/mesh-ca.pem /tmp/held-aside; systemctl start $KC" >/dev/null 2>&1
wait_for "$KC is failed without mesh-ca.pem" "[ \"\$(systemctl show -P ActiveState $KC)\" = failed ]"
check "TC-973-15 without mesh-ca.pem $KC is failed (got $(show $KC ActiveState)/$(show $KC Result))" \
	"$(yes_if [ "$(show $KC ActiveState)" = failed ])"
inside "mv /tmp/held-aside $V/trust/mesh-ca.pem"
reset

echo
echo "16. the start chain and the start wait (TC-973-16)"
# The SubState samples come from one loop in the container, so a short
# start-post is not missed between docker exec calls.
inside "systemctl start --no-block $KC; i=0; : >/tmp/samples
	while [ \$i -lt $((CTR_DEADLINE * 10)) ]; do
		s=\"\$(systemctl show -P ActiveState $DB)/\$(systemctl show -P SubState $DB) \$(systemctl show -P ActiveState $KC)/\$(systemctl show -P SubState $KC)\"
		tail -n 1 /tmp/samples | grep -qxF \"\$s\" || echo \"\$s\" >>/tmp/samples
		case \"\$s\" in *' active/running'|*failed*) break ;; esac
		sleep 0.1; i=\$((i + 1))
	done"
samples=$(inside 'cat /tmp/samples')
printf '%s\n' "$samples" | sed 's/^/    /'
check "TC-973-16 $KC reaches active/running" "$(yes_if [ "$(show $KC ActiveState)/$(show $KC SubState)" = active/running ])" \
	"$(inside "journalctl -u $KC -u $DB --no-pager -o cat | tail -40")"
check "TC-973-16 $KC read activating/start-post, and $DB was already active/running then" \
	"$(yes_if contains 'active/running activating/start-post' "$samples")" "$samples"
check "TC-973-16 $KC never read active before start-post" \
	"$(yes_if [ -z "$(printf '%s\n' "$samples" | sed '/start-post/,$d' | grep ' active/')" ])" "$samples"
check "TC-973-16 $DB never read activating once $KC was in start-post (it reached READY first)" \
	"$(yes_if [ -z "$(printf '%s\n' "$samples" | grep '^activating.* activating/start-post')" ])" "$samples"
up_at=$(inside "journalctl -u $KC -o short-unix --no-pager | grep 'rasputin-keycloak-hooks: The sign-in service has started' | head -1 | cut -d' ' -f1 | cut -d. -f1")
act_at=$(inside "systemctl show -P ActiveEnterTimestamp --timestamp=unix $KC" | tr -d @)
check "TC-973-16 the hook logged UP (at $up_at) no later than $KC became active (at $act_at)" \
	"$({ [ -n "$up_at" ] && [ -n "$act_at" ] && [ "$up_at" -le "$act_at" ]; } && echo 0 || echo 1)"
check "TC-973-16 the start count is gone" "$(yes_if inside "[ ! -e $COUNT ]")"
# The same mutual-TLS ask the hook makes, from the test: UP with the
# db-client leaf; refused without a client certificate.
out=$(inside "curl -sS --tlsv1.3 --max-time 10 --cacert $V/trust/identity-ca.pem --cert $V/tls/identity-db-client/leaf.pem --key $V/tls/identity-db-client/leaf.key https://127.0.0.1:8544/health/started")
check "TC-973-16 /health/started answers UP to the db-client leaf" "$(yes_if contains '"UP"' "$out")" "$out"
out=$(inside "curl -sS --tlsv1.3 --max-time 10 --cacert $V/trust/identity-ca.pem https://127.0.0.1:8544/health/started 2>&1; echo rc=\$?")
check "TC-973-16 without a client certificate the management port refuses the handshake (mutual TLS)" \
	"$({ ! contains '"UP"' "$out" && contains 'certificate required' "$out"; } && echo 0 || echo 1)" "$out"

echo
echo "17. each unit's processes: uid, capabilities, core (TC-973-17)"
for spec in "$KC 991" "$DB 992"; do
	u=${spec%% *} id=${spec#* }
	cg=$(show "$u" ControlGroup)
	pids=$(inside "cat /sys/fs/cgroup$cg/cgroup.procs" | tr '\n' ' ')
	check "TC-973-17 $u has processes ($pids)" "$(yes_if [ -n "$pids" ])"
	for pid in $pids; do
		st=$(inside "grep -E '^(Uid|Gid|CapEff|CapBnd):' /proc/$pid/status | tr -s '\t' ' '")
		check "TC-973-17 $u pid $pid runs as $id:$id with no capabilities" \
			"$(yes_if [ "$st" = "Uid: $id $id $id $id
Gid: $id $id $id $id
CapEff: 0000000000000000
CapBnd: 0000000000000000" ])" "$st"
		lim=$(inside "awk '/^Max core file size/ { print \$5, \$6 }' /proc/$pid/limits")
		check "TC-973-17 $u pid $pid has a core limit of 0:0 (got '$lim')" "$(yes_if [ "$lim" = "0 0" ])"
	done
done

echo
echo "18. each uid reads only its own credentials (TC-973-18)"
# as_uid UID COMMAND — COMMAND as UID, its own group, no supplementary groups.
as_uid() { inside "setpriv --reuid=$1 --regid=$1 --clear-groups sh -c '$2' 2>&1"; }
names=$(inside "ls $KCCREDS" | tr '\n' ' ')
check "TC-973-18 $KCCREDS holds exactly the six credentials, no leaf.key copy (got '$names')" \
	"$(yes_if [ "$names" = "db-client.pem db-client.pk8 identity-ca.pem mesh-ca.pem server.key server.pem " ])"
for spec in "991 $KCCREDS $DBCREDS" "992 $DBCREDS $KCCREDS"; do
	# shellcheck disable=SC2086 # the three words of spec, on purpose
	set -- $spec
	out=$(as_uid "$1" "for f in $2/*; do cat \"\$f\" >/dev/null || echo FAILED \$f; done; echo done")
	check "TC-973-18 uid $1 reads every file in $2" "$(yes_if [ "$out" = 'done' ])" "$out"
	out=$(as_uid "$1" "ls $3")
	check "TC-973-18 uid $1 gets EACCES on $3" "$(yes_if contains 'Permission denied' "$out")" "$out"
	for f in $V/tls/identity-db-client/leaf.key $V/tls/identity-server/leaf.key $V/tls/identity-db-server/leaf.key \
		$V/tls/identity-db-client/leaf.pk8 $V/trust/identity-ca.pem $V/trust/mesh-ca.pem; do
		out=$(as_uid "$1" "cat $f >/dev/null")
		check "TC-973-18 uid $1 cannot read $f" "$(yes_if contains 'Permission denied' "$out")" "$out"
	done
done

echo
echo "19. writes confined to each unit's own directory (TC-973-19, the K-P3 writes cell)"
# in_ns UNIT UID COMMAND — COMMAND in UNIT's mount namespace, as UID.
in_ns() { inside "nsenter -t \$(systemctl show -P MainPID $1) -m setpriv --reuid=$2 --regid=$2 --clear-groups sh -c '$3' 2>&1"; }
for spec in "$KC 991 $V/keycloak/data $V/identity-db/data" "$DB 992 $V/identity-db/data $V/keycloak/data"; do
	# shellcheck disable=SC2086 # the four words of spec, on purpose
	set -- $spec
	out=$(in_ns "$1" "$2" "touch $3/.write-probe && rm $3/.write-probe && echo written")
	check "TC-973-19 $1 writes under its own $3" "$(yes_if [ "$out" = written ])" "$out"
	for d in /usr/lib/keycloak /etc "$V" "$4"; do
		out=$(in_ns "$1" "$2" "touch $d/.write-probe")
		check "TC-973-19 $1 cannot write to $d (EROFS or EACCES)" \
			"$({ contains 'Read-only file system' "$out" || contains 'Permission denied' "$out"; } && echo 0 || echo 1)" "${out:-written}"
	done
done
inside "rm -f $V/.write-probe /etc/.write-probe /usr/lib/keycloak/.write-probe $V/keycloak/data/.write-probe $V/identity-db/data/.write-probe" >/dev/null 2>&1

echo
echo "20. IPAddressDeny holds inside each unit, with a control (TC-973-20)"
ADDR=$(inside "ip -4 -o addr show scope global | awk '{ sub(/\\/.*/, \"\", \$4); print \$4; exit }'")
[ -n "$ADDR" ] || { echo "FAILED: the container has no non-loopback IPv4 address to probe."; exit 1; }
echo "non-loopback address: $ADDR"
# TEST HARNESS: UDP listeners on the non-loopback address and on loopback,
# each writing what it receives to a file; restarted per probe round, as
# ncat -u -l takes one peer.
listen() {
	inside "systemctl stop probe-listen-lan probe-listen-lo 2>/dev/null; rm -f /run/probe-lan /run/probe-lo
		systemd-run --quiet --unit=probe-listen-lan -p StandardOutput=append:/run/probe-lan ncat -u -l $ADDR $PROBE_PORT &&
		systemd-run --quiet --unit=probe-listen-lo -p StandardOutput=append:/run/probe-lo ncat -u -l 127.0.0.1 $PROBE_PORT" \
		&& wait_for "both probe listeners are bound" \
			"ss -Hlun | grep -q '$ADDR:$PROBE_PORT' && ss -Hlun | grep -q '127.0.0.1:$PROBE_PORT'"
}
# probe CGROUP HOST TOKEN — TOKEN in one UDP datagram to HOST:PROBE_PORT from
# a shell that first joins CGROUP (or "" for its own); prints "sent" or
# bash's error. UDP, because the firewall's verdict reaches the sender at
# once: a send the egress program drops fails with EPERM, while a dropped TCP
# SYN is retransmitted and only times out (tcp_connect ignores the transmit
# error).
probe() {
	inside "sh -c '[ -z \"$1\" ] || echo \$\$ > \"/sys/fs/cgroup$1/cgroup.procs\" || exit 9
		exec bash -c \"exec 3<>/dev/udp/$2/$PROBE_PORT && echo $3 >&3 && echo sent\"' 2>&1"
}
received() { wait_for "the listener's $1 holds $2" "grep -qx '$2' $1"; }
listen || exit 1
out=$(probe "" "$ADDR" outside-lan)
check "TC-973-20 control: outside both units the send to $ADDR succeeds" "$(yes_if [ "$out" = sent ])" "$out"
check "TC-973-20 control: the listener on $ADDR received it, so the network carries it outside the units" \
	"$(yes_if received /run/probe-lan outside-lan)"
for u in $KC $DB; do
	listen || exit 1
	cg=$(show "$u" ControlGroup)
	out=$(probe "$cg" "$ADDR" "in-$u")
	check "TC-973-20 inside $u's cgroup the send to $ADDR gets EPERM" "$(yes_if contains 'Operation not permitted' "$out")" "$out"
	out=$(probe "$cg" 127.0.0.1 "lo-$u")
	check "TC-973-20 inside $u's cgroup the send to 127.0.0.1 succeeds" "$(yes_if [ "$out" = sent ])" "$out"
	check "TC-973-20 the loopback listener received it" "$(yes_if received /run/probe-lo "lo-$u")"
	check "TC-973-20 the listener on $ADDR never received $u's datagram" \
		"$(yes_if inside "! grep -qx in-$u /run/probe-lan")" "$(inside 'cat /run/probe-lan')"
done
inside "systemctl stop probe-listen-lan probe-listen-lo" >/dev/null 2>&1
check "TC-973-20 $KC is active under RestrictAddressFamilies=AF_INET AF_UNIX" \
	"$({ [ "$(show $KC ActiveState)" = active ] && [ "$(show $KC RestrictAddressFamilies)" = 'AF_INET AF_UNIX' ]; } && echo 0 || echo 1)" \
	"$(show $KC ActiveState) $(show $KC RestrictAddressFamilies)"

echo
echo "26. the at-rest audit over the live tree's identity rows (TC-973-26)"
inside "grep -E '^[^#]*[[:space:]]/var/lib/rasputin/(identity|keycloak|tls/identity-|trust/identity-)' \
	/overlay/usr/lib/rasputin/atrest/inventory >/tmp/identity-inventory" >/dev/null
inside 'sed "s/^/    /" /tmp/identity-inventory'
# Present on the live tree: the eleven directories, the three leaf keys and
# the db-client pk8 the harness wrote; the count is gone after UP, so the
# sweep of identity/ visits nothing. 15.
out=$(inside "sh /usr/lib/rasputin/atrest/audit.sh -i /tmp/identity-inventory -q; echo rc=\$?")
check "TC-973-26 the real audit over the identity rows says PASS checked=15 and exits 0" \
	"$({ contains 'rasputin-atrest: PASS checked=15' "$out" && contains 'rc=0' "$out"; } && echo 0 || echo 1)" "$out"

echo
echo "21. a TERM stop of the active service (TC-973-21)"
inside "systemctl stop $KC"
st="$(show $KC ActiveState) $(show $KC Result)"
check "TC-973-21 $KC is inactive with Result=success (got '$st')" "$(yes_if [ "$st" = "inactive success" ])"
rec=$(last_rec)
check "TC-973-21 last names a record of success, exited 143" \
	"$({ contains 'outcome=success' "$rec" && contains 'exit_code=exited' "$rec" && contains 'exit_status=143' "$rec"; } && echo 0 || echo 1)" "$rec"
check "TC-973-21 $DB is still active (Requires= runs one way)" "$(yes_if [ "$(show $DB ActiveState)" = active ])"

echo
echo "22. a stop during start-post is orderly (TC-973-22, F-973-02)"
for stopper in $KC $DB; do
	inside "systemctl start $DB && systemctl start --no-block $KC"
	in_start_post || { check "TC-973-22 ($stopper) $KC reached start-post" 1; continue; }
	inside "systemctl stop $stopper"
	settled "$KC"
	st="$(show $KC ActiveState) $(show $KC Result)"
	check "TC-973-22 stopping $stopper during start-post leaves $KC inactive with Result=success (got '$st')" \
		"$(yes_if [ "$st" = "inactive success" ])"
	rec=$(last_rec)
	check "TC-973-22 stopping $stopper: the record says outcome=success" "$(yes_if contains 'outcome=success' "$rec")" "$rec"
done
check "TC-973-22 the wait logged the stop" \
	"$(yes_if inside "journalctl -u $KC -o cat --no-pager | grep -q 'rasputin-keycloak-hooks: The sign-in service was stopped before /health/started answered UP'")"

echo
echo "23. a JVM killed during start-post ends the start within two ticks (TC-973-23, F-979-11)"
reset
inside "systemctl start $DB && systemctl start --no-block $KC"
in_start_post || exit 1
# One loop in the container: kill, then time until start-post ends.
ms=$(inside "j=\$(pgrep -P \$(systemctl show -P MainPID $KC) java); t0=\$(date +%s%N); kill -9 \$j; i=0
	while [ \"\$(systemctl show -P SubState $KC)\" = start-post ] && [ \$i -lt 600 ]; do sleep 0.05; i=\$((i + 1)); done
	echo \$(( (\$(date +%s%N) - t0) / 1000000 ))")
check "TC-973-23 start-post ended ${ms} ms after the kill, within two 1 s ticks" "$({ [ -n "$ms" ] && [ "$ms" -le 2000 ]; } && echo 0 || echo 1)"
wait_for "$KC restarted once" "[ \"\$(systemctl show -P NRestarts $KC)\" = 1 ]"
rec=$(last_rec)
check "TC-973-23 the record says exit-code, exited, 137" \
	"$({ contains 'outcome=exit-code' "$rec" && contains 'exit_code=exited' "$rec" && contains 'exit_status=137' "$rec"; } && echo 0 || echo 1)" "$rec"
check "TC-973-23 the unit starts again (NRestarts=1)" "$(yes_if [ "$(show $KC NRestarts)" = 1 ])"

echo
echo "24. three starts in a row that never reach UP hold the unit (TC-973-24)"
for n in 2 3; do
	in_start_post || exit 1
	check "TC-973-24 start $n counts $n" "$(yes_if [ "$(inside "cat $COUNT")" = "$n" ])" "$(inside "cat $COUNT")"
	inside "kill -9 \$(pgrep -P \$(systemctl show -P MainPID $KC) java)"
	wait_for "$KC restarted $n times" "[ \"\$(systemctl show -P NRestarts $KC)\" -ge $n ]"
done
wait_for "$KC is failed with no job left" "[ \"\$(systemctl show -P ActiveState $KC)\" = failed ] && [ -z \"\$(systemctl show -P Job $KC)\" ]" || exit 1
check "TC-973-24 the fourth start was refused and $KC ended failed (Result=$(show $KC Result))" \
	"$(yes_if [ "$(show $KC ActiveState)" = failed ])"
boot=$(inside 'cat /proc/sys/kernel/random/boot_id')
hold=$(inside "cat $HOLD")
reason=$(printf '%s\n' "$hold" | sed -n 's/^reason=//p')
check "TC-973-24 read after failed, the hold record is exactly outcome=refused, the container's boot_id and a reason" \
	"$({ [ "$(printf '%s\n' "$hold" | sed -n '1p;2p')" = "outcome=refused
boot_id=$boot" ] && [ "$(printf '%s\n' "$hold" | grep -c .)" = 3 ]; } && echo 0 || echo 1)" "$hold"
check "TC-973-24 the reason names status 137 (F-973-01)" "$(yes_if contains 'exit-code, status 137' "$reason")" "$reason"
check "TC-973-24 start-failures reads 3" "$(yes_if [ "$(inside "cat $COUNT")" = 3 ])" "$(inside "cat $COUNT")"
# Recovery, with scenario 27's curl recorder on this one start.
inside "printf '[Service]\nEnvironment=RASPUTIN_KCHOOK_CURL=/usr/local/bin/curl-recorder\n' >/etc/systemd/system/$KC.d/harness-curl.conf && systemctl daemon-reload && rm -f /run/curl-argv"
inside "systemctl reset-failed $KC $DB && systemctl restart $KC"
active_kc
check "TC-973-24 reset-failed and restart: $KC is active" "$(yes_if [ "$(show $KC ActiveState)" = active ])"
check "TC-973-24 the hold record is removed" "$(yes_if inside "[ ! -e $HOLD ]")"
check "TC-973-24 the count is absent" "$(yes_if inside "[ ! -e $COUNT ]")"
inside "rm -f /etc/systemd/system/$KC.d/harness-curl.conf && systemctl daemon-reload"

echo
echo "27. no secret in logs or argv (TC-973-27, LOG-SECRETS)"
journal=$(inside "journalctl -u $KC -u $DB -o cat --no-pager; cat /run/kchook-console 2>/dev/null")
leaks=0
for k in server.key dbserver.key dbclient.key; do
	for line in $(grep -v -e '^-----' "$P/$k"); do
		contains "$line" "$journal" && leaks=$((leaks + 1))
	done
done
check "TC-973-27 no line of the three test keys' PEM bodies is in either unit's journal ($leaks found)" "$(yes_if [ "$leaks" -eq 0 ])"
check "TC-973-27 no /health response body is in the journal" "$({ ! contains '"status"' "$journal"; } && echo 0 || echo 1)"
argv=$(inside "cat /run/curl-argv")
check "TC-973-27 the recorder caught the wait's curl" "$(yes_if contains 'health/started' "$argv")" "$argv"
bad=$(printf '%s\n' "$argv" | grep -vxF -e /usr/local/bin/curl-recorder -e /bin/sh -e -- -e -s -e --tlsv1.3 -e --max-time -e 10 \
	-e --cacert -e --cert -e --key -e -w -e '\n%{http_code}' -e "$V/trust/identity-ca.pem" \
	-e "$V/tls/identity-db-client/leaf.pem" -e "$V/tls/identity-db-client/leaf.key" \
	-e https://127.0.0.1:8544/health/started || true)
check "TC-973-27 the curl argv holds options and paths only" "$(yes_if [ -z "$bad" ])" "$bad"

echo
echo "19b. no Read-only file system line after the starts and stops above (TC-973-19)"
n=$(inside "journalctl -u $KC -u $DB -o cat --no-pager | grep -c 'Read-only file system'")
check "TC-973-19 Keycloak's and postgres's journals have no 'Read-only file system' line (got $n)" "$(yes_if [ "$n" = 0 ])"

echo
echo "25. a database that exits at once on every start reaches the start limit (TC-973-25)"
reset
# TEST HARNESS: a setting postgres refuses, so it exits before READY on
# every start: a persistent fast fault, so systemd's own counting reaches the
# limit and not the test's speed.
inside "cp /etc/rasputin/identity/postgresql.conf /tmp/pg.good && echo 'rasputin_bogus_setting = 1' >>/etc/rasputin/identity/postgresql.conf"
cursor=$(cursor)
inside "systemctl start $DB" >/dev/null 2>&1
wait_for "$DB is failed with no job left" "[ \"\$(systemctl show -P ActiveState $DB)\" = failed ] && [ -z \"\$(systemctl show -P Job $DB)\" ]" || exit 1
# systemd 258.7 refuses the restart after the burst and keeps the crash's own
# Result, exit-code, as test/store-unit-functional.sh's crash loop pins for
# openbao.service; its "Start request repeated too quickly" line is the
# start limit's own record.
burst=$(show $DB StartLimitBurst)
st="$(show $DB ActiveState) $(show $DB Result) $(show $DB NRestarts)"
check "TC-973-25 $DB is failed, Result=exit-code, NRestarts=StartLimitBurst=$burst (got '$st')" \
	"$(yes_if [ "$st" = "failed exit-code $burst" ])"
check "TC-973-25 the journal says the start limit refused it: 'Start request repeated too quickly'" \
	"$(yes_if inside "journalctl --after-cursor='$cursor' -u $DB -o cat --no-pager | grep -q 'Start request repeated too quickly'")"
starts=$(inside "journalctl --after-cursor='$cursor' -u $DB -o cat --no-pager | grep -c '^Starting keycloak-db.service'")
check "TC-973-25 $DB was started StartLimitBurst=$burst times, systemd's own count (got $starts)" "$(yes_if [ "$starts" = "$burst" ])"
inside "cp /tmp/pg.good /etc/rasputin/identity/postgresql.conf && systemctl reset-failed $DB && systemctl start $DB"
check "TC-973-25 with the fault gone, reset-failed and start bring it to active" "$(yes_if [ "$(show $DB ActiveState)" = active ])"
reset

echo
if [ "$fails" -eq 0 ]; then
	echo "identity-unit-functional: all checks passed"
else
	echo "identity-unit-functional: $fails check(s) FAILED"
fi
[ "$fails" -eq 0 ]
