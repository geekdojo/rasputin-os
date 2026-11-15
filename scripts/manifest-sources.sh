#!/usr/bin/env bash
#
# manifest-sources.sh ARTIFACTS_JSONL META_DIR — add each SKU's source bundle
# to its own manifest.json artifact entry (geekdojo/geekdojo-brain#970).
#
# The sign job writes one JSON object per SKU to ARTIFACTS_JSONL. Each
# source-bundle leg writes a META_DIR/source-<sku>.json
# ({"sku", "source", "sourceSha256", "sourceSizeBytes"}, by
# scripts/source-bundle.sh pack). This prints ARTIFACTS_JSONL again on stdout,
# one entry per line, with the source, sourceSha256 and sourceSizeBytes of the
# meta file whose .sku equals the entry's .sku.
#
# The selection is by the meta's own .sku field, never by file order or name,
# so one SKU's bundle cannot be signed into the other SKU's entry. It refuses,
# printing nothing on stdout, when an entry has:
#   - no meta file with its sku, or more than one;
#   - a meta whose source is not named rasputin-os-<sku>-...-source.tar;
#   - a meta whose sourceSha256 is not 64 lower-case hex characters or whose
#     sourceSizeBytes is not a positive whole number.
# The sign job builds manifest.json from this output, so a refusal means no
# manifest and no release (the publish gate then also refuses an entry with
# no source; scripts/release-manifest-gate.sh).
#
# Exit status: 0 printed; 1 a refusal above, one "::error::manifest-sources:
# <sentence>" line per defect on stderr; 2 wrong usage or an unreadable or
# non-JSON input. Needs jq. test/source-bundle-test.sh covers every status.

set -euo pipefail

refuse() {
	printf '::error::manifest-sources: %s\n' "$*" >&2
	exit 2
}

[ "$#" -eq 2 ] || refuse "Usage: manifest-sources.sh ARTIFACTS_JSONL META_DIR."
artifacts="$1"
meta_dir="$2"
[ -r "$artifacts" ] || refuse "Cannot read the artifact list $artifacts."
[ -d "$meta_dir" ] || refuse "The source meta directory $meta_dir does not exist."

shopt -s nullglob
metas=("$meta_dir"/*.json)
shopt -u nullglob
if [ "${#metas[@]}" -eq 0 ]; then
	all='[]'
else
	all="$(jq -s '.' "${metas[@]}" 2>/dev/null)" || refuse "A source meta file in $meta_dir is not valid JSON."
fi
jq -s '.' "$artifacts" >/dev/null 2>&1 || refuse "The artifact list $artifacts is not valid JSON lines."

# Every defect, one per line; empty when every entry has exactly one good meta.
defects="$(jq -r --argjson metas "$all" '
	. as $a | ($a.sku // "") as $sku
	| [$metas[] | select(.sku == $sku)] as $m
	| if $sku == "" then "An artifact entry has no sku, so no source bundle can be matched to it."
	  elif ($m | length) == 0 then "No source meta has sku \($sku), so the \($sku) entry would ship without its source bundle."
	  elif ($m | length) > 1 then "\($m | length) source meta files have sku \($sku); exactly one is expected."
	  elif (($m[0].source | type) != "string") or ($m[0].source | startswith("rasputin-os-\($sku)-") and endswith("-source.tar") | not)
	    then "The \($sku) source meta names \($m[0].source | tostring), which is not a rasputin-os-\($sku)-<version>-source.tar."
	  elif (($m[0].sourceSha256 | type) != "string") or ($m[0].sourceSha256 | test("^[0-9a-f]{64}$") | not)
	    then "The \($sku) source meta gives sourceSha256 \($m[0].sourceSha256 | tostring), which is not 64 lower-case hex characters."
	  elif (($m[0].sourceSizeBytes | type) != "number") or ($m[0].sourceSizeBytes < 1) or ($m[0].sourceSizeBytes | floor) != $m[0].sourceSizeBytes
	    then "The \($sku) source meta gives sourceSizeBytes \($m[0].sourceSizeBytes | tostring), which is not a positive whole number."
	  else empty end' "$artifacts")"
if [ -n "$defects" ]; then
	while IFS= read -r d; do printf '::error::manifest-sources: %s\n' "$d" >&2; done <<<"$defects"
	exit 1
fi

jq -c --argjson metas "$all" '
	.sku as $sku | ([$metas[] | select(.sku == $sku)][0]) as $m
	| . + {source: $m.source, sourceSha256: $m.sourceSha256, sourceSizeBytes: $m.sourceSizeBytes}' "$artifacts"
