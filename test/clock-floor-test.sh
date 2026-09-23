#!/bin/sh
# Tests for the no-RTC clock floor, end to end: what the BUILD bakes, what the
# PID 1 shim restores, what the SAVE half persists, and what the timesyncd
# seeding unit does with the rest.
#
# ── why this is tested at all, and why the first version was not enough ──────
#
# The floor is an MTIME on an empty file and a ten-digit number in another one:
# nothing to read back in a log, nothing a boot test prints, and a build that
# silently stops baking it produces an image that looks identical and mints
# already-expired certificates on every offline first boot
# (geekdojo/rasputin-os#1) while losing every Pi's journal on every boot
# (geekdojo/geekdojo-brain#601).
#
# PR #101's tests passed while the feature did nothing. They asserted the build
# wrote a file and stamped it, which was true — and missed that the file was
# written somewhere systemd-timesyncd cannot use, because timesyncd opens its
# timestamp file READ-WRITE and the rootfs is a read-only squashfs. The tests
# proved the bake; the bake was never the risky half.
#
# The arm64 fix adds two more halves that fail in exactly the same silent way:
#
#   * /usr/lib/clock-epoch. PID 1 stats it and falls back to the systemd
#     PACKAGE's build time — fifteen months stale on 2026.09.4 — when it is
#     absent. A build that stops baking it looks identical and puts every Pi
#     back to booting in 2025;
#   * the persisted last-known-good time. It is read by /sbin/init, before
#     systemd, before journald, and before anything that could report a
#     problem. A shim that reads it wrongly either does nothing (invisible) or
#     panics PID 1 (a dark node with no rollback).
#
# So the cases below cover the bake, the restore, the save and the seeding, and
# each one asserts the direction the floor may move as well as that it moved.
#
# Everything is faked: a minimal TARGET_DIR for post-fakeroot.sh; a fake factory
# copy plus a state dir made genuinely unwritable for the seeding unit; and for
# the shim a scratch tree with stub mount/umount/findfs, a stub hand-off target
# and — above all — A STUB `date`. No root, no fakeroot, no Buildroot, no mount,
# and nothing that can set the clock of the machine running the suite.
#
# Run:  sh test/clock-floor-test.sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
FAKEROOT="$ROOT/board/rasputin/common/post-fakeroot.sh"
BOOT="$OVERLAY/usr/lib/rasputin/clock/rasputin-clock-floor.sh"
SAVE="$OVERLAY/usr/lib/rasputin/clock/rasputin-clock-save.sh"
SHIM="$OVERLAY/usr/lib/rasputin/machine-id/rasputin-init"
UNIT="$OVERLAY/etc/systemd/system/rasputin-clock-floor.service"
SAVE_UNIT="$OVERLAY/etc/systemd/system/rasputin-clock-save.service"
TICK_UNIT="$OVERLAY/etc/systemd/system/rasputin-clock-tick.service"
TICK_TIMER="$OVERLAY/etc/systemd/system/rasputin-clock-tick.timer"
POSTBUILD="$ROOT/board/rasputin/common/post-build.sh"
for f in "$FAKEROOT" "$BOOT" "$SAVE" "$SHIM" "$UNIT" "$SAVE_UNIT" "$TICK_UNIT" "$TICK_TIMER" "$POSTBUILD"; do
	[ -f "$f" ] || { echo "missing: $f"; exit 1; }
done

fails=0
check() {
	if [ "$2" = "$3" ]; then echo "ok   — $1"
	else echo "FAIL — $1: expected '$3', got '$2'"; fails=$((fails + 1)); fi
}
# grep_ok LABEL PATTERN FILE — a grep -qE assertion with the file named on
# failure. Used for the wiring section, where every claim is "this file says
# this", and a bare grep would report nothing but a number.
grep_ok() {
	if grep -qE "$2" "$3" 2>/dev/null; then echo "ok   — $1"
	else echo "FAIL — $1: '$2' not in $3"; fails=$((fails + 1)); fi
}
grep_not() {
	if grep -qE "$2" "$3" 2>/dev/null; then echo "FAIL — $1: '$2' IS in $3"; fails=$((fails + 1))
	else echo "ok   — $1"; fi
}

TMP=$(mktemp -d); trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

make_target() {
	t="$1"; rm -rf "$t"; mkdir -p "$t/etc"
	printf 'root:*:19000:0:99999:7:::\n' > "$t/etc/shadow"
	printf 'root:x:0:0:root:/root:/bin/sh\n' > "$t/etc/passwd"
	printf 'systemd-timesync:x:104:108::/:/bin/false\n' >> "$t/etc/passwd"
}
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
mode_of() { ls -l "$1" 2>/dev/null | cut -c1-10; }

# A `date` that cannot touch the clock of the machine running this suite, and
# that answers the same way on GNU coreutils and on BSD date so the suite is not
# a different test on a Mac than it is in CI.
#
#   -u +%s              -> $STUB_NOW
#   -u -r FILE +%s      -> FILE's mtime (BSD `date -r` takes SECONDS, not a
#                          file, so this cannot be delegated to the real one)
#   -u -r FILE +<other> -> a fixed string; only ever used in a log line
#   -u -s @SECONDS      -> recorded, and NOT applied. $STUB_SET_RC is its exit
#                          status, so "the clock could not be set" is testable.
make_date_stub() {
	cat >"$1" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_DATE_CALLS"
case "$*" in
	*" -s @"*) exit "${STUB_SET_RC:-0}" ;;
	"-u +%s")  printf '%s\n' "$STUB_NOW"; exit 0 ;;
