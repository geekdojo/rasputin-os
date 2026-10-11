#!/bin/sh
#
# update-smoke.sh — boot a PUBLISHED Rasputin image under QEMU, `rauc install`
# the new signed bundle on it, boot the updated slot, assert it runs the new
# kernel with docker working, then roll back and assert the old slot still
# boots a kernel that matches its rootfs (geekdojo/geekdojo-brain#807).
#
#   usage: test/update-smoke.sh <amd64|arm64> <old.img> <new.raucb> <new.img> <new-version>
#
#   old.img      a published flash image (decompressed): the "device" being updated
#   new.raucb    the signed bundle this build will publish
#   new.img      this build's flash image — where the expected new kernel is read
#   new-version  this build's version (the boot marker the bundle must write)
#
# WHY. Both boot smokes boot a fresh image with its own kernel, so nothing
# tested the UPDATE path, and RAUC replaced only the rootfs: dev.276 changed
# the Pi kernel config, OTA'd nodes kept the old kernel, and docker died on
# every arm64 bench node ("Failed to create bridge docker0 via netlink:
# operation not supported"). This is that path, end to end, on the real old
# image with its real old RAUC and backend, and the real signed bundle.
#
# THE STEPS
#   1. Boot the old image (slot A), seeded as a controlplane with a throwaway
#      SSH key; wait for dropbear and for systemd to finish starting.
#   2. `rauc install` the bundle from a second disk; power off.
#   3. Boot what the device would boot next:
#        arm64  the harness plays the Pi firmware: it reads the selector FAT's
#               autoboot.txt and RAUC's trial marker, and loads kernel + cmdline
#               from the [tryboot] partition (the agent's `reboot "0 tryboot"`).
#        amd64  OVMF + the image's own GRUB + grubenv decide, as on the board.
#      Assert: the slot's boot marker is the new version, its kernel file is the
#      new build's kernel, the running kernel (uname) is the new build's, the
#      kernel-match verdict says MATCH, rauc.slot=B, the image version is the
#      new one, docker is active, docker0 exists, /sys/module/bridge exists.
#      The secrets-store binary (geekdojo/geekdojo-brain#798): `bao version`
#      reports the version package/openbao/openbao.mk pins, its LICENSE and
#      source notice are there and the notice names that version, the static
#      openbao user is 990:990, /usr/bin/bao is root:root 0755, and nothing
#      runs it before its leaf exists.
#      The seal key (geekdojo/geekdojo-brain#803): an OTA'd control plane never
#      runs firstboot again, so the every-boot oneshot is what creates its key.
#      rasputin-seal-key.service's Result is success and it is not in
#      `systemctl --failed`, the key is 32 bytes 0600 0:0, the fragment is
#      0600 0:0, and the outcome record says created.
#      The store itself (geekdojo/geekdojo-brain#756): openbao.service is
#      enabled, skipped until its server leaf exists, and the api's store CA
#      is there. Then the harness mints a store-CA server leaf (the image's
#      api pin does not mint one yet) and restarts it: active as uid 990, its
#      only socket 127.0.0.1:8200, `bao status` answers "Initialized false"
#      with a store-CA client leaf and is refused in the TLS handshake, as the
#      store's own journal records, with none, with a controlplane-CA leaf
#      and with the server leaf, no OOM kill, and the
#      at-rest audit passes with the store running. With the role marker
#      moved aside it is skipped again, naming the role condition, and with
#      the marker back it is active. The harness's CA keys and test leaves
#      live only in $WORK/store-pki, which the EXIT trap removes, and the
#      consoles are searched for them before it does.
#      Boot 2 is where these live because it is the only boot of THIS
#      build's rootfs with a shell into the guest, on both arches, and it is an
#      OTA'd node: its persistent shadow was seeded by the old image and has no
#      openbao row, which is exactly the path `id openbao` must work on.
#   4. Roll back without committing: arm64 powers off without mark-good, and the
#      next NORMAL boot falls back to the [all] partition (the one-shot rollback);
#      amd64 marks the booted slot bad, and GRUB falls back to A. Assert slot A
#      runs ITS kernel (the old image's), with docker, and on arm64 that slot
#      A's boot partition is byte-identical to before the update.
#
# WHAT IT DOES NOT PROVE. `virt` is not a Pi: the EEPROM bootloader, config.txt
# kernel selection and the real tryboot flag are emulated by reading the same
# files the firmware reads, and only kernel_2712.img (Pi 5 / CM5) is booted;
# kernel8.img (Pi 4) is checked as bytes, not booted. Pi 4 / Pi 5 / CM4 stay a
# bench step (rasputin-fleet-test skill).
#
# Every assertion is collected and reported; the script exits 1 if any failed,
# so one run shows the whole picture (a red run lists every broken property, not
# the first). Every wait is a poll on a checkable fact with a hard try count,
# or, for the store's handshake-error lines, a journal follow that ends on the
# line, bounded by its SSH call's timeout.
set -u

