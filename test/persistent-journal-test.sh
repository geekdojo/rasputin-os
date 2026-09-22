#!/bin/sh
#
# Tests for persistent journal storage (geekdojo/geekdojo-brain#601): the unit
# that bind-mounts /var/lib/rasputin/journal over /var/log/journal, the journald
# drop-in that tells journald to use it and bounds what it keeps, the tmpfiles
# file that holds the mode there, the at-rest declaration, and the build step
# that enables the unit.
#
# WHY THIS IS TESTED AT ALL. Every part of this change is declarative — a unit,
# a config drop-in, a tmpfiles line, an inventory line — and every way it can be
# wrong is SILENT. There is no error to see and nothing in a build differs:
#
#   * the unit enabled into multi-user.target instead of sysinit.target still
#     mounts the store, just after systemd-journal-flush.service has already
#     concluded there is no persistent store. Boots look identical and the
#     journal is still volatile. This is the shape the existing bind-mount
#     precedent (rasputin-coredump-store.service) has, which is exactly why it
#     is the easy mistake to make;
#   * without DefaultDependencies=no the unit is in an ordering cycle with
#     sysinit.target, and systemd resolves a cycle by dropping an edge of its
#     own choosing — so it works until it does not, on a boot nobody changed;
#   * the tmpfiles line in the wrong file loses to stock systemd.conf and
#     /var/log/journal goes back to 2755 root:systemd-journal, world-listable,
#     under a /var/log that is 0777 — and the at-rest audit then FAILS on every
#     node instead;
#   * Storage= left at its default is what produced the defect in the first
#     place: `auto` decides from whether a directory happens to be writable and
#     says nothing either way;
#   * the retention caps left to journald are derived from the size of a
#     filesystem that this image grows on first boot, so they differ per unit
#     and are smallest on the node whose growpart failed.
#
# So what is pinned here is the SHAPE of what ships, one assertion per way it
# can silently stop working.
#
# WHAT THIS DOES NOT PROVE. That journald actually flushes into the bind mount
# on a real boot. That needs an image build and a reboot; the commands are in
# the pull request. The two claims that can be checked against real systemd
# without hardware — that the tmpfiles file beats stock systemd.conf, and that
# journald with this drop-in writes to /var/log/journal rather than /run — are
# in test/persistent-journal-functional.sh, which runs them against real
# systemd 256.17, the image's version.
#
# Shells. Unlike the other suites here this one loops over no shells and does
# not need busybox: the change adds no shell script to the node. Every case
# below is either a property of a file that ships or a real run of
# post-build.sh, and neither depends on which shell reads it.
#
# Run:  sh test/persistent-journal-test.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
UNITDIR="$OVERLAY/etc/systemd/system"
UNIT="$UNITDIR/rasputin-journal-store.service"
JOURNALD="$OVERLAY/etc/systemd/journald.conf.d/rasputin.conf"
TMPFILESDIR="$OVERLAY/usr/lib/tmpfiles.d"
JTMPFILES="$TMPFILESDIR/zz-rasputin-journal.conf"
RTMPFILES="$TMPFILESDIR/rasputin.conf"
INVENTORY="$OVERLAY/usr/lib/rasputin/atrest/inventory"
POSTBUILD="$ROOT/board/rasputin/common/post-build.sh"

# The persistent store and the mountpoint it is bound over. Named once here and
# then asserted everywhere, because the whole change is four files agreeing on
# two paths.
STORE=/var/lib/rasputin/journal
MOUNTPOINT=/var/log/journal

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

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
has() { grep -qE "$1" "$2" 2>/dev/null; }
hasx() { grep -qxF "$1" "$2" 2>/dev/null; }

# Every file this change consists of. A missing one is a failure here rather
# than a confusing run of empty greps below — on main, before the change, this
# is where the suite stops.
echo "== files"
SH=files
for f in "$UNIT" "$JOURNALD" "$JTMPFILES" "$INVENTORY" "$RTMPFILES" "$POSTBUILD"; do
	ok "ships $(echo "$f" | sed "s#^$ROOT/##")" "$(yes_if test -f "$f")"
done
if [ "$fail" -ne 0 ]; then
	echo "persistent-journal: $pass passed, $fail failed" >&2
	echo "  (a file the change consists of is missing — nothing below can mean anything)" >&2
	exit 1
fi

# ── the unit ───────────────────────────────────────────────────────────────
echo "== unit"
SH=unit

