#!/bin/sh
#
# Tests for rasputin-seal-key.sh and its unit — the every-boot oneshot that
# creates the secrets store's seal key once, on a control plane with neither a
# key nor store data, and refuses when the store has data but no key
# (geekdojo/geekdojo-brain#803).
#
# Why. The script decides, on every boot of every control plane, whether to
# mint the key the whole store is sealed with. Minting one over existing data
# loses the data for good; failing open on an unreadable directory does the
# same; a key byte in a log is a leaked seal key. So every branch is run here
# against a scratch tree, and every run is searched for the key.
#
# How. The real script runs with every collaborator pointed at scratch files
# through RASPUTIN_SEALKEY_*. No root, no systemd: what systemd does with the
# unit is test/seal-key-functional.sh.
#
# Shells. Every case runs under each shell in TEST_SHELLS (default: whichever
# of sh, dash and bash are installed), under `busybox sh`, and under
# `busybox sh` with busybox's own applets ahead of PATH, as
# test/coredump-mode-test.sh does, so the image's ls, head, wc, mv, chmod, rm
# and sync are the ones exercised (F-803-04). REQUIRE_BUSYBOX=1 (CI sets it)
# makes a missing busybox a failure.
#
# Root. The suite refuses to run as root, with a failure and not a skip: root
# reads a mode-000 directory, so the fail-closed cases would pass over nothing.
#
# Run:  sh test/seal-key-test.sh
set -u
LC_ALL=C
export LC_ALL

# TC-803-16: refuse root and a missing busybox before anything else, so the
# self-check below can run this file with a PATH holding nothing but a stub id.
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
SCRIPT="$OVERLAY/usr/lib/rasputin/seal-key/rasputin-seal-key.sh"
UNIT="$OVERLAY/etc/systemd/system/rasputin-seal-key.service"
API_UNIT="$OVERLAY/etc/systemd/system/rasputin-api.service"
for f in "$SCRIPT" "$UNIT" "$API_UNIT"; do
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
	for applet in ls head wc mv chmod rm sync cat mkdir sed tr; do
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
not() { if "$@"; then return 1; else return 0; fi; }
perms() { ls -ld "$1" 2>/dev/null | cut -c1-10; }
nbytes() { wc -c < "$1" 2>/dev/null | tr -d ' \t'; }
hexof() { od -An -v -tx1 "$1" | tr -d ' \n'; }
contains() { grep -qF -- "$2" "$1" 2>/dev/null; }
rec() { sed -n "s/^$1=//p" "$RUN/outcome" 2>/dev/null; }
# listing DIR — every entry with type, mode, size and link target. Times are
# left out; the untouched case checks mtimes on its own.
listing() { ls -lnA "$1" 2>/dev/null | awk 'NR > 1 { $6 = $7 = $8 = ""; print }'; }

# setup — a fresh tree as tmpfiles leaves it on a node: openbao/ and
# openbao-seal/ empty and 0700, the runtime directory systemd makes, and the
# scratch collaborators. The random source is 64 bytes so a key that read past
# 32 is visible.
setup() {
	W=$(mktemp -d "$TMP/w.XXXXXX")
	P="$W/persist"
	RUN="$W/run"
	S="$P/openbao-seal"
	D="$P/openbao"
	mkdir -p "$S" "$D" "$RUN"
	chmod 0700 "$S" "$D" "$RUN"
	head -c 64 /dev/urandom > "$W/random"
	UUID="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | sed 's/^\(........\)\(....\)\(....\)\(....\)/\1-\2-\3-\4-/')"
	printf '%s\n' "$UUID" > "$W/uuid"
	BOOT_ID="b00710d0-0000-4000-8000-000000000001"
	printf '%s\n' "$BOOT_ID" > "$W/bootid"
	: > "$W/kmsg"
	KMSG_PATH="$W/kmsg"
	head -c 32 "$W/random" > "$W/want-key"
}

