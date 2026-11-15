#!/usr/bin/env bash
#
# release-version.sh — the CalVer version, channel and prerelease flag of a
# release run, decided once for every job that needs them.
# (geekdojo/geekdojo-brain#970)
#
# Usage: scripts/release-version.sh >> "$GITHUB_OUTPUT"
#
# Reads the GitHub Actions environment:
#   GITHUB_REF_TYPE    "tag" on a tag push; anything else is a dispatch
#   GITHUB_REF_NAME    the tag, on a tag push
#   TARGET_VERSION     the org var RASPUTIN_VERSION (YYYY.MM.MICRO), the
#                      current dev target shared across the three Rasputin
#                      repos; read only on a dispatch
#   GITHUB_RUN_NUMBER  this workflow's run number; the dev.N of a dispatch
#
# Prints three lines on stdout:
#   version=<tag>, or <TARGET_VERSION>-dev.<run number> on a dispatch
#   channel=dev when the version carries -dev, otherwise stable
#   prerelease=true on the dev channel, otherwise false
#
# Exit status: 0 printed; 1 a dispatch with TARGET_VERSION unset or empty,
# with one ::error:: sentence on stderr and nothing on stdout.
#
# The build, sign and source-bundle jobs each carried or would carry their own
# copy of this logic; it lives here so the artifact names they agree on come
# from one place. test/source-bundle-test.sh covers every branch.

set -euo pipefail

if [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
	version="${GITHUB_REF_NAME:?GITHUB_REF_NAME is unset on a tag push}"
else
	if [ -z "${TARGET_VERSION:-}" ]; then
		echo "::error::release-version: The org var RASPUTIN_VERSION is unset, so a dev build cannot be versioned. Set it to the current dev target (e.g. 2026.07.1): gh variable set RASPUTIN_VERSION --org geekdojo --body 2026.07.1 --visibility all." >&2
		exit 1
	fi
	version="${TARGET_VERSION}-dev.${GITHUB_RUN_NUMBER:?GITHUB_RUN_NUMBER is unset}"
fi

case "$version" in
*-dev*) channel=dev prerelease=true ;;
*) channel=stable prerelease=false ;;
esac

printf 'version=%s\nchannel=%s\nprerelease=%s\n' "$version" "$channel" "$prerelease"
