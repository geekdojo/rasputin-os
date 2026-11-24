#!/bin/sh
#
# Tests for keycloak.service's deny-list staging hook,
# identity-stage-denylist.sh (geekdojo/geekdojo-brain#1145, TC-1145-09 to
# TC-1145-12), and for the realm staging hook beside it, which shares its
# rules for writing in the keycloak uid's data directory (kcdata-stage.sh).
#
# Why. The realm's password policy names the list, and once the realm stores
# that policy a missing list makes the realm unloadable, so the copy has to be
# there, whole, on every start; and the hook writes as root inside a directory
# a less privileged uid owns, so a planted link must never be written through.
# Every branch runs against a scratch tree, and each run's files, modes, inodes,
# exit status and log lines are checked.
#
# How. The real scripts run with every collaborator pointed at scratch files
# through RASPUTIN_KCDENY_* and RASPUTIN_KCSTAGE_*, and OWNER set to the test
# user. No root and no systemd: what systemd does with the hook is
# test/identity-unit-functional.sh's scenario 41 (TC-1145-13).
#
# Shells. Every case runs under each shell in TEST_SHELLS (default: whichever
# of sh, dash and bash are installed), under `busybox sh`, and under
# `busybox sh` with busybox's own applets ahead of PATH. REQUIRE_BUSYBOX=1 (CI
# sets it) makes a missing busybox a failure.
#
# Root. The suite refuses to run as root, with a failure and not a skip: root
# reads a mode-0000 file and writes into a mode-0500 directory, so the
# fail-closed cases would pass over nothing.
#
# Run:  sh test/identity-stage-denylist-test.sh
set -u
LC_ALL=C
export LC_ALL

if [ "$(id -u)" = 0 ]; then
	echo "FAILED: this suite must not run as root, because root reads a mode-0000 file and the fail-closed cases would prove nothing." >&2
	exit 1
fi
if [ "${REQUIRE_BUSYBOX:-0}" = "1" ] && ! command -v busybox >/dev/null 2>&1; then
	echo "FAILED: REQUIRE_BUSYBOX=1 but busybox is not installed." >&2
	exit 1
fi

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
IDDIR="$OVERLAY/usr/lib/rasputin/identity"
DENY="$IDDIR/identity-stage-denylist.sh"
STAGE="$IDDIR/identity-stage-import.sh"
for f in "$DENY" "$STAGE" "$IDDIR/kcdata-stage.sh" "$IDDIR/armed.sh" "$OVERLAY/usr/lib/rasputin/outcome/outcome.sh"; do
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
	for applet in ls mv cp chmod chown rm cat mkdir dirname; do
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
owner() { ls -ldn "$1" 2>/dev/null | awk '{ print $3 ":" $4 }'; }
inode() { ls -id "$1" 2>/dev/null | awk '{ print $1 }'; }
# fingerprint PATH — inode, mode, owner, size, time and bytes: a file left
# exactly as it was, neither rewritten nor replaced.
fingerprint() { printf '%s ' "$(ls -lind "$1" 2>/dev/null)"; cksum < "$1"; }
ME="$(id -u):$(id -g)"
LIST=rasputin-common-passwords.txt

# setup — a fresh scratch tree: the release's deny list directory with one
# list, keycloak/data with nothing staged, identity/ unarmed, a realm baseline.
setup() {
	W=$(mktemp -d "$TMP/w.XXXXXX")
	SRC="$W/share/password-blacklists"
	KCDATA="$W/keycloak/data"
	TARGET="$KCDATA/password-blacklists"
	STAGED_LIST="$TARGET/$LIST"
	IDENT="$W/identity"
	BASELINE="$W/share/realm-baseline.json"
	mkdir -p "$SRC" "$KCDATA" "$IDENT"
	chmod 0700 "$W/keycloak" "$KCDATA" "$IDENT"
	printf 'correcthorsebatterystaple\npasswordpassword123\n' > "$SRC/$LIST"
	chmod 0644 "$SRC/$LIST"
	printf '{"realm": "rasputin"}\n' > "$BASELINE"
	: > "$W/kmsg"
}

