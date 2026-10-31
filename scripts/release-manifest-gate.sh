#!/usr/bin/env bash
#
# release-manifest-gate.sh DIR MANIFEST_SHA256 MANIFEST_SIG_SHA256
#
# Proves every file the publish job is about to release is the file the sign
# job signed for. (geekdojo/geekdojo-brain#902)
#
# The publish job downloads the signed release from the artifact store into DIR
# and runs `gh release create ... DIR/*`. A download that comes back short or
# altered would otherwise be published under the right name, next to a signed
# manifest.json that no longer describes it. This gate runs between the download
# and the publish, over exactly the files DIR/* expands to:
#
#   - every file other than manifest.json and manifest.json.sig must be named in
#     manifest.json's artifacts[] (as .raucb or .image), with the size and
#     sha256 the manifest gives (sizeBytes/sha256, imageSizeBytes/imageSha256);
#     size is checked first, so a truncation reads as "N bytes, but ... gives M";
#   - every file the manifest names must be present;
#   - manifest.json and manifest.json.sig are not in the manifest, so each must
#     match the sha256 the sign job computed after signing (and then proved with
#     its self-verify step). Those pins arrive as arguments, from the sign job's
#     outputs, not through the artifact store the files came through.
#
# Every defect is reported before exit, so one run names every bad file.
#
# Exit status:
#   0  every file matches; one "ok NAME BYTES SHA256" line per file, then a
#      summary line, on stdout
#   1  the release content is wrong: a file missing, extra, of the wrong size or
#      sha256, or not a regular file, or manifest.json / .sig not matching a pin
#   2  the check cannot run: wrong argument count, a pin that is not 64
#      lower-case hex characters, an unreadable DIR or file, or a manifest that
#      does not parse, has no artifacts, or has an entry with a missing name,
#      sha256 or size, a duplicate name, or a name containing "/"
#
# Needs jq and sha256sum on PATH. test/release-manifest-gate-test.sh covers
# every status.

set -euo pipefail

MANIFEST=manifest.json
SIG=manifest.json.sig

refuse() {
	printf '::error::release-manifest-gate: %s\n' "$*" >&2
	exit 2
}

defects=0
defect() {
	printf '::error::release-manifest-gate: %s\n' "$*" >&2
	defects=$((defects + 1))
}

is_sha256() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }

sha_of() { sha256sum <"$1" | awk '{print $1}'; }
size_of() { wc -c <"$1" | tr -d ' '; }

[ "$#" -eq 3 ] || refuse "usage: release-manifest-gate.sh DIR MANIFEST_SHA256 MANIFEST_SIG_SHA256"
dir="$1"
manifest_pin="$2"
sig_pin="$3"

is_sha256 "$manifest_pin" || refuse "the manifest.json pin '$manifest_pin' is not a 64-character lower-case sha256."
is_sha256 "$sig_pin" || refuse "the manifest.json.sig pin '$sig_pin' is not a 64-character lower-case sha256."
[ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] || refuse "cannot read the release directory $dir."

if [ ! -f "$dir/$MANIFEST" ]; then
	defect "$MANIFEST is missing from $dir, so nothing in it can be checked."
	exit 1
fi
[ -r "$dir/$MANIFEST" ] || refuse "cannot read $dir/$MANIFEST."

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
expected="$tmp/expected.tsv" # NAME<TAB>SHA256<TAB>BYTES, one per manifest entry
seen="$tmp/seen"
: >"$seen"

jq -e . "$dir/$MANIFEST" >/dev/null 2>&1 || refuse "$MANIFEST is not valid JSON."
jq -e '(.artifacts | type) == "array" and (.artifacts | length) > 0' "$dir/$MANIFEST" >/dev/null 2>&1 ||
	refuse "$MANIFEST has no artifacts."
# Each artifact names two files: the RAUC bundle and the compressed image. A
# missing or null field becomes an empty column and is refused below.
jq -r '.artifacts[]
	| ([.raucb, .sha256, .sizeBytes], [.image, .imageSha256, .imageSizeBytes])
	| map(if . == null then "" else tostring end)
	| @tsv' "$dir/$MANIFEST" >"$expected" ||
	refuse "$MANIFEST artifacts could not be read."

while IFS=$'\t' read -r name sha bytes; do
	[ -n "$name" ] || refuse "$MANIFEST has an artifact entry with no file name."
	case "$name" in */*) refuse "$MANIFEST names '$name', which contains a '/'." ;; esac
	case "$name" in "$MANIFEST" | "$SIG") refuse "$MANIFEST lists $name as an artifact." ;; esac
	is_sha256 "$sha" || refuse "$MANIFEST gives $name the sha256 '$sha', which is not 64 lower-case hex characters."
	[[ "$bytes" =~ ^[0-9]+$ ]] || refuse "$MANIFEST gives $name the size '$bytes', which is not a whole number of bytes."
done <"$expected"
dup="$(cut -f1 "$expected" | sort | uniq -d | head -1)"
[ -z "$dup" ] || refuse "$MANIFEST names $dup more than once."

# The checked set is exactly what `gh release create ... DIR/*` would upload.
checked=0
for f in "$dir"/*; do
	[ -e "$f" ] || [ -L "$f" ] || continue # an empty DIR leaves the glob unexpanded
	name="$(basename -- "$f")"
	printf '%s\n' "$name" >>"$seen"
	if [ -L "$f" ] || [ ! -f "$f" ]; then
		defect "$name is not a regular file."
		continue
	fi
	[ -r "$f" ] || refuse "cannot read $f."
	got_bytes="$(size_of "$f")"
	got_sha="$(sha_of "$f")"
	case "$name" in
	"$MANIFEST" | "$SIG")
		if [ "$name" = "$MANIFEST" ]; then want_sha="$manifest_pin"; else want_sha="$sig_pin"; fi
		if [ "$got_sha" != "$want_sha" ]; then
			defect "$name has sha256 $got_sha, but the sign job pinned $want_sha."
			continue
		fi
		;;
	*)
		entry="$(N="$name" awk -F'\t' '$1 == ENVIRON["N"]' "$expected")"
		if [ -z "$entry" ]; then
			defect "$name would be published but is not in the signed manifest."
			continue
		fi
		IFS=$'\t' read -r _ want_sha want_bytes <<<"$entry"
		if [ "$got_bytes" != "$want_bytes" ]; then
			defect "$name is $got_bytes bytes, but the signed manifest gives $want_bytes."
			continue
		fi
		if [ "$got_sha" != "$want_sha" ]; then
			defect "$name has sha256 $got_sha, but the signed manifest gives $want_sha."
			continue
		fi
		;;
	esac
	printf 'ok %s %s %s\n' "$name" "$got_bytes" "$got_sha"
	checked=$((checked + 1))
done

grep -Fxq -- "$SIG" "$seen" || defect "$SIG is missing from $dir."
while IFS=$'\t' read -r name _ _; do
	grep -Fxq -- "$name" "$seen" || defect "$name is in the signed manifest but missing from $dir."
done <"$expected"

if [ "$defects" -ne 0 ]; then
	printf '::error::release-manifest-gate: %d defect(s) in %s; refusing to publish.\n' "$defects" "$dir" >&2
	exit 1
fi
echo "release-manifest-gate: all $checked files in $dir match the signed manifest"
