#!/bin/sh
#
# rpi-family-dtbs.sh — check that every Raspberry Pi 4 and Pi 5 family device
# tree the rpi image supports is built and shipped (geekdojo/geekdojo-brain#1061).
#
#   usage: test/rpi-family-dtbs.sh defconfig <family list> <defconfig>
#          test/rpi-family-dtbs.sh image     <family list> <buildroot output dir>
#
#   <family list>  board/rasputin/rpi/family-dtbs.txt: "<dtb basename> <board
#                  name>" per line, '#' comments and blank lines ignored.
#   defconfig      every listed device tree is named, as broadcom/<dtb>, in the
#                  defconfig's BR2_LINUX_KERNEL_INTREE_DTS_NAME (ci.yml, on
#                  every PR, against configs/rasputin_rpi_defconfig).
#   image          every listed <dtb>.dtb is at the FAT root of the three places
#                  a board boots from: the bundle's boot.vfat (what an update
#                  ships) and partitions 2 and 3 of the flash image (boot slots
#                  A and B, what a user flashes) — release.yml, after the build.
#
# WHY. The Pi firmware picks the device tree by board. A board whose device tree
# is missing does not boot at all: on 2026-11-03 a CM5 Lite stopped at
# 'Device-tree file "bcm2712-rpi-cm5l-cm5io.dtb" not found'.
#
# Every miss is reported, then the script exits 1. A missing or empty input (no
# list, a list with no rows, a row with no board name, no DTS line, no FAT, no
# image or two, no partition, no mcopy) is a failure, never a skip.
#
# Tools (image mode): mcopy from the build's own <output>/host/bin (the rpi
# defconfig sets BR2_PACKAGE_HOST_MTOOLS), with no PATH fallback, so the check
# reads the FATs with the mtools that wrote them. sfdisk and jq for the
# partition offsets (part_offset in test/lib/qemu-common.sh).
set -u

USAGE="usage: rpi-family-dtbs.sh <defconfig|image> <family list> <defconfig|output dir>"
MODE="${1:?$USAGE}"
LIST="${2:?$USAGE}"
TARGET="${3:?$USAGE}"
REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

