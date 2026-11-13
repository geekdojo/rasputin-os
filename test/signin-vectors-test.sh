#!/bin/sh
#
# The sign-in client's tests against rasputin-control-plane's vector file
# (geekdojo/geekdojo-brain#967, TC-967-06 and TC-967-07).
#
# Why. The Go client in control-plane and test/lib/signin.py must agree on
# what Keycloak's pages look like and how each ceremony is built, and both
# pass one file: api/internal/identitytest/testdata/signin-vectors.json and
# its pages/. It is fetched, never vendored (two copies would drift), at
# v$RASPUTIN_API_VERSION: the tag the image's api is built from, so the OS
# tests the vectors its pinned api was tested with.
#
# Steps:
#   1. Read the pin with real GNU make; sparse-clone control-plane at that tag
#      holding only testdata/ (test/lib/cp-fetch.sh). A tag with no
#      signin-vectors.json fails, naming it. Nothing is skipped.
#   2. Run test/signin-test.py under python3 -I with SIGNIN_VECTORS set.
#   3. Run it again under python3 -m trace (trace swallows the exit status,
#      so the asserted run is step 2) and fail below 70% line coverage of
#      signin.py and signin_kit/ together (TC-967-06, the TC-834-24 method).
#   4. The control: a fetch at a tag that does not exist must fail, which is
#      the path that makes this script exit 2.
#
# Exit status: 0 the suite passed, coverage held and the control failed as
# it must; 1 a test failed, coverage was below 70% or the control passed;
# 2 the vectors could not be fetched or read (each with a sentence).
#
# Red at a pin that predates the vector file (control-plane 70d8fc2a), by
# design, as the live drift check is.
#
# TEST-ONLY OVERRIDE, for showing the client against a control-plane build
# before it is released; CI never sets it:
#   RASPUTIN_CP_SRC=<checkout>   a local control-plane checkout's testdata/
#                                instead of the clone at the tag; prints a
#                                line starting "LOCAL OVERRIDE:"
#
# Needs: GNU make, git, python3, openssl, network access to GitHub.
# Run:   sh test/signin-vectors-test.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SUITE="$ROOT/test/signin-test.py"
TESTDATA=api/internal/identitytest/testdata
for t in make git python3 openssl; do
	command -v "$t" >/dev/null 2>&1 || { echo "FAILED: this check needs $t, and it is not on PATH."; exit 2; }
done
for f in "$SUITE" "$ROOT/test/lib/mk-var.sh" "$ROOT/test/lib/cp-fetch.sh" "$ROOT/test/lib/signin.py"; do
	[ -f "$f" ] || { echo "FAILED: the file $f is missing."; exit 2; }
done
. "$ROOT/test/lib/mk-var.sh"
. "$ROOT/test/lib/cp-fetch.sh"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT INT TERM

VERSION=$(mk_var "$ROOT/package/rasputin-api/rasputin-api.mk" RASPUTIN_API_VERSION) \
	|| { echo "FAILED: could not read RASPUTIN_API_VERSION from package/rasputin-api/rasputin-api.mk."; exit 2; }
TAG="v$VERSION"

if [ -n "${RASPUTIN_CP_SRC:-}" ]; then
	echo "LOCAL OVERRIDE: using RASPUTIN_CP_SRC=$RASPUTIN_CP_SRC/$TESTDATA instead of $CP_REPO at $TAG. This run says nothing about the pin."
	VECTORS="$RASPUTIN_CP_SRC/$TESTDATA"
else
	echo "fetching $TESTDATA from $CP_REPO at $TAG"
	VECTORS=$(cp_fetch "$TAG" "$W/cp" "$TESTDATA") || VECTORS=""
fi
if [ -z "$VECTORS" ] || [ ! -f "$VECTORS/signin-vectors.json" ]; then
	echo "FAILED: there is no $TESTDATA/signin-vectors.json at $TAG (control-plane's pin), so the sign-in client has no vectors to pass. Re-pin to a control-plane release that carries it."
	exit 2
fi

echo "== the suite (TC-967-01 to TC-967-05)"
SIGNIN_VECTORS="$VECTORS" python3 -I "$SUITE"; rc=$?
[ "$rc" = 0 ] || { echo "FAILED: test/signin-test.py exited $rc."; exit 1; }

echo "== line coverage of signin.py and signin_kit/ (TC-967-06)"
STDLIB=$(python3 -I -c 'import sysconfig; print(sysconfig.get_paths()["stdlib"])')
SIGNIN_VECTORS="$VECTORS" python3 -I -m trace --count --missing --coverdir="$W/cover" \
	--ignore-dir="$STDLIB" "$SUITE" >/dev/null 2>&1
hit=0 miss=0
for c in "$W/cover/signin.cover" "$W/cover"/signin_kit.*.cover; do
	[ -f "$c" ] || continue
	h=$(grep -cE '^ *[0-9]+: ' "$c")
	m=$(grep -c '^>>>>>> ' "$c")
	echo "  $(basename "$c" .cover): $h of $((h + m)) lines ran"
	hit=$((hit + h)) miss=$((miss + m))
done
if [ $((hit + miss)) -eq 0 ]; then
	echo "FAILED: the trace wrote no cover file for signin.py or signin_kit/, so there is no coverage figure."
	exit 1
fi
pct=$((hit * 100 / (hit + miss)))
echo "  signin.py and signin_kit/: $hit of $((hit + miss)) lines ran ($pct%)"
if [ "$pct" -lt 70 ]; then
	echo "FAILED: line coverage is $pct%, below 70%."
	exit 1
fi

echo "== control: a fetch at a tag that does not exist must fail (this script's exit 2 path)"
if cp_fetch v0.0.0-signin-vectors-control "$W/missing" "$TESTDATA" >/dev/null 2>"$W/missing.err"; then
	echo "FAILED: a fetch at a missing tag succeeded, so a failed fetch could pass unseen."
	exit 1
fi
sed 's/^/  /' "$W/missing.err"
echo "signin-vectors-test: the client passes control-plane's vectors at $TAG with $pct% line coverage, and the control failed as it must."
