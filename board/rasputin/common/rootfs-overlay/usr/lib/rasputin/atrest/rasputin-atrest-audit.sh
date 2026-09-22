#!/bin/sh
#
# rasputin-atrest-audit.sh — check every path in the at-rest inventory and
# report one verdict line to the kernel log.
#
# WHY THE KERNEL LOG. The QEMU smoke test has no shell into the guest. Its only
# channels are the serial console and the host-forwarded ports, and only lines
# that reach /dev/kmsg are mirrored to the console — journald's are not. So the
# verdict goes to /dev/kmsg, the smoke greps the console for it, and a widened
# mode fails a release build.
#
# WHY IT RUNS ON EVERY BOOT AND NOT ONLY UNDER TEST. The modes it checks are
# produced by four different mechanisms, three of which run at first boot and
# one of which runs whenever the api writes a file. A check that only ran in CI
# would be checking the image; this checks the machine. It reads and reports,
# changes nothing, and never fails a boot.
#
# Exit status: 0 when every declared path is as declared, 1 otherwise. The unit
# ignores it (see the unit file); the smoke reads the verdict line.
#
# Usage:
#   rasputin-atrest-audit.sh [-i INVENTORY] [-r ROOT] [-u UID] [-q]
#     -i  inventory file (default /usr/lib/rasputin/atrest/inventory)
#     -r  prefix every inventory path with ROOT — for the test harness, which
#         builds a synthetic tree rather than a machine
#     -u  the uid every declared path must belong to (default 0). Only the
#         test harness passes this: it cannot create root-owned files, and a
#         harness that turned the ownership check OFF would be testing a
#         different audit from the one that ships.
#     -q  do not write to /dev/kmsg (the test harness; also what happens
#         automatically when /dev/kmsg cannot be written)
#
# POSIX sh: this runs under busybox on the appliance and under dash and bash in
# the repo's tests. No arrays, no [[ ]], no local.

set -u

INVENTORY=/usr/lib/rasputin/atrest/inventory
ROOT=
QUIET=
WANT_UID=0

while [ $# -gt 0 ]; do
	case "$1" in
	-i) INVENTORY="$2"; shift 2 ;;
	-r) ROOT="$2"; shift 2 ;;
	-u) WANT_UID="$2"; shift 2 ;;
	-q) QUIET=1; shift ;;
	*) echo "rasputin-atrest-audit: unknown argument: $1" >&2; exit 2 ;;
	esac
done

if [ ! -r "$INVENTORY" ]; then
	# An unreadable inventory is a failure, not a pass. A gate that reports
	# "nothing to check" when its own input is missing is the failure mode
	# this whole audit exists to prevent.
	msg="rasputin-atrest: FAIL inventory unreadable: $INVENTORY"
	echo "$msg"
	[ -n "$QUIET" ] || echo "$msg" >/dev/kmsg 2>/dev/null || true
	exit 1
fi

# mode PATH  — the four-digit octal mode, or empty when it cannot be read.
# owner PATH — the numeric owner uid, or empty when it cannot be read.
#
# WHY NOT stat(1). The appliance image ships no stat at all: busybox is built
# without the applet and there is no coreutils. The first version of this
# script probed for GNU `stat -c` and fell back to the BSD spelling so the test
# would also run on a Mac — so on the image BOTH branches called a binary that
# is not there, every path's mode came back empty, and the verdict read
# "is , declared 0600" on every node for as long as it shipped
# (geekdojo/geekdojo-brain#494). The lesson is not that the fallback had the
# wrong spelling. It is that a reader with two branches gets exercised on
# whichever branch CI happens to take, and CI is the machine that has stat. So
# there is one branch now, and it uses only what the image has.
#
# WHY find. busybox find carries -maxdepth and -perm, and `-perm -BITS` asks
# the kernel "are all of these bits set". That is a fact rather than a
# rendering: no locale, no column alignment, and none of the suffix characters
# that make `ls -l`'s first column unsafe to parse (macOS prints '@' for
# extended attributes, GNU '+' or '.' for an ACL or an SELinux label). Twelve
# bit tests compose the mode, including the setuid, setgid and sticky bits, so
# a setuid file cannot read as an ordinary one. Cost, measured on the slowest
# bench node: 0.22s for 288 tests, in a unit that runs once per boot.
#
# THE GOTCHA. find exits 0 when nothing matched, so a bit is decided by whether
# the path was PRINTED, never by exit status.
mode() {
	# The existence probe is load-bearing, not a convenience. Without it a
	# reader that cannot run at all would answer "0000" for every path —
	# a real mode, indistinguishable from a real answer. Empty means "could
	# not be read", and every caller treats that as a failure.
	[ -n "$(find "$1" -maxdepth 0 2>/dev/null)" ] || return 0
	_out=
	for _digit in '4000 2000 1000' '0400 0200 0100' '0040 0020 0010' '0004 0002 0001'; do
		_val=0
		_weight=4
		for _bit in $_digit; do
			if [ -n "$(find "$1" -maxdepth 0 -perm -"$_bit" 2>/dev/null)" ]; then
				_val=$(( _val + _weight ))
			fi
			_weight=$(( _weight / 2 ))
		done
		_out="$_out$_val"
	done
	echo "$_out"
}

