#!/bin/sh
# Assertions on the serial login for the Raspberry Pi 5 Model B's debug UART,
# ttyAMA10 (geekdojo/geekdojo-brain#321, F-321-42 and F-321-43).
#
# What ships is one udev rule that starts serial-getty@ttyAMA10 when the device
# appears, and three drop-ins for that instance: two symlinks to ttyS0's own
# (the BMC-host gate and the fixed baud, one copy each) and a board gate that
# runs the getty only on the Pi 5 Model B. Each piece fails quietly when it is
# lost: a symlink resolved into a copy drifts from ttyS0's, a dropped gate puts
# a login on a CM5 or Pi 500 with no connector for it, and a static wants link
# makes every board without ttyAMA10 wait on a device that never comes.
#
# This is a static assertion on the rootfs overlay, not a functional test — it
# reads what ships. What udev and systemd make of these files is the boot
# smoke's SERIAL_FACTS (TC-321-68..71). No root, no systemd, runs anywhere.
#
# Run:  sh test/serial-getty-test.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
POST_BUILD="$ROOT/board/rasputin/common/post-build.sh"
[ -d "$OVERLAY" ] || { echo "missing: $OVERLAY" >&2; exit 2; }
[ -f "$POST_BUILD" ] || { echo "missing: $POST_BUILD" >&2; exit 2; }

RULE_FILE="etc/udev/rules.d/90-rasputin-pi5-debug-uart.rules"
RULE='SUBSYSTEM=="tty", KERNEL=="ttyAMA10", TAG+="systemd", ENV{SYSTEMD_WANTS}+="serial-getty@ttyAMA10.service"'
SYSD="etc/systemd/system"
DROPIN_DIR="$SYSD/serial-getty@ttyAMA10.service.d"
SHARED="10-rasputin-bmc-host.conf 20-rasputin-fixed-baud.conf"
GATE_FILE="30-rasputin-debug-uart-board.conf"
GATE='ConditionFirmware=device-tree-compatible(raspberrypi,5-model-b)'

fails=0
check() {
	if [ "$2" = "0" ]; then printf '  ok   %s\n' "$1"
	else printf '  FAIL %s\n       %s\n' "$1" "${3:-}"; fails=$((fails + 1)); fi
}

# The lines of a file that are neither blank nor a comment, one per line.
directives() { grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$1"; }

# rule_ok OVERLAY — the rule file exists and its only directive is $RULE.
rule_ok() {
	_f="$1/$RULE_FILE"
	[ -f "$_f" ] || { printf 'missing: %s' "$RULE_FILE"; return 1; }
	_d=$(directives "$_f")
	[ "$_d" = "$RULE" ] || { printf 'its non-comment lines are: %s' "$(printf '%s' "$_d" | tr '\n' '|')"; return 1; }
	return 0
}

# shared_ok OVERLAY NAME — the ttyAMA10 drop-in NAME is a relative symlink to
# ttyS0's file of the same name, and that file exists.
shared_ok() {
	_l="$1/$DROPIN_DIR/$2"
	[ -L "$_l" ] || { printf '%s is not a symlink (a copy would drift from ttyS0'"'"'s)' "$2"; return 1; }
	_t=$(readlink "$_l")
	[ "$_t" = "../serial-getty@ttyS0.service.d/$2" ] || { printf '%s points at %s' "$2" "$_t"; return 1; }
	[ -f "$_l" ] || { printf '%s dangles: %s does not exist' "$2" "$_t"; return 1; }
	return 0
}

# only_expected OVERLAY — the drop-in directory holds the two links and the
# gate, nothing else.
only_expected() {
	for _e in "$1/$DROPIN_DIR"/* "$1/$DROPIN_DIR"/.[!.]*; do
		[ -e "$_e" ] || [ -L "$_e" ] || continue
		case " $SHARED $GATE_FILE " in
			*" ${_e##*/} "*) ;;
			*) printf 'unexpected entry: %s' "${_e##*/}"; return 1 ;;
		esac
	done
	return 0
}

# no_static OVERLAY POST_BUILD — nothing enables the instance statically.
no_static() {
	if grep -n 'serial-getty@ttyAMA10' "$2" >/dev/null; then
		printf '%s names serial-getty@ttyAMA10' "${2##*/}"; return 1
	fi
	_w=$(find "$1" -path '*.wants/serial-getty@ttyAMA10*' 2>/dev/null | head -1)
	[ -z "$_w" ] || { printf 'wants link: %s' "${_w#"$1"/}"; return 1; }
	return 0
}

# gate_ok OVERLAY — the board gate is a plain file whose only directives are
# [Unit] and the exact condition.
gate_ok() {
	_g="$1/$DROPIN_DIR/$GATE_FILE"
	[ -f "$_g" ] && [ ! -L "$_g" ] || { printf '%s is missing or not a plain file' "$GATE_FILE"; return 1; }
	_d=$(directives "$_g")
	_want=$(printf '[Unit]\n%s' "$GATE")
	[ "$_d" = "$_want" ] || { printf 'its non-comment lines are: %s' "$(printf '%s' "$_d" | tr '\n' '|')"; return 1; }
	return 0
}

