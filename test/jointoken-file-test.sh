#!/bin/sh
#
# Functional tests for rasputin-jointoken-file.sh — the every-boot migration
# that moves a node's bus join token out of node.env and into its own 0600 file
# (geekdojo/geekdojo-brain#537, auth methodology §7 4.1).
#
# Why. This script edits the file that holds a node's only credential for the
# bus, on every boot, on nodes that are already in the field. Getting it wrong
# is invisible until the node fails to join, and by then node.env has already
# been rewritten. The properties that matter are cheap to pin here:
#
#   - it is idempotent, and a second run changes nothing;
#   - it never leaves a node with NEITHER form of the token: node.env is
#     rewritten only after the token file is in place and reads back;
#   - it never overwrites a token file that already holds something (on a
#     controlplane that file is the api's, and the api re-mints it);
#   - it leaves a controlplane and an unprovisioned/dev node alone;
#   - the token lands 0600 in a 0700 directory, and is never logged.
#
# How. The real script runs against a scratch directory through
# RASPUTIN_JOINTOKEN_PERSIST and RASPUTIN_JOINTOKEN_KMSG. No root, no
# partitions, no systemd.
#
# Shells. Every case runs under each shell in TEST_SHELLS (default: whichever
# of sh, dash, bash and `busybox sh` are installed). REQUIRE_BUSYBOX=1 (CI sets
# it) fails the run when busybox is missing, since busybox ash is the image's
# /bin/sh.
#
# Run:  sh test/jointoken-file-test.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
SCRIPT="$OVERLAY/usr/lib/rasputin/jointoken/rasputin-jointoken-file.sh"
UNIT="$OVERLAY/etc/systemd/system/rasputin-jointoken-file.service"
POST_BUILD="$ROOT/board/rasputin/common/post-build.sh"
[ -f "$SCRIPT" ] || { echo "missing: $SCRIPT" >&2; exit 2; }

if [ -z "${TEST_SHELLS:-}" ]; then
	TEST_SHELLS=""
	for s in sh dash bash; do
		command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"
	done
	command -v busybox >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS busybox_sh"
fi
if [ "${REQUIRE_BUSYBOX:-0}" = "1" ] && ! command -v busybox >/dev/null 2>&1; then
	echo "FAIL: REQUIRE_BUSYBOX=1 but busybox is not installed" >&2
	exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

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
has_line() { grep -qxF -- "$2" "$1" 2>/dev/null; }
contains() { grep -qF -- "$2" "$1" 2>/dev/null; }
out_has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
# no_such PATTERN... — true when nothing the glob expanded to exists. An
# unmatched glob arrives as its own literal text, which exists no more than a
# matched one that was removed.
no_such() { for f in "$@"; do [ -e "$f" ] && return 1; done; return 0; }

# setup — a fresh persistent partition.
setup() {
	W=$(mktemp -d "$TMP/w.XXXXXX")
	P="$W/persist"
	mkdir -p "$P"
	: > "$W/kmsg"
}

# node_env LINE... — write node.env, one argument per line, 0600 as firstboot
# leaves it.
node_env() {
	(umask 077 && printf '%s\n' "$@" > "$P/node.env")
}

# A node.env as a pre-#537 compute node carries it.
legacy_env() {
	node_env "RASPUTIN_NODE_ROLE=compute" "RASPUTIN_NODE_ID=w1" \
		"RASPUTIN_CLUSTER_ID=bench" "RASPUTIN_NATS_URL=nats://bench.local:4222" \
		"RASPUTIN_CP_JOIN_TOKEN=tok-w1" "$@"
}

# run — run the migration; sets OUT (stdout+stderr) and RC.
run() {
	case "$SH" in
		busybox_sh) set -- busybox sh "$SCRIPT" ;;
		*)          set -- "$SH" "$SCRIPT" ;;
	esac
	OUT=$(RASPUTIN_JOINTOKEN_PERSIST="$P" RASPUTIN_JOINTOKEN_KMSG="$W/kmsg" "$@" 2>&1)
	RC=$?
}

