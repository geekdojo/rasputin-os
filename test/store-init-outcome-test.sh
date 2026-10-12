#!/bin/sh
#
# Tests for rasputin-store-init.sh, the outcome writer openbao.service runs
# around each start to record whether the secrets store's self-init succeeded
# or failed (geekdojo/geekdojo-brain#804, TC-804-15 and TC-804-24).
#
# Why. A failed self-init leaves a store that refuses to unseal, and the
# journal and console line and the record this script writes are how anyone
# learns of it: the bench reads the line, #833's reader parses the record. A
# wrong outcome, a half-written record or a line that reaches only one sink is
# a failure nobody sees. So every branch runs against a scratch tree, and each
# run's record, marker, stdout and console sink are checked.
#
# How. The real script runs with every collaborator pointed at scratch files
# through RASPUTIN_STOREINIT_*. No root, no systemd: what systemd does with the
# hooks is test/store-unit-functional.sh.
#
# Shells. Every case runs under each shell in TEST_SHELLS (default: whichever
# of sh, dash and bash are installed), under `busybox sh`, and under
# `busybox sh` with busybox's own applets ahead of PATH, as
# test/seal-key-test.sh does, so the image's ls, rm, mv, chmod, cat and mkdir
# are the ones exercised. REQUIRE_BUSYBOX=1 (CI sets it) makes a missing
# busybox a failure.
#
# Root. The suite refuses to run as root, with a failure and not a skip: root
# reads a mode-000 directory and writes into a mode-0500 one, so the
# fail-closed cases would pass over nothing.
#
# Run:  sh test/store-init-outcome-test.sh
set -u
LC_ALL=C
export LC_ALL

if [ "$(id -u)" = 0 ]; then
	echo "FAILED: this suite must not run as root, because root reads a mode-000 directory and the fail-closed cases would prove nothing." >&2
	exit 1
fi
if [ "${REQUIRE_BUSYBOX:-0}" = "1" ] && ! command -v busybox >/dev/null 2>&1; then
	echo "FAILED: REQUIRE_BUSYBOX=1 but busybox is not installed." >&2
	exit 1
fi

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
SCRIPT="$OVERLAY/usr/lib/rasputin/store-init/rasputin-store-init.sh"
LIB="$OVERLAY/usr/lib/rasputin/outcome/outcome.sh"
HCL="$OVERLAY/etc/rasputin/openbao/openbao.hcl"
for f in "$SCRIPT" "$LIB" "$HCL" "$ROOT/test/lib/hcl-keys.sh"; do
	[ -f "$f" ] || { echo "FAILED: the file $f is missing." >&2; exit 1; }
done

if [ -z "${TEST_SHELLS:-}" ]; then
	TEST_SHELLS=""
	for s in sh dash bash; do
		command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"
	done
fi

TMP=$(mktemp -d)
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

BUSYBOX_DIR=""
if command -v busybox >/dev/null 2>&1; then
	BUSYBOX_DIR="$TMP/busybox-applets"
	mkdir -p "$BUSYBOX_DIR"
	for applet in ls mv chmod rm cat mkdir dirname; do
		printf '#!/bin/sh\nexec busybox %s "$@"\n' "$applet" > "$BUSYBOX_DIR/$applet"
		chmod 0755 "$BUSYBOX_DIR/$applet"
	done
	TEST_SHELLS="$TEST_SHELLS busybox_sh busybox_applets"