# The three ExecStarts, in the order the store has to be built: the directory,
# then its mode, then the bind mount. chmod is unconditional and not a mkdir
# mode, because a store left behind by an older image keeps whatever mode it
# already had — the same reasoning as the coredump store's.
ok "unit creates the store" "$(yes_if hasx "ExecStart=/bin/mkdir -p $STORE" "$UNIT")" "$(grep -n ExecStart "$UNIT")"
ok "unit sets the store to 0700" "$(yes_if hasx "ExecStart=/bin/chmod 0700 $STORE" "$UNIT")" "$(grep -n ExecStart "$UNIT")"
ok "unit bind-mounts the store over $MOUNTPOINT" \
	"$(yes_if hasx "ExecStart=/bin/mount -o bind $STORE $MOUNTPOINT" "$UNIT")" "$(grep -n ExecStart "$UNIT")"
ok "the mkdir comes before the chmod, which comes before the mount" \
	"$(yes_if test "$(grep -n '^ExecStart=' "$UNIT" | sed -n 's/.*\/bin\/\([a-z]*\).*/\1/p' | tr '\n' ' ')" = 'mkdir chmod mount ')" \
	"$(grep -n '^ExecStart=' "$UNIT")"

# THE ORDERING. Each of these three lines is load-bearing on its own; see the
# unit for the argument. Asserted separately so a failure names which one went.
ok "unit is ordered before the journal flush" \
	"$(yes_if hasx 'Before=systemd-journal-flush.service' "$UNIT")" "$(grep -n '^Before=' "$UNIT")"
ok "unit requires the persistent mount" \
	"$(yes_if hasx 'RequiresMountsFor=/var/lib/rasputin' "$UNIT")" "$(grep -n 'RequiresMountsFor' "$UNIT")"
# Without this the unit inherits After=sysinit.target, and the flush it orders
# itself in front of is ordered before systemd-tmpfiles-setup.service, which is
# part of sysinit.target. That is a cycle, and systemd breaks a cycle by
# dropping an edge it chooses — which would make this arrangement work on some
# boots and not others.
ok "unit has DefaultDependencies=no" \
	"$(yes_if hasx 'DefaultDependencies=no' "$UNIT")" "$(cat "$UNIT")"
ok "unit does not order itself after sysinit.target" \
	"$(yes_if not has '^After=.*sysinit\.target' "$UNIT")" "$(grep -n '^After=' "$UNIT")"

# THE INSTALL TARGET is the difference between this working and looking like it
# works. systemd-journal-flush.service is WantedBy=sysinit.target; a unit wanted
# by multi-user.target starts long after the flush has already decided there is
# no persistent store, so the mount lands and the boot's own log is still lost.
ok "unit is wanted by sysinit.target" \
	"$(yes_if hasx 'WantedBy=sysinit.target' "$UNIT")" "$(grep -n 'WantedBy' "$UNIT")"
ok "unit is NOT wanted by multi-user.target (too late for the flush)" \
	"$(yes_if not has '^WantedBy=.*multi-user\.target' "$UNIT")" "$(grep -n 'WantedBy' "$UNIT")"

ok "unit skips itself when the persistent partition did not mount" \
	"$(yes_if hasx 'ConditionPathIsMountPoint=/var/lib/rasputin' "$UNIT")" "$(cat "$UNIT")"
ok "unit is a oneshot that stays active" \
	"$(yes_if hasx 'Type=oneshot' "$UNIT")" "$(cat "$UNIT")"
ok "unit is a oneshot that stays active (RemainAfterExit)" \
	"$(yes_if hasx 'RemainAfterExit=yes' "$UNIT")" "$(cat "$UNIT")"

# NO ExecStop. systemd-journal-flush.service is Conflicts=soft-reboot.target
# only, so on an ordinary reboot its `journalctl --smart-relinquish-var` never
# runs and journald still holds system.journal open; a umount would return
# EBUSY and leave this unit failed, and the QEMU smoke asserts `systemctl
# --failed` is empty.
ok "unit does not try to umount the store at stop" \
	"$(yes_if not has '^ExecStop=' "$UNIT")" "$(grep -n '^ExecStop=' "$UNIT")"

# ── the journald drop-in ───────────────────────────────────────────────────
echo "== journald"
SH=journald
ok "drop-in is under journald.conf.d" \
	"$(yes_if test "$JOURNALD" = "$OVERLAY/etc/systemd/journald.conf.d/rasputin.conf")"
ok "drop-in has a [Journal] section" "$(yes_if hasx '[Journal]' "$JOURNALD")" "$(cat "$JOURNALD")"

# Storage is stated, not inferred. `auto` is the default and is what shipped;
# it decides from whether /var/log/journal happens to be writable and reports
# the decision nowhere, which is how every node ran with no history until #547
# needed it.
ok "storage is persistent, explicitly" \
	"$(yes_if hasx 'Storage=persistent' "$JOURNALD")" "$(grep -n '^Storage=' "$JOURNALD")"
ok "storage is not left at auto or set volatile" \
	"$(yes_if not has '^Storage=(auto|volatile|none)' "$JOURNALD")" "$(grep -n '^Storage=' "$JOURNALD")"

