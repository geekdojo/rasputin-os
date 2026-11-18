#!/bin/sh
#
# Tests for rasputin-keycloak-recover-admin.sh, the identity service's admin
# recovery command (geekdojo/geekdojo-brain#1131, TC-1131-06 to TC-1131-10).
#
# Why. The launcher decides who kc.sh bootstrap-admin runs as, with which
# credentials and sandbox, and where the temporary client secret goes. A
# lifecycle key carried into the transient unit, a [Service] line dropped, a
# secret on argv, or a refusal that still starts the unit is silent until a
# control plane runs a recovery. So both modes run here against stubs, and the
# stubs' records are checked.
#
# How. The real script runs with its collaborators pointed at stubs through
# RASPUTIN_KCRECOVER_*: a systemctl that prints a `systemctl cat` fixture, a
# systemd-run and a kc.sh that record argv, environment and stdin. No root,
# no systemd: what systemd and Keycloak do with the launcher is
# test/identity-unit-functional.sh, scenarios 39 and 40.
#
# Shells. Every case runs under each shell in TEST_SHELLS (default: whichever
# of sh, dash and bash are installed), under `busybox sh`, and under
# `busybox sh` with busybox's own applets ahead of PATH, so the image's id is
# the one exercised. REQUIRE_BUSYBOX=1 (CI sets it) makes a missing busybox a
# failure (F-1131-02).
#
# Root. The suite refuses to run as root, with a failure and not a skip: the
# exec cases must run as a uid other than 0, as the unit's keycloak user does.
#
# Run:  sh test/identity-recover-admin-test.sh
set -u
LC_ALL=C
export LC_ALL

if [ "$(id -u)" = 0 ]; then
	echo "FAILED: this suite must not run as root, because the exec mode refuses root and its cases would prove nothing." >&2
	exit 1
fi
if [ "${REQUIRE_BUSYBOX:-0}" = "1" ] && ! command -v busybox >/dev/null 2>&1; then
	echo "FAILED: REQUIRE_BUSYBOX=1 but busybox is not installed." >&2
	exit 1
fi

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/board/rasputin/common/rootfs-overlay/usr/lib/rasputin/identity/rasputin-keycloak-recover-admin.sh"
[ -f "$SCRIPT" ] || { echo "FAILED: the file $SCRIPT is missing." >&2; exit 1; }
SELF=/usr/lib/rasputin/identity/rasputin-keycloak-recover-admin.sh

if [ -z "${TEST_SHELLS:-}" ]; then
	TEST_SHELLS=""
	for s in sh dash bash; do
		command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"
	done
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BUSYBOX_DIR=""
# An id that cannot run, first on PATH for TC-1131-10's "id fails" case.
mkdir -p "$TMP/id-fails"
printf '#!/bin/sh\necho "id: cannot find name for user ID" >&2\nexit 1\n' > "$TMP/id-fails/id"
chmod 0755 "$TMP/id-fails/id"
if command -v busybox >/dev/null 2>&1; then
	BUSYBOX_DIR="$TMP/busybox-applets"
	mkdir -p "$BUSYBOX_DIR"
	printf '#!/bin/sh\nexec busybox id "$@"\n' > "$BUSYBOX_DIR/id"
	chmod 0755 "$BUSYBOX_DIR/id"
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

# The stubs. systemctl prints $FAKE_DIR/cat for `cat keycloak.service` and
# exits with $FAKE_DIR/systemctl-rc (0 when absent). systemd-run and kc.sh
# record their argv one element per line, their environment, and their stdin,
# and exit with $FAKE_DIR/rc. kc.sh also records the variable --client-secret:env
# names.
FAKES="$TMP/fakes"
mkdir -p "$FAKES"
cat > "$FAKES/systemctl" <<'EOF'
#!/bin/sh
F=$FAKE_DIR
for a in "$@"; do printf '%s\n' "$a"; done > "$F/systemctl-argv"
[ "$1 $2" = "cat keycloak.service" ] && cat "$F/cat"
exit "$(cat "$F/systemctl-rc" 2>/dev/null || echo 0)"
EOF
cat > "$FAKES/systemd-run" <<'EOF'
#!/bin/sh
F=$FAKE_DIR
for a in "$@"; do printf '%s\n' "$a"; done > "$F/run-argv"
env > "$F/run-env"
cat > "$F/run-stdin"
exit "$(cat "$F/rc")"
EOF
cat > "$FAKES/kc.sh" <<'EOF'
#!/bin/sh
F=$FAKE_DIR
for a in "$@"; do printf '%s\n' "$a"; done > "$F/kc-argv"
env > "$F/kc-env"
printf '%s' "${RASPUTIN_RECOVER_CLIENT_SECRET-<unset>}" > "$F/kc-secret"
exit "$(cat "$F/rc")"
EOF
chmod 0755 "$FAKES/systemctl" "$FAKES/systemd-run" "$FAKES/kc.sh"

