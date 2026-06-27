#!/bin/sh
#
# rpi-tryboot-backend.sh — RAUC custom bootloader backend for Raspberry Pi.
#
# The Pi has no official RAUC bootloader backend. This drives the firmware's
# one-shot `tryboot` flag (autoboot.txt `tryboot_a_b=1`) the same way the n100
# drives GRUB: only the ROOTFS is A/B (one shared boot FAT / kernel set), and
# the active slot is chosen by which cmdline the firmware loads —
#   cmdline.txt  → the COMMITTED slot   (loaded on a normal boot)
#   tryboot.txt  → the CANDIDATE slot   (loaded on a one-shot `tryboot` reboot,
#                  via config.txt's [tryboot] cmdline=tryboot.txt)
# Both live on the boot FAT, mounted rw at /run/rasputin-seed.
#
# THE ROLLBACK IS THE ONE-SHOT: a trial boots once. If it reaches mark-good we
# COMMIT (promote tryboot.txt → cmdline.txt). If it panics/hangs first, the
# one-shot is spent and the next boot falls back to cmdline.txt (the old slot).
#
# "Am I running the trial?"  We do NOT parse the binary /proc/device-tree
# tryboot prop — we use a reliable proxy: a trial is armed for the INACTIVE
# slot, so if the running slot (rauc.slot= on /proc/cmdline) equals the pending
# slot, the firmware must have loaded tryboot.txt → we're in the trial. On a
# normal boot the running slot is the committed one (≠ pending).
#
# RAUC custom-backend protocol — invoked as `<script> <command> [args]`:
#   get-primary                 → bootname that will boot (committed, or pending if armed)
#   get-current                 → bootname currently running (from /proc/cmdline)
#   get-state  <bootname>       → "good" | "bad"
#   set-primary <bootname>      → arm a trial of <bootname> (write tryboot.txt + marker)
#   set-state  <bootname> <st>  → record good/bad; good while trialling → COMMIT
# Plus one Rasputin extension, run early each boot by rasputin-rauc-reconcile.service:
#   reconcile                   → a trial that did NOT come up as itself was rolled
#                                 back → mark it bad + clear the marker.
#
# set -e is deliberately OFF: a spurious non-zero exit would make `rauc status`
# error. We guard explicitly and prefer "do nothing safely" over aborting.
set -u

SEED=/run/rasputin-seed                 # boot FAT (rw), run-rasputin\x2dseed.mount
CMDLINE="$SEED/cmdline.txt"             # committed slot cmdline (normal boot)
TRYBOOT="$SEED/tryboot.txt"            # candidate slot cmdline (one-shot tryboot)
PENDING="$SEED/rauc-trial.pending"     # bootname of an armed-but-uncommitted trial

# bootname (A|B) -> rootfs GPT PARTLABEL. Mirrors rauc-system.conf's slots.
label_for() {
	case "$1" in
		A) echo rootfs-0 ;;
		B) echo rootfs-1 ;;
		*) echo "rpi-tryboot-backend: unknown bootname '$1'" >&2; return 1 ;;
	esac
}

state_file() { echo "$SEED/rauc-slot-$1.state"; }   # A/B distinct on case-insensitive vfat

# Write a tiny control file atomically-ish (tmp + rename) on the vfat.
put() { printf '%s\n' "$2" > "$1.tmp" && mv "$1.tmp" "$1"; }

# bootname encoded as rauc.slot= in a cmdline file ($1) or /proc/cmdline.
slot_in() {
	for tok in $(cat "$1" 2>/dev/null); do
		case "$tok" in rauc.slot=*) echo "${tok#rauc.slot=}"; return 0 ;; esac
	done
	return 1
}
current_slot() { slot_in /proc/cmdline; }

# Are we running the armed trial? (running slot == pending slot — see header.)
in_trial() {
	[ -f "$PENDING" ] || return 1
	[ "$(current_slot 2>/dev/null)" = "$(cat "$PENDING")" ]
}

# tryboot.txt = cmdline.txt with root=PARTLABEL + rauc.slot swapped to <bootname>.
# Templating off the committed cmdline keeps console=/audit=/etc. in lockstep.
write_trial_cmdline() {
	lbl="$(label_for "$1")" || return 1
	sed -e "s#root=PARTLABEL=[^ ]*#root=PARTLABEL=$lbl#" \
	    -e "s#rauc\.slot=[^ ]*#rauc.slot=$1#" \
	    "$CMDLINE" > "$TRYBOOT.tmp" && mv "$TRYBOOT.tmp" "$TRYBOOT"
}

cmd="${1:-}"
case "$cmd" in
	get-primary)
		# What boots next: the armed trial if one is pending, else the committed slot.
		if [ -f "$PENDING" ]; then cat "$PENDING"; else slot_in "$CMDLINE"; fi
		;;

	get-current)
		current_slot
		;;

	get-state)
		f="$(state_file "${2:?get-state needs a bootname}")"
		if [ -f "$f" ]; then cat "$f"; else echo good; fi   # default good
		;;

	set-primary)
		# Arm a trial of <bootname>: stage its cmdline + mark it pending + presume
		# good (freshly installed). cmdline.txt (the committed slot) is left as the
		# fallback. The trial happens on the NEXT `reboot "0 tryboot"` (no vcmailbox
		# in-tree to pre-arm a plain reboot); the update saga issues that reboot.
		bn="${2:?set-primary needs a bootname}"
		write_trial_cmdline "$bn" || { echo "rpi-tryboot-backend: bad slot '$bn'" >&2; exit 1; }
		put "$PENDING" "$bn"
		put "$(state_file "$bn")" good
		sync
		;;

	set-state)
		bn="${2:?set-state needs a bootname}"; st="${3:?set-state needs a state}"
		put "$(state_file "$bn")" "$st"
		# Commit-on-good: RAUC marking the slot we're TRIALLING good promotes it to
		# the committed slot, so the next normal boot stays here. (mark-good runs
		# from rasputin-mark-good.service once our userspace is up.)
		if [ "$st" = good ] && in_trial && [ "$(cat "$PENDING")" = "$bn" ]; then
			cp "$TRYBOOT" "$CMDLINE.tmp" && mv "$CMDLINE.tmp" "$CMDLINE"
			rm -f "$PENDING"
		fi
		sync
		;;

	reconcile)
		# Early each boot, before mark-good. If a trial was armed but we did NOT
		# come up running it (one-shot spent on a failed trial, or a plain reboot
		# aborted the arm), it rolled back → mark that slot bad + clear the marker.
		if [ -f "$PENDING" ] && ! in_trial; then
			put "$(state_file "$(cat "$PENDING")")" bad
			rm -f "$PENDING"
			sync
		fi
		;;

	*)
		echo "rpi-tryboot-backend: unsupported command '$cmd'" >&2
		exit 1
		;;
esac