# run — the script under $SH; stdout, stderr and the exit status apart.
run() {
	case "$SH" in
		busybox_sh) set -- busybox sh "$SCRIPT" ;;
		busybox_applets) set -- busybox sh "$SCRIPT" ;;
		*) set -- "$SH" "$SCRIPT" ;;
	esac
	if [ "$SH" = busybox_applets ]; then
		PATH="$BUSYBOX_DIR:$PATH" RASPUTIN_SEALKEY_PERSIST="$P" RASPUTIN_SEALKEY_RUN="$RUN" \
			RASPUTIN_SEALKEY_RANDOM="$W/random" RASPUTIN_SEALKEY_UUID="$W/uuid" \
			RASPUTIN_SEALKEY_BOOTID="$W/bootid" RASPUTIN_SEALKEY_KMSG="$KMSG_PATH" \
			"$@" > "$W/stdout" 2> "$W/stderr"
	else
		RASPUTIN_SEALKEY_PERSIST="$P" RASPUTIN_SEALKEY_RUN="$RUN" \
			RASPUTIN_SEALKEY_RANDOM="$W/random" RASPUTIN_SEALKEY_UUID="$W/uuid" \
			RASPUTIN_SEALKEY_BOOTID="$W/bootid" RASPUTIN_SEALKEY_KMSG="$KMSG_PATH" \
			"$@" > "$W/stdout" 2> "$W/stderr"
	fi
	RC=$?
	OUT=$(cat "$W/stdout")
	# TC-803-17: every run's reason, kept with its kind for the cross-case check.
	_r=$(rec reason)
	[ -n "$_r" ] && printf '%s\t%s\n' "$KIND" "$_r" >> "$REASONS"
}

# no_secret LABEL KEYFILE — TC-803-15: none of the run's outputs holds the key
# as lowercase hex, uppercase hex, base64 or raw bytes. The raw check searches
# each output's own hex for the key's hex.
no_secret() {
	[ -s "$2" ] || { ok "$1: there is a key to search for" 1; return; }
	_lo=$(hexof "$2")
	_up=$(printf '%s' "$_lo" | tr 'a-f' 'A-F')
	_b64=$(base64 < "$2" | tr -d '\n')
	for _f in "$W/stdout" "$W/stderr" "$W/kmsg" "$RUN/outcome"; do
		[ -e "$_f" ] || continue
		_n=${_f##*/}
		ok "$1: $_n has no lowercase hex of the key" "$(yes_if not contains "$_f" "$_lo")"
		ok "$1: $_n has no uppercase hex of the key" "$(yes_if not contains "$_f" "$_up")"
		ok "$1: $_n has no base64 of the key" "$(yes_if not contains "$_f" "$_b64")"
		_raw=1
		case "$(hexof "$_f")" in *"$_lo"*) ;; *) _raw=0 ;; esac
		ok "$1: $_n has no raw key bytes" "$_raw"
	done
}

