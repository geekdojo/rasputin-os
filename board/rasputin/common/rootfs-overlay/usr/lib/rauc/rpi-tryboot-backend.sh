#!/bin/sh
#
# BRING-UP STUB — rpi (Raspberry Pi) RAUC custom bootloader backend.
#
# The Pi has no official RAUC bootloader backend; the real one will drive the
# firmware's autoboot.txt `tryboot_a_b` + the one-shot `tryboot` flag (rewrite
# boot_partition on set-primary, arm a trial boot via `reboot "0 tryboot"`,
# confirm on mark-good). That lands AFTER a basic Pi 5 boot is confirmed on the
# bench, together with the two-FAT A/B genimage layout.
#
# Until then this STUB makes `rauc status` succeed on a single-slot image
# (slot A = bootname "A", primary + good) so the agent's updater can query RAUC
# without erroring. It does NOT switch slots — an actual A/B update + rollback
# is not yet supported on the Pi. See os-images/buildroot-os.md §3 and the wiki
# backlog (os-images arm64/Pi parity).
#
# RAUC custom-backend protocol: invoked as `<script> <command> [args]`.
set -eu

cmd="${1:-}"
case "$cmd" in
	get-primary)
		# Bootname of the slot to boot. Single active slot → A.
		echo "A"
		;;
	get-state)
		# get-state <bootname> → "good" | "bad". Stub: always good.
		echo "good"
		;;
	set-primary)
		# set-primary <bootname> → no-op (no real A/B switching yet).
		:
		;;
	set-state)
		# set-state <bootname> <good|bad> → no-op.
		:
		;;
	*)
		echo "rpi-tryboot-backend (stub): unsupported command '$cmd'" >&2
		exit 1
		;;
esac
