#!/bin/sh
#
# rpi-tryboot-backend.sh — RAUC custom bootloader backend for Raspberry Pi.
#
# The Pi has no official RAUC bootloader backend. This drives the firmware's
# one-shot `tryboot` flag the CANONICAL way (Rtone/Bootlin/HAOS): A/B at the
# BOOTLOADER stage via `autoboot.txt` `boot_partition` switching. The image has a
# SEPARATE selector partition + two boot slots, each a complete boot env that
# statically roots its own slot:
#   partition 1 = selector (label RASPUTIN-FW) → autoboot.txt + seed + slot state
#   partition 2 = boot-a   (label RASPUTIN-A)  → rootfs-0 → bootname A
#   partition 3 = boot-b   (label RASPUTIN-B)  → rootfs-1 → bootname B
# The firmware reads autoboot.txt from the selector (p1, mounted rw at
# /run/rasputin-seed) and loads start4.elf + config.txt + kernel from the slot it
# names (p2/p3) — boot_partition never points at p1, so p1 needs no kernel:
#   [all]     boot_partition=N  → the COMMITTED slot   (normal boot)
#   [tryboot] boot_partition=M  → the CANDIDATE slot    (one-shot `tryboot` reboot)
# This is portable across Pi 4 (EEPROM → start4.elf) + Pi 5 (unified EEPROM) —
# unlike the config.txt `[tryboot]` cmdline filter, which the Pi 4 ignored.
#
# THE ROLLBACK IS THE ONE-SHOT: a trial boots once. If it reaches mark-good we
# COMMIT (promote [all] boot_partition to the candidate). If it panics/hangs
# first, the spent one-shot falls back to [all] on the next boot.
#
# "Am I running the trial?" — proxy: a trial is armed for the INACTIVE slot, so
# if the running slot (rauc.slot= on /proc/cmdline, baked into each boot FAT's
# cmdline.txt) equals the pending slot, the firmware loaded the candidate
# partition → we're in the trial. On a normal boot the running slot is the
# committed one (≠ pending).
#
# RAUC custom-backend protocol — invoked as `<script> <command> [args]`:
#   get-primary / get-current / get-state <bn> / set-primary <bn> /
#   set-state <bn> <good|bad>  + a Rasputin `reconcile` (rasputin-rauc-reconcile
#   .service, early each boot): a trial that did NOT come up as itself rolled
#   back → mark it bad + clear the marker.
#
# set -e is deliberately OFF: a spurious non-zero exit would make `rauc status`
# error. We guard explicitly and prefer "do nothing safely" over aborting.
set -u

SEED=/run/rasputin-seed                 # boot-a FAT (rw), run-rasputin\x2dseed.mount
AUTOBOOT="$SEED/autoboot.txt"           # the A/B selector (boot_partition per section)
PENDING="$SEED/rauc-trial.pending"     # bootname of an armed-but-uncommitted trial

# bootname (A|B) <-> boot partition number. Mirrors the genimage layout:
# selector=p1, boot-a=p2=rootfs-0=A, boot-b=p3=rootfs-1=B (autoboot.txt's
# boot_partition uses these numbers; MUST stay in sync with genimage.cfg order).
part_for() { case "$1" in A) echo 2 ;; B) echo 3 ;; *) return 1 ;; esac; }
name_for_part() { case "$1" in 2) echo A ;; 3) echo B ;; *) return 1 ;; esac; }

state_file() { echo "$SEED/rauc-slot-$1.state"; }   # A/B distinct on case-insensitive vfat
put() { printf '%s\n' "$2" > "$1.tmp" && mv "$1.tmp" "$1"; }

