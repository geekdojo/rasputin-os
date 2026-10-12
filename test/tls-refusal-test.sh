#!/bin/sh
# Unit tests for test/lib/tls-refusal.sh, the helper both TLS-refusal checks
# run on the store's host (geekdojo/geekdojo-brain#756, F-756-18).
#
# Why. The helper decides whether the store refused a client in the TLS
# handshake, and each of its failure paths reads, to its caller, as "the store
# did not refuse": a wrong-reason line taken as a match would pass a refusal
# for the wrong cause, and a refused connection that started a follower would
# wait on a line that can never come. The functional tests exercise only the
# paths a real store takes, so every path is pinned here.
#
# How. journalctl, mkfifo and the client are shims on PATH, each appending its
# argv to one call log. The journalctl shim serves a canned cursor for
# --show-cursor and canned output for --follow, then exits; that end of output
# is what ends the helper's read, so no case can hang and none needs a timer.
#
# Shells. Every case runs under each of sh, dash and bash that is installed and
# under `busybox sh` (the QEMU guest's shell). REQUIRE_BUSYBOX=1 makes a
# missing busybox a failure.
#
# Run:  sh test/tls-refusal-test.sh
set -u

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
HELPER="$HERE/lib/tls-refusal.sh"
for f in "$HELPER" "$HERE/lib/checks.sh"; do
	[ -f "$f" ] || { echo "FAILED: $f is missing, so this test cannot run."; exit 1; }
done
if [ "${REQUIRE_BUSYBOX:-0}" = "1" ] && ! command -v busybox >/dev/null 2>&1; then
	echo "FAILED: REQUIRE_BUSYBOX=1 but busybox is not installed."; exit 1
fi
# shellcheck source=SCRIPTDIR/lib/checks.sh
. "$HERE/lib/checks.sh"

SCRATCH=$(mktemp -d) || { echo "FAILED: could not make a scratch directory."; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
BIN="$SCRATCH/bin"
CALLS="$SCRATCH/calls"
mkdir -p "$BIN"

# journalctl shim: logs its argv; --show-cursor prints $SCRATCH/cursor.out,
# --follow prints $SCRATCH/follow.out and exits.
cat >"$BIN/journalctl" <<EOF
#!/bin/sh
echo "journalctl \$*" >>"$CALLS"
case " \$* " in
	*" --show-cursor "*) cat "$SCRATCH/cursor.out" ;;
	*" --follow "*) cat "$SCRATCH/follow.out" ;;
esac
EOF
# client shim: logs its argv, prints $SCRATCH/client.out, exits $SCRATCH/client.rc.
cat >"$BIN/fake-client" <<EOF
#!/bin/sh
echo "client \$*" >>"$CALLS"
cat "$SCRATCH/client.out"
exit "\$(cat "$SCRATCH/client.rc")"
EOF
# mkfifo shim, installed only for the fifo-failure case.
cat >"$SCRATCH/mkfifo-fails" <<EOF
#!/bin/sh
echo "mkfifo \$*" >>"$CALLS"
echo "mkfifo: cannot create fifo '\$1': Permission denied" >&2
exit 1
EOF
chmod +x "$BIN/journalctl" "$BIN/fake-client" "$SCRATCH/mkfifo-fails"

GOOD_CURSOR='-- No entries --
-- cursor: s=0123abcd;i=42'
HANDSHAKE='http: TLS handshake error from 127.0.0.1:51234:'

TEST_SHELLS=""
for s in sh dash bash; do command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"; done
command -v busybox >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS busybox_sh"

# setup CURSOR FOLLOW CLIENT_OUT CLIENT_RC — the canned outputs for one case.
setup() {
	printf '%s\n' "$1" >"$SCRATCH/cursor.out"
	printf '%s\n' "$2" >"$SCRATCH/follow.out"
	printf '%s\n' "$3" >"$SCRATCH/client.out"
	printf '%s\n' "$4" >"$SCRATCH/client.rc"
	: >"$CALLS"
	rm -f "$BIN/mkfifo"
}

# run REASON — runs the helper under $SH; sets OUT, ERR, RC and LOG.
run() {
	case "$SH" in
		busybox_sh) set -- busybox sh "$HELPER" openbao.service "$1" fake-client --arg ;;
		*) set -- "$SH" "$HELPER" openbao.service "$1" fake-client --arg ;;
	esac
	OUT=$(PATH="$BIN:$PATH" "$@" 2>"$SCRATCH/err"); RC=$?
	ERR=$(cat "$SCRATCH/err")
	LOG=$(cat "$CALLS")
}

