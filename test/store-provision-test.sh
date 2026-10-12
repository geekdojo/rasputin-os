#!/bin/sh
#
# Tests for rasputin-store-provision.sh, the oneshot that adds a later
# release's kv-v2 mounts and cert roles to the secrets store through the
# store's provisioner identity (geekdojo/geekdojo-brain#805, TC-805-16 to
# TC-805-23).
#
# Why. The oneshot holds rasputin-api.service while it runs, waits on the
# store's own unseal facts, and is the only writer of mounts and roles after
# self-init. A parse that lets a bad item through, a wait that ends on a timer
# when bao already said why, a writer left running after a decision, a write
# sent when the item is present, or a token in a log line would each be silent.
# So every branch runs against a scratch tree, with fakes for every
# collaborator that record each call.
#
# How. The real script runs with every collaborator pointed at scratch files
# through RASPUTIN_STOREPROV_*: a fake bao (RASPUTIN_STOREPROV_BAO), a fake
# journal source (RASPUTIN_STOREPROV_JOURNAL) and a fake systemctl first on
# PATH. Each records its argv. No root, no systemd, no store: what systemd and
# the real bao do is test/store-unit-functional.sh.
#
# Shells. Every case runs under each shell in TEST_SHELLS (default: whichever
# of sh, dash and bash are installed), under `busybox sh`, and under
# `busybox sh` with busybox's own applets ahead of PATH, as
# test/store-init-outcome-test.sh does. REQUIRE_BUSYBOX=1 (CI sets it) makes a
# missing busybox a failure.
#
# Root. The suite refuses to run as root, with a failure and not a skip: root
# reads a mode-000 file, so the unreadable-file case would pass over nothing.
#
# Durations. RASPUTIN_STOREPROV_UNSEAL_BOUND is 1 in the cases that reach the
# bound, and 37 in the cases that must end before it, so a leftover bound
# sleeper is `sleep 37` and nothing else. The one case that must prove the
# wait lasted the whole bound uses 2: in whole seconds a run of 2 s or more
# reads 2 or more, and one that ended under a second reads 1 at most. The fake health ask honours
# BAO_CLIENT_TIMEOUT as the real client does.
#
# Run:  sh test/store-provision-test.sh
set -u
LC_ALL=C
export LC_ALL

if [ "$(id -u)" = 0 ]; then
	echo "FAILED: this suite must not run as root, because root reads a mode-000 file and the unreadable-file case would prove nothing." >&2
	exit 1
fi
if [ "${REQUIRE_BUSYBOX:-0}" = "1" ] && ! command -v busybox >/dev/null 2>&1; then
	echo "FAILED: REQUIRE_BUSYBOX=1 but busybox is not installed." >&2
	exit 1
fi
command -v ps >/dev/null 2>&1 || { echo "FAILED: this suite needs ps, to show no writer outlives a decision." >&2; exit 1; }

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
SCRIPT="$OVERLAY/usr/lib/rasputin/store-provision/rasputin-store-provision.sh"
LIB="$OVERLAY/usr/lib/rasputin/outcome/outcome.sh"
SHIPPED="$OVERLAY/etc/rasputin/openbao/provision.tsv"
for f in "$SCRIPT" "$LIB" "$SHIPPED"; do
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
	for applet in cat rm mv chmod mkdir dirname sed grep tr cut mktemp mkfifo sleep; do
		printf '#!/bin/sh\nexec busybox %s "$@"\n' "$applet" > "$BUSYBOX_DIR/$applet"
		chmod 0755 "$BUSYBOX_DIR/$applet"
	done
	TEST_SHELLS="$TEST_SHELLS busybox_sh busybox_applets"
fi

# --- the fakes -----------------------------------------------------------------
BIN="$TMP/bin"
mkdir -p "$BIN"
# systemctl: records its argv; `show -p InvocationID` prints FAKE_INVOCATION_ID.
cat > "$BIN/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_LOG/systemctl"
case "$*" in "show -p InvocationID --value "*) printf '%s\n' "$FAKE_INVOCATION_ID" ;; esac
EOF
# The journal source: records its argv and pid, then prints the case's lines
# (after FAKE_JOURNAL_DELAY seconds, when set) and follows forever, or, for
# FAKE_JOURNAL=down, exits 1 at once.
cat > "$BIN/journal" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_LOG/journal"
printf '%s\n' "$$" > "$FAKE_LOG/journal.pid"
[ "${FAKE_JOURNAL:-}" = down ] && exit 1
[ -n "${FAKE_JOURNAL_DELAY:-}" ] && sleep "$FAKE_JOURNAL_DELAY"
[ -f "$FAKE_STATE/journal" ] && cat "$FAKE_STATE/journal"
exec sleep 1000
EOF
# bao: records each call's argv on one line, and whether the call saw the
# client settings and the login's token in its environment (never the token
# itself). State (mounts, roles) lives under FAKE_STATE.
cat > "$BIN/bao" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_LOG/bao"
_tok=none
[ -n "${BAO_TOKEN:-}" ] && { [ "$BAO_TOKEN" = "$FAKE_TOKEN" ] && _tok=login || _tok=other; }
printf '%s timeout=%s retries=%s addr=%s cacert=%s cert=%s key=%s token=%s\n' "$1" "${BAO_CLIENT_TIMEOUT:-}" "${BAO_MAX_RETRIES:-}" \
	"${BAO_ADDR:-}" "${BAO_CACERT:-}" "${BAO_CLIENT_CERT:-}" "${BAO_CLIENT_KEY:-}" "$_tok" >> "$FAKE_LOG/bao.env"
