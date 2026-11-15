#!/usr/bin/env bash
#
# source-bundle.sh — build one SKU's GPL source bundle,
# rasputin-os-<sku>-<version>-source.tar (geekdojo/geekdojo-brain#970).
#
#   source-bundle.sh fetch PLAN OUT
#   source-bundle.sh pack SKU VERSION LEGAL_INFO BAKED BR_DIR OUT
#
# fetch reads the plan scripts/gpl-sources.py baked-images printed, one
# "debian<TAB>source<TAB>version" line per Debian source package in a baked
# container image. For each it asks snapshot.debian.org which files make up
# that source package (/mr/package/<src>/<ver>/srcfiles?fileinfo=1) and
# downloads each from /file/<sha1>. snapshot addresses a file by its sha1, so
# a file whose sha1 is not its address is refused. Files land in
# OUT/debian/<src>_<ver without epoch>/ under their Debian names (.dsc, .orig.tar.*,
# .debian.tar.*).
#
# pack stages and tars the bundle into OUT:
#   README                         what is in it, and why host sources are not
#   legal-info/                    Buildroot's `make legal-info` output for the
#                                  target, without host-sources/; its
#                                  legal-info.sha256 is rewritten to list only
#                                  what ships, and `sha256sum -c` must pass on
#                                  the staged tree before anything is tarred
#   rasputin-os-<commit>.tar.gz    this repository at the built commit
#   buildroot-<tag>.tar.gz         Buildroot at the tag init-buildroot.sh pins
#   baked-images/                  BAKED, the fetch output above
# and writes OUT/source-<sku>.json:
#   {"sku", "source", "sourceSha256", "sourceSizeBytes"}
# which the sign job merges into that SKU's manifest.json entry
# (scripts/manifest-sources.sh). A bundle over SOURCE_BUNDLE_MAX_BYTES
# (default 2147483648, GitHub's per-asset limit) is refused, and neither the
# tar nor the meta file is left behind.
#
# Environment:
#   SOURCE_BUNDLE_MAX_BYTES  the size limit (default 2147483648)
#   SOURCE_BUNDLE_REPO       the repository to archive and read pins from
#                            (default: the one this script is in)
#   SNAPSHOT_URL             snapshot.debian.org's base URL (default
#                            https://snapshot.debian.org)
#   CURL_MAX_TIME            seconds one curl call may take (default 600);
#                            it bounds a single download, nothing else
#
# Exit status: 0 done; 1 a defect or failure, each with one "::error::
# source-bundle: <sentence>" line on stderr; 2 wrong usage.
#
# Needs curl, jq, git, tar, sha1sum and sha256sum on PATH.
# test/source-bundle-test.sh covers both subcommands with fakes first on PATH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${SOURCE_BUNDLE_REPO:-$(cd "$SCRIPT_DIR/.." && pwd)}"
MAX_BYTES="${SOURCE_BUNDLE_MAX_BYTES:-2147483648}"
SNAPSHOT="${SNAPSHOT_URL:-https://snapshot.debian.org}"
CURL_MAX_TIME="${CURL_MAX_TIME:-600}"
CONTROL_PLANE_URL="https://github.com/geekdojo/rasputin-control-plane"

# One scratch directory per run, removed on every exit, failures included.
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

fail() {
	printf '::error::source-bundle: %s\n' "$*" >&2
	exit 1
}
usage() {
	printf '::error::source-bundle: %s\n' "Usage: source-bundle.sh fetch PLAN OUT | pack SKU VERSION LEGAL_INFO BAKED BR_DIR OUT." >&2
	exit 2
}

# urlencode STRING — percent-encode everything but RFC 3986 unreserved
# characters (a Debian version can carry ':' and '+' and '~').
urlencode() { jq -rn --arg s "$1" '$s | @uri'; }

get() { # get URL FILE
	curl -fsSL --retry 3 --max-time "$CURL_MAX_TIME" -o "$2" "$1"
}