# run SCRIPT — run SCRIPT under $SH with every collaborator in the scratch
# tree; sets RC and OUT (stdout, the journal's lines).
run() {
	case "$SH" in
		busybox_sh|busybox_applets) _cmd="busybox sh" ;;
		*) _cmd=$SH ;;
	esac
	_path=$PATH
	[ "$SH" = busybox_applets ] && _path="$BUSYBOX_DIR:$PATH"
	# shellcheck disable=SC2086 # _cmd is "busybox sh" on purpose
	env PATH="$_path" \
		RASPUTIN_KCDENY_SOURCE="$SRC" RASPUTIN_KCDENY_DATA="$KCDATA" RASPUTIN_KCDENY_OWNER="$ME" \
		RASPUTIN_KCDENY_KMSG="$W/kmsg" \
		RASPUTIN_KCSTAGE_IDENTITY="$IDENT" RASPUTIN_KCSTAGE_BASELINE="$BASELINE" \
		RASPUTIN_KCSTAGE_DATA="$KCDATA" RASPUTIN_KCSTAGE_OWNER="$ME" RASPUTIN_KCSTAGE_KMSG="$W/kmsg" \
		$_cmd "$1" > "$W/stdout" 2> "$W/stderr"
	RC=$?
	OUT=$(cat "$W/stdout")
}
deny() { run "$DENY"; }
# logged PRIORITY TEXT — stdout has a <PRIORITY>identity-stage-denylist: line
# containing TEXT.
logged() { printf '%s\n' "$OUT" | grep "^<$1>identity-stage-denylist: " | grep -qF -- "$2"; }
# lines PRIORITY — how many <PRIORITY> lines the hook wrote on stdout.
lines() { printf '%s\n' "$OUT" | grep -c "^<$1>identity-stage-denylist: "; }
# no_tmp — no temp name is left in the target directory.
no_tmp() { [ -z "$(ls -A "$TARGET" 2>/dev/null | grep '\.tmp$')" ]; }

