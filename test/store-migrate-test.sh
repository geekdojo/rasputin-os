#!/bin/sh
#
# Tests for rasputin-store-migrate.sh, the root step of a secrets store's
# roll-forward that openbao.service runs third in each start
# (geekdojo/geekdojo-brain#1132, TC-1132-01 to TC-1132-10).
#
# Why. A wrong decision here deletes a store's only copy of its old tree, or
# starts the store on a half-moved one. So every decision runs against a
# scratch tree, and each run's exit status, the data directory's names, types
# and bytes, the state files, the work directories, the record and the line
# on stdout and on the console sink are checked. The interrupted states a
# kill can leave are built by hand, one per kill point, and the next run must
# converge on the old tree each time (TC-1132-05).
#
# How. The real script runs with every collaborator pointed at a scratch tree
# through RASPUTIN_STOREMIGRATE_*. Failures are injected by shims first on
# PATH, and under busybox sh through a function calling the shim (TEST
# HARNESS, as in test/store-rollback-test.sh): an mv that fails a chosen
# rename, a tar that fails its create or its extract, a sync that fails its
# Nth call, an rm that fails on chosen paths, and a chown that records its
# arguments. Each shim then runs the real tool. No root, no systemd: what
# systemd does with the step is test/store-unit-functional.sh scenario 14.
#
# Shells. Every case runs under each shell in TEST_SHELLS (default: whichever
# of sh, dash and bash are installed), under `busybox sh`, and under
# `busybox sh` with busybox's own applets ahead of PATH, tar included.
# REQUIRE_BUSYBOX=1 (CI sets it) makes a missing busybox a failure.
#
# Run:  sh test/store-migrate-test.sh
set -u
LC_ALL=C
export LC_ALL
# No AppleDouble members when the host tar is macOS's bsdtar.
COPYFILE_DISABLE=1
export COPYFILE_DISABLE

if [ "${REQUIRE_BUSYBOX:-0}" = "1" ] && ! command -v busybox >/dev/null 2>&1; then
	echo "FAILED: REQUIRE_BUSYBOX=1 but busybox is not installed." >&2
	exit 1
fi

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
SCRIPT="$OVERLAY/usr/lib/rasputin/store-migrate/rasputin-store-migrate.sh"
SWAP="$OVERLAY/usr/lib/rasputin/store-swap/swap.sh"
for f in "$SCRIPT" "$OVERLAY/usr/lib/rasputin/outcome/outcome.sh" "$SWAP"; do
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
	for applet in ls mv chmod chown cp rm cat mkdir dirname sync awk tar sed; do
		printf '#!/bin/sh\nexec busybox %s "$@"\n' "$applet" > "$BUSYBOX_DIR/$applet"
		chmod 0755 "$BUSYBOX_DIR/$applet"
	done
	TEST_SHELLS="$TEST_SHELLS busybox_sh busybox_applets"
fi

# --- TEST HARNESS: the shims -------------------------------------------------
# Each runs the real tool afterwards: busybox's in the busybox_applets row
# (SHIM_BB=1), the host's otherwise, its path fixed here.
SHIMS="$TMP/shims"
mkdir -p "$SHIMS/mv" "$SHIMS/rm" "$SHIMS/chown" "$SHIMS/tar" "$SHIMS/sync"
REAL_MV=$(command -v mv) REAL_RM=$(command -v rm) REAL_CHOWN=$(command -v chown) REAL_TAR=$(command -v tar) REAL_SYNC=$(command -v sync)
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
cat > "$SHIMS/tar/tar" <<EOF
#!/bin/sh
case "\${SHIM_TAR_FAIL:-}:\$1" in
	create:-cf) printf 'partial' > "\$2"; echo "tar: injected failure (TEST HARNESS)" >&2; echo "\$0 \$*" >> "\${SHIM_FIRED_LOG:-/dev/null}"; exit 1 ;;
	extract:-xf) printf 'partial' > "\$4/partial"; echo "tar: injected failure (TEST HARNESS)" >&2; echo "\$0 \$*" >> "\${SHIM_FIRED_LOG:-/dev/null}"; exit 1 ;;
