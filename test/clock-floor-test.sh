#!/bin/sh
# Tests for the image clock floor: what post-fakeroot.sh bakes, and what
# rasputin-clock-floor.sh does with it at boot.
#
# Why this is tested at all, and why the first version of it was not enough.
#
# The floor is an MTIME on an empty file: nothing to read back in a log, nothing
# a boot test prints, and a build that silently stops baking it produces an
# image that looks identical and mints already-expired certificates on every
# offline first boot (geekdojo/rasputin-os#1).
#
# PR #101's tests passed while the feature did nothing. They asserted the build
# wrote a file and stamped it, which was true — and missed that the file was
# written somewhere systemd-timesyncd cannot use, because timesyncd opens its
# timestamp file READ-WRITE and the rootfs is a read-only squashfs. The tests
# proved the bake; the bake was never the risky half. So the cases below cover
# the SEEDING too, including the read-only case that is the whole reason this
# unit exists.
#
# Everything is faked: a minimal TARGET_DIR for post-fakeroot.sh, and for the
# boot script a fake factory copy plus a state dir made genuinely unwritable.
# No root, no fakeroot, no Buildroot, no mount.
#
# Run:  sh test/clock-floor-test.sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FAKEROOT="$ROOT/board/rasputin/common/post-fakeroot.sh"
BOOT="$ROOT/board/rasputin/common/rootfs-overlay/usr/lib/rasputin/clock/rasputin-clock-floor.sh"
UNIT="$ROOT/board/rasputin/common/rootfs-overlay/etc/systemd/system/rasputin-clock-floor.service"
POSTBUILD="$ROOT/board/rasputin/common/post-build.sh"
for f in "$FAKEROOT" "$BOOT" "$UNIT" "$POSTBUILD"; do
	[ -f "$f" ] || { echo "missing: $f"; exit 1; }
done

fails=0
check() {
	if [ "$2" = "$3" ]; then echo "ok   — $1"
	else echo "FAIL — $1: expected '$3', got '$2'"; fails=$((fails + 1)); fi
}

TMP=$(mktemp -d); trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

make_target() {
	t="$1"; rm -rf "$t"; mkdir -p "$t/etc"
	printf 'root:*:19000:0:99999:7:::\n' > "$t/etc/shadow"
	printf 'root:x:0:0:root:/root:/bin/sh\n' > "$t/etc/passwd"
	printf 'systemd-timesync:x:104:108::/:/bin/false\n' >> "$t/etc/passwd"
}
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

echo "1. what the BUILD bakes"

T="$TMP/ok"; make_target "$T"
before=$(date -u +%s); out=$(sh "$FAKEROOT" "$T" rpi 2>&1); rc=$?; after=$(date -u +%s)
FLOOR="$T/usr/share/factory/rasputin/timesync-clock"
check "exits 0 on a well-formed target" "$rc" "0"
check "the floor is baked as a FACTORY copy" "$([ -f "$FLOOR" ] && echo yes || echo no)" "yes"
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
case "$out" in *"clock floor baked for rpi"*) echo "ok   — the build says what it baked" ;;
	*) echo "FAIL — the build says what it baked: got '$out'"; fails=$((fails + 1)) ;; esac

T="$TMP/rebake"; make_target "$T"
sh "$FAKEROOT" "$T" rpi >/dev/null 2>&1
mkdir -p "$T/usr/share/factory/rasputin"; : > "$T/usr/share/factory/rasputin/timesync-clock"
make_target "$T"; mkdir -p "$T/usr/share/factory/rasputin"; : > "$T/usr/share/factory/rasputin/timesync-clock"
out=$(sh "$FAKEROOT" "$T" rpi 2>&1); rc=$?
check "refuses to restamp an existing floor" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"

T="$TMP/n100"; make_target "$T"; sh "$FAKEROOT" "$T" n100 >/dev/null 2>&1
check "baked on n100 too (one code path, both SKUs)" \
	"$([ -f "$T/usr/share/factory/rasputin/timesync-clock" ] && echo yes || echo no)" "yes"

echo
echo "2. what the BOOT script does with it"