owner() {
	# Column 3 of `ls -ldn` is the numeric uid. Its POSITION is stable across
	# busybox, coreutils and BSD ls, and the suffix characters that make
	# column 1 unsafe to parse do not shift it. -d so a symlink is reported
	# rather than its target, which is what the mode reader above does too.
	ls -ldn "$1" 2>/dev/null | awk 'NR == 1 { print $3 }'
}

# Failures are collected in a file rather than a variable: the sweep reads
# `find` through a pipe, and a `while read` on the far side of a pipe runs in a
# subshell whose variables never come back. A counter that silently stayed at
# zero would make this audit report PASS over the findings it just made, which
# is exactly the shape it exists to catch.
WORK="$(mktemp -d 2>/dev/null || echo /tmp/atrest.$$)"
mkdir -p "$WORK"
FAILURES="$WORK/failures"
CHECKED="$WORK/checked"
: >"$FAILURES"
: >"$CHECKED"
trap 'rm -rf "$WORK"' EXIT INT TERM

fail() {
	echo "$1" >>"$FAILURES"
	echo "rasputin-atrest: $1"
}

counted() { echo x >>"$CHECKED"; }

# A mode is owner-only when neither the group bits nor the other bits grant
# anything. Arithmetic, not string matching, so that a mode written with or
# without its leading zero reads the same.
#
# An empty mode is NOT owner-only. `0$1` on an empty string is 0, so this used
# to answer "compliant" for a mode it had failed to read — which is how a
# broken reader made every swept file look clean.
owner_only() {
	[ -n "$1" ] || return 1
	[ "$(( 0$1 & 0077 ))" -eq 0 ]
}

while read -r col1 col2 col3 _rest; do
	case "$col1" in
	'' | \#*) continue ;;
	esac

	if [ "$col1" = "sweep" ]; then
		dir="$ROOT$col2"
		[ -d "$dir" ] || continue
		# -perm /g+r,o+r is a GNU find extension busybox does not carry, so
		# the modes are read one file at a time instead. These trees hold a
		# handful of files. `read -r` rather than word-splitting `$(find ...)`,
		# because a path with a space would otherwise become two paths and be
		# checked as neither.
		find "$dir" -type f 2>/dev/null | while IFS= read -r f; do
			counted
			m="$(mode "$f")"
			if [ -z "$m" ]; then
				# Never a skip. This branch used to be guarded by
				# `[ -n "$m" ] &&`, so a reader that answered
				# nothing turned the half of this audit that
				# catches an UNDECLARED secret into a no-op that
				# still reported its count.
				fail "FAIL $f mode could not be read in a swept tree; every file under $col2 is owner-only"
			elif ! owner_only "$m"; then
				fail "FAIL $f is $m in a swept tree; every file under $col2 is owner-only"
			fi
		done
		continue
	fi

	want="$col1"
	presence="$col2"
	path="$ROOT$col3"

	if [ ! -e "$path" ]; then
		if [ "$presence" = "required" ]; then
			fail "FAIL $path is missing and is required"
		fi
		continue
	fi

	counted
	got="$(mode "$path")"
	if [ -z "$got" ]; then
		# A mode this audit could not read is a failure that says so.
		# The alternative is what shipped: an empty string compared
		# against a declared mode, which fails every path with the
		# unreadable message "is , declared 0600" and points at the
		# modes instead of at the reader.
		fail "FAIL $path mode could not be read; declared $want"
		continue
	fi
	# The reader and the inventory both write four digits, but the leading
	# zero is stripped from both sides anyway so that an inventory line
	# written the way chmod takes it still compares equal.
	if [ "${got#0}" != "${want#0}" ]; then
		fail "FAIL $path is $got, declared $want"
		continue
	fi
	if ! owner_only "$got"; then
		fail "FAIL $path is $got, which grants group or world access"
		continue
	fi
	o="$(owner "$path")"
	if [ -z "$o" ]; then
		fail "FAIL $path owner could not be read"
	elif [ "$o" != "$WANT_UID" ]; then
		fail "FAIL $path is owned by uid $o, not $WANT_UID"
	fi
done <"$INVENTORY"

failed="$(wc -l <"$FAILURES" | tr -d ' ')"
checked="$(wc -l <"$CHECKED" | tr -d ' ')"
if [ "$failed" -eq 0 ]; then
	verdict="rasputin-atrest: PASS checked=$checked"
else
	first_failure="$(head -1 "$FAILURES")"
	verdict="rasputin-atrest: FAIL failures=$failed checked=$checked first=$first_failure"
fi

echo "$verdict"
# /dev/kmsg is absent in a container and unwritable for a non-root caller.
# Neither is a reason to change the verdict, so the write is allowed to fail.
[ -n "$QUIET" ] || echo "$verdict" >/dev/kmsg 2>/dev/null || true

[ "$failed" -eq 0 ]