cmd_fetch() {
	[ "$#" -eq 2 ] || usage
	local plan="$1" out="$2" kind src ver n=0 files=0
	[ -f "$plan" ] || fail "The fetch plan $plan is missing."
	mkdir -p "$out/debian"
	local tmp="$WORK"
	while IFS=$'\t' read -r kind src ver; do
		[ -n "$kind" ] || continue
		[ "$kind" = debian ] || fail "The fetch plan line '$kind $src $ver' is not a debian line."
		[ -n "$src" ] && [ -n "$ver" ] || fail "The fetch plan has a debian line with no source or version."
		local info="$tmp/info.json"
		get "$SNAPSHOT/mr/package/$(urlencode "$src")/$(urlencode "$ver")/srcfiles?fileinfo=1" "$info" ||
			fail "snapshot.debian.org did not answer for the Debian source $src $ver, so its source cannot be fetched; re-run the job once snapshot.debian.org is reachable."
		local list
		list="$(jq -r '.result[]?.hash as $h | (.fileinfo[$h][0].name // "") as $n | [$h, $n] | @tsv' "$info" 2>/dev/null)" ||
			fail "snapshot.debian.org's answer for the Debian source $src $ver is not the JSON its API documents."
		[ -n "$list" ] || fail "snapshot.debian.org lists no files for the Debian source $src $ver, so its source cannot be fetched."
		# Named as Debian names the files: the epoch ("1:") is dropped.
		local dir="$out/debian/${src}_${ver#*:}"
		mkdir -p "$dir"
		local sha name got
		while IFS=$'\t' read -r sha name; do
			[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || fail "snapshot.debian.org gave '$sha' as a file address for the Debian source $src $ver, which is not a sha1."
			[ -n "$name" ] && [[ "$name" != */* ]] && [[ "$name" != .* ]] ||
				fail "snapshot.debian.org gave no usable file name for $sha in the Debian source $src $ver."
			get "$SNAPSHOT/file/$sha" "$tmp/file" ||
				fail "Downloading $name ($sha) of the Debian source $src $ver from snapshot.debian.org failed."
			got="$(sha1sum <"$tmp/file" | awk '{print $1}')"
			[ "$got" = "$sha" ] ||
				fail "$name of the Debian source $src $ver has sha1 $got, but snapshot.debian.org addresses it as $sha; refusing it."
			mv "$tmp/file" "$dir/$name"
			files=$((files + 1))
		done <<<"$list"
		n=$((n + 1))
	done <"$plan"
	echo "source-bundle: fetched $files files for $n Debian source packages into $out/debian."
}

# mk_var FILE NAME — the value of a "NAME = value" line.
mk_var() { sed -n "s/^$2[[:space:]]*=[[:space:]]*//p" "$1" | head -1 | tr -d '[:space:]'; }

cmd_pack() {
	[ "$#" -eq 6 ] || usage
	local sku="$1" ver="$2" legal="$3" baked="$4" br="$5" out="$6"
	[[ "$sku" =~ ^[a-z0-9]+$ ]] || fail "The SKU '$sku' is not a lower-case name."
	[ -f "$legal/manifest.csv" ] || fail "$legal is not a legal-info directory: it has no manifest.csv."
	[ -f "$legal/legal-info.sha256" ] || fail "$legal has no legal-info.sha256, so what ships cannot be verified."
	[ -d "$baked" ] || fail "The baked-image sources directory $baked does not exist."

	local br_tag commit api_ver agent_ver
	br_tag="$(sed -n 's/^BR_TAG="\([^"]*\)".*/\1/p' "$REPO/scripts/init-buildroot.sh")"
	[ -n "$br_tag" ] || fail "Could not read BR_TAG from scripts/init-buildroot.sh."
	commit="$(git -C "$REPO" rev-parse HEAD)" || fail "Could not read the built commit of $REPO."
	api_ver="$(mk_var "$REPO/package/rasputin-api/rasputin-api.mk" RASPUTIN_API_VERSION)"
	agent_ver="$(mk_var "$REPO/package/rasputin-agent/rasputin-agent.mk" RASPUTIN_AGENT_VERSION)"
	[ -n "$api_ver" ] && [ -n "$agent_ver" ] || fail "Could not read the rasputin-api and rasputin-agent versions from their .mk files."

	local name="rasputin-os-$sku-$ver-source"
	local tar="$out/$name.tar" meta="$out/source-$sku.json"
	mkdir -p "$out"
	rm -f -- "$tar" "$meta"
	local stage="$WORK/stage"
	mkdir -p "$stage"
	local root="$stage/$name"
	mkdir -p "$root"

	# legal-info without host-sources/: host tools build the image but are not
	# in it. Its checksum list is cut to match, then proved against the tree.
	mkdir -p "$root/legal-info"
	(cd "$legal" && tar --exclude=./host-sources -cf - .) | (cd "$root/legal-info" && tar -xf -) ||
		fail "Copying $legal into the bundle failed."
	# grep -v exits 1 when every line is a host-sources line (nothing left to
	# list, which sha256sum -c then refuses) and 2 on a read error.
	local rc=0
	grep -v '^[0-9a-f]\{64\}[ *][ *]*host-sources/' "$legal/legal-info.sha256" >"$root/legal-info/legal-info.sha256" || rc=$?
	[ "$rc" -le 1 ] || fail "Reading $legal/legal-info.sha256 failed."
	(cd "$root/legal-info" && sha256sum -c --quiet legal-info.sha256) >&2 ||
		fail "The staged legal-info does not match its own legal-info.sha256, so the bundle would not verify."

	git -C "$REPO" archive --format=tar.gz --prefix="rasputin-os-$commit/" -o "$root/rasputin-os-$commit.tar.gz" "$commit" ||
		fail "Archiving this repository at $commit failed."
	git -C "$br" archive --format=tar.gz --prefix="buildroot-$br_tag/" -o "$root/buildroot-$br_tag.tar.gz" "refs/tags/$br_tag" ||
		fail "Archiving Buildroot at tag $br_tag from $br failed; is init-buildroot.sh's tag checked out there?"
	mkdir -p "$root/baked-images"
	(cd "$baked" && tar -cf - .) | (cd "$root/baked-images" && tar -xf -) ||
		fail "Copying $baked into the bundle failed."

	cat >"$root/README" <<EOF
Rasputin OS $ver, SKU $sku: complete corresponding source

This bundle holds the source of the free and open-source software in the
rasputin-os-$sku-$ver images (.img.xz and .raucb) of the same release.

  Built from     rasputin-os commit $commit
                 rasputin-os-$commit.tar.gz (the build scripts, board files
                 and package recipes)
  Buildroot      tag $br_tag, buildroot-$br_tag.tar.gz
  Configuration  configs/rasputin_${sku}_defconfig in the rasputin-os archive;
                 legal-info/buildroot.config is the resolved configuration

legal-info/ is the output of Buildroot's \`make legal-info\` for this
configuration: manifest.csv lists every target package with its licence,
licenses/ holds each package's licence texts, and sources/ holds the source
archive and patches of every package Buildroot builds into the image.
legal-info.sha256 lists every file in it; check them with
\`sha256sum -c legal-info.sha256\` inside legal-info/.

Host tools (host-sources/ in Buildroot's output) are omitted. They run on the
build machine to produce the image and are not part of it; Buildroot at
$br_tag downloads and builds them from the same configuration.

baked-images/ holds the Debian source packages (.dsc, .orig and .debian
archives, from snapshot.debian.org) of every package in the container images
baked into the image for an offline first boot.

rasputin-api and rasputin-agent are Geekdojo's own software. Their source is
at the control-plane release tags these images pin:
  rasputin-api    $CONTROL_PLANE_URL/tree/v$api_ver
  rasputin-agent  $CONTROL_PLANE_URL/tree/v$agent_ver
EOF

	tar -C "$stage" -cf "$tar" "$name" || fail "Writing $tar failed."
	local bytes sha
	bytes="$(wc -c <"$tar" | tr -d ' ')"
	if [ "$bytes" -gt "$MAX_BYTES" ]; then
		rm -f -- "$tar"
		fail "The source bundle $name.tar is $bytes bytes, over the $MAX_BYTES-byte limit on one release asset."
	fi
	sha="$(sha256sum <"$tar" | awk '{print $1}')"
	jq -n --arg sku "$sku" --arg source "$name.tar" --arg sha "$sha" --argjson bytes "$bytes" \
		'{sku:$sku, source:$source, sourceSha256:$sha, sourceSizeBytes:$bytes}' >"$meta"
	echo "source-bundle: $name.tar is $bytes bytes, sha256 $sha."
}

[ "$#" -ge 1 ] || usage
cmd="$1"
shift
case "$cmd" in
fetch) cmd_fetch "$@" ;;
pack) cmd_pack "$@" ;;
*) usage ;;
esac
