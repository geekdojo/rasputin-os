#!/bin/sh
#
# Tests for the persistent machine-id (geekdojo/geekdojo-brain#600): the PID 1
# shim that restores it (usr/lib/rasputin/machine-id/rasputin-init), the unit
# that commits it (rasputin-machine-id-commit.sh), and the build step that
# points /sbin/init at the shim.
#
# WHY THIS IS TESTED AT ALL. The shim IS PID 1. If it exits, hangs or trips on a
# guard it never reaches, the node does not boot and the kernel does not fall
# back — it panics with "Requested init … failed", and on the Pi there is no
# bootloader attempt-counter to roll back from a panic that happens this early.
# So the property that matters is not "it restores the id"; it is "it ALWAYS
# hands off to systemd", including when the persistent partition is missing,
# unformatted, empty, or when every helper binary it wants is absent. Nothing in
# the build or in a boot log says otherwise until a node is dark.
#
# The second property is that the id is committed ONCE. A commit script that
# overwrote the store whenever it disagreed with the running id would turn a
# broken restore into exactly the churn this work exists to end — a new id every
# boot, now also written to disk every boot.
#
# WHAT THIS DOES NOT PROVE. That the restore actually precedes systemd's
# machine_id_setup() on real hardware. That needs an image build and two
# reboots; the steps are in the pull request. Everything here is the static
# shape of what ships plus the shim's own decisions, run unprivileged against a
# scratch tree with stub mount/umount/findfs and a stub hand-off target. No
# root, no partitions, no systemd, runs anywhere.
#
# Shells. Every case runs under each shell in TEST_SHELLS (default: whichever of
# sh, dash, bash and `busybox sh` are installed). REQUIRE_BUSYBOX=1 (CI sets it)
# fails the run when busybox is missing, since busybox ash is the image's
# /bin/sh — and the shim runs under it before anything else on the node does.
#
# Run:  sh test/machine-id-test.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
MIDDIR="$OVERLAY/usr/lib/rasputin/machine-id"
SHIM="$MIDDIR/rasputin-init"
COMMIT="$MIDDIR/rasputin-machine-id-commit.sh"
UNIT="$OVERLAY/etc/systemd/system/rasputin-machine-id-commit.service"
POSTBUILD="$ROOT/board/rasputin/common/post-build.sh"
for f in "$SHIM" "$COMMIT" "$UNIT" "$POSTBUILD"; do
	[ -f "$f" ] || { echo "missing: $f" >&2; exit 2; }
done

# The real systemd binary the shim must end up at. Pinned here as well as in the
# shim and in post-build.sh, because those two have to agree: post-build refuses
# to ship a rootfs where this path is not executable, and the shim execs it.
SYSTEMD_PATH=/usr/lib/systemd/systemd
# Where post-build.sh must leave /sbin/init pointing.
SHIM_PATH=/usr/lib/rasputin/machine-id/rasputin-init
# A well-formed machine-id and a few that are not.
GOOD_ID=4f2c1ab97d3e46b08c5d1e9f7a63b204
OTHER_ID=9b81c0d7e6f34a25b7c9d0e1f2a3b4c5

if [ -z "${TEST_SHELLS:-}" ]; then
	TEST_SHELLS=""
	for s in sh dash bash; do
		command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"
	done
	command -v busybox >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS busybox_sh"
fi
if [ "${REQUIRE_BUSYBOX:-0}" = "1" ] && ! command -v busybox >/dev/null 2>&1; then
	echo "FAIL: REQUIRE_BUSYBOX=1 but busybox is not installed" >&2
	exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- harness ------------------------------------------------------------------
pass=0
fail=0
SH=""

ok() {
	if [ "$2" = 0 ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf '  FAIL [%s] %s\n' "$SH" "$1" >&2
		[ -n "${3:-}" ] && printf '       %s\n' "$3" | head -20 >&2
	fi
	return 0
}
yes_if() { if "$@"; then echo 0; else echo 1; fi; }
not() { if "$@"; then return 1; else return 0; fi; }

# setup — a fresh fake root plus the stubs the shim reaches for.
#
#   R/            the rootfs the shim operates on (etc, run, proc, var/lib/rasputin)
#   PERSIST/      what the persistent partition CONTAINS; the mount stub copies
#                 it into R/var/lib/rasputin when the shim mounts ext4
#   BIN/          mount, umount, findfs and the stub systemd the shim execs
setup() {
	W=$(mktemp -d "$TMP/w.XXXXXX")
	R="$W/root"; PERSIST="$W/persist"; BIN="$W/bin"
	mkdir -p "$R/etc" "$R/run" "$R/proc" "$R/sys" "$R/var/lib/rasputin" "$PERSIST" "$BIN"
	# The baked, empty /etc/machine-id a bind mount lands on.
	: >"$R/etc/machine-id"
	: >"$W/mount.calls"; : >"$W/umount.calls"; : >"$W/findfs.calls"
	rm -f "$W/handoff.args"

	cat >"$BIN/mount" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_MOUNT_CALLS"
[ "${STUB_MOUNT_RC:-0}" = 0 ] || exit "$STUB_MOUNT_RC"
src=; dst=
for a in "$@"; do src=$dst; dst=$a; done
case " $* " in
	*" -t ext4 "*)
		[ "${STUB_EXT4_RC:-0}" = 0 ] || exit "$STUB_EXT4_RC"
		mkdir -p "$dst" && cp -R "$STUB_PERSIST/." "$dst/" 2>/dev/null
		;;
	*" -t sysfs "*)
		[ "${STUB_SYSFS_RC:-0}" = 0 ] || exit "$STUB_SYSFS_RC"
		# A mounted sysfs always has block/ in it; that directory is how
		# the shim tells a mounted /sys from the baked, empty one, and
		# how the findfs stub below tells whether it could scan.
		mkdir -p "$dst/block"
		;;
	*" -t tmpfs "*|*" -t proc "*)
		mkdir -p "$dst"
		;;
	*" -o bind "*)
		cp "$src" "$dst" || exit 1
		;;
