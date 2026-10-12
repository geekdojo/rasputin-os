#!/bin/sh
# Functional test for the seal-key oneshot, rasputin-seal-key.service, against
# REAL systemd 258.7 as PID 1 (the release Buildroot 2026.08 builds into the
# image), with the shipped units and one docker volume standing in for the
# persistent partition across four separate containers, one per boot
# (geekdojo/geekdojo-brain#803).
#
# WHY THIS EXISTS. The unit test runs the script. What only systemd can show is
# the arrangement around it: that the oneshot runs at boot with nobody starting
# it, that it finishes before the store and the api start, that a refusal's
# gate file survives the failed unit and stops the api through its
# AssertPathExists=!, that a failure that is not a refusal leaves the api up,
# and that the store receives the very key the oneshot wrote.
#
# Boots, each a new container on the same volume:
#   1  neither key nor data: created at boot, before the store and the api;
#      key 0600 0:0, 32 bytes, delivered to the store (TC-803-19)
#   2  the same volume: untouched, the key unchanged (TC-803-20)
#   3  store data and no key: refused; the data unchanged, the store failed at
#      CREDENTIALS, the api held back by its assertion (TC-803-21)
#   4  no data, no key, a 31-byte random source: failed; the api still starts
#      (TC-803-22)
#   every boot: no key byte in the journal, kernel messages included
#      (TC-803-23)
#
# TEST HARNESS, not from the image, and labelled where it is done:
#   * the store and the api run stand-in ExecStart lines (`sleep infinity`,
#     Type=simple, no watchdog) through drop-ins. Their units are otherwise
#     verbatim, so their ordering, conditions, credentials and assertion are
#     the shipped ones. openbao.service is wanted here; #756 enables it on the
#     image;
#   * a stand-in rasputin-firstboot.service (the api Requires= it), and the role
#     marker, the store CA and the server leaf, which firstboot and the api
#     write on a node, written by the test as placeholder files;
#   * the openbao user, which mkusers creates on the image;
#   * `mount --make-rshared /` early in boot, which a booted image gets from
#     systemd's mount-setup and a container does not;
#   * journald's ReadKMsg=yes, which is journald's default on a node and off in
#     a container;
#   * boot 4's drop-in pointing RASPUTIN_SEALKEY_RANDOM at a 31-byte file.
#
# NOT COVERED: the image's kernel and squashfs, firstboot itself, power-cut
# durability (#763, #771), the store's real config, init and unseal (#756,
# #804), and the other architecture: CI runs this on amd64. The store reading
# the oneshot's key and fragment with the real bao is
# test/store-unit-functional.sh (TC-803-24).
#
# Needs: docker with privileged containers. Linux runner or Docker Desktop.
# Run:   sh test/seal-key-functional.sh
#
# Every wait has a deadline and fails naming the fact that never became true.
# The deadlines bound the test; the units under test choose none.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
UNITS="$OVERLAY/etc/systemd/system"
SCRIPT="$OVERLAY/usr/lib/rasputin/seal-key/rasputin-seal-key.sh"
# The log and record helpers the script sources (geekdojo/geekdojo-brain#804).
OUTCOME_LIB="$OVERLAY/usr/lib/rasputin/outcome/outcome.sh"
TMPFILES="$OVERLAY/usr/lib/tmpfiles.d/rasputin.conf"
BASE=rasputin-seal-key-functional:f43-systemd-258.7
IMAGE=rasputin-seal-key-functional:boot
CTR_DEADLINE="${SEAL_KEY_TEST_DEADLINE:-90}"
V=/var/lib/rasputin
SEAL=$V/openbao-seal
CREDS=/run/credentials/openbao.service
REFUSAL="The secrets store has data but no seal key, so this control plane will not start. A new key cannot open the existing data. Recover by restoring a backup onto a fresh install."

command -v docker >/dev/null 2>&1 || { echo "FAILED: this test needs docker, and docker is not on PATH."; exit 1; }
for f in "$SCRIPT" "$OUTCOME_LIB" "$TMPFILES" "$UNITS/rasputin-seal-key.service" "$UNITS/openbao.service" "$UNITS/rasputin-api.service"; do
	[ -f "$f" ] || { echo "FAILED: the file $f is missing."; exit 1; }
done

. "$ROOT/test/lib/checks.sh"
. "$ROOT/test/lib/f43-systemd.sh"
. "$ROOT/test/lib/container-systemd.sh"

