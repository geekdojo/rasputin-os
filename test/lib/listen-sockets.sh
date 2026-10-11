#!/bin/sh
#
# listen-sockets.sh — turn /proc's socket tables into LISTEN addresses. Sourced,
# never run (geekdojo/geekdojo-brain#756). The parsing runs on the test runner;
# the caller fetches the text from wherever the process lives (a container, or
# a QEMU guest over SSH, whose busybox has no ss), so the same code reads both.
#
#   bao_listeners
#       Reads, on stdin, the text of /proc/<pid>/net/tcp and /proc/<pid>/net/tcp6
#       and the output of `ls -l /proc/<pid>/fd`, in any order. Prints each
#       LISTEN socket that one of those fds holds, as ADDR:PORT (IPv6 in
#       brackets), once each, in table order.
#   listening_sockets
#       The same, for every LISTEN row in the tables, owned by any process.
#       For "nothing listens on this port" when there is no process to ask.
#
# Why the fd listing. /proc/<pid>/net/tcp is the whole network namespace's
# table, not the process's; a row belongs to the process only if one of its
# fds is that row's socket inode.
#
# A table row is "sl: LOCAL REMOTE STATE ... INODE ...", LOCAL being HEX:PORT
# with 8 hex digits for IPv4 and 32 for IPv6, each 32-bit word in host (little
# endian) byte order. State 0A is LISTEN. Header lines and anything else are
# skipped. Empty input prints nothing and returns 0.

_listen_parse() {
	awk -v owned="$1" '
		function hex(s,    i, n, c) {
			n = 0
			s = toupper(s)
			for (i = 1; i <= length(s); i++) {
				c = index("0123456789ABCDEF", substr(s, i, 1))
				n = n * 16 + c - 1
			}
			return n
		}
		# word W: an 8-digit little-endian word, as its 4 bytes in network order.
		function bytes(w,    i, out) {
			out = ""
			for (i = 7; i >= 1; i -= 2) out = out substr(w, i, 2)
			return out
		}
		function v4(h,    b) {
			b = bytes(h)
			return hex(substr(b, 1, 2)) "." hex(substr(b, 3, 2)) "." hex(substr(b, 5, 2)) "." hex(substr(b, 7, 2))
		}
		function v6(h,    b, i, g, n, best, bestlen, run, runstart, out) {
			b = ""
			for (i = 0; i < 4; i++) b = b bytes(substr(h, i * 8 + 1, 8))
			for (i = 0; i < 8; i++) g[i] = sprintf("%x", hex(substr(b, i * 4 + 1, 4)))
			# The longest run of two or more zero groups becomes "::".
			best = -1; bestlen = 1; run = 0
			for (i = 0; i < 8; i++) {
				if (g[i] == "0") {
					if (run == 0) runstart = i
					run++
					if (run > bestlen) { best = runstart; bestlen = run }
				} else run = 0
			}
			out = ""
			for (i = 0; i < 8; i++) {
				if (i == best) { out = out "::"; i += bestlen - 1; continue }
				if (out != "" && substr(out, length(out), 1) != ":") out = out ":"
				out = out g[i]
			}
			return "[" out "]"
		}
		/socket:\[[0-9]+\]/ {
			s = $0
			sub(/.*socket:\[/, "", s); sub(/\].*/, "", s)
			fd[s] = 1
			next
		}
		$1 ~ /^[0-9]+:$/ && $2 ~ /^[0-9A-Fa-f]+:[0-9A-Fa-f]+$/ && $4 == "0A" {
			split($2, a, ":")
			if (length(a[1]) == 8) addr = v4(a[1])
			else if (length(a[1]) == 32) addr = v6(a[1])
			else next
			n++
			row[n] = addr ":" hex(a[2])
			ino[n] = $10
		}
		END {
			for (i = 1; i <= n; i++) {
				if (owned == "yes" && !(ino[i] in fd)) continue
				if (row[i] in seen) continue
				seen[row[i]] = 1
				print row[i]
			}
		}
	'
}

bao_listeners() { _listen_parse yes; }
listening_sockets() { _listen_parse no; }
