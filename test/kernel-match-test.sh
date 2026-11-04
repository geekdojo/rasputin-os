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
# Also the build-side half of the same defect: test/bundle-kernel-match.sh's
# check that every module tree the bundle ships is loadable (section 5 there),
# on a real squashfs. That part needs mksquashfs, unsquashfs and sha256sum.
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

# --- the build-side check: test/bundle-kernel-match.sh, section 5 ------------------
# Every module tree the bundle's rootfs ships must be loadable: no compressed
# module, at least one *.ko, a non-empty modules.dep (geekdojo/geekdojo-brain#1061,
# F-1061-03 and TC-1061-19). An n100-shaped bundle is built for real (mksquashfs,
# a bzImage header carrying an identity, the manifest and the payload checksums),
# so every other check in the script passes and each case changes only the
# module tree. No mksquashfs or unsquashfs is a failure, not a skip.
echo "== bundle-kernel-match module trees"
BKM="$REPO/test/bundle-kernel-match.sh"
for t in mksquashfs unsquashfs sha256sum; do
	command -v "$t" >/dev/null 2>&1 || { echo "the bundle-kernel-match cases need $t, which is not installed" >&2; exit 2; }
done
REL="7.1.13"
# bundle_fixture DIR MODULE-FILES DEP-CONTENT — an n100 output dir whose rootfs's
# module tree holds MODULE-FILES (space-separated, under kernel/) and whose
# modules.dep holds DEP-CONTENT ("" for an empty file).
bundle_fixture() {
	_o="$1"; _b="$1/images/bundle"; _r="$1/rootfs"
	mkdir -p "$_b" "$_r/usr/lib/rasputin" "$_r/usr/lib/modules/$REL/kernel"
	printf '[hooks]\nfilename=hook.sh\nhooks=install-check\n\n[image.rootfs]\nfilename=rootfs.img\nhooks=post-install\n' > "$_b/manifest.raucm"
	printf '#!/bin/sh\nexit 0\n' > "$_b/hook.sh"; chmod 0755 "$_b/hook.sh"
	# A bzImage setup header: "HdrS" at 0x202, kernel_version (0x20E) = 0x200,
	# so the identity string is read at 0x200 + 0x200.
	dd if=/dev/zero of="$_b/bzImage" bs=2048 count=1 2>/dev/null
	printf 'HdrS' | dd of="$_b/bzImage" bs=1 seek=514 conv=notrunc 2>/dev/null
	printf '\000\002' | dd of="$_b/bzImage" bs=1 seek=526 conv=notrunc 2>/dev/null
	printf '%s (ci@test) #1 SMP PREEMPT_DYNAMIC Sun Nov  1 00:00:00 UTC 2026' "$REL" \
		| dd of="$_b/bzImage" bs=1 seek=1024 conv=notrunc 2>/dev/null
	(cd "$_b" && sha256sum bzImage hook.sh > boot-payload.sha256)
	sh "$REPO/scripts/kernel-id.sh" "$_b/bzImage" > "$_r/usr/lib/rasputin/kernel-ids"
	echo "kernel/net/a.ko" > "$_r/usr/lib/modules/$REL/modules.builtin"
	printf '%s' "$3" > "$_r/usr/lib/modules/$REL/modules.dep"
	for _m in $2; do : > "$_r/usr/lib/modules/$REL/kernel/$_m"; done
	mksquashfs "$_r" "$_b/rootfs.img" -noappend -quiet >/dev/null 2>&1
}
# bkm DIR — bundle-kernel-match's output, then "|rc=<status>".
bkm() { _out=$(sh "$BKM" n100 "$1" 2>&1); printf '%s|rc=%s' "$_out" "$?"; }
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
DEP="kernel/exfat.ko:
kernel/wireguard.ko:
"

bundle_fixture "$TMP/bkm-ok" "exfat.ko wireguard.ko" "$DEP"
out=$(bkm "$TMP/bkm-ok")
check "loadable module tree: all checks pass" "yes" "$(has "$out" "all checks passed|rc=0")"
check "loadable module tree: its ok line" "yes" "$(has "$out" "ok  module tree $REL is loadable (2 modules, none compressed, modules.dep 2 lines)")"

bundle_fixture "$TMP/bkm-xz" "exfat.ko wireguard.ko.xz" "$DEP"
out=$(bkm "$TMP/bkm-xz")
check "a .ko.xz in the tree: exit 1" "yes" "$(has "$out" "|rc=1")"
check "a .ko.xz in the tree: named" "yes" "$(has "$out" "::error::bundle-kernel-match (n100): The module tree for $REL carries 1 compressed modules")"
check "a .ko.xz in the tree: the file is shown" "yes" "$(has "$out" "usr/lib/modules/$REL/kernel/wireguard.ko.xz")"

for z in gz zst; do
	bundle_fixture "$TMP/bkm-$z" "exfat.ko wireguard.ko.$z" "$DEP"
	check "a .ko.$z in the tree: refused" "yes" "$(has "$(bkm "$TMP/bkm-$z")" "carries 1 compressed modules")"
done

bundle_fixture "$TMP/bkm-noko" "" "$DEP"
out=$(bkm "$TMP/bkm-noko")
check "no .ko in the tree: exit 1" "yes" "$(has "$out" "|rc=1")"
check "no .ko in the tree: named" "yes" "$(has "$out" "The module tree for $REL has no uncompressed module (*.ko).")"
check "no .ko in the tree: not called compressed" "no" "$(has "$out" "compressed modules")"

bundle_fixture "$TMP/bkm-nodep" "exfat.ko wireguard.ko" ""
out=$(bkm "$TMP/bkm-nodep")
check "empty modules.dep: exit 1" "yes" "$(has "$out" "|rc=1")"
check "empty modules.dep: named" "yes" "$(has "$out" "The module tree for $REL has an empty or missing modules.dep")"
check "empty modules.dep: the other two checks hold" "no" "$(has "$out" "compressed modules")"

echo "kernel-match: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
