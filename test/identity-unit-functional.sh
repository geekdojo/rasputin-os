#!/bin/sh
# Functional test for the identity service's units, keycloak.service and
# keycloak-db.service, keycloak.service's hooks (geekdojo/geekdojo-brain#973),
# and the configuration the image bakes for them (geekdojo/geekdojo-brain#974,
# Identity 2.6), against REAL systemd 258.7 as PID 1 (the
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
#   28  the units enabled by post-build.sh's own link lines, with the shipped
#       configs installed byte-identical to the overlay: the api's exact
#       reset-failed and restart sequence exits 0 at every call and both
#       units reach active, with no build-option drift line (F-973-12;
#       TC-974-13, TC-974-14)
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
#   Identity 2.7's first boot (geekdojo/geekdojo-brain#975), from emptied data:
#   29  the first start creates the database through the gate, records
#       `created`, imports the realm once and creates no administrator; the
#       locale provider is builtin and checksums are on
#   30  a same-boot restart of the database keeps the `created` record, with
#       no second initdb
#   31  data present, not armed, after a new boot: `untouched`, the baseline
#       staged, the realm import skipped
#   32  armed with data present: `untouched`, the staged baseline removed
#   33  armed with the data emptied: `refused`, the database held stopped and
#       Keycloak not active, also after the api's reset-failed and restarts
#   34  the reboot points of a first start, each re-run on its own facts
#   Identity 2.6's shipped configuration (geekdojo/geekdojo-brain#974):
#   35  the WAL settings, the TLS 1.3 floor and a TLS 1.2 client refused, and
#       the database's only listener 127.0.0.1:5432 with no Unix socket
#       (TC-974-15)
#   36  Keycloak's only listeners 127.0.0.1:8543 and :8544, at ready and after
#       a restart (TC-974-16, K-P3 cache=local)
#   37  the written outbound truststore holds the mesh CA alone (TC-974-17)
#   38  every pgjdbc backend is TLS 1.3 with the db-client leaf's subject,
#       read from the PKCS-8 key (TC-974-18)
#   Identity 2.9's admin recovery (geekdojo/geekdojo-brain#1131), the
#   launcher run as the api runs it, a synthetic secret on stdin:
#   39  with keycloak.service stopped, kc.sh bootstrap-admin runs in the
#       transient unit with keycloak.service's user, credentials and sandbox,
#       read while it runs; the secret is in no argv and not in the transient
#       unit file; no root-owned file is left; Keycloak starts, and the
#       temporary client gets a token and reads the realm over the Admin API
#       (TC-1131-12, TC-1131-13)
#   40  with the database stopped too, the run fails, leaves no root-owned
#       file and frees the unit name, and Keycloak starts; a second run then
#       succeeds (TC-1131-14, TC-1131-15)
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
#   * an empty jssecacerts in the harness JRE, made by temurin-jre.mk's own
#     recipe (the image's JRE ships one; the extracted tarball does not);
#   * the realm baseline, copied from the pinned api tarball's identity/ to
#     the path the api package installs it at;
#   * a throwaway identity CA and its leaves (test/lib/test-pki.sh) standing
#     in for the ones the api mints (#977), and a mesh CA;
#   * drop-ins Environment= pointing the hooks' console lines at files,
#     because in a privileged container /dev/kmsg is the host's;
#   * removing /run/rasputin-identity-db-init/ and running tmpfiles again,
#     standing in for a new boot, and scenario 34's interrupted states;
#   * scenario 20's UDP listeners and probe, scenario 27's curl recorder (a
#     drop-in RASPUTIN_KCHOOK_CURL for one start, which copies its own argv
#     from /proc and execs /usr/bin/curl), and scenario 25's bad setting;
#   * `mount --make-rshared /`, which a booted image gets from systemd's
#     mount-setup and a container does not.
#
# NOT COVERED: sign-in flows under
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
ID_REL=usr/lib/rasputin/identity
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
for f in "$SYSD/$KC" "$SYSD/$DB" "$OVERLAY/$HOOK_REL" "$OVERLAY/etc/rasputin/identity/keycloak.conf" \
	"$OVERLAY/etc/rasputin/identity/postgresql.conf" "$OVERLAY/etc/rasputin/identity/pg_hba.conf" "$ROOT/board/rasputin/common/post-build.sh" "$OVERLAY/usr/lib/rasputin/outcome/outcome.sh" \
	"$OVERLAY/$ID_REL/armed.sh" "$OVERLAY/$ID_REL/identity-db-init-gate.sh" "$OVERLAY/$ID_REL/identity-db-init.sh" \
	"$OVERLAY/$ID_REL/identity-stage-import.sh" "$OVERLAY/$ID_REL/rasputin-keycloak-recover-admin.sh" \
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
. "$ROOT/test/lib/listen-sockets.sh"
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
for f in keycloak-build.conf realm-baseline.json; do
	[ -f "$API_DIR/$f" ] || { echo "FAILED: api $API_VERSION's identity/ has no $f."; exit 1; }
done

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

