#!/bin/sh
#
# Tests for board/rasputin/common/rauc-bundle-hook.sh — the RAUC bundle hook
# that installs a slot's kernel and boot files with its rootfs
# (geekdojo/geekdojo-brain#807).
#
# Why. The hook runs as root, on the device, from inside the bundle, under
# whatever image the device is running — and it writes boot partitions. A bug
# here either strands a slot on the wrong kernel (the defect it exists to fix)
# or writes a boot partition it should not touch. The QEMU update smoke
# (test/update-smoke.sh) runs it for real on one path per arch; this suite pins
# every branch, against fake partitions:
#   rpi   slot A and slot B land on p2 and p3 and nowhere else; the read-back;
#         the slot's cmdline and the boot marker; the BMC-host policy (serial
#         console stripped, console=tty1 kept); a payload whose checksum does
#         not match; a boot partition too small (by file size and by sysfs); a
#         missing boot partition; the running slot; a mounted target.
#   n100  /bzImage-<slot> written, the legacy /bzImage left alone; grub.cfg
#         replaced only when it differs; the ESP not mounted; the ESP too full.
#   both  a compatible mismatch and an empty compatible are refused with exit
#         10 (RAUC's "rejected"); an unknown command fails.
#
# Fakes: RASPUTIN_HOOK_ROOT points the hook at a scratch tree (dev, proc, sys,
# run, var/lib/rasputin). `mount`/`umount` are stubs that swap the mount point
# for a directory standing in for the partition's filesystem, and `df` is a
# stub where a case needs a full ESP. Everything else the hook runs is real —
# and, under the busybox_applets shell, it is busybox's, as on the device.
#
# Shells: each case runs under every shell in TEST_SHELLS (default: whichever
# of sh, dash and bash are installed) and once more under busybox sh with
# busybox's applets ahead of PATH. REQUIRE_BUSYBOX=1 (CI sets it) turns a
# missing busybox into a failure rather than a silent skip.
#
# Run:  sh test/boot-hook-test.sh
set -u

REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
HOOK="$REPO/board/rasputin/common/rauc-bundle-hook.sh"
POLICY="$REPO/board/rasputin/common/rootfs-overlay/usr/lib/rasputin/bmc/cmdline-policy.sh"
for f in "$HOOK" "$POLICY" "$REPO/board/rasputin/rpi/cmdline.txt" "$REPO/board/rasputin/rpi/cmdline-b.txt" "$REPO/board/rasputin/n100/grub.cfg"; do
	[ -f "$f" ] || { echo "missing: $f" >&2; exit 2; }
done

if [ -z "${TEST_SHELLS:-}" ]; then
	TEST_SHELLS=""
	for s in sh dash bash; do
		command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"
	done
fi

TMP=$(mktemp -d)
BUSYBOX_DIR=""
if command -v busybox >/dev/null 2>&1; then
	BUSYBOX_DIR="$TMP/busybox"
	mkdir -p "$BUSYBOX_DIR"
	for applet in awk cat cmp cp cut dd grep head mkdir mv readlink rm sed sha256sum sync tr wc; do
		printf '#!/bin/sh\nexec busybox %s "$@"\n' "$applet" > "$BUSYBOX_DIR/$applet"
		chmod 0755 "$BUSYBOX_DIR/$applet"
	done
	TEST_SHELLS="$TEST_SHELLS busybox_applets"
elif [ -n "${REQUIRE_BUSYBOX:-}" ]; then
	echo "REQUIRE_BUSYBOX is set but busybox is not installed" >&2
	exit 2
fi
trap 'rm -rf "$TMP"' EXIT

# ---- stubs: mount, umount, df -----------------------------------------------
# mount -t vfat -o rw DEV MNT: MNT becomes a symlink to $FAKEFS/<DEV's node
# name>, the directory standing in for that partition's filesystem.
STUBS="$TMP/stubs"
mkdir -p "$STUBS"
cat > "$STUBS/mount" <<'EOF'
#!/bin/sh
for a in "$@"; do dev=$mnt; mnt=$a; done
real=$(readlink -f "$dev") || exit 32
mkdir -p "$FAKEFS/${real##*/}" || exit 32
rmdir "$mnt" && ln -s "$FAKEFS/${real##*/}" "$mnt"
EOF
cat > "$STUBS/umount" <<'EOF'
#!/bin/sh
[ -L "$1" ] || exit 32
rm "$1" && mkdir "$1"
EOF
# df -Pk DIR: available KiB from $FAKE_DF_AVAIL when set, else the real df.
cat > "$STUBS/df" <<'EOF'
#!/bin/sh
if [ -n "${FAKE_DF_AVAIL:-}" ]; then
	echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
	echo "/dev/fake 262144 0 $FAKE_DF_AVAIL 1% /run/rasputin-esp"
	exit 0