esac
[ "\${SHIM_BB:-0}" = 1 ] && exec busybox tar "\$@"
exec "$REAL_TAR" "\$@"
EOF
# sync: the SHIM_SYNC_FAIL'th call fails, counted in SHIM_SYNC_COUNT.
cat > "$SHIMS/sync/sync" <<EOF
#!/bin/sh
c=\$(cat "\$SHIM_SYNC_COUNT" 2>/dev/null || echo 0)
c=\$((c + 1))
echo "\$c" > "\$SHIM_SYNC_COUNT"
if [ "\$c" = "\${SHIM_SYNC_FAIL:-0}" ]; then echo "sync: injected failure (TEST HARNESS)" >&2; echo "\$0 \$*" >> "\${SHIM_FIRED_LOG:-/dev/null}"; exit 1; fi
[ "\${SHIM_BB:-0}" = 1 ] && exec busybox sync "\$@"
exec "$REAL_SYNC" "\$@"
EOF
chmod 0755 "$SHIMS/mv/mv" "$SHIMS/rm/rm" "$SHIMS/chown/chown" "$SHIMS/tar/tar" "$SHIMS/sync/sync"

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
TAG=rasputin-store-migrate
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

BOOT=0f3c5b2a-1d4e-4f6a-9b8c-7d6e5f4a3b2c
OTHER_BOOT=9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d
RUNID=feedfacefeedfacefeedfacefeedface
JOB=0b5f1e2a-migrate-job
# A sentinel in every data file; no output may carry it.
SENTINEL="SENTINEL-store-contents-1132"

# setup — a fresh scratch tree: the persistent directory with the old live
# data (two files, a dotfile and a nested directory), an empty 0700 state
# directory, no run directory, and this boot's id.
setup() {
	W=$(mktemp -d "$TMP/w.XXXXXX")
	P="$W/persist"
	D="$P/openbao"
	S="$P/store-migrate"
	R="$W/run"
	MNEW="$D/.rasputin-migrate-new"
	MOLD="$D/.rasputin-migrate-old"
	mkdir -p "$D/bsub" "$S"
	printf 'OLD-one %s' "$SENTINEL" > "$D/000001.log"
	printf 'OLD-two %s' "$SENTINEL" > "$D/MANIFEST-000001"
	printf 'OLD-dot %s' "$SENTINEL" > "$D/.b-only"
	printf 'OLD-nested %s' "$SENTINEL" > "$D/bsub/f"
	printf '%s\n' "$BOOT" > "$W/boot_id"
	chmod -R go-rwx "$W"
	: > "$W/kmsg"
	MV_RULES="" SHIM_PATH="" TAR_FAIL="" RM_GLOB="" SYNC_FAIL=0
	LIVE=$(tree "$D")
}
# mk_aside — aside.tar of the live data, as tar_aside writes it.
mk_aside() { (cd "$D" && "$REAL_TAR" -cf "$S/aside.tar" .); chmod 0600 "$S/aside.tar"; ASIDE_SUM=$(fsum "$S/aside.tar"); }
# to_newer — the data directory holds the store's newer tree instead.
to_newer() {
	"$REAL_RM" -rf "$D"/* "$D"/.[!.]*
	mkdir -p "$D/nsub"
	printf 'NEW-log %s' "$SENTINEL" > "$D/new.log"
	printf 'NEW-dot %s' "$SENTINEL" > "$D/.n-dot"
	printf 'NEW-nested %s' "$SENTINEL" > "$D/nsub/g"
}
request() { printf 'boot_id=%s\njob_id=%s\n' "$1" "$JOB" > "$S/request"; chmod 0600 "$S/request"; }
applied() { mkdir -p "$P/restore-pending/store"; : > "$P/restore-pending/store/applied"; }
mv_rule() { MV_RULES="$W/mv.rules"; printf '%s %s %s\n' "$1" "$2" "$3" > "$MV_RULES"; SHIM_PATH="$SHIMS/mv"; }
# move_first N FROM TO — the first N entries of FROM, sorted, into TO, by the
# real mv: a kill after the Nth rename.
move_first() {
	_mf=0
	for _e in "$2"/* "$2"/.[!.]*; do
		[ -e "$_e" ] || continue
		case "${_e##*/}" in .rasputin-migrate-*) continue ;; esac
		[ "$_mf" -lt "$1" ] || break
		"$REAL_MV" "$_e" "$3/"
		_mf=$((_mf + 1))
	done
}
work_left() { find "$W" -name '.rasputin-migrate-*' -print 2>/dev/null; }