# no_files LABEL — nothing in openbao-seal/: no key, no fragment, no temp file.
no_files() {
	chmod 0700 "$S" 2>/dev/null
	ok "$1: openbao-seal/ holds no key, fragment or temp file" "$(yes_if test -z "$(ls -A "$S")")" "$(ls -A "$S")"
}
no_gate() { ok "$1: there is no gate file" "$(yes_if test ! -e "$RUN/refused")"; }
record_mode() { ok "$1: the record is 0600" "$(yes_if test "$(perms "$RUN/outcome")" = "-rw-------")" "$(perms "$RUN/outcome")"; }
# out_starts PREFIX — some line of stdout starts with PREFIX, taken literally.
out_starts() { printf '%s\n' "$OUT" | cut -c1-${#1} | grep -qxF -- "$1"; }
prio_line() { # prio_line LABEL PREFIX — stdout's line starts with PREFIX
	ok "$1: stdout has a line starting '$2'" \
		"$(yes_if out_starts "$2")" "$OUT"
}
# The line's tag, kept apart from its fields: the full literal with the failed
# outcome reads to the gitleaks generic-api-key rule as a key assignment
# (F-803-09).
TAG=rasputin-seal-key
# failed_case LABEL REASON_PART — the shared assertions of a failed run.
failed_case() {
	ok "$1: exits 1" "$(yes_if test "$RC" = 1)" "rc=$RC $OUT"
	ok "$1: the record says outcome=failed" "$(yes_if test "$(rec outcome)" = failed)" "$(cat "$RUN/outcome" 2>&1)"
	ok "$1: the record's key_id is -" "$(yes_if test "$(rec key_id)" = -)" "$(rec key_id)"
	ok "$1: the reason names the failure ('$2')" "$(yes_if contains "$RUN/outcome" "$2")" "$(rec reason)"
	prio_line "$1" "<3>$TAG: outcome=failed key_id=- reason=\""
	record_mode "$1"
	no_gate "$1"
}

# created_case LABEL — the TC-803-01 assertions, reused by TC-803-03 and others.
created_case() {
	ok "$1: exits 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT $(cat "$W/stderr")"
	ok "$1: seal-key is a regular file" "$(yes_if test -f "$S/seal-key" -a ! -L "$S/seal-key")"
	ok "$1: seal-key is 32 bytes" "$(yes_if test "$(nbytes "$S/seal-key")" = 32)" "$(nbytes "$S/seal-key")"
	ok "$1: seal-key is 0600" "$(yes_if test "$(perms "$S/seal-key")" = "-rw-------")" "$(perms "$S/seal-key")"
	ok "$1: seal-key is the first 32 bytes of the random source" "$(yes_if cmp -s "$W/want-key" "$S/seal-key")"
	ok "$1: seal.hcl is 0600" "$(yes_if test "$(perms "$S/seal.hcl")" = "-rw-------")" "$(perms "$S/seal.hcl")"
	# F-803-07: the multi-line form store-unit-functional.sh proves bao parses.
	printf 'seal "static" {\n  current_key_id = "rasputin-%s"\n  current_key    = "file:///run/credentials/openbao.service/seal-key"\n}\n' "$UUID" > "$W/want-hcl"
	ok "$1: seal.hcl is the multi-line seal \"static\" stanza with the id and the credential path" \
		"$(yes_if cmp -s "$W/want-hcl" "$S/seal.hcl")" "$(cat "$S/seal.hcl" 2>&1)"
	printf 'outcome=created\nboot_id=%s\nkey_id=rasputin-%s\n' "$BOOT_ID" "$UUID" > "$W/want-rec"
	ok "$1: the record holds outcome, boot_id and key_id, then a reason" \
		"$(yes_if test "$(head -n 3 "$RUN/outcome" 2>/dev/null)" = "$(cat "$W/want-rec")")" "$(cat "$RUN/outcome" 2>&1)"
	ok "$1: the record's fourth and last line is reason=" \
		"$(yes_if test "$(sed -n '4p' "$RUN/outcome" | cut -c1-7)" = "reason=" -a "$(wc -l < "$RUN/outcome" | tr -d ' ')" = 4)" "$(cat "$RUN/outcome" 2>&1)"
	record_mode "$1"
	no_gate "$1"
	ok "$1: no temp file is left" "$(yes_if test ! -e "$S/.seal-key.new" -a ! -e "$S/.seal.hcl.new")" "$(ls -A "$S")"
	ok "$1: openbao-seal/ holds exactly the key and the fragment" "$(yes_if test "$(ls -A "$S" | tr '\n' ' ')" = "seal-key seal.hcl ")" "$(ls -A "$S")"
	prio_line "$1" "<6>rasputin-seal-key: outcome=created key_id=rasputin-$UUID reason=\""
	ok "$1: stdout is one line" "$(yes_if test "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1)" "$OUT"
	ok "$1: kmsg has the same line" "$(yes_if test "$(cat "$W/kmsg")" = "$OUT")" "$(cat "$W/kmsg")"
	no_secret "$1" "$S/seal-key"
}

# valid_pair — a well-formed key and fragment, as an earlier boot left them,
# with an old mtime so any write would show.
valid_pair() {
	head -c 32 /dev/urandom > "$S/seal-key"
	printf 'seal "static" {\n  current_key_id = "rasputin-earlier"\n  current_key    = "file:///run/credentials/openbao.service/seal-key"\n}\n' > "$S/seal.hcl"
	chmod 0600 "$S/seal-key" "$S/seal.hcl"
	touch -t 200001010000 "$S/seal-key" "$S/seal.hcl"
	touch -t 200001010001 "$W/stamp"
	cp -p "$S/seal-key" "$W/key.before"
	cp -p "$S/seal.hcl" "$W/hcl.before"
}

cases() {
	REASONS="$TMP/reasons.$SH"
	: > "$REASONS"

	# TC-803-01: key absent, store empty: created.
	KIND=created; setup; run
	created_case "TC-803-01 key absent"
	cp "$S/seal-key" "$W/first-key"; cp "$S/seal.hcl" "$W/first-hcl"

	# TC-803-04: create-once. A second run with a new random source and uuid
	# leaves the first run's pair alone.
	KIND=untouched
	head -c 64 /dev/urandom > "$W/random"
	printf '%s\n' "11111111-2222-4333-8444-555555555555" > "$W/uuid"
	run
	ok "TC-803-04 second run: exits 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT"
	ok "TC-803-04 second run: outcome=untouched" "$(yes_if test "$(rec outcome)" = untouched)" "$(cat "$RUN/outcome" 2>&1)"
	ok "TC-803-04 second run: the key is the first run's" "$(yes_if cmp -s "$W/first-key" "$S/seal-key")"
	ok "TC-803-04 second run: the fragment is the first run's" "$(yes_if cmp -s "$W/first-hcl" "$S/seal.hcl")"
	ok "TC-803-04 second run: the record keeps the first run's key id" "$(yes_if test "$(rec key_id)" = "rasputin-$UUID")" "$(rec key_id)"
	no_secret "TC-803-04 second run" "$S/seal-key"

	# TC-803-02: key present, in an empty and a non-empty store: untouched.
	for row in empty data; do
		setup; valid_pair
		[ "$row" = data ] && printf 'x' > "$D/000001.log"
		run
		l="TC-803-02 key present, $row store"
		ok "$l: exits 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT"
		ok "$l: the key is byte-identical" "$(yes_if cmp -s "$W/key.before" "$S/seal-key")"
		ok "$l: the fragment is byte-identical" "$(yes_if cmp -s "$W/hcl.before" "$S/seal.hcl")"
		ok "$l: neither file's mtime moved" "$(yes_if test -z "$(find "$S/seal-key" "$S/seal.hcl" -newer "$W/stamp")")"
		ok "$l: outcome=untouched" "$(yes_if test "$(rec outcome)" = untouched)" "$(cat "$RUN/outcome" 2>&1)"
		ok "$l: the record carries the fragment's key id" "$(yes_if test "$(rec key_id)" = rasputin-earlier)" "$(rec key_id)"
		record_mode "$l"
		no_gate "$l"
		prio_line "$l" '<6>rasputin-seal-key: outcome=untouched key_id=rasputin-earlier reason="'
		no_secret "$l" "$S/seal-key"
	done

	# TC-803-03: an already provisioned node with no store yet: created.
	KIND=created; setup
	: > "$P/.provisioned"
	printf 'RASPUTIN_NODE_ROLE=controlplane\nRASPUTIN_NODE_ID=cp1\n' > "$P/node.env"
	run
	created_case "TC-803-03 provisioned node"

	# TC-803-05: an unreadable data directory: failed, no key.
	KIND=unlistable; setup; chmod 000 "$D"; run; chmod 0700 "$D"
	failed_case "TC-803-05 openbao/ mode 000" "could not be listed"
	ok "TC-803-05 openbao/ mode 000: the reason says store data could not be checked" \
		"$(yes_if contains "$RUN/outcome" "cannot be told whether store data exists")" "$(rec reason)"
	no_files "TC-803-05 openbao/ mode 000"

	# TC-803-06: the data path is a regular file, or absent.
	KIND=notdir; setup; rmdir "$D"; : > "$D"; run
	failed_case "TC-803-06 openbao is a file" "is not a directory"
	no_files "TC-803-06 openbao is a file"
	KIND=nodata; setup; rmdir "$D"; run
	failed_case "TC-803-06 openbao is absent" "does not exist"
	no_files "TC-803-06 openbao is absent"

	# TC-803-07: openbao-seal/ read-only, and unreadable: no partial files.
	for mode in 0500 000; do
		KIND=unwritable; setup; chmod "$mode" "$S"; run; chmod 0700 "$S"
		failed_case "TC-803-07 openbao-seal/ mode $mode" "could not be written"
		no_files "TC-803-07 openbao-seal/ mode $mode"
	done

	# TC-803-08: a 31-byte random source: failed, nothing renamed.
	KIND=shortread; setup; head -c 31 /dev/urandom > "$W/random"; run
	failed_case "TC-803-08 31-byte random source" "returned 31 bytes instead of 32"
	no_files "TC-803-08 31-byte random source"

	# TC-803-09: an empty uuid source.
	KIND=nouuid; setup; : > "$W/uuid"; run
	failed_case "TC-803-09 empty uuid" "returned no UUID"
	no_files "TC-803-09 empty uuid"

	# F-803-08 / F-803-10: a uuid holding anything but lowercase hex and
	# hyphens fails closed, so no quote or newline reaches the fragment.
	for row in upper quote newline; do
		KIND=uuidchars; setup
		case "$row" in
			upper) printf '%s\n' "$UUID" | tr 'a-f' 'A-F' > "$W/uuid" ;;
			quote) printf '%s"\n' "$UUID" > "$W/uuid" ;;
			newline) printf '%s\n%s\n' "${UUID%%-*}" "${UUID#*-}" > "$W/uuid" ;;
		esac
		run
		failed_case "F-803-08 uuid with a $row" "returned a UUID with characters other than lowercase hex and hyphens"
		no_files "F-803-08 uuid with a $row"
	done

	# F-803-08: a random source that cannot be read.
	KIND=randomread; setup; chmod 000 "$W/random"; run; chmod 0600 "$W/random"
	failed_case "F-803-08 unreadable random source" "The random source $W/random could not be read"
	no_files "F-803-08 unreadable random source"

	# F-803-08: a leftover temp file that cannot be removed. A non-empty
	# directory named .seal-key.new defeats rm -f; it is left as it was, and
	# nothing else is written.
	KIND=leftover; setup
	mkdir "$S/.seal-key.new"; printf 'x' > "$S/.seal-key.new/inner"
	run
	l="F-803-08 unremovable leftover temp"
	failed_case "$l" "The leftover temporary files in $S could not be removed"
	ok "$l: openbao-seal/ holds only the leftover directory" "$(yes_if test "$(ls -A "$S" | tr '\n' ' ')" = ".seal-key.new ")" "$(ls -A "$S")"
	ok "$l: the leftover directory and its file are unchanged" "$(yes_if test "$(ls -A "$S/.seal-key.new")" = inner -a "$(cat "$S/.seal-key.new/inner")" = x)" "$(ls -lA "$S/.seal-key.new")"

	# F-803-08: the record and the gate cannot be written (the run directory
	# is 0500). A failed run still exits 1 and says the record is missing. A
	# refusal still exits 2, but no gate holds the api back, and a <3> line
	# says so: that is the S12 enforcement path failing, so it must be loud.
	# Checked on stdout (the journal): the scratch kmsg file keeps only the last
	# line, because log() opens it with >, which on /dev/kmsg itself appends.
	REC_MSG="The outcome record"
	GATE_MSG="The gate file"
	KIND=nodata; setup; rmdir "$D"; chmod 0500 "$RUN"; run; chmod 0700 "$RUN"
	l="F-803-08 record cannot be written, failed run"
	ok "$l: exits 1" "$(yes_if test "$RC" = 1)" "rc=$RC $OUT"
	ok "$l: there is no record" "$(yes_if test ! -e "$RUN/outcome" -a ! -e "$RUN/.outcome.new")" "$(ls -A "$RUN")"
	prio_line "$l" "<3>$TAG: $REC_MSG $RUN/outcome could not be written, so only this journal line carries the outcome."
	prio_line "$l" "<3>$TAG: outcome=failed key_id=- reason=\"The store's data directory $D does not exist"
	no_gate "$l"
	no_files "$l"
	printf '%s\n' "$OUT" | sed -n "s/^<3>$TAG: \($REC_MSG .*\)$/recordwrite\t\1/p" >> "$REASONS"

	KIND=refused; setup; printf 'one' > "$D/MANIFEST"; cp -Rp "$D" "$W/data.before"
	chmod 0500 "$RUN"; run; chmod 0700 "$RUN"
	l="F-803-08 gate cannot be written, refused run"
	ok "$l: exits 2" "$(yes_if test "$RC" = 2)" "rc=$RC $OUT"
	no_gate "$l"
	ok "$l: there is no record" "$(yes_if test ! -e "$RUN/outcome")" "$(ls -A "$RUN")"
	prio_line "$l" "<3>$TAG: $GATE_MSG $RUN/refused could not be written, so rasputin-api.service is not held back by this refusal."
	prio_line "$l" "<3>$TAG: $REC_MSG $RUN/outcome could not be written, so only this journal line carries the outcome."
	prio_line "$l" "<2>$TAG: outcome=refused key_id=- reason=\"The secrets store has data but no seal key"
	ok "$l: the data tree is unchanged" "$(yes_if diff -r "$W/data.before" "$D")" "$(diff -r "$W/data.before" "$D" 2>&1)"
	no_files "$l"
	printf '%s\n' "$OUT" | sed -n "s/^<3>$TAG: \($GATE_MSG .*\)$/gatewrite\t\1/p" >> "$REASONS"

	# TC-803-10: store data, no key: refused. TC-803-11: a dotfile alone.
	for row in tree dotfile; do
		KIND=refused; setup
		if [ "$row" = tree ]; then
			printf 'one' > "$D/MANIFEST"; mkdir "$D/sub"; printf 'two' > "$D/sub/000001.sst"
			l="TC-803-10 store data, no key"
		else
			printf 'x' > "$D/.x"
			l="TC-803-11 dotfile only"
		fi
		cp -Rp "$D" "$W/data.before"
		run
		ok "$l: exits 2" "$(yes_if test "$RC" = 2)" "rc=$RC $OUT"
		no_files "$l"
		ok "$l: the data tree's names and bytes are unchanged" "$(yes_if diff -r "$W/data.before" "$D")" "$(diff -r "$W/data.before" "$D" 2>&1)"
		ok "$l: the gate exists" "$(yes_if test -f "$RUN/refused")"
		ok "$l: outcome=refused" "$(yes_if test "$(rec outcome)" = refused)" "$(cat "$RUN/outcome" 2>&1)"
		ok "$l: key_id=-" "$(yes_if test "$(rec key_id)" = -)" "$(rec key_id)"
		ok "$l: boot_id is the boot's" "$(yes_if test "$(rec boot_id)" = "$BOOT_ID")" "$(rec boot_id)"
		ok "$l: the reason is the refusal sentence, exactly" \
			"$(yes_if test "$(rec reason)" = "The secrets store has data but no seal key, so this control plane will not start. A new key cannot open the existing data. Recover by restoring a backup onto a fresh install.")" "$(rec reason)"
		record_mode "$l"
		prio_line "$l" '<2>rasputin-seal-key: outcome=refused key_id=- reason="The secrets store has data but no seal key, so this control plane will not start.'
		ok "$l: kmsg has the sentence with a <2> prefix" \
			"$(yes_if grep -q '^<2>rasputin-seal-key: .*The secrets store has data but no seal key, so this control plane will not start. A new key cannot open the existing data. Recover by restoring a backup onto a fresh install.' "$W/kmsg")" "$(cat "$W/kmsg")"
	done

	# TC-803-12: an orphan fragment, no key: replaced.
	KIND=created; setup
	printf 'seal "static" {\n  current_key_id = "stale"\n}\n' > "$S/seal.hcl"
	run
	ok "TC-803-12 orphan fragment: exits 0, outcome=created" "$(yes_if test "$RC" = 0 -a "$(rec outcome)" = created)" "rc=$RC $(cat "$RUN/outcome" 2>&1)"
	ok "TC-803-12 orphan fragment: seal.hcl carries the record's new key id" \
		"$(yes_if grep -qF "current_key_id = \"$(rec key_id)\"" "$S/seal.hcl")" "$(cat "$S/seal.hcl")"
	ok "TC-803-12 orphan fragment: the new id is rasputin-<uuid>" "$(yes_if test "$(rec key_id)" = "rasputin-$UUID")" "$(rec key_id)"
	ok "TC-803-12 orphan fragment: the stale id is gone" "$(yes_if not contains "$S/seal.hcl" stale)"
	no_secret "TC-803-12 orphan fragment" "$S/seal-key"

	# TC-803-13: a malformed existing key: failed, never repaired.
	# hcldir and hcllink (F-803-08): a valid key whose fragment is a directory
	# or a symbolic link to a valid fragment.
	for row in key31 key0 keydir keylink nohcl emptyhcl hcldir hcllink; do
		setup
		case "$row" in
			key31) KIND=keysize; head -c 31 /dev/urandom > "$S/seal-key"; printf 'seal "static" {}\n' > "$S/seal.hcl"; want="is 31 bytes long instead of 32" ;;
			key0) KIND=keysize; : > "$S/seal-key"; printf 'seal "static" {}\n' > "$S/seal.hcl"; want="is 0 bytes long instead of 32" ;;
			keydir) KIND=keytype; mkdir "$S/seal-key"; want="is not a regular file" ;;
			keylink) KIND=keylink; ln -s "$W/nonexistent" "$S/seal-key"; want="is a symbolic link" ;;
			nohcl) KIND=nohcl; head -c 32 /dev/urandom > "$S/seal-key"; want="seal configuration $S/seal.hcl is missing" ;;
			emptyhcl) KIND=emptyhcl; head -c 32 /dev/urandom > "$S/seal-key"; : > "$S/seal.hcl"; want="seal configuration $S/seal.hcl is empty" ;;
			hcldir) KIND=hcltype; head -c 32 /dev/urandom > "$S/seal-key"; mkdir "$S/seal.hcl"; want="seal configuration $S/seal.hcl is not a regular file" ;;
			hcllink) KIND=hcltype; head -c 32 /dev/urandom > "$S/seal-key"
				printf 'seal "static" {\n  current_key_id = "rasputin-earlier"\n}\n' > "$W/real.hcl"
				ln -s "$W/real.hcl" "$S/seal.hcl"; want="seal configuration $S/seal.hcl is not a regular file" ;;
		esac
		before=$(listing "$S")
		[ -f "$S/seal-key" ] && cp -p "$S/seal-key" "$W/key.before"
		[ -f "$S/seal.hcl" ] && cp -p "$S/seal.hcl" "$W/hcl.before"
		run
		l="TC-803-13 $row"
		failed_case "$l" "$want"
		ok "$l: openbao-seal/ lists the same entries, types, modes, sizes and link targets" \
			"$(yes_if test "$(listing "$S")" = "$before")" "before: $before | after: $(listing "$S")"
		[ -f "$W/key.before" ] && ok "$l: the key's bytes are unchanged" "$(yes_if cmp -s "$W/key.before" "$S/seal-key")"
		[ -f "$W/hcl.before" ] && ok "$l: the fragment's bytes are unchanged" "$(yes_if cmp -s "$W/hcl.before" "$S/seal.hcl")"
		[ "$row" = keylink ] && ok "$l: the link target is unchanged" "$(yes_if test "$(readlink "$S/seal-key")" = "$W/nonexistent")"
		[ "$row" = hcllink ] && ok "$l: the fragment is still a link to the same target" "$(yes_if test -L "$S/seal.hcl" -a "$(readlink "$S/seal.hcl")" = "$W/real.hcl")"
		[ "$row" = hcldir ] && ok "$l: the fragment is still an empty directory" "$(yes_if test -d "$S/seal.hcl" -a -z "$(ls -A "$S/seal.hcl")")"
		ok "$l: no temp file is left" "$(yes_if test ! -e "$S/.seal-key.new" -a ! -e "$S/.seal.hcl.new")" "$(ls -A "$S")"
		rm -f "$W/key.before" "$W/hcl.before"
	done

	# TC-803-14: a stale gate and stale temp files are cleared.
	KIND=created; setup
	printf 'stale\n' > "$RUN/refused"
	printf 'stale-key-bytes' > "$S/.seal-key.new"
	printf 'stale-hcl' > "$S/.seal.hcl.new"
	run
	created_case "TC-803-14 stale gate and temps"

	# Code review r2 (ERR-WRAP): a console that cannot be written. The kmsg
	# path is a file under a mode-0500 directory. The outcome is the same as
	# with a console, a warning on stderr (the journal) says the console
	# missed the line, and stderr holds no key bytes.
	KIND=created; setup
	mkdir "$W/ro"; chmod 0500 "$W/ro"; KMSG_PATH="$W/ro/kmsg"
	run; chmod 0700 "$W/ro"
	l="kmsg cannot be written"
	ok "$l: exits 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT $(cat "$W/stderr")"
	ok "$l: outcome=created" "$(yes_if test "$(rec outcome)" = created)" "$(cat "$RUN/outcome" 2>&1)"
	ok "$l: seal-key is the first 32 bytes of the random source" "$(yes_if cmp -s "$W/want-key" "$S/seal-key")"
	ok "$l: openbao-seal/ holds exactly the key and the fragment" "$(yes_if test "$(ls -A "$S" | tr '\n' ' ')" = "seal-key seal.hcl ")" "$(ls -A "$S")"
	prio_line "$l" "<6>$TAG: outcome=created key_id=rasputin-$UUID reason=\""
	ok "$l: stderr has the WARN sentence that the console did not get the line" \
		"$(yes_if grep -qxF -- "<4>$TAG: The log line could not be written to $W/ro/kmsg, so the console did not get it." "$W/stderr")" "$(cat "$W/stderr")"
	ok "$l: no kmsg file was made" "$(yes_if test ! -e "$W/ro/kmsg")"
	no_secret "$l" "$S/seal-key"

	# TC-803-17: levels are pinned by prio_line above. Here, every reason is a
	# sentence, and different failure kinds never share one (F-803-06).
	# The record- and gate-write sentences are log lines, not reason= values;
	# their rows add them under their own kinds so the same checks cover them.
	bad=$(cut -f2 "$REASONS" | grep -v '^[A-Z].*\.$' || true)
	ok "TC-803-17 every reason starts with a capital and ends with a full stop" "$(yes_if test -z "$bad")" "$bad"
	shared=$(sort -u "$REASONS" | cut -f2 | sort | uniq -d)
	ok "TC-803-17 different outcome and failure kinds have different reasons" "$(yes_if test -z "$shared")" "$shared"
	kinds=$(cut -f1 "$REASONS" | sort -u | wc -l | tr -d ' ')
	ok "TC-803-17 the reasons cover all 20 kinds staged here (got $kinds)" "$(yes_if test "$kinds" = 20)" "$(cut -f1 "$REASONS" | sort -u | tr '\n' ' ')"
}

