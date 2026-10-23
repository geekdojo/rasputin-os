#!/bin/sh
#
# Tests for rasputin-store-restore.sh, the step openbao.service runs first in
# each start to apply a staged secrets-store restore
# (geekdojo/geekdojo-brain#766, TC-766-01 to TC-766-13).
#
# Why. A wrong apply either starts the store on mixed data or leaves an
# operator with a store that holds neither the old secrets nor the restored
# ones. So every branch runs against a scratch tree, and each run's exit code,
# the live data and seal hashes, the marker, the work directories and the line
# on stdout and on the console sink are checked.
#
# How. The real script runs with every collaborator pointed at a scratch tree
# through RASPUTIN_STORERESTORE_*. Failures are injected by shims first on
# PATH, and under busybox sh through a function calling the shim (see run)
# (TEST HARNESS): an mv that fails a chosen rename, an rm that fails on the
# work directories once the marker is written, and a chown that records its
# arguments. Each shim then runs the real tool. No root, no systemd: what
# systemd does with the step is test/store-unit-functional.sh scenario 12.
#
# Shells. Every case runs under each shell in TEST_SHELLS (default: whichever
# of sh, dash and bash are installed), under `busybox sh`, and under
# `busybox sh` with busybox's own applets ahead of PATH, so the image's cp, mv,
# chown, ls, rm and sync are the ones exercised. REQUIRE_BUSYBOX=1 (CI sets
# it) makes a missing busybox a failure.
#
# Root. The suite refuses to run as root, with a failure and not a skip: root
# reads a mode-000 file, so the copy-failure case would pass over nothing.
#
# Run:  sh test/store-restore-test.sh
set -u
LC_ALL=C
export LC_ALL

if [ "$(id -u)" = 0 ]; then
	echo "FAILED: this suite must not run as root, because root reads a mode-000 file and the copy-failure case would prove nothing." >&2
	exit 1
fi
if [ "${REQUIRE_BUSYBOX:-0}" = "1" ] && ! command -v busybox >/dev/null 2>&1; then
	echo "FAILED: REQUIRE_BUSYBOX=1 but busybox is not installed." >&2
	exit 1
fi

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
SCRIPT="$OVERLAY/usr/lib/rasputin/store-restore/rasputin-store-restore.sh"
LIB="$OVERLAY/usr/lib/rasputin/outcome/outcome.sh"
for f in "$SCRIPT" "$LIB"; do
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
	for applet in ls mv chmod chown cp rm cat mkdir dirname sync awk; do
		printf '#!/bin/sh\nexec busybox %s "$@"\n' "$applet" > "$BUSYBOX_DIR/$applet"
		chmod 0755 "$BUSYBOX_DIR/$applet"
	done
	TEST_SHELLS="$TEST_SHELLS busybox_sh busybox_applets"
fi

# --- TEST HARNESS: the shims -------------------------------------------------
# Each runs the real tool afterwards: busybox's in the busybox_applets row
# (SHIM_BB=1), the host's otherwise, its path fixed here.
SHIMS="$TMP/shims"
mkdir -p "$SHIMS/mv" "$SHIMS/rm" "$SHIMS/chown"
REAL_MV=$(command -v mv) REAL_RM=$(command -v rm) REAL_CHOWN=$(command -v chown)
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
		if [ "\$c" = "\$n" ]; then echo "mv: injected failure (TEST HARNESS)" >&2; exit 1; fi
	done < "\$SHIM_MV_RULES"
fi
[ "\${SHIM_BB:-0}" = 1 ] && exec busybox mv "\$@"
exec "$REAL_MV" "\$@"
EOF
# rm: fails on any work directory once the file SHIM_RM_MARK exists.
cat > "$SHIMS/rm/rm" <<EOF
#!/bin/sh
for a in "\$@"; do
	case "\$a" in *.rasputin-restore-*)
		[ -e "\${SHIM_RM_MARK:-/nonexistent}" ] && { echo "rm: injected failure (TEST HARNESS)" >&2; exit 1; } ;;
	esac
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
chmod 0755 "$SHIMS/mv/mv" "$SHIMS/rm/rm" "$SHIMS/chown/chown"

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
TAG=rasputin-store-restore
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

