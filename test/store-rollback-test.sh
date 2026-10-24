#!/bin/sh
#
# Tests for rasputin-store-rollback.sh, the secrets store's version gate that
# openbao.service runs second in each start (geekdojo/geekdojo-brain#801,
# TC-801-01 to TC-801-25).
#
# Why. A wrong decision here either starts an older store on data a newer one
# wrote, wipes secrets written since an update, or holds a healthy store
# stopped. So every branch runs against a scratch tree, and each run's exit
# code, the data hashes, the marker, the hold, the aside copy, the work
# directories, the record and the line on stdout and on the console sink are
# checked.
#
# How. The real script runs with every collaborator pointed at a scratch tree
# through RASPUTIN_STOREROLLBACK_*; the store binary is a stub printing the
# real `bao version` line's shape ("OpenBao vX.Y.Z (...)", measured on v2.7.1).
# The pre-update copy is built in #800's shape (F-801-03): regular-file
# members only, named explicitly in sorted order, then store/openbao-version
# written with no trailing newline, and no directory members. Failures are
# injected by shims first on PATH, and under busybox sh through a function
# calling the shim (TEST HARNESS, as in test/store-restore-test.sh): an mv
# that fails a chosen rename (the swap, the marker commit), a tar that fails
# its create or its extract, an rm that fails on chosen paths, and a chown
# that records its arguments. Each shim then runs the real tool. No root, no
# systemd: what systemd does with the step is test/store-unit-functional.sh
# scenario 13.
#
# Shells (TC-801-24). Every case runs under each shell in TEST_SHELLS
# (default: whichever of sh, dash and bash are installed), under `busybox sh`,
# and under `busybox sh` with busybox's own applets ahead of PATH, tar
# included, so the image's tools are the ones exercised. REQUIRE_BUSYBOX=1 (CI
# sets it) makes a missing busybox a failure.
#
# Root. The suite refuses to run as root, with a failure and not a skip: root
# reads a mode-000 copy and lists a mode-000 directory, so those cases would
# prove nothing.
#
# Run:  sh test/store-rollback-test.sh
set -u
LC_ALL=C
export LC_ALL
# No AppleDouble members when the host tar is macOS's bsdtar.
COPYFILE_DISABLE=1
export COPYFILE_DISABLE

if [ "$(id -u)" = 0 ]; then
	echo "FAILED: this suite must not run as root, because root reads a mode-000 file and the unreadable cases would prove nothing." >&2
	exit 1
fi
if [ "${REQUIRE_BUSYBOX:-0}" = "1" ] && ! command -v busybox >/dev/null 2>&1; then
	echo "FAILED: REQUIRE_BUSYBOX=1 but busybox is not installed." >&2
	exit 1
fi

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
SCRIPT="$OVERLAY/usr/lib/rasputin/store-rollback/rasputin-store-rollback.sh"
for f in "$SCRIPT" "$OVERLAY/usr/lib/rasputin/outcome/outcome.sh" "$OVERLAY/usr/lib/rasputin/store-swap/swap.sh"; do
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

if command -v sha256sum >/dev/null 2>&1; then
	sha() { sha256sum | cut -d' ' -f1; }
else
	sha() { shasum -a 256 | cut -d' ' -f1; }
fi

BUSYBOX_DIR=""
if command -v busybox >/dev/null 2>&1; then
	BUSYBOX_DIR="$TMP/busybox-applets"
	mkdir -p "$BUSYBOX_DIR"
	for applet in ls mv chmod chown cp rm cat mkdir dirname sync awk tar; do
		printf '#!/bin/sh\nexec busybox %s "$@"\n' "$applet" > "$BUSYBOX_DIR/$applet"
		chmod 0755 "$BUSYBOX_DIR/$applet"
	done
	TEST_SHELLS="$TEST_SHELLS busybox_sh busybox_applets"
fi

# --- TEST HARNESS: the shims -------------------------------------------------
# Each runs the real tool afterwards: busybox's in the busybox_applets row
# (SHIM_BB=1), the host's otherwise, its path fixed here.
SHIMS="$TMP/shims"
mkdir -p "$SHIMS/mv" "$SHIMS/rm" "$SHIMS/chown" "$SHIMS/tar"
REAL_MV=$(command -v mv) REAL_RM=$(command -v rm) REAL_CHOWN=$(command -v chown) REAL_TAR=$(command -v tar)
# mv: SHIM_MV_RULES names a file of rules "SRC_GLOB DEST N": the Nth call
# whose source matches SRC_GLOB and whose destination is DEST fails. The
# script always calls mv -f SRC DEST.
cat > "$SHIMS/mv/mv" <<EOF
#!/bin/sh
src=\$2 dest=\$3
if [ -n "\${SHIM_MV_RULES:-}" ]; then
	i=0
	while read -r glob want n; do
		i=\$((i + 1))
		[ "\$dest" = "\$want" ] || continue
		# shellcheck disable=SC2254 # the rule's glob, on purpose
		case "\$src" in \$glob) ;; *) continue ;; esac
		c=\$(cat "\$SHIM_MV_RULES.\$i" 2>/dev/null || echo 0)
		c=\$((c + 1))
		echo "\$c" > "\$SHIM_MV_RULES.\$i"
		if [ "\$c" = "\$n" ]; then echo "mv: injected failure (TEST HARNESS)" >&2; echo "\$0 \$*" >> "\${SHIM_FIRED_LOG:-/dev/null}"; exit 1; fi
	done < "\$SHIM_MV_RULES"