fi

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
perms() { ls -ld "$1" 2>/dev/null | cut -c1-10; }
rec() { sed -n "s/^$1=//p" "$RUN/outcome" 2>/dev/null; }
# out_starts PREFIX — some line of stdout starts with PREFIX, taken literally.
out_starts() { printf '%s\n' "$OUT" | cut -c1-${#1} | grep -qxF -- "$1"; }
TAG=rasputin-store-init

# setup — a fresh scratch tree: an empty data directory, a run directory that
# does not exist yet (the script makes it), a boot id fixture and a console
# file.
setup() {
	W=$(mktemp -d "$TMP/w.XXXXXX")
	RUN="$W/run"
	D="$W/data"
	mkdir -p "$D"
	chmod 0700 "$D"
	BOOT_ID="b00710d0-0000-4000-8000-000000000804"
	printf '%s\n' "$BOOT_ID" > "$W/bootid"
	BOOTID_PATH="$W/bootid"
	: > "$W/kmsg"
	KMSG_PATH="$W/kmsg"
}

# run PHASE [VAR=VALUE ...] — the script under $SH, with the given extra
# environment (SERVICE_RESULT, EXIT_STATUS); stdout, stderr and status apart.
run() {
	_phase=$1; shift
	case "$SH" in
		busybox_sh|busybox_applets) _cmd="busybox sh" ;;
		*) _cmd=$SH ;;
	esac
	_path=$PATH
	[ "$SH" = busybox_applets ] && _path="$BUSYBOX_DIR:$PATH"
	# shellcheck disable=SC2086 # _cmd is "busybox sh" on purpose
	env PATH="$_path" RASPUTIN_STOREINIT_RUN="$RUN" RASPUTIN_STOREINIT_DATA="$D" \
		RASPUTIN_STOREINIT_BOOTID="$BOOTID_PATH" RASPUTIN_STOREINIT_KMSG="$KMSG_PATH" "$@" \
		$_cmd "$SCRIPT" "$_phase" > "$W/stdout" 2> "$W/stderr"
	RC=$?
	OUT=$(cat "$W/stdout")
	_r=$(rec reason)
	[ -n "$_r" ] && printf '%s\t%s\n' "$KIND" "$_r" >> "$REASONS"
	printf '%s\n' "$OUT" | sed -n "s/^<[0-9]>$TAG: \([A-Z].*\)$/$KIND-line\t\1/p" >> "$REASONS"
}

# quiet LABEL — the run wrote nothing: no line, no record, exit 0.
quiet() {
	ok "$1: exits 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT"
	ok "$1: prints nothing" "$(yes_if test -z "$OUT" -a ! -s "$W/stderr")" "stdout: $OUT stderr: $(cat "$W/stderr")"
	ok "$1: the console got nothing" "$(yes_if test ! -s "$W/kmsg")" "$(cat "$W/kmsg")"
	ok "$1: there is no record" "$(yes_if test ! -e "$RUN/outcome")" "$(ls -A "$RUN" 2>&1)"
}
# no_pending LABEL — the marker is absent.
no_pending() { ok "$1: there is no pending marker" "$(yes_if test ! -e "$RUN/pending")" "$(ls -A "$RUN" 2>&1)"; }
# same_line LABEL — the console sink holds stdout's last line, identical. The
# scratch console keeps only the last line written (outcome_log opens it with
# >, which on /dev/kmsg itself appends), so the last line is the one compared.
same_line() {
	ok "$1: the console has stdout's line, identical" \
		"$(yes_if test -n "$OUT" -a "$(cat "$W/kmsg")" = "$(printf '%s\n' "$OUT" | tail -n 1)")" \
		"kmsg: $(cat "$W/kmsg") | stdout: $OUT"
}
# record_is LABEL OUTCOME — TC-804-24: the record is exactly three lines,
# outcome, boot_id from the fixture and a reason sentence, at 0600, and the run
# directory holds nothing but it: no temp file, no marker.
record_is() {
	ok "$1: the record's outcome is $2" "$(yes_if test "$(rec outcome)" = "$2")" "$(cat "$RUN/outcome" 2>&1)"
	ok "$1: TC-804-24 boot_id is the fixture's exactly" "$(yes_if test "$(rec boot_id)" = "$BOOT_ID")" "$(rec boot_id)"
	ok "$1: the record is exactly outcome=, boot_id=, reason= in that order" \
		"$(yes_if test "$(cut -d= -f1 "$RUN/outcome" | tr '\n' ' ')" = "outcome boot_id reason ")" "$(cat "$RUN/outcome" 2>&1)"
	ok "$1: the reason is a sentence" "$(yes_if eval 'rec reason | grep -q "^[A-Z].*\.$"')" "$(rec reason)"
	ok "$1: the record is 0600" "$(yes_if test "$(perms "$RUN/outcome")" = "-rw-------")" "$(perms "$RUN/outcome")"
	ok "$1: TC-804-24 the run directory holds only outcome" "$(yes_if test "$(ls -A "$RUN")" = outcome)" "$(ls -A "$RUN")"
}