# The `systemctl cat` fixture: the main file and two drop-ins, each with
# [Unit], [Service] and [Install], # and ; comments and blank lines; every
# lifecycle key; a quoted Environment=, an empty LoadCredential= and
# TimeoutStopSec= (a near-name of TimeoutStartSec that is carried).
cat > "$TMP/cat.fixture" <<'EOF'
# /etc/systemd/system/keycloak.service
[Unit]
Description=Rasputin identity service
Requires=keycloak-db.service

[Service]
# a comment
Type=exec
User=keycloak
Group=keycloak
SuccessExitStatus=143
TimeoutStartSec=1h
Environment=JAVA_HOME=/usr/lib/temurin-jre
Environment="A=-x -y"
ExecStartPre=+/usr/lib/rasputin/identity/rasputin-keycloak-hooks.sh hold
ExecStart=/usr/lib/keycloak/bin/kc.sh start --optimized
ExecStartPost=+/usr/lib/rasputin/identity/rasputin-keycloak-hooks.sh wait
ExecStopPost=-+/usr/lib/rasputin/identity/rasputin-keycloak-hooks.sh exit
LoadCredential=server.pem:/var/lib/rasputin/tls/identity-server/leaf.pem
Restart=always
; another comment
ProtectSystem=strict
DeviceAllow=/dev/kmsg w
CapabilityBoundingSet=
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target

# /etc/systemd/system/keycloak.service.d/10-a.conf
[Unit]
After=other.service
[Service]
LoadCredential=
LoadCredential=mesh-ca.pem:/var/lib/rasputin/trust/mesh-ca.pem
Environment=RASPUTIN_KCHOOK_KMSG=/run/kchook-console
Restart=no
[Install]
Alias=kc.service

# /etc/systemd/system/keycloak.service.d/20-b.conf
[Service]
; drop-in comment
MemoryMax=832M
ExecStart=
[Install]
WantedBy=other.target
EOF
# The -p lines the launcher must pass, in order.
WANT_P='User=keycloak
Group=keycloak
Environment=JAVA_HOME=/usr/lib/temurin-jre
Environment="A=-x -y"
LoadCredential=server.pem:/var/lib/rasputin/tls/identity-server/leaf.pem
ProtectSystem=strict
CapabilityBoundingSet=
TimeoutStopSec=30
LoadCredential=
LoadCredential=mesh-ca.pem:/var/lib/rasputin/trust/mesh-ca.pem
Environment=RASPUTIN_KCHOOK_KMSG=/run/kchook-console
MemoryMax=832M'
# want_run_argv CLIENT — the exact systemd-run argv for CLIENT.
want_run_argv() {
	printf '%s\n' --quiet --pipe --wait --collect --service-type=exec --unit=rasputin-keycloak-recover-admin
	printf '%s\n' "$WANT_P" | while IFS= read -r l; do printf -- '-p\n%s\n' "$l"; done
	printf '%s\n' -- "$SELF" exec "$1"
}
SECRET="tc1131-$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"

# setup — a fresh scratch tree with the fixture and status 0.
setup() {
	W=$(mktemp -d "$TMP/w.XXXXXX")
	F="$W/fake"
	mkdir -p "$F"
	cp "$TMP/cat.fixture" "$F/cat"
	echo 0 > "$F/rc"
}

