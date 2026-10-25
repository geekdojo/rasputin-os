#!/bin/sh
#
# fetch-vendored.sh ROOT ARCH DL PKG...
#
# Places the pinned control-plane release tarball for each PKG (rasputin-agent,
# rasputin-api) into Buildroot's dl/ cache, DL/PKG/, for release.yml's "Fetch
# vendored binaries (control-plane release)" step. ARCH is amd64 or arm64.
#
# The version comes from ROOT/package/PKG/PKG.mk (PKG_VERSION, upper-cased with
# _ for -), and the tarball's sha256 from ROOT/package/PKG/PKG.hash, the
# release's own *.hash lines. A download counts only when both facts hold: `gh
# release download` exited 0, and the file it wrote has the pinned sha256.
#
# WHY IT RETRIES. One dropped connection to the release CDN used to fail the
# whole image build: run 40229531683 died here on `connection reset by peer`
# with the asset intact, and only a re-run got past it. A transient network
# fault is retried, up to ATTEMPTS times per tarball, with no sleep between
# tries: the next attempt is started by the failed one's exit status or hash,
# never by a timer. ATTEMPTS is fixed; a pin that is truly wrong (a hash that
# never matches, a release that does not exist) still fails after the last try,
# with an ::error:: naming the tarball. A file that fails the hash check is
# deleted, so Buildroot never sees a bad tarball in dl/.
#
# Exit status: 0 every tarball is in place and matches its .hash; 1 any is not;
# 2 usage error.
#
# Needs: gh (GH_TOKEN in Actions), openssl, awk, sed.
# test/fetch-vendored-test.sh covers every branch against a stub gh.

set -eu

ATTEMPTS=3

[ "$#" -ge 4 ] || { echo "::error::usage: fetch-vendored.sh ROOT ARCH DL PKG..." >&2; exit 2; }
root=$1 arch=$2 dl=$3
shift 3
case "$arch" in
	amd64 | arm64) ;;
	*) echo "::error::fetch-vendored: ARCH must be amd64 or arm64, not '$arch'" >&2; exit 2 ;;
esac

fetch() {
	pkg=$1
	var=$(printf '%s' "$pkg" | tr 'a-z-' 'A-Z_') # rasputin-agent → RASPUTIN_AGENT
	mk="$root/package/$pkg/$pkg.mk"
	hashfile="$root/package/$pkg/$pkg.hash"
	ver=$(sed -n "s/^${var}_VERSION = //p" "$mk" 2>/dev/null | tr -d '[:space:]')
	[ -n "$ver" ] || { echo "::error::could not parse ${var}_VERSION from package/$pkg/$pkg.mk"; return 1; }
	src="$pkg-$ver-linux-$arch.tar.gz"
	want=$(awk -v s="$src" '$1 == "sha256" && $3 == s { print $2 }' "$hashfile" 2>/dev/null)
	[ -n "$want" ] || { echo "::error::package/$pkg/$pkg.hash has no sha256 line for $src"; return 1; }
	mkdir -p "$dl/$pkg"
	out="$dl/$pkg/$src"
	n=1
	while [ "$n" -le "$ATTEMPTS" ]; do
		echo "→ fetching $src into dl/$pkg/ (attempt $n of $ATTEMPTS)"
		if gh release download "v$ver" \
			--repo geekdojo/rasputin-control-plane \
			--pattern "$src" \
			--dir "$dl/$pkg" \
			--clobber; then
			got=$(openssl dgst -sha256 -r "$out" 2>/dev/null | cut -d' ' -f1)
			if [ "$got" = "$want" ]; then
				echo "  $src matches package/$pkg/$pkg.hash"
				return 0
			fi
			echo "::warning::$src does not match package/$pkg/$pkg.hash on attempt $n of $ATTEMPTS (got ${got:-no file}, want $want)"
		else
			echo "::warning::gh release download of $src failed on attempt $n of $ATTEMPTS"
		fi
		rm -f -- "$out"
		n=$((n + 1))
	done
	echo "::error::could not fetch $src with the sha256 in package/$pkg/$pkg.hash after $ATTEMPTS attempts"
	return 1
}

for pkg in "$@"; do
	fetch "$pkg" || exit 1
done