SCRATCH=$(mktemp -d)
VOL="rasputin-seal-key-functional-$$"
cleanup() {
	ctr_cleanup
	docker volume rm -f "$VOL" >/dev/null 2>&1
	docker image rm -f "$IMAGE" >/dev/null 2>&1
	rm -rf "$SCRATCH"
}
trap cleanup EXIT INT TERM

# --- the image: the shipped units and script, plus the labelled harness -------
f43_systemd_image "$BASE" || exit 1
CTX="$SCRATCH/ctx"
mkdir -p "$CTX"
cp "$SCRIPT" "$CTX/rasputin-seal-key.sh"
cp "$OUTCOME_LIB" "$CTX/outcome.sh"
for u in rasputin-seal-key.service openbao.service rasputin-api.service; do
	cp "$UNITS/$u" "$CTX/$u"
done
cp "$TMPFILES" "$CTX/rasputin.conf"
docker build -q -t "$IMAGE" -f - "$CTX" >/dev/null <<DOCKERFILE || { echo "FAILED: the boot image could not be built."; exit 1; }
FROM $BASE
# The shipped files, verbatim.
COPY rasputin-seal-key.sh /usr/lib/rasputin/seal-key/rasputin-seal-key.sh
COPY outcome.sh /usr/lib/rasputin/outcome/outcome.sh
COPY rasputin-seal-key.service openbao.service rasputin-api.service /etc/systemd/system/
COPY rasputin.conf /usr/lib/tmpfiles.d/rasputin.conf
RUN chmod 0755 /usr/lib/rasputin/seal-key/rasputin-seal-key.sh \\
 && mkdir -p /etc/systemd/system/multi-user.target.wants \\
 && ln -s /etc/systemd/system/rasputin-seal-key.service /etc/systemd/system/multi-user.target.wants/ \\
 && ln -s /etc/systemd/system/rasputin-api.service /etc/systemd/system/multi-user.target.wants/
# TEST HARNESS: openbao is wanted here (#756 enables it on the image), and both
# it and the api run a stand-in. The store's stand-in also clears the
# self-init outcome hooks (#804): with no bao there is nothing to record, and a
# Type=simple stand-in would run ExecStartPost alongside its own start, which
# the shipped Type=notify unit never does.
RUN ln -s /etc/systemd/system/openbao.service /etc/systemd/system/multi-user.target.wants/ \\
 && mkdir -p /etc/systemd/system/openbao.service.d /etc/systemd/system/rasputin-api.service.d \\
 && printf '[Service]\nType=simple\nExecStartPre=\nExecStartPost=\nExecStopPost=\nExecStart=\nExecStart=/usr/bin/sleep infinity\n' \\
      > /etc/systemd/system/openbao.service.d/harness.conf \\
 && printf '[Service]\nType=simple\nWatchdogSec=0\nExecStart=\nExecStart=/usr/bin/sleep infinity\n' \\
      > /etc/systemd/system/rasputin-api.service.d/harness.conf
# TEST HARNESS: firstboot, which the api Requires= and the oneshot is ordered
# after, as a stand-in.
RUN printf '[Unit]\nDescription=stand-in firstboot\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/bin/true\n' \\
      > /etc/systemd/system/rasputin-firstboot.service
# TEST HARNESS: the openbao user, which mkusers creates on the image.
RUN echo 'openbao:x:990:' >>/etc/group && echo 'openbao:x:990:990::/:/sbin/nologin' >>/etc/passwd
# TEST HARNESS: a shared root, as systemd's mount-setup gives a booted image.
RUN printf '[Unit]\nDefaultDependencies=no\nBefore=sysinit.target\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/bin/mount --make-rshared /\n[Install]\nWantedBy=sysinit.target\n' \\
      > /etc/systemd/system/harness-rshared.service \\
 && mkdir -p /etc/systemd/system/sysinit.target.wants \\
 && ln -s /etc/systemd/system/harness-rshared.service /etc/systemd/system/sysinit.target.wants/
# TEST HARNESS: journald reads the kernel log, as it does on a node.
RUN mkdir -p /etc/systemd/journald.conf.d \\
 && printf '[Journal]\nReadKMsg=yes\n' > /etc/systemd/journald.conf.d/harness-kmsg.conf
DOCKERFILE

