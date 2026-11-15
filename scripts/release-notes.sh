#!/usr/bin/env bash
#
# release-notes.sh TAG CHANNEL REPO_URL SKU... — the GitHub release notes of
# a rasputin-os release (geekdojo/geekdojo-brain#970).
#
# Prints the channel and the verify sentence the publish job has always
# carried, then one link per SKU to that SKU's source bundle,
# REPO_URL/releases/download/TAG/rasputin-os-<sku>-TAG-source.tar: the
# complete corresponding source of the GPL components in that SKU's images.
# REPO_URL is the repository's web URL, with no trailing .git.
#
# Exit status: 0 printed; 2 wrong usage, with one ::error:: sentence.
# test/source-bundle-test.sh covers it.

set -euo pipefail

if [ "$#" -lt 4 ]; then
	echo "::error::release-notes: Usage: release-notes.sh TAG CHANNEL REPO_URL SKU..." >&2
	exit 2
fi
tag="$1"
channel="$2"
repo_url="${3%/}"
shift 3

printf '%s\n' "Channel: \`${channel}\`. Verify the chain with the public root CA (https://rasputin.geekdojo.com/rasputin-root-ca.pem): \`manifest.json.sig\` is a detached DER CMS signature over \`manifest.json\`, which carries per-asset SHA-256. Verify commands: https://rasputin.geekdojo.com/docs/agents/."
printf '\n%s\n\n' "Source code: each image's GPL components ship with their complete corresponding source, one bundle per SKU, listed with its SHA-256 in \`manifest.json\`:"
for sku in "$@"; do
	printf -- '- %s: %s/releases/download/%s/rasputin-os-%s-%s-source.tar\n' "$sku" "$repo_url" "$tag" "$sku" "$tag"
done