ARCH="${1:?usage: update-smoke.sh <amd64|arm64> <old.img> <new.raucb> <new.img> <new-version>}"
OLD_IMG="${2:?old image}"
BUNDLE="${3:?new bundle}"
NEW_IMG="${4:?new image}"
NEW_VERSION="${5:?new version}"
WORK="${WORK:-/tmp/update-smoke}"
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
KID="$HERE/../scripts/kernel-id.sh"
. "$HERE/lib/qemu-common.sh"
. "$HERE/lib/mk-var.sh"
. "$HERE/lib/test-pki.sh"
. "$HERE/lib/listen-sockets.sh"

case "$ARCH" in amd64|arm64) ;; *) echo "::error::unknown arch '$ARCH'"; exit 2 ;; esac
for f in "$OLD_IMG" "$BUNDLE" "$NEW_IMG"; do
	[ -f "$f" ] || { echo "::error::no such file: $f"; exit 2; }
done
# The OpenBao version this build pins, read with real make the way Buildroot
# reads it; boot 2's store checks compare against it.
BAO_PIN="$(mk_var "$HERE/../package/openbao/openbao.mk" OPENBAO_VERSION)" \
	|| { echo "::error::Could not read the OpenBao pin from package/openbao/openbao.mk, so boot 2's store checks have nothing to compare against."; exit 2; }

SSH_PORT=12222
BUDGET=1800        # hard bound on one QEMU run (a whole boot + install session)
SSH_TRIES=150      # 2s apart: 300s for dropbear to answer after QEMU starts
GONE_TRIES=90      # 2s apart: 180s for the guest to power off
READY_TIMEOUT=600  # one `systemctl is-system-running --wait` call
STORE_CA_TRIES=60  # 2s apart: 120s for the api to mint the store CA after boot settles

# The store's files on the guest (geekdojo/geekdojo-brain#756).
STORE_CA=/var/lib/rasputin/trust/store-ca.pem
MESH_CA=/var/lib/rasputin/trust/mesh-ca.pem
STORE_LEAF=/var/lib/rasputin/tls/openbao-server/leaf
GUEST_PKI=/run/update-smoke-store

rm -rf "$WORK"
mkdir -p "$WORK"
DISK="$WORK/disk.img"
KEY="$WORK/id_ed25519"
QPID=""
cleanup() {
	[ -n "$QPID" ] && kill "$QPID" 2>/dev/null
	# The key is throwaway, but it is a private key: it does not outlive the run.
	rm -f "$KEY" "$KEY.pub" "$DISK" "$WORK/bundle.vfat" "$WORK"/*.bin
	# So are the store's harness CA keys and test leaves (TC-756-24).
	rm -rf "$WORK/store-pki"
	return 0
}
trap cleanup EXIT

FAILS=0
fail() { echo "::error::update-smoke ($ARCH): $*"; FAILS=$((FAILS + 1)); }
pass() { echo "ok  $*"; }
expect() { # expect LABEL WANT GOT
	if [ "$2" = "$3" ]; then pass "$1 ($3)"; else fail "$1: want '$2', got '$3'"; fi
}
die() { echo "::error::update-smoke ($ARCH): $*"; exit 1; }

mtools() { MTOOLS_SKIP_CHECK=1 "$@"; }

# fat_get IMG PART FILE OUT — copy FILE out of partition PART's FAT; status 1 if absent.
fat_get() {
	_off="$(part_offset "$1" "$2")"
	[ -n "$_off" ] || return 1
	mtools mcopy -n -i "$1@@$_off" "::$3" "$4" 2>/dev/null
}
fat_cat() { # fat_cat IMG PART FILE — print FILE, nothing if absent
	fat_get "$1" "$2" "$3" "$WORK/fat_cat.tmp" && tr -d '\r' < "$WORK/fat_cat.tmp"
	rm -f "$WORK/fat_cat.tmp"
}
part_hash() { # part_hash IMG PART — sha256 of the whole partition
	sfdisk -J "$1" | jq -r --arg n "$2" '.partitiontable.partitions[]
		| select(.node | test("[^0-9]" + $n + "$")) | "\(.start) \(.size)"' | {
		read -r _s _n
		dd if="$1" bs=512 skip="$_s" count="$_n" 2>/dev/null | sha256sum | cut -d' ' -f1
	}
}

# The kernel a slot's boot files would load, as a kernel id. arm64: the slot's
# boot FAT (p2 = A, p3 = B) kernel_2712.img. amd64: the ESP's /bzImage-<slot>,
# else the legacy shared /bzImage — exactly grub.cfg's own fallback.
slot_kernel_id() { # slot_kernel_id IMG SLOT
	rm -f "$WORK/k.bin"
	case "$ARCH" in
		arm64)
			case "$2" in A) _p=2 ;; B) _p=3 ;; esac
			fat_get "$1" "$_p" kernel_2712.img "$WORK/k.bin" || return 1
			;;
		amd64)
			fat_get "$1" 1 "bzImage-$2" "$WORK/k.bin" || fat_get "$1" 1 bzImage "$WORK/k.bin" || return 1
			;;
	esac
	sh "$KID" "$WORK/k.bin"
}

# The section's boot_partition in the selector FAT's autoboot.txt — read the
# way rpi-tryboot-backend.sh reads it.
autoboot_part() { # autoboot_part SECTION
	fat_cat "$DISK" 1 autoboot.txt | awk -v sec="[$1]" '
		/^\[/ { cur = $1 }
		cur == sec && /^boot_partition=/ { v = $0; sub(/.*boot_partition=/, "", v); sub(/[^0-9].*/, "", v); print v; exit }'
}