# run — the script under $SH; stdout, stderr and status apart.
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
	"$REAL_RM" -f "$W/sync.count"
	# shellcheck disable=SC2086 # _cmd is "busybox sh" on purpose
	env PATH="$_path" SHIM_BB="$_bb" SHIM_MV_RULES="$MV_RULES" SHIM_TAR_FAIL="$TAR_FAIL" \
		SHIM_RM_GLOB="$RM_GLOB" SHIM_CHOWN_LOG="$W/chown.log" SHIM_FIRED_LOG="$W/fired" \
		SHIM_SYNC_FAIL="$SYNC_FAIL" SHIM_SYNC_COUNT="$W/sync.count" INVOCATION_ID="$RUNID" \
		RASPUTIN_STOREMIGRATE_PERSIST="$P" RASPUTIN_STOREMIGRATE_RUN="$R" \
		RASPUTIN_STOREMIGRATE_BOOTID="$W/boot_id" RASPUTIN_STOREMIGRATE_KMSG="$W/kmsg" \
		$_cmd "$@" > "$W/stdout" 2> "$W/stderr"
	RC=$?
	OUT=$(cat "$W/stdout")
	cat "$W/stdout" "$W/stderr" "$W/kmsg" "$R/outcome" >> "$ALLOUT" 2>/dev/null
}
fired() { ok "$1: the injected failure fired" "$(yes_if test -s "$W/fired")" "nothing fired"; }

