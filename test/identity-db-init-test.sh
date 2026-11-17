#!/bin/sh
#
# Tests for Identity 2.7's first-boot scripts (geekdojo/geekdojo-brain#975,
# TC-975-08 to TC-975-13): keycloak-db.service's gate (identity-db-init-gate.sh
# pre and post) and init step (identity-db-init.sh), keycloak.service's stage
# step (identity-stage-import.sh), and the `armed` reading they share
# (armed.sh), held to the #979 outcome record the api's reader parses.
#
# Why. The gate decides whether a start may create an empty identity database,
# which on an armed cluster would hand it a blank identity; the record is the
# only way the api learns which way it went; and the gate and the stage step
# write as root inside directories a less privileged uid owns. A wrong row, a
# record outside the contract, a reason that names a vendor to an operator,
# or a write through a planted link is silent until a node is broken. So
# every branch runs against a scratch tree, with a fake initdb and a fake
# postgres that record their argv and stdin, and each run's files, modes,
# exit status and log lines are checked.
#
# How. The real scripts run with every collaborator pointed at scratch files
# through RASPUTIN_IDDBGATE_*, RASPUTIN_IDDBINIT_* and RASPUTIN_KCSTAGE_*, and
# OWNER set to the test user. No root, no systemd, no PostgreSQL: what systemd,
# the real initdb and Keycloak do with them is test/identity-unit-functional.sh.
#
# Shells. Every case runs under each shell in TEST_SHELLS (default: whichever
# of sh, dash and bash are installed), under `busybox sh`, and under
# `busybox sh` with busybox's own applets ahead of PATH, so the image's ls,
# rm, mv, cp, chmod, chown, mkdir, rmdir, sed, grep, head and sync are the ones
# exercised. REQUIRE_BUSYBOX=1 (CI sets it) makes a missing busybox a failure.
#
# Root. The suite refuses to run as root, with a failure and not a skip: root
# lists a mode-0000 directory and writes into a mode-0500 one, so the
# fail-closed cases would pass over nothing.
#
# Run:  sh test/identity-db-init-test.sh
set -u
LC_ALL=C
export LC_ALL

if [ "$(id -u)" = 0 ]; then
	echo "FAILED: this suite must not run as root, because root lists a mode-0000 directory and the fail-closed cases would prove nothing." >&2
	exit 1
fi
if [ "${REQUIRE_BUSYBOX:-0}" = "1" ] && ! command -v busybox >/dev/null 2>&1; then
	echo "FAILED: REQUIRE_BUSYBOX=1 but busybox is not installed." >&2
	exit 1
fi

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
IDDIR="$OVERLAY/usr/lib/rasputin/identity"
GATE="$IDDIR/identity-db-init-gate.sh"
INIT="$IDDIR/identity-db-init.sh"
STAGE="$IDDIR/identity-stage-import.sh"
ARMED="$IDDIR/armed.sh"
LIB="$OVERLAY/usr/lib/rasputin/outcome/outcome.sh"
for f in "$GATE" "$INIT" "$STAGE" "$ARMED" "$LIB"; do
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
	for applet in ls mv cp chmod chown rm rmdir cat mkdir dirname sed grep head sync; do
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
# fingerprint PATH — mode, owner and bytes, to prove a link target unchanged.
fingerprint() { printf '%s %s ' "$(perms "$1")" "$(owner "$1")"; cksum < "$1"; }
ME="$(id -u):$(id -g)"
BOOT_ID="b00710d0-0000-4000-8000-000000000975"

