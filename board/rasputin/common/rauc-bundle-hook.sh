#!/bin/sh
#
# rauc-bundle-hook.sh — the RAUC bundle hook that installs a slot's KERNEL with
# its rootfs (geekdojo/geekdojo-brain#807). post-image.sh copies it into every
# bundle as hook.sh; the manifest declares it for `install-check` and as the
# rootfs image's `post-install` hook.
#
# WHY IT EXISTS. RAUC used to replace only the rootfs. The kernel sits outside
# it — on the rpi in each slot's boot FAT (p2/p3), on the n100 as one /bzImage
# on the ESP shared by both slots — so an update booted the OLD kernel against
# the NEW rootfs. dev.276 changed the Pi kernel config: its rootfs lists
# bridge.ko as built in and so does not ship it, the old kernel has it as a
# module, and docker died on every OTA'd arm64 node ("Failed to create bridge
# docker0 via netlink: operation not supported"). Now the bundle carries the
# slot's boot files and this hook writes them, so a slot's kernel and its
# modules are always one build.
#
# WHY A HOOK AND NOT A SLOT. Devices running dev.269 (RAUC 1.13) and dev.276
# (RAUC 1.15.2) have no boot slot in their system.conf, and RAUC refuses a
# bundle carrying an image class the device has no slot for ("No target slot
# for class ..."). A hook needs nothing from the device, so the FIRST update
# from one of those images already moves its kernel.
#
# IT RUNS ON THE OLD ROOTFS. Whatever image is installed runs this, from the
# bundle, under that image's busybox. So: POSIX sh and busybox applets only,
# and nothing from the running rootfs that an older image might not have —
# which is why the BMC-host cmdline policy is sourced from the copy shipped in
# the bundle, not from /usr/lib/rasputin.
#
# Commands (RAUC passes one as $1):
#   install-check      Replaces RAUC's own compatible check (a declared
#                      install-check hook does that), so it re-implements it,
#                      then refuses a bundle whose boot payload is corrupt or
#                      that this device's boot partitions cannot take. Runs
#                      before anything is written. Exit 10 = rejected; RAUC
#                      reports the last stderr line.
#   slot-post-install  After RAUC wrote the rootfs to the target slot, writes
#                      that slot's boot files, then reads them back. Any
#                      failure exits non-zero, which fails the install BEFORE
#                      RAUC calls set-primary: the device keeps booting the slot
#                      it is on.
#
# Per SKU (dispatched on RAUC_SYSTEM_COMPATIBLE, which install-check has
# already proven equals the bundle's):
#   rpi   dd the slot-neutral boot.vfat onto the slot's boot partition (A=p2,
#         B=p3), read it back, mount it, write cmdline-<slot>.txt as cmdline.txt
#         (BMC-host policy re-applied), then the rasputin-boot-version marker.
#   n100  write bzImage-<slot> on the ESP (write, read back, rename), replace
#         the shared grub.cfg only when it differs, then the
#         rasputin-boot-version-<slot> marker. The grub.cfg write is the one
#         write both slots share: a power cut DURING it can leave the board
#         unbootable. It happens once per grub.cfg change, not per update.
#
# RASPUTIN_HOOK_ROOT prefixes every device-side path (/dev, /proc, /sys, /run,
# /var/lib/rasputin). It is the test seam for test/boot-hook-test.sh, which
# runs this against fake partitions; RAUC never sets it.
set -u

ROOT="${RASPUTIN_HOOK_ROOT:-}"
BUNDLE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
SUMS="$BUNDLE/boot-payload.sha256"
MNT="$ROOT/run/rasputin-bundle-hook"
ESP="$ROOT/run/rasputin-esp"
PARTUUID_DIR="$ROOT/dev/disk/by-partuuid"
MOUNTED=""

log() { echo "rasputin-bundle-hook: $*" >&2; }
die() { log "ERROR: $*"; exit 1; }
# A rejection in install-check: exit 10 makes RAUC report this line as the
# reason, and it is the LAST line written to stderr, so nothing may follow it.
reject() { echo "rasputin-bundle-hook: refusing this bundle: $*" >&2; exit 10; }

cleanup() {
	rc=$?
	if [ -n "$MOUNTED" ]; then
		umount "$MOUNTED" 2>/dev/null || log "WARNING: could not unmount $MOUNTED"
	fi
	exit "$rc"
}
trap cleanup EXIT

sku() {
	case "${RAUC_SYSTEM_COMPATIBLE:-}" in
		rasputin-rpi-arm64) echo rpi ;;
		rasputin-n100) echo n100 ;;
		*) return 1 ;;
	esac
}

# Every payload file against the checksums post-image.sh wrote. The bundle is
# signed and verity-checked as a whole; this catches a payload that does not
# match what the build meant to ship (a staging bug), before anything is written.
verify_payload() {
	[ -f "$SUMS" ] || return 1
	(cd "$BUNDLE" && sha256sum -c "$SUMS") >/dev/null 2>&1
}

sum_of() { # sum_of NAME — the expected sha256 of payload file NAME
	awk -v n="$1" '$2 == n || $2 == "*" n { print $1; exit }' "$SUMS"
}

