#!/bin/sh
#
# Tests for usr/lib/rasputin/kernel-match/rasputin-kernel-match.sh — the
# once-per-boot verdict on whether the running kernel is one this rootfs was
# built for (geekdojo/geekdojo-brain#807).
#
# Why. The QEMU smokes assert this verdict on every build, and the update
# smoke reads it after an update. A verdict that said MATCH for the wrong
# kernel would hide exactly the skew it exists to report, so what is pinned
# here is mostly what must NOT match: the same release built at another time
# (dev.276's case: the release string did not change, the config did), a
# release-only line, a missing or empty list.
#
# Fakes: `uname` is a stub on PATH answering -r and -v; the list and the kmsg
# sink are scratch files (RASPUTIN_KERNEL_IDS, RASPUTIN_KMSG). Runs under each
# shell in TEST_SHELLS and, with busybox present, under busybox sh with its
# grep and tr ahead of PATH (REQUIRE_BUSYBOX=1 makes a missing busybox fail).
#
# Run:  sh test/kernel-match-test.sh
set -u

REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$REPO/board/rasputin/common/rootfs-overlay/usr/lib/rasputin/kernel-match/rasputin-kernel-match.sh"
UNIT="$REPO/board/rasputin/common/rootfs-overlay/etc/systemd/system/rasputin-kernel-match.service"
[ -f "$SCRIPT" ] || { echo "missing: $SCRIPT" >&2; exit 2; }

if [ -z "${TEST_SHELLS:-}" ]; then
	TEST_SHELLS=""
	for s in sh dash bash; do
		command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"
	done
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BUSYBOX_DIR=""
if command -v busybox >/dev/null 2>&1; then
	BUSYBOX_DIR="$TMP/busybox"
	mkdir -p "$BUSYBOX_DIR"
	for applet in grep tr; do
		printf '#!/bin/sh\nexec busybox %s "$@"\n' "$applet" > "$BUSYBOX_DIR/$applet"
		chmod 0755 "$BUSYBOX_DIR/$applet"
	done
	TEST_SHELLS="$TEST_SHELLS busybox_applets"
elif [ -n "${REQUIRE_BUSYBOX:-}" ]; then
	echo "REQUIRE_BUSYBOX is set but busybox is not installed" >&2
	exit 2
fi

STUBS="$TMP/stubs"
mkdir -p "$STUBS"
cat > "$STUBS/uname" <<'EOF'
#!/bin/sh
case "$1" in
	-r) echo "$FAKE_RELEASE" ;;
	-v) echo "$FAKE_VERSION" ;;
	*) exit 1 ;;
esac
EOF
chmod 0755 "$STUBS/uname"

pass=0
fail=0
check() {
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); else
		fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3" >&2
	fi
}

PI5="6.6.28-v8-16k #1 SMP PREEMPT Sun Oct  4 01:36:08 UTC 2026"
PI4="6.6.28-v8 #1 SMP PREEMPT Sun Oct  4 01:40:20 UTC 2026"

# run SHELL IDS RELEASE VERSION — prints the kmsg line, then "|rc=<status>".
run() {
	: > "$TMP/kmsg"
	if [ "$1" = busybox_applets ]; then
		env PATH="$STUBS:$BUSYBOX_DIR:$PATH" RASPUTIN_KERNEL_IDS="$2" RASPUTIN_KMSG="$TMP/kmsg" \
			FAKE_RELEASE="$3" FAKE_VERSION="$4" STUB_UNAME="$STUBS/uname" busybox sh -c '
				# busybox sh runs its own applets ahead of PATH; a function
				# is what replaces its uname.
				uname() { "$STUB_UNAME" "$@"; }
				. "$0"' "$SCRIPT" >/dev/null 2>&1
		_rc=$?
	else
		env PATH="$STUBS:$PATH" RASPUTIN_KERNEL_IDS="$2" RASPUTIN_KMSG="$TMP/kmsg" \
			FAKE_RELEASE="$3" FAKE_VERSION="$4" "$1" "$SCRIPT" >/dev/null 2>&1
		_rc=$?
	fi
	printf '%s|rc=%s' "$(cat "$TMP/kmsg")" "$_rc"
}

printf '%s\n%s\n' "$PI5" "$PI4" > "$TMP/ids"
: > "$TMP/empty"
printf '%s\n' "6.6.28-v8-16k" > "$TMP/release-only"

for SH in $TEST_SHELLS; do
	echo "== $SH"
	check "Pi 5 kernel of a two-kernel image: MATCH" \
		"rasputin-kernel-match: MATCH running=$PI5|rc=0" \
		"$(run "$SH" "$TMP/ids" "6.6.28-v8-16k" "#1 SMP PREEMPT Sun Oct  4 01:36:08 UTC 2026")"
	check "Pi 4 kernel of a two-kernel image: MATCH" \
		"rasputin-kernel-match: MATCH running=$PI4|rc=0" \
		"$(run "$SH" "$TMP/ids" "6.6.28-v8" "#1 SMP PREEMPT Sun Oct  4 01:40:20 UTC 2026")"
	# dev.276's case: same release string, an older build. Double spaces in the
	# date are part of the id and must not be squeezed into a false match.
	check "same release, another build: MISMATCH" \
		"rasputin-kernel-match: MISMATCH running=6.6.28-v8-16k #1 SMP PREEMPT Sat Sep 26 10:00:00 UTC 2026 built-for=$PI5;$PI4;|rc=1" \
		"$(run "$SH" "$TMP/ids" "6.6.28-v8-16k" "#1 SMP PREEMPT Sat Sep 26 10:00:00 UTC 2026")"
	check "whitespace-squeezed version is not the same id" \
		"1" "$(run "$SH" "$TMP/ids" "6.6.28-v8-16k" "#1 SMP PREEMPT Sun Oct 4 01:36:08 UTC 2026" | sed 's/.*|rc=//')"
	check "a line holding only the release does not match" \
		"1" "$(run "$SH" "$TMP/release-only" "6.6.28-v8-16k" "#1 SMP PREEMPT Sun Oct  4 01:36:08 UTC 2026" | sed 's/.*|rc=//')"
	check "no list: FAIL" \
		"rasputin-kernel-match: FAIL no kernel list at $TMP/missing, so nothing says which kernel this rootfs was built for|rc=1" \
		"$(run "$SH" "$TMP/missing" "6.6.28-v8-16k" "#1")"
	check "empty list: FAIL" "1" "$(run "$SH" "$TMP/empty" "6.6.28-v8-16k" "#1" | sed 's/.*|rc=//')"
done

# The unit runs the script once per boot and is enabled by post-build.sh.
check "unit runs the script" "ExecStart=/usr/lib/rasputin/kernel-match/rasputin-kernel-match.sh" "$(grep '^ExecStart=' "$UNIT")"
check "post-build enables the unit" 1 "$(grep -c 'multi-user.target.wants/rasputin-kernel-match.service' "$REPO/board/rasputin/common/post-build.sh")"

echo "kernel-match: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
