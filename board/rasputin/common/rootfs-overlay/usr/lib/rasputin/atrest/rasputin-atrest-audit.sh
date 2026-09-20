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

# mode PATH — the octal mode, or empty when the path does not exist.
#
# `stat -c` is what busybox and coreutils understand, which covers the
# appliance and the CI runner. The BSD spelling is probed once so that
# test/atrest-modes-test.sh also runs on a Mac: a gate that can only be run in
# CI is one nobody runs before pushing, and this script's logic is the part the
# test exercises.
if stat -c '%a' / >/dev/null 2>&1; then
	mode() { stat -c '%a' "$1" 2>/dev/null; }
	owner() { stat -c '%u' "$1" 2>/dev/null; }
else
	mode() { stat -f '%Lp' "$1" 2>/dev/null; }
	owner() { stat -f '%u' "$1" 2>/dev/null; }
fi

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
# anything. Arithmetic, not string matching: `stat` prints 000 as "0", and a
# text comparison against "00" would call that mode group-readable.
owner_only() {
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
			if [ -n "$m" ] && ! owner_only "$m"; then
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
	# stat prints 600 where the inventory writes 0600; compare without the
	# leading zero rather than teaching the inventory to drop it, because an
	# inventory that writes modes the way chmod does is the one people get
	# right.
	if [ "${got#0}" != "${want#0}" ]; then
		fail "FAIL $path is $got, declared $want"
		continue
	fi
	if ! owner_only "$got"; then
		fail "FAIL $path is $got, which grants group or world access"
		continue
	fi
	o="$(owner "$path")"
	if [ "$o" != "$WANT_UID" ]; then
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