docker volume create "$VOL" >/dev/null || { echo "FAILED: the docker volume could not be created."; exit 1; }
# on_volume SCRIPT — run SCRIPT as root on the volume, with no init: the
# persistent partition between boots.
on_volume() { docker run --rm -v "$VOL:$V" "$IMAGE" sh -c "$1"; }

# TEST HARNESS: what firstboot and the api leave on a control plane.
on_volume "
set -e
chmod 0755 $V
touch $V/role.controlplane
mkdir -p $V/trust $V/tls/openbao-server
echo placeholder-ca > $V/trust/store-ca.pem
echo placeholder-leaf > $V/tls/openbao-server/leaf.pem
echo placeholder-key > $V/tls/openbao-server/leaf.key
" || { echo "FAILED: could not prepare the volume."; exit 1; }

# boot N [DOCKER_RUN_OPTION ...] — a new container on the volume.
boot() {
	_n=$1; shift
	ctr_boot "boot $_n" "$IMAGE" -v "$VOL:$V" "$@"
}
show() { inside "systemctl show $1 -p $2 --value"; }
# settled UNIT STATE — wait until UNIT is STATE with no job queued.
settled() {
	wait_for "$1 is $2 with no job queued" \
		"[ \"\$(systemctl show $1 -p ActiveState --value)\" = $2 ] && [ -z \"\$(systemctl show $1 -p Job --value)\" ]" \
		|| fails=$((fails + 1))
}
# journal_line UNIT TOKEN — the JSON journal entry of UNIT holding TOKEN.
journal_line() { inside "journalctl -u $1 --no-pager -o json" | grep -F -- "$2" | head -1; }
prio_of() { printf '%s\n' "$1" | sed -n 's/.*"PRIORITY":"\([0-9]\)".*/\1/p'; }
stat_key() { inside "stat -c '%s %a %u %g %Y' $SEAL/seal-key 2>&1"; }
hexof() { od -An -v -tx1 "$1" | tr -d ' \n'; }

# no_key_in_journal N — TC-803-23: export boot N's whole journal, kernel
# messages included, and search it for every key this run produced: raw (as
# hex of the export, byte-aligned or not), as lowercase and uppercase hex, and
# as base64.
KEYS=""
no_key_in_journal() {
	_j="$SCRATCH/journal-$1.export"
	inside "journalctl -o export --no-pager" > "$_j"
	_k=$(inside "journalctl -k --no-pager -o cat | wc -l")
	check "boot $1: the exported journal has kernel messages ($_k lines from journalctl -k)" "$(yes_if [ "${_k:-0}" -gt 0 ])"
	[ -n "$KEYS" ] || { check "boot $1: a key exists to search for" 1; return; }
	_jhex=$(hexof "$_j")
	for _key in $KEYS; do
		_lo=$(hexof "$_key")
		_up=$(printf '%s' "$_lo" | tr 'a-f' 'A-F')
		_b64=$(base64 < "$_key" | tr -d '\n')
		_raw=1; case "$_jhex" in *"$_lo"*) ;; *) _raw=0 ;; esac
		check "boot $1: no raw bytes of ${_key##*/} in the journal" "$_raw"
		check "boot $1: no lowercase hex of ${_key##*/}" "$(yes_if [ "$(grep -cF -- "$_lo" "$_j")" = 0 ])"
		check "boot $1: no uppercase hex of ${_key##*/}" "$(yes_if [ "$(grep -cF -- "$_up" "$_j")" = 0 ])"
		check "boot $1: no base64 of ${_key##*/}" "$(yes_if [ "$(grep -cF -- "$_b64" "$_j")" = 0 ])"
	done
}

echo
echo "boot 1: neither key nor data, so the key is created at boot (TC-803-19)"
boot 1 || exit 1
echo "in the container: $(inside 'systemctl --version | head -1')"
settled rasputin-seal-key.service active
settled openbao.service active
settled rasputin-api.service active
check "the oneshot's Result is success (got '$(show rasputin-seal-key.service Result)')" \
	"$(yes_if [ "$(show rasputin-seal-key.service Result)" = success ])"
exit_t=$(show rasputin-seal-key.service ExecMainExitTimestampMonotonic)
for u in openbao.service rasputin-api.service; do
	start_t=$(show $u ExecMainStartTimestampMonotonic)
	r=1; [ "${exit_t:-0}" -gt 0 ] && [ "${start_t:-0}" -gt "$exit_t" ] && r=0
	check "the oneshot exited ($exit_t) before $u started ($start_t)" "$r"