# All four caps, and all four as absolute sizes. A percentage is derived from
# the filesystem, and this image ships a 512M persistent partition that
# rasputin-growpart grows to fill the medium on first boot — so a percentage
# gives a different retention on every unit and the smallest retention on the
# node whose grow failed, which is the node most likely to need reading.
for k in SystemMaxUse SystemKeepFree SystemMaxFileSize MaxRetentionSec; do
	ok "$k is set" "$(yes_if has "^$k=" "$JOURNALD")" "$(cat "$JOURNALD")"
	ok "$k is not a percentage of the filesystem" \
		"$(yes_if not has "^$k=.*%" "$JOURNALD")" "$(grep -n "^$k=" "$JOURNALD")"
done

# The neighbours. Docker and containerd image data, the api's data directory
# and agent state share this partition, so the journal must yield to them: on
# an ungrown 512M partition KeepFree binds and journald vacuums itself down,
# and KeepFree can only do that if it is larger than the cap.
MAXUSE=$(sed -n 's/^SystemMaxUse=\([0-9]*\)M$/\1/p' "$JOURNALD")
KEEPFREE=$(sed -n 's/^SystemKeepFree=\([0-9]*\)G$/\1/p' "$JOURNALD")
MAXFILE=$(sed -n 's/^SystemMaxFileSize=\([0-9]*\)M$/\1/p' "$JOURNALD")
ok "SystemMaxUse is a whole number of MiB" "$(yes_if test -n "$MAXUSE")" "$(grep -n SystemMaxUse "$JOURNALD")"
ok "SystemKeepFree is a whole number of GiB" "$(yes_if test -n "$KEEPFREE")" "$(grep -n SystemKeepFree "$JOURNALD")"
ok "SystemMaxFileSize is a whole number of MiB" "$(yes_if test -n "$MAXFILE")" "$(grep -n SystemMaxFileSize "$JOURNALD")"
if [ -n "$MAXUSE" ] && [ -n "$KEEPFREE" ]; then
	ok "KeepFree is larger than MaxUse, so the neighbours win on a small partition" \
		"$(yes_if test "$((KEEPFREE * 1024))" -gt "$MAXUSE")" "MaxUse=${MAXUSE}M KeepFree=${KEEPFREE}G"
	# The partition genimage ships before rasputin-growpart grows it.
	ok "MaxUse alone cannot fill the 512M partition the image ships" \
		"$(yes_if test "$MAXUSE" -le 512 )" "MaxUse=${MAXUSE}M"
fi
if [ -n "$MAXUSE" ] && [ -n "$MAXFILE" ]; then
	ok "MaxFileSize leaves room for several files at the cap" \
		"$(yes_if test "$((MAXUSE / MAXFILE))" -ge 4)" "MaxUse=${MAXUSE}M MaxFileSize=${MAXFILE}M"
fi

# ── the mode, and the file that holds it ───────────────────────────────────
echo "== tmpfiles"
SH=tmpfiles

# Stock systemd.conf carries `z /var/log/journal 2755 root systemd-journal`, and
# systemd-tmpfiles-setup.service runs after systemd-journal-flush.service — so
# that line lands on the bind-mounted store on every boot. Of two lines naming
# one path the LAST applied wins, and files are read in lexicographic order of
# basename, so ours has to sort after "systemd.conf". Measured against real
# systemd-tmpfiles 256.17 in test/persistent-journal-functional.sh.
BASE=$(basename "$JTMPFILES")
ok "the tmpfiles file sorts after systemd.conf" \
	"$(yes_if test "$(printf '%s\nsystemd.conf\n' "$BASE" | sort | tail -1)" = "$BASE")" \
	"basename=$BASE"
ok "it pins $MOUNTPOINT to 0700 root root" \
	"$(yes_if has "^z[[:space:]]+$MOUNTPOINT[[:space:]]+0700[[:space:]]+root[[:space:]]+root" "$JTMPFILES")" \
	"$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$JTMPFILES")"
ok "it adjusts rather than creates (z, not d/Z)" \
	"$(yes_if not has "^[dZ][[:space:]]+$MOUNTPOINT" "$JTMPFILES")" \
	"$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$JTMPFILES")"