# detail — the last run, on one line, for a FAIL.
detail() { printf 'rc=%s stdout: %s stderr: %s calls: %s' "$RC" "$(printf '%s' "$OUT" | tr '\n' '|')" "$ERR" "$(printf '%s' "$LOG" | tr '\n' '|')"; }

# followed — 0 when the call log holds a --follow call.
followed() { contains ' --follow ' "$LOG "; }

for SH in $TEST_SHELLS; do
	echo
	echo "tls-refusal.sh under $SH"

	# Right reason: the line naming the reason is printed, and only it.
	REASON='tls: certificate required'
	setup "$GOOD_CURSOR" "a line that says $REASON but is no handshake error
$HANDSHAKE remote error: tls: bad certificate
$HANDSHAKE $REASON
$HANDSHAKE $REASON (a later one)" 'curl: (56) OpenSSL SSL_read: error' 56
	run "$REASON"
	st=0
	[ "$RC" -eq 0 ] || st=1
	[ "$OUT" = "client: curl: (56) OpenSSL SSL_read: error|rc=56
journal: $HANDSHAKE $REASON" ] || st=1
	contains 'journalctl -u openbao.service --after-cursor=s=0123abcd;i=42 --follow' "$LOG" || st=1
	contains 'client --arg' "$LOG" || st=1
	check "[$SH] right reason: exits 0 and prints the client line and the first handshake line naming the reason, followed from the cursor" "$st" "$(detail)"

	# Wrong reason: a handshake line with another reason is not a match.
	setup "$GOOD_CURSOR" "$HANDSHAKE remote error: tls: bad certificate" 'curl: (35) error' 35
	run 'tls: certificate required'
	st=0
	[ "$RC" -eq 1 ] || st=1
	contains 'journal: none, the follower ended with no matching line' "$OUT" || st=1
	contains 'bad certificate' "$OUT" && st=1
	check "[$SH] wrong reason: exits 1, saying the follower ended with no matching line" "$st" "$(detail)"

	# Connection refused, curl's and Go's words: exit 1 with no follower.
	for words in 'curl: (7) Failed to connect to 127.0.0.1 port 8200: Could not connect to server' \
		'Get "https://127.0.0.1:8200/v1/sys/seal-status": dial tcp 127.0.0.1:8200: connect: connection refused'; do
		setup "$GOOD_CURSOR" "$HANDSHAKE tls: certificate required" "$words" 7
		run 'tls: certificate required'
		st=0
		[ "$RC" -eq 1 ] || st=1
		contains 'journal: none, the connection was refused' "$OUT" || st=1
		followed && st=1
		contains 'client --arg' "$LOG" || st=1
		check "[$SH] connection refused ($(printf '%s' "$words" | cut -c1-24)...): exits 1 at once, saying it was refused, and no follower ran" "$st" "$(detail)"
	done

	# No cursor: exit 1 before the client or a follower runs.
	setup '-- No entries --' "$HANDSHAKE tls: certificate required" 'unused' 0
	run 'tls: certificate required'
	st=0
	[ "$RC" -eq 1 ] || st=1
	contains 'journal: none, openbao.service has no journal entry to start from' "$OUT" || st=1
	contains 'client' "$LOG" && st=1
	followed && st=1
	check "[$SH] no cursor: exits 1, naming the unit with no journal entry, and neither the client nor a follower ran" "$st" "$(detail)"

	# fifo failure: exit 1 with no follower.
	setup "$GOOD_CURSOR" "$HANDSHAKE tls: certificate required" 'curl: (56) error' 56
	cp "$SCRATCH/mkfifo-fails" "$BIN/mkfifo"
	run 'tls: certificate required'
	st=0
	[ "$RC" -eq 1 ] || st=1
	contains 'journal: none, could not make a fifo at ' "$OUT" || st=1
	contains 'mkfifo ' "$LOG" || st=1
	followed && st=1
	check "[$SH] fifo failure: exits 1, saying it could not make a fifo, and no follower ran" "$st" "$(detail)"
done

echo
if [ -z "$TEST_SHELLS" ]; then echo "FAILED: no shell to run the helper under."; exit 1; fi
if [ "$fails" -ne 0 ]; then echo "tls-refusal-test: $fails check(s) FAILED"; exit 1; fi
echo "tls-refusal-test: all checks passed"