done
st=$(stat_key)
check "seal-key is 32 bytes, 0600, 0:0 (got '${st% *}')" "$(yes_if [ "${st% *}" = "32 600 0 0" ])"
st=$(inside "stat -c '%a %u %g' $SEAL/seal.hcl 2>&1")
check "seal.hcl is 0600, 0:0 (got '$st')" "$(yes_if [ "$st" = "600 0 0" ])"
# Byte-exact copies out through docker exec: the credential is on a mount
# only the container's own namespace sees.
docker exec "$CID" cat "$SEAL/seal-key" > "$SCRATCH/key-boot1" 2>/dev/null \
	&& KEYS="$SCRATCH/key-boot1"
docker exec "$CID" cat "$CREDS/seal-key" > "$SCRATCH/cred-boot1" 2>/dev/null
check "the store's $CREDS/seal-key is byte-equal to the key" \
	"$(yes_if cmp -s "$SCRATCH/key-boot1" "$SCRATCH/cred-boot1")"
api=$(show rasputin-api.service ActiveState)
check "the api is active (got '$api')" "$(yes_if [ "$api" = active ])"
line=$(journal_line rasputin-seal-key.service "outcome=created")
check "the journal has outcome=created at PRIORITY=6 (got '$(prio_of "$line")')" "$(yes_if [ "$(prio_of "$line")" = 6 ])" "$line"
BOOT1_STAT=$(stat_key)
BOOT1_SHA=$(inside "sha256sum < $SEAL/seal-key")
no_key_in_journal 1

echo
echo "boot 2: the same volume, so the key is untouched (TC-803-20)"
boot 2 || exit 1
settled rasputin-seal-key.service active
settled rasputin-api.service active
line=$(journal_line rasputin-seal-key.service "outcome=untouched")
check "the journal has outcome=untouched at PRIORITY=6 (got '$(prio_of "$line")')" "$(yes_if [ "$(prio_of "$line")" = 6 ])" "$line"
check "the key's sha256 is boot 1's" "$(yes_if [ "$(inside "sha256sum < $SEAL/seal-key")" = "$BOOT1_SHA" ])"
check "the key's size, mode, owner and mtime are boot 1's ($BOOT1_STAT)" "$(yes_if [ "$(stat_key)" = "$BOOT1_STAT" ])" "$(stat_key)"
api=$(show rasputin-api.service ActiveState)
check "the api is active (got '$api')" "$(yes_if [ "$api" = active ])"
no_key_in_journal 2

echo
echo "boot 3: store data and no key, so the oneshot refuses and the cluster stays down (TC-803-21)"
ctr_cleanup
MANIFEST="cd $V/openbao && find . | sort && find . -type f | sort | xargs sha256sum"
on_volume "
set -e
mkdir -p $V/openbao/sub
echo store-data > $V/openbao/MANIFEST
echo more > $V/openbao/sub/000001.sst
chown -R 990:990 $V/openbao
rm -f $SEAL/seal-key
" || check "store data was written and the key removed" 1
before=$(on_volume "$MANIFEST")
boot 3 || exit 1
settled rasputin-seal-key.service failed
settled openbao.service failed
st="$(show rasputin-seal-key.service ActiveState) $(show rasputin-seal-key.service ExecMainStatus)"
check "the oneshot is failed with ExecMainStatus=2 (got '$st')" "$(yes_if [ "$st" = "failed 2" ])"
r=$(inside "test -e $SEAL/seal-key && echo present || echo absent")
check "no seal-key exists (got '$r')" "$(yes_if [ "$r" = absent ])"
after=$(inside "$MANIFEST")
check "the store's data tree has the same names and sha256s" "$(yes_if [ -n "$before" ] && [ "$before" = "$after" ])" "$after"
st=$(show openbao.service ExecMainStatus)
check "openbao is failed with ExecMainStatus=243, CREDENTIALS (got '$st')" "$(yes_if [ "$st" = 243 ])"
line=$(inside "journalctl -u openbao.service --no-pager -o cat" | grep -F 'Failed at step CREDENTIALS' | head -1)
check "openbao's journal says 'Failed at step CREDENTIALS'" "$(yes_if [ -n "$line" ])"
wait_for "the api's start job is finished" '[ -z "$(systemctl show rasputin-api.service -p Job --value)" ]' || fails=$((fails + 1))
st="$(show rasputin-api.service ActiveState) $(show rasputin-api.service AssertResult)"
check "the api is inactive with AssertResult=no (got '$st')" "$(yes_if [ "$st" = "inactive no" ])"
line=$(inside "journalctl -u rasputin-api.service --no-pager -o cat" | grep -F 'Starting requested but asserts failed.' | head -1)
check "the api's journal says 'Starting requested but asserts failed.'" "$(yes_if [ -n "$line" ])" \
	"$(inside "journalctl -u rasputin-api.service --no-pager -o cat | tail -3" | tr '\n' '|')"
