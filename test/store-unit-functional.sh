#!/bin/sh
# Functional test for the secrets store's unit, openbao.service, against REAL
# systemd 258.7 as PID 1 (the release Buildroot 2026.08 builds into the image)
# and the REAL pinned bao, downloaded for this machine's architecture and
# checked against package/openbao/openbao.hash (geekdojo/geekdojo-brain#755).
#
# WHY THIS EXISTS. The unit is nothing but systemd configuration around a
# third-party binary, and what matters about it is what systemd and bao do with
# it together: whether bao runs at all as 990:990 with no capabilities inside a
# read-only filesystem, whether LoadCredential= reaches it, whether the
# conditions skip it cleanly, and what a crash loop leaves behind. A static
# test cannot show any of that, and neither can a stub ExecStart.
#
# Scenarios, in one container, in this order:
#   0  the test fails closed: no docker, a failed download and a tarball that
#      does not match openbao.hash each stop it with a sentence (TC-755-08)
#   1  installed, not wanted: real preset-all leaves it static (TC-755-09)
#   2  no role marker: skipped, not failed (TC-755-10)
#   3  first boot, no leaf or no CA: skipped; then a restart starts it
#      (TC-755-11)
#   4  no seal key: fails, never skips (TC-755-12)
#
# The seal key and the seal fragment are NOT harness: the real
# rasputin-seal-key.sh (#803) writes them in the container, against the empty
# store tree tmpfiles makes, so scenario 5's credential and sys/health checks
# run bao on the oneshot's own output under 258.7 (TC-803-24).
#   5  the running store: its user, capabilities, environment, core limit,
#      credentials, writable paths and memory (TC-755-13 to TC-755-16, 18)
#   6  repeated crashes: the start limit, then recovery by reset-failed and
#      start (TC-755-17)
#
# TEST HARNESS, not from the image, and labelled where it is done:
#   * the openbao user, which mkusers creates on the image from OPENBAO_USERS;
#   * the store's main config, which is #756's to bake: a listener on
#     127.0.0.1:8200 naming the credentials, and PebbleDB in the data
#     directory;
#   * a throwaway PKI standing in for the store CA and the server leaf the
#     api mints (#758);
#   * `mount --make-rshared /`. A booted image gets a shared root from systemd
#     itself (mount-setup); a container's root is private, and without this the
#     credentials systemd mounts never reach the service.
#
# NOT COVERED: the image's kernel, squashfs and memory under load (#756's
# smoke, F3.6), the store's real config, init and unseal (#756, #804), the
# api's first-boot handoff (#758), F3.3's alert itself (#760), and the other
# architecture: CI runs this on amd64.
#
# Needs: docker with privileged containers, openssl, GNU make, curl, network
# access to the OpenBao release. Linux runner or Docker Desktop.
# Run:   sh test/store-unit-functional.sh
#
# Every wait below has a deadline and fails naming the fact that never became
# true. The deadlines bound the test; the unit under test chooses none.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
UNIT="$OVERLAY/etc/systemd/system/openbao.service"
TMPFILES="$OVERLAY/usr/lib/tmpfiles.d/rasputin.conf"
PKG="$ROOT/package/openbao"
IMAGE=rasputin-store-unit-functional:f43-systemd-258.7
CTR_DEADLINE="${STORE_UNIT_TEST_DEADLINE:-60}"
V=/var/lib/rasputin
CREDS=/run/credentials/openbao.service
PORT=8200

# --- fail closed (scenario 0 checks this) ------------------------------------
command -v docker >/dev/null 2>&1 || { echo "FAILED: this test needs docker, and docker is not on PATH."; exit 1; }
for t in openssl make curl tar; do
	command -v "$t" >/dev/null 2>&1 || { echo "FAILED: this test needs $t, and it is not on PATH."; exit 1; }
done
for f in "$UNIT" "$TMPFILES" "$PKG/openbao.mk" "$PKG/openbao.hash"; do
	[ -f "$f" ] || { echo "FAILED: the file $f is missing."; exit 1; }