# launch MODE [ARG] — exec the script under $SH with an exact environment
# (as the api passes one), the stubs and any VAR=VALUE in $EXTRA. Called in a
# subshell, so its process is the script's; stdin is the caller's.
EXTRA=""
PATH_FIRST=""
launch() {
	# Each shell named in full, so one outside the exact PATH is still found.
	case "$SH" in
		busybox_sh|busybox_applets) _cmd="$(command -v busybox) sh" ;;
		*) _cmd=$(command -v "$SH") ;;
	esac
	_path=/usr/bin:/bin
	[ "$SH" = busybox_applets ] && _path="$BUSYBOX_DIR:$_path"
	[ -n "$PATH_FIRST" ] && _path="$PATH_FIRST:$_path"
	# shellcheck disable=SC2086 # _cmd is "busybox sh" on purpose; EXTRA is VAR=VALUE words
	exec env -i PATH="$_path" FAKE_DIR="$F" \
		RASPUTIN_KCRECOVER_SYSTEMCTL="$FAKES/systemctl" RASPUTIN_KCRECOVER_SYSTEMD_RUN="$FAKES/systemd-run" \
		RASPUTIN_KCRECOVER_KCSH="$FAKES/kc.sh" $EXTRA \
		$_cmd "$SCRIPT" "$@"
}
# go INPUT MODE [ARG] — launch with INPUT on stdin ("<eof>" for none); stdout,
# stderr and status apart.
go() {
	_in=$1; shift
	if [ "$_in" = "<eof>" ]; then
		(launch "$@") < /dev/null > "$W/stdout" 2> "$W/stderr"
	else
		printf '%s' "$_in" | (launch "$@") > "$W/stdout" 2> "$W/stderr"
	fi
	RC=$?
}
# one_sentence — stderr is exactly one line, a capital letter to a full stop,
# with no secret, and stdout is empty.
one_sentence() {
	[ "$(grep -c '' "$W/stderr")" = 1 ] && grep -qE '^[A-Z].*\.$' "$W/stderr" \
		&& ! grep -qF -- "$SECRET" "$W/stderr" && [ ! -s "$W/stdout" ]
}
# leaks FILE... — how many of FILE hold $SECRET.
leaks() { _n=0; for _f in "$@"; do [ -f "$_f" ] && grep -qF -- "$SECRET" "$_f" && _n=$((_n + 1)); done; echo "$_n"; }

for SH in $TEST_SHELLS; do
	echo "under $SH"

	# --- run --------------------------------------------------------------------
	# TC-1131-06: the [Service] lines, drop-ins included, in order, no lifecycle
	# key, no [Unit] or [Install] line, no comment.
	setup
	go "$SECRET
" run rasputin-recover-t6
	ok "TC-1131-06 run exits with systemd-run's status 0" "$(yes_if test "$RC" = 0)" "rc=$RC $(cat "$W/stderr")"
	ok "TC-1131-06 systemctl was asked for exactly 'cat keycloak.service'" \
		"$(yes_if test "$(cat "$F/systemctl-argv")" = "cat
keycloak.service")" "$(cat "$F/systemctl-argv")"
	want=$(want_run_argv rasputin-recover-t6)
	got=$(cat "$F/run-argv" 2>/dev/null)
	ok "TC-1131-06 systemd-run's argv is exactly the fixed options, -p per carried line in file order, then -- $SELF exec" \
		"$(yes_if test "$got" = "$want")" "$(printf 'got:\n%s\nwant:\n%s' "$got" "$want" | tr '\n' '|')"
	bad=$(grep -E '^(Type|ExecStart|ExecStartPre|ExecStartPost|ExecStopPost|Restart|SuccessExitStatus|TimeoutStartSec|DeviceAllow)=' "$F/run-argv" || true)
	ok "TC-1131-06 no lifecycle key is passed" "$(yes_if test -z "$bad")" "$bad"
	bad=$(grep -E '^(Description|Requires|After|WantedBy|Alias)=|^[#;]|^\[' "$F/run-argv" || true)
	ok "TC-1131-06 no [Unit] or [Install] line and no comment is passed" "$(yes_if test -z "$bad")" "$bad"

	# TC-1131-07: stdin passes through byte for byte; the status is
	# systemd-run's; the secret is in no argv, environment or output.
	for want_rc in 0 3; do
		setup
		echo "$want_rc" > "$F/rc"
		go "$SECRET
" run rasputin-recover-t7
		printf '%s\n' "$SECRET" > "$W/want-stdin"
		ok "TC-1131-07 (status $want_rc) systemd-run's stdin is the secret and a newline, byte for byte" \
			"$(yes_if cmp -s "$W/want-stdin" "$F/run-stdin")"
		ok "TC-1131-07 (status $want_rc) the launcher exits with systemd-run's status" "$(yes_if test "$RC" = "$want_rc")" "rc=$RC"
		n=$(leaks "$F/run-argv" "$F/run-env" "$F/systemctl-argv" "$W/stdout" "$W/stderr")
		ok "TC-1131-07 (status $want_rc) the secret is in no argv, environment, stdout or stderr ($n found)" "$(yes_if test "$n" = 0)"
	done

	# TC-1131-08: each refusal exits 2 with one sentence and never starts the
	# unit.
	for case in "no client id" "empty client id" "systemctl fails" "no User="; do
		setup
		arg=rasputin-recover-t8
		case "$case" in
			"no client id") go "$SECRET
