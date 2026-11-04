#!/bin/sh
#
# Tests for test/rpi-family-dtbs.sh — the check that every Raspberry Pi 4 and
# Pi 5 family device tree is in the rpi defconfig and on every boot FAT a
# release ships (geekdojo/geekdojo-brain#1061).
#
# Why. A board whose device tree is missing does not boot at all, and nothing
# else in CI would notice: the QEMU smoke boots `virt`, which needs no Pi device
# tree. So the check itself must be right — a miss in exactly one place is
# named with its place, a prefix is not a match (bcm2711-rpi-cm4 vs -cm4-io),
# and every missing or empty input fails instead of passing vacuously.
#
# Fixtures are real: FATs made with mkfs.vfat and filled with mcopy, an MBR
# image laid out with sfdisk, read back by the script through part_offset.
# Needs mcopy, mdir, mkfs.vfat, sfdisk and jq; a missing tool fails the run, it is
# never a skip (ci.yml installs mtools, dosfstools and jq).
#
# Run:  sh test/rpi-family-dtbs-test.sh
set -u

REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$REPO/test/rpi-family-dtbs.sh"
LIST="$REPO/board/rasputin/rpi/family-dtbs.txt"
DEFCONFIG="$REPO/configs/rasputin_rpi_defconfig"
for f in "$SCRIPT" "$LIST" "$DEFCONFIG"; do
	[ -f "$f" ] || { echo "missing: $f" >&2; exit 2; }
done
for t in mcopy mdir mkfs.vfat sfdisk jq; do
	command -v "$t" >/dev/null 2>&1 || { echo "rpi-family-dtbs-test needs $t, which is not installed" >&2; exit 2; }
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
check() {
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); else
		fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3" >&2
	fi
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
rc_of() { echo "${1##*|rc=}"; }
errors() { printf '%s\n' "${1%|rc=*}" | grep -c '^::error::'; }

# run MODE LIST TARGET — the script's output, then "|rc=<status>".
run() { _out=$(sh "$SCRIPT" "$1" "$2" "$3" 2>&1); printf '%s|rc=%s' "$_out" "$?"; }

ALL="bcm2711-rpi-4-b
bcm2711-rpi-400
bcm2711-rpi-cm4
bcm2711-rpi-cm4-io
bcm2711-rpi-cm4s
bcm2712-rpi-5-b
bcm2712d0-rpi-5-b
bcm2712-d-rpi-5-b
bcm2712-rpi-500
bcm2712-rpi-cm5-cm5io
bcm2712-rpi-cm5-cm4io
bcm2712-rpi-cm5l-cm5io
bcm2712-rpi-cm5l-cm4io"

# --- fixtures -----------------------------------------------------------------------
# A defconfig with these broadcom/ names removed from the DTS line.
defconfig_without() {
	_out="$TMP/defconfig.$$.$1"; cp "$DEFCONFIG" "$_out"
	for _d in "$@"; do
		sed -e "/^BR2_LINUX_KERNEL_INTREE_DTS_NAME=/s#broadcom/$_d\\([ \"]\\)#\\1#" "$_out" > "$_out.new" && mv "$_out.new" "$_out"
	done
	echo "$_out"
}

