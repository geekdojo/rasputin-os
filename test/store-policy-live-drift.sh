#!/bin/sh
#
# The live drift check for the secrets store's policy text
# (geekdojo/geekdojo-brain#804, TC-804-11; ADR-0010 S9).
#
# Why. rasputin-control-plane owns the text; its tests run it against the real
# store, and its release packs it into the api tarball as openbao-policy/. The
# image installs the tarball's copy. This check fetches the pinned api tarball
# exactly as the build does (pin read with real GNU make, sha256 checked
# against rasputin-api.hash) and a sparse, shallow clone of control-plane at
# the same tag, v$RASPUTIN_API_VERSION, and compares the tarball's
# openbao-policy/ with api/internal/secretstore/storepolicy/ through
# scripts/store-policy-drift.sh. A difference means the image would enforce
# text control-plane did not test.
#
# It never skips. Then it runs two controls, so a check that cannot fail
# cannot pass:
#   - the tarball's rasputin-api.hcl altered by one byte must fail, naming it;
#   - a clone at a tag that does not exist must fail, which is the path that
#     makes this script exit 2.
#
# Exit status: 0 the copies match and both controls behaved; 1 they differ, or
# a control did not fail as it must; 2 a fetch, clone or read failed (each
# with a sentence).
#
# TEST-ONLY OVERRIDES, for showing the os side against a control-plane build
# before it is released; CI sets neither:
#   RASPUTIN_API_TARBALL=<tarball>  test/lib/api-tarball.sh's override
#   RASPUTIN_CP_SRC=<checkout>      a local rasputin-control-plane checkout
#                                   instead of the clone at the tag
# Each prints a line starting "LOCAL OVERRIDE:".
#
# ci.yml runs it on every pull request and release.yml's validate job on
# every tag and dispatch. It is red on a branch whose api pin predates the
# policy files, by design: the image would not build either.
#
# Needs: GNU make, curl, openssl, tar, git, network access to GitHub.
# Run:   sh test/store-policy-live-drift.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
DRIFT="$ROOT/scripts/store-policy-drift.sh"
REPO=https://github.com/geekdojo/rasputin-control-plane
SRCDIR=api/internal/secretstore/storepolicy
for t in make curl openssl tar git; do
	command -v "$t" >/dev/null 2>&1 || { echo "FAILED: this check needs $t, and it is not on PATH."; exit 2; }
done
for f in "$DRIFT" "$ROOT/test/lib/mk-var.sh" "$ROOT/test/lib/api-tarball.sh"; do
	[ -f "$f" ] || { echo "FAILED: the file $f is missing."; exit 2; }
done
. "$ROOT/test/lib/mk-var.sh"
. "$ROOT/test/lib/api-tarball.sh"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT INT TERM

# cp_fetch TAG DEST — a sparse, shallow clone of control-plane at TAG holding
# only the policy directory; prints the directory's path. Fails with a
# sentence.
cp_fetch() {
	if ! git clone -q --depth 1 --filter=blob:none --sparse --branch "$1" "$REPO" "$2" >/dev/null 2>&1 \
		|| ! git -C "$2" sparse-checkout set "$SRCDIR" >/dev/null 2>&1; then
		echo "FAILED: could not clone $REPO at $1, so there is no policy source to compare with." >&2
		return 1
	fi
	[ -d "$2/$SRCDIR" ] || { echo "FAILED: $REPO at $1 has no $SRCDIR." >&2; return 1; }
	printf '%s\n' "$2/$SRCDIR"
}

# Either architecture's tarball carries the same text; amd64 is fetched.
api_policy_fetch "$ROOT" BR2_x86_64 "$W/api" || exit 2
TAG="v$API_VERSION"
LABEL="the api $API_VERSION tarball"
[ -n "${RASPUTIN_API_TARBALL:-}" ] && LABEL="the local api tarball (override)"
if [ -n "${RASPUTIN_CP_SRC:-}" ]; then
	echo "LOCAL OVERRIDE: comparing with RASPUTIN_CP_SRC=$RASPUTIN_CP_SRC instead of $REPO at $TAG. This run says nothing about the pin."
	SRC="$RASPUTIN_CP_SRC/$SRCDIR"
else
	SRC=$(cp_fetch "$TAG" "$W/cp") || exit 2
fi

echo "comparing $LABEL's openbao-policy/ with $SRCDIR at $TAG"
sh "$DRIFT" "$API_POLICY" "$SRC"; rc=$?
case "$rc" in
	0) ;;
	1) echo "FAILED: the pinned api tarball's policy text is not control-plane's at $TAG."; exit 1 ;;
	*) echo "FAILED: the policy text could not be compared (drift check exit $rc)."; exit 2 ;;
esac

echo "control: one changed byte in the tarball's rasputin-api.hcl must fail"
cp -R "$API_POLICY" "$W/altered"
printf '#' >> "$W/altered/rasputin-api.hcl"
sh "$DRIFT" "$W/altered" "$SRC" 2>"$W/altered.err"; crc=$?
sed 's/^/  drift: /' "$W/altered.err"
if [ "$crc" != 1 ] || ! grep -qF 'rasputin-api.hcl differs' "$W/altered.err"; then
	echo "FAILED: the altered copy was not refused naming rasputin-api.hcl (exit $crc), so this check cannot see drift."
	exit 1
fi
echo "  refused, exit 1"

echo "control: a clone at a tag that does not exist must fail (this script's exit 2 path)"
if cp_fetch v0.0.0-store-policy-drift-control "$W/missing" >/dev/null 2>"$W/missing.err"; then
	echo "FAILED: a clone at a missing tag succeeded, so a failed fetch could pass unseen."
	exit 1
fi
sed 's/^/  /' "$W/missing.err"
echo "store-policy-live-drift: $LABEL carries control-plane's policy text at $TAG, and both controls failed as they must."