# outcome_is LABEL OUTCOME PRIORITY RC — the exit status, stdout's last line
# of that outcome and priority, the console holding it, and a record of
# exactly four lines at 0600.
outcome_is() {
	ok "$1: exits $4" "$(yes_if test "$RC" = "$4")" "rc=$RC $OUT $(cat "$W/stderr")"
	_oi_last=$(printf '%s\n' "$OUT" | tail -n 1)
	_oi_head="<$3>$TAG: outcome=$2 reason=\""
	ok "$1: stdout's last line is <$3>$TAG: outcome=$2 reason=\"<sentence>\"" \
		"$(yes_if eval '[ "${_oi_last#"$_oi_head"[A-Z]}" != "$_oi_last" ] && [ "${_oi_last%.\"}" != "$_oi_last" ]')" "$OUT"
	ok "$1: the console has stdout's last line, identical" \
		"$(yes_if test -n "$OUT" -a "$(tail -n 1 "$W/kmsg")" = "$_oi_last")" "kmsg: $(cat "$W/kmsg") | stdout: $OUT"
	_r="$R/outcome"
	_oi_want="outcome=$2"
	ok "$1: the record is exactly outcome=$2, boot_id=$BOOT, run_id=$RUNID and a reason sentence" \
		"$(yes_if eval '[ "$(wc -l < "$_r" | tr -d " ")" = 4 ] && [ "$(sed -n 1p "$_r")" = "$_oi_want" ] && [ "$(sed -n 2p "$_r")" = "boot_id=$BOOT" ] && [ "$(sed -n 3p "$_r")" = "run_id=$RUNID" ] && sed -n 4p "$_r" | grep -q "^reason=[A-Z].*[.]\$"')" \
		"$(cat "$_r" 2>&1 | tr '\n' '|')"
	ok "$1: the record is mode 0600" "$(yes_if test "$(ls -l "$_r" 2>/dev/null | cut -c1-10)" = "-rw-------")" "$(ls -l "$_r" 2>&1)"
}
silent() {
	ok "$1: exits 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT"
	ok "$1: no line on stdout or the console" "$(yes_if test -z "$OUT" -a ! -s "$W/kmsg")" "$OUT"
	ok "$1: no record" "$(yes_if test ! -e "$R/outcome")" "$(cat "$R/outcome" 2>&1)"
}
data_is() { ok "$1: the data directory is $2, byte for byte" "$(yes_if test "$(tree "$D")" = "$3")" "$(tree "$D" | tr '\n' '|')"; }
absent() {
	_l=$1; shift
	for _a in "$@"; do
		ok "$_l: ${_a#"$P/"} is absent" "$(yes_if eval '! [ -e "$_a" ] && ! [ -L "$_a" ]')"
	done
}
no_work() { ok "$1: no .rasputin-migrate-* is left" "$(yes_if test -z "$(work_left)")" "$(work_left)"; }
state_gone() { absent "$1" "$S/request" "$S/attempt" "$S/aside.tar" "$S/aside.tar.partial" "$S/commit"; no_work "$1"; }

cases() {
	ALLOUT="$TMP/all.$SH"
	: > "$ALLOUT"

	# TC-1132-01: nothing to do.
	setup; run
	l="TC-1132-01 an empty state directory"
	silent "$l"
	data_is "$l" unchanged "$LIVE"
	setup; "$REAL_RM" -rf "$S"; run
	silent "TC-1132-01 no state directory at all"
	setup; : > "$S/aside.tar.partial"; run
	l="TC-1132-01 a stray aside.tar.partial alone"
	silent "$l"
	absent "$l" "$S/aside.tar.partial"

	# TC-1132-02: the move-aside.
	setup; request "$BOOT"; run
	l="TC-1132-02 a request naming this boot"
	outcome_is "$l" moved 6 0
	ok "$l: stdout is one line" "$(yes_if test "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1)" "$OUT"
	mkdir "$W/aside-x"; "$REAL_TAR" -xf "$S/aside.tar" -C "$W/aside-x"
	ok "$l: aside.tar holds the old data directory, every name, type and byte" \
		"$(yes_if test "$(tree "$W/aside-x")" = "$LIVE")" "$(tree "$W/aside-x" | tr '\n' '|')"
	ok "$l: aside.tar is mode 0600 and owned by the step's user" \
		"$(yes_if test "$(ls -ln "$S/aside.tar" | cut -c1-10) $(ls -ln "$S/aside.tar" | awk '{ print $3 }')" = "-rw------- $(id -u)")" "$(ls -ln "$S/aside.tar")"
	ok "$l: the data directory is empty" "$(yes_if test -z "$(ls -A "$D")")" "$(ls -A "$D")"
	absent "$l" "$S/request" "$S/aside.tar.partial"
	ok "$l: request became attempt, job id kept" "$(yes_if grep -qx "job_id=$JOB" "$S/attempt")" "$(cat "$S/attempt" 2>&1)"
	no_work "$l"
	ok "$l: the reason names aside.tar" "$(yes_if contains "$S/aside.tar" "$OUT")" "$OUT"

	# TC-1132-03: the move-aside fails at each step before the store starts.
	for inj in "tar create" "sync 1" "sync 2" "sync 3" "rename to aside.tar" \
		"entry rename 1" "entry rename 2" "entry rename 3" "entry rename 4" "request rename"; do
		setup; request "$BOOT"
		case "$inj" in
			"tar create") SHIM_PATH="$SHIMS/tar"; TAR_FAIL=create ;;
			"sync "*) SHIM_PATH="$SHIMS/sync"; SYNC_FAIL=${inj#sync } ;;
			"rename to aside.tar") mv_rule "$S/aside.tar.partial" "$S/aside.tar" 1 ;;
			"entry rename "*) mv_rule "$D/*" "$MOLD/" "${inj#entry rename }" ;;
			"request rename") mv_rule "$S/request" "$S/attempt" 1 ;;
		esac
		run
		l="TC-1132-03 a failure at the $inj"
		fired "$l"
		outcome_is "$l" failed 3 0
		data_is "$l" "the old data" "$LIVE"
		state_gone "$l"
	done

	# TC-1132-04: the put-back, over a newer tree.
	setup; request "$BOOT"; mk_aside; printf 'job_id=%s\n' "$JOB" > "$S/attempt"; to_newer
	mkdir -p "$MNEW/x" "$MOLD/y"
	SHIM_PATH="$SHIMS/chown"; : > "$W/chown.log"
	want_owner=$(ls -ldn "$D" | awk '{ print $3 ":" $4 }')
	run; SHIM_PATH=""
	l="TC-1132-04 aside.tar without a commit"
	outcome_is "$l" restored 4 0
	data_is "$l" "aside.tar's tree" "$LIVE"
	state_gone "$l"
	ok "$l: exactly one chown, -R $want_owner (the data directory's owner) of the unpacked tree" \
		"$(yes_if test "$(cat "$W/chown.log")" = "-R $want_owner $MNEW")" "$(cat "$W/chown.log")"
	ok "$l: every entry in the data directory has the data directory's owner" \
		"$(yes_if test -z "$(find "$D" ! -user "$(id -u)")")"

	# TC-1132-05: a kill at each point leaves a state the next run converges
	# from: the old tree in place, nothing else left, restored, exit 0.
	for kp in "move-aside: aside.tar written" "move-aside: 1 entry moved" "move-aside: 3 entries moved" \
		"move-aside: all entries moved" "move-aside: rm -rf part way" "move-aside: emptied, request kept" \
		"put-back: unpacked" "put-back: 2 live entries moved" "put-back: all live, 1 unpacked moved" \
		"put-back: all renames done" "put-back: request removed" "work directories and a partial left"; do
		setup; request "$BOOT"; mk_aside
		case "$kp" in
			"move-aside: aside.tar written") ;;
			"move-aside: "*" moved")
				mkdir "$MOLD"; n=${kp#move-aside: }; n=${n%% *}; [ "$n" = all ] && n=99
				move_first "$n" "$D" "$MOLD" ;;
			"move-aside: rm -rf part way")
				mkdir "$MOLD"; move_first 99 "$D" "$MOLD"; "$REAL_RM" -rf "$MOLD/bsub" "$MOLD/000001.log" ;;
			"move-aside: emptied, request kept") "$REAL_RM" -rf "$D"/* "$D"/.[!.]* ;;
			"put-back: unpacked")
				to_newer; mkdir "$MNEW"; "$REAL_TAR" -xf "$S/aside.tar" -C "$MNEW" ;;
			"put-back: 2 live entries moved")
				to_newer; mkdir "$MNEW" "$MOLD"; "$REAL_TAR" -xf "$S/aside.tar" -C "$MNEW"; move_first 2 "$D" "$MOLD" ;;
			"put-back: all live, 1 unpacked moved")
				to_newer; mkdir "$MNEW" "$MOLD"; "$REAL_TAR" -xf "$S/aside.tar" -C "$MNEW"; move_first 99 "$D" "$MOLD"; move_first 1 "$MNEW" "$D" ;;
			"put-back: all renames done")
				to_newer; mkdir "$MNEW" "$MOLD"; "$REAL_TAR" -xf "$S/aside.tar" -C "$MNEW"; move_first 99 "$D" "$MOLD"; move_first 99 "$MNEW" "$D" ;;
			"put-back: request removed")
				"$REAL_RM" -f "$S/request"; printf 'job_id=%s\n' "$JOB" > "$S/attempt" ;;
			"work directories and a partial left")
				to_newer; mkdir -p "$MNEW/a" "$MOLD/b"; printf 'part' > "$S/aside.tar.partial" ;;
		esac
		run
		l="TC-1132-05 after a kill at $kp"
		outcome_is "$l" restored 4 0
		data_is "$l" "the old tree" "$LIVE"
		state_gone "$l"
	done
	# A removal that fails part way through the move-aside: the put-back
	# cannot clear it either, so the store is held; the next start converges.
	setup; request "$BOOT"; RM_GLOB="$MOLD"; SHIM_PATH="$SHIMS/rm"; run; SHIM_PATH=""; RM_GLOB=""
	l="TC-1132-05 the old entries cannot be removed"
	fired "$l"
	outcome_is "$l" failed 2 1
	ok "$l: aside.tar and request are kept, and the reason names aside.tar" \
		"$(yes_if eval '[ -f "$S/aside.tar" ] && [ -f "$S/request" ] && contains "$S/aside.tar" "$OUT"')" "$OUT"
	run
	outcome_is "TC-1132-05 the next start after it" restored 4 0
	data_is "TC-1132-05 the next start after it" "the old tree" "$LIVE"
	state_gone "TC-1132-05 the next start after it"

	# TC-1132-06: a put-back whose rename fails is held, aside.tar unchanged.
	for inj in "live entry rename" "unpacked entry rename" "tar extract"; do
		setup; request "$BOOT"; mk_aside; to_newer
		case "$inj" in
			"live entry rename") mv_rule "$D/*" "$MOLD/" 1 ;;
			"unpacked entry rename") mv_rule "$MNEW/*" "$D/" 2 ;;
			"tar extract") SHIM_PATH="$SHIMS/tar"; TAR_FAIL=extract ;;
		esac
		run
		l="TC-1132-06 a put-back whose $inj fails"
		fired "$l"
		outcome_is "$l" failed 2 1
		ok "$l: the reason names aside.tar" "$(yes_if contains "$S/aside.tar" "$OUT")" "$OUT"
		ok "$l: aside.tar is present and unchanged" "$(yes_if test "$(fsum "$S/aside.tar")" = "$ASIDE_SUM")"
		MV_RULES="" SHIM_PATH="" TAR_FAIL=""
		run
		data_is "$l, then a clean start" "the old tree" "$LIVE"
		state_gone "$l, then a clean start"
	done

	# TC-1132-07: the commit.
	for with in "with request" "without request"; do
		setup; mk_aside; to_newer; NEWER=$(tree "$D")
		printf 'job_id=%s\n' "$JOB" > "$S/attempt"; : > "$S/commit"
		[ "$with" = "with request" ] && request "$BOOT"
		run
		l="TC-1132-07 aside.tar and commit, $with"
		outcome_is "$l" finished 6 0
		data_is "$l" unchanged "$NEWER"
		state_gone "$l"
	done

	# TC-1132-08: a restore applied first supersedes any migration state.
	for st in request "aside.tar without commit" "work directories" "aside.tar with commit"; do
		setup; to_newer; RESTORED=$(tree "$D"); applied
		case "$st" in
			request) request "$BOOT" ;;
			"aside.tar without commit") mk_aside; printf 'job_id=%s\n' "$JOB" > "$S/attempt" ;;
			"work directories") mkdir -p "$MNEW/a" "$MOLD/b" ;;
			"aside.tar with commit") mk_aside; : > "$S/commit" ;;
		esac
		run
		l="TC-1132-08 a restore applied, and $st"
		if [ "$st" = "aside.tar with commit" ]; then
			outcome_is "$l" finished 6 0
		else
			outcome_is "$l" superseded 4 0
		fi
		data_is "$l" "the restored data, unchanged" "$RESTORED"
		state_gone "$l"
	done
	setup; applied; run
	silent "TC-1132-08 a restore applied with no migration state"

	# TC-1132-09: a request from another boot.
	for how in "another boot" "another boot, with a partial" "no boot_id line"; do
		setup
		case "$how" in
			"no boot_id line") printf 'job_id=%s\n' "$JOB" > "$S/request" ;;
			*) request "$OTHER_BOOT" ;;
		esac
		contains partial "$how" && printf 'part' > "$S/aside.tar.partial"
		run
		l="TC-1132-09 a request with $how"
		outcome_is "$l" failed 3 0
		data_is "$l" unchanged "$LIVE"
		state_gone "$l"
	done

	# Decision 6: leftovers alone are removed with one <4> line, no record.
	setup; printf 'job_id=%s\n' "$JOB" > "$S/attempt"; mkdir -p "$MOLD/z"; run
	l="decision 6 an attempt and a work directory alone"
	ok "$l: exits 0 with one <4> line and no record" \
		"$(yes_if eval '[ "$RC" = 0 ] && [ "$(printf "%s\n" "$OUT" | wc -l | tr -d " ")" = 1 ] && contains "<4>$TAG: " "$OUT" && [ ! -e "$R/outcome" ]')" "rc=$RC $OUT"
	state_gone "$l"

	# TC-1132-10: move_entries leaves every step's work directories alone.
	setup; mkdir -p "$MNEW/keep" "$MOLD/keep" "$W/to"
	# shellcheck source=/dev/null
	(. "$SWAP"; move_entries data "$D" "$W/to")
	l="TC-1132-10 move_entries data"
	ok "$l: both migrate work directories stay where they are" "$(yes_if test -d "$MNEW/keep" -a -d "$MOLD/keep")"
	ok "$l: every other entry moved" \
		"$(yes_if test "$(ls -A "$D" | sort | tr '\n' ' ')" = ".rasputin-migrate-new .rasputin-migrate-old " -a "$(ls -A "$W/to" | sort | tr '\n' ' ')" = ".b-only 000001.log MANIFEST-000001 bsub ")" \
		"left: $(ls -A "$D" | tr '\n' ' ') moved: $(ls -A "$W/to" | tr '\n' ' ')"

	l="LOG-SECRETS"
	ok "$l: the sentinel is in no stdout, stderr, console line or record" \
		"$(yes_if test -s "$ALLOUT" -a "$(grep -cF -- "$SENTINEL" "$ALLOUT")" = 0)" "$(grep -F -- "$SENTINEL" "$ALLOUT" | head -3)"
}

echo "store-migrate tests, shells:$TEST_SHELLS"
for SH in $TEST_SHELLS; do
	cases
done

# --- static -------------------------------------------------------------------
SH=static
ok "the script is executable in the overlay" "$(yes_if test -x "$SCRIPT")"
ok "no uid literal in the script; the owner is read" \
	"$(yes_if test -z "$(grep -nE '(^|[^0-9])990([^0-9]|$)' "$SCRIPT")")" "$(grep -n '990' "$SCRIPT")"
for d in 'PERSIST="${RASPUTIN_STOREMIGRATE_PERSIST:-/var/lib/rasputin}"' \
	'RUN="${RASPUTIN_STOREMIGRATE_RUN:-/run/rasputin-store-migrate}"' \
	'BOOTID_SRC="${RASPUTIN_STOREMIGRATE_BOOTID:-/proc/sys/kernel/random/boot_id}"' \
	'OUTCOME_KMSG="${RASPUTIN_STOREMIGRATE_KMSG:-/dev/kmsg}"' \
	'STATE="$PERSIST/store-migrate"' 'DATA="$PERSIST/openbao"' 'ASIDE="$STATE/aside.tar"' \
	'MNEW="$DATA/.rasputin-migrate-new"' 'MOLD="$DATA/.rasputin-migrate-old"'; do
	ok "the script's production default: $d" "$(yes_if grep -qxF -- "$d" "$SCRIPT")"
done
case "$TEST_SHELLS" in
	*busybox_applets*) ok "the busybox applets row ran" 0 ;;
	*) [ "${REQUIRE_BUSYBOX:-0}" = 1 ] && ok "the busybox applets row ran" 1 ;;
esac

echo "store-migrate tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