# rasputin.conf sorts BEFORE systemd.conf, so a line put there would be
# overwritten by stock systemd and would look like it worked in review.
# Directive lines only — rasputin.conf carries a comment pointing at the other
# file, and a check that could not tell a comment from a directive would be
# asserting nothing the day someone writes one.
ok "rasputin.conf has no directive line for the journal (it would lose)" \
	"$(yes_if not grep -qE "^[^#][^[:space:]]*[[:space:]]+$MOUNTPOINT([[:space:]]|\$)" "$RTMPFILES")" \
	"$(grep -nE "^[^#][^[:space:]]*[[:space:]]+$MOUNTPOINT([[:space:]]|\$)" "$RTMPFILES")"

# ── the at-rest declaration ────────────────────────────────────────────────
echo "== at-rest"
SH=atrest
# The audit is a release gate (geekdojo/geekdojo-brain#494) and this is new
# writable state on the persistent partition, so it is declared. Optional, not
# required: the store appears only once the unit has run.
ok "the inventory declares the store" \
	"$(yes_if has "^0700[[:space:]]+optional[[:space:]]+$STORE\$" "$INVENTORY")" \
	"$(grep -n 'journal' "$INVENTORY")"
# Not swept: journald owns everything under it and stock tmpfiles puts
# system.journal at 0640 root:systemd-journal. A sweep would be asserting modes
# this image does not set, and would fail on every node the moment journald
# wrote its first file.
ok "the store is not swept" \
	"$(yes_if not has "^sweep[[:space:]]+$STORE\$" "$INVENTORY")" "$(grep -n '^sweep' "$INVENTORY")"
# The declared mode and the mode the unit sets have to be the same number.
ok "the inventory's mode and the unit's chmod agree" \
	"$(yes_if test "$(sed -n "s#^\([0-7]\{4\}\)[[:space:]]\{1,\}optional[[:space:]]\{1,\}$STORE\$#\1#p" "$INVENTORY")" \
		= "$(sed -n "s#^ExecStart=/bin/chmod \([0-7]\{4\}\) $STORE\$#\1#p" "$UNIT")")" \
	"inventory=$(grep -F "$STORE" "$INVENTORY") unit=$(grep -F "chmod" "$UNIT")"

# ── the build step ─────────────────────────────────────────────────────────
# Grepping post-build.sh says what it is written to do; running it says what it
# does. The symlink is the entire difference between a unit that ships and a
# unit that ships disabled, and a disabled unit is invisible in a build.
echo "== build"
SH=build
ok "post-build enables the unit into sysinit.target.wants" \
	"$(yes_if grep -qF 'sysinit.target.wants/rasputin-journal-store.service' "$POSTBUILD")" \
	"$(grep -n 'journal-store' "$POSTBUILD")"
ok "post-build does not enable it into multi-user.target.wants" \
	"$(yes_if not grep -qF 'multi-user.target.wants/rasputin-journal-store.service' "$POSTBUILD")" \
	"$(grep -n 'journal-store' "$POSTBUILD")"

# A target dir shaped like the one Buildroot hands post-build.sh. Only the
# parts this step touches are present; the machine-id suite builds the same
# fixture for the same reason.
T="$TMP/target"
rm -rf "$T"
mkdir -p "$T/etc" "$T/sbin" "$T/usr/lib/systemd" "$T/usr/lib/rasputin/machine-id" "$T/var/lib"
printf 'root:x:0:0:root:/root:/bin/sh\n' >"$T/etc/passwd"
printf 'root:*:20000:0:99999:7:::\n' >"$T/etc/shadow"; chmod 600 "$T/etc/shadow"
printf 'root:x:0:\n' >"$T/etc/group"
printf 'root:*::\n' >"$T/etc/gshadow"
printf '#!/bin/sh\nexit 0\n' >"$T/usr/lib/systemd/systemd"; chmod +x "$T/usr/lib/systemd/systemd"
cp "$OVERLAY/usr/lib/rasputin/machine-id/rasputin-init" "$T/usr/lib/rasputin/machine-id/rasputin-init"
chmod +x "$T/usr/lib/rasputin/machine-id/rasputin-init"
ln -s ../lib/systemd/systemd "$T/sbin/init"
OUT=$(sh "$POSTBUILD" "$T" n100 2>&1); RC=$?
ok "post-build succeeds on a normal target dir" "$(yes_if test "$RC" = 0)" "$OUT"
ok "post-build leaves the unit enabled at sysinit" \
	"$(yes_if test -L "$T/etc/systemd/system/sysinit.target.wants/rasputin-journal-store.service")" \
	"$(ls -l "$T/etc/systemd/system/sysinit.target.wants" 2>&1)"
ok "the symlink points at the unit in the overlay's location" \
	"$(yes_if test "$(readlink "$T/etc/systemd/system/sysinit.target.wants/rasputin-journal-store.service")" \
		= /etc/systemd/system/rasputin-journal-store.service)" \
	"$(readlink "$T/etc/systemd/system/sysinit.target.wants/rasputin-journal-store.service" 2>&1)"
OUT=$(sh "$POSTBUILD" "$T" n100 2>&1); RC=$?
ok "post-build is idempotent (a second run over the same tree)" "$(yes_if test "$RC" = 0)" "$OUT"

echo
echo "persistent-journal: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
