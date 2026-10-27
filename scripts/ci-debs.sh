#!/usr/bin/env bash
#
# ci-debs.sh — install a fixed set of Ubuntu packages on a CI runner WITHOUT
# depending on an Ubuntu mirror being fast, by keeping the exact .debs in
# actions/cache and fetching them ourselves only when the cache misses.
#
# WHY THIS EXISTS
#   Every release.yml image build installs packages from an Ubuntu mirror in
#   five places: QEMU (+ OVMF on amd64) in smoke-amd64, smoke-arm64 and each
#   update-smoke leg, and rauc in sign; ci.yml's verify-bundle installs rauc on
#   every pull request. None of those installs had a bound. On 2026-10-27 the
#   firewall repo's smoke job (geekdojo/rasputin-openwrt-firewall run
#   40537097987, the same install of qemu-system-x86 + ovmf on the same runner
#   image) got its apt index at 10.9 MB/s and then the .debs from
#   azure.archive.ubuntu.com, the runner's own default mirror via
#   mirror+file:/etc/apt/apt-mirrors.txt, at 37.6 kB/s: ovmf-generic (5.4 MB)
#   took 2m11s, qemu-system-x86 (11.5 MB) stalled, was dropped ("Ign") and was
#   fetched again for 3m43s, and the step hit its 10-minute timeout before dpkg
#   unpacked anything; that lost a build of the day's batched dev chain. Here,
#   with no step timeout at all, the same trickle would have held the job until
#   GitHub's 6-hour job limit. Bounding apt does not fix it: apt has no
#   minimum-speed option, so a transfer that trickles rather than dies never
#   trips Acquire::*::Timeout, and pointing the sources at the Azure mirror
#   changes nothing because they already point there (the firewall's
#   2026-08-19 sed rewrite matched nothing for that reason).
#
#   This script is a copy of the firewall repo's scripts/ci-debs.sh
#   (geekdojo/rasputin-openwrt-firewall#115). Keep the two in step: a fix to
#   one is owed to the other.
#
#   The fix is to stop fetching on the common path at all:
#     warm  — the .debs come out of actions/cache, are checked against the
#             SHA256SUMS written when they were first verified, and go in with
#             apt-get --no-download as local files. No network, no apt index. Deterministic: the cache key
#             (`key`) is a hash of the runner's installed package base, so the
#             debs only ever land on the exact base they were resolved against.
#     cold  — on a miss (a new runner image, or 7 days unused), `fetch` resolves
#             the set with apt, downloads each .deb itself with a MINIMUM SPEED
#             (curl --speed-limit/--speed-time), and moves to the next mirror when
#             one trickles. Each file is checked against the size and hash in the
#             signed index, then apt installs them with --no-download (so apt
#             verifies them again, and cannot quietly fetch anything itself). The
#             verified set is then saved to the cache.
#   Every failure is loud: a ::error:: line naming the package, the mirrors tried
#   and why each was refused, and a non-zero exit. Nothing here skips the job that needs the packages.
#
# USAGE
#   ci-debs.sh key <pkg>...           print the cache key for <pkg>... on this runner
#   ci-debs.sh fetch <dir> <pkg>...   cold path: resolve, download, verify, apt install,
#                                     and write <dir>/SHA256SUMS for the cache
#   ci-debs.sh install <dir>          warm path: verify <dir>/SHA256SUMS, install the set
#   ci-debs.sh get <pool-path> <size> <hashtype:hex> <dest>
#                                     fetch one pool file through the mirror list
#                                     (what `fetch` calls per file; exposed for the test)
#
# ENVIRONMENT (defaults are what CI uses; the test overrides them)
#   CI_DEBS_MIRRORS      space-separated archive roots, tried in order
#   CI_DEBS_SPEED_LIMIT  bytes/s a transfer must sustain ...            (default 102400)
#   CI_DEBS_SPEED_TIME   ... over this many seconds, or it is abandoned (default 15)
#   CI_DEBS_MAX_TIME     hard cap on one file from one mirror, seconds  (default 120)
#   CI_DEBS_UPDATE_MAX   hard cap on `apt-get update`, seconds          (default 180)
#
# Used through .github/actions/ci-debs. Tested by test/ci-debs-test.sh.

set -euo pipefail

MIRRORS="${CI_DEBS_MIRRORS:-http://azure.archive.ubuntu.com/ubuntu https://archive.ubuntu.com/ubuntu https://security.ubuntu.com/ubuntu}"
SPEED_LIMIT="${CI_DEBS_SPEED_LIMIT:-102400}"
SPEED_TIME="${CI_DEBS_SPEED_TIME:-15}"
MAX_TIME="${CI_DEBS_MAX_TIME:-120}"
UPDATE_MAX="${CI_DEBS_UPDATE_MAX:-180}"

die() { printf '::error::%s\n' "$*" >&2; exit 1; }

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
	else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# hash_of <hashtype> <file> — the digest apt's index records, for the types