hash_file() { sha256sum "$1" | cut -d' ' -f1; }

file_size() { wc -c < "$1" | tr -d ' '; }

# Size in bytes of a block device (from sysfs) or, in tests, a regular file.
dev_size() {
	_real="$(readlink -f "$1")" || return 1
	_name="${_real##*/}"
	if [ -r "$ROOT/sys/class/block/$_name/size" ]; then
		echo $(( $(cat "$ROOT/sys/class/block/$_name/size") * 512 ))
	elif [ -f "$_real" ]; then
		file_size "$_real"
	else
		return 1
	fi
}

running_slot() {
	for tok in $(cat "$ROOT/proc/cmdline" 2>/dev/null); do
		case "$tok" in rauc.slot=*) echo "${tok#rauc.slot=}"; return 0 ;; esac
	done
	return 1
}

# Status 0 when DEV (by its link or its real node) is a mounted source.
is_mounted() {
	_real="$(readlink -f "$1")"
	_rootreal=""
	[ -z "$ROOT" ] || _rootreal="$(readlink -f "$ROOT")"
	awk -v a="${1#"$ROOT"}" -v b="${_real#"$_rootreal"}" \
		'$1 == a || $1 == b { f = 1 } END { exit !f }' "$ROOT/proc/mounts"
}

esp_mounted() {
	awk '$2 == "/run/rasputin-esp" { f = 1 } END { exit !f }' "$ROOT/proc/mounts"
}

# Pages written above are clean after sync; dropping them makes the read-back
# come from the medium rather than from the cache the write just filled.
drop_caches() {
	sync
	echo 3 > "$ROOT/proc/sys/vm/drop_caches" || die "could not drop the page cache before the read-back"
}

rpi_part_dev() {
	case "$1" in
		A) echo "$PARTUUID_DIR/52415350-02" ;;
		B) echo "$PARTUUID_DIR/52415350-03" ;;
		*) return 1 ;;
	esac
}

boot_version() {
	_v="$(cat "$BUNDLE/boot-version" 2>/dev/null)"
	[ -n "$_v" ] || die "the bundle carries no boot-version"
	echo "$_v"
}

# put_file SRC DST — write DST through DST.tmp + rename, so a reader never sees
# half a file. vfat has no atomic rename guarantee across a power cut, but the
# old file survives until the rename itself.
put_file() {
	cp "$1" "$2.tmp" || die "could not write $2.tmp"
	mv "$2.tmp" "$2" || die "could not rename $2.tmp to $2"
}

# ------------------------------------------------------------- install-check --
install_check() {
	_mf="${RAUC_MF_COMPATIBLE:-}"
	_sys="${RAUC_SYSTEM_COMPATIBLE:-}"
	# The check RAUC skips when an install-check hook is declared. Empty on
	# either side refuses: a missing value is not a match.
	if [ -z "$_mf" ] || [ "$_mf" != "$_sys" ]; then
		reject "it is for '$_mf' and this system is '$_sys'"
	fi
	_sku="$(sku)" || reject "unknown system compatible '$_sys'"
	verify_payload || reject "its boot payload does not match its checksums"

	case "$_sku" in
		rpi)
			_need="$(file_size "$BUNDLE/boot.vfat")"
			for _bn in A B; do
				_dev="$(rpi_part_dev "$_bn")"
				[ -e "$_dev" ] || reject "boot partition for slot $_bn ($_dev) is missing"
				_have="$(dev_size "$_dev")" || reject "cannot read the size of $_dev"
				[ "$_have" -ge "$_need" ] \
					|| reject "boot partition for slot $_bn is $_have bytes, the boot FAT needs $_need"
			done
			;;
		n100)
			esp_mounted || reject "the ESP is not mounted at /run/rasputin-esp"
			[ -f "$ESP/EFI/BOOT/grub.cfg" ] || reject "no grub.cfg on the ESP"
			_need_kb=$(( ($(file_size "$BUNDLE/bzImage") + $(file_size "$BUNDLE/grub.cfg")) / 1024 + 64 ))
			_free_kb="$(df -Pk "$ESP" | awk 'NR == 2 { print $4 }')"
			case "$_free_kb" in ''|*[!0-9]*) reject "cannot read free space on the ESP" ;; esac
			[ "$_free_kb" -ge "$_need_kb" ] \
				|| reject "the ESP has ${_free_kb} KiB free, the kernel needs ${_need_kb} KiB"
			;;
	esac
	log "install-check passed ($_sku, $_mf)"
}