FAILS=0
bad() { echo "::error::rpi-family-dtbs: $*"; FAILS=$((FAILS + 1)); }
die() { echo "::error::rpi-family-dtbs: $*"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- the family list ------------------------------------------------------------
# Parsed into $TMP/family: "<dtb>\t<board>" per row.
[ -f "$LIST" ] || die "The family list $LIST does not exist."
TAB=$(printf '\t')
: > "$TMP/family"
line_no=0
while IFS= read -r line || [ -n "$line" ]; do
	line_no=$((line_no + 1))
	line="${line%%#*}"
	# shellcheck disable=SC2086 # splitting the row into its words is the point
	set -- $line
	[ $# -gt 0 ] || continue
	dtb="$1"; shift
	if [ $# -eq 0 ]; then
		die "Line $line_no of the family list $LIST names the device tree $dtb but no board."
	fi
	printf '%s\t%s\n' "$dtb" "$*" >> "$TMP/family"
done < "$LIST"
COUNT=$(wc -l < "$TMP/family" | tr -d ' ')
[ "$COUNT" -gt 0 ] || die "The family list $LIST has no boards in it, so there is nothing to check."

# check_present WHERE DESCRIPTION PRESENT_FILE SUFFIX — one error per listed
# device tree not in PRESENT_FILE (one basename per line, whole-line match, so
# bcm2711-rpi-cm4 is not present just because bcm2711-rpi-cm4-io is), else one
# ok line. SUFFIX is how the name is shown: ".dtb" for a file on a FAT.
check_present() {
	_where="$1"; _what="$2"; _present="$3"; _sfx="$4"; _missing=0
	while IFS="$TAB" read -r _dtb _board; do
		if ! grep -qxF -- "$_dtb" "$_present"; then
			bad "The $_board device tree $_dtb$_sfx $_what $_where."
			_missing=$((_missing + 1))
		fi
	done < "$TMP/family"
	if [ "$_missing" -eq 0 ]; then
		echo "ok  $_where: $COUNT of $COUNT family device trees"
	fi
}

case "$MODE" in
defconfig)
	[ -f "$TARGET" ] || die "The defconfig $TARGET does not exist."
	dts_line=$(grep '^BR2_LINUX_KERNEL_INTREE_DTS_NAME=' "$TARGET" | tail -1)
	[ -n "$dts_line" ] || die "The defconfig $TARGET has no BR2_LINUX_KERNEL_INTREE_DTS_NAME line, so it builds no device trees."
	dts="${dts_line#*=}"
	dts=$(printf '%s' "$dts" | tr -d '"')
	# One name per line, broadcom/ stripped; check_present matches whole names.
	: > "$TMP/present"
	for name in $dts; do
		case "$name" in broadcom/*) echo "${name#broadcom/}" >> "$TMP/present" ;; esac
	done
	check_present "$TARGET" "is not named in BR2_LINUX_KERNEL_INTREE_DTS_NAME in" "$TMP/present" ""
	;;
image)
	O="$TARGET"
	MCOPY="$O/host/bin/mcopy"
	[ -x "$MCOPY" ] || die "The build's own mcopy is not at $MCOPY, so its boot FATs cannot be read."
	# shellcheck source=test/lib/qemu-common.sh
	. "$REPO/test/lib/qemu-common.sh"

	# read_fat WHERE FAT[@@OFFSET] — check one FAT's root.
	read_fat() {
		_dir="$TMP/fat-$(printf '%s' "$1" | tr -c 'a-z0-9' '_')"
		mkdir -p "$_dir"
		if ! MTOOLS_SKIP_CHECK=1 "$MCOPY" -n -i "$2" '::*.dtb' "$_dir/" 2> "$TMP/mcopy.err"; then
			if [ -z "$(ls -A "$_dir")" ]; then
				bad "No device tree could be read from $1, so none of the $COUNT family device trees is there."
				sed 's/^/    mcopy: /' "$TMP/mcopy.err"
				return
			fi
		fi
		: > "$_dir.list"
		for _f in "$_dir"/*.dtb; do
			[ -f "$_f" ] || continue
			_f="${_f##*/}"; echo "${_f%.dtb}" >> "$_dir.list"
		done
		check_present "$1" "is missing from" "$_dir.list" ".dtb"
	}

	BUNDLE_FAT="$O/images/bundle/boot.vfat"
	if [ -f "$BUNDLE_FAT" ]; then
		read_fat "bundle boot.vfat" "$BUNDLE_FAT"
	else
		bad "The bundle has no boot.vfat at $BUNDLE_FAT, so an update would ship no device trees."
	fi

	: > "$TMP/images"
	for f in "$O"/images/rasputin-os-rpi-*.img; do
		[ -f "$f" ] && echo "$f" >> "$TMP/images"
	done
	n_img=$(wc -l < "$TMP/images" | tr -d ' ')
	if [ "$n_img" -eq 0 ]; then
		bad "There is no flash image rasputin-os-rpi-*.img in $O/images."
	elif [ "$n_img" -gt 1 ]; then
		bad "There are $n_img flash images rasputin-os-rpi-*.img in $O/images, so which one ships is ambiguous."
	else
		IMG=$(cat "$TMP/images")
		for p in 2 3; do
			# part_offset is a pipe whose status is jq's, so a reader failure shows only
			# on stderr: keep it, to tell "could not read the table" from "no partition".
			off=$(part_offset "$IMG" "$p" 2> "$TMP/part.err")
			if [ -z "$off" ] && [ -s "$TMP/part.err" ]; then
				bad "The partition table of the flash image $IMG could not be read, so its boot slots cannot be checked."
				sed 's/^/    /' "$TMP/part.err"
				break
			elif [ -z "$off" ]; then
				bad "The flash image $IMG has no partition $p, the boot slot the firmware reads it from."
			else
				read_fat "image p$p" "$IMG@@$off"
			fi
		done
	fi
	;;
*)
	die "The mode $MODE is not one this script knows; use defconfig or image."
	;;
esac

if [ "$FAILS" -gt 0 ]; then
	echo "rpi-family-dtbs: $FAILS check(s) failed."
	exit 1
fi
echo "rpi-family-dtbs: all $COUNT family device trees are present."
