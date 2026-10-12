#!/bin/sh
#
# tls-refusal.sh — did the secrets store refuse this client in the TLS
# handshake? Copied to the store's host (the functional test's container, or
# the QEMU guest over SSH) and run there (geekdojo/geekdojo-brain#756).
#
#   sh tls-refusal.sh UNIT REASON CLIENT [ARG ...]
#
# Runs CLIENT with its ARGs once, then prints two lines:
#   client: <CLIENT's output on one line>|rc=N
#   journal: <the first line UNIT logs after CLIENT started that reads
#            "http: TLS handshake error from" and holds REASON>
# and exits 0. If CLIENT's output says "connection refused" (Go) or "Could
# not connect" (curl), nothing is listening, so there is no handshake to wait
# for: it prints the client line and "journal: none, the connection was
# refused" and exits 1 at once.
#
# WHY THE STORE'S JOURNAL, NOT THE CLIENT'S WORDS (F-756-16). Under TLS 1.3 the
# client's handshake is over once it has sent its certificate, before the
# server has checked it. The server's refusal then reaches the client as an
# alert, or, when the server's close lands first, as a failed write (broken
# pipe, connection reset) or, in Go's HTTP/2 client, as "client conn could
# not be established". Which one is timing. The store's own line names the
# reason every time: bao's HTTP server logs "http: TLS handshake error from
# ADDR: REASON" for each refused handshake, at info, the shipped log level.
#
# NO SLEEP. The line is read by following UNIT's journal from a cursor taken
# before CLIENT starts, so a line written before the follower opens is read
# too, and the wait ends the moment the line exists. The follower has no end of
# its own; the caller bounds this script with the deadline of its one remote
# call (the container's `timeout`, update-smoke's SSH call timeout), and a
# missing line shows there as no "journal:" line.
set -u
[ "$#" -ge 3 ] || { echo "usage: tls-refusal.sh UNIT REASON CLIENT [ARG ...]" >&2; exit 2; }
unit=$1 reason=$2
shift 2

cursor=$(journalctl -u "$unit" -n 1 -o cat --show-cursor --no-pager 2>/dev/null | sed -n 's/^-- cursor: //p')
[ -n "$cursor" ] || { echo "journal: none, $unit has no journal entry to start from"; exit 1; }

out=$("$@" 2>&1)
rc=$?
echo "client: $(printf '%s' "$out" | tr '\n' '|')|rc=$rc"
case "$out" in
	*"onnection refused"*|*"Could not connect"*) echo "journal: none, the connection was refused"; exit 1 ;;
esac

fifo=$(mktemp -u)
mkfifo "$fifo" || { echo "journal: none, could not make a fifo at $fifo"; exit 1; }
journalctl -u "$unit" --after-cursor="$cursor" --follow -o cat --no-pager >"$fifo" 2>/dev/null &
follower=$!
line=$(awk -v r="$reason" 'index($0, "http: TLS handshake error from") && index($0, r) { print; exit }' <"$fifo")
kill "$follower" 2>/dev/null
wait "$follower" 2>/dev/null
rm -f "$fifo"
[ -n "$line" ] || { echo "journal: none, the follower ended with no matching line"; exit 1; }
echo "journal: $line"