# ------------------------------------------------------- slot-post-install: rpi --
rpi_post_install() {
	_bn="$1"
	_dev="$(rpi_part_dev "$_bn")" || die "unknown slot bootname '$_bn'"
	[ -e "$_dev" ] || die "no boot partition $_dev for slot $_bn"
	if [ "$(running_slot)" = "$_bn" ]; then
		die "slot $_bn is the running slot; refusing to rewrite the boot partition under it"
	fi
	is_mounted "$_dev" && die "$_dev is mounted; refusing to write under a mounted filesystem"
	verify_payload || die "the boot payload does not match its checksums"
	_version="$(boot_version)"
	_need="$(file_size "$BUNDLE/boot.vfat")"
	_have="$(dev_size "$_dev")" || die "cannot read the size of $_dev"
	[ "$_have" -ge "$_need" ] || die "$_dev is $_have bytes, the boot FAT needs $_need"
	_want="$(sum_of boot.vfat)"
	[ -n "$_want" ] || die "no checksum for boot.vfat in the payload list"

	log "slot $_bn: writing the boot FAT ($_need bytes) to $_dev"
	dd if="$BUNDLE/boot.vfat" of="$_dev" bs=1M 2>/dev/null || die "writing $_dev failed"
	drop_caches
	_got="$(head -c "$_need" "$_dev" | sha256sum | cut -d' ' -f1)"
	[ "$_got" = "$_want" ] || die "read-back of $_dev does not match boot.vfat (got $_got, want $_want)"

	_src="$BUNDLE/cmdline-$_bn.txt"
	[ -f "$_src" ] || die "the bundle carries no cmdline-$_bn.txt"
	mkdir -p "$MNT" || die "cannot create $MNT"
	mount -t vfat -o rw "$_dev" "$MNT" || die "cannot mount $_dev"
	MOUNTED="$MNT"
	if [ -e "$ROOT/var/lib/rasputin/bmc-host" ]; then
		[ -f "$BUNDLE/cmdline-policy.sh" ] || die "BMC host, but the bundle carries no cmdline-policy.sh"
		# shellcheck disable=SC1091
		. "$BUNDLE/cmdline-policy.sh"
		cmdline_strip_serial_console "$_src" > "$MNT/cmdline.txt.tmp" || die "cannot write $MNT/cmdline.txt.tmp"
		mv "$MNT/cmdline.txt.tmp" "$MNT/cmdline.txt" || die "cannot rename cmdline.txt"
		log "slot $_bn: BMC host, serial console removed from cmdline.txt"
	else
		put_file "$_src" "$MNT/cmdline.txt"
	fi
	# The marker goes LAST: its presence says every step above completed.
	printf '%s\n' "$_version" > "$MNT/rasputin-boot-version.tmp" || die "cannot write the boot marker"
	mv "$MNT/rasputin-boot-version.tmp" "$MNT/rasputin-boot-version" || die "cannot rename the boot marker"
	sync
	umount "$MNT" || die "cannot unmount $MNT"
	MOUNTED=""
	log "slot $_bn: boot FAT $_version installed"
}

# ------------------------------------------------------ slot-post-install: n100 --
# install_verified SRC DST NAME — DST via DST.new: write, read back against
# the payload checksum for NAME, rename.
install_verified() {
	_want="$(sum_of "$3")"
	[ -n "$_want" ] || die "no checksum for $3 in the payload list"
	cp "$1" "$2.new" || die "could not write $2.new"
	drop_caches
	_got="$(hash_file "$2.new")"
	[ "$_got" = "$_want" ] || die "read-back of $2.new does not match $3 (got $_got, want $_want)"
	mv "$2.new" "$2" || die "could not rename $2.new to $2"
	sync
}

n100_post_install() {
	_bn="$1"
	case "$_bn" in A|B) ;; *) die "unknown slot bootname '$_bn'" ;; esac
	if [ "$(running_slot)" = "$_bn" ]; then
		die "slot $_bn is the running slot; refusing to rewrite its kernel under it"
	fi
	esp_mounted || die "the ESP is not mounted at /run/rasputin-esp"
	verify_payload || die "the boot payload does not match its checksums"
	_version="$(boot_version)"

	log "slot $_bn: writing $ESP/bzImage-$_bn"
	install_verified "$BUNDLE/bzImage" "$ESP/bzImage-$_bn" bzImage
	if ! cmp -s "$BUNDLE/grub.cfg" "$ESP/EFI/BOOT/grub.cfg"; then
		log "replacing the shared $ESP/EFI/BOOT/grub.cfg (per-slot kernels with the legacy /bzImage fallback)"
		install_verified "$BUNDLE/grub.cfg" "$ESP/EFI/BOOT/grub.cfg" grub.cfg
	fi
	printf '%s\n' "$_version" > "$ESP/rasputin-boot-version-$_bn.tmp" || die "cannot write the boot marker"
	mv "$ESP/rasputin-boot-version-$_bn.tmp" "$ESP/rasputin-boot-version-$_bn" || die "cannot rename the boot marker"
	sync
	log "slot $_bn: kernel $_version installed"
}

case "${1:-}" in
	install-check)
		install_check
		;;
	slot-post-install)
		_sku="$(sku)" || die "unknown system compatible '${RAUC_SYSTEM_COMPATIBLE:-}'"
		_bn="${RAUC_SLOT_BOOTNAME:-}"
		[ -n "$_bn" ] || die "RAUC_SLOT_BOOTNAME is not set"
		"${_sku}_post_install" "$_bn"
		;;
	*)
		die "unsupported hook command '${1:-}'"
		;;
esac
exit 0