cases() {
	REASONS="$TMP/reasons.$SH"
	: > "$REASONS"

	# pre on an empty data directory: the marker, and nothing else.
	KIND=pre-empty; setup; run pre
	l="pre on an empty directory"
	ok "$l: exits 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT"
	ok "$l: writes the pending marker" "$(yes_if test -f "$RUN/pending")" "$(ls -A "$RUN" 2>&1)"
	ok "$l: prints nothing" "$(yes_if test -z "$OUT" -a ! -s "$W/stderr" -a ! -s "$W/kmsg")" "$OUT"
	ok "$l: the run directory is 0700" "$(yes_if test "$(perms "$RUN")" = "drwx------")" "$(perms "$RUN")"
	ok "$l: no record" "$(yes_if test ! -e "$RUN/outcome")"

	# started with the marker: initialised.
	KIND=initialised; run started
	l="started with pending"
	ok "$l: exits 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT"
	record_is "$l" initialised
	ok "$l: stdout is one <6> outcome=initialised line" \
		"$(yes_if test "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1)" "$OUT"
	ok "$l: the line is <6>$TAG: outcome=initialised reason=\"...\"" \
		"$(yes_if out_starts "<6>$TAG: outcome=initialised reason=\"The secrets store initialised itself")" "$OUT"
	same_line "$l"
	no_pending "$l"
	cp "$RUN/outcome" "$W/initialised.rec"

	# A later start on the now initialised store: pre, started, stopped write
	# nothing, and the record is untouched. This is the bench's "already
	# initialised" fact: no rasputin-store-init: line.
	printf 'x' > "$D/000001.log"
	for ph in pre started stopped; do
		KIND=again; : > "$W/kmsg"; run "$ph"
		quiet_l="a start on an initialised store, $ph"
		ok "$quiet_l: exits 0 and prints nothing" "$(yes_if test "$RC" = 0 -a -z "$OUT" -a ! -s "$W/kmsg")" "rc=$RC $OUT"
		ok "$quiet_l: the record is unchanged" "$(yes_if cmp -s "$W/initialised.rec" "$RUN/outcome")"
		no_pending "$quiet_l"
	done

	# pre on a non-empty directory: nothing written, and a stale marker is
	# cleared so a later started cannot claim this start initialised.
	KIND=nonempty; setup; printf 'x' > "$D/MANIFEST"; run pre
	quiet "pre on a non-empty directory"; no_pending "pre on a non-empty directory"
	KIND=stale; setup; printf 'x' > "$D/.dot"; mkdir -p "$RUN"; : > "$RUN/pending"; run pre
	quiet "pre on a dotfile-only directory with a stale marker"
	no_pending "pre on a dotfile-only directory with a stale marker"

	# pre on an unreadable or absent data directory: a <4> line, no marker.
	for row in unreadable absent; do
		KIND=unlistable; setup
		mkdir -p "$RUN"; : > "$RUN/pending"
		case "$row" in
			unreadable) chmod 000 "$D" ;;
			absent) rmdir "$D" ;;
		esac
		run pre
		[ "$row" = unreadable ] && chmod 0700 "$D"
		l="pre on an $row data directory"
		ok "$l: exits 0 (it reports, it does not gate)" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT"
		ok "$l: a <4> line says the outcome will not be recorded" \
			"$(yes_if out_starts "<4>$TAG: The store's data directory $D could not be listed, so whether this start initialises the store will not be recorded.")" "$OUT"
		same_line "$l"
		no_pending "$l"
		ok "$l: no record" "$(yes_if test ! -e "$RUN/outcome")"
	done

	# started and stopped without a marker: nothing.
	KIND=nopending; setup; run started; quiet "started without pending"
	KIND=nopending; setup; run stopped SERVICE_RESULT=exit-code EXIT_STATUS=1; quiet "stopped without pending"

	# stopped with the marker, after bao wrote its data: failed, and the store
	# refuses to unseal.
	KIND=failed; setup; run pre; printf 'x' > "$D/000002.log"
	run stopped SERVICE_RESULT=exit-code EXIT_STATUS=1
	l="stopped with pending, data written"
	ok "$l: exits 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT"
	record_is "$l" failed
	ok "$l: the reason names SERVICE_RESULT and EXIT_STATUS" \
		"$(yes_if test "$(rec reason)" = "The secrets store's first start ended before it was initialised (service result exit-code, status 1), and it will refuse to unseal until its data directory is cleared.")" "$(rec reason)"
	ok "$l: the line is <3>$TAG: outcome=failed reason=\"...\"" \
		"$(yes_if out_starts "<3>$TAG: outcome=failed reason=\"The secrets store's first start ended before it was initialised (service result exit-code, status 1)")" "$OUT"
	same_line "$l"
	no_pending "$l"
	cp "$RUN/outcome" "$W/failed.rec"

	# ... then pre and started on the non-empty directory: the record stays
	# failed, byte for byte.
	KIND=after; run pre; run started
	l="pre, stopped, then started on a non-empty directory"
	ok "$l: the record stays failed, byte for byte" "$(yes_if cmp -s "$W/failed.rec" "$RUN/outcome")" "$(cat "$RUN/outcome" 2>&1)"
	ok "$l: started printed nothing" "$(yes_if test -z "$OUT")" "$OUT"
	no_pending "$l"

	# stopped with the marker and the data directory still empty (bao never
	# ran, a credential failure for one): failed, and the next start inits.
	KIND=failed-empty; setup; run pre; run stopped SERVICE_RESULT=exit-code EXIT_STATUS=243
	l="stopped with pending, data still empty"
	record_is "$l" failed
	ok "$l: the reason says the next start initialises again" \
		"$(yes_if test "$(rec reason)" = "The secrets store's first start ended before it was initialised (service result exit-code, status 243). Its data directory is still empty, so the next start initialises it again.")" "$(rec reason)"
	same_line "$l"
	# ... and that next start, still empty, records initialised over it.
	KIND=retry; run pre; run started
	ok "$l, then a start that initialises: the record says initialised" "$(yes_if test "$(rec outcome)" = initialised)" "$(cat "$RUN/outcome" 2>&1)"

	# stopped with the marker and systemd's variables unset: named unknown.
	KIND=failed-unset; setup; run pre; printf 'x' > "$D/x"; run stopped
	ok "stopped with no SERVICE_RESULT or EXIT_STATUS: both are named unknown" \
		"$(yes_if eval 'rec reason | grep -qF "(service result unknown, status unknown)"')" "$(rec reason)"

	# The record cannot be written, nor the marker removed: the run directory
	# is 0500 with the marker in it. The outcome line still goes out, after a
	# <3> line for the record and a <4> line for the marker.
	KIND=recordwrite; setup; run pre; chmod 0500 "$RUN"; run started; chmod 0700 "$RUN"
	l="the record cannot be written"
	ok "$l: exits 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT"
	ok "$l: a <3> line says only the journal line carries the outcome" \
		"$(yes_if out_starts "<3>$TAG: The outcome record $RUN/outcome could not be written, so only this journal line carries the outcome.")" "$OUT"
	ok "$l: a <4> line says the marker could not be removed" \
		"$(yes_if out_starts "<4>$TAG: The marker $RUN/pending could not be removed, so a later stop of the store may record a second outcome for this start.")" "$OUT"
	_last=$(printf '%s\n' "$OUT" | tail -n 1)
	ok "$l: the outcome line still goes out, last" \
		"$(yes_if test "${_last#"<6>$TAG: outcome=initialised reason="}" != "$_last")" "$OUT"
	same_line "$l"
	ok "$l: no record and no temp file" "$(yes_if test ! -e "$RUN/outcome" -a ! -e "$RUN/.outcome.new")" "$(ls -A "$RUN")"

	# The marker cannot be written: a <4> line, no marker.
	KIND=pendingwrite; setup; mkdir -p "$RUN"; chmod 0500 "$RUN"; run pre; chmod 0700 "$RUN"
	l="the marker cannot be written"
	ok "$l: exits 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT"
	ok "$l: a <4> line says the outcome will not be recorded" \
		"$(yes_if out_starts "<4>$TAG: The marker $RUN/pending could not be written, so whether this start initialises the store will not be recorded.")" "$OUT"
	same_line "$l"
	no_pending "$l"

	# An unreadable boot id: boot_id=-.
	KIND=nobootid; setup; run pre; BOOTID_PATH="$W/none"; run started
	ok "an unreadable boot id is recorded as -" "$(yes_if test "$(rec boot_id)" = -)" "$(cat "$RUN/outcome" 2>&1)"

	# A console that cannot be written: the outcome is unchanged and a <4>
	# sentence on stderr says the console missed the line.
	KIND=nokmsg; setup; run pre
	mkdir "$W/ro"; chmod 0500 "$W/ro"; KMSG_PATH="$W/ro/kmsg"
	run started; chmod 0700 "$W/ro"
	l="the console cannot be written"
	ok "$l: exits 0, outcome=initialised" "$(yes_if test "$RC" = 0 -a "$(rec outcome)" = initialised)" "rc=$RC $(cat "$RUN/outcome" 2>&1)"
	ok "$l: stdout still has the <6> line" "$(yes_if out_starts "<6>$TAG: outcome=initialised")" "$OUT"
	ok "$l: stderr has the <4> sentence that the console did not get it" \
		"$(yes_if grep -qxF -- "<4>$TAG: The log line could not be written to $W/ro/kmsg, so the console did not get it." "$W/stderr")" "$(cat "$W/stderr")"

	# An unknown phase: exit 2, a <3> line, nothing written.
	KIND=phase; setup; run start
	l="an unknown phase"
	ok "$l: exits 2" "$(yes_if test "$RC" = 2)" "rc=$RC $OUT"
	ok "$l: a <3> line names it" \
		"$(yes_if out_starts "<3>$TAG: rasputin-store-init.sh was run with 'start' instead of pre, started or stopped, so nothing was recorded.")" "$OUT"
	same_line "$l"
	ok "$l: nothing written" "$(yes_if test ! -e "$RUN")"

	# Every reason and every sentence line is a sentence, and different kinds
	# never share one.
	bad=$(cut -f2 "$REASONS" | grep -v '^[A-Z].*\.$' || true)
	ok "every reason and sentence line starts with a capital and ends with a full stop" "$(yes_if test -z "$bad")" "$bad"
}