esac
exit 0
STUB
	cat >"$BIN/umount" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_UMOUNT_CALLS"
dst=
for a in "$@"; do dst=$a; done
case "$dst" in
	*/var/lib/rasputin) rm -f "$dst"/* 2>/dev/null ;;
esac
exit 0
STUB
	# findfs, modelled on the real one. With udev not running there is no
	# /dev/disk/by-label, so util-linux's findfs resolves a LABEL= by scanning
	# sysfs — opendir("/sys/block"), then /sys/dev/block/<maj>:<min> per entry
	# (strace, util-linux 2.38.1 and 2.40.4; 2.40.4 is what the image ships).
	# With /sys unmounted that first opendir is ENOENT, the scan yields
	# nothing, and findfs exits 1 having printed nothing. dev.251 shipped
	# without mounting /sys and landed in exactly that branch on both SKUs
	# (geekdojo/geekdojo-brain#600), so the stub refuses the same way: this is
	# what makes the ordering — sysfs BEFORE findfs — a tested property rather
	# than a comment.
	cat >"$BIN/findfs" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_FINDFS_CALLS"
[ "${STUB_FINDFS_RC:-0}" = 0 ] || exit "$STUB_FINDFS_RC"
if [ -n "${STUB_FINDFS_NEEDS_SYS:-}" ] && [ ! -d "${STUB_SYSFS_MARK:-/nonexistent}" ]; then
	echo "findfs: unable to resolve '$*'" >&2
	exit 1
fi
printf '%s\n' "${STUB_FINDFS_DEV:-/dev/fake1}"
STUB
	# The hand-off target. Records that it was reached and with which
	# arguments — the kernel passes init any command-line words it did not
	# recognise, and they have to survive the shim.
	cat >"$BIN/systemd" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" > "$STUB_HANDOFF_ARGS"
exit 0
STUB
	chmod +x "$BIN/mount" "$BIN/umount" "$BIN/findfs" "$BIN/systemd"
	STUB_MOUNT_RC=0; STUB_EXT4_RC=0; STUB_FINDFS_RC=0; STUB_SYSFS_RC=0
	# On by default: a findfs that needs sysfs is the one the image has.
	STUB_FINDFS_NEEDS_SYS=1
	MOUNT_BIN="$BIN/mount"; UMOUNT_BIN="$BIN/umount"; FINDFS_BIN="$BIN/findfs"
}

# store ID — put ID on the "persistent partition".
store() { printf '%s\n' "$1" >"$PERSIST/machine-id"; }

# shim [ARG...] — run the shim; sets OUT (stdout+stderr) and RC.
shim() {
	case "$SH" in
		busybox_sh) set -- busybox sh "$SHIM" "$@" ;;
		*)          set -- "$SH" "$SHIM" "$@" ;;
	esac
	OUT=$(STUB_MOUNT_CALLS="$W/mount.calls" STUB_UMOUNT_CALLS="$W/umount.calls" \
		STUB_FINDFS_CALLS="$W/findfs.calls" STUB_HANDOFF_ARGS="$W/handoff.args" \
		STUB_PERSIST="$PERSIST" STUB_MOUNT_RC="$STUB_MOUNT_RC" \
		STUB_EXT4_RC="$STUB_EXT4_RC" STUB_FINDFS_RC="$STUB_FINDFS_RC" \
		STUB_SYSFS_RC="$STUB_SYSFS_RC" STUB_SYSFS_MARK="$R/sys/block" \
		STUB_FINDFS_NEEDS_SYS="$STUB_FINDFS_NEEDS_SYS" \
		RASPUTIN_INIT_TEST=1 \
		RASPUTIN_INIT_ROOT="$R" \
		RASPUTIN_INIT_MOUNT="$MOUNT_BIN" \
		RASPUTIN_INIT_UMOUNT="$UMOUNT_BIN" \
		RASPUTIN_INIT_FINDFS="$FINDFS_BIN" \
		RASPUTIN_INIT_KMSG="$W/kmsg" \
		RASPUTIN_INIT_SYSTEMD="$BIN/systemd" \
		"$@" 2>&1)
	RC=$?
}

# commit — run the commit script against the scratch tree; sets OUT and RC.
commit() {
	case "$SH" in
		busybox_sh) set -- busybox sh "$COMMIT" ;;
		*)          set -- "$SH" "$COMMIT" ;;
	esac
	OUT=$(RASPUTIN_MACHINE_ID_PERSIST="$PERSIST" \
		RASPUTIN_MACHINE_ID_CURRENT="$R/etc/machine-id" \
		"$@" 2>&1)
	RC=$?
}

handed_off() { [ -f "$W/handoff.args" ]; }
bound() { grep -qF -- "-o bind $R/run/machine-id $R/etc/machine-id" "$W/mount.calls"; }
out_has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
# reason_line — the single "…; this boot uses a transient id" line from $OUT.
# Assertions about how a degrade READS must look at this and not at all of
# $OUT, which also carries the scratch tree's mktemp path.
reason_line() { printf '%s\n' "$OUT" | grep -- 'this boot uses a transient id'; }
# reason_matches ERE — true when the reason line matches. A separate function
# because `not` takes a command, not a pipeline.
reason_matches() { reason_line | grep -Eq -- "$1"; }
file_is() { [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; }
perms() { ls -ld "$1" 2>/dev/null | cut -c1-10; }

# --- cases --------------------------------------------------------------------
cases() {
	# 1. The happy path: a stored id is restored into /run/machine-id, bound
	#    over /etc/machine-id, and systemd is reached with the boot's arguments
	#    intact.
	setup; store "$GOOD_ID"; shim 3 quiet
	ok "restore: hands off to systemd" "$(yes_if handed_off)" "$OUT"
	ok "restore: kernel args survive" \
		"$(yes_if file_is "$W/handoff.args" "3 quiet")" "$(cat "$W/handoff.args" 2>/dev/null)"
	ok "restore: /run/machine-id holds the stored id" \
		"$(yes_if file_is "$R/run/machine-id" "$GOOD_ID")" "$(cat "$R/run/machine-id" 2>/dev/null)"
	ok "restore: /run/machine-id is 0444" \
		"$(yes_if test "$(perms "$R/run/machine-id")" = '-r--r--r--')" "$(perms "$R/run/machine-id")"
	ok "restore: bound over /etc/machine-id" "$(yes_if bound)" "$(cat "$W/mount.calls")"
	ok "restore: /etc/machine-id now reads the stored id" \
		"$(yes_if file_is "$R/etc/machine-id" "$GOOD_ID")" "$(cat "$R/etc/machine-id" 2>/dev/null)"
	# Names the device it restored FROM, not just "the persistent partition".
	# That is the only thing in the log that distinguishes a restore off the
	# node's own disk from one off a second Rasputin medium left attached.
	ok "restore: says so on the console, naming the device" \
		"$(yes_if out_has "machine-id $GOOD_ID restored from /dev/fake1 (LABEL=persistent)")" "$OUT"

	# 2. The persistent partition is mounted READ-ONLY and put back. Leaving it
	#    mounted would hand systemd's fstab unit a filesystem it did not mount,
	#    so x-systemd.growfs/makefs would never run and rasputin-growpart's
	#    expansion would silently stop happening.
	ok "restore: persistent is mounted ro" \
		"$(yes_if grep -q -- '-t ext4 -o ro,nosuid,nodev,noexec' "$W/mount.calls")" "$(cat "$W/mount.calls")"
	ok "restore: persistent is unmounted again" \
		"$(yes_if grep -qF -- "$R/var/lib/rasputin" "$W/umount.calls")" "$(cat "$W/umount.calls")"
	ok "restore: found by filesystem label, which both SKUs share" \
		"$(yes_if grep -qxF 'LABEL=persistent' "$W/findfs.calls")" "$(cat "$W/findfs.calls")"

	# 3. /run is mounted with systemd's own mount_setup() options. systemd skips
	#    a /run that is already a mount point, so anything weaker here ships as
	#    the node's real /run: no size cap, no inode cap, suid and device nodes
	#    allowed. This is the one line in the shim that can quietly widen a
	#    default rather than fail.
	ok "restore: /run gets systemd's exact tmpfs options" \
		"$(yes_if grep -q -- '-t tmpfs -o mode=0755,nosuid,nodev,strictatime,size=20%,nr_inodes=800k' "$W/mount.calls")" \
		"$(cat "$W/mount.calls")"

	# 4. An already-mounted /run is left alone (this is what happens if systemd
	#    ever grows an earlier /run, or on a re-exec).
	setup; store "$GOOD_ID"
	printf 'tmpfs %s tmpfs rw 0 0\n' "$R/run" >"$R/proc/self_mounts_tmp"
	mkdir -p "$R/proc/self" && mv "$R/proc/self_mounts_tmp" "$R/proc/self/mounts"
	shim
	ok "mounted /run: not re-mounted" \
		"$(yes_if not grep -q -- '-t tmpfs' "$W/mount.calls")" "$(cat "$W/mount.calls")"
	ok "mounted /run: /proc not re-mounted either" \
		"$(yes_if not grep -q -- '-t proc' "$W/mount.calls")" "$(cat "$W/mount.calls")"
	ok "mounted /run: still restores" "$(yes_if bound)" "$(cat "$W/mount.calls")"

	# 5. /sys. THE dev.251 DEFECT (geekdojo/geekdojo-brain#600). The kernel
	#    mounts neither /proc nor /sys before init, and with udev not running
	#    findfs resolves a LABEL= only by scanning sysfs. dev.251 never mounted
	#    /sys, so findfs returned nothing on every boot of every node and the
	#    restore silently degraded. The mount has to happen, with systemd's own
	#    options, and BEFORE findfs is called — the ordering is the fix.
	setup; store "$GOOD_ID"; shim
	ok "sysfs: mounted, since the kernel does not mount it for init" \
		"$(yes_if grep -q -- '-t sysfs' "$W/mount.calls")" "$(cat "$W/mount.calls")"
	ok "sysfs: gets systemd's exact mount_setup() options" \
		"$(yes_if grep -q -- '-t sysfs -o nosuid,nodev,noexec sysfs '"$R/sys" "$W/mount.calls")" \
		"$(cat "$W/mount.calls")"
	# The stub findfs refuses while $R/sys/block is absent, the way the real one
	# does. So these two passing IS the ordering assertion: sysfs is mounted
	# first, or findfs resolves nothing and neither of them holds.
	ok "sysfs: mounted first, so findfs resolves the label" \
		"$(yes_if grep -q -- '-t ext4 -o ro,nosuid,nodev,noexec /dev/fake1' "$W/mount.calls")" \
		"$(cat "$W/mount.calls")"
	ok "sysfs: and the id is restored (this is the whole bug)" \
		"$(yes_if bound)" "$OUT"
	ok "sysfs: unmounted again, leaving what systemd would have made" \
		"$(yes_if grep -qxF "$R/sys" "$W/umount.calls")" "$(cat "$W/umount.calls")"
	ok "sysfs: says it mounted it" "$(yes_if out_has "mounted $R/sys")" "$OUT"

	# 6. A /sys that is already mounted is left alone — not re-mounted, and NOT
	#    unmounted on the way out, because it was not ours to remove. (What
	#    happens if systemd ever grows an earlier /sys, or on a re-exec.)
	setup; store "$GOOD_ID"; mkdir -p "$R/sys/block"; shim
	ok "mounted /sys: not re-mounted" \
		"$(yes_if not grep -q -- '-t sysfs' "$W/mount.calls")" "$(cat "$W/mount.calls")"
	ok "mounted /sys: not unmounted either" \
		"$(yes_if not grep -qxF "$R/sys" "$W/umount.calls")" "$(cat "$W/umount.calls")"
	ok "mounted /sys: still restores" "$(yes_if bound)" "$(cat "$W/mount.calls")"

	# 7. A /sys that will NOT mount. findfs then finds nothing, exactly as in
	#    dev.251 — but the node still boots, and the log now names both steps
	#    instead of one message that could mean any of three things.
	setup; store "$GOOD_ID"; STUB_SYSFS_RC=32; shim
	ok "sysfs will not mount: hands off" "$(yes_if handed_off)" "$OUT"
	ok "sysfs will not mount: nothing bound" "$(yes_if not bound)" "$(cat "$W/mount.calls")"
	ok "sysfs will not mount: says so" \
		"$(yes_if out_has "could not mount $R/sys")" "$OUT"
	ok "sysfs will not mount: and says findfs found nothing" \
		"$(yes_if out_has 'findfs found no filesystem labelled persistent')" "$OUT"
	ok "sysfs will not mount: nothing is unmounted that was never mounted" \
		"$(yes_if not grep -qxF "$R/sys" "$W/umount.calls")" "$(cat "$W/umount.calls")"

	# 8. No store yet — the first boot of a node, and the first boot after this
	#    image lands on a fielded one. Nothing is bound and the boot continues.
	setup; shim
	ok "no store: hands off" "$(yes_if handed_off)" "$OUT"
	ok "no store: nothing bound" "$(yes_if not bound)" "$(cat "$W/mount.calls")"
	ok "no store: no /run/machine-id written" "$(yes_if not test -e "$R/run/machine-id")"
	ok "no store: says a transient id is in use" "$(yes_if out_has 'this boot uses a transient id')" "$OUT"
	ok "no store: names the partition it mounted and read" \
		"$(yes_if out_has 'no machine-id stored on /dev/fake1 yet')" "$OUT"
	# This one is the EXPECTED first boot, so its reason must not read as a
	# fault. Checked on the REASON LINE alone, not on $OUT: $OUT carries the
	# scratch tree's mktemp path, and a random temp component containing the
	# needle would fail the run at random, which is a flake by construction.
	ok "no store: the reason does not read as a fault" \
		"$(yes_if not reason_matches 'but|could not|refus|unable|fail')" "$(reason_line)"

	# 9. A malformed store is refused rather than passed on. systemd would mint
	#    a transient id anyway, so binding garbage buys nothing and hides the
	#    fault.
	for bad in 'not-a-machine-id' '4F2C1AB97D3E46B08C5D1E9F7A63B204' '4f2c1ab97d3e46b08c5d1e9f7a63b20' \
		'4f2c1ab97d3e46b08c5d1e9f7a63b2045' '00000000000000000000000000000000' ''
	do
		setup; store "$bad"; shim
		ok "bad store '$bad': hands off" "$(yes_if handed_off)" "$OUT"
		ok "bad store '$bad': nothing bound" "$(yes_if not bound)" "$(cat "$W/mount.calls")"
	done

	# 10. Every way the read can fail still boots — and each one now says which
	#     step failed. dev.251 emitted "no stored machine-id yet" for all
	#     of them, so a boot log could not tell a first boot apart from a broken
	#     findfs, a wedged partition or an unreadable file, and the sysfs defect
	#     above had to be found by elimination instead. These assertions exist
	#     so that never costs a hardware round trip again: the messages must be
	#     distinct, and must name $persist_dev once findfs has produced one.
	setup; store "$GOOD_ID"; STUB_FINDFS_RC=1; shim
	ok "findfs fails: hands off" "$(yes_if handed_off)" "$OUT"
	ok "findfs fails: nothing mounted from it" \
		"$(yes_if not grep -q -- '-t ext4' "$W/mount.calls")" "$(cat "$W/mount.calls")"
	ok "findfs fails: says findfs found nothing" \
		"$(yes_if out_has 'findfs found no filesystem labelled persistent')" "$OUT"

	setup; store "$GOOD_ID"; STUB_EXT4_RC=32; shim
	ok "persistent will not mount: hands off" "$(yes_if handed_off)" "$OUT"
	ok "persistent will not mount: nothing bound" "$(yes_if not bound)" "$(cat "$W/mount.calls")"
	ok "persistent will not mount: names the device and the mountpoint" \
		"$(yes_if out_has "found /dev/fake1 but could not mount it read-only on $R/var/lib/rasputin")" "$OUT"

	setup; store "$GOOD_ID"; STUB_MOUNT_RC=1; shim
	ok "every mount fails: hands off" "$(yes_if handed_off)" "$OUT"
	ok "every mount fails: says /sys could not be mounted" \
		"$(yes_if out_has "could not mount $R/sys")" "$OUT"

	# The store is there and readable but empty, versus not there at all: two
	# different faults on disk, two different messages.
	setup; store ''; shim
	ok "empty store: hands off" "$(yes_if handed_off)" "$OUT"
	ok "empty store: says the file is empty, not that it is missing" \
		"$(yes_if out_has 'mounted /dev/fake1 but its machine-id is empty')" "$OUT"

	setup; store 'not-a-machine-id'; shim
	ok "malformed store: hands off" "$(yes_if handed_off)" "$OUT"
	ok "malformed store: says it is malformed and quotes it" \
		"$(yes_if out_has 'its machine-id is malformed: not-a-machine-id')" "$OUT"

	# A partition that will not unmount. systemd derives .mount state from
	# /proc/self/mountinfo, so one left mounted here comes up "mounted" without
	# systemd ever running mount(8): x-systemd.growfs never runs and
	# rasputin-growpart's expansion silently stops happening, while the commit
	# unit's ConditionPathIsMountPoint passes and it then fails writing to a
	# read-only filesystem. All of that is silent, so the shim has to say it.
	setup; store "$GOOD_ID"; UMOUNT_BIN="$W/nonexistent-umount"; shim
	ok "persistent will not unmount: hands off anyway" "$(yes_if handed_off)" "$OUT"
	ok "persistent will not unmount: still restores the id" "$(yes_if bound)" "$(cat "$W/mount.calls")"
	ok "persistent will not unmount: says so" \
		"$(yes_if out_has "could not unmount $R/var/lib/rasputin")" "$OUT"

	# The five ways this can degrade, one run each.
	setup; store "$GOOD_ID"; STUB_FINDFS_RC=1;  shim; m1=$OUT
	setup; store "$GOOD_ID"; STUB_EXT4_RC=32;   shim; m2=$OUT
	setup;                                      shim; m3=$OUT
	setup; store '';                            shim; m4=$OUT
	setup; store 'garbage';                     shim; m5=$OUT
	# Exactly one reason in EACH run — counted per run, because five lines
	# across five runs is also what "one run printed two, another printed
	# none" looks like, and that is the shape this assertion exists to reject.
	ones=0
	for m in "$m1" "$m2" "$m3" "$m4" "$m5"; do
		n=$(printf '%s\n' "$m" | grep -c 'this boot uses a transient id')
		[ "$n" = 1 ] && ones=$((ones + 1))
	done
	ok "each degrade prints exactly one reason" \
		"$(yes_if test "$ones" = 5)" "runs printing exactly one reason: $ones of 5"
	# ...and the five are five DIFFERENT messages. ONE message that meant three
	# things is what made this defect expensive to find, so distinctness is the
	# property, not merely that something was printed.
	reasons=$(printf '%s\n%s\n%s\n%s\n%s\n' "$m1" "$m2" "$m3" "$m4" "$m5" \
		| grep 'this boot uses a transient id')
	ok "and the five reasons are five DIFFERENT messages" \
		"$(yes_if test "$(printf '%s\n' "$reasons" | sort -u | wc -l | tr -d ' ')" = 5)" "$reasons"

	# 11. THE ONE RULE. With no mount, no umount and no findfs on the machine at
	#    all, PID 1 still reaches systemd. This is the case that separates a
	#    degraded boot from a dark node.
	setup; store "$GOOD_ID"
	MOUNT_BIN="$W/nonexistent-mount"; UMOUNT_BIN="$W/nonexistent-umount"
	FINDFS_BIN="$W/nonexistent-findfs"
	shim single
	ok "no helper binaries at all: hands off" "$(yes_if handed_off)" "$OUT"
	ok "no helper binaries at all: kernel args survive" \
		"$(yes_if file_is "$W/handoff.args" "single")" "$(cat "$W/handoff.args" 2>/dev/null)"

	# 12. Run by hand rather than by the kernel, the shim is what the symlink it
	#    replaced was: it execs systemd and touches nothing. (RASPUTIN_INIT_TEST
	#    unset is the real-world case; the overrides exist only for this file.)
	setup; store "$GOOD_ID"
	case "$SH" in
		busybox_sh) set -- busybox sh "$SHIM" --version ;;
		*)          set -- "$SH" "$SHIM" --version ;;
	esac
	OUT=$(STUB_MOUNT_CALLS="$W/mount.calls" "$@" 2>&1)
	ok "run by hand: does not mount anything" \
		"$(yes_if test ! -s "$W/mount.calls")" "$(cat "$W/mount.calls")"

	# --- the commit half ------------------------------------------------------

	# 13. First boot: whatever id the node is running with becomes the stored
	#     one. The node KEEPS the identity it already has rather than being
	#     handed a new one, so a fielded node changes id exactly once.
	setup; printf '%s\n' "$GOOD_ID" >"$R/etc/machine-id"; commit
	ok "commit: succeeds" "$(yes_if test "$RC" = 0)" "$OUT"
	ok "commit: stores the running id" \
		"$(yes_if file_is "$PERSIST/machine-id" "$GOOD_ID")" "$(cat "$PERSIST/machine-id" 2>/dev/null)"
	ok "commit: store is 0444" \
		"$(yes_if test "$(perms "$PERSIST/machine-id")" = '-r--r--r--')" "$(perms "$PERSIST/machine-id")"
	ok "commit: leaves no temp file" "$(yes_if not test -e "$PERSIST/machine-id.tmp")"
	ok "commit: says it takes effect next boot" "$(yes_if out_has 'next boot')" "$OUT"

	# 14. Every boot after: a no-op.
	commit
	ok "commit again: still 0" "$(yes_if test "$RC" = 0)" "$OUT"
	ok "commit again: unchanged" "$(yes_if file_is "$PERSIST/machine-id" "$GOOD_ID")"
	ok "commit again: says already committed" "$(yes_if out_has 'already committed')" "$OUT"

	# 15. THE SECOND RULE. A store that disagrees with the running id means the
	#     restore did not happen — /sbin/init reverted, findfs gone, partition
	#     unreadable. Overwriting would restart the churn and write a new id to
	#     disk on every boot. Report, change nothing.
	setup; store "$OTHER_ID"; printf '%s\n' "$GOOD_ID" >"$R/etc/machine-id"; commit
	ok "disagreement: exits 0" "$(yes_if test "$RC" = 0)" "$OUT"
	ok "disagreement: store is NOT replaced" \
		"$(yes_if file_is "$PERSIST/machine-id" "$OTHER_ID")" "$(cat "$PERSIST/machine-id" 2>/dev/null)"
	ok "disagreement: warns that the restore did not happen" \
		"$(yes_if out_has 'was NOT restored this boot')" "$OUT"

	# 16. A running id that is not a machine-id is never written to the store.
	setup; printf 'uninitialized\n' >"$R/etc/machine-id"; commit
	ok "bad running id: exits 0" "$(yes_if test "$RC" = 0)" "$OUT"
	ok "bad running id: nothing stored" "$(yes_if not test -e "$PERSIST/machine-id")"
	ok "bad running id: says why" "$(yes_if out_has 'refusing to commit')" "$OUT"

	setup; rm -f "$R/etc/machine-id"; commit
	ok "no running id: exits 0" "$(yes_if test "$RC" = 0)" "$OUT"
	ok "no running id: nothing stored" "$(yes_if not test -e "$PERSIST/machine-id")"

	# 17. An unusable store IS replaced — it is not an identity, it is damage.
	setup; store 'garbage'; printf '%s\n' "$GOOD_ID" >"$R/etc/machine-id"; commit
	ok "unusable store: replaced" \
		"$(yes_if file_is "$PERSIST/machine-id" "$GOOD_ID")" "$(cat "$PERSIST/machine-id" 2>/dev/null)"
}

for SH in $TEST_SHELLS; do
	echo "== $SH"
	cases
done

# --- what ships ---------------------------------------------------------------
# Shell-independent, so checked once.
SH=static

echo "== static"
ok "the shim is executable" "$(yes_if test -x "$SHIM")"
ok "the shim is /bin/sh, the image's shell" \
	"$(yes_if test "$(head -1 "$SHIM")" = '#!/bin/sh')" "$(head -1 "$SHIM")"
ok "the commit script is executable" "$(yes_if test -x "$COMMIT")"

# The hand-off is the last thing in the file, unindented: every path through the
# script reaches it. A hand_off tucked inside an `if` is the shape that boots a
# node only on the happy path.
last=$(grep -v '^[[:space:]]*#' "$SHIM" | grep -v '^[[:space:]]*$' | tail -1)
ok "the shim's last statement is the unconditional hand-off" \
	"$(yes_if test "$last" = 'hand_off "$@"')" "last statement: $last"

# `set -e` in PID 1 turns any unguarded non-zero — a missing file, a failed
# probe — into an exit, and an exiting PID 1 is a kernel panic, not a degraded
# boot. `set -u` does the same for the first unset variable.
ok "the shim does not use set -e" "$(yes_if not grep -Eq '^[[:space:]]*set[[:space:]]+-[a-z]*e' "$SHIM")"
ok "the shim does not use set -u" "$(yes_if not grep -Eq '^[[:space:]]*set[[:space:]]+-[a-z]*u' "$SHIM")"

# The shim and post-build.sh must name the same systemd: post-build refuses to
# ship a rootfs where that path is not executable, which is the check that stops
# an upstream move from producing a node that panics on the first boot.
ok "the shim execs $SYSTEMD_PATH" \
	"$(yes_if grep -qx "SYSTEMD=$SYSTEMD_PATH" "$SHIM")"
ok "post-build asserts the same systemd path" \
	"$(yes_if grep -qx "INIT_REAL=$SYSTEMD_PATH" "$POSTBUILD")"

# The build step itself: it must repoint /sbin/init, and it must refuse rather
# than guess if /sbin/init is not the systemd symlink it expects.
ok "post-build repoints /sbin/init at the shim" \
	"$(yes_if grep -qx 'INIT_SHIM=/usr/lib/rasputin/machine-id/rasputin-init' "$POSTBUILD")"
ok "post-build links it" \
	"$(yes_if grep -qx 'ln -sf "$INIT_SHIM" "$INIT_LINK"' "$POSTBUILD")"
ok "post-build refuses a /sbin/init that is not a symlink" \
	"$(yes_if grep -qF 'is not a symlink — refusing to replace it' "$POSTBUILD")"
ok "post-build refuses a /sbin/init that does not point at systemd" \
	"$(yes_if grep -qF 'not systemd — refusing to replace it' "$POSTBUILD")"
ok "post-build refuses a rootfs with no shim in it" \
	"$(yes_if grep -qF 'missing or non-executable $INIT_SHIM' "$POSTBUILD")"
ok "post-build enables rasputin-machine-id-commit.service" \
	"$(yes_if grep -qF 'multi-user.target.wants/rasputin-machine-id-commit.service' "$POSTBUILD")"

# The unit. It writes a value that takes effect on the NEXT boot, so it must
# block nothing: an Ordering that put it in front of anything would make a
# wedged persistent partition a boot delay for no gain.
ok "unit runs the commit script" \
	"$(yes_if grep -qx 'ExecStart=/usr/lib/rasputin/machine-id/rasputin-machine-id-commit.sh' "$UNIT")"
ok "unit requires the persistent mount" \
	"$(yes_if grep -qx 'RequiresMountsFor=/var/lib/rasputin' "$UNIT")"
ok "unit skips itself when the persistent partition did not mount" \
	"$(yes_if grep -qx 'ConditionPathIsMountPoint=/var/lib/rasputin' "$UNIT")"
ok "unit is a oneshot that stays active" \
	"$(yes_if grep -qx 'RemainAfterExit=yes' "$UNIT")"
ok "unit is wanted by multi-user.target" \
	"$(yes_if grep -qx 'WantedBy=multi-user.target' "$UNIT")"
ok "unit orders itself before nothing" \
	"$(yes_if not grep -Eq '^Before=' "$UNIT")" "$(grep -E '^Before=' "$UNIT" 2>/dev/null)"

# --- the build step -----------------------------------------------------------
# post-build.sh actually run over a target dir shaped like the one Buildroot
# hands it. Grepping the script says what it is written to do; running it says
# what it does — and the refusals below are the only thing standing between an
# upstream change to /sbin/init and a node that panics before it can roll back.
echo "== build"
SH=build

# make_target DIR [init symlink target] — a target dir with the parts this step
# touches: the systemd binary, /sbin/init pointing at it, and the shim that the
# rootfs overlay would already have copied in.
make_target() {
	_d="$1"
	rm -rf "$_d"
	mkdir -p "$_d/etc" "$_d/sbin" "$_d/usr/lib/systemd" "$_d/usr/lib/rasputin/machine-id" "$_d/var/lib"
	printf 'root:x:0:0:root:/root:/bin/sh\n' >"$_d/etc/passwd"
	printf 'root:*:20000:0:99999:7:::\n' >"$_d/etc/shadow"; chmod 600 "$_d/etc/shadow"
	printf 'root:x:0:\n' >"$_d/etc/group"
	printf 'root:*::\n' >"$_d/etc/gshadow"
	printf '#!/bin/sh\nexit 0\n' >"$_d/usr/lib/systemd/systemd"; chmod +x "$_d/usr/lib/systemd/systemd"
	cp "$SHIM" "$_d/usr/lib/rasputin/machine-id/rasputin-init"
	chmod +x "$_d/usr/lib/rasputin/machine-id/rasputin-init"
	ln -s "${2:-../lib/systemd/systemd}" "$_d/sbin/init"
	unset _d
}
# post_build DIR — run it; sets OUT and RC.
post_build() { OUT=$(sh "$POSTBUILD" "$1" n100 2>&1); RC=$?; }

T="$TMP/target"
make_target "$T"; post_build "$T"
ok "post-build succeeds on a normal target dir" "$(yes_if test "$RC" = 0)" "$OUT"
ok "post-build points /sbin/init at the shim" \
	"$(yes_if test "$(readlink "$T/sbin/init")" = "$SHIM_PATH")" "$(readlink "$T/sbin/init")"
ok "post-build enables the commit unit in the target dir" \
	"$(yes_if test -L "$T/etc/systemd/system/multi-user.target.wants/rasputin-machine-id-commit.service")"

# An incremental `make` re-runs target-finalize over a tree already swapped.
post_build "$T"
ok "post-build is idempotent (a second run over the same tree)" "$(yes_if test "$RC" = 0)" "$OUT"
ok "post-build leaves the link pointing at the shim" \
	"$(yes_if test "$(readlink "$T/sbin/init")" = "$SHIM_PATH")" "$(readlink "$T/sbin/init")"

# The refusals. Each of these is a rootfs that would boot to a kernel panic if
# it shipped, and none of them looks different from a good one.
make_target "$T" '../bin/busybox'; post_build "$T"
ok "refuses a /sbin/init that is not systemd" "$(yes_if test "$RC" != 0)" "$OUT"
ok "refuses it out loud" "$(yes_if out_has 'not systemd')" "$OUT"

make_target "$T"; rm -f "$T/sbin/init"; printf '#!/bin/sh\n' >"$T/sbin/init"; post_build "$T"
ok "refuses a /sbin/init that is a regular file" "$(yes_if test "$RC" != 0)" "$OUT"

make_target "$T"; rm -f "$T/usr/lib/rasputin/machine-id/rasputin-init"; post_build "$T"
ok "refuses a rootfs with no shim in it" "$(yes_if test "$RC" != 0)" "$OUT"
ok "leaves /sbin/init alone when it refuses" \
	"$(yes_if test "$(readlink "$T/sbin/init")" = '../lib/systemd/systemd')" "$(readlink "$T/sbin/init")"

make_target "$T"; chmod -x "$T/usr/lib/rasputin/machine-id/rasputin-init"; post_build "$T"
ok "refuses a shim that is not executable" "$(yes_if test "$RC" != 0)" "$OUT"

# The case the guard exists for: systemd moves, the shim's exec target stops
# existing, and every node that takes the image panics on its first boot with
# no slot to roll back to.
make_target "$T"; rm -f "$T/usr/lib/systemd/systemd"; post_build "$T"
ok "refuses when the shim's exec target is gone" "$(yes_if test "$RC" != 0)" "$OUT"
ok "says the shim would exec nothing" "$(yes_if out_has 'would exec nothing')" "$OUT"

echo
echo "machine-id: $pass passed, $fail failed (shells:$TEST_SHELLS)"
[ "$fail" -eq 0 ]
