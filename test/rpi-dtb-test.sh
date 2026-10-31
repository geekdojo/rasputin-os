#!/bin/sh
#
# Pins the rpi SKU's device-tree list and firmware selection.
#
# Why. One unified FAT boots Pi 4, Pi 5 and CM5. The firmware auto-selects the
# DTB by board and applies [pi4]/[pi5]/[cm5] in config.txt. Dropping a DTB from
# the defconfig, pinning device_tree=, or moving kernel= out of its [block]
# looks identical in a build and only fails on the board that needed that file.
# CM5 in particular had no DTB on the FAT, so the firmware fell back to the
# Pi 5 tree (or refused the partition). Nothing in QEMU reads config.txt or
# picks a DTB, so this is pinned here.
#
# This is a config assertion, not a kernel build: it reads the defconfig, the
# board config.txt, and the post-image staging line. The DTS files themselves
# were checked at the kernel pin named below (raspberrypi/linux 576cc10) —
# arch/arm64/boot/dts/broadcom/bcm2712-rpi-cm5-cm5io.dts and -cm4io.dts exist
# and are listed in that tree's Makefile; bcm2712-rpi-cm5l-*.dts do not.
#
# Run:  sh test/rpi-dtb-test.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
DEFCONFIG="$ROOT/configs/rasputin_rpi_defconfig"
CONFIG="$ROOT/board/rasputin/rpi/config.txt"
POST_IMAGE="$ROOT/board/rasputin/common/post-image.sh"
README="$ROOT/README.md"

for f in "$DEFCONFIG" "$CONFIG" "$POST_IMAGE" "$README"; do
	[ -f "$f" ] || { echo "missing: $f" >&2; exit 2; }
done

fails=0
check() {
	if [ "$2" = "0" ]; then printf '  ok   %s\n' "$1"
	else printf '  FAIL %s\n       %s\n' "$1" "${3:-}"; fails=$((fails + 1)); fi
}

# Kernel pin this suite verified the DTS files against. A bump that does not
# update this (and re-check the tree) is how a CM5 DTB name that does not
# exist at the new pin ships, or a Lite DTB that now exists stays omitted.
PIN=576cc10e1ed50a9eacffc7a05c796051d7343ea4
# Membership, not a locale-sorted string: `sort` without LC_ALL=C treats
# `bcm2712d0` and `bcm2712-rpi` as equal-then-different across machines.
WANT_DTS="broadcom/bcm2711-rpi-4-b
broadcom/bcm2712-rpi-5-b
broadcom/bcm2712d0-rpi-5-b
broadcom/bcm2712-rpi-cm5-cm5io
broadcom/bcm2712-rpi-cm5-cm4io"

echo "1. the defconfig still names the kernel pin whose DTS list was checked"
got_pin=$(sed -n 's/.*raspberrypi,linux,\([0-9a-f]\{40\}\).*/\1/p' "$DEFCONFIG")
check "BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION is $PIN" \
	"$([ "$got_pin" = "$PIN" ] && echo 0 || echo 1)" \
	"got '${got_pin:-<unset>}'"

echo "2. INTREE_DTS_NAME is the Pi 4 + Pi 5 + CM5 set, and only that set"
got_dts=$(sed -n 's/^BR2_LINUX_KERNEL_INTREE_DTS_NAME="\(.*\)"/\1/p' "$DEFCONFIG" \
	| tr ' ' '\n' | grep -v '^$')
got_n=$(printf '%s\n' "$got_dts" | grep -c .)
want_n=$(printf '%s\n' "$WANT_DTS" | grep -c .)
missing=""
for dts in $WANT_DTS; do
	printf '%s\n' "$got_dts" | grep -qxF "$dts" || missing="$missing $dts"
done
extra=""
for dts in $got_dts; do
	printf '%s\n' "$WANT_DTS" | grep -qxF "$dts" || extra="$extra $dts"
done
check "INTREE_DTS_NAME is exactly the $want_n pinned DTBs" \
	"$([ -z "$missing" ] && [ -z "$extra" ] && [ "$got_n" = "$want_n" ] && echo 0 || echo 1)" \
	"got ($got_n):
${got_dts:-<unset>}
missing:${missing:- (none)} extra:${extra:- (none)}"