# ssh_guest CMD... — one command in the guest, bounded by SSH_CALL_TIMEOUT
# seconds (default 120): a timeout bounds a single call, it never decides state.
ssh_guest() {
	timeout "${SSH_CALL_TIMEOUT:-120}" ssh -i "$KEY" -p "$SSH_PORT" \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=10 \
		root@127.0.0.1 "$@"
}

qemu_gone() { [ -z "$QPID" ] || ! kill -0 "$QPID" 2>/dev/null; }

# boot N — start QEMU on the disk for boot number N (console-N.log), then wait
# for SSH and for systemd to finish starting. Status 1 if the guest never
# answered; the console is printed either way on failure.
boot() {
	_n=$1
	LOG="$WORK/console-$_n.log"
	: > "$LOG"
	(QEMU_DISK2="$WORK/bundle.vfat" qemu_exec "$ARCH" "$DISK" "$BUDGET" "$LOG" \
		"hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" -no-reboot) &
	QPID=$!
	_i=0
	while [ "$_i" -lt "$SSH_TRIES" ]; do
		if ssh_guest true 2>/dev/null; then break; fi
		if qemu_gone; then
			echo "----- console-$_n (QEMU exited before SSH answered) -----"; tail -80 "$LOG"
			wait "$QPID" 2>/dev/null; QPID=""; return 1
		fi
		_i=$((_i + 1)); sleep 2
	done
	if [ "$_i" -ge "$SSH_TRIES" ]; then
		echo "----- console-$_n (no SSH after $((SSH_TRIES * 2))s) -----"; tail -80 "$LOG"
		kill_guest
		return 1
	fi
	# A fact, not a sleep: returns when the boot transaction is over (running
	# or degraded — a failed unit is what the assertions below are for).
	_state="$(SSH_CALL_TIMEOUT="$READY_TIMEOUT" ssh_guest systemctl is-system-running --wait 2>/dev/null)"
	echo "boot $_n: SSH up, system state '${_state:-unknown}'"
	ssh_guest 'systemctl --failed --no-legend --plain' 2>/dev/null | sed "s/^/    boot $_n failed unit: /"
	return 0
}

kill_guest() {
	[ -n "$QPID" ] || return 0
	kill "$QPID" 2>/dev/null
	wait "$QPID" 2>/dev/null
	QPID=""
}

# poweroff_guest — ask for a clean power-off and wait for QEMU to exit.
poweroff_guest() {
	ssh_guest 'systemctl poweroff' >/dev/null 2>&1 || true
	_i=0
	while ! qemu_gone; do
		[ "$_i" -lt "$GONE_TRIES" ] || { kill "$QPID" 2>/dev/null; fail "the guest did not power off within $((GONE_TRIES * 2))s; killed it"; break; }
		_i=$((_i + 1)); sleep 2
	done
	wait "$QPID" 2>/dev/null
	QPID=""
}

# arm64: load kernel + cmdline from boot partition P into QEMU_KERNEL/QEMU_APPEND.
arm64_load_slot() {
	fat_get "$DISK" "$1" kernel_2712.img "$WORK/boot-kernel.bin" \
		|| die "boot partition $1 carries no kernel_2712.img"
	_cl="$(fat_cat "$DISK" "$1" cmdline.txt | tr -d '\n')"
	[ -n "$_cl" ] || die "boot partition $1 carries no cmdline.txt"
	QEMU_KERNEL="$WORK/boot-kernel.bin"
	# Same two harness additions as boot-smoke.sh: virt's only UART is a PL011,
	# and PID 1's log goes to kmsg so the console carries it.
	QEMU_APPEND="$_cl systemd.log_target=kmsg console=ttyAMA0,115200"
	echo "loading partition $1: kernel $(sh "$KID" "$QEMU_KERNEL" 2>/dev/null || echo '?')"
	echo "  cmdline: $QEMU_APPEND"
}

running_id() { ssh_guest 'echo "$(uname -r) $(uname -v)"' 2>/dev/null; }
cmdline_slot() { ssh_guest 'cat /proc/cmdline' 2>/dev/null | tr ' ' '\n' | sed -n 's/^rauc\.slot=//p'; }
guest_yes() { if ssh_guest "$1" >/dev/null 2>&1; then echo yes; else echo no; fi; }