# The case that matters: the state dir is NOT writable, as on the squashfs.
# The script cannot mount a tmpfs unprivileged here, so it must say so and exit
# 0 rather than fail the boot — and must not pretend it seeded anything.
B="$TMP/boot-ro"; mkdir -p "$B/usr/share/factory/rasputin" "$B/var/lib/systemd/timesync"
: > "$B/usr/share/factory/rasputin/timesync-clock"
touch -t 202609202252.16 "$B/usr/share/factory/rasputin/timesync-clock"
chmod a-w "$B/var/lib/systemd/timesync"
out=$(sed -e "s|^FACTORY=.*|FACTORY=$B/usr/share/factory/rasputin/timesync-clock|" \
          -e "s|^STATE_DIR=.*|STATE_DIR=$B/var/lib/systemd/timesync|" "$BOOT" | sh 2>&1); rc=$?
check "a read-only state dir does not fail the boot" "$rc" "0"
case "$out" in *"could not mount"*|*"WARNING"*) echo "ok   — and says the floor will not apply" ;;
	*) echo "FAIL — and says the floor will not apply: got '$out'"; fails=$((fails + 1)) ;; esac
chmod u+w "$B/var/lib/systemd/timesync"

# Writable and empty: seed it, preserving the mtime — the mtime IS the floor.
B="$TMP/boot-rw"; mkdir -p "$B/usr/share/factory/rasputin" "$B/var/lib/systemd/timesync"
: > "$B/usr/share/factory/rasputin/timesync-clock"
touch -t 202609202252.16 "$B/usr/share/factory/rasputin/timesync-clock"
want=$(mtime_of "$B/usr/share/factory/rasputin/timesync-clock")
out=$(sed -e "s|^FACTORY=.*|FACTORY=$B/usr/share/factory/rasputin/timesync-clock|" \
          -e "s|^STATE_DIR=.*|STATE_DIR=$B/var/lib/systemd/timesync|" "$BOOT" | sh 2>&1); rc=$?
check "a writable state dir is seeded" "$rc" "0"
check "  the timestamp file exists" \
	"$([ -f "$B/var/lib/systemd/timesync/clock" ] && echo yes || echo no)" "yes"
check "  its mtime is the FACTORY mtime, not now" "$(mtime_of "$B/var/lib/systemd/timesync/clock")" "$want"

# A timestamp already recorded by a previous NTP sync is newer than the build
# and must never be clobbered backwards.
B="$TMP/boot-existing"; mkdir -p "$B/usr/share/factory/rasputin" "$B/var/lib/systemd/timesync"
: > "$B/usr/share/factory/rasputin/timesync-clock"; touch -t 202609202252.16 "$B/usr/share/factory/rasputin/timesync-clock"
: > "$B/var/lib/systemd/timesync/clock"; touch -t 202612250000.00 "$B/var/lib/systemd/timesync/clock"
keep=$(mtime_of "$B/var/lib/systemd/timesync/clock")
sed -e "s|^FACTORY=.*|FACTORY=$B/usr/share/factory/rasputin/timesync-clock|" \
    -e "s|^STATE_DIR=.*|STATE_DIR=$B/var/lib/systemd/timesync|" "$BOOT" | sh >/dev/null 2>&1
check "an existing recorded timestamp is left alone" \
	"$(mtime_of "$B/var/lib/systemd/timesync/clock")" "$keep"

# No factory copy: nothing to do, and still not a boot failure.
B="$TMP/boot-nofactory"; mkdir -p "$B/var/lib/systemd/timesync"
out=$(sed -e "s|^FACTORY=.*|FACTORY=$B/nope|" \
          -e "s|^STATE_DIR=.*|STATE_DIR=$B/var/lib/systemd/timesync|" "$BOOT" | sh 2>&1); rc=$?
check "a missing factory copy is a no-op, not a failure" "$rc" "0"

echo
echo "3. the wiring"

grep -q 'Before=.*systemd-timesyncd\.service' "$UNIT" \
	&& echo "ok   — the unit is ordered BEFORE systemd-timesyncd" \
	|| { echo "FAIL — the unit is ordered BEFORE systemd-timesyncd"; fails=$((fails + 1)); }
grep -q 'sysinit\.target\.wants/rasputin-clock-floor\.service' "$POSTBUILD" \
	&& echo "ok   — post-build enables it in sysinit.target.wants" \
	|| { echo "FAIL — post-build enables it in sysinit.target.wants"; fails=$((fails + 1)); }
grep -q 'WantedBy=sysinit\.target' "$UNIT" \
	&& echo "ok   — the unit's [Install] matches where post-build links it" \
	|| { echo "FAIL — the unit's [Install] matches where post-build links it"; fails=$((fails + 1)); }

echo
if [ "$fails" -eq 0 ]; then echo "clock-floor-test: all checks passed"; exit 0; fi
echo "clock-floor-test: $fails check(s) failed"; exit 1