esac
# -u -r FILE FMT
f=; fmt=
set -- $*
while [ $# -gt 0 ]; do
	case "$1" in
		-r) f=$2; shift 2 ;;
		+*) fmt=$1; shift ;;
		*)  shift ;;
	esac
done
if [ -n "$f" ]; then
	case "$fmt" in
		'+%s') stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null; exit 0 ;;
		*)     echo 'stubbed-date'; exit 0 ;;
	esac
fi
exit 1
STUB
	chmod +x "$1"
}

echo "1. what the BUILD bakes"

T="$TMP/ok"; make_target "$T"
before=$(date -u +%s); out=$(sh "$FAKEROOT" "$T" rpi 2>&1); rc=$?; after=$(date -u +%s)
FLOOR="$T/usr/share/factory/rasputin/timesync-clock"
EPOCH="$T/usr/lib/clock-epoch"
check "exits 0 on a well-formed target" "$rc" "0"
check "the timesyncd floor is baked as a FACTORY copy" "$([ -f "$FLOOR" ] && echo yes || echo no)" "yes"
# The #101 regression, pinned: the state path must NOT be what the build writes,
# because timesyncd cannot open a read-only squashfs file for writing.
check "nothing is baked into the read-only state path" \
	"$([ -e "$T/var/lib/systemd/timesync/clock" ] && echo yes || echo no)" "no"
check "the floor is empty (timesyncd stats it, never reads it)" \
	"$(wc -c < "$FLOOR" | tr -d ' ')" "0"
m=$(mtime_of "$FLOOR")
if [ -n "$m" ] && [ "$m" -ge "$before" ] && [ "$m" -le "$after" ]; then
	echo "ok   — the floor's mtime is this build's timestamp"
else
	echo "FAIL — the floor's mtime is this build's timestamp: got '$m', wanted ${before}..${after}"; fails=$((fails + 1))
fi

# ── /usr/lib/clock-epoch ─────────────────────────────────────────────────────
# PID 1's OWN floor, and the half the image never had. systemd 256's
# clock_apply_epoch() stats this path and falls back to the compiled TIME_EPOCH
# — the systemd PACKAGE's build date, 2025-06-25 on 2026.09.4 — only when the
# stat fails. Absent from the image, so every no-RTC node booted fifteen months
# in the past. Nothing else in the tree can substitute: it is read before the
# manager exists, so before any unit, any generator and any journal line.
check "PID 1's own epoch file is baked" "$([ -f "$EPOCH" ] && echo yes || echo no)" "yes"
check "  it is empty too (clock_apply_epoch stats it, never reads it)" \
	"$(wc -c < "$EPOCH" | tr -d ' ')" "0"
check "  it is world-readable and not writable (PID 1 reads it; nothing writes it)" \
	"$(mode_of "$EPOCH")" "-rw-r--r--"
# ONE stamp. Two files a few microseconds apart would agree almost always and
# would disagree across a second boundary, and a floor that is sometimes one
# second older than the other floor is a difference nothing would ever explain.
check "  it carries the SAME mtime as the timesyncd floor" "$(mtime_of "$EPOCH")" "$(mtime_of "$FLOOR")"
case "$out" in *"clock floor baked for rpi"*) echo "ok   — the build says what it baked" ;;
	*) echo "FAIL — the build says what it baked: got '$out'"; fails=$((fails + 1)) ;; esac
case "$out" in *"/usr/lib/clock-epoch"*) echo "ok   — and names the epoch file it baked" ;;
	*) echo "FAIL — and names the epoch file it baked: got '$out'"; fails=$((fails + 1)) ;; esac

# Refusing to restamp. Asserted for EACH file separately: a loop that only
# checked one of them would pass while the other was silently re-dated by a
# second pass over a tree, which is what an incremental `make` produces.
T="$TMP/rebake"; make_target "$T"
mkdir -p "$T/usr/share/factory/rasputin"; : > "$T/usr/share/factory/rasputin/timesync-clock"
out=$(sh "$FAKEROOT" "$T" rpi 2>&1); rc=$?
check "refuses to restamp an existing timesyncd floor" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"

T="$TMP/rebake-epoch"; make_target "$T"
mkdir -p "$T/usr/lib"; : > "$T/usr/lib/clock-epoch"
out=$(sh "$FAKEROOT" "$T" rpi 2>&1); rc=$?
check "refuses to restamp an existing clock-epoch" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"

T="$TMP/n100"; make_target "$T"; sh "$FAKEROOT" "$T" n100 >/dev/null 2>&1
check "baked on n100 too (one code path, both SKUs)" \
	"$([ -f "$T/usr/share/factory/rasputin/timesync-clock" ] && echo yes || echo no)" "yes"