# The fakes. initdb records its argv, one word per line, in $FAKE_DIR/initdb.argv,
# exits with $FAKE_DIR/initdb.rc when present, and otherwise writes PG_VERSION
# and global/pg_control into its -D directory. postgres records its argv and
# stdin and answers by $FAKE_DIR/postgres.mode: ok (the token, exit 0), rc
# (the token, exit 1), error (an ERROR: line and the token, exit 0) or
# notoken (nothing, exit 0).
FAKES="$TMP/fakes"
mkdir -p "$FAKES"
cat > "$FAKES/initdb" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done > "$FAKE_DIR/initdb.argv"
[ -f "$FAKE_DIR/initdb.rc" ] && exit "$(cat "$FAKE_DIR/initdb.rc")"
mkdir -p "$2/global" && echo 18 > "$2/PG_VERSION" && echo control > "$2/global/pg_control"
EOF
cat > "$FAKES/postgres" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done > "$FAKE_DIR/postgres.argv"
cat > "$FAKE_DIR/postgres.stdin"
tok='	 1: rasputin_bootstrap = "ok"	(typeid = 25, len = -1, typmod = -1, byval = f)'
case "$(cat "$FAKE_DIR/postgres.mode" 2>/dev/null || echo ok)" in
	ok) printf '%s\n' "$tok" ;;
	rc) printf '%s\n' "$tok"; exit 1 ;;
	error) printf '2026-11-17 ERROR:  role "keycloak" already exists\n%s\n' "$tok" ;;
	notoken) : ;;
esac
exit 0
EOF
chmod 0755 "$FAKES/initdb" "$FAKES/postgres"

# setup — a fresh scratch tree: identity-db/ with tmpfiles' empty data/,
# identity/ unarmed, no run directory yet, keycloak/data, a baseline, a boot id
# and a console.
setup() {
	W=$(mktemp -d "$TMP/w.XXXXXX")
	F="$W/fake"
	DB="$W/identity-db"
	DATA="$DB/data"
	DINIT="$DB/data.init"
	IDENT="$W/identity"
	RUN="$W/run"
	REC="$RUN/outcome"
	PENDING="$RUN/pending"
	KCDATA="$W/keycloak/data"
	IMPORT="$KCDATA/import"
	STAGED="$IMPORT/realm-baseline.json"
	BASELINE="$W/share/realm-baseline.json"
	mkdir -p "$F" "$DATA" "$IDENT" "$KCDATA" "$W/share"
	chmod 0700 "$DB" "$DATA" "$IDENT" "$W/keycloak" "$KCDATA"
	printf '{"realm": "rasputin"}\n' > "$BASELINE"
	printf '%s\n' "$BOOT_ID" > "$W/bootid"
	: > "$W/kmsg"
}