fi
[ "\${SHIM_BB:-0}" = 1 ] && exec busybox mv "\$@"
exec "$REAL_MV" "\$@"
EOF
# rm: fails on any argument matching SHIM_RM_GLOB.
cat > "$SHIMS/rm/rm" <<EOF
#!/bin/sh
for a in "\$@"; do
	# shellcheck disable=SC2254 # the glob, on purpose
	case "\$a" in \${SHIM_RM_GLOB:-/nonexistent}) echo "rm: injected failure (TEST HARNESS)" >&2; echo "\$0 \$*" >> "\${SHIM_FIRED_LOG:-/dev/null}"; exit 1 ;; esac
done
[ "\${SHIM_BB:-0}" = 1 ] && exec busybox rm "\$@"
exec "$REAL_RM" "\$@"
EOF
# chown: appends its arguments, one call per line, to SHIM_CHOWN_LOG.
cat > "$SHIMS/chown/chown" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "\$SHIM_CHOWN_LOG"
[ "\${SHIM_BB:-0}" = 1 ] && exec busybox chown "\$@"
exec "$REAL_CHOWN" "\$@"
EOF
# tar: SHIM_TAR_FAIL=create fails `tar -cf FILE ...` after writing part of
# FILE; =extract fails `tar -xf ARCHIVE -C DIR` after writing part of DIR.
# Listing (-tf) and reading a member (-xOf) are never failed.
cat > "$SHIMS/tar/tar" <<EOF
#!/bin/sh
case "\${SHIM_TAR_FAIL:-}:\$1" in
	create:-cf) printf 'partial' > "\$2"; echo "tar: injected failure (TEST HARNESS)" >&2; echo "\$0 \$*" >> "\${SHIM_FIRED_LOG:-/dev/null}"; exit 1 ;;
	extract:-xf) mkdir -p "\$4/store"; printf 'partial' > "\$4/store/partial"; echo "tar: injected failure (TEST HARNESS)" >&2; echo "\$0 \$*" >> "\${SHIM_FIRED_LOG:-/dev/null}"; exit 1 ;;
esac
[ "\${SHIM_BB:-0}" = 1 ] && exec busybox tar "\$@"
exec "$REAL_TAR" "\$@"
EOF
chmod 0755 "$SHIMS/mv/mv" "$SHIMS/rm/rm" "$SHIMS/chown/chown" "$SHIMS/tar/tar"

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
TAG=rasputin-store-rollback
# out_has PREFIX — some line of stdout starts with PREFIX, taken literally.
out_has() { printf '%s\n' "$OUT" | cut -c1-${#1} | grep -qxF -- "$1"; }
contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# tree DIR — one line per path under DIR: its type, and a regular file's
# sha256. Comparing two of these compares names, types and bytes.
tree() {
	[ -e "$1" ] || { echo absent; return; }
	(cd "$1" && find . -print | sort | while IFS= read -r f; do
		if [ -L "$f" ]; then printf 'l %s\n' "$f"
		elif [ -f "$f" ]; then printf 'f %s %s\n' "$f" "$(sha < "$f")"
		else printf 'd %s\n' "$f"; fi
	done)
}
fsum() { if [ -e "$1" ]; then sha < "$1"; else echo absent; fi; }

BIN=2.7.1
NEWER=2.8.0
BOOT=0f3c5b2a-1d4e-4f6a-9b8c-7d6e5f4a3b2c
# A sentinel in every data file, live and copied (TC-801-23).
SENTINEL="SENTINEL-store-contents-7f3a9c"

# mk_bao MODE [VERSION] — the stub store binary. ok prints the real line's
# shape; fail exits 1; garbage prints a line of another shape.
mk_bao() {
	case "$1" in
		ok) printf '#!/bin/sh\nprintf "OpenBao v%s (a5db72c0f1e2d3c4b5a6), committed 2026-10-01T15:32:54Z\\n"\n' "${2:-$BIN}" ;;
		fail) printf '#!/bin/sh\necho "bao: cannot run" >&2\nexit 1\n' ;;
		garbage) printf '#!/bin/sh\necho "Vault v1.2.3 (deadbeef)"\n' ;;
	esac > "$W/bao"
	chmod 0755 "$W/bao"
}

# mk_copy VERSION [nover] — #800's copy at $P/openbao-preupdate.tar: data
# members store/data/<rel> in sorted order, then store/openbao-version with no
# trailing newline; regular files only. nover leaves the version member out.
mk_copy() {
	_st="$W/copy-stage"
	rm -rf "$_st"
	mkdir -p "$_st/store/data/sub"
	printf 'COPY-two %s' "$SENTINEL" > "$_st/store/data/000002.log"
	printf 'COPY-dot %s' "$SENTINEL" > "$_st/store/data/.cdot"
	printf 'COPY-nested %s' "$SENTINEL" > "$_st/store/data/sub/g"
	_members=$(cd "$_st" && find store/data -type f | sort)
	if [ "${2:-}" != nover ]; then
		printf '%s' "$1" > "$_st/store/openbao-version"
		_members="$_members
store/openbao-version"
	fi
	# shellcheck disable=SC2086 # the member list, split on purpose (no spaces)
	(cd "$_st" && "$REAL_TAR" -cf "$P/openbao-preupdate.tar" $_members)
	COPY_DATA=$(tree "$_st/store/data")
}