failed=$(inside "systemctl --failed --no-legend --plain")
r=1; contains rasputin-seal-key.service "$failed" && ! contains rasputin-api.service "$failed" && r=0
check "systemctl --failed lists the oneshot and not the api (F-803-05)" "$r" "$failed"
r=$(inside "test -f /run/rasputin-seal-key/refused && echo present || echo absent")
check "the gate /run/rasputin-seal-key/refused exists (got '$r')" "$(yes_if [ "$r" = present ])"
line=$(inside "journalctl -k --no-pager -o json" | grep -F -- "$REFUSAL" | head -1)
check "journalctl -k holds the refusal sentence at PRIORITY=2 (got '$(prio_of "$line")')" "$(yes_if [ "$(prio_of "$line")" = 2 ])" "$line"
line=$(inside "journalctl -u rasputin-seal-key.service -p crit --no-pager -o cat" | grep -F 'outcome=refused' | head -1)
check "journalctl -u rasputin-seal-key -p crit holds outcome=refused" "$(yes_if [ -n "$line" ])"
no_key_in_journal 3

echo
echo "boot 4: no data, no key, a short random source, so the oneshot fails and the api still starts (TC-803-22)"
ctr_cleanup
on_volume "rm -rf $V/openbao/* $V/openbao/.[!.]* 2>/dev/null; rm -f $SEAL/seal-key $SEAL/seal.hcl; test -z \"\$(ls -A $V/openbao)\"" \
	|| check "the store's data was emptied" 1
# TEST HARNESS: the drop-in and the 31-byte file.
mkdir -p "$SCRATCH/dropin"
printf '[Service]\nEnvironment=RASPUTIN_SEALKEY_RANDOM=/etc/harness-short-random\n' > "$SCRATCH/dropin/harness-random.conf"
head -c 31 /dev/urandom > "$SCRATCH/short-random"
boot 4 -v "$SCRATCH/dropin:/etc/systemd/system/rasputin-seal-key.service.d:ro" \
	-v "$SCRATCH/short-random:/etc/harness-short-random:ro" || exit 1
settled rasputin-seal-key.service failed
settled openbao.service failed
settled rasputin-api.service active
st="$(show rasputin-seal-key.service ActiveState) $(show rasputin-seal-key.service ExecMainStatus)"
check "the oneshot is failed with ExecMainStatus=1 (got '$st')" "$(yes_if [ "$st" = "failed 1" ])"
line=$(journal_line rasputin-seal-key.service "outcome=failed")
check "its journal line is PRIORITY=3 (got '$(prio_of "$line")')" "$(yes_if [ "$(prio_of "$line")" = 3 ])" "$line"
r=$(inside "test -e $SEAL/seal-key && echo present || echo absent")
check "no seal-key exists (got '$r')" "$(yes_if [ "$r" = absent ])"
st=$(show openbao.service ExecMainStatus)
check "openbao is failed with ExecMainStatus=243 (got '$st')" "$(yes_if [ "$st" = 243 ])"
st="$(show rasputin-api.service ActiveState) $(show rasputin-api.service AssertResult)"
check "the api is active with AssertResult=yes (got '$st')" "$(yes_if [ "$st" = "active yes" ])"
r=$(inside "test -e /run/rasputin-seal-key/refused && echo present || echo absent")
check "there is no gate (got '$r')" "$(yes_if [ "$r" = absent ])"
no_key_in_journal 4

echo
if [ "$fails" -eq 0 ]; then
	echo "seal-key-functional: all checks passed"
else
	echo "seal-key-functional: $fails check(s) FAILED"
fi
[ "$fails" -eq 0 ]
