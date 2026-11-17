#!/bin/sh
# Tests for qemu_exec's KVM refusal (test/lib/qemu-common.sh;
# geekdojo/geekdojo-brain#974, TC-974-12). The amd64 guest runs under KVM
# only, because the identity service's JVM crashes under amd64 TCG: with the
# KVM device missing, or present but not writable, qemu_exec prints one
# sentence naming the device and never starts QEMU; with it usable, QEMU's
# argv carries -accel kvm.
#
# How. qemu_exec runs in a subshell with a stub qemu-system-x86_64 and a stub
# timeout first on PATH (macOS has no timeout(1)); the QEMU stub writes its
# argv to a log. The device is a scratch file named by QEMU_KVM_DEV, the
# variable qemu_exec reads. Run unprivileged: root can write a 0444 file.
#
# Run:  sh test/qemu-common-test.sh
set -u
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
for f in "$ROOT/test/lib/qemu-common.sh" "$ROOT/test/lib/checks.sh"; do
	[ -f "$f" ] || { echo "FAILED: the file $f is missing."; exit 1; }
done
. "$ROOT/test/lib/checks.sh"
. "$ROOT/test/lib/qemu-common.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP/bin"
cat >"$TMP/bin/qemu-system-x86_64" <<STUB
#!/bin/sh
printf '%s\n' "\$@" >"$TMP/argv"
STUB
cat >"$TMP/bin/timeout" <<'STUB'
#!/bin/sh
shift
exec "$@"
STUB
chmod +x "$TMP/bin/qemu-system-x86_64" "$TMP/bin/timeout"
PATH="$TMP/bin:$PATH"
OVMF_CODE="$TMP/code.fd" VARS_FD="$TMP/vars.fd"

# run DEV — qemu_exec amd64 with the device DEV; sets OUT, RC and ARGV.
run() {
	rm -f "$TMP/argv"
	OUT=$( (QEMU_KVM_DEV="$1" qemu_exec amd64 "$TMP/disk.img" 60 "$TMP/console.log" hostfwd=tcp:127.0.0.1:1-:22) 2>&1); RC=$?
	ARGV=$(cat "$TMP/argv" 2>/dev/null)
}

echo "TC-974-12 qemu_exec amd64 runs under KVM, never TCG"
run "$TMP/no-such-kvm"
check "TC-974-12 no KVM device: exits non-zero (rc=$RC)" "$(yes_if [ "$RC" -ne 0 ])"
check "TC-974-12 no KVM device: one sentence naming the device" \
	"$({ [ "$(printf '%s\n' "$OUT" | grep -c '')" = 1 ] && contains "$TMP/no-such-kvm does not exist" "$OUT"; } && echo 0 || echo 1)" "$OUT"
check "TC-974-12 no KVM device: QEMU never ran" "$(yes_if [ ! -e "$TMP/argv" ])" "$ARGV"
: >"$TMP/ro-kvm"; chmod 0444 "$TMP/ro-kvm"
run "$TMP/ro-kvm"
check "TC-974-12 a KVM device that is not writable: exits non-zero (rc=$RC)" "$(yes_if [ "$RC" -ne 0 ])"
check "TC-974-12 a KVM device that is not writable: one sentence naming the device" \
	"$({ [ "$(printf '%s\n' "$OUT" | grep -c '')" = 1 ] && contains "$TMP/ro-kvm is not readable and writable" "$OUT"; } && echo 0 || echo 1)" "$OUT"
check "TC-974-12 a KVM device that is not writable: QEMU never ran" "$(yes_if [ ! -e "$TMP/argv" ])" "$ARGV"
: >"$TMP/rw-kvm"; chmod 0666 "$TMP/rw-kvm"
run "$TMP/rw-kvm"
check "TC-974-12 a usable KVM device: QEMU ran (rc=$RC)" "$(yes_if [ -e "$TMP/argv" ])" "$OUT"
check "TC-974-12 a usable KVM device: QEMU's argv carries -accel kvm" \
	"$(yes_if contains "
-accel
kvm
" "
$ARGV
")" "$ARGV"

echo
if [ "$fails" -ne 0 ]; then echo "qemu-common-test: $fails check(s) FAILED"; exit 1; fi
echo "qemu-common-test: all checks passed"