echo "3. Lite cm5l names are not invented for a pin that does not have them"
check "no bcm2712-rpi-cm5l-* in INTREE_DTS_NAME" \
	"$(printf '%s\n' "$got_dts" | grep -q 'cm5l' && echo 1 || echo 0)" \
	"cm5l DTBs are not in raspberrypi/linux $PIN (raspberrypi/linux#6272 added them later)"

echo "4. config.txt keeps Pi 4 / Pi 5 kernel selection and lets firmware pick the DTB"
# settings: print every directive as "<section>|<key>=<value>". A kernel= that
# sits above the first [block] is "all" and would force one kernel onto every
# board; a device_tree= anywhere pins every CM5 carrier to one DTB.
cfg_settings() {
	awk '
		/^[[:space:]]*#/ { next }
		/^[[:space:]]*$/ { next }
		/^\[/            { s = $0; gsub(/[][]/, "", s); next }
		/=/              { print s "|" $0 }
	' "$1"
}
got_cfg=$(cfg_settings "$CONFIG")
check "[pi4] kernel=kernel8.img" \
	"$(printf '%s\n' "$got_cfg" | grep -qxF 'pi4|kernel=kernel8.img' && echo 0 || echo 1)" \
	"$got_cfg"
check "[pi5] kernel=kernel_2712.img" \
	"$(printf '%s\n' "$got_cfg" | grep -qxF 'pi5|kernel=kernel_2712.img' && echo 0 || echo 1)" \
	"$got_cfg"
check "[pi5] dtparam=pciex1 (CM5 inherits [pi5])" \
	"$(printf '%s\n' "$got_cfg" | grep -qxF 'pi5|dtparam=pciex1' && echo 0 || echo 1)" \
	"$got_cfg"
check "no global kernel= (would override the [pi4]/[pi5] split)" \
	"$(printf '%s\n' "$got_cfg" | grep -q '^|kernel=' && echo 1 || echo 0)" \
	"$got_cfg"
check "no device_tree= (firmware auto-selects bcm2712-rpi-cm5-cm5io.dtb on a CM5)" \
	"$(printf '%s\n' "$got_cfg" | grep -q 'device_tree=' && echo 1 || echo 0)" \
	"$got_cfg"

echo "5. [cm5] exists so CM5-only knobs have a home; it must not re-pin the kernel"
# The filter is what the firmware documents ([cm5] also sees [pi5]). An absent
# [cm5] is not a boot failure today, but it is how a later CM5-only setting
# gets stuffed into [pi5] and changes Pi 5. A kernel= or device_tree= under
# [cm5] would override the inherited [pi5] selection for CM5 only.
check "[cm5] section is present" \
	"$(grep -qxF '[cm5]' "$CONFIG" && echo 0 || echo 1)"
check "[cm5] does not set kernel=" \
	"$(printf '%s\n' "$got_cfg" | grep -q '^cm5|kernel=' && echo 1 || echo 0)" \
	"$got_cfg"
check "[cm5] does not set device_tree=" \
	"$(printf '%s\n' "$got_cfg" | grep -q '^cm5|device_tree=' && echo 1 || echo 0)" \
	"$got_cfg"

echo "6. post-image.sh still stages every built DTB onto the boot FAT"
# The staging is a wildcard, not a name list: a new INTREE_DTS_NAME entry
# reaches the FAT without a second edit. Pinning a hardcoded list here would
# let the two files drift.
check "post-image.sh copies BINARIES_DIR/*.dtb into the common boot stage" \
	"$(grep -q 'cp "\$BINARIES_DIR"/\*\.dtb' "$POST_IMAGE" && echo 0 || echo 1)"

echo "7. README still calls CM5 builds-but-untested, and does not claim extra rollback"
check "README says CM5 builds; untested on hardware" \
	"$(grep -q 'CM5 \*\*builds; untested on hardware\*\*' "$README" && echo 0 || echo 1)"
check "README does not claim CM5 rollback beyond Pi 5 tryboot" \
	"$(grep -q 'same defense-in-depth as Pi 5' "$README" && echo 0 || echo 1)"

echo
if [ "$fails" -ne 0 ]; then echo "FAILED: $fails check(s)"; exit 1; fi
echo "all rpi-dtb tests passed"