# setup — a fresh scratch tree. Live store B: data entries (a file, a second
# file, a dotfile and a nested directory), its seal pair and a staged rotation
# key. Staged store A under restore-pending/store/, laid out as PrepareRestore
# lays it out: data/ (a file, a dotfile and a nested directory), seal-key,
# seal.hcl and openbao-version; restore-pending/trust/store-ca.{key,pem} and
# restore-pending/restore.json beside it. The keys are printable, so the
# secret scan can grep for them raw and as hex.
KEY_A="AAAAkey-restored-0123456789abcde"
KEY_B="BBBBkey-reflashed-123456789abcde"
setup() {
	W=$(mktemp -d "$TMP/w.XXXXXX")
	RP="$W/restore-pending"
	P="$RP/store"
	D="$W/openbao"
	S="$W/openbao-seal"
	mkdir -p "$D/bsub" "$S/rotation" "$P/data/sub" "$RP/trust"
	printf 'B-one' > "$D/000001.log"
	printf 'B-two' > "$D/MANIFEST-000001"
	printf 'B-dot' > "$D/.b-only"
	printf 'B-nested' > "$D/bsub/f"
	printf '%s' "$KEY_B" > "$S/seal-key"
	printf 'seal "static" { current_key_id = "rasputin-bbbb" }\n' > "$S/seal.hcl"
	printf 'rotation key' > "$S/rotation/rasputin-cccc"
	printf 'A-one' > "$P/data/000002.log"
	printf 'A-dot' > "$P/data/.a-dot"
	printf 'A-nested' > "$P/data/sub/f"
	printf '%s' "$KEY_A" > "$P/seal-key"
	printf 'seal "static" { current_key_id = "rasputin-aaaa" }\n' > "$P/seal.hcl"
	printf 'v2.7.1\n' > "$P/openbao-version"
	printf 'ca key\n' > "$RP/trust/store-ca.key"
	printf 'ca pem\n' > "$RP/trust/store-ca.pem"
	printf '{"id":"r1"}\n' > "$RP/restore.json"
	chmod -R go-rwx "$W"
	: > "$W/kmsg"
	PENDING="$P"
	MV_RULES=""
	SHIM_PATH=""
	B_DATA=$(tree "$D")
	B_SEAL=$(seal_sum)
	A_DATA=$(tree "$P/data")
	STAGED=$(tree "$RP")
}
# seal_sum — the live seal pair and rotation/, hashed.
seal_sum() { printf '%s|%s|%s\n' "$(sha < "$S/seal-key" 2>&1)" "$(sha < "$S/seal.hcl" 2>&1)" "$(tree "$S/rotation")"; }
# work_left — the work directories still present, by name.
work_left() { find "$W" -name '.rasputin-restore-*' -print 2>/dev/null; }

# run — the script under $SH; stdout, stderr and status apart. Every output is
# kept for the secret scan (TC-766-13).
#
# busybox sh runs its own mv, rm and chown applets ahead of PATH (Ubuntu's
# busybox-static, which the CI runner has, does), so a shim on PATH alone
# never fires there. A shell function does: when a shim is in use, busybox sh
# defines the shim's command as a function calling it, then sources the
# script with $0 set as a direct run sets it (the test/tls-refusal-test.sh
# pattern). TEST HARNESS only; the script itself is unchanged.
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
	# shellcheck disable=SC2086 # _cmd is "busybox sh" on purpose
	env PATH="$_path" SHIM_BB="$_bb" SHIM_MV_RULES="$MV_RULES" SHIM_RM_MARK="$P/applied" \
		SHIM_CHOWN_LOG="$W/chown.log" \
		RASPUTIN_STORERESTORE_PENDING="$PENDING" RASPUTIN_STORERESTORE_DATA="$D" \
		RASPUTIN_STORERESTORE_SEAL="$S" RASPUTIN_STORERESTORE_KMSG="$W/kmsg" \
		$_cmd "$@" > "$W/stdout" 2> "$W/stderr"
	RC=$?
	OUT=$(cat "$W/stdout")
	cat "$W/stdout" "$W/stderr" "$W/kmsg" >> "$ALLOUT"
}