echo "seal-key tests, shells:$TEST_SHELLS"
for SH in $TEST_SHELLS; do
	cases
done

# --- TC-803-18: the unit files, statically ------------------------------------
SH=static
# directives UNIT — "Section|Key=Value" per directive; comments and blanks out.
directives() {
	awk '
		{ sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "") }
		/^$/ || /^[#;]/ { next }
		/^\[.*\]$/ { sect = substr($0, 2, length($0) - 2); next }
		{ print sect "|" $0 }
	' "$1"
}
got=$(directives "$UNIT" | grep -v '^Unit|Description=' | sort)
want=$(sort <<'EOF'
Unit|After=rasputin-firstboot.service
Unit|Before=openbao.service rasputin-api.service
Unit|RequiresMountsFor=/var/lib/rasputin
Unit|ConditionPathExists=/var/lib/rasputin/role.controlplane
Service|Type=oneshot
Service|RemainAfterExit=yes
Service|ExecStart=/usr/lib/rasputin/seal-key/rasputin-seal-key.sh
Service|ProtectSystem=strict
Service|ReadWritePaths=/var/lib/rasputin/openbao-seal
Service|RuntimeDirectory=rasputin-seal-key
Service|RuntimeDirectoryMode=0700
Service|RuntimeDirectoryPreserve=yes
Install|WantedBy=multi-user.target
EOF
)
ok "TC-803-18 rasputin-seal-key.service has exactly the planned directives, in their sections" \
	"$(yes_if test "$got" = "$want")" "$(printf 'got:\n%s\nwant:\n%s' "$got" "$want" | tr '\n' '|')"