check "and the epoch file on n100 too" \
	"$([ -f "$T/usr/lib/clock-epoch" ] && echo yes || echo no)" "yes"

echo
echo "2. what the SAVE half persists"

# The ceiling: ten years past the image build date, as 10 * 365.25 * 86400.
# Named once here and used by both the save cases and the shim cases, because
# the whole point of the ceiling is that the two halves agree on it.
CEILING=315576000
# A build date to measure against — the mtime of a fake /usr/lib/clock-epoch.
BUILD_EPOCH=1790000000          # 2026-09-22
IN_CEILING=$((BUILD_EPOCH + CEILING - 86400))
OVER_CEILING=$((BUILD_EPOCH + CEILING + 86400))

# save STORE NOW [EPOCH_FILE] -> sets out/rc. The script's inputs.
save() {
	out=$(RASPUTIN_CLOCK_STORE="$1" RASPUTIN_CLOCK_DATE="$STUB_DATE" STUB_NOW="$2" \
		RASPUTIN_CLOCK_EPOCH="${3:-$EPOCHF}" \
		STUB_DATE_CALLS="$TMP/date.calls" sh "$SAVE" 2>&1); rc=$?
}
STUB_DATE="$TMP/date-stub"; make_date_stub "$STUB_DATE"
S="$TMP/store"; mkdir -p "$S"
# The ceiling reference the save half reads: an empty file whose MTIME is the
# image build date, exactly as post-fakeroot.sh bakes it.
EPOCHF="$TMP/clock-epoch"; : > "$EPOCHF"
touch -d "@$BUILD_EPOCH" "$EPOCHF" 2>/dev/null || touch -t 202609221333.20 "$EPOCHF"
BUILD_EPOCH=$(mtime_of "$EPOCHF")
IN_CEILING=$((BUILD_EPOCH + CEILING - 86400))
OVER_CEILING=$((BUILD_EPOCH + CEILING + 86400))

save "$S/clock" 1758579000
check "a fresh store is written" "$rc" "0"
check "  it holds the current time" "$(cat "$S/clock" 2>/dev/null)" "1758579000"
check "  0644: a timestamp, not a credential" "$(mode_of "$S/clock")" "-rw-r--r--"
check "  no temp file is left behind" "$([ -e "$S/clock.tmp" ] && echo yes || echo no)" "no"

# THE WHOLE LOGIC. A clock earlier than the store means this boot has not been
# corrected yet; writing it would ratchet the floor DOWN one boot at a time
# until it was the image build date again — the defect with extra steps.
save "$S/clock" 1700000000
check "an earlier clock does NOT move the store backwards" "$(cat "$S/clock")" "1758579000"
check "  and says so without calling it a fault" \
	"$(printf '%s' "$out" | grep -c 'leaving the floor where it is')" "1"
save "$S/clock" 1758579000
check "an equal clock leaves the store alone" "$(cat "$S/clock")" "1758579000"
save "$S/clock" 1758999999
check "a later clock advances the store" "$(cat "$S/clock")" "1758999999"

printf 'not-a-timestamp\n' > "$S/clock"
save "$S/clock" 1758579000
check "an unusable store is replaced" "$(cat "$S/clock")" "1758579000"
check "  and the replacement is announced" \
	"$(printf '%s' "$out" | grep -c 'replacing an unusable clock store')" "1"

# A clock the shim would refuse on the way back in must not be written on the
# way out, or the two halves disagree and a refusal at boot stops meaning
# damage. Nine digits is 1973; the shim's rule is exactly ten.
printf '1758579000\n' > "$S/clock"
save "$S/clock" 999999999
check "a clock that is not ten digits is refused" "$(cat "$S/clock")" "1758579000"
check "  and exits 0 rather than failing a shutdown" "$rc" "0"

rm -f "$S/clock"
save "$S/nonexistent-dir/clock" 1758579000
check "an unwritable store path does not exit 0 silently pretending it saved" \
	"$(printf '%s' "$out" | grep -c 'saved clock')" "0"

# ── the ceiling ──────────────────────────────────────────────────────────────
# NTP is unauthenticated, and this floor only ever moves FORWARD, so a hostile
# or broken server that timesyncd accepts would otherwise be persisted and
# carried for the life of the node: certificates minted years ahead, and a node
# that can never again accept a correct time. The ceiling bounds it relative to
# something the network cannot move — the image's own build date.
#
# Note what it is not: gating on /run/systemd/timesync/synchronized would not
# help, because that flag is SET by timesyncd accepting the bad answer.
rm -f "$S/clock"
save "$S/clock" "$IN_CEILING"
check "a clock just inside the ceiling is saved" "$(cat "$S/clock" 2>/dev/null)" "$IN_CEILING"

rm -f "$S/clock"
save "$S/clock" "$OVER_CEILING"
check "a clock beyond the ceiling is REFUSED" \
	"$([ -e "$S/clock" ] && echo yes || echo no)" "no"
check "  and the refusal is logged distinctly" \
	"$(printf '%s' "$out" | grep -c 'REFUSING to save clock')" "1"
check "  and it names the build date it measured against" \
	"$(printf '%s' "$out" | grep -c "build date $BUILD_EPOCH")" "1"