echo "store-init outcome tests, shells:$TEST_SHELLS"
for SH in $TEST_SHELLS; do
	cases
done

# --- static: the script's defaults are the image's paths ---------------------
SH=static
. "$ROOT/test/lib/hcl-keys.sh"
data_default=$(sed -n 's/^DATA="${RASPUTIN_STOREINIT_DATA:-\(.*\)}"$/\1/p' "$SCRIPT")
storage=$(hcl_get "$HCL" 'storage "pebbledb"' path 2>&1)
ok "the script's default data directory ($data_default) is openbao.hcl's storage path ($storage)" \
	"$(yes_if test -n "$data_default" -a "$data_default" = "$storage")"
run_default=$(sed -n 's/^RUN="${RASPUTIN_STOREINIT_RUN:-\(.*\)}"$/\1/p' "$SCRIPT")
ok "the record lives on tmpfs, under /run ($run_default)" "$(yes_if test "${run_default#/run/}" != "$run_default")"
ok "the script is executable in the overlay" "$(yes_if test -x "$SCRIPT")"
for tok in 'outcome=$1 reason=' 'outcome=$1' '"boot_id=$(outcome_boot_id' '"reason=$3"'; do
	ok "the script names the contract token '$tok'" "$(yes_if grep -qF -- "$tok" "$SCRIPT")"
done

# --- the harness refuses root and a missing busybox ---------------------------
SH=harness
SH_BIN=$(command -v sh)
for row in root:0 nobusybox:1000; do
	name=${row%%:*} uid=${row#*:}
	stub="$TMP/stub-$name"
	mkdir -p "$stub"
	printf '#!%s\necho %s\n' "$SH_BIN" "$uid" > "$stub/id"
	chmod 0755 "$stub/id"
	out=$(PATH="$stub" REQUIRE_BUSYBOX=1 "$SH_BIN" "$0" 2>&1); rc=$?
	ok "$name: the suite exits non-zero" "$(yes_if test "$rc" != 0)" "rc=$rc"
	ok "$name: it says why in a sentence starting FAILED:" "$(yes_if eval 'printf "%s" "$out" | grep -q "^FAILED: .*\.$"')" "$out"
done
case "$TEST_SHELLS" in
	*busybox_applets*) ok "the busybox applets row ran" 0 ;;
	*) [ "${REQUIRE_BUSYBOX:-0}" = 1 ] && ok "the busybox applets row ran" 1 ;;
esac

echo "store-init outcome tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
