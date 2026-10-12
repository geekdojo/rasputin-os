#!/bin/sh
#
# store-policy-drift.sh — compare two copies of the secrets store's fixed
# policy text (geekdojo/geekdojo-brain#804; ADR-0010 S9).
#
# Usage: scripts/store-policy-drift.sh A B
#
# A and B are directories of policy files, for example the image's
# /usr/share/rasputin/openbao-policy and the api tarball's openbao-policy/, or
# that tarball's copy and rasputin-control-plane's
# api/internal/secretstore/storepolicy at the release tag. Only regular files
# whose names end in .hcl are compared: the control-plane directory also holds
# the Go package around the text.
#
# Exit status, each failure with sentences on stderr:
#   0  both hold the same .hcl names with the same bytes
#   1  they differ; every differing, missing and extra file is named
#   2  either side cannot be read, or holds no .hcl file, or bad usage
#      (two empty sides agree about nothing, so they are not a match)
#
# The image build (board/rasputin/common/check-store-policy.sh) and CI's drift
# check (test/store-policy-live-drift.sh) both run this. It never skips.
set -u

if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
	echo "Usage: $0 A B, where A and B are the two policy directories to compare." >&2
	exit 2
fi
A=$1 B=$2

# names DIR — the .hcl regular files in DIR, one per line, sorted. Fails with a
# sentence when DIR cannot be listed.
names() {
	if [ ! -d "$1" ] || ! _n_all=$(ls -A -- "$1" 2>/dev/null); then
		echo "The policy directory $1 cannot be read, so the two copies cannot be compared." >&2
		return 1
	fi
	printf '%s\n' "$_n_all" | while IFS= read -r _n; do
		case "$_n" in *.hcl) [ -f "$1/$_n" ] && printf '%s\n' "$_n" ;; esac
	done | LC_ALL=C sort
}

an=$(names "$A") || exit 2
bn=$(names "$B") || exit 2
for side in "$A:$an" "$B:$bn"; do
	if [ -z "${side#*:}" ]; then
		echo "The policy directory ${side%%:*} holds no .hcl file, so there is nothing to compare." >&2
		exit 2
	fi
done

# has LIST NAME — NAME is one of LIST's lines.
has() { case "
$1
" in *"
$2
"*) return 0 ;; esac; return 1; }

# Each loop reads names one per line from a here-document, so no name is ever
# word-split.
compare() {
	_c_rc=0
	while IFS= read -r n; do
		if ! has "$bn" "$n"; then
			echo "The policy file $n is in $A but missing from $B." >&2
			_c_rc=1
			continue
		fi
		cmp -s "$A/$n" "$B/$n"
		case $? in
			0) ;;
			1) echo "The policy file $n differs between $A and $B." >&2; _c_rc=1 ;;
			*) echo "The policy file $n cannot be read on both sides, so it cannot be compared." >&2; return 2 ;;
		esac
	done <<-EOF2
	$an
	EOF2
	while IFS= read -r n; do
		if ! has "$an" "$n"; then
			echo "The policy file $n is in $B but not in $A." >&2
			_c_rc=1
		fi
	done <<-EOF2
	$bn
	EOF2
	return "$_c_rc"
}

compare; rc=$?
[ "$rc" -eq 0 ] && echo "The policy files in $A and $B match: $(printf '%s\n' "$an" | tr '\n' ' ' | sed 's/ $//')."
exit "$rc"