cases() {
	# 1. The migration itself: a pre-#537 compute node.env.
	setup; legacy_env; run
	ok "migrate: succeeds" "$RC" "$OUT"
	printf '%s\n' "tok-w1" > "$W/want.token"
	ok "migrate: the token is in bus/join.token verbatim plus one newline" \
		"$(yes_if cmp -s "$W/want.token" "$P/bus/join.token")" "$(cat "$P/bus/join.token" 2>&1)"
	ok "migrate: the token file is 0600" "$(yes_if test "$(perms "$P/bus/join.token")" = "-rw-------")" "$(perms "$P/bus/join.token")"
	ok "migrate: the bus dir is 0700" "$(yes_if test "$(perms "$P/bus")" = "drwx------")" "$(perms "$P/bus")"
	ok "migrate: no temp file left beside it" "$(yes_if test "$(ls -A "$P/bus")" = "join.token")" "$(ls -A "$P/bus")"
	ok "migrate: node.env names the file" \
		"$(yes_if has_line "$P/node.env" "RASPUTIN_CP_JOIN_TOKEN_FILE=$P/bus/join.token")" "$(cat "$P/node.env")"
	ok "migrate: the inline token line is gone" \
		"$(yes_if not grep -q '^RASPUTIN_CP_JOIN_TOKEN=' "$P/node.env")" "$(cat "$P/node.env")"
	ok "migrate: the token value is nowhere in node.env" "$(yes_if not contains "$P/node.env" "tok-w1")" "$(cat "$P/node.env")"
	ok "migrate: node.env keeps its other lines" \
		"$(yes_if has_line "$P/node.env" "RASPUTIN_NATS_URL=nats://bench.local:4222")" "$(cat "$P/node.env")"
	ok "migrate: node.env keeps the node id" "$(yes_if has_line "$P/node.env" "RASPUTIN_NODE_ID=w1")" "$(cat "$P/node.env")"
	ok "migrate: node.env is still 0600" "$(yes_if test "$(perms "$P/node.env")" = "-rw-------")" "$(perms "$P/node.env")"
	ok "migrate: no temp node.env left behind" "$(yes_if no_such "$P"/.node.env.jointoken.*)" "$(ls -A "$P")"
	ok "migrate: the token is never logged (stdout)" "$(yes_if not out_has "tok-w1")" "$OUT"
	ok "migrate: the token is never logged (kmsg)" "$(yes_if not contains "$W/kmsg" "tok-w1")" "$(cat "$W/kmsg")"

	# 2. Idempotent: a second run (the next boot) changes nothing.
	cp "$P/node.env" "$W/env.after1"
	run
	ok "second run: succeeds" "$RC" "$OUT"
	ok "second run: node.env byte-for-byte unchanged" "$(yes_if cmp -s "$W/env.after1" "$P/node.env")" "$(cat "$P/node.env")"
	ok "second run: the token file is unchanged" "$(yes_if cmp -s "$W/want.token" "$P/bus/join.token")" "$(cat "$P/bus/join.token")"

	# 3. A node.env that already names a token file and carries no inline
	#    token — a node provisioned by the new firstboot. No-op.
	setup
	node_env "RASPUTIN_NODE_ROLE=compute" "RASPUTIN_NODE_ID=w1" \
		"RASPUTIN_CP_JOIN_TOKEN_FILE=$P/bus/join.token"
	mkdir -p "$P/bus"; (umask 077 && printf 'tok-w1\n' > "$P/bus/join.token")
	cp "$P/node.env" "$W/env.before"; run
	ok "already migrated: succeeds" "$RC" "$OUT"
	ok "already migrated: node.env unchanged" "$(yes_if cmp -s "$W/env.before" "$P/node.env")" "$(cat "$P/node.env")"

	# 4. A controlplane: its seed carries no token at all — the api mints one
	#    into bus/agent.token. Nothing to migrate, and nothing touched.
	setup
	node_env "RASPUTIN_NODE_ROLE=controlplane" "RASPUTIN_NODE_ID=cp1" \
		"RASPUTIN_SELF_NODE_ID=cp1" "RASPUTIN_CP_JOIN_TOKEN_FILE=$P/bus/agent.token"
	cp "$P/node.env" "$W/env.before"; run
	ok "controlplane: succeeds" "$RC" "$OUT"
	ok "controlplane: node.env unchanged" "$(yes_if cmp -s "$W/env.before" "$P/node.env")" "$(cat "$P/node.env")"
	ok "controlplane: no token file invented" "$(yes_if not test -e "$P/bus/agent.token")" "$(ls -A "$P" 2>&1)"

	# 5. A token file that already holds something WINS: it is not overwritten
	#    with the inline value, and the inline line still goes. On a
	#    controlplane that file is the api's, re-minted at every start; on any
	#    node it was written later than the seed was.
	setup
	legacy_env "RASPUTIN_CP_JOIN_TOKEN_FILE=$P/bus/agent.token"
	mkdir -p "$P/bus"; (umask 077 && printf 'minted-by-the-api\n' > "$P/bus/agent.token")
	run
	ok "file wins: succeeds" "$RC" "$OUT"
	ok "file wins: the existing token file is untouched" \
		"$(yes_if has_line "$P/bus/agent.token" "minted-by-the-api")" "$(cat "$P/bus/agent.token")"
	ok "file wins: the inline token is gone from node.env" \
		"$(yes_if not grep -q '^RASPUTIN_CP_JOIN_TOKEN=' "$P/node.env")" "$(cat "$P/node.env")"
	ok "file wins: no join.token invented beside it" "$(yes_if not test -e "$P/bus/join.token")" "$(ls -A "$P/bus")"

	# 6. A blank inline token is not a credential: nothing is written, and the
	#    line is left exactly as it is rather than "migrated" into an empty
	#    token file that would take the node off the bus.
	setup
	node_env "RASPUTIN_NODE_ROLE=compute" "RASPUTIN_NODE_ID=w1" "RASPUTIN_CP_JOIN_TOKEN="
	cp "$P/node.env" "$W/env.before"; run
	ok "blank token: succeeds" "$RC" "$OUT"
	ok "blank token: node.env unchanged" "$(yes_if cmp -s "$W/env.before" "$P/node.env")" "$(cat "$P/node.env")"
	ok "blank token: no token file written" "$(yes_if not test -e "$P/bus/join.token")" "$(ls -A "$P" 2>&1)"

	# 7. No node.env at all (a dev box; the unit also condition-skips there):
	#    exits 0 and writes nothing.
	setup; run
	ok "no node.env: succeeds" "$RC" "$OUT"
	ok "no node.env: nothing written" "$(yes_if test -z "$(ls -A "$P")")" "$(ls -A "$P")"

	# 8. The token file cannot be written (its directory is taken by a
	#    non-directory): node.env MUST be left alone, so the node keeps the
	#    only credential it has and the next boot retries. This is the failure
	#    that would otherwise strand a node.
	setup; legacy_env
	: > "$P/bus"
	run
	ok "unwritable: still exits 0 (the next boot retries)" "$RC" "$OUT"
	ok "unwritable: says so" "$(yes_if out_has "node.env is unchanged")" "$OUT"
	ok "unwritable: the inline token is still there" \
		"$(yes_if has_line "$P/node.env" "RASPUTIN_CP_JOIN_TOKEN=tok-w1")" "$(cat "$P/node.env")"

	# 9. A token carrying the rest of the base64 alphabet — "+", "/" and "="
	#    padding — survives the round trip: the value is everything after the
	#    FIRST "=", and the line match cannot be confused with the _FILE key.
	#    The fixture is deliberately short and low-entropy: a realistic-looking
	#    token here is a finding for the repository's secret scan.
	setup
	node_env "RASPUTIN_NODE_ROLE=compute" "RASPUTIN_NODE_ID=w1" \
		"RASPUTIN_CP_JOIN_TOKEN=tok-w1+/aa=="
	run
	printf '%s\n' "tok-w1+/aa==" > "$W/want.token"
	ok "padded token: succeeds" "$RC" "$OUT"
	ok "padded token: stored verbatim" "$(yes_if cmp -s "$W/want.token" "$P/bus/join.token")" "$(cat "$P/bus/join.token" 2>&1)"
}

