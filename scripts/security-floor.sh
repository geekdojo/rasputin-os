#!/bin/sh
#
# security-floor.sh FILE RELEASE_VERSION
#
# Prints the security floor a release's manifest.json carries, read from FILE
# (the repo's security-floor.txt), or nothing when FILE is empty or absent.
# (geekdojo/geekdojo-brain#772)
#
# The floor is the oldest Rasputin OS version that carries every fix for a
# reachable critical or high advisory. A control plane raises a security alert
# for every node older than it, so a floor that is wrong strands every cluster
# that reads it:
#   - a value that is not CalVer cannot be read by the control plane;
#   - a floor that ranks above this release's own version names a version this
#     release does not reach, so installing it would never clear the alert.
# Both are refused here, before anything is signed or published.
#
# Ranking matches rasputin-control-plane releases.Compare: YYYY, MM and PATCH
# compare as numbers, in that order (so 2026.09 < 2026.10 and 2026.10.9 <
# 2026.10.10); for the same base, a stable version outranks any -dev.N, and a
# higher N is newer. No shell arithmetic is used: $((09)) is an octal error in
# dash, while test(1)'s -lt and -gt read 09 as decimal nine in dash, bash and
# busybox ash, so each field is compared with test(1).
#
# Exit status:
#   0  FILE empty or absent (no output), or the floor is printed on stdout
#   1  the floor is not CalVer, or ranks above RELEASE_VERSION (stderr names it)
#   2  usage error, or RELEASE_VERSION is not CalVer
#
# test/security-floor-test.sh covers every status.
set -eu

fail() {
	_status=$1
	shift
	printf '::error::security-floor: %s\n' "$*" >&2
	exit "$_status"
}

[ "$#" -eq 2 ] || fail 2 "usage: security-floor.sh FILE RELEASE_VERSION"
file=$1
release=$2

# is_calver V — V is YYYY.M[M].PATCH with an optional -dev.N suffix.
is_calver() {
	printf '%s\n' "$1" | grep -Eqx '[0-9]{4}\.[0-9]{1,2}\.[0-9]+(-dev\.[0-9]+)?'
}

# cmp_num A B — prints -1, 0 or 1 as A is below, equal to or above B.
cmp_num() {
	_a=$1 _b=$2
	if [ "$_a" -lt "$_b" ]; then
		printf '%s' -1
	elif [ "$_a" -gt "$_b" ]; then
		printf '%s' 1
	else
		printf '%s' 0
	fi
}

# above A B — succeeds when version A ranks strictly above version B.
above() {
	_va=${1%%-dev.*} _vb=${2%%-dev.*}
	# Base fields, left to right: the first that differs decides.
	_ra=$_va _rb=$_vb
	for _i in 1 2 3; do
		_fa=${_ra%%.*} _fb=${_rb%%.*}
		_ra=${_ra#*.} _rb=${_rb#*.}
		case "$(cmp_num "$_fa" "$_fb")" in
			1) return 0 ;;
			-1) return 1 ;;
		esac
	done
	# Same base. Stable outranks dev; two devs compare by N.
	case "$1" in *-dev.*) _da=${1##*-dev.} ;; *) _da="" ;; esac
	case "$2" in *-dev.*) _db=${2##*-dev.} ;; *) _db="" ;; esac
	if [ -z "$_da" ]; then
		[ -n "$_db" ]
		return
	fi
	[ -n "$_db" ] || return 1
	[ "$(cmp_num "$_da" "$_db")" = 1 ]
}

is_calver "$release" || fail 2 "release version '$release' is not CalVer (YYYY.MM.PATCH or YYYY.MM.PATCH-dev.N)"

[ -f "$file" ] || exit 0
# The file holds one version or nothing; surrounding whitespace and a trailing
# newline are not part of it. Anything else on another line makes the value
# non-CalVer, and is refused rather than half-read.
floor=$(tr -d ' \t\r\n' < "$file")
[ -n "$floor" ] || exit 0

is_calver "$floor" || fail 1 "$file: floor '$floor' is not CalVer (YYYY.MM.PATCH or YYYY.MM.PATCH-dev.N)"
if above "$floor" "$release"; then
	fail 1 "$file: floor '$floor' ranks above this release's own version '$release'; a floor names a version this release reaches"
fi
printf '%s\n' "$floor"