check "  and does not fail the unit over it" "$rc" "0"

# An existing good store is not destroyed by a poisoned clock either.
printf '%s\n' "$IN_CEILING" > "$S/clock"
save "$S/clock" "$OVER_CEILING"
check "a poisoned clock leaves a good store intact" "$(cat "$S/clock")" "$IN_CEILING"

# FAIL CLOSED with no reference. No epoch file means no ceiling, and an
# unbounded value is precisely what this check exists to refuse.
rm -f "$S/clock"
save "$S/clock" 1758579000 "$TMP/no-such-epoch-file"
check "no epoch file to measure against: nothing is saved" \
	"$([ -e "$S/clock" ] && echo yes || echo no)" "no"
check "  and it says why rather than degrading silently" \
	"$(printf '%s' "$out" | grep -c 'gave no image build date')" "1"
check "  and still exits 0" "$rc" "0"

# A clock BEFORE the build date is not a ceiling case — the difference is
# negative — and must fall through to the ordinary not-ahead-of-the-store rule.
rm -f "$S/clock"
save "$S/clock" 1758579000
check "a clock before the build date is not caught by the ceiling" \
	"$(cat "$S/clock" 2>/dev/null)" "1758579000"

echo
echo "3. what the PID 1 SHIM restores"

# The shim's harness. Deliberately smaller than test/machine-id-test.sh's: that
# suite owns the hand-off invariant across every shell and every missing binary,
# and it still does — it runs the same script. What is here is the clock path
# only, and the one property that matters about it is that it moves the clock in
# exactly one direction and never calls a real `date`.
shim_setup() {
	W=$(mktemp -d "$TMP/shim.XXXXXX")
	R="$W/root"; PERSIST="$W/persist"; BIN="$W/bin"
	mkdir -p "$R/etc" "$R/run" "$R/proc" "$R/sys/block" "$R/var/lib/rasputin" "$PERSIST" "$BIN" "$R/usr/lib"
	: >"$R/etc/machine-id"
	# The ceiling reference, exactly as post-fakeroot.sh bakes it: an empty file
	# whose MTIME is the image build date. shim_no_epoch() removes it.
	: >"$R/usr/lib/clock-epoch"
	touch -r "$EPOCHF" "$R/usr/lib/clock-epoch"
	: >"$W/date.calls"
	rm -f "$W/handoff.args"
	cat >"$BIN/mount" <<'STUB'
#!/bin/sh
src=; dst=
for a in "$@"; do src=$dst; dst=$a; done
case " $* " in
	*" -t ext4 "*) mkdir -p "$dst" && cp -R "$STUB_PERSIST/." "$dst/" 2>/dev/null ;;
	*" -o bind "*) cp "$src" "$dst" || exit 1 ;;
	*) mkdir -p "$dst" ;;
esac
exit 0
STUB
	cat >"$BIN/umount" <<'STUB'
#!/bin/sh
dst=
for a in "$@"; do dst=$a; done
case "$dst" in */var/lib/rasputin) rm -f "$dst"/* 2>/dev/null ;; esac
exit 0
STUB
	printf '#!/bin/sh\nprintf %%s\\\\n /dev/fake1\n' >"$BIN/findfs"
	printf '#!/bin/sh\nprintf %%s\\\\n "$*" > "$STUB_HANDOFF_ARGS"\nexit 0\n' >"$BIN/systemd"
	make_date_stub "$BIN/date"
	chmod +x "$BIN/mount" "$BIN/umount" "$BIN/findfs" "$BIN/systemd"
	STUB_SET_RC=0
}
# shim NOW — run the shim with the stub clock reading NOW; sets OUT and RC.
shim() {
	OUT=$(STUB_PERSIST="$PERSIST" STUB_HANDOFF_ARGS="$W/handoff.args" \
		STUB_DATE_CALLS="$W/date.calls" STUB_NOW="$1" STUB_SET_RC="$STUB_SET_RC" \
		RASPUTIN_INIT_TEST=1 RASPUTIN_INIT_ROOT="$R" \
		RASPUTIN_INIT_MOUNT="$BIN/mount" RASPUTIN_INIT_UMOUNT="$BIN/umount" \
		RASPUTIN_INIT_FINDFS="$BIN/findfs" RASPUTIN_INIT_DATE="$BIN/date" \
		RASPUTIN_INIT_KMSG="$W/kmsg" RASPUTIN_INIT_SYSTEMD="$BIN/systemd" \
		sh "$SHIM" 2>&1); RC=$?
}
set_calls() { grep -c -- '-s @' "$W/date.calls" 2>/dev/null | tr -d ' '; }
set_to() { sed -n 's/.*-s @\([0-9]*\).*/\1/p' "$W/date.calls" 2>/dev/null | tail -1; }
handed_off() { [ -f "$W/handoff.args" ] && echo yes || echo no; }
out_has() { printf '%s\n' "$OUT" | grep -qF -- "$1" && echo yes || echo no; }

