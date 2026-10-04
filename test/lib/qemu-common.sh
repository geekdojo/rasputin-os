#!/bin/sh
#
# qemu-common.sh — what test/boot-smoke.sh and test/update-smoke.sh share about
# booting a Rasputin image under QEMU. Sourced, never run.
#
# One copy because the two must not drift: how the seed partition is found,
# which OVMF file is used, and the per-arch machine/CPU/disk/NIC line are the
# details that decide whether a guest boots at all, and a fix to one script
# that never reached the other would turn a real regression into a "flaky"
# smoke. See boot-smoke.sh for the reasoning behind each QEMU option; it is
# kept there, next to the assertions it serves.
#
# Needs: sfdisk, jq, timeout, and qemu-system-x86_64 / qemu-system-aarch64.

# part_offset IMG N — byte offset of partition number N (MBR or GPT; logical
# MBR partitions count from 5, as the kernel numbers them). Empty if absent.
part_offset() {
	sfdisk -J "$1" | jq -r --arg n "$2" '
		.partitiontable.partitions[]
		| select(.node | test("[^0-9]" + $n + "$"))
		| .start * 512'
}

# seed_offset IMG — byte offset of the provisioning seed FAT, on both tables:
#   n100 — GPT: the seed is Microsoft basic data (EBD0A0A2-…), deliberately NOT
#          the EFI System partition, which Windows and macOS hide from the user.
#   rpi  — MBR: the selector FAT is type "c" + bootable. It is the ONLY bootable
#          entry in that table (boot-a/boot-b are type "c" as well but carry no
#          boot flag), so the pair is unambiguous.
seed_offset() {
	sfdisk -J "$1" | jq -r '
		.partitiontable.partitions[]
		| select(((.type | ascii_upcase) == "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7")
		      or ((.type | ascii_downcase) == "c" and (.bootable == true)))
		| .start * 512' | head -1
}

# find_ovmf — set OVMF_CODE and OVMF_VARS. Ubuntu's ovmf package renamed the
# firmware files (the un-suffixed OVMF_CODE.fd / OVMF_VARS.fd are gone on
# 24.04+; the 4M variants are the modern names, and the secboot ones require
# signed bootloaders, which our GRUB isn't). Pick whichever non-secboot variant
# is installed. Returns 1 when there is none.
find_ovmf() {
	OVMF_CODE=""; OVMF_VARS=""
	for f in /usr/share/OVMF/OVMF_CODE*.fd; do
		case "$f" in *secboot*) continue ;; esac
		[ -f "$f" ] || continue; OVMF_CODE="$f"; break
	done
	for f in /usr/share/OVMF/OVMF_VARS*.fd; do
		case "$f" in *secboot*) continue ;; esac
		[ -f "$f" ] || continue; OVMF_VARS="$f"; break
	done
	[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ]
}

# qemu_exec ARCH IMG BUDGET LOG HOSTFWDS [extra qemu args...] — replace the
# calling (sub)shell with QEMU, bounded by BUDGET seconds, console to LOG.
#   HOSTFWDS   comma-joined "hostfwd=..." entries for the user-mode NIC.
#   amd64      needs OVMF_CODE and VARS_FD (a writable copy of OVMF_VARS).
#   arm64      needs QEMU_KERNEL and QEMU_APPEND: `virt` has no Pi firmware,
#              so the caller reads a boot slot's kernel and cmdline itself.
#   QEMU_DISK2 (optional) a second raw disk, attached the same way as the first.
qemu_exec() {
	_arch=$1 _img=$2 _budget=$3 _log=$4 _fwd=$5
	shift 5
	case "$_arch" in
	amd64)
		if [ -n "${QEMU_DISK2:-}" ]; then
			set -- -drive file="$QEMU_DISK2",format=raw,if=virtio "$@"
		fi
		exec timeout "$_budget" qemu-system-x86_64 \
			-machine q35 -m 2048 -smp 2 -cpu max -nographic \
			-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
			-drive if=pflash,format=raw,file="$VARS_FD" \
			-drive file="$_img",format=raw,if=virtio \
			-nic "user,model=virtio-net-pci,$_fwd" \
			-serial mon:stdio "$@" > "$_log" 2>&1
		;;
	arm64)
		if [ -n "${QEMU_DISK2:-}" ]; then
			set -- -drive file="$QEMU_DISK2",format=raw,if=none,id=hd1 -device virtio-blk-pci,drive=hd1 "$@"
		fi
		exec timeout "$_budget" qemu-system-aarch64 \
			-machine virt,gic-version=3 -accel tcg -m 2048 -smp 2 -cpu cortex-a72 -nographic \
			-kernel "$QEMU_KERNEL" -append "$QEMU_APPEND" \
			-drive file="$_img",format=raw,if=none,id=hd0 -device virtio-blk-pci,drive=hd0 \
			-netdev "user,id=n0,$_fwd" \
			-device virtio-net-pci,netdev=n0,romfile= \
			-serial mon:stdio "$@" > "$_log" 2>&1
		;;
	*)
		echo "qemu_exec: unknown arch '$_arch'" >&2
		return 1
		;;
	esac
}