# same_line LABEL — the console sink holds stdout's last line, identical. The
# scratch console keeps only the last line written (outcome_log opens it with
# >, which on /dev/kmsg itself appends).
same_line() {
	ok "$1: the console has stdout's line, identical" \
		"$(yes_if test -n "$OUT" -a "$(cat "$W/kmsg")" = "$(printf '%s\n' "$OUT" | tail -n 1)")" \
		"kmsg: $(cat "$W/kmsg") | stdout: $OUT"
}
# untouched LABEL — B's data and seal are live, byte for byte; no marker; no
# work directory; restore-pending/ as staged.
untouched() {
	ok "$1: the live data is B's, byte for byte" "$(yes_if test "$(tree "$D")" = "$B_DATA")" "$(tree "$D")"
	ok "$1: the live seal key, fragment and rotation/ are B's" "$(yes_if test "$(seal_sum)" = "$B_SEAL")"
	ok "$1: there is no marker" "$(yes_if test ! -e "$P/applied")"
	ok "$1: no work directory is left" "$(yes_if test -z "$(work_left)")" "$(work_left)"
	ok "$1: restore-pending/ is as staged" "$(yes_if test "$(tree "$RP")" = "$STAGED")"
}
# applied_state LABEL — A's data and seal pair are live, rotation/ is B's,
# restore-pending/ is whole plus a 0600 marker, and no work directory is left.
applied_state() {
	ok "$1: the live data is exactly A's entries, byte for byte" "$(yes_if test "$(tree "$D")" = "$A_DATA")" \
		"live: $(tree "$D" | tr '\n' '|') staged: $(printf '%s' "$A_DATA" | tr '\n' '|')"
	ok "$1: none of B's names is left" "$(yes_if test ! -e "$D/000001.log" -a ! -e "$D/.b-only" -a ! -e "$D/bsub" -a ! -e "$D/MANIFEST-000001")"
	ok "$1: the dotfile and the nested file came across" "$(yes_if test -f "$D/.a-dot" -a -f "$D/sub/f")"
	ok "$1: the live seal-key is the staged one, byte for byte" "$(yes_if cmp -s "$S/seal-key" "$P/seal-key")"
	ok "$1: the live seal.hcl is the staged one, byte for byte" "$(yes_if cmp -s "$S/seal.hcl" "$P/seal.hcl")"
	ok "$1: TC-766-04 rotation/ and its file are unchanged" \
		"$(yes_if test "$(tree "$S/rotation")" = "$(printf '%s' "$B_SEAL" | cut -d'|' -f3-)")" "$(tree "$S/rotation")"
	ok "$1: TC-766-04 every path under restore-pending/ but applied is as staged" \
		"$(yes_if test "$(tree "$RP" | grep -v '^f ./store/applied ')" = "$STAGED")" "$(tree "$RP" | tr '\n' '|')"
	ok "$1: TC-766-04 applied is a regular file, mode 0600" \
		"$(yes_if test -f "$P/applied" -a ! -L "$P/applied" -a "$(ls -l "$P/applied" | cut -c1-10)" = "-rw-------")" "$(ls -l "$P/applied" 2>&1)"
	ok "$1: TC-766-04 no work directory is left" "$(yes_if test -z "$(work_left)")" "$(work_left)"
}