# ------------------------------------------------------------------ setup ----
echo "== setup"
cp "$OLD_IMG" "$DISK" || die "cannot copy $OLD_IMG"
ssh-keygen -q -t ed25519 -N '' -C update-smoke -f "$KEY" || die "ssh-keygen failed"
SEED_OFF="$(seed_offset "$DISK")"
[ -n "$SEED_OFF" ] || die "no seed partition in $OLD_IMG"
# A controlplane, as in boot-smoke.sh, plus the key: the only way in over SSH.
{
	printf 'RASPUTIN_NODE_ROLE=controlplane\nRASPUTIN_NODE_ID=smoke-cp\nRASPUTIN_CLUSTER_ID=updsmoke\n'
	printf 'RASPUTIN_NATS_URL=\nRASPUTIN_CP_JOIN_TOKEN=\n'
	printf 'RASPUTIN_SSH_AUTHORIZED_KEY="%s"\n' "$(cat "$KEY.pub")"
} > "$WORK/seed.env"
mtools mcopy -o -i "$DISK@@$SEED_OFF" "$WORK/seed.env" ::rasputin-seed.env || die "cannot write the seed"

# The bundle rides in on its own FAT disk, mounted by label in the guest: no
# copy over SSH, and no claim on the 512 MiB persistent partition.
BKB=$(( $(wc -c < "$BUNDLE") / 1024 + 65536 ))
mkfs.vfat -C -n SMOKEBUNDLE "$WORK/bundle.vfat" "$BKB" >/dev/null || die "mkfs.vfat failed"
mtools mcopy -i "$WORK/bundle.vfat" "$BUNDLE" ::update.raucb || die "cannot stage the bundle"

if [ "$ARCH" = amd64 ]; then
	find_ovmf || die "OVMF firmware not found"
	cp "$OVMF_VARS" "$WORK/vars.fd"
	VARS_FD="$WORK/vars.fd"
fi

NEW_ID="$(slot_kernel_id "$NEW_IMG" A)" || die "cannot read the kernel of the new image $NEW_IMG"
OLD_ID="$(slot_kernel_id "$DISK" A)" || die "cannot read slot A's kernel in the old image"
echo "old kernel (slot A): $OLD_ID"
echo "new kernel (build):  $NEW_ID"
[ "$NEW_ID" != "$OLD_ID" ] || die "the old and new kernels have the same identity; this run cannot tell them apart"
if [ "$ARCH" = arm64 ]; then
	A_BOOT_BEFORE="$(part_hash "$DISK" 2)"
fi

# ------------------------------------------------------- 1: old image, slot A --
echo "== boot 1: the old image"
if [ "$ARCH" = arm64 ]; then
	expect "fresh image: normal boot uses partition 2" 2 "$(autoboot_part all)"
	arm64_load_slot 2
fi
boot 1 || die "the old image did not come up"
OLD_VERSION="$(ssh_guest 'cat /etc/rasputin/image-version' 2>/dev/null)"
echo "old image version: $OLD_VERSION"
expect "boot 1: running slot" A "$(cmdline_slot)"

echo "== install"
if SSH_CALL_TIMEOUT=1500 ssh_guest 'mkdir -p /run/smoke-bundle && mount -o ro /dev/disk/by-label/SMOKEBUNDLE /run/smoke-bundle && rauc install /run/smoke-bundle/update.raucb' \
	> "$WORK/install.log" 2>&1; then
	pass "rauc install of the new bundle on $OLD_VERSION"
else
	sed 's/^/    /' "$WORK/install.log"
	fail "rauc install failed on $OLD_VERSION"
fi
tail -15 "$WORK/install.log" | sed 's/^/    install: /'
ssh_guest 'rauc status --detailed' 2>&1 | sed 's/^/    rauc: /'
poweroff_guest

# ---------------------------------------------- 2: the updated slot (trial) --
echo "== boot 2: the updated slot"
if [ "$ARCH" = arm64 ]; then
	PENDING="$(fat_cat "$DISK" 1 rauc-trial.pending | tr -d '\n')"
	expect "RAUC armed a trial of slot B" B "$PENDING"
	TRY_PART="$(autoboot_part tryboot)"
	expect "the [tryboot] partition is slot B's boot partition" 3 "$TRY_PART"
	expect "slot B boot marker" "$NEW_VERSION" "$(fat_cat "$DISK" 3 rasputin-boot-version | tr -d '\n')"
	expect "slot B boot FAT carries the new kernel" "$NEW_ID" "$(slot_kernel_id "$DISK" B || echo none)"
	arm64_load_slot "${TRY_PART:-3}"
else
	expect "slot B boot marker" "$NEW_VERSION" "$(fat_cat "$DISK" 1 rasputin-boot-version-B | tr -d '\n')"
	expect "slot B's kernel on the ESP is the new kernel" "$NEW_ID" "$(slot_kernel_id "$DISK" B || echo none)"