" run ;;
			"empty client id") go "$SECRET
" run "" ;;
			"systemctl fails") echo 1 > "$F/systemctl-rc"; go "$SECRET
" run "$arg" ;;
			"no User=") grep -v '^User=' "$TMP/cat.fixture" > "$F/cat"; go "$SECRET
" run "$arg" ;;
		esac
		ok "TC-1131-08 $case: exit 2" "$(yes_if test "$RC" = 2)" "rc=$RC"
		ok "TC-1131-08 $case: one sentence on stderr, no secret" "$(yes_if one_sentence)" "$(cat "$W/stderr" "$W/stdout")"
		ok "TC-1131-08 $case: systemd-run was never called" "$(yes_if test ! -e "$F/run-argv")"
	done

	# --- exec -------------------------------------------------------------------
	# TC-1131-09: kc.sh gets the exact argv and the secret in its environment
	# only; its status is the launcher's. No uid seam: the real id runs.
	for want_rc in 0 5; do
		setup
		echo "$want_rc" > "$F/rc"
		go "$SECRET
" exec rasputin-recover-t9
		want="--config-file=/etc/rasputin/identity/keycloak.conf
bootstrap-admin
service
--optimized
--no-prompt
--client-id
rasputin-recover-t9
--client-secret:env
RASPUTIN_RECOVER_CLIENT_SECRET"
		ok "TC-1131-09 (status $want_rc) kc.sh's argv is exactly bootstrap-admin service with --client-secret:env" \
			"$(yes_if test "$(cat "$F/kc-argv" 2>/dev/null)" = "$want")" "$(tr '\n' ' ' < "$F/kc-argv" 2>&1)"
		ok "TC-1131-09 (status $want_rc) kc.sh saw RASPUTIN_RECOVER_CLIENT_SECRET equal to the secret" \
			"$(yes_if test "$(cat "$F/kc-secret" 2>/dev/null)" = "$SECRET")"
		n=$(leaks "$F/kc-argv" "$W/stdout" "$W/stderr")
		ok "TC-1131-09 (status $want_rc) the secret is in none of kc.sh's argv and no output ($n found)" "$(yes_if test "$n" = 0)"
		ok "TC-1131-09 (status $want_rc) the launcher exits with kc.sh's status" "$(yes_if test "$RC" = "$want_rc")" "rc=$RC"
	done

	# TC-1131-10: exec refuses empty input, no client id, root and an unknown
	# uid. "uid not numeric" proves the guard's non-numeric arm on every shell.
	# "id fails" plants a failing id on PATH, which only takes effect where the
	# shell runs id from PATH: busybox built to prefer its own applets runs its
	# id applet whatever PATH says (F-1131-19), so that row is dash and bash only.
	cases='"stdin at EOF" "an empty line" "no client id" "uid 0" "uid not numeric"'
	case "$SH" in
		busybox_sh | busybox_applets) ;;
		*) cases="$cases \"id fails\"" ;;
	esac
	eval "set -- $cases"
	for case in "$@"; do
		setup
		EXTRA=""
		PATH_FIRST=""
		case "$case" in
			"stdin at EOF") go "<eof>" exec rasputin-recover-t10 ;;
			"an empty line") go "
" exec rasputin-recover-t10 ;;
			"no client id") go "$SECRET
" exec ;;
			"uid 0") EXTRA=RASPUTIN_KCRECOVER_UID=0; go "$SECRET
" exec rasputin-recover-t10 ;;
			"uid not numeric") EXTRA=RASPUTIN_KCRECOVER_UID=unknown; go "$SECRET
" exec rasputin-recover-t10 ;;
			# F-1131-13: id cannot run and the uid seam is unset, so the uid is
			# unknown; the guard must refuse, not read the empty value as non-root.
			"id fails") PATH_FIRST="$TMP/id-fails"; go "$SECRET
" exec rasputin-recover-t10 ;;
		esac
		EXTRA=""
		PATH_FIRST=""
		ok "TC-1131-10 $case: exit 2" "$(yes_if test "$RC" = 2)" "rc=$RC"
		ok "TC-1131-10 $case: one sentence on stderr, no secret" "$(yes_if one_sentence)" "$(cat "$W/stderr" "$W/stdout")"
		ok "TC-1131-10 $case: kc.sh never ran" "$(yes_if test ! -e "$F/kc-argv")"
	done
done

echo
echo "identity-recover-admin-test: $pass passed, $fail failed (shells:$TEST_SHELLS)"
[ "$fail" -eq 0 ]