fi
PATH=$(echo "$PATH" | sed "s#^$STUBS_DIR:##") exec df "$@"
EOF
chmod 0755 "$STUBS/mount" "$STUBS/umount" "$STUBS/df"

pass=0
fail=0
check() {
	_label=$1 _want=$2 _got=$3
	if [ "$_want" = "$_got" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$_label" "$_want" "$_got" >&2
	fi
}
contains() { # contains LABEL NEEDLE HAYSTACK
	case "$3" in
		*"$2"*) pass=$((pass + 1)) ;;
		*) fail=$((fail + 1)); printf '  FAIL %s\n       want substring: %s\n       got: %s\n' "$1" "$2" "$3" >&2 ;;
	esac
}
lacks() { # lacks LABEL NEEDLE HAYSTACK
	case "$3" in
		*"$2"*) fail=$((fail + 1)); printf '  FAIL %s\n       must not contain: %s\n       got: %s\n' "$1" "$2" "$3" >&2 ;;
		*) pass=$((pass + 1)) ;;
	esac
}
hash_of() { if [ -f "$1" ]; then sha256sum "$1" | cut -d' ' -f1; else echo absent; fi; }

VERSION=2026.10.1-dev.999

# make_bundle DIR SKU — a bundle directory as post-image.sh lays it out.
make_bundle() {
	_b=$1
	mkdir -p "$_b"
	cp "$HOOK" "$_b/hook.sh"
	chmod 0755 "$_b/hook.sh"
	printf '%s\n' "$VERSION" > "$_b/boot-version"
	case "$2" in
		rpi)
			# A stand-in boot FAT: 32 KiB of non-repeating bytes, so a short
			# or misplaced write cannot hash the same.
			awk 'BEGIN { for (i = 0; i < 2048; i++) printf "%015d\n", i * 7919 }' > "$_b/boot.vfat"
			cp "$REPO/board/rasputin/rpi/cmdline.txt" "$_b/cmdline-A.txt"
			cp "$REPO/board/rasputin/rpi/cmdline-b.txt" "$_b/cmdline-B.txt"
			cp "$POLICY" "$_b/cmdline-policy.sh"
			(cd "$_b" && sha256sum boot.vfat cmdline-A.txt cmdline-B.txt cmdline-policy.sh boot-version > boot-payload.sha256)
			;;
		n100)
			awk 'BEGIN { for (i = 0; i < 1024; i++) printf "%015d\n", i * 104729 }' > "$_b/bzImage"
			cp "$REPO/board/rasputin/n100/grub.cfg" "$_b/grub.cfg"
			(cd "$_b" && sha256sum bzImage grub.cfg boot-version > boot-payload.sha256)
			;;
	esac
}

# make_root DIR SKU RUNNING_SLOT — the device side.
make_root() {
	_r=$1
	mkdir -p "$_r/proc/sys/vm" "$_r/run" "$_r/var/lib/rasputin" "$_r/dev/disk/by-partuuid" "$_r/sys/class/block"
	: > "$_r/proc/sys/vm/drop_caches"
	printf 'root=PARTUUID=52415350-05 rootfstype=squashfs ro rauc.slot=%s audit=0\n' "$3" > "$_r/proc/cmdline"
	case "$2" in
		rpi)
			# 64 KiB "partitions", filled with a pattern distinct from the payload.
			for n in 2 3; do
				awk -v n="$n" 'BEGIN { for (i = 0; i < 4096; i++) printf "%015d\n", n }' > "$_r/dev/mmcblk0p$n"
				ln -s "../../mmcblk0p$n" "$_r/dev/disk/by-partuuid/52415350-0$n"
			done
			printf '/dev/mmcblk0p5 / squashfs ro 0 0\n/dev/mmcblk0p1 /run/rasputin-seed vfat rw 0 0\n' > "$_r/proc/mounts"
			;;
		n100)
			mkdir -p "$_r/run/rasputin-esp/EFI/BOOT"
			echo "legacy grub.cfg" > "$_r/run/rasputin-esp/EFI/BOOT/grub.cfg"
			echo "legacy shared kernel" > "$_r/run/rasputin-esp/bzImage"
			printf '/dev/sda3 / squashfs ro 0 0\n/dev/sda1 /run/rasputin-esp vfat rw 0 0\n' > "$_r/proc/mounts"
			;;
	esac
}