case "$1 ${2:-}" in
	"read sys/health")
		case "$FAKE_HEALTH" in
			200) exit 0 ;;
			hang) sleep "${BAO_CLIENT_TIMEOUT%s}"; echo 'Error reading sys/health: context deadline exceeded' >&2; exit 2 ;;
			*) printf 'Error reading sys/health: Error making API request.\n\nCode: 503. Raw Message:\n' >&2; exit 2 ;;
		esac ;;
	"login -method=cert")
		[ "$FAKE_LOGIN" = ok ] && { printf '%s' "$FAKE_TOKEN"; exit 0; }
		printf 'Error authenticating: Error making API request.\n\nURL: PUT https://127.0.0.1:8200/v1/auth/cert/login\nCode: 403. Errors:\n\n* permission denied\n' >&2
		exit 2 ;;
	"read sys/mounts/"*)
		[ -e "$FAKE_STATE/mount-${2#sys/mounts/}" ] && { printf 'Key Value\ntype kv\n'; exit 0; }
		if [ "$FAKE_MOUNT_READ" = error ]; then
			printf 'Error reading %s: Error making API request.\n\nCode: 500. Errors:\n\n* internal error\n' "$2" >&2; exit 2
		fi
		printf 'Error reading %s: Error making API request.\n\nCode: 400. Errors:\n\n* No secret engine mount at %s/\n' "$2" "${2#sys/mounts/}" >&2
		exit 2 ;;
	"write sys/mounts/"*|"write auth/cert/certs/"*)
		case " $FAKE_REFUSE " in *" $2 "*)
			printf 'Error writing data to %s: Error making API request.\n\nCode: 403. Errors:\n\n* permission denied\n' "$2" >&2; exit 2 ;;
		esac
		case "$2" in
			sys/mounts/*) : > "$FAKE_STATE/mount-${2#sys/mounts/}" ;;
			*) printf '%s\n' "${2#auth/cert/certs/}" >> "$FAKE_STATE/roles" ;;
		esac
		exit 0 ;;
	"list auth/cert/certs")
		[ "$FAKE_LIST" = error ] && { printf 'Error listing auth/cert/certs: Code: 500.\n' >&2; exit 2; }
		printf 'Keys\n----\n'
		cat "$FAKE_STATE/roles" 2>/dev/null
		exit 0 ;;
esac
echo "fake bao: unexpected call: $*" >&2
exit 99
EOF
chmod 0755 "$BIN/systemctl" "$BIN/journal" "$BIN/bao"

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
contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
perms() { ls -ld "$1" 2>/dev/null | cut -c1-10; }
res() { sed -n "s/^$1=//p" "$WORK/result" 2>/dev/null; }
rec() { sed -n "s/^$1=//p" "$RUN/outcome" 2>/dev/null; }
calls() { [ -f "$LOG/$1" ] && grep -c '' "$LOG/$1" || echo 0; }
TAG=rasputin-store-provision
TOKEN=s.FAKEtoken0123456789abcdef
INV=0123456789abcdef0123456789abcdef
OK_LINE='2026-10-12T00:00:01.000Z [INFO]  core: unsealed with stored key'
NONE_LINE='2026-10-12T00:00:00.500Z [WARN]  failed to unseal core: error="stored unseal keys are supported, but none were found: is the server initialized?"'

# setup — a fresh scratch tree: the record directory absent (pre makes it), the
# work directory present (systemd's RuntimeDirectory), one valid item, the
# credentials, a boot id, a console file and empty fake state.
setup() {
	W=$(mktemp -d "$TMP/w.XXXXXX")
	RUN="$W/run" WORK="$W/work" CONFIG="$W/provision.tsv" CREDS="$W/creds" LOG="$W/log" STATE="$W/state"
	mkdir -p "$WORK" "$CREDS" "$LOG" "$STATE"
	printf 'role\trasputin-rel-x\trasputin-bindable\n' > "$CONFIG"
	: > "$CREDS/store-ca.pem"; : > "$CREDS/provisioner.pem"; : > "$CREDS/provisioner.key"
	BOOT_ID="b00710d0-0000-4000-8000-000000000805"
	printf '%s\n' "$BOOT_ID" > "$W/bootid"
	: > "$W/kmsg"
	FAKE_INVOCATION_ID=$INV FAKE_JOURNAL="" FAKE_JOURNAL_DELAY="" FAKE_HEALTH=503 FAKE_LOGIN=ok
	FAKE_MOUNT_READ="" FAKE_REFUSE="" FAKE_LIST="" BOUND=37
}
journal_says() { printf '%s\n' "$@" > "$STATE/journal"; }

# run PHASE [VAR=VALUE ...] — the script under $SH with every collaborator in
# the scratch tree; stdout, stderr, status and whole seconds taken apart.
run() {
	_phase=$1; shift
	case "$SH" in
		busybox_sh|busybox_applets) _cmd="busybox sh" ;;
		*) _cmd=$SH ;;
	esac
	_path="$BIN:$PATH"
	[ "$SH" = busybox_applets ] && _path="$BIN:$BUSYBOX_DIR:$PATH"
	_t0=$(date +%s)
	# shellcheck disable=SC2086 # _cmd is "busybox sh" on purpose
	env PATH="$_path" RASPUTIN_STOREPROV_RUN="$RUN" RASPUTIN_STOREPROV_WORK="$WORK" \
		RASPUTIN_STOREPROV_CONFIG="$CONFIG" RASPUTIN_STOREPROV_CREDS="$CREDS" RASPUTIN_STOREPROV_BAO="$BIN/bao" \
		RASPUTIN_STOREPROV_JOURNAL="$BIN/journal" RASPUTIN_STOREPROV_BOOTID="$W/bootid" RASPUTIN_STOREPROV_KMSG="$W/kmsg" \
		RASPUTIN_STOREPROV_UNSEAL_BOUND="$BOUND" FAKE_LOG="$LOG" FAKE_STATE="$STATE" FAKE_TOKEN="$TOKEN" \
		FAKE_INVOCATION_ID="$FAKE_INVOCATION_ID" FAKE_JOURNAL="$FAKE_JOURNAL" FAKE_JOURNAL_DELAY="$FAKE_JOURNAL_DELAY" \
		FAKE_HEALTH="$FAKE_HEALTH" FAKE_LOGIN="$FAKE_LOGIN" FAKE_MOUNT_READ="$FAKE_MOUNT_READ" FAKE_REFUSE="$FAKE_REFUSE" \
		FAKE_LIST="$FAKE_LIST" "$@" \
		$_cmd "$SCRIPT" "$_phase" > "$W/stdout" 2> "$W/stderr"
	RC=$?
	EL=$(( $(date +%s) - _t0 ))
	OUT=$(cat "$W/stdout")
	# Every output of every run, for TC-805-23's search.
	cat "$W/stdout" "$W/stderr" "$WORK/result" "$RUN/outcome" "$W/kmsg" "$LOG"/* >> "$TMP/all-outputs" 2>/dev/null
}

# no_writers LABEL — no journal source, bound sleeper or health ask survives
# the run, and the fifo is gone.
no_writers() {
	_jp=$(cat "$LOG/journal.pid" 2>/dev/null)
	_alive=""
	[ -n "$_jp" ] && kill -0 "$_jp" 2>/dev/null && _alive="journal source $_jp"
	_sl=$(ps -eo args 2>/dev/null | grep -cx 'sleep 37' || true)
	[ "$_sl" -gt 0 ] && _alive="$_alive; $_sl 'sleep 37' bound sleeper(s)"
	_hs=$(ps -eo args 2>/dev/null | awk -v p="$BIN/bao read sys/health" 'index($0, p) && $1 != "awk"' | grep -c '' || true)
	[ "$_hs" -gt 0 ] && _alive="$_alive; $_hs health ask(s)"
	ok "$1: no journal source, bound sleeper or health ask is left" "$(yes_if [ -z "$_alive" ])" "$_alive"
	[ -n "$_jp" ] && kill "$_jp" 2>/dev/null
	_fifo=$(ls -A "$WORK" 2>/dev/null | grep '^\.wait\.' || true)
	ok "$1: the fifo is gone" "$(yes_if [ -z "$_fifo" ])" "left: $_fifo"
}
# count ERE FILE — the lines of FILE matching ERE; 0 when there is no FILE.
count() { _ct=$(grep -cE -- "$1" "$2" 2>/dev/null); echo "${_ct:-0}"; }
health_asks() { count '^read sys/health$' "$LOG/bao"; }
no_login() { ok "$1: no login was made" "$(yes_if [ "$(count '^login' "$LOG/bao")" = 0 ])" "$(cat "$LOG/bao" 2>/dev/null)"; }

# --- TC-805-16: the parse fails closed ------------------------------------------
parse_cases() {
	_tab=$(printf '\t')
	while IFS='|' read -r label text needle; do
		[ -n "$label" ] || continue
		for phase in wait apply; do
			setup
			printf '%b' "$text" > "$CONFIG"
			run "$phase"
			ok "TC-805-16 $label: $phase exits 1" "$(yes_if [ "$RC" = 1 ])" "rc=$RC $OUT $(cat "$W/stderr")"
			ok "TC-805-16 $label: $phase's result is failed" "$(yes_if [ "$(res outcome)" = failed ])" "$(cat "$WORK/result" 2>&1)"
			ok "TC-805-16 $label: $phase's reason names $needle" "$(yes_if contains "$needle" "$(res reason)")" "$(res reason)"
			ok "TC-805-16 $label: $phase made no systemctl, journal or bao call" \
				"$(yes_if [ "$(calls systemctl)$(calls journal)$(calls bao)" = 000 ])" "$(cat "$LOG"/* 2>/dev/null)"
		done
	done <<EOF_CASES
an unknown kind|policy\trasputin-rel-x\n|Line 1 of
a mount with a third field|mount\trasputin-rel-x\textra\n|Line 1 of
a role with two fields|role\trasputin-rel-x\n|Line 1 of
a role with four fields|role\trasputin-rel-x\trasputin-bindable\tx\n|Line 1 of
a duplicate|mount\trasputin-rel-x\n# c\nmount\trasputin-rel-x\n|Line 3 of
a name without the prefix|mount\trasputin-x\n|Line 1 of
the bare prefix|mount\trasputin-rel-\n|Line 1 of
a name with /|mount\trasputin-rel-a/b\n|Line 1 of
a name with a comma|mount\trasputin-rel-a,b\n|Line 1 of
a name with a space|mount\trasputin-rel-a b\n|Line 1 of
a name with an uppercase letter|mount\trasputin-rel-A\n|Line 1 of
a role binding rasputin-api|role\trasputin-rel-x\trasputin-api\n|Line 1 of
a role binding rasputin-seal-rotate|role\trasputin-rel-x\trasputin-seal-rotate\n|Line 1 of
EOF_CASES
	for phase in wait apply; do
		setup; rm -f "$CONFIG"; run "$phase"
		ok "TC-805-16 a missing file: $phase exits 1, failed, naming the file, with no call" \
			"$(yes_if eval '[ "$RC" = 1 ] && [ "$(res outcome)" = failed ] && contains "$CONFIG" "$(res reason)" && [ "$(calls systemctl)$(calls journal)$(calls bao)" = 000 ]')" "rc=$RC $(cat "$WORK/result" 2>&1)"
		setup; chmod 000 "$CONFIG"; run "$phase"
		ok "TC-805-16 an unreadable file: $phase exits 1, failed, naming the file, with no call" \
			"$(yes_if eval '[ "$RC" = 1 ] && [ "$(res outcome)" = failed ] && contains "$CONFIG" "$(res reason)" && [ "$(calls systemctl)$(calls journal)$(calls bao)" = 000 ]')" "rc=$RC $(cat "$WORK/result" 2>&1)"
		chmod 600 "$CONFIG"
	done
	# Comments and blank lines are skipped: one item behind them parses, so
	# apply reaches the store.
	setup
	printf '# a comment\n\n   \n%s\n# another\n' "role${_tab}rasputin-rel-x${_tab}rasputin-bindable" > "$CONFIG"
	run apply
	ok "TC-805-16 comment and blank lines are skipped: the one item is applied" \
		"$(yes_if eval '[ "$RC" = 0 ] && [ "$(res outcome)" = applied ] && [ "$(res changed)" = 1 ]')" "rc=$RC $(cat "$WORK/result" 2>&1) $(cat "$W/stderr")"
	# The shipped file: no entry, so no wait and no store call.
	setup; cp "$SHIPPED" "$CONFIG"; run wait
	ok "TC-805-16 the shipped provision.tsv: wait exits 0 at once with zero fake calls" \
		"$(yes_if eval '[ "$RC" = 0 ] && [ "$EL" -le 1 ] && [ "$(calls systemctl)$(calls journal)$(calls bao)" = 000 ] && [ ! -e "$WORK/result" ]')" "rc=$RC el=$EL $(cat "$LOG"/* 2>/dev/null)"
	run apply
	ok "TC-805-16 the shipped provision.tsv: apply gives unchanged changed=0 with zero bao calls" \
		"$(yes_if eval '[ "$RC" = 0 ] && [ "$(res outcome)" = unchanged ] && [ "$(res changed)" = 0 ] && [ "$(calls bao)" = 0 ]')" "rc=$RC $(cat "$WORK/result" 2>&1)"
}

# --- TC-805-17: the unseal wait ---------------------------------------------------
wait_cases() {
	# The success line, at once (the replay case) and after a delay.
	for delay in "" 1; do
		setup; journal_says "$OK_LINE"; FAKE_JOURNAL_DELAY=$delay
		run wait
		_l="TC-805-17 success line${delay:+ after ${delay}s}"
		ok "$_l: wait exits 0 before the bound" "$(yes_if eval '[ "$RC" = 0 ] && [ "$EL" -lt 10 ]')" "rc=$RC el=$EL $(cat "$WORK/result" 2>&1)"
		ok "$_l: the journal source's argv is exactly the store run's filter" \
			"$(yes_if [ "$(cat "$LOG/journal" 2>/dev/null)" = "--follow --no-tail -o cat _SYSTEMD_INVOCATION_ID=$INV" ])" "$(cat "$LOG/journal" 2>&1)"
		ok "$_l: systemctl was asked the store's InvocationID" \
			"$(yes_if [ "$(cat "$LOG/systemctl" 2>/dev/null)" = "show -p InvocationID --value openbao.service" ])" "$(cat "$LOG/systemctl" 2>&1)"
		ok "$_l: no health ask was made" "$(yes_if [ "$(health_asks)" = 0 ])" "$(cat "$LOG/bao" 2>/dev/null)"
		no_writers "$_l"
		run apply
		ok "$_l: apply then logs in" "$(yes_if grep -q '^login -method=cert -token-only -no-store name=rasputin-provisioner$' "$LOG/bao")" "$(cat "$LOG/bao" 2>&1)"
	done
	# The ignored self-init line, then success.
	setup; journal_says "$NONE_LINE" "$OK_LINE"; run wait
	ok "TC-805-17 none were found, then success: wait ends on success" \
		"$(yes_if eval '[ "$RC" = 0 ] && [ "$EL" -lt 10 ] && [ "$(health_asks)" = 0 ]')" "rc=$RC el=$EL $(cat "$WORK/result" 2>&1)"
	no_writers "TC-805-17 none were found, then success"
	# Every terminal line (F-805-12: by exclusion).
	while IFS='|' read -r label line want; do
		[ -n "$label" ] || continue
		setup; journal_says "$NONE_LINE" "$line"; run wait
		_l="TC-805-17 terminal: $label"
		ok "$_l: wait exits 1 before the bound" "$(yes_if eval '[ "$RC" = 1 ] && [ "$EL" -lt 10 ]')" "rc=$RC el=$EL"
		ok "$_l: the result is failed" "$(yes_if [ "$(res outcome)" = failed ])" "$(cat "$WORK/result" 2>&1)"
		ok "$_l: the reason quotes the line's error text" "$(yes_if contains "$want" "$(res reason)")" "$(res reason)"
		ok "$_l: the reason does not name the bound" "$(yes_if eval '! contains "within" "$(res reason)"')" "$(res reason)"
		ok "$_l: no health ask was made" "$(yes_if [ "$(health_asks)" = 0 ])" "$(cat "$LOG/bao" 2>/dev/null)"
		no_login "$_l"
		no_writers "$_l"
	done <<'EOF_TERM'
fetching stored unseal keys failed|2026-10-12T00:00:01Z [WARN]  failed to unseal core: error="fetching stored unseal keys failed: failed to decrypt keys from storage: unknown key id"|it logged: fetching stored unseal keys failed: failed to decrypt keys from storage: unknown key id)
unseal with stored key failed|2026-10-12T00:00:01Z [WARN]  failed to unseal core: error="unseal with stored key failed: barrier error"|it logged: unseal with stored key failed: barrier error)
expected exactly one stored key|2026-10-12T00:00:01Z [WARN]  failed to unseal core: error="expected exactly one stored key"|it logged: expected exactly one stored key)
vault still sealed after using stored unseal key|2026-10-12T00:00:01Z [WARN]  core: vault still sealed after using stored unseal key|it logged: vault still sealed after using stored unseal key)
error unsealing core|2026-10-12T00:00:01Z [ERROR] error unsealing core: error="self-initialization failed: refusing to unseal"|it logged: self-initialization failed: refusing to unseal)
failed to automatically unseal after initialization|2026-10-12T00:00:01Z [ERROR] core: failed to automatically unseal after initialization with no recovery keys: err="unseal failed"|it logged: unseal failed)
EOF_TERM
	# A dropped success line: nothing logged, health 200 at the bound.
	setup; BOUND=1; FAKE_HEALTH=200; run wait
	ok "TC-805-17 dropped success line: wait exits 0 on the bound's one health ask" \
		"$(yes_if eval '[ "$RC" = 0 ] && [ "$EL" -ge 1 ] && [ "$(health_asks)" = 1 ]')" "rc=$RC el=$EL asks=$(health_asks)"
	ok "TC-805-17 dropped success line: the health ask carried BAO_CLIENT_TIMEOUT=2s and BAO_MAX_RETRIES=0" \
		"$(yes_if grep -q '^read timeout=2s retries=0 ' "$LOG/bao.env")" "$(cat "$LOG/bao.env" 2>&1)"
	no_writers "TC-805-17 dropped success line"
	# No fact: sealed, or a health ask that hangs to its 2 s timeout.
	for h in 503 hang; do
		setup; BOUND=1; FAKE_HEALTH=$h; run wait
		_l="TC-805-17 no fact, health $h"
		ok "$_l: wait exits 1 by the bound + 2 s" "$(yes_if eval '[ "$RC" = 1 ] && [ "$EL" -ge 1 ] && [ "$EL" -le 4 ]')" "rc=$RC el=$EL"
		ok "$_l: the reason names the bound" "$(yes_if contains 'logged no unseal result within 1 s' "$(res reason)")" "$(res reason)"
		ok "$_l: exactly one health ask" "$(yes_if [ "$(health_asks)" = 1 ])" "asks=$(health_asks)"
		no_login "$_l"
		no_writers "$_l"
	done
	# The journal source down at once: no hang, EOF is not success.
	for h in 200 503; do
		setup; BOUND=1; FAKE_JOURNAL=down; FAKE_HEALTH=$h; run wait
		_l="TC-805-17 journal source down, health $h"
		_want=1; [ "$h" = 200 ] && _want=0
		ok "$_l: wait ends by the bound's health ask with $_want" \
			"$(yes_if eval '[ "$RC" = "$_want" ] && [ "$EL" -ge 1 ] && [ "$EL" -le 4 ] && [ "$(health_asks)" = 1 ]')" "rc=$RC el=$EL asks=$(health_asks)"
		no_writers "$_l"
	done
	# F-805-25: a journal source that exits at once must not end the wait
	# early through the fifo's EOF. The wait lasts the whole bound, and only
	# then does the reason name the bound.
	for h in 200 503; do
		setup; BOUND=2; FAKE_JOURNAL=down; FAKE_HEALTH=$h; run wait
		_l="TC-805-17 journal source exits at once, bound 2 s, health $h"
		_want=1; [ "$h" = 200 ] && _want=0
		ok "$_l: wait lasts at least the bound, then ends with $_want on one health ask" \
			"$(yes_if eval '[ "$RC" = "$_want" ] && [ "$EL" -ge 2 ] && [ "$EL" -le 5 ] && [ "$(health_asks)" = 1 ]')" "rc=$RC el=$EL asks=$(health_asks)"
		if [ "$h" = 503 ]; then
			ok "$_l: the reason names the 2 s bound" "$(yes_if contains 'logged no unseal result within 2 s' "$(res reason)")" "$(res reason)"
		fi
		no_writers "$_l"
	done
	# An empty or malformed InvocationID: refused before any journal source.
	for id in "" "zz23456789abcdef0123456789abcdef" "0123456789abcdef" "0123456789ABCDEF0123456789ABCDEF"; do
		setup; FAKE_INVOCATION_ID=$id; run wait
		_l="TC-805-17 InvocationID '$id'"
		ok "$_l: wait exits 1 naming the store's run" \
			"$(yes_if eval '[ "$RC" = 1 ] && contains "current run could not be identified" "$(res reason)"')" "rc=$RC $(res reason)"
		ok "$_l: no journal source was started" "$(yes_if [ "$(calls journal)" = 0 ])" "$(cat "$LOG/journal" 2>&1)"
	done
	# Untrusted text: a terminal line carrying command substitutions runs nothing.
	setup
	journal_says "2026-10-12T00:00:01Z [WARN]  failed to unseal core: error=\"fetching stored unseal keys failed: \$(touch $W/pwned) \`touch $W/pwned2\`\""
	run wait
	ok "TC-805-17 untrusted text: nothing it names was executed" "$(yes_if eval '[ ! -e "$W/pwned" ] && [ ! -e "$W/pwned2" ]')"
	ok "TC-805-17 untrusted text: it reaches the result as text, cut to the error field" \
		"$(yes_if contains "(it logged: fetching stored unseal keys failed: \$(touch $W/pwned) \`touch $W/pwned2\`)" "$(res reason)")" "$(res reason)"
	no_writers "TC-805-17 untrusted text"
	# Every case above made at most one health ask (no interval poll); the
	# count is asserted in each.
}

# --- TC-805-18 to TC-805-21: login, mounts, roles, the outcome ---------------
apply_cases() {
	_tab=$(printf '\t')
	setup; FAKE_LOGIN=refuse; printf 'mount\trasputin-rel-m\nrole\trasputin-rel-x\trasputin-bindable\n' > "$CONFIG"; run apply
	ok "TC-805-18 login refused: failed, exit 1" "$(yes_if eval '[ "$RC" = 1 ] && [ "$(res outcome)" = failed ]')" "rc=$RC"
	ok "TC-805-18 login refused: the reason names the login and its 403" "$(yes_if contains 'could not log in to the secrets store (HTTP 403)' "$(res reason)")" "$(res reason)"
	ok "TC-805-18 login refused: no mount or role call" "$(yes_if [ "$(calls bao)" = 1 ])" "$(cat "$LOG/bao")"
	ok "TC-805-18 the login carried the client settings and the provisioner's credentials" \
		"$(yes_if grep -qx "login timeout=2s retries=0 addr=https://127.0.0.1:8200 cacert=$CREDS/store-ca.pem cert=$CREDS/provisioner.pem key=$CREDS/provisioner.key token=none" "$LOG/bao.env")" "$(cat "$LOG/bao.env")"

	# TC-805-19: a mount present, absent, or a read that errors.
	setup; printf 'mount\trasputin-rel-m\n' > "$CONFIG"; : > "$STATE/mount-rasputin-rel-m"; run apply
	ok "TC-805-19 mount present: no write, unchanged" \
		"$(yes_if eval '[ "$RC" = 0 ] && [ "$(res outcome)" = unchanged ] && ! grep -q "^write" "$LOG/bao"')" "$(cat "$LOG/bao")"
	setup; printf 'mount\trasputin-rel-m\n' > "$CONFIG"; run apply
	ok "TC-805-19 mount absent: exactly write sys/mounts/rasputin-rel-m type=kv-v2, applied changed=1" \
		"$(yes_if eval '[ "$RC" = 0 ] && [ "$(res outcome)" = applied ] && [ "$(res changed)" = 1 ] && [ "$(grep "^write" "$LOG/bao")" = "write sys/mounts/rasputin-rel-m type=kv-v2" ]')" "$(cat "$LOG/bao")"
	ok "TC-805-19 mount absent: one INFO line for the change" "$(yes_if contains "<6>$TAG: added the kv-v2 mount rasputin-rel-m." "$OUT")" "$OUT"
	ok "TC-805-19 calls after login carry the login's token in the environment" \
		"$(yes_if [ "$(count 'token=login' "$LOG/bao.env")" = 2 ])" "$(cat "$LOG/bao.env")"
	setup; printf 'mount\trasputin-rel-m\n' > "$CONFIG"; FAKE_MOUNT_READ=error; run apply
	ok "TC-805-19 mount read errors: failed with no write" \
		"$(yes_if eval '[ "$RC" = 1 ] && [ "$(res outcome)" = failed ] && contains "HTTP 500" "$(res reason)" && ! grep -q "^write" "$LOG/bao"')" "$(res reason) $(cat "$LOG/bao")"

	# TC-805-20: a role present (exact line), only a prefix, absent, refused.
	setup; printf 'rasputin-rel-x\n' > "$STATE/roles"; run apply
	ok "TC-805-20 role listed by exact line: no write, unchanged" \
		"$(yes_if eval '[ "$RC" = 0 ] && [ "$(res outcome)" = unchanged ] && ! grep -q "^write" "$LOG/bao"')" "$(cat "$LOG/bao")"
	ok "TC-805-20 presence comes from one LIST, never a role read" \
		"$(yes_if eval '[ "$(grep -c "^list auth/cert/certs$" "$LOG/bao")" = 1 ] && ! grep -q "^read auth/cert" "$LOG/bao"')" "$(cat "$LOG/bao")"
	for listed in rasputin-rel-x-long rasputin-rel-xx; do
		setup; printf '%s\n' "$listed" > "$STATE/roles"; run apply
		ok "TC-805-20 only $listed listed: rasputin-rel-x counts as absent and is written" \
			"$(yes_if eval '[ "$(res outcome)" = applied ] && grep -q "^write auth/cert/certs/rasputin-rel-x " "$LOG/bao"')" "$(cat "$LOG/bao")"
	done
	setup; run apply
	ok "TC-805-20 role absent: exactly the role write, every value a string" \
		"$(yes_if [ "$(grep '^write' "$LOG/bao")" = "write auth/cert/certs/rasputin-rel-x certificate=@$CREDS/store-ca.pem allowed_common_names=rasputin-rel-x token_policies=rasputin-bindable token_no_default_policy=true token_ttl=1h" ])" "$(grep '^write' "$LOG/bao")"
	ok "TC-805-20 role absent: one INFO line for the change" "$(yes_if contains "<6>$TAG: added the cert role rasputin-rel-x, bound to rasputin-bindable." "$OUT")" "$OUT"
	setup; FAKE_REFUSE=auth/cert/certs/rasputin-rel-x; run apply
	ok "TC-805-20 role write refused: failed, exit 1, the reason naming the path and 403" \
		"$(yes_if eval '[ "$RC" = 1 ] && [ "$(res outcome)" = failed ] && contains "write to auth/cert/certs/rasputin-rel-x (HTTP 403)" "$(res reason)"')" "rc=$RC $(res reason)"
	setup; FAKE_LIST=error; run apply
	ok "TC-805-20 the LIST errors: failed with no write" \
		"$(yes_if eval '[ "$RC" = 1 ] && [ "$(res outcome)" = failed ] && ! grep -q "^write" "$LOG/bao"')" "$(res reason)"

	# TC-805-21: the outcome.
	setup; printf 'mount\trasputin-rel-m\nrole\trasputin-rel-x\trasputin-bindable\n' > "$CONFIG"; run apply
	ok "TC-805-21 two absent items: applied changed=2, exit 0, with a reason" \
		"$(yes_if eval '[ "$RC" = 0 ] && [ "$(res outcome)" = applied ] && [ "$(res changed)" = 2 ] && [ -n "$(res reason)" ]')" "rc=$RC $(cat "$WORK/result")"
	run apply
	ok "TC-805-21 the same items again: unchanged changed=0, exit 0, and no write" \
		"$(yes_if eval '[ "$RC" = 0 ] && [ "$(res outcome)" = unchanged ] && [ "$(res changed)" = 0 ] && [ "$(grep -c "^write" "$LOG/bao")" = 2 ]')" "rc=$RC $(cat "$WORK/result")"
	setup; printf 'mount\trasputin-rel-m\n' > "$CONFIG"; FAKE_REFUSE=sys/mounts/rasputin-rel-m; run apply
	ok "TC-805-21 a refused write: failed, exit 1, with the reason" \
		"$(yes_if eval '[ "$RC" = 1 ] && [ "$(res outcome)" = failed ] && [ "$(res changed)" = 0 ] && contains "sys/mounts/rasputin-rel-m (HTTP 403)" "$(res reason)"')" "rc=$RC $(cat "$WORK/result")"
}

# --- TC-805-22: pre, record and stopped; the record contract ---------------------
record_cases() {
	setup; rm -rf "$WORK"; run pre
	ok "TC-805-22 pre makes the record directory 0700 and writes pending" \
		"$(yes_if eval '[ "$RC" = 0 ] && [ "$(perms "$RUN")" = drwx------ ] && [ -e "$RUN/pending" ]')" "rc=$RC $(perms "$RUN")"
	ok "TC-805-22 pre creates no work directory" "$(yes_if [ ! -e "$WORK" ])"
	setup; printf 'outcome=failed\nchanged=0\nreason=Stale.\n' > "$WORK/result"; run pre
	ok "TC-805-22 pre removes a stale result" "$(yes_if [ ! -e "$WORK/result" ])"

	# record, applied: the four lines, 0600, temp file gone, pending removed.
	setup; run pre
	printf 'outcome=applied\nchanged=2\nreason=The provisioner added this release'"'"'s missing mounts and roles to the secrets store.\n' > "$WORK/result"
	run record INVOCATION_ID=feedfacefeedfacefeedfacefeedface
	ok "TC-805-22 record exits 0" "$(yes_if [ "$RC" = 0 ])" "rc=$RC"
	ok "TC-805-22 record is 0600" "$(yes_if [ "$(perms "$RUN/outcome")" = -rw------- ])" "$(perms "$RUN/outcome")"
	ok "TC-805-22 record holds exactly outcome, boot_id, run_id and reason, in order" \
		"$(yes_if [ "$(cut -d= -f1 "$RUN/outcome" | tr '\n' ' ')" = "outcome boot_id run_id reason " ])" "$(cat "$RUN/outcome")"
	ok "TC-805-22 record: outcome=applied, this boot, run_id is the INVOCATION_ID given" \
		"$(yes_if eval '[ "$(rec outcome)" = applied ] && [ "$(rec boot_id)" = "$BOOT_ID" ] && [ "$(rec run_id)" = feedfacefeedfacefeedfacefeedface ]')" "$(cat "$RUN/outcome")"
	ok "TC-805-22 record: no temp file, no pending" "$(yes_if eval '[ ! -e "$RUN/.outcome.new" ] && [ ! -e "$RUN/pending" ]')" "$(ls -A "$RUN")"
	_want="<6>$TAG: outcome=applied changed=2 reason=\"The provisioner added this release's missing mounts and roles to the secrets store.\""
	ok "TC-805-22 record: one <6> line on stdout and the same on the console" \
		"$(yes_if eval '[ "$OUT" = "$_want" ] && [ "$(cat "$W/kmsg")" = "$_want" ]')" "stdout: $OUT console: $(cat "$W/kmsg")"
	setup; run pre; printf 'outcome=unchanged\nchanged=0\nreason=Nothing.\n' > "$WORK/result"; run record INVOCATION_ID=$INV
	ok "TC-805-22 record, unchanged: a <6> line" "$(yes_if [ "$OUT" = "<6>$TAG: outcome=unchanged changed=0 reason=\"Nothing.\"" ])" "$OUT"
	setup; run pre; rm -f "$WORK/result"; run record INVOCATION_ID=$INV
	ok "TC-805-22 record with no result: failed, a <3> line" \
		"$(yes_if eval '[ "$(rec outcome)" = failed ] && contains "<3>$TAG: outcome=failed changed=0" "$OUT"')" "$OUT"

	# stopped after a failed wait.
	setup; journal_says '2026-10-12T00:00:01Z [WARN]  failed to unseal core: error="fetching stored unseal keys failed: x"'
	run pre; run wait; run stopped SERVICE_RESULT=exit-code EXIT_STATUS=1 INVOCATION_ID=$INV
	ok "TC-805-22 stopped after a failed wait: failed, naming the service result, the status and the wait's reason" \
		"$(yes_if eval '[ "$(rec outcome)" = failed ] && contains "(it logged: fetching stored unseal keys failed: x)" "$(rec reason)" && contains "(service result exit-code, exit status 1)" "$(rec reason)"')" "$(rec reason)"
	ok "TC-805-22 stopped after a failed wait: a <3> line, pending removed" \
		"$(yes_if eval 'contains "<3>$TAG: outcome=failed" "$OUT" && [ ! -e "$RUN/pending" ]')" "$OUT"
	# stopped with pending and no result: the store stopped mid-run.
	setup; run pre; run stopped SERVICE_RESULT=success EXIT_STATUS=TERM INVOCATION_ID=$INV
	ok "TC-805-22 stopped with pending: failed, naming the service result and the status" \
		"$(yes_if eval '[ "$(rec outcome)" = failed ] && contains "(service result success, exit status TERM)" "$(rec reason)" && contains "stopped" "$(rec reason)"')" "$(rec reason)"
	# stopped, 243, no pending and no record directory: the absent certificate.
	setup; run stopped SERVICE_RESULT=exit-code EXIT_STATUS=243 INVOCATION_ID=$INV
	ok "TC-805-22 stopped on 243 with no record directory: creates it and records failed" \
		"$(yes_if eval '[ "$(perms "$RUN")" = drwx------ ] && [ "$(rec outcome)" = failed ]')" "$(perms "$RUN") $(cat "$RUN/outcome" 2>&1)"
	ok "TC-805-22 stopped on 243: the reason says the provisioner's certificate could not be loaded" \
		"$(yes_if contains "The provisioner's certificate could not be loaded (service result exit-code, exit status 243)" "$(rec reason)")" "$(rec reason)"
	# What systemd 258.7 really passes when the spawn fails at CREDENTIALS for a
	# control process: no EXIT_STATUS, no pending (pre never ran), and the last
	# run's result still in the work directory. The stale reason is not used.
	setup; printf 'outcome=unchanged\nchanged=0\nreason=Stale from the last run.\n' > "$WORK/result"
	run stopped SERVICE_RESULT=exit-code INVOCATION_ID=$INV
	ok "TC-805-22 stopped with no pending and no EXIT_STATUS: failed, the certificate could not be loaded, the stale result unused" \
		"$(yes_if eval '[ "$(rec outcome)" = failed ] && contains "certificate could not be loaded (service result exit-code, exit status unknown)" "$(rec reason)" && ! contains Stale "$(rec reason)"')" "$(rec reason)"
	# stopped, success, no pending: a normal stop of an exited run.
	setup; run stopped SERVICE_RESULT=success EXIT_STATUS=0
	ok "TC-805-22 stopped on success with no pending writes nothing" \
		"$(yes_if eval '[ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -s "$W/kmsg" ] && [ ! -e "$RUN/outcome" ]')" "$OUT"
	# stopped clears a fifo directory a killed wait left behind.
	setup; mkdir -p "$WORK/.wait.abc123"; run stopped SERVICE_RESULT=success EXIT_STATUS=0
	ok "TC-805-22 stopped removes a killed wait's fifo directory" "$(yes_if [ ! -e "$WORK/.wait.abc123" ])"
	# A record that cannot be written: a <3> sentence, the outcome line still out.
	# The record directory's path is a plain file, so nothing can be made in it.
	setup; : > "$RUN"; printf 'outcome=unchanged\nchanged=0\nreason=Nothing.\n' > "$WORK/result"
	run record INVOCATION_ID=$INV
	ok "TC-805-22 a failed record write: a <3> line naming the record" "$(yes_if contains "<3>$TAG: The outcome record $RUN/outcome could not be written" "$OUT")" "$OUT"
	ok "TC-805-22 a failed record write: the outcome line still goes out" "$(yes_if contains "<6>$TAG: outcome=unchanged changed=0" "$OUT")" "$OUT"
	setup; run nonsense
	ok "TC-805-22 an unknown phase exits 2 with a <3> line" "$(yes_if eval '[ "$RC" = 2 ] && contains "<3>$TAG:" "$OUT"')" "rc=$RC $OUT"
}

echo "store-provision tests, shells:$TEST_SHELLS"
: > "$TMP/all-outputs"
for SH in $TEST_SHELLS; do
	parse_cases
	wait_cases
	apply_cases
	record_cases
done

# --- TC-805-23: no token anywhere ----------------------------------------------
SH=harness
ok "TC-805-23 the outputs searched are not empty" "$(yes_if test -s "$TMP/all-outputs")"
ok "TC-805-23 the login's token appears in no stdout, stderr, result, record, console line or recorded argv" \
	"$(yes_if eval '! grep -qF "$TOKEN" "$TMP/all-outputs"')" "$(grep -F "$TOKEN" "$TMP/all-outputs" | head -3)"
ok "TC-805-23 the script has no set -x" "$(yes_if eval '! grep -qE "^[[:space:]]*set[[:space:]]+-[a-z]*x" "$SCRIPT"')"
case "$TEST_SHELLS" in
	*busybox_sh*) ok "the busybox rows ran" 0 ;;
	*) [ "${REQUIRE_BUSYBOX:-0}" = 1 ] && ok "the busybox rows ran" 1 ;;
esac
echo "store-provision tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
