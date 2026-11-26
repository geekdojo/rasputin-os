#!/bin/sh
#
# update-plan.sh RUN_TAG — the published images the update smoke starts from
# (release.yml's update-plan job; geekdojo/geekdojo-brain#807, #1012).
#
#   gh release list --json tagName,isDraft,isPrerelease,publishedAt \
#     | EXTRA="<versions>" scripts/update-plan.sh "$GITHUB_REF_NAME"
#
# Reads the release list, a JSON array, on stdin. RUN_TAG is this run's own
# tag (a branch name on a dispatch), which is never a base. The bases, in
# order, each once:
#   1. the newest published (non-draft) release: the image most of the fleet
#      updates from;
#   2. the newest stable: non-draft, not a prerelease. Today it is the last
#      release without identity; once Identity 6.6 is cut it is the last
#      identity release, so the one rule covers both;
#   3. each comma-separated version in EXTRA (the update_smoke_from dispatch
#      input, free text), which must be a CalVer release version.
# Prints the matrix JSON, {"include": [...]}, one {arch: amd64, sku: n100}
# and one {arch: arm64, sku: rpi} row per base.
#
# Exit 1, with one ::error:: line, on a list that is not JSON, no published
# release, no stable release, or an EXTRA entry that is not a version. Fails
# closed: with no plan the update smoke does not run, and publish waits on it.
#
# Tested by test/update-plan-test.sh against fixture lists.
set -eu

err() { echo "::error::update-plan: $*"; exit 1; }

[ "$#" = 1 ] || err "usage: update-plan.sh RUN_TAG (the release list on stdin)"
run_tag=$1
list=$(cat)
printf '%s\n' "$list" | jq -e 'type == "array"' >/dev/null 2>&1 || err "the release list on stdin is not a JSON array"

# newest FILTER — the newest release's tag passing FILTER, not this run's.
newest() {
	printf '%s\n' "$list" | jq -r --arg own "$run_tag" \
		"[.[] | select(.isDraft | not) | select(.tagName != \$own) | select($1)] | sort_by(.publishedAt) | reverse | .[0].tagName // empty"
}
prev=$(newest true)
[ -n "$prev" ] || err "no published release to update from"
stable=$(newest '.isPrerelease | not')
[ -n "$stable" ] || err "no published stable release to update from"

bases=$(printf '%s\n%s\n' "$prev" "$stable")
# One version per line; never word-split the input.
extra=$(printf '%s\n' "${EXTRA:-}" | tr ',' '\n' | tr -d ' \t')
while IFS= read -r b; do
	[ -n "$b" ] || continue
	printf '%s\n' "$b" | grep -Eqx '[0-9]{4}\.[0-9]{2}\.[0-9]+(-dev\.[0-9]+)?' \
		|| err "update_smoke_from entry '$b' is not a CalVer release version"
	bases=$(printf '%s\n%s\n' "$bases" "$b")
done <<EOF
$extra
EOF
printf '%s\n' "$bases" | awk 'NF && !seen[$0]++' | jq -Rnc '
	[inputs] as $b | {include: [
		$b[] as $v | ({arch: "amd64", sku: "n100", base: $v}, {arch: "arm64", sku: "rpi", base: $v})
	]}'