# Read boot_partition (a number) from the [<section>] block of autoboot.txt.
# Keys are unindented (column 0) in our autoboot.txt — anchored patterns keep
# this portable across busybox awk + gawk. Comment lines start with '#', so the
# section-header rule (`^\[`) never matches them.
get_section_partition() {
	awk -v sec="[$1]" '
		/^\[/ { cur=$1 }
		cur==sec && /^boot_partition=/ {
			v=$0; sub(/.*boot_partition=/, "", v); sub(/[^0-9].*/, "", v); print v; exit
		}' "$AUTOBOOT" 2>/dev/null
}

# Set boot_partition=<num> in the [<section>] block (preserves comments + the
# rest of the file).
set_section_partition() {
	awk -v sec="[$1]" -v val="$2" '
		/^\[/ { cur=$1 }
		cur==sec && /^boot_partition=/ { sub(/boot_partition=.*/, "boot_partition=" val) }
		{ print }' "$AUTOBOOT" > "$AUTOBOOT.tmp" && mv "$AUTOBOOT.tmp" "$AUTOBOOT"
}

committed_slot() { name_for_part "$(get_section_partition all)"; }

slot_in() {
	for tok in $(cat "$1" 2>/dev/null); do
		case "$tok" in rauc.slot=*) echo "${tok#rauc.slot=}"; return 0 ;; esac
	done
	return 1
}
current_slot() { slot_in /proc/cmdline; }

in_trial() {
	[ -f "$PENDING" ] || return 1
	[ "$(current_slot 2>/dev/null)" = "$(cat "$PENDING")" ]
}

cmd="${1:-}"
case "$cmd" in
	get-primary)
		# What boots next: the armed trial if one is pending, else the committed slot.
		if [ -f "$PENDING" ]; then cat "$PENDING"; else committed_slot; fi
		;;

	get-current)
		current_slot
		;;

	get-state)
		f="$(state_file "${2:?get-state needs a bootname}")"
		if [ -f "$f" ]; then cat "$f"; else echo good; fi   # default good
		;;

	set-primary)
		# Arm a trial of <bootname>: point [tryboot] at its partition + mark it
		# pending + presume good. [all] (the committed slot) is left as the
		# fallback. The trial happens on the NEXT `reboot "0 tryboot"` (no vcmailbox
		# in-tree to pre-arm a plain reboot); the update saga issues that reboot.
		bn="${2:?set-primary needs a bootname}"
		p="$(part_for "$bn")" || { echo "rpi-tryboot-backend: bad slot '$bn'" >&2; exit 1; }
		set_section_partition tryboot "$p"
		put "$PENDING" "$bn"
		put "$(state_file "$bn")" good
		sync
		;;

	set-state)
		bn="${2:?set-state needs a bootname}"; st="${3:?set-state needs a state}"
		put "$(state_file "$bn")" "$st"
		# Commit-on-good: RAUC marking the slot we're TRIALLING good promotes it to
		# the committed slot ([all] boot_partition), so the next normal boot stays
		# here. (mark-good runs from rasputin-mark-good.service once userspace is up.)
		if [ "$st" = good ] && in_trial && [ "$(cat "$PENDING")" = "$bn" ]; then
			set_section_partition all "$(part_for "$bn")"
			rm -f "$PENDING"
		fi
		sync
		;;

	reconcile)
		# Early each boot, before mark-good. A spent one-shot (trial never taken,
		# or aborted) falls back to the COMMITTED slot → mark the candidate bad +
		# clear the marker.
		#
		# Detect the rollback CONFIDENTLY: we rolled back iff we're running the
		# committed slot while a trial is pending. The earlier test was
		# `! in_trial` (current_slot != candidate), which also fired on an
		# *ambiguous* read — and once, at a cold boot, it wrongly cleared a VALID
		# trial (current_slot read as not-the-candidate for a moment before the
		# state settled; 2026-06-29, buildroot-os backlog). Comparing against
		# committed_slot fails safe: a candidate boot has current==candidate!=committed
		# (kept), and an empty/unreadable current_slot never equals committed (kept).
		# We only ever clear when current_slot is definitively the committed slot.
		if [ -f "$PENDING" ]; then
			cur="$(current_slot 2>/dev/null)"
			com="$(committed_slot 2>/dev/null)"
			if [ -n "$cur" ] && [ "$cur" = "$com" ]; then
				put "$(state_file "$(cat "$PENDING")")" bad
				rm -f "$PENDING"
				sync
			fi
		fi
		;;

	*)
		echo "rpi-tryboot-backend: unsupported command '$cmd'" >&2
		exit 1
		;;
esac