# run SHELL BUNDLE ROOT CMD [VAR=VALUE...] — run the hook with the given
# environment; prints its combined output then "|rc=<status>".
run() {
	_sh=$1 _bundle=$2 _root=$3 _cmd=$4
	shift 4
	_fakefs="$_root.fakefs"
	mkdir -p "$_fakefs"
	if [ "$_sh" = busybox_applets ]; then
		_out=$(env PATH="$STUBS:$BUSYBOX_DIR:$PATH" STUBS_DIR="$STUBS" FAKEFS="$_fakefs" \
			RASPUTIN_HOOK_ROOT="$_root" "$@" busybox sh "$_bundle/hook.sh" "$_cmd" 2>&1)
	else
		_out=$(env PATH="$STUBS:$PATH" STUBS_DIR="$STUBS" FAKEFS="$_fakefs" \
			RASPUTIN_HOOK_ROOT="$_root" "$@" "$_sh" "$_bundle/hook.sh" "$_cmd" 2>&1)
	fi
	printf '%s|rc=%s' "$_out" "$?"
}
rc_of() { echo "${1##*|rc=}"; }
# check_rc LABEL WANT OUT — like check on the exit status, and on a mismatch
# prints the hook's own output, which says why.
check_rc() {
	_got_rc="$(rc_of "$3")"
	check "$1" "$2" "$_got_rc"
	[ "$2" = "$_got_rc" ] || printf '       hook said: %s\n' "${3%|rc=*}" >&2
}

RPI_ENV="RAUC_SYSTEM_COMPATIBLE=rasputin-rpi-arm64"
N100_ENV="RAUC_SYSTEM_COMPATIBLE=rasputin-n100"