# `apt-get --print-uris` can print.
hash_of() {
	case "$1" in
	MD5Sum) if command -v md5sum >/dev/null 2>&1; then md5sum "$2" | awk '{print $1}'; else md5 -q "$2"; fi ;;
	SHA1) if command -v sha1sum >/dev/null 2>&1; then sha1sum "$2" | awk '{print $1}'; else shasum -a 1 "$2" | awk '{print $1}'; fi ;;
	SHA256) sha256_of "$2" ;;
	SHA512) if command -v sha512sum >/dev/null 2>&1; then sha512sum "$2" | awk '{print $1}'; else shasum -a 512 "$2" | awk '{print $1}'; fi ;;
	*) return 1 ;;
	esac
}

size_of() { wc -c < "$1" | tr -d ' '; }

# parse_uris — read `apt-get install --print-uris -qq` on stdin and print one
# "<pool-path> <filename> <size> <hashtype:hex>" line per .deb. The URI may be a
# plain mirror URL or mirror+file:/etc/apt/apt-mirrors.txt/pool/...; either way
# the part from /pool/ on is the same on every Ubuntu archive mirror.
parse_uris() {
	local uri file size hash pool
	while read -r uri file size hash; do
		[ -n "${uri:-}" ] || continue
		uri="${uri#\'}"; uri="${uri%\'}"
		case "$uri" in
		*/pool/*) pool="pool/${uri#*/pool/}" ;;
		*) die "apt printed a URI with no /pool/ path, so it cannot be fetched from a mirror: $uri" ;;
		esac
		case "$size" in ''|*[!0-9]*) die "apt printed no size for $file: '$size'" ;; esac
		case "$hash" in *:?*) ;; *) die "apt printed no hash for $file: '${hash:-}'" ;; esac
		printf '%s %s %s %s\n' "$pool" "$file" "$size" "$hash"
	done
}

# get <pool-path> <size> <hashtype:hex> <dest> — try each mirror once. A mirror is
# abandoned on: connect failure, HTTP error, falling under SPEED_LIMIT for
# SPEED_TIME seconds (the trickle), MAX_TIME, a wrong size, or a wrong hash.
cmd_get() {
	[ "$#" -eq 4 ] || die "usage: ci-debs.sh get <pool-path> <size> <hashtype:hex> <dest>"
	local pool="$1" size="$2" hash="$3" dest="$4"
	local htype="${hash%%:*}" hval="${hash#*:}" tmp="$4.part" m url rc stats got why tried=""
	hash_of "$htype" /dev/null >/dev/null 2>&1 || die "unsupported hash type '$htype' for $pool"
	for m in $MIRRORS; do
		url="${m%/}/$pool"
		rm -f "$tmp"
		rc=0
		stats="$(curl -fsS --connect-timeout 10 \
			--speed-limit "$SPEED_LIMIT" --speed-time "$SPEED_TIME" --max-time "$MAX_TIME" \
			-w '%{time_total}s %{speed_download}B/s' -o "$tmp" "$url" 2>&1)" || rc=$?
		if [ "$rc" -ne 0 ]; then
			case "$rc" in
			28) why="slower than ${SPEED_LIMIT} B/s for ${SPEED_TIME}s or over ${MAX_TIME}s (curl 28)" ;;
			22) why="HTTP error (curl 22)" ;;
			*) why="curl exit $rc" ;;
			esac
			printf '  %s: %s — %s\n' "$m" "$why" "$(printf '%s' "$stats" | tail -1)" >&2
			tried="$tried [$m: $why]"
			continue
		fi
		got="$(size_of "$tmp")"
		if [ "$got" != "$size" ]; then
			printf '  %s: size %s, index says %s\n' "$m" "$got" "$size" >&2
			tried="$tried [$m: size $got != $size]"
			continue
		fi
		got="$(hash_of "$htype" "$tmp")"
		if [ "$got" != "$hval" ]; then
			printf '  %s: %s %s, index says %s\n' "$m" "$htype" "$got" "$hval" >&2
			tried="$tried [$m: $htype mismatch]"
			continue
		fi
		mv -f "$tmp" "$dest"
		printf '  %s  %s  %s\n' "$(basename "$dest")" "$stats" "$m"
		return 0
	done
	rm -f "$tmp"
	die "could not fetch $pool from any mirror:$tried"
}

# key <pkg>... — a hash of everything that decides whether a cached set of debs
# installs: the requested packages, the architecture, the OS release, and every
# package already installed with its version. No network.
cmd_key() {
	[ "$#" -gt 0 ] || die "usage: ci-debs.sh key <pkg>..."
	command -v dpkg-query >/dev/null 2>&1 || die "dpkg-query not found: ci-debs.sh key runs on a Debian/Ubuntu runner"
	local osr="unknown"
	# shellcheck disable=SC1091  # the runner's os-release, read at run time
	[ -r /etc/os-release ] && osr="$(. /etc/os-release && printf '%s-%s' "${ID:-}" "${VERSION_ID:-}")"
	{
		printf 'ci-debs v1\n'
		printf 'pkgs %s\n' "$*"
		printf 'arch %s\n' "$(dpkg --print-architecture)"
		printf 'os %s\n' "$osr"
		dpkg-query -W -f='${binary:Package}=${Version}\n' | LC_ALL=C sort
	} | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | awk '{print $1}'
}