run_all() {
	echo "1. the udev rule ships exactly (TC-321-64)"
	out=$(rule_ok "$OVERLAY") && r=0 || r=1
	check "TC-321-64 $RULE_FILE holds the one rule" "$r" "$out"

	echo
	echo "2. one copy of each shared drop-in (TC-321-65)"
	for n in $SHARED; do
		out=$(shared_ok "$OVERLAY" "$n") && r=0 || r=1
		check "TC-321-65 $n links to ttyS0's" "$r" "$out"
	done
	out=$(only_expected "$OVERLAY") && r=0 || r=1
	check "TC-321-65 the drop-in directory holds nothing else" "$r" "$out"

	echo
	echo "3. no static enablement (TC-321-66)"
	out=$(no_static "$OVERLAY" "$POST_BUILD") && r=0 || r=1
	check "TC-321-66 no post-build.sh mention and no wants link" "$r" "$out"

	echo
	echo "4. the board gate (TC-321-67, F-321-43)"
	out=$(gate_ok "$OVERLAY") && r=0 || r=1
	check "TC-321-67 $GATE_FILE holds exactly the Pi 5 Model B condition" "$r" "$out"
}

run_all

# Negative controls: each way the files can go wrong must fail its check. Each
# runs against a scratch copy of the overlay's pieces with one fault planted.
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
fresh() {
	rm -rf "$SCRATCH/o" "$SCRATCH/post-build.sh"
	mkdir -p "$SCRATCH/o/etc/udev/rules.d" "$SCRATCH/o/$SYSD"
	cp "$OVERLAY/$RULE_FILE" "$SCRATCH/o/$RULE_FILE"
	cp -R "$OVERLAY/$SYSD/serial-getty@ttyS0.service.d" "$OVERLAY/$DROPIN_DIR" "$SCRATCH/o/$SYSD/"
	cp "$POST_BUILD" "$SCRATCH/post-build.sh"
}
refused() { "$@" >/dev/null && echo 1 || echo 0; }

echo
echo "5. negative controls"
fresh; echo "$RULE" >> "$SCRATCH/o/$RULE_FILE"
check "TC-321-64 a second rule line is refused" "$(refused rule_ok "$SCRATCH/o")" "rule_ok accepted two rule lines"
fresh; sed 's/ttyAMA10\.service/ttyAMA0.service/' "$OVERLAY/$RULE_FILE" > "$SCRATCH/o/$RULE_FILE"
check "TC-321-64 an edited rule is refused" "$(refused rule_ok "$SCRATCH/o")" "rule_ok accepted an edited rule"
fresh; rm -f "$SCRATCH/o/$RULE_FILE"
check "TC-321-64 a missing rule file is refused" "$(refused rule_ok "$SCRATCH/o")" "rule_ok accepted no file"
fresh; rm -f "$SCRATCH/o/$DROPIN_DIR/10-rasputin-bmc-host.conf"
cp "$OVERLAY/$SYSD/serial-getty@ttyS0.service.d/10-rasputin-bmc-host.conf" "$SCRATCH/o/$DROPIN_DIR/"
check "TC-321-65 a plain-file copy is refused" "$(refused shared_ok "$SCRATCH/o" 10-rasputin-bmc-host.conf)" "shared_ok accepted a copy"
fresh; rm -f "$SCRATCH/o/$SYSD/serial-getty@ttyS0.service.d/20-rasputin-fixed-baud.conf"
check "TC-321-65 a dangling link is refused" "$(refused shared_ok "$SCRATCH/o" 20-rasputin-fixed-baud.conf)" "shared_ok accepted a dangling link"
fresh; rm -f "$SCRATCH/o/$DROPIN_DIR/20-rasputin-fixed-baud.conf"
ln -s ../serial-getty@ttyS0.service.d/10-rasputin-bmc-host.conf "$SCRATCH/o/$DROPIN_DIR/20-rasputin-fixed-baud.conf"
check "TC-321-65 a link to another name is refused" "$(refused shared_ok "$SCRATCH/o" 20-rasputin-fixed-baud.conf)" "shared_ok accepted a link to the wrong file"
fresh; : > "$SCRATCH/o/$DROPIN_DIR/40-extra.conf"
check "TC-321-65 an extra drop-in is refused" "$(refused only_expected "$SCRATCH/o")" "only_expected accepted an extra file"
fresh; mkdir -p "$SCRATCH/o/$SYSD/getty.target.wants"
ln -s /usr/lib/systemd/system/serial-getty@.service "$SCRATCH/o/$SYSD/getty.target.wants/serial-getty@ttyAMA10.service"
check "TC-321-66 a wants link is refused" "$(refused no_static "$SCRATCH/o" "$SCRATCH/post-build.sh")" "no_static accepted a wants link"
fresh; echo "ln -sf x getty.target.wants/serial-getty@ttyAMA10.service" >> "$SCRATCH/post-build.sh"
check "TC-321-66 a post-build.sh link is refused" "$(refused no_static "$SCRATCH/o" "$SCRATCH/post-build.sh")" "no_static accepted a post-build.sh mention"
fresh; grep -v '^ConditionFirmware=' "$OVERLAY/$DROPIN_DIR/$GATE_FILE" > "$SCRATCH/o/$DROPIN_DIR/$GATE_FILE"
check "TC-321-67 the gate line removed is refused" "$(refused gate_ok "$SCRATCH/o")" "gate_ok accepted no condition"
fresh; sed 's/5-model-b/5-compute-module/' "$OVERLAY/$DROPIN_DIR/$GATE_FILE" > "$SCRATCH/o/$DROPIN_DIR/$GATE_FILE"
check "TC-321-67 a gate for another board is refused" "$(refused gate_ok "$SCRATCH/o")" "gate_ok accepted the CM5's compatible"

echo
if [ "$fails" -ne 0 ]; then echo "FAILED: $fails check(s)"; exit 1; fi
echo "all serial-getty tests passed"