done

. "$ROOT/test/lib/checks.sh"
. "$ROOT/test/lib/mk-var.sh"
. "$ROOT/test/lib/f43-systemd.sh"
. "$ROOT/test/lib/container-systemd.sh"
neither() { ! contains "$1" "$3" && ! contains "$2" "$3"; }

SCRATCH=$(mktemp -d)
cleanup() { ctr_cleanup; rm -rf "$SCRATCH"; }
trap cleanup EXIT INT TERM

# The architecture of the containers docker runs, which is the bao this needs.
case "$(docker info --format '{{.Architecture}}' 2>/dev/null)" in
	aarch64|arm64) BR_ARCH=BR2_aarch64 ;;
	x86_64|amd64) BR_ARCH=BR2_x86_64 ;;
	*) echo "FAILED: docker reports an architecture this test has no OpenBao tarball for: '$(docker info --format '{{.Architecture}}' 2>/dev/null)'."; exit 1 ;;
esac

# The pin, the tarball name and the static user, read the way Buildroot reads
# them. No version, URL or uid is written in this file.
SITE=$(mk_var "$PKG/openbao.mk" OPENBAO_SITE) || exit 1
SOURCE=$(mk_var "$PKG/openbao.mk" OPENBAO_SOURCE BR2_PACKAGE_OPENBAO=y "$BR_ARCH=y") || exit 1
USERS=$(mk_var "$PKG/openbao.mk" OPENBAO_USERS) || exit 1
set -f
# shellcheck disable=SC2086 # the fields of OPENBAO_USERS; -f as field 5 is *
set -- $USERS
set +f
BAO_USER=$1 BAO_UID=$2 BAO_GROUP=$3 BAO_GID=$4

# --- fetch and verify the pinned binary ----------------------------------------
WANT_SHA=$(awk -v s="$SOURCE" '$1 == "sha256" && $3 == s { print $2 }' "$PKG/openbao.hash")
[ -n "$WANT_SHA" ] || { echo "FAILED: openbao.hash has no sha256 line for $SOURCE."; exit 1; }
echo "downloading $SITE/$SOURCE"
curl -fsSL -o "$SCRATCH/$SOURCE" "$SITE/$SOURCE" \
	|| { echo "FAILED: the download of $SITE/$SOURCE failed, so there is no bao to test."; exit 1; }
GOT_SHA=$(openssl dgst -sha256 -r "$SCRATCH/$SOURCE" | cut -d' ' -f1)
[ "$GOT_SHA" = "$WANT_SHA" ] \
	|| { echo "FAILED: $SOURCE does not match openbao.hash (got $GOT_SHA, want $WANT_SHA)."; exit 1; }
echo "  $SOURCE matches openbao.hash"
tar -xzf "$SCRATCH/$SOURCE" -C "$SCRATCH" bao \
	|| { echo "FAILED: $SOURCE has no bao in it."; exit 1; }