ok "TC-803-18 rasputin-seal-key.service has one Description=" "$(yes_if test "$(directives "$UNIT" | grep -c '^Unit|Description=')" = 1)"
for k in UMask Environment Requires; do
	ok "TC-803-18 rasputin-seal-key.service sets no $k=" "$(yes_if not grep -qE "^[[:space:]]*$k=" "$UNIT")"
done
exec_path=$(directives "$UNIT" | sed -n 's/^Service|ExecStart=//p')
ok "TC-803-18 ExecStart names the shipped script, executable in the overlay" \
	"$(yes_if test -x "$OVERLAY$exec_path" -a "$OVERLAY$exec_path" = "$SCRIPT")" "$exec_path"
asserts=$(directives "$API_UNIT" | sed -n 's/^Unit|AssertPathExists=//p')
ok "TC-803-18 rasputin-api.service has exactly one assertion, on the gate" \
	"$(yes_if test "$asserts" = '!/run/rasputin-seal-key/refused')" "$asserts"
run_default=$(sed -n 's/^RUN="${RASPUTIN_SEALKEY_RUN:-\(.*\)}"$/\1/p' "$SCRIPT")
gate_rel=$(sed -n 's/^GATE="$RUN\/\(.*\)"$/\1/p' "$SCRIPT")
ok "TC-803-18 the api's gate path is the script's default gate path ($run_default/$gate_rel)" \
	"$(yes_if test "!$run_default/$gate_rel" = "$asserts")" "$run_default/$gate_rel vs $asserts"