mkdir -p "$SCRATCH/conf"
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
	&& docker cp "$API_DIR/keycloak-build.conf" "$CID:/harness/keycloak-build.conf" >/dev/null \
	&& docker cp "$API_DIR/realm-baseline.json" "$CID:/harness/realm-baseline.json" >/dev/null; }; then
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
# Identity 2.7's gate, init and stage steps and armed.sh, and Identity 2.9's
# recovery launcher, verbatim.
install -m 0644 /overlay/$ID_REL/armed.sh /$ID_REL/armed.sh
for s in identity-db-init-gate.sh identity-db-init.sh identity-stage-import.sh rasputin-keycloak-recover-admin.sh; do
	install -m 0755 /overlay/$ID_REL/\$s /$ID_REL/\$s
done
# The realm baseline where the api package installs it.
install -D -m 0644 /harness/realm-baseline.json /usr/share/rasputin/identity/realm-baseline.json
install -D -m 0755 /overlay/usr/lib/rasputin/atrest/rasputin-atrest-audit.sh /usr/lib/rasputin/atrest/audit.sh
install -m 0755 /harness/curl-recorder /usr/local/bin/curl-recorder
# TEST HARNESS: the empty jssecacerts the image's JRE ships, by
# temurin-jre.mk's own recipe (TEMURIN_JRE_INSTALL_EMPTY_JSSECACERTS): one
# throwaway entry added, deleted, and the listing required to show none.
J='-storetype PKCS12 -storepass changeit -keystore /usr/lib/temurin-jre/lib/security/jssecacerts'
rm -f /usr/lib/temurin-jre/lib/security/jssecacerts
/usr/lib/temurin-jre/bin/keytool -genkeypair -alias temurin-jre-empty -keyalg EC -groupname secp256r1 -dname CN=empty -keypass changeit \$J >/dev/null 2>&1
/usr/lib/temurin-jre/bin/keytool -delete -alias temurin-jre-empty \$J >/dev/null 2>&1
/usr/lib/temurin-jre/bin/keytool -list \$J 2>/dev/null | grep -qx 'Your keystore contains 0 entries'
# TEST HARNESS: in a privileged container /dev/kmsg is the host's.
mkdir -p /etc/systemd/system/$KC.d
printf '[Service]\nEnvironment=RASPUTIN_KCHOOK_KMSG=/run/kchook-console\nEnvironment=RASPUTIN_KCSTAGE_KMSG=/run/kcstage-console\n' >/etc/systemd/system/$KC.d/harness-console.conf
mkdir -p /etc/systemd/system/$DB.d
printf '[Service]\nEnvironment=RASPUTIN_IDDBGATE_KMSG=/run/iddbgate-console\n' >/etc/systemd/system/$DB.d/harness-console.conf
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
# put_confs — the overlay's three identity configs, verbatim (TC-974-13).
put_confs() {
	inside "install -D -m 0644 /overlay/etc/rasputin/identity/keycloak.conf /etc/rasputin/identity/keycloak.conf &&
		install -m 0644 /overlay/etc/rasputin/identity/postgresql.conf /etc/rasputin/identity/postgresql.conf &&
		install -m 0644 /overlay/etc/rasputin/identity/pg_hba.conf /etc/rasputin/identity/pg_hba.conf"
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
echo "28. enabled by post-build.sh's links, the shipped configs, the api's sequence (TC-974-13, TC-974-14, F-973-12)"
{ put_role && put_ca && put_mesh && put_leaves && put_confs; } || { echo "FAILED: the credential sources and the configs could not be written."; exit 1; }
# Copied out and compared on this side: the harness image has no cmp.
for f in keycloak.conf postgresql.conf pg_hba.conf; do
	docker cp "$CID:/etc/rasputin/identity/$f" "$SCRATCH/installed-$f" >/dev/null 2>&1
	check "TC-974-13 the installed $f is byte-identical to the overlay's (cmp)" \
		"$(yes_if cmp -s "$OVERLAY/etc/rasputin/identity/$f" "$SCRATCH/installed-$f")"
done
# post-build.sh's own two link lines, run in the container with TARGET_DIR=/.
LINKS=$(grep -v '^[[:space:]]*#' "$ROOT/board/rasputin/common/post-build.sh" | grep -E 'multi-user\.target\.wants/keycloak(-db)?\.service"$')
check "TC-974-14 post-build.sh has the two identity link lines" "$(yes_if [ "$(printf '%s\n' "$LINKS" | grep -c .)" = 2 ])" "$LINKS"
inside "TARGET_DIR=/
$LINKS
systemctl daemon-reload" || check "TC-974-14 the link lines and daemon-reload ran" 1
for u in $KC $DB; do
	check "TC-974-14 $u is enabled by the link (got $(inside "systemctl is-enabled $u"))" "$(yes_if [ "$(inside "systemctl is-enabled $u")" = enabled ])"
done
c=$(cursor)
# Each call's exit status and its stderr, kept apart.
out=$(inside "rc=''; for c in 'reset-failed $DB $KC' 'restart $DB' 'reset-failed $DB $KC' 'restart $KC'; do
		systemctl \$c 2>>/tmp/api-seq.err; rc=\"\$rc \$?\"; done; echo \$rc")
err=$(inside 'cat /tmp/api-seq.err')
printf '    statuses:%s\n' "$out"
printf '%s\n' "$err" | sed 's/^/    /'
check "TC-974-14 each of the api's four calls exits 0 (statuses:$out)" "$(yes_if [ "$(echo $out)" = "0 0 0 0" ])" "$err"
active_kc
for u in $KC $DB; do
	check "TC-974-14 $u reaches active (got $(show "$u" ActiveState))" "$(yes_if [ "$(show "$u" ActiveState)" = active ])" \
		"$(inside "systemctl show $u -p ActiveState -p SubState -p Result; journalctl --after-cursor='$c' -u $u --no-pager -o cat | tail -20")"
done
drift=$(inside "journalctl --after-cursor='$c' -u $KC --no-pager -o cat | grep -i 'build time options have values that differ'" || true)
check "TC-974-13 Keycloak's journal has no build-option drift line on the shipped keycloak.conf" "$(yes_if [ -z "$drift" ])" "$drift"
reset

echo
echo "15. each input removed in turn: skipped, not failed (TC-973-15)"
put_confs || { echo "FAILED: the harness configs could not be written."; exit 1; }
# No harness initdb: the first start below (scenario 16) creates the database
# through Identity 2.7's gate and init step, as on a node.
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

# --- Identity 2.7: first boot (geekdojo/geekdojo-brain#975) -------------------
IDB=$V/identity-db
IDREC_DIR=/run/rasputin-identity-db-init
IDREC=$IDREC_DIR/outcome
STAGED=$V/keycloak/data/import/realm-baseline.json
BASELINE=/usr/share/rasputin/identity/realm-baseline.json
# psql_kc SQL — SQL as keycloak over mutual TLS with the db-client leaf, as
# Keycloak connects. SQL holds no double quote and no $.
psql_kc() {
	inside "psql 'host=127.0.0.1 port=5432 dbname=keycloak user=keycloak sslmode=verify-full sslrootcert=$V/trust/identity-ca.pem sslcert=$V/tls/identity-db-client/leaf.pem sslkey=$V/tls/identity-db-client/leaf.key' -Atc \"$1\" 2>&1"
}
realm_id() { psql_kc "SELECT id FROM realm WHERE name = 'rasputin'"; }
realm_count() { psql_kc "SELECT count(*) FROM realm WHERE name = 'rasputin'"; }
rec_outcome() { inside "sed -n 's/^outcome=//p' $IDREC 2>/dev/null"; }
# new_boot — both units stopped and reset, the hooks' state and the outcome
# record cleared, and tmpfiles run again (TEST HARNESS: stands in for a boot).
new_boot() {
	reset
	inside "rm -rf $IDREC_DIR; systemd-tmpfiles --create /usr/lib/tmpfiles.d/rasputin.conf >/dev/null 2>&1; true"
}
start_kc() { inside "systemctl start $KC" >/dev/null 2>&1; active_kc; }
# import_done CURSOR — wait for Keycloak's own line, after CURSOR, that realm
# rasputin was imported or already existed, and print which. On a fresh
# database Keycloak creates its schema and the master realm and runs the
# import after /health/started answers UP (measured here at 26.8.2), so
# `active` alone does not mean the import has run.
import_done() {
	wait_for "Keycloak logged realm rasputin imported or already existing" \
		"journalctl --after-cursor='$1' -u $KC -o cat --no-pager | grep -qE \"Realm 'rasputin' (imported|already exists)\"" || return 1
	inside "journalctl --after-cursor='$1' -u $KC -o cat --no-pager | grep -oE \"Realm 'rasputin' (imported|already exists)\" | tail -n 1"
}
boot=$(inside 'cat /proc/sys/kernel/random/boot_id')

echo
echo "29. the first start creates the database once (TC-975-01, TC-975-05)"
new_boot
inside "rm -rf $IDB/data $IDB/data.init $V/keycloak/data/import; systemd-tmpfiles --create /usr/lib/tmpfiles.d/rasputin.conf >/dev/null 2>&1; true"
check "TC-975-01 given: tmpfiles' empty data directory, 0700 992:992, no armed, no record" \
	"$(yes_if inside "[ -d $IDB/data ] && [ -z \"\$(ls -A $IDB/data)\" ] && [ \"\$(stat -c '%a %u:%g' $IDB/data)\" = '700 992:992' ] && [ ! -e $V/identity/armed ] && [ ! -e $IDREC_DIR ]")"
c=$(cursor)
start_kc
check "TC-975-01 $KC is active" "$(yes_if [ "$(show $KC ActiveState)" = active ])" \
	"$(inside "journalctl --after-cursor='$c' -u $KC -u $DB --no-pager -o cat | tail -40")"
rec=$(inside "cat $IDREC")
check "TC-975-01 the record is exactly outcome=created, this boot's id and a reason" \
	"$({ [ "$(printf '%s\n' "$rec" | sed -n '1p;2p')" = "outcome=created
boot_id=$boot" ] && [ "$(printf '%s\n' "$rec" | grep -c .)" = 3 ] && printf '%s\n' "$rec" | sed -n 3p | grep -q '^reason=The .*\.$'; } && echo 0 || echo 1)" "$rec"
modes=$(inside "stat -c '%a %U' $IDREC $IDREC_DIR | tr '\n' ' '")
check "TC-975-01 the record is 0600 root in a 0700 root directory (got '$modes')" "$(yes_if [ "$modes" = "600 root 700 root " ])"
imp=$(import_done "$c")
check "TC-975-01 Keycloak imported realm rasputin on this start (got '$imp')" "$(yes_if [ "$imp" = "Realm 'rasputin' imported" ])"
n=$(inside "journalctl --after-cursor='$c' -u $DB -p 6..6 -o cat --no-pager | grep -c '^identity-db-init-gate: outcome=created reason=\"'")
check "TC-975-01 the journal holds one <6> identity-db-init-gate outcome=created line (got $n)" "$(yes_if [ "$n" = 1 ])"
check "TC-975-01 data holds the cluster; data.init and the pending marker are gone" \
	"$(yes_if inside "[ -f $IDB/data/PG_VERSION ] && [ ! -e $IDB/data.init ] && [ ! -e $IDREC_DIR/pending ]")" "$(inside "ls -A $IDB $IDB/data $IDREC_DIR")"
n=$(realm_count)
check "TC-975-01 realm rasputin exists exactly once (got '$n')" "$(yes_if [ "$n" = 1 ])"
n=$(psql_kc "SELECT count(*) FROM user_entity u JOIN realm r ON r.id = u.realm_id WHERE r.name = 'master'")
check "TC-975-01 master holds no user, no bootstrap administrator or service account (got '$n')" "$(yes_if [ "$n" = 0 ])"
out=$(psql_kc "SELECT datlocprovider FROM pg_database WHERE datname = 'keycloak'")
check "TC-975-05 datlocprovider is b (got '$out')" "$(yes_if [ "$out" = b ])"
out=$(psql_kc "SHOW data_checksums")
check "TC-975-05 data_checksums is on (got '$out')" "$(yes_if [ "$out" = on ])"
RID=$(realm_id)
echo "    realm rasputin id: $RID"
[ -n "$RID" ] || { echo "FAILED: realm rasputin has no id, so the later id checks would compare nothing."; exit 1; }

echo
echo "30. a same-boot restart of the database keeps created (TC-975-07)"
# The database system identifier is set by initdb and nothing else, so an
# unchanged identifier and PG_VERSION mtime mean no second initdb.
sysid() { inside "pg_controldata $IDB/data | sed -n 's/^Database system identifier: *//p'"; }
before="$(inside "stat -c %Y $IDB/data/PG_VERSION") $(sysid)"
inside "systemctl restart $DB" >/dev/null 2>&1
active_kc
after="$(inside "stat -c %Y $IDB/data/PG_VERSION") $(sysid)"
check "TC-975-07 the record still reads outcome=created" "$(yes_if [ "$(rec_outcome)" = created ])" "$(inside "cat $IDREC")"
check "TC-975-07 no second initdb: PG_VERSION mtime and system identifier unchanged ($before / $after)" \
	"$({ [ -n "${before#* }" ] && [ "$before" = "$after" ]; } && echo 0 || echo 1)"
check "TC-975-07 realm rasputin's id is unchanged" "$(yes_if [ "$(realm_id)" = "$RID" ])"

echo
echo "31. data present, not armed, after a new boot: untouched (TC-975-02)"
new_boot
c=$(cursor)
start_kc
imp=$(import_done "$c")
check "TC-975-02 Keycloak skipped the import: realm rasputin already exists (got '$imp')" "$(yes_if [ "$imp" = "Realm 'rasputin' already exists" ])"
check "TC-975-02 the record reads outcome=untouched" "$(yes_if [ "$(rec_outcome)" = untouched ])" "$(inside "cat $IDREC")"
st=$(inside "stat -c '%a %u:%g' $STAGED")
check "TC-975-02 the baseline is staged at 0600 991:991 (got '$st')" "$(yes_if [ "$st" = '600 991:991' ])"
check "TC-975-02 the staged file is byte-equal to the shipped baseline" "$(yes_if inside "[ \"\$(sha256sum <$BASELINE)\" = \"\$(sha256sum <$STAGED)\" ]")"
check "TC-975-02 realm rasputin's id is unchanged and it exists once (the import was skipped)" \
	"$({ [ "$(realm_id)" = "$RID" ] && [ "$(realm_count)" = 1 ]; } && echo 0 || echo 1)"

echo
echo "32. armed with data present: the staged baseline is removed (TC-975-04)"
inside "install -m 0600 /dev/null $V/identity/armed"
check "TC-975-04 given: a staged baseline from the start before" "$(yes_if inside "[ -f $STAGED ]")"
inside "systemctl stop $KC $DB" >/dev/null 2>&1
start_kc
out=$(rec_outcome)
check "TC-975-04 the record reads untouched (got '$out')" "$(yes_if [ "$out" = untouched ])"
check "TC-975-04 the staged baseline is gone" "$(yes_if inside "[ ! -e $STAGED ]")" "$(inside "ls -A $V/keycloak/data/import")"
check "TC-975-04 $KC is active and realm rasputin's id is unchanged" \
	"$({ [ "$(show $KC ActiveState)" = active ] && [ "$(realm_id)" = "$RID" ]; } && echo 0 || echo 1)"

echo
echo "33. armed with the data emptied: refused, held stopped (TC-975-03)"
inside "systemctl stop $KC $DB; find $IDB/data -mindepth 1 -delete" >/dev/null 2>&1
c=$(cursor)
inside "systemctl start $KC" >/dev/null 2>&1
wait_for "$DB is failed with no job left" "[ \"\$(systemctl show -P ActiveState $DB)\" = failed ] && [ -z \"\$(systemctl show -P Job $DB)\" ] && [ -z \"\$(systemctl show -P Job $KC)\" ]"
# held — the TC-975-03 facts, read now.
held() {
	rec=$(inside "cat $IDREC")
	check "TC-975-03 $1: the record reads outcome=refused with this boot's id" \
		"$(yes_if [ "$(printf '%s\n' "$rec" | sed -n '1p;2p')" = "outcome=refused
boot_id=$boot" ])" "$rec"
	check "TC-975-03 $1: $DB is failed (got $(show $DB ActiveState))" "$(yes_if [ "$(show $DB ActiveState)" = failed ])"
	check "TC-975-03 $1: data is still empty, no data.init, no postmaster.pid" \
		"$(yes_if inside "[ -z \"\$(ls -A $IDB/data)\" ] && [ ! -e $IDB/data.init ]")" "$(inside "ls -A $IDB $IDB/data")"
	check "TC-975-03 $1: postgres never started under the unit" \
		"$(yes_if inside "! journalctl --after-cursor='$c' -u $DB -o cat --no-pager | grep -q 'starting PostgreSQL'")"
	check "TC-975-03 $1: $KC is not active (got $(show $KC ActiveState))" "$(yes_if [ "$(show $KC ActiveState)" != active ])"
}
held "after the start"
n=$(inside "journalctl --after-cursor='$c' -u $DB -p 2..2 -o cat --no-pager | grep -c '^identity-db-init-gate: outcome=refused reason='")
check "TC-975-03 a <2> identity-db-init-gate outcome=refused line is in the journal (got $n)" "$(yes_if [ "$n" -ge 1 ])"
# The api's sequence on a new leaf.
inside "systemctl reset-failed $KC $DB; systemctl restart $DB; systemctl restart $KC" >/dev/null 2>&1
settled "$DB"; settled "$KC"
wait_for "$DB is failed with no job left" "[ \"\$(systemctl show -P ActiveState $DB)\" = failed ] && [ -z \"\$(systemctl show -P Job $DB)\" ]"
held "after the api's reset-failed and restarts"
inside "rm -f $V/identity/armed"

echo
echo "34. the reboot points of a first start re-run on their own facts (TC-975-06)"
# run_case LABEL WANT — a new boot, then the pair started: the record reads
# WANT, the cluster is complete, Keycloak is active with one realm rasputin.
run_case() {
	inside "rm -rf $IDREC_DIR"
	inside "systemctl reset-failed $KC $DB" >/dev/null 2>&1
	_c=$(cursor)
	start_kc
	import_done "$_c" >/dev/null
	check "TC-975-06 $1: the record reads $2 (got '$(rec_outcome)')" "$(yes_if [ "$(rec_outcome)" = "$2" ])"
	check "TC-975-06 $1: the cluster is complete, no data.init" \
		"$(yes_if inside "[ -f $IDB/data/PG_VERSION ] && [ -f $IDB/data/global/pg_control ] && [ ! -e $IDB/data.init ]")" "$(inside "ls -A $IDB $IDB/data")"
	check "TC-975-06 $1: $KC is active with exactly one realm rasputin" \
		"$({ [ "$(show $KC ActiveState)" = active ] && [ "$(realm_count)" = 1 ]; } && echo 0 || echo 1)"
}
# (a) empty data, a partial data.init: initdb stopped part-way.
reset
inside "find $IDB/data -mindepth 1 -delete; rm -rf $IDB/data.init; install -d -m 0700 -o 992 -g 992 $IDB/data.init $IDB/data.init/base
	echo 18 >$IDB/data.init/PG_VERSION; touch $IDB/data.init/base/partial; chown -R 992:992 $IDB/data.init"
run_case "(a) empty data, partial data.init" created
# (b) data absent, a complete data.init: the reboot fell between rmdir and mv.
reset
inside "mv $IDB/data $IDB/data.init"
run_case "(b) data absent, complete data.init" created
# (c) complete data.
reset
run_case "(c) complete data" untouched
reset

# --- Identity 2.6: the shipped configuration (geekdojo/geekdojo-brain#974) -----
start_kc
check "the pair is active for scenarios 35 to 38" "$(yes_if [ "$(show $KC ActiveState)" = active ])"
# listeners_of UID — the LISTEN rows UID owns in the container's tables,
# sorted, space-separated (test/lib/listen-sockets.sh).
listeners_of() { inside "cat /proc/net/tcp /proc/net/tcp6" | listening_sockets_of_uids "$1" | sort | tr '\n' ' ' | sed 's/ $//'; }

echo
echo "35. the WAL settings and TLS-only PostgreSQL (TC-974-15)"
for kv in wal_level=minimal max_wal_senders=0 min_wal_size=32MB; do
	got=$(psql_kc "SHOW ${kv%%=*}")
	check "TC-974-15 SHOW ${kv%%=*} over the cert connection is ${kv#*=} (got '$got')" "$(yes_if [ "$got" = "${kv#*=}" ])"
done
# SHOW ssl_min_protocol_version as keycloak is refused for want of
# pg_read_all_settings (F-974-06), so postgres -C reads the shipped config.
got=$(inside "setpriv --reuid=992 --regid=992 --clear-groups /usr/bin/postgres -C ssl_min_protocol_version -D $IDB/data -c config_file=/etc/rasputin/identity/postgresql.conf 2>&1")
check "TC-974-15 postgres -C ssl_min_protocol_version on the shipped config is TLSv1.3 (got '$got')" "$(yes_if [ "$got" = TLSv1.3 ])"
out=$(inside "psql 'host=127.0.0.1 port=5432 dbname=keycloak user=keycloak sslmode=verify-full sslrootcert=$V/trust/identity-ca.pem sslcert=$V/tls/identity-db-client/leaf.pem sslkey=$V/tls/identity-db-client/leaf.key ssl_max_protocol_version=TLSv1.2' -Atc 'SELECT 1' 2>&1; echo rc=\$?")
check "TC-974-15 a client capped at TLS 1.2, with the db-client leaf, is refused in the handshake" \
	"$({ ! contains 'rc=0' "$out" && contains 'protocol version' "$out"; } && echo 0 || echo 1)" "$out"
printf '    %s\n' "$out" | head -2
got=$(listeners_of 992)
check "TC-974-15 the only LISTEN row uid 992 owns is 127.0.0.1:5432 (got '$got')" "$(yes_if [ "$got" = 127.0.0.1:5432 ])"
n=$(inside "grep -c '\.s\.PGSQL\.' /proc/net/unix")
check "TC-974-15 /proc/net/unix holds no .s.PGSQL. path (got $n)" "$(yes_if [ "$n" = 0 ])"

echo
echo "36. Keycloak listens on 8543 and 8544 only (TC-974-16, K-P3 cache=local)"
got=$(listeners_of 991)
check "TC-974-16 at ready, the LISTEN rows uid 991 owns are exactly 127.0.0.1:8543 and :8544 (got '$got')" \
	"$(yes_if [ "$got" = "127.0.0.1:8543 127.0.0.1:8544" ])"
inside "systemctl restart $KC" >/dev/null 2>&1
active_kc
got=$(listeners_of 991)
check "TC-974-16 after one restart, exactly 127.0.0.1:8543 and :8544 again (got '$got')" \
	"$(yes_if [ "$got" = "127.0.0.1:8543 127.0.0.1:8544" ])"

echo
echo "37. the outbound truststore is the mesh CA alone (TC-974-17)"
# keycloakchangeit is Keycloak's own public dummy password for this store
# (TruststoreBuilder.DUMMY_PASSWORD); it protects public certificates.
list=$(inside "/usr/lib/temurin-jre/bin/keytool -list -storetype PKCS12 -storepass keycloakchangeit -keystore $V/keycloak/data/keycloak-truststore.p12 2>&1")
printf '%s\n' "$list" | sed 's/^/    /'
check "TC-974-17 the written truststore holds exactly one entry" "$(yes_if contains 'Your keystore contains 1 entry' "$list")" "$list"
fp_store=$(printf '%s\n' "$list" | sed -n 's/.*(SHA-256): //p' | tr -d ' \r' | tr 'a-f' 'A-F')
fp_mesh=$(inside "openssl x509 -in /pki/mesh-ca.pem -noout -fingerprint -sha256" | sed 's/.*=//' | tr -d ' \r' | tr 'a-f' 'A-F')
check "TC-974-17 its SHA-256 fingerprint ($fp_store) is mesh-ca.pem's ($fp_mesh)" \
	"$({ [ -n "$fp_mesh" ] && [ "$fp_store" = "$fp_mesh" ]; } && echo 0 || echo 1)"

echo
echo "38. pgjdbc on the PKCS-8 key, over TLS 1.3 (TC-974-18)"
rows=$(psql_kc "SELECT s.ssl, s.version, s.client_dn FROM pg_stat_ssl s JOIN pg_stat_activity a ON a.pid = s.pid WHERE a.application_name = 'PostgreSQL JDBC Driver'")
printf '%s\n' "$rows" | sed 's/^/    /'
n=$(printf '%s\n' "$rows" | grep -c .)
bad=$(printf '%s\n' "$rows" | grep . | grep -vxF 't|TLSv1.3|/CN=keycloak' || true)
check "TC-974-18 every PostgreSQL JDBC Driver backend ($n) is ssl=t, TLSv1.3, client_dn=/CN=keycloak" \
	"$({ [ "$n" -gt 0 ] && [ -z "$bad" ]; } && echo 0 || echo 1)" "$rows"
reset

# --- Identity 2.9: admin recovery on the appliance (geekdojo/geekdojo-brain#1131)
RECOVER=/$ID_REL/rasputin-keycloak-recover-admin.sh
RUNIT=rasputin-keycloak-recover-admin.service
TLSARGS="--tlsv1.3 --max-time 30 --cacert $V/trust/identity-ca.pem --cert $V/tls/identity-db-client/leaf.pem --key $V/tls/identity-db-client/leaf.key"
absent() { ! contains "$1" "$2"; }
# new_secret — a synthetic client secret, made on this side.
new_secret() { printf 'tc1131-%s' "$(openssl rand -hex 24)"; }
# recover_bg SECRET CLIENT TAG — the launcher as the api runs it: as root,
# with exactly PATH in its environment, `run CLIENT`, and SECRET and a newline
# on stdin. The secret is piped in from this side, so no process in the
# container carries it on argv. In the background: its status lands in
# /tmp/TAG.rc, its stdout and stderr in /tmp/TAG.out and /tmp/TAG.err.
recover_bg() {
	printf '%s\n' "$1" | docker exec -i "$CID" sh -c \
		"env -i PATH=/usr/bin:/bin $RECOVER run $2 >/tmp/$3.out 2>/tmp/$3.err; echo \$? >/tmp/$3.rc" &
	RECOVER_PID=$!
}
# recover_done TAG — wait for the run's status; sets RC and OUT (its stdout
# and stderr).
recover_done() {
	wait_for "the recovery run $1 has finished" "[ -s /tmp/$1.rc ]"
	wait "$RECOVER_PID"
	RC=$(inside "cat /tmp/$1.rc")
	OUT=$(inside "cat /tmp/$1.out /tmp/$1.err")
}
# no_foreign_files LABEL — nothing under the identity data directory is owned
# by anyone but 991:991.
no_foreign_files() {
	_f=$(inside "find $V/keycloak ! -user 991 -o ! -group 991")
	check "$1: every file under $V/keycloak is owned by 991:991" "$(yes_if [ -z "$_f" ])" "$_f"
}
collected() {
	wait_for "$RUNIT is collected" "[ \"\$(systemctl show -P LoadState $RUNIT)\" = not-found ]"
	check "$1: $RUNIT is no longer loaded (got $(show $RUNIT LoadState))" "$(yes_if [ "$(show $RUNIT LoadState)" = not-found ])"
}
# kc_up LABEL — keycloak.service started: active, and /health/started UP.
# Then the wait for Keycloak's realm import line, as scenario 34 waits: with
# the baseline staged, the import runs after /health/started answers UP, and
# the HTTPS listener answers 503 until it has.
kc_up() {
	_c=$(cursor)
	inside "systemctl start $KC" >/dev/null 2>&1
	active_kc
	import_done "$_c" >/dev/null
	_h=$(inside "curl -sS $TLSARGS https://127.0.0.1:8544/health/started")
	check "$1: $KC is active and /health/started answers UP" \
		"$({ [ "$(show $KC ActiveState)" = active ] && contains '"UP"' "$_h"; } && echo 0 || echo 1)" "$(show $KC ActiveState) $_h"
}
# admin_works LABEL CLIENT SECRET — over mutual TLS, CLIENT gets a
# client_credentials token in realm master with SECRET, and with it
# GET /admin/realms/rasputin answers 200. SECRET and the token reach curl on
# stdin, never argv.
admin_works() {
	_t=$(printf 'grant_type=client_credentials&client_id=%s&client_secret=%s' "$2" "$3" \
		| docker exec -i "$CID" sh -c "curl -sS $TLSARGS --data-binary @- -H 'Content-Type: application/x-www-form-urlencoded' -w '\n%{http_code}' https://127.0.0.1:8543/realms/master/protocol/openid-connect/token")
	_tok=$(printf '%s\n' "$_t" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
	check "$1: client $2 gets a client_credentials token in realm master" "$(yes_if [ -n "$_tok" ])" \
		"HTTP $(printf '%s\n' "$_t" | tail -n 1)"
	_r=$(printf 'Authorization: Bearer %s\n' "$_tok" \
		| docker exec -i "$CID" sh -c "curl -sS $TLSARGS -H @- -w '\n%{http_code}' https://127.0.0.1:8543/admin/realms/rasputin")
	check "$1: with it GET /admin/realms/rasputin answers 200 with realm rasputin" \
		"$({ [ "$(printf '%s\n' "$_r" | tail -n 1)" = 200 ] && contains '"realm":"rasputin"' "$_r"; } && echo 0 || echo 1)" \
		"$(printf '%s\n' "$_r" | tail -n 1)"
}

echo
echo "39. the admin recovery runs as 991 in keycloak.service's sandbox (TC-1131-12, TC-1131-13)"
inside "systemctl start $DB" >/dev/null 2>&1
wait_for "$DB is active" "[ \"\$(systemctl show -P ActiveState $DB)\" = active ]" || exit 1
check "TC-1131-12 given: $KC is not active and $DB is (got $(show $KC ActiveState)/$(show $DB ActiveState))" \
	"$(yes_if [ "$(show $KC ActiveState)/$(show $DB ActiveState)" = inactive/active ])"
S39=$(new_secret)
recover_bg "$S39" rasputin-recover-tc39 r39
# Read while the run is in progress (F-1131-04): the fact waited on is the
# unit's main process and its JVM, a java process of uid 991 in its cgroup.
wait_for "$RUNIT has a main process and a java process of uid 991 in its cgroup" \
	"[ \"\$(systemctl show -P MainPID $RUNIT)\" != 0 ] && p=\$(pgrep -u 991 -x java) && grep -q '/$RUNIT\$' /proc/\$p/cgroup"
for prop in User Group LoadCredential Environment ProtectSystem ReadWritePaths PrivateTmp PrivateDevices NoNewPrivileges \
	CapabilityBoundingSet RestrictAddressFamilies IPAddressDeny IPAddressAllow MemoryMax OOMScoreAdjust; do
	want=$(inside "systemctl show -p $prop $KC")
	got=$(inside "systemctl show -p $prop $RUNIT")
	check "TC-1131-12 during the run, $RUNIT's $prop equals $KC's" "$({ [ -n "$want" ] && [ "$got" = "$want" ]; } && echo 0 || echo 1)" \
		"$KC: $want | $RUNIT: $got"
done
jpid=$(inside "pgrep -u 991 -x java")
st=$(inside "grep -E '^(Uid|CapEff|NoNewPrivs):' /proc/$jpid/status | tr -s '\t' ' '")
check "TC-1131-12 during the run, the JVM (pid $jpid) is uid 991 with CapEff 0 and NoNewPrivs 1" \
	"$(yes_if [ "$st" = "Uid: 991 991 991 991
CapEff: 0000000000000000
NoNewPrivs: 1" ])" "$st"
argvs=$(inside "for f in /proc/[0-9]*/cmdline; do tr '\\0' ' ' <\$f 2>/dev/null; echo; done")
check "TC-1131-12 during the run, the process table was read with the JVM in it (bootstrap-admin in an argv)" \
	"$(yes_if contains bootstrap-admin "$argvs")"
check "TC-1131-12 during the run, the secret is in no /proc/*/cmdline" "$(yes_if absent "$S39" "$argvs")"
tf=$(inside "cat /run/systemd/transient/$RUNIT")
check "TC-1131-12 during the run, /run/systemd/transient/$RUNIT exists and carries User=keycloak" \
	"$(yes_if contains 'User=keycloak' "$tf")" "$tf"
check "TC-1131-12 during the run, the secret is not in /run/systemd/transient/$RUNIT" "$(yes_if absent "$S39" "$tf")"
recover_done r39
check "TC-1131-12 the launcher exits 0 (got $RC)" "$(yes_if [ "$RC" = 0 ])" "$OUT"
collected "TC-1131-12 after the run"
no_foreign_files "TC-1131-13 after the run"
nw=$(inside "find $V/keycloak -type f ! -perm -u+w")
check "TC-1131-13 every regular file under $V/keycloak is writable by its owner" "$(yes_if [ -z "$nw" ])" "$nw"
kc_up "TC-1131-13 after the run"
admin_works "TC-1131-13" rasputin-recover-tc39 "$S39"
check "TC-1131-13 the secret is not in the launcher's stdout or stderr" "$(yes_if absent "$S39" "$OUT")"
check "TC-1131-13 the secret is not in journalctl -b" "$(yes_if absent "$S39" "$(inside 'journalctl -b --no-pager -o cat')")"
files=$(inside "find $V/keycloak /run -type f -exec cat {} + 2>/dev/null")
check "TC-1131-13 the secret is in no file under $V/keycloak or /run" "$(yes_if absent "$S39" "$files")"

echo
echo "40. a failed run leaves no root file and frees the unit name (TC-1131-14, TC-1131-15)"
reset
S40=$(new_secret)
recover_bg "$S40" rasputin-recover-tc40 r40
recover_done r40
printf '%s\n' "$OUT" | grep -iE 'error|fail' | head -5 | sed 's/^/    /'
check "TC-1131-14 with the database stopped the launcher exits non-zero (got $RC)" "$(yes_if [ "$RC" != 0 ])"
check "TC-1131-14 its output carries kc.sh's database failure" \
	"$({ contains 'Connection refused' "$OUT" || contains 'JDBC' "$OUT"; } && echo 0 || echo 1)" "$(printf '%s' "$OUT" | tail -20)"
check "TC-1131-14 its output does not carry the secret" "$(yes_if absent "$S40" "$OUT")"
no_foreign_files "TC-1131-14 after the failed run"
collected "TC-1131-14 after the failed run"
kc_up "TC-1131-14 after the failed run"
inside "systemctl stop $KC"
check "TC-1131-15 given: $KC stopped again and $DB active (got $(show $KC ActiveState)/$(show $DB ActiveState))" \
	"$(yes_if [ "$(show $KC ActiveState)/$(show $DB ActiveState)" = inactive/active ])"
S40B=$(new_secret)
recover_bg "$S40B" rasputin-recover-tc40b r40b
recover_done r40b
check "TC-1131-15 the unit name is reused: a second run exits 0 (got $RC)" "$(yes_if [ "$RC" = 0 ])" "$OUT"
collected "TC-1131-15 after the second run"
kc_up "TC-1131-15 after the second run"
admin_works "TC-1131-15" rasputin-recover-tc40b "$S40B"
reset

echo
if [ "$fails" -eq 0 ]; then
	echo "identity-unit-functional: all checks passed"
else
	echo "identity-unit-functional: $fails check(s) FAILED"
fi
[ "$fails" -eq 0 ]