# launch SCRIPT ARG [VAR=VALUE ...] — exec SCRIPT under $SH with ARG (none
# when empty) and every collaborator pointed into the scratch tree, plus the
# given extra environment. Called in a subshell.
launch() {
	_script=$1 _arg=$2; shift 2
	case "$SH" in
		busybox_sh|busybox_applets) _cmd="busybox sh" ;;
		*) _cmd=$SH ;;
	esac
	_path=$PATH
	[ "$SH" = busybox_applets ] && _path="$BUSYBOX_DIR:$PATH"
	set -- env PATH="$_path" FAKE_DIR="$F" \
		RASPUTIN_IDDBGATE_DB="$DB" RASPUTIN_IDDBGATE_IDENTITY="$IDENT" RASPUTIN_IDDBGATE_RUN="$RUN" \
		RASPUTIN_IDDBGATE_BOOTID="$W/bootid" RASPUTIN_IDDBGATE_KMSG="$W/kmsg" RASPUTIN_IDDBGATE_OWNER="$ME" \
		RASPUTIN_IDDBINIT_DB="$DB" RASPUTIN_IDDBINIT_INITDB="$FAKES/initdb" \
		RASPUTIN_IDDBINIT_POSTGRES="$FAKES/postgres" RASPUTIN_IDDBINIT_KMSG="$W/kmsg" \
		RASPUTIN_KCSTAGE_IDENTITY="$IDENT" RASPUTIN_KCSTAGE_BASELINE="$BASELINE" \
		RASPUTIN_KCSTAGE_DATA="$KCDATA" RASPUTIN_KCSTAGE_OWNER="$ME" RASPUTIN_KCSTAGE_KMSG="$W/kmsg" \
		"$@"
	# shellcheck disable=SC2086 # _cmd is "busybox sh" on purpose
	if [ -n "$_arg" ]; then exec "$@" $_cmd "$_script" "$_arg"; fi
	# shellcheck disable=SC2086
	exec "$@" $_cmd "$_script"
}
# run SCRIPT ARG [VAR=VALUE ...] — launch it and wait; stdout and status.
run() {
	(launch "$@") > "$W/stdout" 2> "$W/stderr"
	RC=$?
	OUT=$(cat "$W/stdout")
}
gate() { _p=$1; shift; run "$GATE" "$_p" "$@"; }
init() { run "$INIT" ""; }
stage() { run "$STAGE" ""; }
# logged PRIORITY TAG TEXT — stdout (the journal) has a <PRIORITY>TAG: line
# containing TEXT.
logged() { printf '%s\n' "$OUT" | grep "^<$1>$2: " | grep -qF -- "$3"; }
field() { sed -n "s/^$1=//p" "$REC" 2>/dev/null; }
# record_is OUTCOME — the record is exactly the three lines, ending in a
# newline, 0600 in a 0700 directory, with no temp file beside it.
record_is() {
	_want=$(printf 'outcome=%s\nboot_id=%s\nreason=%s\n.' "$1" "$BOOT_ID" "$(field reason)")
	_got=$(cat "$REC" 2>/dev/null; echo .)
	[ "$_got" = "$_want" ] && [ "$(grep -c . "$REC")" = 3 ] \
		&& [ "$(perms "$REC")" = -rw------- ] && [ "$(perms "$RUN")" = drwx------ ] \
		&& [ ! -e "$RUN/.outcome.new" ]
}
# reason_ok — TC-975-10's reason rules on the record's reason: 1 to 1024
# bytes, no control character, a capital first, a full stop last, and no
# vendor or tool name in any case.
reason_ok() {
	_r=$(field reason)
	[ -n "$_r" ] && [ "${#_r}" -le 1024 ] || return 1
	printf '%s' "$_r" | grep -q '[[:cntrl:]]' && return 1
	case "$_r" in [A-Z]*.) ;; *) return 1 ;; esac
	! printf '%s' "$_r" | grep -qiE 'keycloak|postgresql|postgres|initdb'
}
# outcome_line OUTCOME PRIORITY — the gate's line at PRIORITY, with the
# record's reason, on stdout and as the console's last line.
outcome_line() {
	_l="<$2>identity-db-init-gate: outcome=$1 reason=\"$(field reason)\""
	printf '%s\n' "$OUT" | grep -qxF -- "$_l" && [ "$(tail -n 1 "$W/kmsg")" = "$_l" ]
}
# old_record OUTCOME — a record from an earlier start of this boot.
old_record() {
	mkrun
	printf 'outcome=%s\nboot_id=%s\nreason=Earlier.\n' "$1" "$BOOT_ID" > "$REC"
	chmod 0600 "$REC"
}
cluster() { : > "$DATA/PG_VERSION"; }
# mkrun — the record directory as the gate makes it, 0700.
mkrun() { mkdir -p "$RUN" && chmod 0700 "$RUN"; }
# link_kept — the planted link is still where it was planted.
link_kept() {
	case "$plant" in
		data) [ -L "$KCDATA" ] ;;
		import) [ -L "$IMPORT" ] ;;
		final) [ -L "$STAGED" ] ;;
	esac
}

