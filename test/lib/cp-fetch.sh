#!/bin/sh
#
# cp-fetch.sh — a sparse, shallow clone of rasputin-control-plane at a tag,
# holding one directory. Sourced, never run. Extracted from
# test/store-policy-live-drift.sh (geekdojo/geekdojo-brain#804), which shares
# it with test/signin-vectors-test.sh (geekdojo/geekdojo-brain#967).
#
#   cp_fetch TAG DEST DIR
#       Clones control-plane at TAG into DEST with only DIR checked out and
#       prints DIR's path under DEST. Returns 1 with a sentence on stderr when
#       the clone fails (a tag that does not exist included) or the tag has no
#       DIR.
#
# Needs: git, network access to GitHub.

CP_REPO=https://github.com/geekdojo/rasputin-control-plane

cp_fetch() {
	if ! git clone -q --depth 1 --filter=blob:none --sparse --branch "$1" "$CP_REPO" "$2" >/dev/null 2>&1 \
		|| ! git -C "$2" sparse-checkout set "$3" >/dev/null 2>&1; then
		echo "FAILED: could not clone $CP_REPO at $1." >&2
		return 1
	fi
	[ -d "$2/$3" ] || { echo "FAILED: $CP_REPO at $1 has no $3." >&2; return 1; }
	printf '%s\n' "$2/$3"
}
