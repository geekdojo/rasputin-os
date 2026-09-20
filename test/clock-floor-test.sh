#!/bin/sh
# Tests for the clock floor post-fakeroot.sh bakes into
# /var/lib/systemd/timesync/clock.
#
# Why this is tested at all. The floor is an MTIME on an empty file: there is
# nothing to read back in a log, nothing a boot test would print, and a build
# that silently fails to set it produces an image that looks identical and
# mints expired certificates on every offline first boot. That is the failure
# geekdojo/rasputin-os#1 was closed on in July 2026 and which came back on
# 2026.09.4-dev.238. A no-op here is invisible, so it is pinned here.
#
# Everything is faked: a minimal TARGET_DIR with the /etc/shadow and
# /etc/passwd post-fakeroot.sh needs, and the timesync directory the image
# ships. No root, no fakeroot, no Buildroot.
#
# Run:  sh test/clock-floor-test.sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/board/rasputin/common/post-fakeroot.sh"
[ -f "$SCRIPT" ] || { echo "missing: $SCRIPT"; exit 1; }

fails=0
check() {
	if [ "$2" = "$3" ]; then
		echo "ok   — $1"
	else
		echo "FAIL — $1: expected '$3', got '$2'"
		fails=$((fails + 1))
	fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A target dir shaped like the one the fakeroot script is handed.
make_target() {
	t="$1"
	rm -rf "$t"
	mkdir -p "$t/etc" "$t/var/lib/systemd/timesync"
	printf 'root:*:19000:0:99999:7:::\n' > "$t/etc/shadow"
	printf 'root:x:0:0:root:/root:/bin/sh\n' > "$t/etc/passwd"
	printf 'systemd-timesync:x:104:108:systemd Time Synchronization:/:/bin/false\n' >> "$t/etc/passwd"
}

mtime_of() {
	# GNU coreutils and BSD/macOS disagree on stat(1); try both.
	stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# --- 1. happy path: the floor is baked, empty, and stamped at build time -----
T="$TMP/ok"
make_target "$T"
before=$(date -u +%s)
out=$(sh "$SCRIPT" "$T" rpi 2>&1); rc=$?
after=$(date -u +%s)
check "exits 0 on a well-formed target" "$rc" "0"
check "the clock floor exists" "$([ -f "$T/var/lib/systemd/timesync/clock" ] && echo yes || echo no)" "yes"
check "the clock floor is empty (timesyncd stats it, never reads it)" \
	"$(wc -c < "$T/var/lib/systemd/timesync/clock" | tr -d ' ')" "0"

m=$(mtime_of "$T/var/lib/systemd/timesync/clock")
if [ -n "$m" ] && [ "$m" -ge "$before" ] && [ "$m" -le "$after" ]; then
	echo "ok   — the floor's mtime is this build's timestamp"
else
	echo "FAIL — the floor's mtime is this build's timestamp: got '$m', wanted ${before}..${after}"
	fails=$((fails + 1))
fi

case "$out" in
	*"clock floor baked for rpi"*) echo "ok   — the build says what it baked" ;;
	*) echo "FAIL — the build says what it baked: got '$out'"; fails=$((fails + 1)) ;;
esac

# --- 2. a missing timesync directory is created, not fatal, not skipped ------
# If Buildroot ever stops shipping the directory the floor must still be baked.
# Failing the build instead would be worse than useless: post-fakeroot.sh also
# runs against minimal fixture trees (test/rootfs-shadow-test.sh), so a hard
# failure here breaks an unrelated test without protecting anything.
T="$TMP/nodir"
make_target "$T"
rmdir "$T/var/lib/systemd/timesync"
out=$(sh "$SCRIPT" "$T" rpi 2>&1); rc=$?
check "exits 0 when the timesync directory is absent" "$rc" "0"
check "and creates the floor anyway" \
	"$([ -f "$T/var/lib/systemd/timesync/clock" ] && echo yes || echo no)" "yes"

# --- 3. an existing clock file is never restamped -----------------------------
T="$TMP/exists"
make_target "$T"
: > "$T/var/lib/systemd/timesync/clock"
out=$(sh "$SCRIPT" "$T" rpi 2>&1); rc=$?
check "exits non-zero rather than restamp an existing floor" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"

# --- 4. the floor is baked on both SKUs ---------------------------------------
# n100 has an RTC and does not need the floor, but it is not harmed by one, and
# a per-SKU bake is a second code path that only one arch ever exercises —
# which is how the rpi-only failure went unseen through n100 bench validation
# in the first place (geekdojo/rasputin-os#1).
T="$TMP/n100"
make_target "$T"
sh "$SCRIPT" "$T" n100 >/dev/null 2>&1
check "the floor is baked on n100 too" \
	"$([ -f "$T/var/lib/systemd/timesync/clock" ] && echo yes || echo no)" "yes"

echo
if [ "$fails" -eq 0 ]; then
	echo "clock-floor-test: all checks passed"
	exit 0
fi
echo "clock-floor-test: $fails check(s) failed"
exit 1