for SH in $TEST_SHELLS; do
	echo "== $SH"
	C="$TMP/$SH"
	mkdir -p "$C"

	# ---------------------------------------------------------------- rpi ----
	# Slot B from a node running A: p3 gets the boot FAT, cmdline-B, the marker;
	# p2 is not touched.
	make_bundle "$C/b1" rpi; make_root "$C/r1" rpi A
	p2_before=$(hash_of "$C/r1/dev/mmcblk0p2")
	out=$(run "$SH" "$C/b1" "$C/r1" install-check "$RPI_ENV" RAUC_MF_COMPATIBLE=rasputin-rpi-arm64)
	check_rc "rpi install-check passes on a sound device" 0 "$out"
	out=$(run "$SH" "$C/b1" "$C/r1" slot-post-install "$RPI_ENV" RAUC_SLOT_BOOTNAME=B)
	check_rc "rpi slot B: exit 0" 0 "$out"
	check "rpi slot B: p3 carries boot.vfat" "$(hash_of "$C/b1/boot.vfat")" "$(hash_of "$C/r1/dev/mmcblk0p3")"
	check "rpi slot B: p2 untouched" "$p2_before" "$(hash_of "$C/r1/dev/mmcblk0p2")"
	check "rpi slot B: cmdline.txt is cmdline-B" "$(cat "$C/b1/cmdline-B.txt")" "$(cat "$C/r1.fakefs/mmcblk0p3/cmdline.txt" 2>/dev/null)"
	check "rpi slot B: boot marker" "$VERSION" "$(cat "$C/r1.fakefs/mmcblk0p3/rasputin-boot-version" 2>/dev/null)"
	check "rpi slot B: no temp files left" "" "$(ls "$C/r1.fakefs/mmcblk0p3" | grep '\.tmp$')"
	check "rpi slot B: mount point released" "no" "$([ -L "$C/r1/run/rasputin-bundle-hook" ] && echo yes || echo no)"
	check "rpi slot B: page cache dropped before the read-back" "3" "$(cat "$C/r1/proc/sys/vm/drop_caches")"

	# Slot A from a node running B: the mirror image.
	make_bundle "$C/b2" rpi; make_root "$C/r2" rpi B
	p3_before=$(hash_of "$C/r2/dev/mmcblk0p3")
	out=$(run "$SH" "$C/b2" "$C/r2" slot-post-install "$RPI_ENV" RAUC_SLOT_BOOTNAME=A)
	check_rc "rpi slot A: exit 0" 0 "$out"
	check "rpi slot A: p2 carries boot.vfat" "$(hash_of "$C/b2/boot.vfat")" "$(hash_of "$C/r2/dev/mmcblk0p2")"
	check "rpi slot A: p3 untouched" "$p3_before" "$(hash_of "$C/r2/dev/mmcblk0p3")"
	check "rpi slot A: cmdline.txt is cmdline-A" "$(cat "$C/b2/cmdline-A.txt")" "$(cat "$C/r2.fakefs/mmcblk0p2/cmdline.txt" 2>/dev/null)"
	check "rpi slot A: boot marker" "$VERSION" "$(cat "$C/r2.fakefs/mmcblk0p2/rasputin-boot-version" 2>/dev/null)"

	# BMC host: the serial console comes out of the cmdline it writes; tty1 stays.
	make_bundle "$C/b3" rpi; make_root "$C/r3" rpi A
	: > "$C/r3/var/lib/rasputin/bmc-host"
	out=$(run "$SH" "$C/b3" "$C/r3" slot-post-install "$RPI_ENV" RAUC_SLOT_BOOTNAME=B)
	check_rc "rpi BMC host: exit 0" 0 "$out"
	cl=$(cat "$C/r3.fakefs/mmcblk0p3/cmdline.txt" 2>/dev/null)
	lacks "rpi BMC host: no serial console" "console=ttyS0" "$cl"
	contains "rpi BMC host: console=tty1 kept" "console=tty1" "$cl"
	contains "rpi BMC host: still roots slot B" "root=PARTUUID=52415350-06" "$cl"
	contains "rpi BMC host: says so" "BMC host" "$out"

	# A payload that does not match its checksums: refused before any write.
	make_bundle "$C/b4" rpi; make_root "$C/r4" rpi A
	echo tampered >> "$C/b4/boot.vfat"
	p3_before=$(hash_of "$C/r4/dev/mmcblk0p3")
	out=$(run "$SH" "$C/b4" "$C/r4" install-check "$RPI_ENV" RAUC_MF_COMPATIBLE=rasputin-rpi-arm64)
	check_rc "rpi hash mismatch: install-check rejects (10)" 10 "$out"
	contains "rpi hash mismatch: install-check says why" "does not match its checksums" "$out"
	out=$(run "$SH" "$C/b4" "$C/r4" slot-post-install "$RPI_ENV" RAUC_SLOT_BOOTNAME=B)
	check_rc "rpi hash mismatch: post-install fails" 1 "$out"
	check "rpi hash mismatch: p3 untouched" "$p3_before" "$(hash_of "$C/r4/dev/mmcblk0p3")"

	# A boot partition smaller than the boot FAT, by file size.
	make_bundle "$C/b5" rpi; make_root "$C/r5" rpi A
	head -c 4096 "$C/r5/dev/mmcblk0p3" > "$C/r5/p3.small" && mv "$C/r5/p3.small" "$C/r5/dev/mmcblk0p3"
	out=$(run "$SH" "$C/b5" "$C/r5" install-check "$RPI_ENV" RAUC_MF_COMPATIBLE=rasputin-rpi-arm64)
	check_rc "rpi too small: install-check rejects (10)" 10 "$out"
	contains "rpi too small: install-check names the slot" "slot B is 4096 bytes" "$out"
	out=$(run "$SH" "$C/b5" "$C/r5" slot-post-install "$RPI_ENV" RAUC_SLOT_BOOTNAME=B)
	check_rc "rpi too small: post-install fails" 1 "$out"
	check "rpi too small: p3 not written" 4096 "$(wc -c < "$C/r5/dev/mmcblk0p3" | tr -d ' ')"

	# ... and by the sysfs size of the real node, as on a device.
	make_bundle "$C/b6" rpi; make_root "$C/r6" rpi A
	mkdir -p "$C/r6/sys/class/block/mmcblk0p2"
	echo 8 > "$C/r6/sys/class/block/mmcblk0p2/size"
	out=$(run "$SH" "$C/b6" "$C/r6" install-check "$RPI_ENV" RAUC_MF_COMPATIBLE=rasputin-rpi-arm64)
	check_rc "rpi too small (sysfs): install-check rejects (10)" 10 "$out"
	contains "rpi too small (sysfs): sized from sysfs" "slot A is 4096 bytes" "$out"

	# A boot partition that does not exist.
	make_bundle "$C/b7" rpi; make_root "$C/r7" rpi A
	rm "$C/r7/dev/disk/by-partuuid/52415350-03"
	out=$(run "$SH" "$C/b7" "$C/r7" install-check "$RPI_ENV" RAUC_MF_COMPATIBLE=rasputin-rpi-arm64)
	check_rc "rpi missing partition: install-check rejects (10)" 10 "$out"
	contains "rpi missing partition: says which" "slot B" "$out"

	# The running slot's boot partition is never rewritten.
	make_bundle "$C/b8" rpi; make_root "$C/r8" rpi A
	p2_before=$(hash_of "$C/r8/dev/mmcblk0p2")
	out=$(run "$SH" "$C/b8" "$C/r8" slot-post-install "$RPI_ENV" RAUC_SLOT_BOOTNAME=A)
	check_rc "rpi running slot: refused" 1 "$out"
	check "rpi running slot: p2 untouched" "$p2_before" "$(hash_of "$C/r8/dev/mmcblk0p2")"

	# Nor is a mounted one.
	make_bundle "$C/b9" rpi; make_root "$C/r9" rpi A
	echo "/dev/mmcblk0p3 /run/rasputin-bootfat vfat rw 0 0" >> "$C/r9/proc/mounts"
	p3_before=$(hash_of "$C/r9/dev/mmcblk0p3")
	out=$(run "$SH" "$C/b9" "$C/r9" slot-post-install "$RPI_ENV" RAUC_SLOT_BOOTNAME=B)
	check_rc "rpi mounted target: refused" 1 "$out"
	check "rpi mounted target: p3 untouched" "$p3_before" "$(hash_of "$C/r9/dev/mmcblk0p3")"

	# --------------------------------------------------------------- both ----
	make_bundle "$C/b10" rpi; make_root "$C/r10" rpi A
	out=$(run "$SH" "$C/b10" "$C/r10" install-check "$RPI_ENV" RAUC_MF_COMPATIBLE=rasputin-n100)
	check_rc "compatible mismatch: rejected (10)" 10 "$out"
	contains "compatible mismatch: names both" "it is for 'rasputin-n100' and this system is 'rasputin-rpi-arm64'" "$out"
	out=$(run "$SH" "$C/b10" "$C/r10" install-check "$RPI_ENV")
	check_rc "empty bundle compatible: rejected (10)" 10 "$out"
	out=$(run "$SH" "$C/b10" "$C/r10" install-check RAUC_MF_COMPATIBLE=rasputin-other RAUC_SYSTEM_COMPATIBLE=rasputin-other)
	check_rc "unknown system: rejected (10)" 10 "$out"
	out=$(run "$SH" "$C/b10" "$C/r10" slot-pre-install "$RPI_ENV" RAUC_SLOT_BOOTNAME=B)
	check_rc "unknown hook command: fails" 1 "$out"
	out=$(run "$SH" "$C/b10" "$C/r10" slot-post-install "$RPI_ENV")
	check_rc "no RAUC_SLOT_BOOTNAME: fails" 1 "$out"

	# --------------------------------------------------------------- n100 ----
	# Slot B from a board flashed before per-slot kernels: bzImage-B written,
	# the shared legacy /bzImage left for slot A, grub.cfg replaced.
	make_bundle "$C/b11" n100; make_root "$C/r11" n100 A
	esp="$C/r11/run/rasputin-esp"
	legacy_before=$(hash_of "$esp/bzImage")
	out=$(run "$SH" "$C/b11" "$C/r11" install-check "$N100_ENV" RAUC_MF_COMPATIBLE=rasputin-n100)
	check_rc "n100 install-check passes on a sound device" 0 "$out"
	out=$(run "$SH" "$C/b11" "$C/r11" slot-post-install "$N100_ENV" RAUC_SLOT_BOOTNAME=B)
	check_rc "n100 slot B: exit 0" 0 "$out"
	check "n100 slot B: bzImage-B is the bundle's kernel" "$(hash_of "$C/b11/bzImage")" "$(hash_of "$esp/bzImage-B")"
	check "n100 slot B: no bzImage-A written" absent "$(hash_of "$esp/bzImage-A")"
	check "n100 slot B: legacy /bzImage untouched" "$legacy_before" "$(hash_of "$esp/bzImage")"
	check "n100 slot B: grub.cfg replaced" "$(hash_of "$C/b11/grub.cfg")" "$(hash_of "$esp/EFI/BOOT/grub.cfg")"
	contains "n100 slot B: says it replaced grub.cfg" "replacing the shared" "$out"
	check "n100 slot B: boot marker" "$VERSION" "$(cat "$esp/rasputin-boot-version-B" 2>/dev/null)"
	check "n100 slot B: no temp files left" "" "$(ls "$esp" "$esp/EFI/BOOT" | grep -E '\.(new|tmp)$')"

	# Slot A while A is running: refused. Then from B, with grub.cfg already
	# current: written, and grub.cfg is not rewritten.
	out=$(run "$SH" "$C/b11" "$C/r11" slot-post-install "$N100_ENV" RAUC_SLOT_BOOTNAME=A)
	check_rc "n100 running slot A: refused" 1 "$out"
	check "n100 running slot A: no bzImage-A written" absent "$(hash_of "$esp/bzImage-A")"
	printf 'root=PARTLABEL=rootfs-1 rauc.slot=B\n' > "$C/r11/proc/cmdline"
	out=$(run "$SH" "$C/b11" "$C/r11" slot-post-install "$N100_ENV" RAUC_SLOT_BOOTNAME=A)
	check_rc "n100 slot A: exit 0" 0 "$out"
	check "n100 slot A: bzImage-A is the bundle's kernel" "$(hash_of "$C/b11/bzImage")" "$(hash_of "$esp/bzImage-A")"
	lacks "n100 slot A: grub.cfg already current, not rewritten" "replacing the shared" "$out"

	# The ESP not mounted: refused.
	make_bundle "$C/b12" n100; make_root "$C/r12" n100 A
	printf '/dev/sda3 / squashfs ro 0 0\n' > "$C/r12/proc/mounts"
	out=$(run "$SH" "$C/b12" "$C/r12" install-check "$N100_ENV" RAUC_MF_COMPATIBLE=rasputin-n100)
	check_rc "n100 ESP not mounted: install-check rejects (10)" 10 "$out"
	out=$(run "$SH" "$C/b12" "$C/r12" slot-post-install "$N100_ENV" RAUC_SLOT_BOOTNAME=B)
	check_rc "n100 ESP not mounted: post-install fails" 1 "$out"
	check "n100 ESP not mounted: nothing written" absent "$(hash_of "$C/r12/run/rasputin-esp/bzImage-B")"

	# The ESP too full for the kernel.
	make_bundle "$C/b13" n100; make_root "$C/r13" n100 A
	out=$(run "$SH" "$C/b13" "$C/r13" install-check "$N100_ENV" RAUC_MF_COMPATIBLE=rasputin-n100 FAKE_DF_AVAIL=10)
	check_rc "n100 ESP full: install-check rejects (10)" 10 "$out"
	contains "n100 ESP full: says how much" "the ESP has 10 KiB free" "$out"

	# A tampered kernel: refused before anything is written.
	make_bundle "$C/b14" n100; make_root "$C/r14" n100 A
	echo tampered >> "$C/b14/bzImage"
	out=$(run "$SH" "$C/b14" "$C/r14" slot-post-install "$N100_ENV" RAUC_SLOT_BOOTNAME=B)
	check_rc "n100 hash mismatch: post-install fails" 1 "$out"
	check "n100 hash mismatch: nothing written" absent "$(hash_of "$C/r14/run/rasputin-esp/bzImage-B")"
	check "n100 hash mismatch: grub.cfg untouched" "legacy grub.cfg" "$(cat "$C/r14/run/rasputin-esp/EFI/BOOT/grub.cfg")"
done

echo "boot-hook: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