# The whole point: the node boots at a stale floor and the store is newer.
shim_setup; printf '1758579000\n' >"$PERSIST/clock"; shim 1750000000
check "stale clock + newer store: the clock is set" "$(set_calls)" "1"
check "  set to exactly the stored value" "$(set_to)" "1758579000"
check "  and it still hands off to systemd" "$(handed_off)" "yes"
check "  and says what it moved, naming the device" \
	"$(out_has 'clock advanced from 1750000000 to 1758579000, restored from /dev/fake1')" "yes"

# ONLY FORWARDS. This is the n100's every boot — its RTC has already given the
# kernel a correct time — and it is what stops a stale store from dragging a
# corrected clock backwards on any SKU.
shim_setup; printf '1750000000\n' >"$PERSIST/clock"; shim 1758579000
check "clock already ahead of the store: NOT set" "$(set_calls)" "0"
check "  and says it left it alone" "$(out_has 'leaving it alone')" "yes"
check "  and still hands off" "$(handed_off)" "yes"

shim_setup; printf '1758579000\n' >"$PERSIST/clock"; shim 1758579000
check "clock equal to the store: NOT set" "$(set_calls)" "0"

# No store — a node's first boot ever, and the first boot after this change
# lands on a fielded node. systemd's own /usr/lib/clock-epoch covers it, so this
# must not read as a fault, and above all it must not reach for `date` at all:
# a shim that ran a real `date -s` here would set the clock of any machine that
# ran its tests as root.
shim_setup; shim 1750000000
check "no stored clock: hands off" "$(handed_off)" "yes"
check "  the date binary is not invoked AT ALL" \
	"$(wc -c < "$W/date.calls" | tr -d ' ')" "0"
check "  and it names the backstop it is falling through to" \
	"$(out_has 'no clock stored on /dev/fake1 yet')" "yes"
check "  and names /usr/lib/clock-epoch as that backstop" \
	"$(out_has '/usr/lib/clock-epoch')" "yes"

# A corrupt store is refused before `date` ever sees it. Each of these is a way
# a half-written or foreign file can look, and none of them may reach `date -s`.
for bad in 'garbage' '' '17585790000000' '175857900' '17585790a0' '-758579000'; do
	shim_setup; printf '%s\n' "$bad" >"$PERSIST/clock"; shim 1750000000
	check "malformed store '$bad': hands off" "$(handed_off)" "yes"
	check "malformed store '$bad': the clock is not set" "$(set_calls)" "0"
done

# ── a TINY $now is the case this whole block exists for ─────────────────────
# The shim runs before systemd's clock_apply_epoch() has applied
# /usr/lib/clock-epoch, so on a no-RTC node the kernel clock genuinely reads a
# few seconds past 1970 and `date -u +%s` genuinely answers '4'. Measured on
# cp-compute5.local (geekdojo-brain#601): the first version validated $now with
# clock_valid(), which demands a plausible ten-digit epoch, so it read the very
# condition it exists to fix as a broken `date` and left the clock at 1970.
#
# Each value below is a real kernel clock a Pi can present on boot, and every
# one of them must RESTORE.
for tiny in 4 0 1 999999999; do
	shim_setup; printf '1758579000\n' >"$PERSIST/clock"; shim "$tiny"
	check "tiny now '$tiny' + valid store: the clock is set" "$(set_calls)" "1"
	check "tiny now '$tiny': set to exactly the stored value" "$(set_to)" "1758579000"
	check "tiny now '$tiny': still hands off" "$(handed_off)" "yes"
	check "tiny now '$tiny': and says what it moved" \
		"$(out_has "clock advanced from $tiny to 1758579000")" "yes"
done

# ── and what must STILL bail ────────────────────────────────────────────────
# The genuine failure — a `date` that is missing, or that answers something
# nothing can compare — keeps the old behaviour and the old message. "Produced a
# number that happens to be small" and "produced no usable number" are different
# facts, and only the second is a reason to leave the clock alone.
#
# '11111111111' is eleven digits: a clock past 2286, which cannot be compared
# under busybox ash's test applet without risking an overflow, so it degrades
# here exactly as clock_valid() says it does.
for badnow in '' 'garbage' '-1750000000' '1750000000x' '17 58' '11111111111'; do
	shim_setup; printf '1758579000\n' >"$PERSIST/clock"; shim "$badnow"
	check "unusable now '$badnow': the clock is NOT set" "$(set_calls)" "0"
	check "unusable now '$badnow': the node still boots" "$(handed_off)" "yes"
	check "unusable now '$badnow': and it says date would not report the time" \
		"$(out_has 'would not report the current time')" "yes"
done

# `date` absent altogether — the same bail, reached a different way. Removed
# AFTER shim_setup so $W/date.calls still exists and reads as zero calls.
shim_setup; printf '1758579000\n' >"$PERSIST/clock"; rm -f "$BIN/date"; shim 1750000000
check "no date binary at all: the clock is NOT set" "$(set_calls)" "0"
check "no date binary at all: the node still boots" "$(handed_off)" "yes"
check "no date binary at all: and it says so" \
	"$(out_has 'would not report the current time')" "yes"