cases() {
	ALLOUT="$TMP/all.$SH"
	: > "$ALLOUT"

	# TC-766-01 (a): no restore-pending/ at all.
	setup; rm -rf "$RP"; run
	l="TC-766-01 nothing staged"
	ok "$l: exits 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT"
	ok "$l: prints nothing on stdout, stderr or the console" "$(yes_if test -z "$OUT" -a ! -s "$W/stderr" -a ! -s "$W/kmsg")" "$OUT $(cat "$W/stderr")"
	ok "$l: the data and seal are unchanged" "$(yes_if test "$(tree "$D")" = "$B_DATA" -a "$(seal_sum)" = "$B_SEAL")"
	ok "$l: nothing was created" "$(yes_if test ! -e "$RP" -a -z "$(work_left)")"
	# TC-766-01 (b): a v1/v2 staging, which stages no store/.
	setup; rm -rf "$P"; STAGED=$(tree "$RP"); run
	l="TC-766-01 a staging with no store/"
	ok "$l: exits 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT"
	ok "$l: prints nothing on stdout, stderr or the console" "$(yes_if test -z "$OUT" -a ! -s "$W/stderr" -a ! -s "$W/kmsg")" "$OUT $(cat "$W/stderr")"
	ok "$l: the data, seal and staging are unchanged" \
		"$(yes_if test "$(tree "$D")" = "$B_DATA" -a "$(seal_sum)" = "$B_SEAL" -a "$(tree "$RP")" = "$STAGED")"
	ok "$l: nothing was created" "$(yes_if test -z "$(work_left)")"

	# TC-766-02: the marker present, with all four work directories left.
	setup
	: > "$P/applied"; chmod 0600 "$P/applied"
	for w in "$D/.rasputin-restore-old" "$D/.rasputin-restore-new" "$S/.rasputin-restore-old" "$S/.rasputin-restore-new"; do
		mkdir "$w"; printf 'left' > "$w/left"
	done
	STAGED=$(tree "$RP"); B_DATA_NOWORK=$B_DATA
	run
	l="TC-766-02 the marker present"
	ok "$l: exits 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT"
	ok "$l: prints nothing" "$(yes_if test -z "$OUT" -a ! -s "$W/stderr" -a ! -s "$W/kmsg")" "$OUT $(cat "$W/stderr")"
	ok "$l: all four work directories are gone" "$(yes_if test -z "$(work_left)")" "$(work_left)"
	ok "$l: the live data is unchanged" "$(yes_if test "$(tree "$D")" = "$B_DATA_NOWORK")" "$(tree "$D")"
	ok "$l: the live seal is unchanged" "$(yes_if test "$(seal_sum)" = "$B_SEAL")"
	ok "$l: restore-pending/ is unchanged, the marker included" "$(yes_if test "$(tree "$RP")" = "$STAGED")"

	# TC-766-03 and TC-766-04: the swap.
	setup; run
	l="TC-766-03 the swap"
	ok "$l: exits 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT $(cat "$W/stderr")"
	applied_state "$l"
	ok "$l: stdout is one <6> outcome=applied line" \
		"$(yes_if test "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 -a -n "$OUT")" "$OUT"
	ok "$l: the line is <6>$TAG: outcome=applied reason=\"...\"" "$(yes_if out_has "<6>$TAG: outcome=applied reason=\"")" "$OUT"
	same_line "$l"
	ok "$l: nothing on stderr" "$(yes_if test ! -s "$W/stderr")" "$(cat "$W/stderr")"

	# TC-766-05: the owner comes from the data directory, through one recursive
	# chown of the data copy.
	setup; SHIM_PATH="$SHIMS/chown"; : > "$W/chown.log"
	want_owner=$(ls -ldn "$D" | awk '{ print $3 ":" $4 }')
	run; SHIM_PATH=""
	l="TC-766-05 the owner"
	ok "$l: exits 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT"
	ok "$l: exactly one chown, -R $want_owner of the data copy" \
		"$(yes_if test "$(cat "$W/chown.log")" = "-R $want_owner $D/.rasputin-restore-new")" "$(cat "$W/chown.log")"

	# TC-766-06: member refusals.
	for v in "data:missing" "data:file" "data:symlink" "seal-key:missing" "seal-key:dir" "seal-key:symlink" \
		"seal.hcl:missing" "seal.hcl:dir" "seal.hcl:symlink"; do
		m=${v%%:*} how=${v#*:}
		setup
		rm -rf "${P:?}/$m"
		case "$how" in
			file) printf 'x' > "$P/$m" ;;
			dir) mkdir "$P/$m" ;;
			symlink)
				if [ "$m" = data ]; then mkdir "$W/elsewhere"; ln -s "$W/elsewhere" "$P/$m"
				else printf 'x' > "$W/elsewhere"; ln -s "$W/elsewhere" "$P/$m"; fi ;;
		esac
		STAGED=$(tree "$RP")
		run
		l="TC-766-06 store/$m $how"
		ok "$l: exits 1" "$(yes_if test "$RC" = 1)" "rc=$RC $OUT"
		ok "$l: a <3> refused line naming the member and saying nothing was changed" \
			"$(yes_if eval 'out_has "<3>$TAG: outcome=refused reason=\"The staged member $P/$m " && contains "nothing was changed." "$OUT"')" "$OUT"
		same_line "$l"
		untouched "$l"
	done

	# TC-766-07: an interrupted swap refuses and changes nothing, -old and
	# -new included.
	for wn in openbao openbao-seal; do
		setup
		w="$W/$wn"
		mkdir "$w/.rasputin-restore-old" "$w/.rasputin-restore-new"
		printf 'old' > "$w/.rasputin-restore-old/x"; printf 'new' > "$w/.rasputin-restore-new/y"
		before=$(tree "$W")
		run
		l="TC-766-07 a leftover ${w##*/}/.rasputin-restore-old"
		ok "$l: exits 1" "$(yes_if test "$RC" = 1)" "rc=$RC $OUT"
		ok "$l: a <3> refused line saying an earlier apply was interrupted" \
			"$(yes_if out_has "<3>$TAG: outcome=refused reason=\"An earlier apply of the staged restore was interrupted and left $w/.rasputin-restore-old")" "$OUT"
		ok "$l: F-766-01 it says to reflash and restore again from the backup disk" \
			"$(yes_if contains "Reflash the control plane and restore again from the backup disk, whose archive is untouched.\"" "$OUT")" "$OUT"
		same_line "$l"
		ok "$l: every tree hashes the same as before (live, -old, -new, staged)" \
			"$(yes_if test "$(tree "$W" | grep -v -e ' ./stdout' -e ' ./stderr' -e ' ./kmsg')" = "$(printf '%s\n' "$before" | grep -v -e ' ./stdout' -e ' ./stderr' -e ' ./kmsg')")"
	done

	# TC-766-08: a leftover -new is cleared, then the apply goes ahead.
	setup
	mkdir "$D/.rasputin-restore-new" "$S/.rasputin-restore-new"
	printf 'stale' > "$D/.rasputin-restore-new/stale-data"; printf 'stale' > "$S/.rasputin-restore-new/stale-seal"
	run
	l="TC-766-08 a leftover -new"
	ok "$l: exits 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT $(cat "$W/stderr")"
	applied_state "$l"
	ok "$l: the stale names are gone" "$(yes_if test -z "$(find "$W" -name 'stale-*')")" "$(find "$W" -name 'stale-*')"

	# TC-766-09: a copy failure changes nothing.
	setup
	chmod 000 "$P/data/000002.log"
	STAGED=$(chmod 0600 "$P/data/000002.log"; tree "$RP"; chmod 000 "$P/data/000002.log")
	run
	chmod 0600 "$P/data/000002.log"
	l="TC-766-09 the copy fails"
	ok "$l: exits 1" "$(yes_if test "$RC" = 1)" "rc=$RC $OUT"
	ok "$l: a <3> failed line naming the copy step and saying the data and seal key were not changed" \
		"$(yes_if eval 'out_has "<3>$TAG: outcome=failed reason=\"Copying the staged restore failed at the step that copies the data into $D/.rasputin-restore-new" && contains "the store'"'"'s data and seal key were not changed." "$OUT"')" "$OUT"
	same_line "$l"
	untouched "$l"

	# TC-766-10: a failed rename rolls back, at each of five points.
	DO=.rasputin-restore-old DN=.rasputin-restore-new
	for point in "data phase A" "data phase B" "seal phase A" "seal phase B" "the marker"; do
		setup; SHIM_PATH="$SHIMS/mv"; MV_RULES="$W/mv.rules"
		case "$point" in
			"data phase A") printf '%s %s 2\n' "$D/*" "$D/$DO/" ;;
			"data phase B") printf '%s %s 2\n' "$D/$DN/*" "$D/" ;;
			"seal phase A") printf '%s %s 2\n' "$S/*" "$S/$DO/" ;;
			"seal phase B") printf '%s %s 2\n' "$S/$DN/*" "$S/" ;;
			"the marker") printf '%s %s 1\n' "$P/.applied.new" "$P/applied" ;;
		esac > "$MV_RULES"
		run; SHIM_PATH=""; MV_RULES=""
		l="TC-766-10 a rename fails in $point"
		ok "$l: the injected failure fired" "$(yes_if grep -q 'injected failure' "$W/stderr")" "$(cat "$W/stderr")"
		ok "$l: exits 1" "$(yes_if test "$RC" = 1)" "rc=$RC $OUT"
		ok "$l: a <3> failed line saying the old data and seal key were put back" \
			"$(yes_if eval 'out_has "<3>$TAG: outcome=failed reason=\"" && contains "the old data and seal key were put back.\"" "$OUT"')" "$OUT"
		same_line "$l"
		untouched "$l"
		rm -f "$W"/mv.rules*
	done

	# TC-766-11: the rollback fails too; then the next start refuses.
	setup; SHIM_PATH="$SHIMS/mv"; MV_RULES="$W/mv.rules"
	printf '%s %s 2\n%s %s 1\n' "$D/$DN/*" "$D/" "$D/*" "$D/$DN/" > "$MV_RULES"
	run; SHIM_PATH=""; MV_RULES=""
	l="TC-766-11 the rollback fails"
	ok "$l: exits 1" "$(yes_if test "$RC" = 1)" "rc=$RC $OUT"
	ok "$l: a <2> failed line saying the work directories are left" \
		"$(yes_if eval 'out_has "<2>$TAG: outcome=failed reason=\"" && contains "so the work directories $D/$DO and $S/$DO are left" "$OUT"')" "$OUT"
	ok "$l: F-766-01 it says to reflash and restore again from the backup disk" \
		"$(yes_if contains "Reflash the control plane and restore again from the backup disk, whose archive is untouched.\"" "$OUT")" "$OUT"
	same_line "$l"
	ok "$l: -old remains" "$(yes_if test -d "$D/$DO")"
	ok "$l: there is no marker" "$(yes_if test ! -e "$P/applied")"
	run
	ok "$l, then a run with the real mv: exits 1" "$(yes_if test "$RC" = 1)" "rc=$RC $OUT"
	ok "$l, then a run with the real mv: refused as interrupted" \
		"$(yes_if out_has "<3>$TAG: outcome=refused reason=\"An earlier apply of the staged restore was interrupted")" "$OUT"

	# TC-766-12: cleanup after the commit fails; the next start finishes it.
	setup; SHIM_PATH="$SHIMS/rm"
	run; SHIM_PATH=""
	l="TC-766-12 cleanup fails after the commit"
	ok "$l: exits 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT"
	ok "$l: the marker is present" "$(yes_if test -f "$P/applied")"
	ok "$l: a <4> line names the path left behind" \
		"$(yes_if out_has "<4>$TAG: The work directory $D/$DO is left from an applied restore and could not be removed")" "$OUT"
	ok "$l: the live data and seal are A's" \
		"$(yes_if test "$(tree "$D" | grep -v "$DO" | grep -v "$DN")" = "$A_DATA" -a "$(sha < "$S/seal-key")" = "$(sha < "$P/seal-key")")"
	ok "$l: the last line is outcome=applied" "$(yes_if eval 'printf "%s\n" "$OUT" | tail -n 1 | grep -q "^<6>$TAG: outcome=applied "')" "$OUT"
	run
	ok "$l, then a run with the real rm: exits 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT"
	ok "$l, then a run with the real rm: no output" "$(yes_if test -z "$OUT" -a ! -s "$W/stderr" -a ! -s "$W/kmsg")" "$OUT"
	ok "$l, then a run with the real rm: no work directory is left" "$(yes_if test -z "$(work_left)")" "$(work_left)"

	# TC-766-13: no key byte, raw or as lowercase hex, in any output above.
	l="TC-766-13 LOG-SECRETS"
	printf '%s' "$KEY_A" > "$TMP/key-a"; printf '%s' "$KEY_B" > "$TMP/key-b"
	for k in a b; do
		raw=$(cat "$TMP/key-$k")
		hex=$(od -An -v -tx1 "$TMP/key-$k" | tr -d ' \n')
		ok "$l: key $k raw is in no output" "$(yes_if test -s "$ALLOUT" -a "$(grep -cF -- "$raw" "$ALLOUT")" = 0)"
		ok "$l: key $k as hex is in no output" "$(yes_if test "$(grep -cF -- "$hex" "$ALLOUT")" = 0)"
		printf 'x%sx\n%s\n' "$raw" "$hex" > "$TMP/control"
		ok "$l: positive control: the same search finds key $k, raw and hex, in a file that holds it" \
			"$(yes_if test "$(grep -cF -- "$raw" "$TMP/control")" = 1 -a "$(grep -cF -- "$hex" "$TMP/control")" = 1)"
	done
}