# fetch <dir> <pkg>... — the cold path.
cmd_fetch() {
	[ "$#" -ge 2 ] || die "usage: ci-debs.sh fetch <dir> <pkg>..."
	local dir="$1"; shift
	local apt_opts="-o DPkg::Lock::Timeout=120 -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30"
	mkdir -p "$dir"
	rm -f "$dir"/*.deb "$dir/SHA256SUMS"
	[ -r /etc/apt/apt-mirrors.txt ] && { echo "runner apt mirror list:"; sed 's/^/  /' /etc/apt/apt-mirrors.txt; }
	echo "apt-get update (capped at ${UPDATE_MAX}s)"
	# shellcheck disable=SC2086  # apt_opts is a list of separate options
	sudo timeout "$UPDATE_MAX" env DEBIAN_FRONTEND=noninteractive apt-get update -q $apt_opts \
		|| die "apt-get update failed or ran over ${UPDATE_MAX}s (exit $?); the package index could not be read, so $* cannot be installed"
	local list
	# shellcheck disable=SC2086
	list="$(sudo env DEBIAN_FRONTEND=noninteractive apt-get install --print-uris -qq --no-install-recommends $apt_opts "$@")" \
		|| die "apt could not resolve: $*"
	list="$(printf '%s\n' "$list" | { grep "^'" || true; } | parse_uris)" || exit 1
	if [ -z "$list" ]; then
		echo "nothing to fetch: $* already installed"
		return 0
	fi
	echo "fetching $(printf '%s\n' "$list" | wc -l | tr -d ' ') packages (floor ${SPEED_LIMIT} B/s over ${SPEED_TIME}s, ${MAX_TIME}s cap per file)"
	local pool file size hash
	while read -r pool file size hash; do
		cmd_get "$pool" "$size" "$hash" "$dir/$file"
	done < <(printf '%s\n' "$list")
	# apt verifies each file against the signed index again before using it, and
	# --no-download means a file it rejects is an error, never a quiet re-fetch
	# from the mirror this script exists to avoid.
	sudo cp "$dir"/*.deb /var/cache/apt/archives/
	# shellcheck disable=SC2086
	sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-download --no-install-recommends $apt_opts "$@" \
		|| die "apt-get install --no-download failed for: $*"
	( cd "$dir" && for f in *.deb; do printf '%s  %s\n' "$(sha256_of "$f")" "$f"; done ) > "$dir/SHA256SUMS"
	echo "installed and recorded $(wc -l < "$dir/SHA256SUMS" | tr -d ' ') packages in $dir/SHA256SUMS"
}

# install <dir> — the warm path.
cmd_install() {
	[ "$#" -eq 1 ] || die "usage: ci-debs.sh install <dir>"
	local dir="$1" f want got n=0
	[ -s "$dir/SHA256SUMS" ] || die "$dir/SHA256SUMS is missing or empty: the cached package set is incomplete"
	while read -r want f; do
		[ -f "$dir/$f" ] || die "cached package set is missing $f"
		got="$(sha256_of "$dir/$f")"
		[ "$got" = "$want" ] || die "cached $f has sha256 $got, recorded $want: refusing to install it"
		n=$((n + 1))
	done < "$dir/SHA256SUMS"
	[ "$(find "$dir" -maxdepth 1 -name '*.deb' | wc -l | tr -d ' ')" = "$n" ] \
		|| die "$dir holds .debs that SHA256SUMS does not list: refusing an unverified set"
	# apt, not a bare `dpkg -i`: dpkg unpacks a set in argument order and refuses
	# a package whose Pre-Depends sits later in the same set, where apt orders
	# the set itself (measured: `dpkg -i` of this exact set failed on python3's
	# pre-dependency). Local files need no package index, and --no-download makes
	# any dependency the cached set lacks an error rather than a mirror fetch.
	# They are installed from apt's own archive directory: with no index, apt
	# looks a dependency's file up there, and fails with "Pathname to install is
	# not absolute" when it is only in $dir.
	echo "verified $n cached packages; installing them with apt-get --no-download"
	local files=()
	while read -r want f; do files+=("/var/cache/apt/archives/$f"); done < "$dir/SHA256SUMS"
	sudo cp "$dir"/*.deb /var/cache/apt/archives/
	sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-download --no-install-recommends \
		-o DPkg::Lock::Timeout=120 "${files[@]}" \
		|| die "apt-get install of the cached package set failed"
}

[ "$#" -ge 1 ] || die "usage: ci-debs.sh key|fetch|install|get ..."
sub="$1"; shift
case "$sub" in
key) cmd_key "$@" ;;
fetch) cmd_fetch "$@" ;;
install) cmd_install "$@" ;;
get) cmd_get "$@" ;;
parse-uris) parse_uris ;;
*) die "unknown subcommand '$sub' (key|fetch|install|get)" ;;
esac