# A tiny $now must not become a way past the ceiling: the store is still
# measured against the image build date before it is believed.
shim_setup; printf '%s\n' "$OVER_CEILING" >"$PERSIST/clock"; shim 4
check "tiny now + store beyond the ceiling: still REFUSED" "$(set_calls)" "0"
check "  and the node still boots" "$(handed_off)" "yes"

# A tiny $now must not become a way past a missing ceiling reference either.
shim_setup; printf '1758579000\n' >"$PERSIST/clock"
rm -f "$R/usr/lib/clock-epoch"; shim 4
check "tiny now + no epoch file: still fails closed" "$(set_calls)" "0"
check "  and the node still boots" "$(handed_off)" "yes"

# A `date` that will not set the clock. The boot continues and degrades to
# systemd's own epoch file rather than to 1970.
shim_setup; printf '1758579000\n' >"$PERSIST/clock"; STUB_SET_RC=1; shim 1750000000
check "date refuses to set: hands off anyway" "$(handed_off)" "yes"
check "  and says it is falling back to the baked epoch" \
	"$(out_has 'falling back to the image')" "yes"

# ── the ceiling, on the READ side ────────────────────────────────────────────
# The save half's ceiling only protects stores THIS image wrote. The shim is the
# point of use, and what it reads is a plain file on a partition: filesystem
# damage can turn a good timestamp into a plausible ten-digit one, an older or
# forked image could write the store without the rule, and anything with root on
# the node can edit it. So the ceiling is checked again on read, the same way
# clock_valid() already is.
shim_setup; printf '%s\n' "$IN_CEILING" >"$PERSIST/clock"; shim 1750000000
check "a store just inside the ceiling is honoured" "$(set_calls)" "1"
check "  and set to exactly that value" "$(set_to)" "$IN_CEILING"

shim_setup; printf '%s\n' "$OVER_CEILING" >"$PERSIST/clock"; shim 1750000000
check "a store beyond the ceiling is REFUSED on read" "$(set_calls)" "0"
check "  and the node still boots" "$(handed_off)" "yes"
check "  and the refusal is logged distinctly" "$(out_has 'REFUSING clock')" "yes"
check "  and it names the build date it measured against" \
	"$(out_has "past this image's build date $BUILD_EPOCH")" "yes"
check "  and says NTP is why the ceiling exists" "$(out_has 'NTP is unauthenticated')" "yes"

# FAIL CLOSED: no reference means no ceiling, and an unbounded value is what
# this refuses. The node degrades to whatever PID 1 applies, which on a rootfs
# with no epoch file is exactly where this image was before any of this shipped.
shim_setup; printf '%s\n' "$IN_CEILING" >"$PERSIST/clock"
rm -f "$R/usr/lib/clock-epoch"; shim 1750000000
check "no epoch file to measure against: the store is NOT applied" "$(set_calls)" "0"
check "  and the node still boots" "$(handed_off)" "yes"
check "  and it says why rather than degrading silently" \
	"$(out_has 'gave no image build date')" "yes"

# The machine-id half is read from the same mount and must be untouched by any
# of this — a regression here would be an identity change on every boot.
shim_setup
printf '4f2c1ab97d3e46b08c5d1e9f7a63b204\n' >"$PERSIST/machine-id"
printf '1758579000\n' >"$PERSIST/clock"
shim 1750000000
check "one mount serves both: the machine-id is still restored" \
	"$(cat "$R/etc/machine-id" 2>/dev/null)" "4f2c1ab97d3e46b08c5d1e9f7a63b204"
check "one mount serves both: and the clock is still set" "$(set_calls)" "1"
# A stored id with no stored clock, and the reverse, each degrade on their own.
shim_setup; printf '4f2c1ab97d3e46b08c5d1e9f7a63b204\n' >"$PERSIST/machine-id"; shim 1750000000
check "id without clock: id restored" \
	"$(cat "$R/etc/machine-id" 2>/dev/null)" "4f2c1ab97d3e46b08c5d1e9f7a63b204"
check "id without clock: clock reason is its own line" \
	"$(out_has 'no clock stored on /dev/fake1 yet')" "yes"
shim_setup; printf '1758579000\n' >"$PERSIST/clock"; shim 1750000000
check "clock without id: clock set" "$(set_calls)" "1"
check "clock without id: id reason is its own line" \
	"$(out_has 'no machine-id stored on /dev/fake1 yet')" "yes"

echo
echo "4. what the timesyncd SEEDING unit does"

# boot_floor DIR NOW — run rasputin-clock-floor.sh against DIR with the stub
# clock reading NOW; sets out/rc.
boot_floor() {
	out=$(sed -e "s|^FACTORY=.*|FACTORY=$1/usr/share/factory/rasputin/timesync-clock|" \
	          -e "s|^STATE_DIR=.*|STATE_DIR=$1/var/lib/systemd/timesync|" "$BOOT" \
		| RASPUTIN_CLOCK_DATE="$STUB_DATE" STUB_NOW="$2" STUB_DATE_CALLS="$TMP/date.calls" sh 2>&1)
	rc=$?
}
# factory_at DIR MTIME — a fake factory copy stamped at MTIME (a touch string).
factory_at() {
	mkdir -p "$1/usr/share/factory/rasputin" "$1/var/lib/systemd/timesync"
	: > "$1/usr/share/factory/rasputin/timesync-clock"
	touch -t "$2" "$1/usr/share/factory/rasputin/timesync-clock"
}