for SH in $TEST_SHELLS; do

	# --- TC-975-13: armed.sh ----------------------------------------------------
	setup
	for kind in file dir dangling none unlistable missing; do
		d="$W/arm-$kind"
		mkdir -p "$d"
		case "$kind" in
			file) : > "$d/armed" ;;
			dir) mkdir "$d/armed" ;;
			dangling) ln -s "$W/nowhere" "$d/armed" ;;
			none) : > "$d/armed.old" ;;
			unlistable) : > "$d/armed"; chmod 0000 "$d" ;;
			missing) rmdir "$d" ;;
		esac
		case "$SH" in busybox_sh|busybox_applets) c="busybox sh" ;; *) c=$SH ;; esac
		p=$PATH
		[ "$SH" = busybox_applets ] && p="$BUSYBOX_DIR:$PATH"
		# shellcheck disable=SC2086 # c is "busybox sh" on purpose
		got=$(PATH="$p" $c -c '. "$1"; identity_armed "$2"' armed-test "$ARMED" "$d")
		case "$kind" in file|dir|dangling) want=armed ;; none) want=unarmed ;; *) want=unknown ;; esac
		ok "TC-975-13 identity_armed on $kind prints $want" "$(yes_if test "$got" = "$want")" "got '$got'"
		chmod 0700 "$d" 2>/dev/null
	done

	# --- TC-975-08: gate pre ----------------------------------------------------
	# data unlistable: refused.
	setup
	chmod 0000 "$DATA"
	gate pre
	chmod 0700 "$DATA"
	ok "TC-975-08 data unlistable: refused, exit 1" "$(yes_if test "$RC" = 1 -a "$(field outcome)" = refused)" "rc=$RC $OUT"
	ok "TC-975-08 data unlistable: the record is exact and the reason says the data could not be read" \
		"$({ record_is refused && reason_ok && field reason | grep -qF 'data could not be read'; } && echo 0 || echo 1)" "$(cat "$REC" 2>&1)"
	ok "TC-975-08 data unlistable: a <2> line, also on the console" "$(yes_if outcome_line refused 2)" "$OUT"
	# data a symlink to a listable directory: refused, never followed.
	setup
	rmdir "$DATA"; mkdir "$W/elsewhere"; : > "$W/elsewhere/x"; ln -s "$W/elsewhere" "$DATA"
	gate pre
	ok "TC-975-08 data planted as a symlink: refused, exit 1, no data.init" \
		"$(yes_if test "$RC" = 1 -a "$(field outcome)" = refused -a ! -e "$DINIT")" "rc=$RC $OUT"

	# data lists anything: untouched, a stale pending removed.
	setup
	cluster
	mkrun; : > "$PENDING"
	gate pre
	ok "TC-975-08 data present: untouched, exit 0" "$(yes_if test "$RC" = 0 -a "$(field outcome)" = untouched)" "rc=$RC $OUT"
	ok "TC-975-08 data present: the stale pending is removed, no data.init" "$(yes_if test ! -e "$PENDING" -a ! -e "$DINIT")"
	ok "TC-975-10 untouched: the record is exact and its reason passes" "$({ record_is untouched && reason_ok; } && echo 0 || echo 1)" "$(cat "$REC" 2>&1)"
	ok "TC-975-10 untouched: a <6> line, also on the console" "$(yes_if outcome_line untouched 6)" "$OUT"

	# armed (file, directory, dangling symlink) with data empty or absent.
	for kind in file dir dangling; do
		for d in empty absent; do
			setup
			case "$kind" in
				file) : > "$IDENT/armed" ;;
				dir) mkdir "$IDENT/armed" ;;
				dangling) ln -s "$W/nowhere" "$IDENT/armed" ;;
			esac
			[ "$d" = absent ] && rmdir "$DATA"
			mkrun; : > "$PENDING"
			gate pre
			ok "TC-975-08 armed ($kind), data $d: refused, exit 1" "$(yes_if test "$RC" = 1 -a "$(field outcome)" = refused)" "rc=$RC $OUT"
			ok "TC-975-08 armed ($kind), data $d: pending removed, no data.init" "$(yes_if test ! -e "$PENDING" -a ! -e "$DINIT")"
		done
	done
	ok "TC-975-10 armed: the record is exact and its reason passes" "$({ record_is refused && reason_ok; } && echo 0 || echo 1)" "$(cat "$REC" 2>&1)"
	ok "TC-975-10 armed: the reason names a restore from a backup of this cluster as the way out" \
		"$(yes_if sh -c "sed -n 's/^reason=//p' '$REC' | grep -q 'Restore the sign-in data from a backup of this cluster'")" "$(field reason)"
	ok "TC-975-10 refused: a <2> line, also on the console" "$(yes_if outcome_line refused 2)" "$OUT"

	# identity unlistable: unknown, refused.
	setup
	chmod 0000 "$IDENT"
	gate pre
	chmod 0700 "$IDENT"
	ok "TC-975-08 identity unlistable (unknown): refused, exit 1, no data.init" \
		"$(yes_if test "$RC" = 1 -a "$(field outcome)" = refused -a ! -e "$DINIT")" "rc=$RC $OUT"
	ok "TC-975-10 unknown: the record is exact, the reason says it could not be read" \
		"$({ record_is refused && reason_ok && field reason | grep -qF 'could not be read'; } && echo 0 || echo 1)" "$(cat "$REC" 2>&1)"

	# unarmed, data empty or absent: permitted.
	for d in empty absent; do
		setup
		[ "$d" = absent ] && rmdir "$DATA"
		mkdir -p "$DINIT/base"; : > "$DINIT/base/stale"
		gate pre
		ok "TC-975-08 unarmed, data $d: exit 0, no record" "$(yes_if test "$RC" = 0 -a ! -e "$REC")" "rc=$RC $OUT"
		ok "TC-975-08 unarmed, data $d: pending written" "$(yes_if test -f "$PENDING")"
		ok "TC-975-08 unarmed, data $d: the stale data.init is replaced by an empty one, 0700, owned by OWNER" \
			"$(yes_if test -d "$DINIT" -a -z "$(ls -A "$DINIT")" -a "$(perms "$DINIT")" = drwx------ -a "$(owner "$DINIT")" = "$ME")" \
			"$(ls -lA "$DINIT" 2>&1)"
		ok "TC-975-08 unarmed, data $d: a <6> line" "$(yes_if logged 6 identity-db-init-gate 'so this start may create it')" "$OUT"
	done
	# data.init planted as a symlink to a directory: unlinked, never followed.
	setup
	mkdir "$W/victim"; printf 'keep\n' > "$W/victim/file"; chmod 0640 "$W/victim/file"
	before=$(fingerprint "$W/victim/file")
	ln -s "$W/victim" "$DINIT"
	gate pre
	ok "TC-975-08 data.init planted as a symlink: exit 0, a real empty directory replaces the link" \
		"$(yes_if test "$RC" = 0 -a ! -L "$DINIT" -a -d "$DINIT" -a -z "$(ls -A "$DINIT")")" "rc=$RC $OUT"
	ok "TC-975-08 data.init planted as a symlink: the target's contents, mode and owner are unchanged" \
		"$(yes_if test "$(ls -A "$W/victim")" = file -a "$(fingerprint "$W/victim/file")" = "$before")"
	# data.init cannot be created, or cannot be chowned.
	setup
	chmod 0500 "$DB"
	gate pre
	chmod 0700 "$DB"
	ok "TC-975-08 data.init cannot be created: refused, exit 1, no pending" \
		"$(yes_if test "$RC" = 1 -a "$(field outcome)" = refused -a ! -e "$PENDING")" "rc=$RC $OUT"
	ok "TC-975-10 preparation failed: the record is exact and its reason passes" "$({ record_is refused && reason_ok; } && echo 0 || echo 1)" "$(cat "$REC" 2>&1)"
	setup
	gate pre RASPUTIN_IDDBGATE_OWNER=0:0
	ok "TC-975-08 data.init cannot be chowned: refused, exit 1, no pending" \
		"$(yes_if test "$RC" = 1 -a "$(field outcome)" = refused -a ! -e "$PENDING")" "rc=$RC $OUT"
	# unknown phase.
	setup
	gate bogus
	ok "TC-975-08 an unknown phase exits 2 with a <3> line, no record" \
		"$(yes_if test "$RC" = 2 -a ! -e "$REC")" "rc=$RC $OUT"
	ok "TC-975-08 an unknown phase: the <3> sentence names pre and post" "$(yes_if logged 3 identity-db-init-gate 'instead of pre or post')" "$OUT"

	# --- TC-975-09: gate post ---------------------------------------------------
	setup
	cluster
	gate post
	ok "TC-975-09 no pending: exit 0, nothing written" "$(yes_if test "$RC" = 0 -a ! -e "$RUN" -a -z "$OUT")" "rc=$RC $OUT"
	setup
	mkrun; : > "$PENDING"; cluster
	gate post
	ok "TC-975-09 pending and data present: created, exit 0, pending removed" \
		"$(yes_if test "$RC" = 0 -a "$(field outcome)" = created -a ! -e "$PENDING")" "rc=$RC $OUT"
	ok "TC-975-10 created: the record is exact and its reason passes" "$({ record_is created && reason_ok; } && echo 0 || echo 1)" "$(cat "$REC" 2>&1)"
	ok "TC-975-10 created: a <6> line, also on the console" "$(yes_if outcome_line created 6)" "$OUT"
	setup
	mkrun; : > "$PENDING"
	gate post
	ok "TC-975-09 pending and data empty: refused, exit 1" "$(yes_if test "$RC" = 1 -a "$(field outcome)" = refused)" "rc=$RC $OUT"
	ok "TC-975-10 post found no data: the record is exact and its reason passes" "$({ record_is refused && reason_ok; } && echo 0 || echo 1)" "$(cat "$REC" 2>&1)"

	# --- TC-975-10: the record rule, boot id, unwritable directory --------------
	# untouched never over created; untouched over refused (F-975-02).
	setup
	cluster; old_record created
	gate pre
	ok "TC-975-10 untouched leaves an earlier created record as it was" \
		"$(yes_if test "$RC" = 0 -a "$(field outcome)" = created -a "$(field reason)" = Earlier.)" "$(cat "$REC")"
	ok "TC-975-10 untouched over created still logs its <6> line" "$(yes_if logged 6 identity-db-init-gate 'outcome=untouched')" "$OUT"
	setup
	cluster; old_record refused
	gate pre
	ok "TC-975-10 untouched replaces an earlier refused record (F-975-02)" \
		"$({ [ "$RC" = 0 ] && record_is untouched && reason_ok; } && echo 0 || echo 1)" "$(cat "$REC")"
	# created and refused always overwrite.
	for old in created untouched refused; do
		setup
		cluster; old_record "$old"; : > "$PENDING"
		gate post
		ok "TC-975-10 created overwrites an earlier $old record" "$(yes_if record_is created)" "$(cat "$REC")"
		setup
		: > "$IDENT/armed"; old_record "$old"
		gate pre
		ok "TC-975-10 refused overwrites an earlier $old record" "$({ [ "$RC" = 1 ] && record_is refused; } && echo 0 || echo 1)" "$(cat "$REC")"
	done
	# boot_id - when unreadable.
	setup
	: > "$IDENT/armed"
	gate pre RASPUTIN_IDDBGATE_BOOTID="$W/no-such-bootid"
	ok "TC-975-10 an unreadable boot id is recorded as -" "$(yes_if test "$(field boot_id)" = -)" "$(cat "$REC")"
	# An unwritable record directory: exit 1 on every refusal, both lines out.
	for why in armed post; do
		setup
		mkdir -p "$RUN"; chmod 0500 "$RUN"
		if [ "$why" = armed ]; then
			: > "$IDENT/armed"
			gate pre
		else
			chmod 0700 "$RUN"; : > "$PENDING"; chmod 0500 "$RUN"
			gate post
		fi
		chmod 0700 "$RUN"
		ok "TC-975-10 an unwritable record directory ($why): still exit 1, no record" "$(yes_if test "$RC" = 1 -a ! -e "$REC")" "rc=$RC $OUT"
		ok "TC-975-10 an unwritable record directory ($why): outcome_record's <3> and the gate's <2> line both on stdout" \
			"$({ logged 3 identity-db-init-gate 'could not be written' && logged 2 identity-db-init-gate 'outcome=refused'; } && echo 0 || echo 1)" "$OUT"
	done

	# --- TC-975-11: the init step -----------------------------------------------
	setup
	cluster
	init
	ok "TC-975-11 data present: exit 0, neither fake runs" \
		"$(yes_if test "$RC" = 0 -a ! -e "$F/initdb.argv" -a ! -e "$F/postgres.argv")" "rc=$RC $OUT"
	for st in missing nonempty link; do
		setup
		case "$st" in
			nonempty) mkdir "$DINIT"; : > "$DINIT/x" ;;
			link) mkdir "$W/victim"; ln -s "$W/victim" "$DINIT" ;;
		esac
		init
		ok "TC-975-11 data.init $st: exit 1, a <3> 'not permitted' line, initdb never runs" \
			"$({ [ "$RC" = 1 ] && [ ! -e "$F/initdb.argv" ] && logged 3 identity-db-init 'not permitted'; } && echo 0 || echo 1)" "rc=$RC $OUT"
	done
	for d in empty absent; do
		setup
		[ "$d" = absent ] && rmdir "$DATA"
		mkdir "$DINIT"
		init
		ok "TC-975-11 data $d: exit 0, data holds the staged cluster, no data.init" \
			"$(yes_if test "$RC" = 0 -a -f "$DATA/PG_VERSION" -a -f "$DATA/global/pg_control" -a ! -e "$DINIT")" "rc=$RC $OUT $(cat "$W/stderr")"
		ok "TC-975-11 data $d: a <6> line" "$(yes_if logged 6 identity-db-init 'was created')" "$OUT"
	done
	want_argv=$(printf '%s\n' -D "$DINIT" -U postgres -A reject --no-instructions -E UTF8 \
		--locale-provider=builtin --builtin-locale=C.UTF-8 --locale=C --data-checksums)
	ok "TC-975-11 the initdb argv is exactly the pinned flags" "$(yes_if test "$(cat "$F/initdb.argv")" = "$want_argv")" "$(cat "$F/initdb.argv")"
	ok "TC-975-11 the bootstrap runs as postgres --single -D <db>/data.init postgres" \
		"$(yes_if test "$(cat "$F/postgres.argv")" = "$(printf '%s\n' --single -D "$DINIT" postgres)")" "$(cat "$F/postgres.argv")"
	ok "TC-975-11 the bootstrap stdin creates the keycloak login role and its database" \
		"$({ grep -qxF 'CREATE ROLE keycloak LOGIN;' "$F/postgres.stdin" && grep -qxF 'CREATE DATABASE keycloak OWNER keycloak;' "$F/postgres.stdin"; } && echo 0 || echo 1)" \
		"$(cat "$F/postgres.stdin")"
	ok "TC-975-11 the bootstrap stdin holds no password" "$(yes_if sh -c "! grep -qi password '$F/postgres.stdin'")"
	# initdb fails.
	setup
	mkdir "$DINIT"; echo 3 > "$F/initdb.rc"
	init
	ok "TC-975-11 initdb exits 3: exit 1, a <3> line naming status 3, no rename" \
		"$({ [ "$RC" = 1 ] && logged 3 identity-db-init 'status 3' && [ -d "$DINIT" ] && [ -z "$(ls -A "$DATA")" ] && [ ! -e "$F/postgres.argv" ]; } && echo 0 || echo 1)" "rc=$RC $OUT"
	# the bootstrap fails three ways.
	for mode in rc error notoken; do
		setup
		mkdir "$DINIT"; echo "$mode" > "$F/postgres.mode"
		init
		ok "TC-975-11 the bootstrap ($mode): exit 1, a <3> line, no rename" \
			"$({ [ "$RC" = 1 ] && logged 3 identity-db-init 'bootstrap SQL' && [ -d "$DINIT" ] && [ -z "$(ls -A "$DATA")" ]; } && echo 0 || echo 1)" "rc=$RC $OUT"
	done

	# --- TC-975-12: the stage step ----------------------------------------------
	setup
	stage
	ok "TC-975-12 unarmed: exit 0, the copy is byte-equal" "$(yes_if test "$RC" = 0 -a -f "$STAGED")" "rc=$RC $OUT"
	ok "TC-975-12 unarmed: the copy is byte-equal, 0600, owned by OWNER" \
		"$(yes_if test -f "$STAGED" -a "$(perms "$STAGED")" = -rw------- -a "$(owner "$STAGED")" = "$ME")" "$(ls -l "$STAGED" 2>&1)"
	ok "TC-975-12 unarmed: the copy's bytes equal the baseline's" "$(yes_if cmp -s "$BASELINE" "$STAGED")"
	ok "TC-975-12 unarmed: import is 0700, owned by OWNER, with no .tmp left" \
		"$(yes_if test "$(perms "$IMPORT")" = drwx------ -a "$(owner "$IMPORT")" = "$ME" -a "$(ls -A "$IMPORT")" = realm-baseline.json)" "$(ls -lA "$IMPORT")"
	first=$(fingerprint "$STAGED")
	stage
	ok "TC-975-12 a second run gives the same result (idempotent)" \
		"$(yes_if test "$RC" = 0 -a "$(fingerprint "$STAGED")" = "$first" -a "$(ls -A "$IMPORT")" = realm-baseline.json)" "rc=$RC $OUT"
	# armed: the staged copy removed.
	: > "$IDENT/armed"
	stage
	ok "TC-975-12 armed: exit 0, the staged copy is removed" "$(yes_if test "$RC" = 0 -a ! -e "$STAGED")" "rc=$RC $OUT"
	stage
	ok "TC-975-12 armed with nothing staged: exit 0, nothing written" "$(yes_if test "$RC" = 0 -a -z "$(ls -A "$IMPORT")")" "rc=$RC $OUT"
	# unknown.
	setup
	chmod 0000 "$IDENT"
	stage
	chmod 0700 "$IDENT"
	ok "TC-975-12 unknown: exit 1, a <3> line, nothing staged" \
		"$({ [ "$RC" = 1 ] && logged 3 identity-stage-import 'could not be read' && [ ! -e "$IMPORT" ]; } && echo 0 || echo 1)" "rc=$RC $OUT"
	# baseline unreadable.
	setup
	chmod 0000 "$BASELINE"
	stage
	ok "TC-975-12 baseline unreadable: exit 1, a <3> line, nothing written" \
		"$({ [ "$RC" = 1 ] && logged 3 identity-stage-import 'cannot be read' && [ ! -e "$IMPORT" ]; } && echo 0 || echo 1)" "rc=$RC $OUT"
	# keycloak/data missing.
	setup
	rmdir "$KCDATA"
	stage
	ok "TC-975-12 keycloak/data missing: exit 1, a <3> line, nothing created" \
		"$({ [ "$RC" = 1 ] && logged 3 identity-stage-import 'missing or not a real directory' && [ ! -e "$KCDATA" ]; } && echo 0 || echo 1)" "rc=$RC $OUT"
	# Planted links (F-975-01): a scratch "root" directory and file as targets.
	for plant in data import final tmp; do
		for arm in unarmed armed; do
			setup
			[ "$arm" = armed ] && : > "$IDENT/armed"
			RD="$W/rootdir"
			mkdir "$RD"; printf 'root-owned\n' > "$RD/file"; chmod 0640 "$RD/file"
			before=$(fingerprint "$RD/file")
			case "$plant" in
				data) rmdir "$KCDATA"; ln -s "$RD" "$KCDATA" ;;
				import) ln -s "$RD" "$IMPORT" ;;
				final) mkdir "$IMPORT"; ln -s "$RD/file" "$STAGED" ;;
				tmp) mkdir "$IMPORT"; ln -s "$RD/file" "$STAGED.tmp" ;;
			esac
			stage
			ok "TC-975-12 $plant planted as a symlink ($arm): the target's bytes, mode and owner are unchanged, nothing added beside it" \
				"$(yes_if test "$(fingerprint "$RD/file")" = "$before" -a "$(ls -A "$RD")" = file)" "rc=$RC $OUT"
			if [ "$plant" = tmp ]; then
				# Unlinked by rm -f and replaced by the copy's own regular file.
				if [ "$arm" = unarmed ]; then
					ok "TC-975-12 tmp planted ($arm): exit 0, the staged copy is a regular byte-equal file, no .tmp left" \
						"$(yes_if test "$RC" = 0 -a ! -L "$STAGED" -a -f "$STAGED" -a ! -e "$STAGED.tmp" -a ! -L "$STAGED.tmp")" "rc=$RC $OUT"
				else
					ok "TC-975-12 tmp planted ($arm): exit 0" "$(yes_if test "$RC" = 0)" "rc=$RC $OUT"
				fi
			else
				ok "TC-975-12 $plant planted as a symlink ($arm): exit 1 with a <3> line, the link left in place" \
					"$({ [ "$RC" = 1 ] && logged 3 identity-stage-import 'not' && link_kept; } && echo 0 || echo 1)" "rc=$RC $OUT"
			fi
		done
	done
	# import a regular file, the staged name a directory: wrong types refused.
	setup
	: > "$IMPORT"
	stage
	ok "TC-975-12 import a regular file: exit 1" "$(yes_if test "$RC" = 1 -a -f "$IMPORT")" "rc=$RC $OUT"
	setup
	mkdir -p "$STAGED"
	stage
	ok "TC-975-12 the staged name a directory: exit 1, left as it is" "$(yes_if test "$RC" = 1 -a -d "$STAGED")" "rc=$RC $OUT"
done

echo "identity-db-init-test: $pass passed, $fail failed (shells:$TEST_SHELLS)"
[ "$fail" -eq 0 ]
