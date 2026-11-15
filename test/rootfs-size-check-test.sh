#!/bin/sh
# Tests for board/rasputin/common/rootfs-size-check.sh and its call in
# post-image.sh (geekdojo/geekdojo-brain#969): every release build reports the
# squashfs size against the 768 MiB limit and #957's baselines, and a build
# over the limit stops before post-image.sh stages anything.
#
# Fixtures are sparse files made with dd seek, so an 805,306,369-byte
# "squashfs" costs no disk. The check runs under sh and under dash, because
# the image build runs it as /bin/sh and dash is the strictest POSIX shell CI
# has; no dash is a failure, not a skip.
#
#   TC-969-13  the check on its own: missing, unreadable, baseline-sized,
#              at and one byte over the limit, unknown SoC, no arguments.
#   TC-969-14  post-image.sh on a fixture BINARIES_DIR: over the limit it
#              exits non-zero with the limit message and stages nothing;
#              under it, it reports and carries on.
#
# What this does NOT prove: the size of a real image. The first release build
# with this change shows that (TC-969-17).
#
# Run:  sh test/rootfs-size-check-test.sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMMON="$ROOT/board/rasputin/common"
CHECK="$COMMON/rootfs-size-check.sh"
[ -f "$CHECK" ] || { echo "FAIL — missing: $CHECK"; exit 1; }
command -v dash >/dev/null 2>&1 || { echo "FAIL — dash is not on PATH. This suite runs the check under it and never skips."; exit 1; }
[ "$(id -u)" != 0 ] || { echo "FAIL — This suite must run as a user other than root, or the unreadable-file case reads the file anyway."; exit 1; }

fails=0
check() { # check LABEL GOT WANT
	if [ "$2" = "$3" ]; then echo "ok   — $1 ($2)"
	else echo "FAIL — $1: expected '$3', got '$2'"; fails=$((fails + 1)); fi
}
contains() { # contains LABEL HAYSTACK NEEDLE
	case "$2" in
		*"$3"*) echo "ok   — $1" ;;
		*) echo "FAIL — $1: '$3' not in: $2"; fails=$((fails + 1)) ;;
	esac
}

TMP=$(mktemp -d); trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

LIMIT=805306368
sparse() { # sparse PATH BYTES
	rm -f "$1"
	dd if=/dev/zero of="$1" bs=1 count=0 seek="$2" 2>/dev/null
	[ "$(wc -c < "$1" | tr -d ' ')" = "$2" ] || { echo "FAIL — could not make a $2-byte fixture at $1."; exit 1; }
}
run() { # run SHELL ARGS... — leaves $out, $err, $rc
	_sh="$1"; shift
	out=$("$_sh" "$CHECK" "$@" 2> "$TMP/err"); rc=$?
	err=$(cat "$TMP/err")
}
refused() { # refused LABEL SHELL WANT_STDERR ARGS...
	_l="$1"; _s="$2"; _w="$3"; shift 3
	run "$_s" "$@"
	check "TC-969-13 [$_s] $_l: exit status" "$rc" 1
	check "TC-969-13 [$_s] $_l: stderr" "$err" "$_w"
	check "TC-969-13 [$_s] $_l: nothing on stdout" "$out" ""
}

sparse "$TMP/rpi-base" 213209088
sparse "$TMP/n100-base" 207921152
sparse "$TMP/at-limit" "$LIMIT"
sparse "$TMP/over" $((LIMIT + 1))
sparse "$TMP/unreadable" $((LIMIT + 1))
chmod 000 "$TMP/unreadable"
OVER_MSG="rootfs-size-check: The root filesystem is $((LIMIT + 1)) bytes, over the 768 MiB limit ($LIMIT bytes). Revisit the control-plane-only extension image (platform.md §2.6) before shipping a root filesystem this large."

for s in sh dash; do
	echo "── rootfs-size-check.sh under $s"
	# TC-969-13
	refused "missing file" "$s" \
		"rootfs-size-check: The root filesystem $TMP/absent does not exist, so its size cannot be checked." \
		"$TMP/absent" rpi
	refused "unreadable over-limit file" "$s" \
		"rootfs-size-check: The root filesystem $TMP/unreadable cannot be read, so its size cannot be checked." \
		"$TMP/unreadable" rpi
	refused "unknown SoC" "$s" "rootfs-size-check: Unknown SoC 'pi9'. It must be rpi or n100." "$TMP/rpi-base" pi9
	refused "no arguments" "$s" "rootfs-size-check: Needs the squashfs path and the SoC (rpi or n100)."

	run "$s" "$TMP/rpi-base" rpi
	check "TC-969-13 [$s] rpi at its baseline: exit status" "$rc" 0
	check "TC-969-13 [$s] rpi at its baseline: report" "$out" \
		"rootfs-size-check: the rpi root filesystem is 213209088 bytes (203 MiB) of the 768 MiB limit ($LIMIT bytes); the #957 baseline for rpi is 213209088 bytes without identity and 432533504 bytes with it."
	run "$s" "$TMP/n100-base" n100
	check "TC-969-13 [$s] n100 at its baseline: exit status" "$rc" 0
	check "TC-969-13 [$s] n100 at its baseline: report" "$out" \
		"rootfs-size-check: the n100 root filesystem is 207921152 bytes (198 MiB) of the 768 MiB limit ($LIMIT bytes); the #957 baseline for n100 is 207921152 bytes without identity and 429506560 bytes with it."

	run "$s" "$TMP/at-limit" n100
	check "TC-969-13 [$s] exactly $LIMIT bytes passes" "$rc" 0
	contains "TC-969-13 [$s] and is reported" "$out" "is $LIMIT bytes (768 MiB)"
	refused "one byte over the limit" "$s" "$OVER_MSG" "$TMP/over" rpi
done

echo "── post-image.sh runs the check before it stages anything"
# TC-969-14
BIN="$TMP/binaries"
mkdir -p "$BIN"
sparse "$BIN/rootfs.squashfs" $((LIMIT + 1))
out=$(sh "$COMMON/post-image.sh" "$BIN" rpi 2> "$TMP/err"); rc=$?
err=$(cat "$TMP/err")
check "TC-969-14 over the limit: exit status is non-zero" "$([ "$rc" -ne 0 ] && echo non-zero || echo 0)" non-zero
contains "TC-969-14 over the limit: the limit message" "$err" "$OVER_MSG"
for f in rasputin-seed.env rasputin-boot-version bundle; do
	check "TC-969-14 over the limit: $f was not created" "$([ -e "$BIN/$f" ] && echo present || echo absent)" absent
done
sparse "$BIN/rootfs.squashfs" 213209088
# The run goes on past the check and stops at the first boot file this
# fixture lacks; its exit status is not what this case is about.
out=$(sh "$COMMON/post-image.sh" "$BIN" rpi 2> "$TMP/err")
contains "TC-969-14 under the limit: the report line" "$out" \
	"rootfs-size-check: the rpi root filesystem is 213209088 bytes"
check "TC-969-14 under the limit: post-image carried on and staged rasputin-seed.env" \
	"$([ -f "$BIN/rasputin-seed.env" ] && echo present || echo absent)" present

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all rootfs size check tests passed"