echo "store-restore tests, shells:$TEST_SHELLS"
for SH in $TEST_SHELLS; do
	cases
done

# --- static -------------------------------------------------------------------
SH=static
ok "the script is executable in the overlay" "$(yes_if test -x "$SCRIPT")"
# TC-766-05: no uid or uid:gid literal in the script; the owner is read.
ok "TC-766-05 no uid literal in the script" \
	"$(yes_if test -z "$(grep -nE '(^|[^0-9])990([^0-9]|$)|[0-9]+:[0-9]+' "$SCRIPT")")" "$(grep -nE '990|[0-9]+:[0-9]+' "$SCRIPT")"
for d in 'PENDING="${RASPUTIN_STORERESTORE_PENDING:-/var/lib/rasputin/restore-pending/store}"' \
	'DATA="${RASPUTIN_STORERESTORE_DATA:-/var/lib/rasputin/openbao}"' \
	'SEAL="${RASPUTIN_STORERESTORE_SEAL:-/var/lib/rasputin/openbao-seal}"' \
	'OUTCOME_KMSG="${RASPUTIN_STORERESTORE_KMSG:-/dev/kmsg}"'; do
	ok "the script's production default: $d" "$(yes_if grep -qxF -- "$d" "$SCRIPT")"
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

echo "store-restore tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