for SH in $TEST_SHELLS; do
	echo "== $SH"
	cases
done

# Unit wiring — shell-independent, so checked once.
SH=unit
ok "the unit runs the migration script" \
	"$(yes_if grep -qx 'ExecStart=/usr/lib/rasputin/jointoken/rasputin-jointoken-file.sh' "$UNIT")" "$(cat "$UNIT")"
# Ordered before whatever reads the token, or the agent reads a node.env that
# is mid-migration.
ok "the unit is ordered before the agent and the api" \
	"$(yes_if grep -qx 'Before=rasputin-agent.service rasputin-api.service' "$UNIT")" "$(cat "$UNIT")"
ok "the unit runs after firstboot (which writes node.env)" \
	"$(yes_if grep -qx 'After=rasputin-firstboot.service' "$UNIT")" "$(cat "$UNIT")"
# Every boot, not once: an OS update keeps the persistent node.env and never
# re-runs firstboot, which is the node this migration is for.
ok "the unit is wanted by multi-user.target" \
	"$(yes_if grep -qx 'WantedBy=multi-user.target' "$UNIT")" "$(cat "$UNIT")"
# "enabled" on a read-only rootfs is a symlink made at build time.
ok "post-build enables the unit" \
	"$(yes_if grep -q 'multi-user.target.wants/rasputin-jointoken-file.service' "$POST_BUILD")" "$(grep -n jointoken "$POST_BUILD")"

echo "jointoken-file: $pass passed, $fail failed (shells:$TEST_SHELLS)"
[ "$fail" -eq 0 ]
