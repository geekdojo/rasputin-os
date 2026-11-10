#!/bin/sh
#
# resolved-mdns-loopback.sh — check that systemd-resolved drops the mDNS
# packets that loop back from the host's own addresses BEFORE it handles them
# as replies (geekdojo/geekdojo-brain#1067).
#
#   usage: test/resolved-mdns-loopback.sh <path to src/resolve/resolved-mdns.c>
#
# WHY. systemd 258.5 to 258.7 moved the "packet from the local host" check in
# on_mdns_packet() inside the query branch, so a reply the kernel loops back to
# resolved's own socket is processed. Restart resolved while the host's name is
# being probed and its own announcement completes the probe as a rival: resolved
# decides it lost and renames the host (bench -> bench4), and the .local name is
# gone. Upstream reverted that in 658e5ac06f80 (in 258.8); the image carries the
# revert as board/rasputin/common/patches/systemd/258.7/. CI runs this check on
# the systemd source each defconfig's Buildroot actually builds, after patching.
#
# The property, read from the source: inside on_mdns_packet(), the first
# manager_packet_from_local_address( call comes before the first
# dns_packet_validate_reply( call. The function body runs from its
# "static int on_mdns_packet(" line to the first "}" in column 0.
#
# Exit 0: the property holds. Exit 1: it does not, or it cannot be decided (the
# function or either call is missing, as after an upstream refactor) — never a
# pass by default. Exit 2: no input, or an input that is not a readable file.
set -u

NAME=resolved-mdns-loopback
FILE="${1:-}"

if [ -z "$FILE" ]; then
	echo "::error::$NAME: No input file was given. Usage: resolved-mdns-loopback.sh <path to src/resolve/resolved-mdns.c>."
	exit 2
fi
if [ ! -f "$FILE" ] || [ ! -r "$FILE" ]; then
	echo "::error::$NAME: The input $FILE is not a readable file, so it cannot be checked."
	exit 2
fi

# One line: "<found> <local line> <reply line>", 0 for a call not in the body.
if ! found=$(awk '
	!in_fn && /^static int on_mdns_packet\(/ { in_fn = 1; seen = 1; next }
	in_fn && /^}/ { in_fn = 0; done = 1 }
	in_fn && !done && !loc && /manager_packet_from_local_address\(/ { loc = NR }
	in_fn && !done && !rep && /dns_packet_validate_reply\(/ { rep = NR }
	END { printf "%d %d %d\n", seen, loc, rep }
' "$FILE"); then
	echo "::error::$NAME: The input $FILE could not be read by awk, so it cannot be checked."
	exit 2
fi
# shellcheck disable=SC2086 # three numbers, split on purpose
set -- $found
seen=$1 local_line=$2 reply_line=$3

if [ "$seen" -eq 0 ]; then
	echo "::error::$NAME: $FILE has no on_mdns_packet() function, so it cannot be decided whether resolved drops its own looped-back mDNS packets before handling replies. Upstream may have refactored it; re-check the source by hand."
	exit 1
fi
if [ "$local_line" -eq 0 ]; then
	echo "::error::$NAME: The on_mdns_packet() function in $FILE never calls manager_packet_from_local_address(), so it cannot be decided whether resolved drops its own looped-back mDNS packets before handling replies. Upstream may have refactored it; re-check the source by hand."
	exit 1
fi
if [ "$reply_line" -eq 0 ]; then
	echo "::error::$NAME: The on_mdns_packet() function in $FILE never calls dns_packet_validate_reply(), so it cannot be decided whether resolved drops its own looped-back mDNS packets before handling replies. Upstream may have refactored it; re-check the source by hand."
	exit 1
fi
if [ "$local_line" -gt "$reply_line" ]; then
	echo "::error::$NAME: In $FILE, on_mdns_packet() checks for packets from the local host (manager_packet_from_local_address at line $local_line) only after it handles replies (dns_packet_validate_reply at line $reply_line), so resolved accepts its own looped-back mDNS replies and can rename the host."
	exit 1
fi
echo "ok  $FILE: on_mdns_packet() drops packets from the local host (line $local_line) before it handles replies (line $reply_line)."