rt=$(directives "$UNIT" | sed -n 's/^Service|RuntimeDirectory=//p')
ok "TC-803-18 the unit's RuntimeDirectory is the script's default run directory" \
	"$(yes_if test "/run/$rt" = "$run_default")" "/run/$rt vs $run_default"
# F-803-03: the contract #828 reads is literal in the script.
for tok in 'outcome=$_outcome key_id=$_key_id reason=' 'rasputin-seal-key: outcome=refused' \
	'rasputin-seal-key: outcome=created' '/var/lib/rasputin/openbao-seal/seal-key'; do
	ok "TC-803-18 the script names the contract token '$tok'" "$(yes_if contains "$SCRIPT" "$tok")"
done

# --- TC-803-16: the harness refuses root and a missing busybox ----------------
# Run this file again with a PATH that holds only a stub id: as uid 0 it must
# fail with a sentence before any case runs; as a user with REQUIRE_BUSYBOX=1
# and no busybox on that PATH it must fail too.
SH=harness
SH_BIN=$(command -v sh)
for row in root:0 nobusybox:1000; do
	name=${row%%:*} uid=${row#*:}
	stub="$TMP/stub-$name"
	mkdir -p "$stub"
	printf '#!%s\necho %s\n' "$SH_BIN" "$uid" > "$stub/id"
	chmod 0755 "$stub/id"
	out=$(PATH="$stub" REQUIRE_BUSYBOX=1 "$SH_BIN" "$0" 2>&1); rc=$?
	ok "TC-803-16 $name: the suite exits non-zero" "$(yes_if test "$rc" != 0)" "rc=$rc"
	ok "TC-803-16 $name: it says why in a sentence starting FAILED:" "$(yes_if eval 'printf "%s" "$out" | grep -q "^FAILED: .*\.$"')" "$out"
	ok "TC-803-16 $name: no case ran" "$(yes_if not eval 'printf "%s" "$out" | grep -q "seal-key tests, shells"')" "$out"
done
case "$TEST_SHELLS" in
	*busybox_applets*) ok "TC-803-16 the busybox applets row ran" 0 ;;
	*) [ "${REQUIRE_BUSYBOX:-0}" = 1 ] && ok "TC-803-16 the busybox applets row ran" 1 ;;
esac

echo "seal-key tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