# The case that matters: the state dir is NOT writable, as on the squashfs. The
# script cannot mount a tmpfs unprivileged here, so it must say so and exit 0
# rather than fail the boot — and must not pretend it seeded anything.
B="$TMP/boot-ro"; factory_at "$B" 202609202252.16
chmod a-w "$B/var/lib/systemd/timesync"
boot_floor "$B" 1758579000
check "a read-only state dir does not fail the boot" "$rc" "0"
case "$out" in *"could not mount"*|*"WARNING"*) echo "ok   — and says the floor will not apply" ;;
	*) echo "FAIL — and says the floor will not apply: got '$out'"; fails=$((fails + 1)) ;; esac
chmod u+w "$B/var/lib/systemd/timesync"

# Writable and empty, with a clock BEHIND the build date. Nothing earlier
# floored it, so the factory mtime is the best answer and must survive intact —
# this is the pre-existing behaviour and it is what a node falls back to when
# both earlier floors failed.
B="$TMP/boot-behind"; factory_at "$B" 202609202252.16
want=$(mtime_of "$B/usr/share/factory/rasputin/timesync-clock")
boot_floor "$B" 1700000000
check "clock behind the build date: seeded" "$rc" "0"
check "  the timestamp file exists" \
	"$([ -f "$B/var/lib/systemd/timesync/clock" ] && echo yes || echo no)" "yes"
check "  its mtime is the FACTORY mtime, not the stale clock" \
	"$(mtime_of "$B/var/lib/systemd/timesync/clock")" "$want"

# Writable and empty, with a clock AHEAD of the build date — every healthy boot,
# because the PID 1 shim or /usr/lib/clock-epoch has already floored it. The
# state file must come up to the clock, so that this unit can never be the one
# stale number in the set and can never pull timesyncd backwards.
B="$TMP/boot-ahead"; factory_at "$B" 202609202252.16
old=$(mtime_of "$B/usr/share/factory/rasputin/timesync-clock")
boot_floor "$B" 1790000000
new=$(mtime_of "$B/var/lib/systemd/timesync/clock")
check "clock ahead of the build date: seeded" "$rc" "0"
if [ -n "$new" ] && [ "$new" -gt "$old" ]; then
	echo "ok   — the state file is advanced to the running clock, not left at the build date"
else
	echo "FAIL — the state file is advanced to the running clock: factory=$old state=$new"; fails=$((fails + 1))
fi
case "$out" in *"advanced"*) echo "ok   — and says it advanced it" ;;
	*) echo "FAIL — and says it advanced it: got '$out'"; fails=$((fails + 1)) ;; esac

# A timestamp already recorded by a previous NTP sync is newer than the build
# and must never be clobbered backwards.
B="$TMP/boot-existing"; factory_at "$B" 202609202252.16
: > "$B/var/lib/systemd/timesync/clock"; touch -t 202612250000.00 "$B/var/lib/systemd/timesync/clock"
keep=$(mtime_of "$B/var/lib/systemd/timesync/clock")
boot_floor "$B" 1758579000
check "an existing recorded timestamp is left alone" \
	"$(mtime_of "$B/var/lib/systemd/timesync/clock")" "$keep"

# No factory copy: nothing to do, and still not a boot failure.
B="$TMP/boot-nofactory"; mkdir -p "$B/var/lib/systemd/timesync"
out=$(sed -e "s|^FACTORY=.*|FACTORY=$B/nope|" \
          -e "s|^STATE_DIR=.*|STATE_DIR=$B/var/lib/systemd/timesync|" "$BOOT" | sh 2>&1); rc=$?
check "a missing factory copy is a no-op, not a failure" "$rc" "0"

echo
echo "5. the wiring"

grep_ok "the seeding unit is ordered BEFORE systemd-timesyncd" \
	'Before=.*systemd-timesyncd\.service' "$UNIT"
grep_ok "post-build enables it in sysinit.target.wants" \
	'sysinit\.target\.wants/rasputin-clock-floor\.service' "$POSTBUILD"
grep_ok "the seeding unit's [Install] matches where post-build links it" \
	'WantedBy=sysinit\.target' "$UNIT"

# ── the save half ────────────────────────────────────────────────────────────
# ExecStop is the write that matters: it is the last thing on the node that
# knows what time it is. RemainAfterExit is what makes systemd run it, and
# DefaultDependencies=no would take away the Before=shutdown.target that puts
# the stop inside the shutdown transaction — so its ABSENCE is the assertion.
grep_ok "the save unit runs the save script at start" \
	'^ExecStart=/usr/lib/rasputin/clock/rasputin-clock-save\.sh$' "$SAVE_UNIT"
grep_ok "the save unit runs it again at STOP (the shutdown write)" \
	'^ExecStop=/usr/lib/rasputin/clock/rasputin-clock-save\.sh$' "$SAVE_UNIT"
grep_ok "the save unit stays active so its ExecStop can run" \
	'^RemainAfterExit=yes$' "$SAVE_UNIT"