fi
if boot 2; then
	expect "boot 2: running slot" B "$(cmdline_slot)"
	expect "boot 2: running kernel is the new build's" "$NEW_ID" "$(running_id)"
	expect "boot 2: image version" "$NEW_VERSION" "$(ssh_guest 'cat /etc/rasputin/image-version' 2>/dev/null)"
	expect "boot 2: docker active" active "$(ssh_guest 'systemctl is-active docker' 2>/dev/null)"
	expect "boot 2: docker0 exists" yes "$(guest_yes 'ip link show docker0')"
	expect "boot 2: bridge in the running kernel" yes "$(guest_yes 'test -d /sys/module/bridge')"
	KM="$(grep -ao 'rasputin-kernel-match: .*' "$LOG" | tr -d '\r' | head -1)"
	case "$KM" in
		"rasputin-kernel-match: MATCH "*) pass "boot 2: kernel-match verdict ($KM)" ;;
		*) fail "boot 2: kernel-match verdict is not MATCH: '${KM:-<none on the console>}'" ;;
	esac
	# The secrets-store binary (geekdojo/geekdojo-brain#798). Only busybox
	# applets the image has: no stat and no pgrep, so ls -ln and pidof.
	BAO_LINE="$(ssh_guest '/usr/bin/bao version' 2>/dev/null | tr -d '\r' | head -1)"
	case "$BAO_LINE" in
		"OpenBao v$BAO_PIN "*) pass "boot 2: bao version reports the pin ($BAO_LINE)" ;;
		*) fail "boot 2: /usr/bin/bao version: want a first line starting 'OpenBao v$BAO_PIN ', got '${BAO_LINE:-<nothing>}'" ;;
	esac
	BAO_RAN="$(printf '%s\n' "$BAO_LINE" | sed -n 's/^OpenBao v\([^ ]*\) .*/\1/p')"
	expect "boot 2: the OpenBao LICENSE is installed" yes "$(guest_yes 'test -s /usr/share/licenses/openbao/LICENSE')"
	expect "boot 2: the OpenBao source notice is installed" yes "$(guest_yes 'test -s /usr/share/licenses/openbao/SOURCE')"
	expect "boot 2: the source notice names the version bao reported" "${BAO_RAN:-<no version from bao>}" \
		"$(ssh_guest 'cat /usr/share/licenses/openbao/SOURCE' 2>/dev/null | sed -n 's/^OpenBao \([^ ]*\) is distributed under the Mozilla Public License 2\.0\.$/\1/p')"
	expect "boot 2: openbao uid" 990 "$(ssh_guest 'id -u openbao' 2>/dev/null)"
	expect "boot 2: openbao gid" 990 "$(ssh_guest 'id -g openbao' 2>/dev/null)"
	expect "boot 2: /usr/bin/bao mode, owner and group" "-rwxr-xr-x 0 0" \
		"$(ssh_guest 'ls -ln /usr/bin/bao' 2>/dev/null | awk '{print $1, $3, $4}')"
	# rc=1 only: pidof's "no such process". rc=127 (no pidof) and any PID fail,
	# so this cannot pass because the tool is missing.
	expect "boot 2: nothing runs bao (pidof bao)" rc=1 "$(ssh_guest 'pidof bao; echo rc=$?' 2>/dev/null)"
	expect "boot 2: no failed unit names openbao or bao" "" \
		"$(ssh_guest 'systemctl --failed --no-legend --plain' 2>/dev/null | grep -i bao)"
	# The seal key on an OTA'd, provisioned control plane (TC-803-25). Result
	# alone is success for a unit that never ran, so the files and the record
	# are checked too.
	expect "boot 2: rasputin-seal-key.service Result" success \
		"$(ssh_guest 'systemctl show rasputin-seal-key.service -p Result --value' 2>/dev/null)"
	expect "boot 2: seal-key mode, owner, group and size" "-rw------- 0 0 32" \
		"$(ssh_guest 'ls -ln /var/lib/rasputin/openbao-seal/seal-key' 2>/dev/null | awk '{print $1, $3, $4, $5}')"
	expect "boot 2: seal.hcl mode, owner and group" "-rw------- 0 0" \
		"$(ssh_guest 'ls -ln /var/lib/rasputin/openbao-seal/seal.hcl' 2>/dev/null | awk '{print $1, $3, $4}')"
	expect "boot 2: the seal-key outcome record says created" created \
		"$(ssh_guest 'sed -n "s/^outcome=//p" /run/rasputin-seal-key/outcome' 2>/dev/null)"
	expect "boot 2: systemctl --failed does not list rasputin-seal-key" "" \
		"$(ssh_guest 'systemctl --failed --no-legend --plain' 2>/dev/null | grep rasputin-seal-key)"
	# Enabled (geekdojo/geekdojo-brain#756): post-build.sh's wants link, and no
	# [Install], so preset-all left the link alone (TC-756-18, TC-756-19).
	expect "boot 2: openbao.service is enabled" enabled \
		"$(ssh_guest 'systemctl is-enabled openbao.service' 2>/dev/null)"
	# The api mints the store CA at its start; a poll with a hard try count.
	_i=0
	while [ "$(guest_yes "test -s $STORE_CA")" != yes ] && [ "$_i" -lt "$STORE_CA_TRIES" ]; do
		_i=$((_i + 1)); sleep 2
	done
	if [ "$(guest_yes "test -s $STORE_CA")" = yes ]; then
		pass "boot 2: the api's store CA $STORE_CA exists"
		STORE_CA_OK=1
	else
		fail "boot 2: the api's store CA $STORE_CA never appeared in $((STORE_CA_TRIES * 2))s"
		STORE_CA_OK=0
	fi
	# Skipped before its leaf. At the api pin this image carries, nothing mints
	# the server leaf, so a leaf here means the api now does: the harness block
	# below would then overwrite the api's own leaf, and is to go.
	if [ "$(guest_yes "test -e $STORE_LEAF.pem || test -e $STORE_LEAF.key")" = yes ]; then
		fail "boot 2: a server leaf already exists at $STORE_LEAF.{pem,key} before the harness wrote one, so the api now mints it. Delete the 'store harness mint' block in test/update-smoke.sh and re-baseline per geekdojo/geekdojo-brain#763."
		STORE_LEAF_FREE=0
	else
		STORE_LEAF_FREE=1
		expect "boot 2: openbao.service before its leaf: ConditionResult and ActiveState" "no inactive" \
			"$(ssh_guest 'echo $(systemctl show openbao.service -p ConditionResult --value) $(systemctl show openbao.service -p ActiveState --value)' 2>/dev/null)"
	fi
	if [ "$STORE_CA_OK" = 1 ] && [ "$STORE_LEAF_FREE" = 1 ]; then
		# ---- store harness mint (TC-756-20, TC-756-21) ----------------------
		# TEST HARNESS, until the image's api mints the leaf (#758; the later
		# pin bump replaces this block, recorded on #763). The CA keys come
		# over SSH into $WORK/store-pki (0700, files 0600) and never leave it;
		# test/lib/test-pki.sh takes every key by file. The server leaf goes
		# back over SSH stdin, at the at-rest inventory's modes.
		SP="$WORK/store-pki"
		(umask 077 && mkdir -p "$SP" \
			&& ssh_guest "cat $STORE_CA" >"$SP/store-ca.pem" \
			&& ssh_guest "cat ${STORE_CA%.pem}.key" >"$SP/store-ca.key" \
			&& ssh_guest "cat $MESH_CA" >"$SP/mesh-ca.pem" \
			&& ssh_guest "cat ${MESH_CA%.pem}.key" >"$SP/mesh-ca.key") 2>/dev/null \
			|| fail "boot 2: could not read the store CA and the controlplane CA over SSH"
		if mint_leaf "$SP/server.key" "$SP/server.pem" update-smoke-store-server "$SP/store-ca.pem" "$SP/store-ca.key" serverAuth IP:127.0.0.1 \
			&& mint_leaf "$SP/client.key" "$SP/client.pem" update-smoke-store-client "$SP/store-ca.pem" "$SP/store-ca.key" clientAuth \
			&& mint_leaf "$SP/mesh-client.key" "$SP/mesh-client.pem" update-smoke-mesh-client "$SP/mesh-ca.pem" "$SP/mesh-ca.key" clientAuth \
			&& ssh_guest "umask 022 && cat >$STORE_LEAF.pem && chmod 0644 $STORE_LEAF.pem" <"$SP/server.pem" \
			&& ssh_guest "umask 077 && cat >$STORE_LEAF.key && chmod 0600 $STORE_LEAF.key" <"$SP/server.key" \
			&& ssh_guest "umask 077 && mkdir -p $GUEST_PKI" </dev/null; then
			for f in store-ca.pem client.pem client.key mesh-client.pem mesh-client.key server.pem server.key; do
				ssh_guest "umask 077 && cat >$GUEST_PKI/$f" <"$SP/$f" || fail "boot 2: could not copy $f to the guest"
			done
			pass "boot 2: the harness wrote a store-CA server leaf to $STORE_LEAF.{pem,key}"
		else
			fail "boot 2: the harness could not mint and write the store's test leaves"
		fi
		# ---- end of the store harness mint ----------------------------------
		ssh_guest 'systemctl reset-failed openbao.service; systemctl restart openbao.service' >/dev/null 2>&1
		expect "boot 2: openbao.service with its leaf is active" active \
			"$(ssh_guest 'systemctl show openbao.service -p ActiveState --value' 2>/dev/null)"
		expect "boot 2: the store's MainPID runs as uid 990" 990 \
			"$(ssh_guest 'p=$(systemctl show openbao.service -p MainPID --value); awk "/^Uid:/ { print \$2 }" /proc/$p/status' 2>/dev/null)"
		expect "boot 2: bao's only LISTEN socket" 127.0.0.1:8200 \
			"$(ssh_guest 'p=$(systemctl show openbao.service -p MainPID --value); cat /proc/$p/net/tcp /proc/$p/net/tcp6; ls -l /proc/$p/fd' 2>/dev/null | bao_listeners | tr '\n' ' ' | sed 's/ $//')"
		# bao_status ARGS — `bao status` against the store, with the guest
		# copies of the test certificates; its output, then rc=N.
		bao_status() {
			ssh_guest "BAO_ADDR=https://127.0.0.1:8200 bao status -ca-cert=$GUEST_PKI/store-ca.pem $1 2>&1; echo rc=\$?" 2>/dev/null | tr -d '\r'
		}
		ST="$(bao_status "-client-cert=$GUEST_PKI/client.pem -client-key=$GUEST_PKI/client.key")"
		if printf '%s\n' "$ST" | grep -Eq '^Initialized[[:space:]]+false$' && printf '%s\n' "$ST" | grep -qx 'rc=2'; then
			pass "boot 2: bao status with a store-CA client leaf: Initialized false, exit 2"
		else
			fail "boot 2: bao status with a store-CA client leaf: want 'Initialized false' and rc=2, got: $(printf '%s' "$ST" | tr '\n' '|')"
		fi
		# The refusals. Under TLS 1.3 bao's client reports the store's refusal
		# as an alert, a failed write or an HTTP/2 setup failure, by timing
		# (F-756-16), so its words are not the fact. The fact is the store's own
		# "http: TLS handshake error" line naming the reason, read by
		# test/lib/tls-refusal.sh on the guest from a cursor taken before the
		# attempt; the SSH call's timeout is its deadline. With it: rc=1, no
		# HTTP status, and no connection refusal.
		ssh_guest "umask 077 && cat >$GUEST_PKI/tls-refusal.sh" <"$HERE/lib/tls-refusal.sh" \
			|| fail "boot 2: could not copy test/lib/tls-refusal.sh to the guest"
		for c in "no client certificate|provide a certificate|" \
			"the controlplane CA's client leaf|certificate signed by unknown authority|-client-cert=$GUEST_PKI/mesh-client.pem -client-key=$GUEST_PKI/mesh-client.key" \
			"the server leaf as a client|certificate specifies an incompatible key usage|-client-cert=$GUEST_PKI/server.pem -client-key=$GUEST_PKI/server.key"; do
			_who=${c%%|*}; _rest=${c#*|}; _why=${_rest%%|*}; _args=${_rest#*|}
			ST="$(ssh_guest "BAO_ADDR=https://127.0.0.1:8200 sh $GUEST_PKI/tls-refusal.sh openbao.service '$_why' bao status -ca-cert=$GUEST_PKI/store-ca.pem $_args" 2>/dev/null | tr -d '\r')"
			_client=$(printf '%s\n' "$ST" | sed -n 's/^client: //p')
			_line=$(printf '%s\n' "$ST" | sed -n 's/^journal: //p')
			case "$_line" in *"http: TLS handshake error from 127.0.0.1:"*"$_why"*) _logged=1 ;; *) _logged=0 ;; esac
			case "$_client" in *"Code: "*|*"onnection refused"*) _client_ok=0 ;; *"|rc=1") _client_ok=1 ;; *) _client_ok=0 ;; esac
			if [ "$_logged" = 1 ] && [ "$_client_ok" = 1 ]; then
				pass "boot 2: bao status with $_who is refused in the TLS handshake: the store logged '$_line'; the client got no HTTP status (rc=1)"
			else
				fail "boot 2: bao status with $_who: want the store's 'http: TLS handshake error … $_why' line, rc=1, no HTTP status and no connection refusal, got: $(printf '%s' "${ST:-<nothing; the SSH call ended with no output within ${SSH_CALL_TIMEOUT:-120}s>}" | tr '\n' '|')"
			fi
		done
		expect "boot 2: the store's memory.events oom_kill" 0 \
			"$(ssh_guest 'awk "\$1 == \"oom_kill\" { print \$2 }" /sys/fs/cgroup$(systemctl show openbao.service -p ControlGroup --value)/memory.events' 2>/dev/null)"
		AR="$(ssh_guest '/usr/lib/rasputin/atrest/rasputin-atrest-audit.sh -q' 2>/dev/null | tr -d '\r' | grep '^rasputin-atrest: ' | tail -1)"
		case "$AR" in
			"rasputin-atrest: PASS checked="[1-9]*) pass "boot 2: the at-rest audit with the store active ($AR)" ;;
			*) fail "boot 2: the at-rest audit with the store active: want 'rasputin-atrest: PASS checked=N' with N > 0, got '${AR:-<nothing>}'" ;;
		esac
		# The role gate on the image (TC-756-22, TC-756-23).
		ROLE=/var/lib/rasputin/role.controlplane
		# PID 1 logs to the journal for this step, as it does on a booted image.
		# On arm64 the harness boots with systemd.log_target=kmsg (arm64_load_slot),
		# and a PID 1 line sent through kmsg reaches journald with no UNIT= field,
		# so `journalctl -u` can never name it (F-756-13). The image has busctl and
		# no systemd-analyze. `journalctl --sync` returns once journald has stored
		# every line already sent, so each count is read after its fact.
		PID1_LOG="org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager LogTarget"
		_target="$(ssh_guest "busctl get-property $PID1_LOG" 2>/dev/null | tr -d '\r' | sed -n 's/^s "\(.*\)"$/\1/p')"
		# Without the old target there is nothing to restore it to (F-756-17).
		[ -n "$_target" ] || fail "boot 2: role marker moved aside: could not read PID 1's LogTarget with busctl, so the step cannot restore it"
		ssh_guest "busctl set-property $PID1_LOG s journal-or-kmsg" >/dev/null 2>&1
		expect "boot 2: role marker moved aside: PID 1 logs to the journal for the step (was ${_target:-?})" 's "journal-or-kmsg"' \
			"$(ssh_guest "busctl get-property $PID1_LOG" 2>/dev/null | tr -d '\r')"
		_before="$(ssh_guest "journalctl --sync && journalctl -b -u openbao.service --no-pager -o cat | grep -c 'ConditionPathExists=$ROLE'" 2>/dev/null)"
		ssh_guest "mv $ROLE $ROLE.smoke-aside && systemctl restart openbao.service" >/dev/null 2>&1
		expect "boot 2: role marker moved aside: openbao.service ConditionResult and ActiveState" "no inactive" \
			"$(ssh_guest 'echo $(systemctl show openbao.service -p ConditionResult --value) $(systemctl show openbao.service -p ActiveState --value)' 2>/dev/null)"
		_after="$(ssh_guest "journalctl --sync && journalctl -b -u openbao.service --no-pager -o cat | grep -c 'ConditionPathExists=$ROLE'" 2>/dev/null)"
		if [ "${_after:-0}" -gt "${_before:-0}" ] 2>/dev/null; then
			pass "boot 2: role marker moved aside: the journal names ConditionPathExists=$ROLE"
		else
			fail "boot 2: role marker moved aside: no new journal line names ConditionPathExists=$ROLE (before ${_before:-?}, after ${_after:-?})"
		fi
		if [ -n "$_target" ]; then
			ssh_guest "busctl set-property $PID1_LOG s $_target" >/dev/null 2>&1
			expect "boot 2: role marker moved aside: PID 1's log target is restored to $_target" "s \"$_target\"" \
				"$(ssh_guest "busctl get-property $PID1_LOG" 2>/dev/null | tr -d '\r')"
		fi
		expect "boot 2: role marker moved aside: nothing runs bao (pidof bao)" rc=1 "$(ssh_guest 'pidof bao; echo rc=$?' 2>/dev/null)"
		expect "boot 2: role marker moved aside: no LISTEN socket on port 8200" "" \
			"$(ssh_guest 'cat /proc/net/tcp /proc/net/tcp6' 2>/dev/null | listening_sockets | grep ':8200$')"
		ssh_guest "mv $ROLE.smoke-aside $ROLE && systemctl restart openbao.service" >/dev/null 2>&1
		expect "boot 2: role marker restored: openbao.service is active again" active \
			"$(ssh_guest 'systemctl show openbao.service -p ActiveState --value' 2>/dev/null)"
		ssh_guest "rm -rf $GUEST_PKI" >/dev/null 2>&1
	fi
	if ! ssh_guest 'systemctl is-active docker' >/dev/null 2>&1; then
		ssh_guest 'journalctl -b -u docker --no-pager | tail -15' 2>&1 | sed 's/^/    docker: /'
	fi
	# Roll back without committing.
	if [ "$ARCH" = amd64 ]; then
		ssh_guest 'rauc status mark-bad booted' 2>&1 | sed 's/^/    rauc: /'
	fi
	poweroff_guest