for SH in $TEST_SHELLS; do

	# --- TC-1145-09: the list staged, unarmed then armed, beside the realm --
	setup
	for arm in unarmed armed; do
		[ "$arm" = armed ] && : > "$IDENT/armed"
		deny
		ok "TC-1145-09 $arm: the deny-list hook exits 0 with a <6> line" \
			"$(yes_if test "$RC" = 0 -a "$(lines 6)" = 1 -a "$(lines 3)" = 0)" "rc=$RC $OUT $(cat "$W/stderr")"
		ok "TC-1145-09 $arm: password-blacklists is 0700, owned by OWNER" \
			"$(yes_if test "$(perms "$TARGET")" = drwx------ -a "$(owner "$TARGET")" = "$ME")" "$(ls -ld "$TARGET" 2>&1)"
		ok "TC-1145-09 $arm: the list is 0600, owned by OWNER, byte-equal to the source" \
			"$({ [ "$(perms "$STAGED_LIST")" = -rw------- ] && [ "$(owner "$STAGED_LIST")" = "$ME" ] && cmp -s "$SRC/$LIST" "$STAGED_LIST"; } && echo 0 || echo 1)" \
			"$(ls -l "$STAGED_LIST" 2>&1)"
		ok "TC-1145-09 $arm: the directory holds the list alone, no .tmp left" \
			"$(yes_if test "$(ls -A "$TARGET")" = "$LIST")" "$(ls -A "$TARGET")"
		run "$STAGE"
		if [ "$arm" = unarmed ]; then
			ok "TC-1145-09 unarmed: the realm staging still exits 0 and stages the baseline" \
				"$(yes_if test "$RC" = 0 -a -f "$KCDATA/import/realm-baseline.json")" "rc=$RC $OUT"
		else
			ok "TC-1145-09 armed: the realm staging still exits 0 and removes the baseline" \
				"$(yes_if test "$RC" = 0 -a ! -e "$KCDATA/import/realm-baseline.json")" "rc=$RC $OUT"
		fi
		ok "TC-1145-09 $arm: the realm staging leaves the staged list as it was" \
			"$(yes_if cmp -s "$SRC/$LIST" "$STAGED_LIST")"
	done

	# --- TC-1145-10: a stale copy replaced by rename ---------------------
	setup
	mkdir -m 0700 "$TARGET"
	printf 'an older list\n' > "$STAGED_LIST"
	chmod 0644 "$STAGED_LIST"
	before=$(inode "$STAGED_LIST")
	deny
	ok "TC-1145-10 a stale copy: exit 0, the name holds the source's bytes" \
		"$(yes_if test "$RC" = 0 -a -f "$STAGED_LIST")" "rc=$RC $OUT"
	ok "TC-1145-10 a stale copy: the bytes equal the source's" "$(yes_if cmp -s "$SRC/$LIST" "$STAGED_LIST")"
	ok "TC-1145-10 a stale copy: replaced by a rename (inode $before, now $(inode "$STAGED_LIST"))" \
		"$(yes_if test -n "$before" -a "$(inode "$STAGED_LIST")" != "$before")"
	ok "TC-1145-10 a stale copy: 0600, owned by OWNER, no .tmp left" \
		"$({ [ "$(perms "$STAGED_LIST")" = -rw------- ] && [ "$(owner "$STAGED_LIST")" = "$ME" ] && no_tmp; } && echo 0 || echo 1)" \
		"$(ls -lA "$TARGET")"
	# An identical copy is replaced too: no skip, a fresh copy on every start
	# (F-1145-01).
	before=$(inode "$STAGED_LIST")
	deny
	ok "TC-1145-10 an identical copy: exit 0, replaced again by a rename" \
		"$(yes_if test "$RC" = 0 -a "$(inode "$STAGED_LIST")" != "$before")" "rc=$RC $OUT"

	# --- TC-1145-11: an older api tarball, an existing copy kept ---------
	setup
	deny
	before=$(fingerprint "$STAGED_LIST")
	rm -rf "$SRC"
	deny
	ok "TC-1145-11 source absent: exit 0 with exactly one line, at <6>" \
		"$({ [ "$RC" = 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c .)" = 1 ] && logged 6 'ships no password deny list'; } && echo 0 || echo 1)" \
		"rc=$RC $OUT"
	ok "TC-1145-11 source absent: the existing copy's inode, mode, size, time and bytes are unchanged" \
		"$(yes_if test "$(fingerprint "$STAGED_LIST")" = "$before")" "$before / $(fingerprint "$STAGED_LIST")"
	setup
	rm -rf "$SRC"
	deny
	ok "TC-1145-11 source absent, nothing staged: exit 0, nothing created" \
		"$(yes_if test "$RC" = 0 -a ! -e "$TARGET")" "rc=$RC $OUT"

	# --- TC-1145-12: refusals --------------------------------------------
	# password-blacklists, or the list's name, planted as a symlink to a
	# scratch "root" directory or file.
	for plant in dir name; do
		setup
		RD="$W/rootdir"
		mkdir "$RD"; printf 'root-owned\n' > "$RD/$LIST"; chmod 0640 "$RD/$LIST"
		before=$(fingerprint "$RD/$LIST")
		case "$plant" in
			dir) ln -s "$RD" "$TARGET" ;;
			name) mkdir -m 0700 "$TARGET"; ln -s "$RD/$LIST" "$STAGED_LIST" ;;
		esac
		deny
		ok "TC-1145-12 $plant planted as a symlink: exit 1 with one <3> line" \
			"$(yes_if test "$RC" = 1 -a "$(lines 3)" = 1)" "rc=$RC $OUT"
		ok "TC-1145-12 $plant planted as a symlink: the link is kept and its target unwritten, nothing added beside it" \
			"$({ [ "$(fingerprint "$RD/$LIST")" = "$before" ] && [ "$(ls -A "$RD")" = "$LIST" ] \
				&& { [ -L "$TARGET" ] || [ -L "$STAGED_LIST" ]; }; } && echo 0 || echo 1)" "$(ls -lA "$RD" "$TARGET" 2>&1)"
		ok "TC-1145-12 $plant planted as a symlink: no .tmp anywhere" \
			"$(yes_if test -z "$(find "$W" -name '*.tmp')")" "$(find "$W" -name '*.tmp')"
	done
	# password-blacklists a regular file.
	setup
	printf 'x\n' > "$TARGET"
	deny
	ok "TC-1145-12 password-blacklists a regular file: exit 1 with a <3> line, the file as it was" \
		"$({ [ "$RC" = 1 ] && logged 3 'is not a real directory' && [ "$(cat "$TARGET")" = x ]; } && echo 0 || echo 1)" "rc=$RC $OUT"
	# keycloak/data missing.
	setup
	rmdir "$KCDATA"
	deny
	ok "TC-1145-12 keycloak/data missing: exit 1 with a <3> line, nothing created" \
		"$({ [ "$RC" = 1 ] && logged 3 'missing or not a real directory' && [ ! -e "$KCDATA" ]; } && echo 0 || echo 1)" "rc=$RC $OUT"
	# The source list unreadable: nothing written, not even the directory.
	setup
	chmod 0000 "$SRC/$LIST"
	deny
	chmod 0644 "$SRC/$LIST"
	ok "TC-1145-12 the source list unreadable: exit 1 with a <3> line naming it, nothing written" \
		"$({ [ "$RC" = 1 ] && logged 3 'cannot be read' && [ ! -e "$TARGET" ]; } && echo 0 || echo 1)" "rc=$RC $OUT"
	# The source directory unreadable.
	setup
	chmod 0000 "$SRC"
	deny
	chmod 0755 "$SRC"
	ok "TC-1145-12 the source directory unreadable: exit 1 with a <3> line, nothing written" \
		"$({ [ "$RC" = 1 ] && logged 3 'cannot be read' && [ ! -e "$TARGET" ]; } && echo 0 || echo 1)" "rc=$RC $OUT"
	# The copy fails (the target directory not writable): the previous copy
	# stays whole and no temp name is left.
	setup
	deny
	printf 'a newer list\n' >> "$SRC/$LIST"
	before=$(fingerprint "$STAGED_LIST")
	chmod 0500 "$TARGET"
	deny
	chmod 0700 "$TARGET"
	ok "TC-1145-12 the copy fails: exit 1 with one <3> line" \
		"$({ [ "$RC" = 1 ] && [ "$(lines 3)" = 1 ] && logged 3 'could not be staged'; } && echo 0 || echo 1)" "rc=$RC $OUT"
	ok "TC-1145-12 the copy fails: the previous copy is intact, no .tmp left" \
		"$({ [ "$(fingerprint "$STAGED_LIST")" = "$before" ] && no_tmp; } && echo 0 || echo 1)" "$(ls -lA "$TARGET")"
	# The chown fails (an owner the test user cannot give): the same.
	setup
	deny
	before=$(fingerprint "$STAGED_LIST")
	ME_SAVED=$ME; ME=0:0
	deny
	ME=$ME_SAVED
	ok "TC-1145-12 the chown fails: exit 1, the previous copy intact, no .tmp left" \
		"$({ [ "$RC" = 1 ] && [ "$(fingerprint "$STAGED_LIST")" = "$before" ] && no_tmp; } && echo 0 || echo 1)" "rc=$RC $OUT $(ls -lA "$TARGET")"
done

echo "identity-stage-denylist-test: $pass passed, $fail failed (shells:$TEST_SHELLS)"
[ "$fail" -eq 0 ]