echo
echo "0. the test fails closed (TC-755-08)"
SH_BIN=$(command -v sh)
# No docker on PATH: a stub directory holding only dirname, which the script
# needs before it looks for docker.
mkdir -p "$SCRATCH/nodocker"
ln -s "$(command -v dirname)" "$SCRATCH/nodocker/dirname"
out=$(PATH="$SCRATCH/nodocker" "$SH_BIN" "$0" 2>&1); rc=$?
check "with no docker the test exits non-zero" "$(yes_if [ "$rc" -ne 0 ])" "exit=$rc"
check "with no docker the message names docker" "$(yes_if contains 'needs docker' "$out")" "$out"
check "with no docker nothing reports success or a skip" "$(yes_if neither passed skip "$out")" "$out"
# A root that is this tree with the pin's site moved: once to nowhere, once to
# a directory holding a tarball of the right name and the wrong content.
fake_root() {
	_r="$SCRATCH/$1"
	mkdir -p "$_r/test/lib" "$_r/package/openbao" "$_r/board/rasputin/common/rootfs-overlay/etc/systemd/system" \
		"$_r/board/rasputin/common/rootfs-overlay/usr/lib/tmpfiles.d"
	cp "$0" "$_r/test/store-unit-functional.sh"
	cp "$ROOT"/test/lib/*.sh "$_r/test/lib/"
	cp "$UNIT" "$_r/board/rasputin/common/rootfs-overlay/etc/systemd/system/"
	cp "$TMPFILES" "$_r/board/rasputin/common/rootfs-overlay/usr/lib/tmpfiles.d/"
	cp "$PKG/openbao.hash" "$_r/package/openbao/"
	sed "s|^OPENBAO_SITE = .*|OPENBAO_SITE = $2|" "$PKG/openbao.mk" >"$_r/package/openbao/openbao.mk"
	echo "$_r/test/store-unit-functional.sh"
}
out=$("$SH_BIN" "$(fake_root nosite http://127.0.0.1:9)" 2>&1); rc=$?
check "a failed download exits non-zero" "$(yes_if [ "$rc" -ne 0 ])" "exit=$rc"
check "a failed download is named as one" "$(yes_if contains 'the download of' "$out")" "$out"
check "a failed download reports no success or skip" "$(yes_if neither passed skip "$out")" "$out"
mkdir -p "$SCRATCH/badsite"
echo "not the pinned tarball" >"$SCRATCH/badsite/$SOURCE"
out=$("$SH_BIN" "$(fake_root badhash "file://$SCRATCH/badsite")" 2>&1); rc=$?
check "a tarball that does not match openbao.hash exits non-zero" "$(yes_if [ "$rc" -ne 0 ])" "exit=$rc"
check "the mismatch names openbao.hash" "$(yes_if contains 'does not match openbao.hash' "$out")" "$out"
check "a mismatch reports no success or skip" "$(yes_if neither passed skip "$out")" "$out"
# The 258.7 pin refusal is f43_systemd_is_pinned, shown by
# test/store-paths-functional.sh (TC-754-17).

# --- the test PKI (TEST HARNESS: stands in for the CA and leaf the api mints) ---
P="$SCRATCH/pki"
mkdir -p "$P"
printf 'subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\n' >"$P/server.ext"
printf 'extendedKeyUsage=clientAuth\n' >"$P/client.ext"
{
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 \
		-subj /CN=store-unit-test-ca -keyout "$P/ca.key" -out "$P/store-ca.pem" \
		-addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign &&
	for n in server client; do
		openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=store-unit-test-$n" \
			-keyout "$P/$n.key" -out "$P/$n.csr" &&
		openssl x509 -req -in "$P/$n.csr" -CA "$P/store-ca.pem" -CAkey "$P/ca.key" -set_serial "0x$(openssl rand -hex 8)" \
			-days 2 -extfile "$P/$n.ext" -out "$P/$n.pem" || exit 1
	done
} >/dev/null 2>&1 || { echo "FAILED: openssl could not make the test PKI."; exit 1; }

# --- the container ---------------------------------------------------------------
f43_systemd_image "$IMAGE" || exit 1
ctr_boot "the store unit" "$IMAGE" -v "$OVERLAY:/overlay:ro" || exit 1
echo "in the container: $(inside 'systemctl --version | head -1')"
if ! { docker cp "$SCRATCH/bao" "$CID:/usr/bin/bao" >/dev/null && docker cp "$P" "$CID:/pki" >/dev/null; }; then
	echo "FAILED: could not copy bao and the test PKI into the container."; exit 1
fi

inside "
set -e
# TEST HARNESS: a booted image gets a shared root from systemd's mount-setup.
mount --make-rshared /
# TEST HARNESS: mkusers creates this user on the image, from OPENBAO_USERS.
! getent passwd $BAO_UID >/dev/null && ! getent group $BAO_GID >/dev/null
echo '$BAO_GROUP:x:$BAO_GID:' >>/etc/group
echo '$BAO_USER:x:$BAO_UID:$BAO_GID::/:/sbin/nologin' >>/etc/passwd
chown 0:0 /usr/bin/bao && chmod 0755 /usr/bin/bao
# The image's tmpfiles.d creates the persistent tree, as on a node. Lines this
# container cannot satisfy (the console master copy, the baked root CA) are
# not this test's.
mkdir -p $V && chmod 0755 $V
install -D -m 0644 /overlay/usr/lib/tmpfiles.d/rasputin.conf /usr/lib/tmpfiles.d/rasputin.conf
systemd-tmpfiles --create /usr/lib/tmpfiles.d/rasputin.conf >/dev/null 2>&1 || true
# The unit, verbatim.
install -m 0644 /overlay/etc/systemd/system/openbao.service /etc/systemd/system/openbao.service
# TEST HARNESS: the main config #756 bakes.
install -d -m 0755 /etc/rasputin/openbao
cat >/etc/rasputin/openbao/openbao.hcl <<'EOF'
api_addr           = \"https://127.0.0.1:$PORT\"
disable_clustering = true
listener \"tcp\" {
  address                            = \"127.0.0.1:$PORT\"
  tls_cert_file                      = \"$CREDS/server.pem\"
  tls_key_file                       = \"$CREDS/server.key\"
  tls_client_ca_file                 = \"$CREDS/store-ca.pem\"
  tls_require_and_verify_client_cert = true
}
storage \"pebbledb\" {
  path = \"$V/openbao\"
}
EOF
systemctl daemon-reload
" || { echo "FAILED: could not install the unit and the test harness into the container."; exit 1; }

# The seal key and fragment, from the real oneshot (#803, TC-803-24), run as
# root with its production paths. Its kernel-log line goes to /dev/null: in a
# privileged container /dev/kmsg is the host's. A copy of its output is kept
# in /pki, so put_seal below re-installs exactly what the oneshot wrote.
echo
echo "the seal key and fragment, from the real rasputin-seal-key.sh (TC-803-24)"
out=$(inside "RASPUTIN_SEALKEY_KMSG=/dev/null sh /overlay/usr/lib/rasputin/seal-key/rasputin-seal-key.sh; echo rc=\$?" 2>&1)
check "the oneshot exits 0" "$(yes_if contains 'rc=0' "$out")" "$out"
check "the oneshot reports outcome=created" "$(yes_if contains 'rasputin-seal-key: outcome=created' "$out")" "$out"
inside "cp -p $V/openbao-seal/seal-key /pki/seal-key && cp -p $V/openbao-seal/seal.hcl /pki/seal.hcl" \
	|| { echo "FAILED: could not keep a copy of the oneshot's key and fragment."; exit 1; }
ONESHOT_SHA=$(inside "cat $V/openbao-seal/seal-key $V/openbao-seal/seal.hcl | sha256sum")
# seal_is_oneshots LABEL — the installed pair is byte-identical to the oneshot's.
seal_is_oneshots() {
	check "$1: the installed key and fragment are the oneshot's, byte for byte" \
		"$(yes_if [ "$(inside "cat $V/openbao-seal/seal-key $V/openbao-seal/seal.hcl | sha256sum")" = "$ONESHOT_SHA" ])"
}

# The credential sources, written as their writers would (root, 0600 or 0644).
put_seal() { inside "install -m 0600 /pki/seal-key $V/openbao-seal/seal-key && install -m 0600 /pki/seal.hcl $V/openbao-seal/seal.hcl"; }
put_ca() { inside "install -m 0644 /pki/store-ca.pem $V/trust/store-ca.pem"; }
put_leaf() { inside "install -m 0644 /pki/server.pem $V/tls/openbao-server/leaf.pem && install -m 0600 /pki/server.key $V/tls/openbao-server/leaf.key"; }
show() { inside "systemctl show openbao.service -p $1 --value"; }
# as_uid UID COMMAND — COMMAND as UID, its own group, no supplementary groups.
as_uid() { inside "setpriv --reuid=$1 --regid=$1 --clear-groups sh -c '$2'"; }
# --max-time bounds the one I/O call, so a listener that accepts and never
# answers is a failure, not a hang.
health() { inside "curl -sS --max-time $CTR_DEADLINE -o /dev/null -w '%{http_code}' --cacert /pki/store-ca.pem --cert /pki/client.pem --key /pki/client.key https://127.0.0.1:$PORT/v1/sys/health 2>&1"; }
# skipped LABEL — ConditionResult=no, inactive, no MainPID, not failed, no restarts.
skipped() {
	_s="$(show ConditionResult) $(show ActiveState) $(show MainPID) $(show NRestarts)"
	check "$1: ConditionResult=no, inactive, MainPID=0, NRestarts=0 (got '$_s')" "$(yes_if [ "$_s" = "no inactive 0 0" ])"
	_f=$(inside "systemctl --failed --no-legend --plain" | grep openbao || true)
	check "$1: not in systemctl --failed" "$(yes_if [ -z "$_f" ])" "$_f"
}

echo
echo "1. installed, not wanted, under real preset-all (TC-755-09)"
inside "
set -e
for t in shipped control; do
	mkdir -p /tmp/preset-\$t/etc/systemd/system
	cp /overlay/etc/systemd/system/openbao.service /tmp/preset-\$t/etc/systemd/system/
done
printf '\n[Install]\nWantedBy=multi-user.target\n' >>/tmp/preset-control/etc/systemd/system/openbao.service
systemctl --root=/tmp/preset-shipped preset-all >/dev/null 2>&1
systemctl --root=/tmp/preset-control preset-all >/dev/null 2>&1
" || check "preset-all ran on both trees" 1
st=$(inside "systemctl --root=/tmp/preset-shipped is-enabled openbao.service 2>&1")
check "the shipped unit is static after preset-all (got '$st')" "$(yes_if [ "$st" = static ])"
wants=$(inside "find /tmp/preset-shipped -name openbao.service -path '*.wants/*'")
check "preset-all made no .wants link for it" "$(yes_if [ -z "$wants" ])" "$wants"
st=$(inside "systemctl --root=/tmp/preset-control is-enabled openbao.service 2>&1")
check "control: the same unit with [Install] appended comes out enabled (got '$st')" "$(yes_if [ "$st" = enabled ])"

echo
echo "2. no role marker: skipped (TC-755-10)"
if ! { put_seal && put_ca && put_leaf; }; then check "the credential sources are written" 1; fi
seal_is_oneshots "put_seal"
inside "rm -f $V/role.controlplane; systemctl start openbao.service" >/dev/null 2>&1
skipped "no role marker"

echo
echo "3. first boot: no leaf, or no CA, then the restart that starts it (TC-755-11)"
inside "touch $V/role.controlplane" >/dev/null
for case in "A no leaf:rm -f $V/tls/openbao-server/leaf.pem $V/tls/openbao-server/leaf.key:put_leaf" \
	"B no store CA:rm -f $V/trust/store-ca.pem:put_ca"; do
	label=${case%%:*}; rest=${case#*:}; remove=${rest%%:*}; restore=${rest#*:}
	inside "$remove; systemctl start openbao.service" >/dev/null 2>&1
	skipped "case $label"
	$restore
	inside "systemctl restart openbao.service" >/dev/null 2>&1
	st="$(show ActiveState) $(show MainPID)"
	r=1; [ "${st%% *}" = active ] && [ "${st#* }" != 0 ] && r=0
	check "case $label: once written, systemctl restart leaves it active with a MainPID (got '$st')" "$r"
	inside "systemctl stop openbao.service" >/dev/null 2>&1
done

echo
echo "4. no seal key: fails, never skips (TC-755-12)"
inside "rm -f $V/openbao-seal/seal-key; systemctl reset-failed openbao.service 2>/dev/null; systemctl start openbao.service" >/dev/null 2>&1
wait_for "openbao.service is failed after the missing seal key" \
	'[ "$(systemctl show openbao.service -p ActiveState --value)" = failed ]' || fails=$((fails + 1))
st="$(show ConditionResult) $(show ActiveState) $(show Result)"
check "ConditionResult=yes, ActiveState=failed, Result=exit-code (got '$st')" "$(yes_if [ "$st" = "yes failed exit-code" ])"
# systemd 258.7 names the failed step, not the credential, at its default log
# level: "Failed at step CREDENTIALS spawning /usr/bin/bao" and status
# 243/CREDENTIALS.
journal=$(inside "journalctl -u openbao.service --no-pager -o cat" | grep 'Failed at step CREDENTIALS' | head -1)
check "the unit's journal says the credentials could not be set up" "$(yes_if [ -n "$journal" ])" \
	"$(inside "journalctl -u openbao.service --no-pager -o cat | tail -5" | tr '\n' '|')"
[ -n "$journal" ] && printf '         journal: %s\n' "$journal"
exit_status=$(show ExecMainStatus)
# 243 is the spawn step's own status: bao was never executed.
check "the store's start exited 243, systemd's CREDENTIALS status (got '$exit_status')" "$(yes_if [ "$exit_status" = 243 ])"
put_seal
inside "systemctl reset-failed openbao.service" >/dev/null 2>&1

echo
echo "5. the running store (TC-755-13 to TC-755-16, TC-755-18)"
inside "touch /tmp/before-start" >/dev/null
inside "systemctl start openbao.service" >/dev/null 2>&1
st=$(show ActiveState)
check "systemctl start returns with the store active: it waited for READY=1 (got '$st')" "$(yes_if [ "$st" = active ])"
PID=$(show MainPID)
status=$(inside "cat /proc/$PID/status")
field() { printf '%s\n' "$status" | awk -v f="$1:" '$1 == f { $1 = ""; sub(/^ /, ""); print }'; }
echo "  MainPID $PID"
for f in Uid Gid; do
	got=$(field $f)
	check "$f is $BAO_UID in all four slots (got '$got')" "$(yes_if [ "$got" = "$BAO_UID $BAO_UID $BAO_UID $BAO_UID" ])"
done
# systemd sets the groups with initgroups(3), which always lists the user's
# own primary group; nothing beyond it means no supplementary group.
check "no group beyond its own: Groups is exactly $BAO_GID (got '$(field Groups)')" "$(yes_if [ "$(field Groups)" = "$BAO_GID" ])"
for f in CapEff CapBnd CapAmb CapPrm CapInh; do
	check "$f is 0 (got '$(field $f)')" "$(yes_if [ "$(field $f)" = 0000000000000000 ])"
done
check "NoNewPrivs is 1 (got '$(field NoNewPrivs)')" "$(yes_if [ "$(field NoNewPrivs)" = 1 ])"
env_line=$(inside "tr '\\0' '\\n' </proc/$PID/environ | grep '^GOMEMLIMIT='")
check "GOMEMLIMIT=60MiB reaches the store (got '$env_line')" "$(yes_if [ "$env_line" = GOMEMLIMIT=60MiB ])"

core=$(inside "grep 'Max core file size' /proc/$PID/limits")
echo "  $core"
check "core limit is 0 soft and 0 hard (TC-755-14)" \
	"$(yes_if [ "$(printf '%s' "$core" | awk '{ print $5, $6 }')" = "0 0" ])" "$core"

echo "  -- credentials (TC-755-15)"
code=$(health)
check "sys/health over TLS with a client cert from the test CA answers 501, not initialised (got '$code')" \
	"$(yes_if [ "$code" = 501 ])"
n=$(as_uid "$BAO_UID" "wc -c <$CREDS/seal-key")
check "uid $BAO_UID reads the 32-byte seal-key (got '$n' bytes)" "$(yes_if [ "$n" = 32 ])"
for c in seal-key seal.hcl store-ca.pem server.pem server.key; do
	err=$(as_uid 65534 "cat $CREDS/$c >/dev/null" 2>&1) && r=1 || r=0
	check "uid 65534 is refused $c ($err)" "$r"
done
for s in openbao-seal/seal-key openbao-seal/seal.hcl trust/store-ca.pem tls/openbao-server/leaf.pem tls/openbao-server/leaf.key; do
	err=$(as_uid "$BAO_UID" "cat $V/$s >/dev/null" 2>&1) && r=1 || r=0
	check "uid $BAO_UID is refused the root source $s ($err)" "$r"
done

echo "  -- writes, inside the unit's mount namespace (TC-755-16)"
for d in "$V/openbao" "$V/openbao-audit"; do
	err=$(inside "nsenter -t $PID -m setpriv --reuid=$BAO_UID --regid=$BAO_GID --clear-groups touch $d/.store-unit-test" 2>&1) && r=0 || r=1
	check "uid $BAO_UID can create a file in $d" "$r" "$err"
done
for d in "$V" "$V/openbao-seal" "$V/tls" "$V/trust" /etc /usr /var/log /run; do
	err=$(inside "nsenter -t $PID -m setpriv --reuid=$BAO_UID --regid=$BAO_GID --clear-groups touch $d/.store-unit-test" 2>&1) && r=1 || r=0
	check "uid $BAO_UID cannot create a file in $d (${err##*: })" "$r"
done
err=$(inside "nsenter -t $PID -m touch $V/.store-unit-test-root" 2>&1) && r=1 || r=0
contains 'Read-only file system' "$err" || r=1
check "root in the namespace gets EROFS writing $V (${err##*: })" "$r" "$err"

echo "  -- memory (TC-755-18)"
CG=/sys/fs/cgroup$(show ControlGroup)
inside "sync; echo 3 >/proc/sys/vm/drop_caches" >/dev/null 2>&1 || check "drop_caches was written" 1
# Exercise the store so its pages fault back in, charged to its own cgroup.
for _ in 1 2 3 4 5 6 7 8 9 10; do health >/dev/null; done
st=$(show ActiveState)
check "still active after the binary's pages are charged to it (got '$st')" "$(yes_if [ "$st" = active ])"
oom=$(inside "awk '\$1 == \"oom_kill\" { print \$2 }' $CG/memory.events")
check "memory.events oom_kill is 0 (got '$oom')" "$(yes_if [ "$oom" = 0 ])"
mm=$(show MemoryMax)
check "MemoryMax is 134217728 (got '$mm')" "$(yes_if [ "$mm" = 134217728 ])"
for f in memory.max:134217728 memory.high:max memory.swap.max:0; do
	got=$(inside "cat $CG/${f%%:*}" 2>&1)
	check "${f%%:*} is ${f#*:} (got '$got')" "$(yes_if [ "$got" = "${f#*:}" ])"
done
adj=$(inside "cat /proc/$PID/oom_score_adj")
check "oom_score_adj is -999 (got '$adj')" "$(yes_if [ "$adj" = -999 ])"
echo "  memory.peak $(inside "cat $CG/memory.peak" 2>&1) bytes; memory.current $(inside "cat $CG/memory.current" 2>&1) bytes"

inside "systemctl stop openbao.service" >/dev/null 2>&1
gone=$(inside "test -e $CREDS && echo present || echo gone")
check "after stop, $CREDS is gone (got '$gone')" "$(yes_if [ "$gone" = gone ])"
newer=$(inside "find $V \\( -path $V/openbao -o -path $V/openbao-audit \\) -prune -o -newer /tmp/before-start -print")
check "nothing under $V outside its two directories changed while it ran" "$(yes_if [ -z "$newer" ])" "$newer"

echo
echo "6. repeated crashes: the start limit, then recovery (TC-755-17)"
inside "systemctl reset-failed openbao.service 2>/dev/null; systemctl start openbao.service" >/dev/null 2>&1
pid=$(show MainPID)
inside "kill -KILL $pid" >/dev/null 2>&1
if wait_for "after one SIGKILL, a new active MainPID other than $pid" \
	"[ \"\$(systemctl show openbao.service -p ActiveState --value)\" = active ] &&
	 p=\$(systemctl show openbao.service -p MainPID --value) && [ \"\$p\" != 0 ] && [ \"\$p\" != $pid ]"; then
	check "after one SIGKILL of $pid systemd restarts it: active, MainPID $(show MainPID)" 0
else
	check "after one SIGKILL of $pid systemd restarts it" 1 "$(show ActiveState) $(show MainPID)"
fi
# The crash loop is systemd's, not this test's: a seal fragment bao cannot
# parse makes bao exit non-zero on every start, and systemd's own restart
# delay drives each restart. Nothing below waits on the test reaching a step
# inside StartLimitIntervalSec.
inside "systemctl stop openbao.service; systemctl reset-failed openbao.service 2>/dev/null
printf 'seal \"static\" {\n  this is not hcl\n' >$V/openbao-seal/seal.hcl
systemctl start openbao.service" >/dev/null 2>&1
burst=$(show StartLimitBurst)
echo "  StartLimitBurst $burst, StartLimitIntervalUSec $(show StartLimitIntervalUSec), RestartUSec $(show RestartUSec): systemd's defaults"
wait_for "openbao.service is failed with no job, after bao rejects its seal config on every start" \
	'[ "$(systemctl show openbao.service -p ActiveState --value)" = failed ] && [ -z "$(systemctl show openbao.service -p Job --value)" ]' \
	|| fails=$((fails + 1))
st="$(show ActiveState) $(show Result)"
check "the unit is failed and Result keeps the crash's own value, exit-code (got '$st')" "$(yes_if [ "$st" = "failed exit-code" ])"
job=$(inside "systemctl list-jobs --no-legend --plain" | grep openbao || true)
check "no job is queued for it" "$(yes_if [ -z "$job" ])" "$job"
# NRestarts = StartLimitBurst holds here because reset-failed cleared the
# start-limit counter and the loop's first start is the `systemctl start`
# above, inside the window: that start plus StartLimitBurst-1 restarts use up
# the burst, and the restart after them is counted and refused. It is not a
# general rule: a store that ran longer than StartLimitIntervalSec before it
# crashed ends at StartLimitBurst+1 (verifier r1, F-755-08).
nr=$(show NRestarts)
check "NRestarts = StartLimitBurst = $burst, both from systemctl show (got '$nr')" "$(yes_if [ "$nr" = "$burst" ])"
line=$(inside "journalctl -u openbao.service --no-pager -o cat" | grep 'Start request repeated too quickly' | tail -1)
check "the journal says 'Start request repeated too quickly'" "$(yes_if [ -n "$line" ])"
code=$(health)
r=1; { contains 'Could not connect' "$code" || contains 'Connection refused' "$code"; } && r=0
check "sys/health on 127.0.0.1 gets connection refused (got '$code')" "$r"
put_seal
seal_is_oneshots "put_seal after the crash loop"
inside "systemctl reset-failed openbao.service && systemctl start openbao.service" >/dev/null 2>&1
st=$(show ActiveState)
check "with the valid seal.hcl back, reset-failed then start brings it back active (got '$st')" "$(yes_if [ "$st" = active ])"
inside "systemctl stop openbao.service" >/dev/null 2>&1

echo
if [ "$fails" -eq 0 ]; then
	echo "store-unit-functional: all checks passed"
else
	echo "store-unit-functional: $fails check(s) FAILED"
fi
[ "$fails" -eq 0 ]