# setup — a fresh scratch tree: the persistent directory with live data B (a
# file, a second file, a dotfile and a nested directory), the binary at BIN,
# and an empty run directory.
setup() {
	W=$(mktemp -d "$TMP/w.XXXXXX")
	P="$W/persist"
	D="$P/openbao"
	R="$W/run"
	mkdir -p "$D/bsub" "$R"
	printf 'LIVE-one %s' "$SENTINEL" > "$D/000001.log"
	printf 'LIVE-two %s' "$SENTINEL" > "$D/MANIFEST-000001"
	printf 'LIVE-dot %s' "$SENTINEL" > "$D/.b-only"
	printf 'LIVE-nested %s' "$SENTINEL" > "$D/bsub/f"
	printf '%s\n' "$BOOT" > "$W/boot_id"
	chmod -R go-rwx "$W"
	: > "$W/kmsg"
	mk_bao ok
	MV_RULES="" SHIM_PATH="" TAR_FAIL="" RM_GLOB=""
	LIVE=$(tree "$D")
}
marker() { printf '%s\n' "$1" > "$P/openbao-version"; chmod 0600 "$P/openbao-version"; }
work_left() { find "$W" -name '.rasputin-rollback-*' -print 2>/dev/null; }

# run — the script under $SH; stdout, stderr and status apart. Every output is
# kept for the sentinel scan (TC-801-23).
run() {
	set -- "$SCRIPT"
	case "$SH" in
		busybox_sh|busybox_applets)
			_cmd="busybox sh"
			if [ -n "$SHIM_PATH" ]; then
				_fn=$(basename "$SHIM_PATH")
				set -- -c "$_fn() { \"$SHIM_PATH/$_fn\" \"\$@\"; }; . \"\$0\"" "$SCRIPT"
			fi
			;;
		*) _cmd=$SH ;;
	esac
	_bb=0
	_path=$PATH
	[ "$SH" = busybox_applets ] && { _path="$BUSYBOX_DIR:$PATH"; _bb=1; }
	[ -n "$SHIM_PATH" ] && _path="$SHIM_PATH:$_path"
	: > "$W/kmsg"
	: > "$W/fired"
	# shellcheck disable=SC2086 # _cmd is "busybox sh" on purpose
	env PATH="$_path" SHIM_BB="$_bb" SHIM_MV_RULES="$MV_RULES" SHIM_TAR_FAIL="$TAR_FAIL" \
		SHIM_RM_GLOB="$RM_GLOB" SHIM_CHOWN_LOG="$W/chown.log" SHIM_FIRED_LOG="$W/fired" \
		RASPUTIN_STOREROLLBACK_PERSIST="$P" RASPUTIN_STOREROLLBACK_RUN="$R" \
		RASPUTIN_STOREROLLBACK_BAO="$W/bao" RASPUTIN_STOREROLLBACK_BOOTID="$W/boot_id" \
		RASPUTIN_STOREROLLBACK_KMSG="$W/kmsg" \
		$_cmd "$@" > "$W/stdout" 2> "$W/stderr"
	RC=$?
	OUT=$(cat "$W/stdout")
	cat "$W/stdout" "$W/stderr" "$W/kmsg" >> "$ALLOUT"
}