grep_not "the save unit keeps its default shutdown ordering" \
	'^DefaultDependencies=no$' "$SAVE_UNIT"
grep_ok "the save unit requires the persistent mount" \
	'^RequiresMountsFor=/var/lib/rasputin$' "$SAVE_UNIT"
grep_ok "the save unit skips itself when that mount is absent" \
	'^ConditionPathIsMountPoint=/var/lib/rasputin$' "$SAVE_UNIT"
grep_ok "post-build enables the save unit" \
	'multi-user\.target\.wants/rasputin-clock-save\.service' "$POSTBUILD"

# ── the periodic half ────────────────────────────────────────────────────────
# The timer must NOT drive rasputin-clock-save.service: that unit is
# RemainAfterExit, so starting an already-active unit is a no-op and every tick
# would silently do nothing while the wiring looked correct.
grep_ok "the timer drives its own unit, not the RemainAfterExit save unit" \
	'^Unit=rasputin-clock-tick\.service$' "$TICK_TIMER"
grep_not "the tick unit does not RemainAfterExit (each tick is complete)" \
	'^RemainAfterExit=' "$TICK_UNIT"
grep_not "the tick unit has no [Install] — only the timer starts it" \
	'^WantedBy=' "$TICK_UNIT"
grep_ok "the tick unit runs the same save script" \
	'^ExecStart=/usr/lib/rasputin/clock/rasputin-clock-save\.sh$' "$TICK_UNIT"
grep_ok "the timer fires after boot" '^OnBootSec=' "$TICK_TIMER"
grep_ok "the timer repeats" '^OnUnitActiveSec=' "$TICK_TIMER"
# Persistent=true needs a writable /var/lib/systemd/timers, and /var/lib/systemd
# is on the read-only squashfs rootfs.
grep_not "the timer is not Persistent (nothing on the rootfs is writable)" \
	'^Persistent=true$' "$TICK_TIMER"
grep_ok "post-build enables the timer in timers.target.wants" \
	'timers\.target\.wants/rasputin-clock-tick\.timer' "$POSTBUILD"

# ── the save script itself ───────────────────────────────────────────────────
check "the save script is executable" "$([ -x "$SAVE" ] && echo yes || echo no)" "yes"
check "the save script is /bin/sh, the image's shell" "$(head -1 "$SAVE")" "#!/bin/sh"

# ── the ceiling, as a cross-file contract ────────────────────────────────────
# The save half and the shim have to bound against the SAME number and the SAME
# reference file. If they drift apart, one of them silently stops being a
# control: a looser saver writes values the shim then refuses on every boot (the
# floor quietly stops working), and a looser shim honours values the saver would
# never have written (the ceiling is not a ceiling). Neither shows up in a build
# or a boot log, so the agreement is pinned here rather than left to a comment.
save_ceiling=$(sed -n 's/^CEILING_SECS=\([0-9]*\).*/\1/p' "$SAVE")
shim_ceiling=$(sed -n 's/^CLOCK_CEILING_SECS=\([0-9]*\).*/\1/p' "$SHIM")
check "the save half declares a ceiling" "$([ -n "$save_ceiling" ] && echo yes || echo no)" "yes"
check "the shim declares a ceiling" "$([ -n "$shim_ceiling" ] && echo yes || echo no)" "yes"
check "and the two are the same number" "$save_ceiling" "$shim_ceiling"
# Ten years, as 10 * 365.25 * 86400. Pinned as a literal because the reasoning
# brackets it from both sides: it must stay UNDER systemd's own 15-year backward
# clamp (clock-valid-range-usec-max, which Buildroot does not override) or it
# could never fire, and OVER the service life of a node still running one image.
check "and it is the ten years the reasoning bracketed" "$shim_ceiling" "315576000"
# Both halves must measure against the file post-fakeroot.sh bakes, not a second
# source of truth someone introduced later.
grep_ok "the save half measures against /usr/lib/clock-epoch" \
	'^EPOCH_FILE=.*/usr/lib/clock-epoch' "$SAVE"
grep_ok "the shim measures against /usr/lib/clock-epoch" \
	'^CLOCK_EPOCH_FILE=.*/usr/lib/clock-epoch' "$SHIM"

# ── the shim ─────────────────────────────────────────────────────────────────
# Restated here rather than left to test/machine-id-test.sh: the clock path adds
# new branches to PID 1, and an exiting PID 1 is a kernel panic with no
# rollback. The hand-off has to still be the last thing in the file.
last=$(grep -v '^[[:space:]]*#' "$SHIM" | grep -v '^[[:space:]]*$' | tail -1)
check "the shim's last statement is still the unconditional hand-off" \
	"$last" 'hand_off "$@"'
grep_not "the shim still does not use set -e" '^[[:space:]]*set[[:space:]]+-[a-z]*e' "$SHIM"
grep_not "the shim still does not use set -u" '^[[:space:]]*set[[:space:]]+-[a-z]*u' "$SHIM"

echo
if [ "$fails" -eq 0 ]; then echo "clock-floor-test: all checks passed"; exit 0; fi
echo "clock-floor-test: $fails check(s) failed"; exit 1
