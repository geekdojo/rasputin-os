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
#      runs it. Boot 2 is where these live because it is the only boot of THIS
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
# the first). Every wait is a poll on a checkable fact with a hard try count.
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

rm -rf "$WORK"
mkdir -p "$WORK"
DISK="$WORK/disk.img"
KEY="$WORK/id_ed25519"
QPID=""
cleanup() {
	[ -n "$QPID" ] && kill "$QPID" 2>/dev/null
	# The key is throwaway, but it is a private key: it does not outlive the run.
	rm -f "$KEY" "$KEY.pub" "$DISK" "$WORK/bundle.vfat" "$WORK"/*.bin
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

echo "== consoles: $WORK/console-{1,2,3}.log"
if [ "$FAILS" -gt 0 ]; then
	echo "update-smoke ($ARCH, from $OLD_VERSION): $FAILS assertion(s) failed"
	exit 1
fi
echo "update-smoke ($ARCH, from $OLD_VERSION): all assertions passed"