else
	fail "the updated slot did not come up"
fi

# ----------------------------------------------------------- 3: rollback --
echo "== boot 3: rollback"
if [ "$ARCH" = arm64 ]; then
	ALL_PART="$(autoboot_part all)"
	expect "the uncommitted trial leaves normal boot on partition 2" 2 "$ALL_PART"
	expect "slot A's boot partition is untouched by the update" "$A_BOOT_BEFORE" "$(part_hash "$DISK" 2)"
	arm64_load_slot "${ALL_PART:-2}"
fi
if boot 3; then
	expect "boot 3: running slot" A "$(cmdline_slot)"
	expect "boot 3: running kernel is slot A's own" "$OLD_ID" "$(running_id)"
	expect "boot 3: image version" "$OLD_VERSION" "$(ssh_guest 'cat /etc/rasputin/image-version' 2>/dev/null)"
	expect "boot 3: docker active" active "$(ssh_guest 'systemctl is-active docker' 2>/dev/null)"
	expect "boot 3: docker0 exists" yes "$(guest_yes 'ip link show docker0')"
	poweroff_guest
else
	fail "slot A did not come back after the rollback"
fi

# No key material from the store harness on any console (TC-756-24): no PEM
# private-key text, and no line of any key file's base64. Each line is a
# pattern file for grep -f, so no value is printed or put on a command line.
if [ -d "$WORK/store-pki" ]; then
	_pem="$(cat "$WORK"/console-*.log 2>/dev/null | grep -c 'PRIVATE KEY')"
	_hits=0
	for k in "$WORK"/store-pki/*.key; do
		[ -f "$k" ] || continue
		grep -v '^-----' "$k" | while IFS= read -r _l; do
			printf '%s\n' "$_l" >"$WORK/store-pki/needle"
			if cat "$WORK"/console-*.log 2>/dev/null | grep -q -F -f "$WORK/store-pki/needle"; then echo hit; fi
		done
	done >"$WORK/store-pki/hits"
	_hits="$(grep -c hit "$WORK/store-pki/hits")"
	expect "the consoles hold no PEM private-key text and no line of the harness's keys (counts)" "0 0" "$_pem $_hits"
fi

echo "== consoles: $WORK/console-{1,2,3}.log"
if [ "$FAILS" -gt 0 ]; then
	echo "update-smoke ($ARCH, from $OLD_VERSION): $FAILS assertion(s) failed"
	exit 1
fi
echo "update-smoke ($ARCH, from $OLD_VERSION): all assertions passed"