# make_fat FILE OMIT — a 2 MiB FAT holding every family .dtb but OMIT ("" = none).
make_fat() {
	rm -rf "$TMP/stage"; mkdir -p "$TMP/stage"
	for _d in $ALL; do [ "$_d" = "$2" ] || echo "$_d" > "$TMP/stage/$_d.dtb"; done
	# A neighbour that is not a device tree, as on the real FAT.
	echo "kernel" > "$TMP/stage/kernel8.img"
	dd if=/dev/zero of="$1" bs=1M count=2 2>/dev/null
	mkfs.vfat "$1" >/dev/null
	MTOOLS_SKIP_CHECK=1 mcopy -i "$1" "$TMP/stage"/* ::
}

# make_fixture DIR OMIT_BUNDLE OMIT_P2 OMIT_P3 [PARTS] — a buildroot output dir:
# images/bundle/boot.vfat, images/rasputin-os-rpi-test.img (MBR: p1 1 MiB, p2
# and p3 2 MiB FATs; PARTS=2 leaves p3 out), host/bin/mcopy -> the system one.
make_fixture() {
	_o="$1"; _parts="${5:-3}"
	rm -rf "$_o"; mkdir -p "$_o/images/bundle" "$_o/host/bin"
	ln -s "$(command -v mcopy)" "$_o/host/bin/mcopy"
	make_fat "$_o/images/bundle/boot.vfat" "$2"
	_img="$_o/images/rasputin-os-rpi-test.img"
	dd if=/dev/zero of="$_img" bs=1M count=8 2>/dev/null
	{
		echo "label: dos"
		echo "start=2048, size=2048, type=c, bootable"
		echo "start=4096, size=4096, type=c"
		[ "$_parts" -lt 3 ] || echo "start=8192, size=4096, type=c"
	} | sfdisk --quiet "$_img" >/dev/null
	make_fat "$TMP/p2.vfat" "$3"
	dd if="$TMP/p2.vfat" of="$_img" bs=512 seek=4096 conv=notrunc 2>/dev/null
	if [ "$_parts" -ge 3 ]; then
		make_fat "$TMP/p3.vfat" "$4"
		dd if="$TMP/p3.vfat" of="$_img" bs=512 seek=8192 conv=notrunc 2>/dev/null
	fi
}

# --- TC-1061-01: the shipped list yields exactly the 13 family boards ---------------
# Parsed the way the script parses it: against a defconfig that names no device
# tree, defconfig mode reports every row, in order, with its board.
echo "== family list"
NONE="$TMP/defconfig.none"
sed 's#^BR2_LINUX_KERNEL_INTREE_DTS_NAME=.*#BR2_LINUX_KERNEL_INTREE_DTS_NAME=""#' "$DEFCONFIG" > "$NONE"
out=$(run defconfig "$LIST" "$NONE")
check "TC-1061-01 every row reported against an empty DTS line" "1" "$(rc_of "$out")"
names=$(printf '%s\n' "${out%|rc=*}" | sed -n 's/^::error::rpi-family-dtbs: The .* device tree \([^ ]*\) is not named in .*/\1/p')
check "TC-1061-01 the 13 device trees, in order" "$ALL" "$names"
boards=$(printf '%s\n' "${out%|rc=*}" | sed -n 's/^::error::rpi-family-dtbs: The \(.*\) device tree [^ ]* is not named in .*/\1/p' | grep -c .)
check "TC-1061-01 each row has a board name" "13" "$boards"
check "TC-1061-01 the CM5 Lite row" "yes" "$(has "$out" "The CM5 Lite device tree bcm2712-rpi-cm5l-cm5io is not named")"
# Comments (whole-line and trailing) and blank lines are not rows.
printf '# header\n\n   \nbcm2712-rpi-5-b  Pi 5   # trailing comment\n\t# indented comment\nbcm2711-rpi-4-b Pi 4 Model B\n' > "$TMP/list.comments"
out=$(run defconfig "$TMP/list.comments" "$DEFCONFIG")
check "TC-1061-01 comments and blank lines ignored: exit 0" "0" "$(rc_of "$out")"
check "TC-1061-01 comments and blank lines ignored: 2 rows" "yes" "$(has "$out" "ok  $DEFCONFIG: 2 of 2 family device trees")"

# --- defconfig mode -----------------------------------------------------------------
echo "== defconfig mode"
# TC-1061-02: the real defconfig passes with all 13.
out=$(run defconfig "$LIST" "$DEFCONFIG")
check "TC-1061-02 real defconfig: exit 0" "0" "$(rc_of "$out")"
check "TC-1061-02 real defconfig: ok line with 13" "yes" "$(has "$out" "ok  $DEFCONFIG: 13 of 13 family device trees")"

# TC-1061-03: one removed — one error naming the DTB, its board and the defconfig.
dc=$(defconfig_without bcm2712-rpi-cm5l-cm5io)
out=$(run defconfig "$LIST" "$dc")
check "TC-1061-03 cm5l-cm5io removed: exit 1" "1" "$(rc_of "$out")"
check "TC-1061-03 one error" "1" "$(errors "$out")"
check "TC-1061-03 the sentence" "yes" "$(has "$out" "::error::rpi-family-dtbs: The CM5 Lite device tree bcm2712-rpi-cm5l-cm5io is not named in BR2_LINUX_KERNEL_INTREE_DTS_NAME in $dc.")"

# TC-1061-04: two removed — both reported.
dc=$(defconfig_without bcm2712-rpi-500 bcm2711-rpi-cm4s)
out=$(run defconfig "$LIST" "$dc")
check "TC-1061-04 two removed: exit 1" "1" "$(rc_of "$out")"
check "TC-1061-04 two errors" "2" "$(errors "$out")"
check "TC-1061-04 Pi 500 named" "yes" "$(has "$out" "The Pi 500 device tree bcm2712-rpi-500 is not named")"
check "TC-1061-04 CM4S named" "yes" "$(has "$out" "The CM4S device tree bcm2711-rpi-cm4s is not named")"

# TC-1061-05: a prefix of two present names is still missing.
dc=$(defconfig_without bcm2711-rpi-cm4)
check "TC-1061-05 fixture keeps cm4-io and cm4s" "2" "$(grep '^BR2_LINUX_KERNEL_INTREE_DTS_NAME=' "$dc" | grep -o 'broadcom/bcm2711-rpi-cm4[-s][a-z]*' | grep -c .)"
out=$(run defconfig "$LIST" "$dc")
check "TC-1061-05 cm4 removed: exit 1" "1" "$(rc_of "$out")"
check "TC-1061-05 one error" "1" "$(errors "$out")"
check "TC-1061-05 names bcm2711-rpi-cm4 (CM4)" "yes" "$(has "$out" "The CM4 device tree bcm2711-rpi-cm4 is not named")"

# TC-1061-06: no DTS line; no defconfig.
grep -v '^BR2_LINUX_KERNEL_INTREE_DTS_NAME=' "$DEFCONFIG" > "$TMP/defconfig.nodts"
out=$(run defconfig "$LIST" "$TMP/defconfig.nodts")
check "TC-1061-06 no DTS line: exit 1" "1" "$(rc_of "$out")"
check "TC-1061-06 no DTS line: said" "yes" "$(has "$out" "::error::rpi-family-dtbs: The defconfig $TMP/defconfig.nodts has no BR2_LINUX_KERNEL_INTREE_DTS_NAME line, so it builds no device trees.")"
out=$(run defconfig "$LIST" "$TMP/no-such-defconfig")
check "TC-1061-06 no defconfig: exit 1" "1" "$(rc_of "$out")"
check "TC-1061-06 no defconfig: said" "yes" "$(has "$out" "::error::rpi-family-dtbs: The defconfig $TMP/no-such-defconfig does not exist.")"

# --- image mode ---------------------------------------------------------------------
echo "== image mode"
FX="$TMP/fx"

# TC-1061-08: all 13 everywhere.
make_fixture "$FX" "" "" ""
out=$(run image "$LIST" "$FX")
check "TC-1061-08 happy path: exit 0" "0" "$(rc_of "$out")"
for where in "bundle boot.vfat" "image p2" "image p3"; do
	check "TC-1061-08 ok $where with 13" "yes" "$(has "$out" "ok  $where: 13 of 13 family device trees")"
done
check "TC-1061-08 no error" "0" "$(errors "$out")"

# TC-1061-09: missing from one slot only — that slot named, the others ok.
for p in 2 3; do
	if [ "$p" = 2 ]; then make_fixture "$FX" "" bcm2712-rpi-cm5l-cm4io ""; other=3
	else make_fixture "$FX" "" "" bcm2712-rpi-cm5l-cm4io; other=2; fi
	out=$(run image "$LIST" "$FX")
	check "TC-1061-09 p$p miss: exit 1" "1" "$(rc_of "$out")"
	check "TC-1061-09 p$p miss: one error" "1" "$(errors "$out")"
	check "TC-1061-09 p$p miss: the sentence" "yes" "$(has "$out" "::error::rpi-family-dtbs: The CM5 Lite device tree bcm2712-rpi-cm5l-cm4io.dtb is missing from image p$p.")"
	check "TC-1061-09 p$p miss: p$other ok" "yes" "$(has "$out" "ok  image p$other: 13 of 13")"
	check "TC-1061-09 p$p miss: bundle ok" "yes" "$(has "$out" "ok  bundle boot.vfat: 13 of 13")"
done

# TC-1061-10: missing from the OTA boot.vfat only.
make_fixture "$FX" bcm2711-rpi-400 "" ""
out=$(run image "$LIST" "$FX")
check "TC-1061-10 bundle miss: exit 1" "1" "$(rc_of "$out")"
check "TC-1061-10 bundle miss: one error" "1" "$(errors "$out")"
check "TC-1061-10 bundle miss: the sentence" "yes" "$(has "$out" "::error::rpi-family-dtbs: The Pi 400 device tree bcm2711-rpi-400.dtb is missing from bundle boot.vfat.")"
check "TC-1061-10 bundle miss: p2 ok" "yes" "$(has "$out" "ok  image p2: 13 of 13")"
check "TC-1061-10 bundle miss: p3 ok" "yes" "$(has "$out" "ok  image p3: 13 of 13")"

# TC-1061-11: cm4 missing everywhere while cm4-io and cm4s are present.
make_fixture "$FX" bcm2711-rpi-cm4 bcm2711-rpi-cm4 bcm2711-rpi-cm4
check "TC-1061-11 fixture keeps cm4-io and cm4s" "2" "$(MTOOLS_SKIP_CHECK=1 mdir -b -i "$FX/images/bundle/boot.vfat" :: 2>/dev/null | grep -c -i 'bcm2711-rpi-cm4[-s]')"
out=$(run image "$LIST" "$FX")
check "TC-1061-11 cm4 missing: exit 1" "1" "$(rc_of "$out")"
check "TC-1061-11 cm4 missing: three errors" "3" "$(errors "$out")"
for where in "bundle boot.vfat" "image p2" "image p3"; do
	check "TC-1061-11 cm4 named in $where" "yes" "$(has "$out" "The CM4 device tree bcm2711-rpi-cm4.dtb is missing from $where.")"
done

# TC-1061-12: the bundle's FAT absent, then unreadable.
make_fixture "$FX" "" "" ""
rm "$FX/images/bundle/boot.vfat"
out=$(run image "$LIST" "$FX")
check "TC-1061-12 no boot.vfat: exit 1" "1" "$(rc_of "$out")"
check "TC-1061-12 no boot.vfat: said" "yes" "$(has "$out" "::error::rpi-family-dtbs: The bundle has no boot.vfat at $FX/images/bundle/boot.vfat, so an update would ship no device trees.")"
dd if=/dev/zero of="$FX/images/bundle/boot.vfat" bs=1M count=1 2>/dev/null
out=$(run image "$LIST" "$FX")
check "TC-1061-12 zeroed boot.vfat: exit 1" "1" "$(rc_of "$out")"
check "TC-1061-12 zeroed boot.vfat: said" "yes" "$(has "$out" "::error::rpi-family-dtbs: No device tree could be read from bundle boot.vfat, so none of the 13 family device trees is there.")"
check "TC-1061-12 zeroed boot.vfat: no ok for it" "no" "$(has "$out" "ok  bundle boot.vfat")"

# TC-1061-13: no flash image; two.
make_fixture "$FX" "" "" ""
mv "$FX/images/rasputin-os-rpi-test.img" "$TMP/aside.img"
out=$(run image "$LIST" "$FX")
check "TC-1061-13 no image: exit 1" "1" "$(rc_of "$out")"
check "TC-1061-13 no image: said" "yes" "$(has "$out" "::error::rpi-family-dtbs: There is no flash image rasputin-os-rpi-*.img in $FX/images.")"
cp "$TMP/aside.img" "$FX/images/rasputin-os-rpi-test.img"
cp "$TMP/aside.img" "$FX/images/rasputin-os-rpi-other.img"
out=$(run image "$LIST" "$FX")
check "TC-1061-13 two images: exit 1" "1" "$(rc_of "$out")"
check "TC-1061-13 two images: said" "yes" "$(has "$out" "::error::rpi-family-dtbs: There are 2 flash images rasputin-os-rpi-*.img in $FX/images, so which one ships is ambiguous.")"

# TC-1061-14: an image with no partition 3.
make_fixture "$FX" "" "" "" 2
out=$(run image "$LIST" "$FX")
check "TC-1061-14 no p3: exit 1" "1" "$(rc_of "$out")"
check "TC-1061-14 no p3: said" "yes" "$(has "$out" "::error::rpi-family-dtbs: The flash image $FX/images/rasputin-os-rpi-test.img has no partition 3, the boot slot the firmware reads it from.")"
check "TC-1061-14 no p3: p2 still checked" "yes" "$(has "$out" "ok  image p2: 13 of 13")"

# F-1061-11: an image the partition reader cannot read — said as that, with the reader's
# own message, and not reported as a missing partition.
make_fixture "$FX" "" "" ""
dd if=/dev/zero of="$FX/images/rasputin-os-rpi-test.img" bs=1M count=8 2>/dev/null
out=$(run image "$LIST" "$FX")
check "F-1061-11 unreadable table: exit 1" "1" "$(rc_of "$out")"
check "F-1061-11 unreadable table: said" "yes" "$(has "$out" "::error::rpi-family-dtbs: The partition table of the flash image $FX/images/rasputin-os-rpi-test.img could not be read, so its boot slots cannot be checked.")"
check "F-1061-11 unreadable table: reader's stderr shown" "yes" "$(has "$out" "    sfdisk:")"
check "F-1061-11 unreadable table: not a missing partition" "no" "$(has "$out" "has no partition")"
check "F-1061-11 unreadable table: one error" "1" "$(errors "$out")"
check "F-1061-11 unreadable table: bundle still checked" "yes" "$(has "$out" "ok  bundle boot.vfat: 13 of 13")"

# TC-1061-15: the build's mcopy gone, a system one still on PATH — no fallback.
make_fixture "$FX" "" "" ""
rm "$FX/host/bin/mcopy"
command -v mcopy >/dev/null 2>&1 || { echo "TC-1061-15 needs mcopy on PATH" >&2; exit 2; }
out=$(run image "$LIST" "$FX")
check "TC-1061-15 no build mcopy: exit 1" "1" "$(rc_of "$out")"
check "TC-1061-15 no build mcopy: said" "yes" "$(has "$out" "::error::rpi-family-dtbs: The build's own mcopy is not at $FX/host/bin/mcopy, so its boot FATs cannot be read.")"
check "TC-1061-15 no build mcopy: nothing read" "no" "$(has "$out" "ok  ")"

# --- TC-1061-07: the list absent, empty or malformed, in both modes -----------------
echo "== family list errors"
make_fixture "$FX" "" "" ""
printf '# only comments\n\n   \n' > "$TMP/list.empty"
printf 'bcm2712-rpi-5-b Pi 5\nbcm2712-rpi-cm5l-cm5io   # no board\n' > "$TMP/list.noboard"
for mode in defconfig image; do
	if [ "$mode" = defconfig ]; then target="$DEFCONFIG"; else target="$FX"; fi
	out=$(run "$mode" "$TMP/no-such-list" "$target")
	check "TC-1061-07 $mode, no list: exit 1" "1" "$(rc_of "$out")"
	check "TC-1061-07 $mode, no list: said" "yes" "$(has "$out" "::error::rpi-family-dtbs: The family list $TMP/no-such-list does not exist.")"
	out=$(run "$mode" "$TMP/list.empty" "$target")
	check "TC-1061-07 $mode, no rows: exit 1" "1" "$(rc_of "$out")"
	check "TC-1061-07 $mode, no rows: said" "yes" "$(has "$out" "::error::rpi-family-dtbs: The family list $TMP/list.empty has no boards in it, so there is nothing to check.")"
	out=$(run "$mode" "$TMP/list.noboard" "$target")
	check "TC-1061-07 $mode, row with no board: exit 1" "1" "$(rc_of "$out")"
	check "TC-1061-07 $mode, row with no board: said" "yes" "$(has "$out" "::error::rpi-family-dtbs: Line 2 of the family list $TMP/list.noboard names the device tree bcm2712-rpi-cm5l-cm5io but no board.")"
done

echo "rpi-family-dtbs: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