# outcome_is LABEL OUTCOME PRIORITY RC — the exit status, one stdout line of
# that outcome and priority, the console holding it, and a record of exactly
# three lines at 0600.
outcome_is() {
	ok "$1: exits $4" "$(yes_if test "$RC" = "$4")" "rc=$RC $OUT $(cat "$W/stderr")"
	_oi_last=$(printf '%s\n' "$OUT" | tail -n 1)
	_oi_head="<$3>$TAG: outcome=$2 reason=\""
	ok "$1: stdout's last line is <$3>$TAG: outcome=$2 reason=\"...\"" \
		"$(yes_if eval 'contains "$_oi_head" "$_oi_last" && [ "${_oi_last#"$_oi_head"}" != "$_oi_last" ] && [ "${_oi_last%.\"}" != "$_oi_last" ]')" "$OUT"
	ok "$1: the console has stdout's last line, identical" \
		"$(yes_if test -n "$OUT" -a "$(cat "$W/kmsg")" = "$(printf '%s\n' "$OUT" | tail -n 1)")" \
		"kmsg: $(cat "$W/kmsg") | stdout: $OUT"
	record_is "$1" "$2"
}
# record_is LABEL OUTCOME — the record is outcome=, boot_id= and reason=,
# exactly, at 0600.
record_is() {
	_r="$R/outcome"
	_ri_want="outcome=$2"
	ok "$1: the record is three lines: outcome=$2, boot_id=$BOOT, reason=..." \
		"$(yes_if eval '[ "$(wc -l < "$_r" | tr -d " ")" = 3 ] && [ "$(sed -n 1p "$_r")" = "$_ri_want" ] && [ "$(sed -n 2p "$_r")" = "boot_id=$BOOT" ] && sed -n 3p "$_r" | grep -q "^reason=[A-Z].*[.]\$"')" \
		"$(cat "$_r" 2>&1 | tr '\n' '|')"
	ok "$1: the record is mode 0600" "$(yes_if test "$(ls -l "$_r" 2>/dev/null | cut -c1-10)" = "-rw-------")" "$(ls -l "$_r" 2>&1)"
}
one_line() { ok "$1: stdout is one line" "$(yes_if test "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 -a -n "$OUT")" "$OUT"; }
marker_is() { ok "$1: the marker holds $2" "$(yes_if test "$(cat "$P/openbao-version" 2>/dev/null)" = "$2")" "marker: $(cat "$P/openbao-version" 2>&1)"; }
data_is_live() { ok "$1: the data is unchanged, byte for byte" "$(yes_if test "$(tree "$D")" = "$LIVE")" "$(tree "$D" | tr '\n' '|')"; }
no_work() { ok "$1: no .rasputin-rollback-* is left" "$(yes_if test -z "$(work_left)")" "$(work_left)"; }
# held LABEL — nothing changed: data, marker, aside copy and copy as before,
# no work directory.
snapshot() { SNAP="$(tree "$D")|$(fsum "$P/openbao-version")|$(fsum "$P/openbao-version-hold")|$(fsum "$P/openbao-rolled-back.tar")|$(fsum "$P/openbao-preupdate.tar")"; }
held() {
	_now="$(tree "$D")|$(fsum "$P/openbao-version")|$(fsum "$P/openbao-version-hold")|$(fsum "$P/openbao-rolled-back.tar")|$(fsum "$P/openbao-preupdate.tar")"
	ok "$1: the data, marker, hold, aside copy and copy are unchanged" "$(yes_if test "$_now" = "$SNAP")"
	no_work "$1"
	ok "$1: no .partial is left" "$(yes_if test ! -e "$P/openbao-rolled-back.tar.partial")"
}
REFLASH_V="Reflash this control plane with a release whose secrets store is version $NEWER or later, then restore the latest backup."

cases() {
	ALLOUT="$TMP/all.$SH"
	: > "$ALLOUT"

	# TC-801-01: first init writes the marker.
	setup; rm -rf "$D"/* "$D"/.[!.]*
	run
	l="TC-801-01 an empty data directory"
	outcome_is "$l" current 6 0
	one_line "$l"
	marker_is "$l" "$BIN"
	ok "$l: the marker is one line, mode 0600" \
		"$(yes_if test "$(wc -l < "$P/openbao-version" | tr -d ' ')" = 1 -a "$(ls -l "$P/openbao-version" | cut -c1-10)" = "-rw-------")" "$(ls -l "$P/openbao-version" 2>&1)"
	ok "$l: nothing on stderr" "$(yes_if test ! -s "$W/stderr")" "$(cat "$W/stderr")"

	# TC-801-02: data and no marker: adopted.
	setup; run
	l="TC-801-02 data and no marker"
	outcome_is "$l" current 6 0
	marker_is "$l" "$BIN"
	data_is_live "$l"

	# TC-801-03: equal versions change nothing, mtimes included.
	setup; marker "$BIN"
	find "$D" "$P/openbao-version" -exec touch -t 202001010000 {} +
	touch -t 202101010000 "$W/ref"
	before=$(fsum "$P/openbao-version")
	run
	l="TC-801-03 equal versions"
	outcome_is "$l" current 6 0
	data_is_live "$l"
	ok "$l: the marker's bytes are unchanged" "$(yes_if test "$(fsum "$P/openbao-version")" = "$before")"
	ok "$l: no data file and not the marker has a newer mtime" \
		"$(yes_if test -z "$(find "$D" "$P/openbao-version" -newer "$W/ref")")" "$(find "$D" "$P/openbao-version" -newer "$W/ref")"
	ok "$l: there is no aside copy" "$(yes_if test ! -e "$P/openbao-rolled-back.tar")"

	# TC-801-04: older data, each component lower in turn.
	for old in 1.9.9 2.6.9 2.7.0; do
		setup; marker "$old"; run
		l="TC-801-04 data at $old, older than $BIN"
		outcome_is "$l" current 6 0
		marker_is "$l" "$BIN"
		data_is_live "$l"
	done

	# TC-801-05 and TC-801-25: a rollback with a matching copy.
	setup; marker "$NEWER"; mk_copy "$BIN"
	COPY_SUM=$(fsum "$P/openbao-preupdate.tar")
	SHIM_PATH="$SHIMS/chown"; : > "$W/chown.log"
	want_owner=$(ls -ldn "$D" | awk '{ print $3 ":" $4 }')
	run; SHIM_PATH=""
	l="TC-801-05 newer data and a copy at $BIN"
	outcome_is "$l" restored 4 0
	one_line "$l"
	ok "$l: the data is exactly the copy's store/data, byte for byte" "$(yes_if test "$(tree "$D")" = "$COPY_DATA")" \
		"live: $(tree "$D" | tr '\n' '|') copy: $(printf '%s' "$COPY_DATA" | tr '\n' '|')"
	ok "$l: TC-801-25 the dotfile and the nested file came across" "$(yes_if test -f "$D/.cdot" -a -f "$D/sub/g")"
	mkdir "$W/aside-x"; "$REAL_TAR" -xf "$P/openbao-rolled-back.tar" -C "$W/aside-x" 2>/dev/null
	ok "$l: the aside copy holds the previous data, byte for byte" "$(yes_if test "$(tree "$W/aside-x")" = "$LIVE")" "$(tree "$W/aside-x" | tr '\n' '|')"
	ok "$l: the aside copy is mode 0600" "$(yes_if test "$(ls -l "$P/openbao-rolled-back.tar" | cut -c1-10)" = "-rw-------")"
	marker_is "$l" "$BIN"
	no_work "$l"
	ok "$l: the copy itself is unchanged" "$(yes_if test "$(fsum "$P/openbao-preupdate.tar")" = "$COPY_SUM")"
	ok "$l: exactly one chown, -R $want_owner of the unpacked copy" \
		"$(yes_if test "$(cat "$W/chown.log")" = "-R $want_owner $D/.rasputin-rollback-new")" "$(cat "$W/chown.log")"
	ok "$l: the reason says the copy was put back and where the newer data is" \
		"$(yes_if contains "so the copy taken before the update was put back. Secrets written since that update are gone from the store; the newer data is kept in $P/openbao-rolled-back.tar." "$OUT")" "$OUT"

	# TC-801-25: the fixture is #800's shape.
	l="TC-801-25 the copy fixture"
	tv=$("$REAL_TAR" -tvf "$P/openbao-preupdate.tar")
	ok "$l: tar -tvf lists no directory member" "$(yes_if test -z "$(printf '%s\n' "$tv" | grep '^d')")" "$tv"
	ok "$l: the members are store/data/<rel> sorted, then store/openbao-version" \
		"$(yes_if test "$("$REAL_TAR" -tf "$P/openbao-preupdate.tar" | tr '\n' ' ')" = "store/data/.cdot store/data/000002.log store/data/sub/g store/openbao-version ")" \
		"$("$REAL_TAR" -tf "$P/openbao-preupdate.tar" | tr '\n' ' ')"
	ok "$l: store/openbao-version has no trailing newline" \
		"$(yes_if test "$("$REAL_TAR" -xOf "$P/openbao-preupdate.tar" store/openbao-version | wc -c | tr -d ' ')" = "${#BIN}")"

	# TC-801-06: no copy.
	setup; marker "$NEWER"; printf 'previous aside' > "$P/openbao-rolled-back.tar"; snapshot; run
	l="TC-801-06 newer data and no copy"
	outcome_is "$l" refused 2 1
	one_line "$l"
	held "$l"
	ok "$l: the reason names both versions, the missing copy and the recovery (F-801-06)" \
		"$(yes_if eval 'contains "written by version $NEWER, newer than this image'"'"'s $BIN, and there is no usable copy for $BIN ($P/openbao-preupdate.tar does not exist)" "$OUT" && contains "$REFLASH_V" "$OUT"')" "$OUT"

	# TC-801-07: a copy of another version.
	setup; marker "$NEWER"; mk_copy 2.6.0; snapshot; run
	l="TC-801-07 a copy at 2.6.0"
	outcome_is "$l" refused 2 1
	held "$l"
	ok "$l: the reason names the copy's version and the recovery" \
		"$(yes_if eval 'contains "is for version 2.6.0)" "$OUT" && contains "$REFLASH_V" "$OUT"')" "$OUT"

	# TC-801-08: unusable copies.
	for how in nover corrupt unreadable badversion; do
		setup; marker "$NEWER"
		case "$how" in
			nover) mk_copy "$BIN" nover; why="has no store/openbao-version" ;;
			corrupt) printf 'this is not an archive %s\n' "$SENTINEL" > "$P/openbao-preupdate.tar"; why="is not a readable archive" ;;
			unreadable) mk_copy "$BIN"; why="cannot be read" ;;
			badversion) mk_copy "v$BIN"; why="could not be parsed" ;;
		esac
		snapshot
		[ "$how" = unreadable ] && chmod 000 "$P/openbao-preupdate.tar"
		run
		chmod 0600 "$P/openbao-preupdate.tar"
		l="TC-801-08 a copy that is $how"
		outcome_is "$l" refused 2 1
		held "$l"
		ok "$l: the reason names why ($why) and the recovery" \
			"$(yes_if eval 'contains "$why" "$OUT" && contains "$REFLASH_V" "$OUT"')" "$OUT"
	done

	# TC-801-09: the binary's version unreadable.
	for b in fail garbage; do
		for d in empty data; do
			setup; mk_bao "$b"
			if [ "$d" = empty ]; then rm -rf "$D"/* "$D"/.[!.]*; else marker 2.6.0; fi
			snapshot; run
			l="TC-801-09 a binary that is $b, with $d"
			outcome_is "$l" failed 3 1
			held "$l"
			[ "$d" = empty ] && ok "$l: no marker was written" "$(yes_if test ! -e "$P/openbao-version")"
		done
	done

	# TC-801-10: unparseable data versions.
	for m in v2.7.1 "" 2.7 2.7.1.4 1234567890.0.0 2.7.x "2.7.1
2.7.1" -2.7.1 ".2.7"; do
		setup; marker "$m"; snapshot; run
		l="TC-801-10 a marker of '$(printf '%s' "$m" | tr '\n' '|')'"
		outcome_is "$l" failed 3 1
		held "$l"
	done

	# TC-801-11: an unlistable data directory.
	setup; marker "$BIN"; chmod 000 "$D"; before=$(fsum "$P/openbao-version"); run; chmod 0700 "$D"
	l="TC-801-11 an unlistable data directory"
	outcome_is "$l" failed 3 1
	ok "$l: the marker is unchanged" "$(yes_if test "$(fsum "$P/openbao-version")" = "$before")"
	data_is_live "$l"

	# TC-801-12: an interrupted swap.
	setup; marker "$NEWER"; mk_copy "$BIN"
	mkdir "$D/.rasputin-rollback-old"; printf 'old' > "$D/.rasputin-rollback-old/x"
	mkdir "$D/.rasputin-rollback-new"; printf 'new' > "$D/.rasputin-rollback-new/y"
	before=$(tree "$D"); snapshot; run
	l="TC-801-12 a leftover -old with a newer marker"
	outcome_is "$l" failed 3 1
	ok "$l: the data directory's tree, -old and -new included, is unchanged" "$(yes_if test "$(tree "$D")" = "$before")"
	ok "$l: the marker, hold, aside copy and copy are unchanged" \
		"$(yes_if test "$(fsum "$P/openbao-version")|$(fsum "$P/openbao-version-hold")|$(fsum "$P/openbao-rolled-back.tar")|$(fsum "$P/openbao-preupdate.tar")" = "${SNAP#*|}")"
	ok "$l: the reason says the rollback was interrupted and how to recover (F-801-06)" \
		"$(yes_if contains "An earlier rollback of the secrets store's data was interrupted and left $D/.rasputin-rollback-old, so nothing was changed and the store will not start. Reflash this control plane and restore the latest backup; the data from before the rollback is in $P/openbao-rolled-back.tar." "$OUT")" "$OUT"

	# TC-801-13: a leftover -new alone is removed.
	setup; marker "$BIN"; mkdir "$D/.rasputin-rollback-new"; printf 'stale' > "$D/.rasputin-rollback-new/s"; run
	l="TC-801-13 a leftover -new"
	outcome_is "$l" current 6 0
	no_work "$l"
	data_is_live "$l"
	# ... and one that cannot be removed fails the start.
	setup; marker "$BIN"; mkdir "$D/.rasputin-rollback-new"
	SHIM_PATH="$SHIMS/rm"; RM_GLOB="*.rasputin-rollback-new"; run; SHIM_PATH=""; RM_GLOB=""
	l="TC-801-13 a leftover -new that cannot be removed"
	ok "$l: the injected failure fired" "$(yes_if test -s "$W/fired")" "$(cat "$W/stderr")"
	outcome_is "$l" failed 3 1

	# TC-801-14: extraction fails.
	setup; marker "$NEWER"; mk_copy "$BIN"
	SHIM_PATH="$SHIMS/tar"; TAR_FAIL=extract; run; SHIM_PATH=""; TAR_FAIL=""
	l="TC-801-14 the extract fails"
	ok "$l: the injected failure fired" "$(yes_if test -s "$W/fired")" "$(cat "$W/stderr")"
	outcome_is "$l" failed 3 1
	data_is_live "$l"
	no_work "$l"
	marker_is "$l" "$NEWER"
	# ... and a copy with no store/data is refused the same way, rather than
	# swapping in an empty store.
	setup; marker "$NEWER"; printf '%s' "$BIN" > "$W/ver"; mkdir -p "$W/vs/store"; cp "$W/ver" "$W/vs/store/openbao-version"
	(cd "$W/vs" && "$REAL_TAR" -cf "$P/openbao-preupdate.tar" store/openbao-version); run
	l="TC-801-14 a copy with no store/data"
	outcome_is "$l" failed 3 1
	data_is_live "$l"
	no_work "$l"
	marker_is "$l" "$NEWER"

	# TC-801-15: the aside write fails.
	setup; marker "$NEWER"; mk_copy "$BIN"; printf 'previous aside' > "$P/openbao-rolled-back.tar"; snapshot
	SHIM_PATH="$SHIMS/tar"; TAR_FAIL=create; run; SHIM_PATH=""; TAR_FAIL=""
	l="TC-801-15 the aside write fails"
	ok "$l: the injected failure fired" "$(yes_if test -s "$W/fired")" "$(cat "$W/stderr")"
	outcome_is "$l" failed 3 1
	held "$l"
	ok "$l: the reason says the data was not rolled back" \
		"$(yes_if contains "Writing the newer secrets store data aside to $P/openbao-rolled-back.tar failed" "$OUT")" "$OUT"

	# TC-801-16: a swap rename fails, at phase A and at phase B; then with the
	# rollback failing too.
	for point in A B AB; do
		setup; marker "$NEWER"; mk_copy "$BIN"
		SHIM_PATH="$SHIMS/mv"; MV_RULES="$W/mv.rules"
		case "$point" in
			A) printf '%s %s 2\n' "$D/*" "$D/.rasputin-rollback-old/" ;;
			B) printf '%s %s 2\n' "$D/.rasputin-rollback-new/store/data/*" "$D/" ;;
			AB) printf '%s %s 2\n%s %s 1\n' "$D/.rasputin-rollback-new/store/data/*" "$D/" "$D/*" "$D/.rasputin-rollback-new/store/data/" ;;
		esac > "$MV_RULES"
		run; SHIM_PATH=""; MV_RULES=""
		l="TC-801-16 a rename fails in phase $point"
		ok "$l: the injected failure fired" "$(yes_if test -s "$W/fired")" "$(cat "$W/stderr")"
		marker_is "$l" "$NEWER"
		if [ "$point" = AB ]; then
			outcome_is "$l" failed 2 1
			ok "$l: the <2> reason names both work directories and the recovery" \
				"$(yes_if contains "so the work directories $D/.rasputin-rollback-new and $D/.rasputin-rollback-old are left and the store will not start. Reflash this control plane and restore the latest backup" "$OUT")" "$OUT"
			ok "$l: -old is left" "$(yes_if test -d "$D/.rasputin-rollback-old")"
			# The next start refuses it as interrupted.
			run
			ok "$l, then a run with the real mv: failed as interrupted" \
				"$(yes_if eval '[ "$RC" = 1 ] && out_has "<3>$TAG: outcome=failed reason=\"An earlier rollback of the secrets store'"'"'s data was interrupted"')" "$OUT"
		else
			outcome_is "$l" failed 3 1
			data_is_live "$l"
			no_work "$l"
			ok "$l: the <3> reason says the newer data was put back" \
				"$(yes_if contains "the newer data was put back and nothing else was changed." "$OUT")" "$OUT"
		fi
		rm -f "$W"/mv.rules*
	done

	# TC-801-17: the marker commit fails.
	setup; marker "$NEWER"; mk_copy "$BIN"
	SHIM_PATH="$SHIMS/mv"; MV_RULES="$W/mv.rules"
	printf '%s %s 1\n' "$P/.openbao-version.new" "$P/openbao-version" > "$MV_RULES"
	run; SHIM_PATH=""; MV_RULES=""
	l="TC-801-17 the marker commit fails"
	ok "$l: the injected failure fired" "$(yes_if test -s "$W/fired")" "$(cat "$W/stderr")"
	outcome_is "$l" failed 3 1
	data_is_live "$l"
	marker_is "$l" "$NEWER"
	no_work "$l"
	ok "$l: no marker temp file is left" "$(yes_if test ! -e "$P/.openbao-version.new")"

	# TC-801-18: a staged backup's version is used.
	for v in 2.9.0:refused:2:1 "$BIN":current:6:0 2.6.0:current:6:0; do
		sv=${v%%:*} rest=${v#*:}; want=${rest%%:*} rest=${rest#*:}; pri=${rest%%:*} rc=${rest#*:}
		setup; marker "$BIN"; mkdir -p "$P/restore-pending/store"
		: > "$P/restore-pending/store/applied"
		printf '%s' "$sv" > "$P/restore-pending/store/openbao-version"
		[ "$want" = current ] && printf '9.9.9\n' > "$P/openbao-version-hold"
		run
		l="TC-801-18 a staged backup at $sv"
		outcome_is "$l" "$want" "$pri" "$rc"
		data_is_live "$l"
		if [ "$want" = refused ]; then
			marker_is "$l" "$sv"
			ok "$l: the hold holds $sv, mode 0600" \
				"$(yes_if test "$(cat "$P/openbao-version-hold" 2>/dev/null)" = "$sv" -a "$(ls -l "$P/openbao-version-hold" | cut -c1-10)" = "-rw-------")"
			ok "$l: the staged reason names the versions and the recovery (F-801-06)" \
				"$(yes_if contains "The restored backup's secrets store data was written by version $sv, newer than this image's $BIN, so the store was not started and the restored data was left untouched. Reflash with a release whose secrets store is version $sv or later and restore this backup again, or restore a backup taken on this release." "$OUT")" "$OUT"
			# TC-801-19: the refusal persists once restore-pending/ is gone.
			rm -rf "$P/restore-pending"
			run
			l="TC-801-19 the staged refusal, after restore-pending/ is removed"
			outcome_is "$l" refused 2 1
			data_is_live "$l"
			ok "$l: it is the staged reason again" "$(yes_if contains "The restored backup's secrets store data was written by version $sv" "$OUT")" "$OUT"
		else
			marker_is "$l" "$BIN"
			ok "$l: the hold is removed" "$(yes_if test ! -e "$P/openbao-version-hold")"
		fi
	done
	# ... and an unparseable staged version is failed.
	setup; marker "$BIN"; mkdir -p "$P/restore-pending/store"; : > "$P/restore-pending/store/applied"
	printf 'v2.7.1\n' > "$P/restore-pending/store/openbao-version"; snapshot; run
	l="TC-801-18 a staged version of v2.7.1"
	outcome_is "$l" failed 3 1
	held "$l"

	# TC-801-20: the copy never replaces a backup's data.
	setup; marker "$BIN"; mk_copy "$BIN"; mkdir -p "$P/restore-pending/store"
	: > "$P/restore-pending/store/applied"; printf '2.9.0' > "$P/restore-pending/store/openbao-version"
	for n in 1 2; do
		run
		l="TC-801-20 a staged 2.9.0 backup and a copy at $BIN, run $n"
		ok "$l: exits 1" "$(yes_if test "$RC" = 1)" "rc=$RC $OUT"
		data_is_live "$l"
		ok "$l: no aside copy was written" "$(yes_if test ! -e "$P/openbao-rolled-back.tar")"
		no_work "$l"
		rm -rf "$P/restore-pending"
	done

	# TC-801-21: a committed restore's leftover -old is cleaned up.
	setup; marker "$BIN"; mkdir "$D/.rasputin-rollback-old" "$D/.rasputin-rollback-new"; printf 'x' > "$D/.rasputin-rollback-old/x"
	run
	l="TC-801-21 a leftover -old with the marker at $BIN"
	outcome_is "$l" current 6 0
	no_work "$l"
	data_is_live "$l"
	# ... and one that cannot be removed fails the start.
	setup; marker "$BIN"; mkdir "$D/.rasputin-rollback-old"
	SHIM_PATH="$SHIMS/rm"; RM_GLOB="*.rasputin-rollback-old"; run; SHIM_PATH=""; RM_GLOB=""
	l="TC-801-21 a committed leftover that cannot be removed"
	outcome_is "$l" failed 3 1
	# ... and a cleanup failing right after a commit is a <4> line, exit 0,
	# with the next start cleaning up.
	setup; marker "$NEWER"; mk_copy "$BIN"
	SHIM_PATH="$SHIMS/rm"; RM_GLOB="*.rasputin-rollback-old"; run; SHIM_PATH=""; RM_GLOB=""
	l="TC-801-21 cleanup fails after the commit"
	outcome_is "$l" restored 4 0
	ok "$l: a <4> line names the work directories left" \
		"$(yes_if out_has "<4>$TAG: The work directories $D/.rasputin-rollback-new and $D/.rasputin-rollback-old are left from a completed rollback")" "$OUT"
	marker_is "$l" "$BIN"
	run
	ok "$l, then a run with the real rm: current, exit 0" "$(yes_if eval '[ "$RC" = 0 ] && out_has "<6>$TAG: outcome=current "')" "$OUT"
	no_work "$l, then a run with the real rm"
	ok "$l, then a run with the real rm: the data is the copy's" "$(yes_if test "$(tree "$D")" = "$COPY_DATA")"

	# TC-801-22: one record per boot.
	setup; marker "$BIN"
	printf 'outcome=restored\nboot_id=%s\nreason=Earlier.\n' "$BOOT" > "$R/outcome"; chmod 0600 "$R/outcome"
	before=$(fsum "$R/outcome"); run
	l="TC-801-22 a restored record, then equal versions"
	ok "$l: exits 0 with a current line" "$(yes_if eval '[ "$RC" = 0 ] && out_has "<6>$TAG: outcome=current "')" "$OUT"
	ok "$l: the record is byte-identical" "$(yes_if test "$(fsum "$R/outcome")" = "$before")"
	marker "$NEWER"; run
	record_is "TC-801-22 a restored record, then a refusal" refused
	mk_bao fail; run
	record_is "TC-801-22 a refused record, then a failure" failed
	setup; rm -rf "$R"; run
	l="TC-801-22 no run directory"
	outcome_is "$l" current 6 0

	# TC-801-23: no data byte in any output above.
	l="TC-801-23 LOG-SECRETS"
	ok "$l: the sentinel is in no stdout, stderr or console output" \
		"$(yes_if test -s "$ALLOUT" -a "$(grep -cF -- "$SENTINEL" "$ALLOUT")" = 0)" "$(grep -F -- "$SENTINEL" "$ALLOUT" | head -3)"
	printf 'x%sx\n' "$SENTINEL" > "$TMP/control"
	ok "$l: positive control: the same search finds the sentinel in a file that holds it" \
		"$(yes_if test "$(grep -cF -- "$SENTINEL" "$TMP/control")" = 1)"
}

echo "store-rollback tests, shells:$TEST_SHELLS"
for SH in $TEST_SHELLS; do
	cases
done

# --- static -------------------------------------------------------------------
SH=static
ok "the script is executable in the overlay" "$(yes_if test -x "$SCRIPT")"
ok "no uid literal in the script; the owner is read" \
	"$(yes_if test -z "$(grep -nE '(^|[^0-9])990([^0-9]|$)|[0-9]+:[0-9]+' "$SCRIPT")")" "$(grep -nE '990|[0-9]+:[0-9]+' "$SCRIPT")"
for d in 'PERSIST="${RASPUTIN_STOREROLLBACK_PERSIST:-/var/lib/rasputin}"' \
	'RUN="${RASPUTIN_STOREROLLBACK_RUN:-/run/rasputin-store-rollback}"' \
	'BAO="${RASPUTIN_STOREROLLBACK_BAO:-/usr/bin/bao}"' \
	'BOOTID_SRC="${RASPUTIN_STOREROLLBACK_BOOTID:-/proc/sys/kernel/random/boot_id}"' \
	'OUTCOME_KMSG="${RASPUTIN_STOREROLLBACK_KMSG:-/dev/kmsg}"' \
	'COPY="$PERSIST/openbao-preupdate.tar"' 'MARKER="$PERSIST/openbao-version"' 'HOLD="$PERSIST/openbao-version-hold"' \
	'ASIDE="$PERSIST/openbao-rolled-back.tar"'; do
	ok "the script's production default: $d" "$(yes_if grep -qxF -- "$d" "$SCRIPT")"
done
# SC-UI 1: no reason names the vendor.
ok "no reason sentence names the vendor" \
	"$(yes_if test -z "$(grep -nE '(failed|finish [a-z]+ [0-9]|refuse_[a-z]+) .*OpenBao' "$SCRIPT")")" "$(grep -n 'OpenBao' "$SCRIPT")"

# --- the harness refuses root and a missing busybox (TC-801-24) ---------------
SH=harness
SH_BIN=$(command -v sh)
for row in root:0 nobusybox:1000; do
	name=${row%%:*} uid=${row#*:}
	stub="$TMP/stub-$name"
	mkdir -p "$stub"
	printf '#!%s\necho %s\n' "$SH_BIN" "$uid" > "$stub/id"
	chmod 0755 "$stub/id"
	out=$(PATH="$stub" REQUIRE_BUSYBOX=1 "$SH_BIN" "$0" 2>&1); rc=$?
	ok "TC-801-24 $name: the suite exits non-zero" "$(yes_if test "$rc" != 0)" "rc=$rc"
	ok "TC-801-24 $name: it says why in a sentence starting FAILED:" "$(yes_if eval 'printf "%s" "$out" | grep -q "^FAILED: .*\.$"')" "$out"
done
case "$TEST_SHELLS" in
	*busybox_applets*) ok "TC-801-24 the busybox applets row ran" 0 ;;
	*) [ "${REQUIRE_BUSYBOX:-0}" = 1 ] && ok "TC-801-24 the busybox applets row ran" 1 ;;
esac

echo "store-rollback tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
