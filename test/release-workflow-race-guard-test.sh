#!/usr/bin/env bash
#
# release-workflow-race-guard-test.sh — tests for
# scripts/release-workflow-race-guard.sh.
#
# Run:  bash test/release-workflow-race-guard-test.sh
#
# Builds a throwaway git remote whose branches stand in for main at publish
# time: still on the built commit, moved on with no workflow change, moved on
# with a workflow edited, added or deleted. The guard runs inside a depth-1
# clone of the built commit, the shape actions/checkout gives the publish job,
# and every exit status is checked: same, differs, unreadable remote, missing
# branch, built commit absent, bad arguments. No network, no GitHub.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
GUARD="${GUARD:-$here/../scripts/release-workflow-race-guard.sh}"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

# Hermetic git: no user or system config (signing, hooks, default branch).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

remote="$tmp/remote.git"
git init -q --bare "$remote"
git init -q "$tmp/work"
w() { git -C "$tmp/work" "$@"; }
mkdir -p "$tmp/work/.github/workflows" "$tmp/work/board"
echo "ci v1" >"$tmp/work/.github/workflows/ci.yml"
echo "release v1" >"$tmp/work/.github/workflows/release.yml"
echo "board v1" >"$tmp/work/board/config"
w add -A
w commit -q -m built
built="$(w rev-parse HEAD)"
w push -q "$remote" HEAD:refs/heads/same

# put PATH CONTENT — write CONTENT to PATH under the work tree.
put() { printf '%s\n' "$2" >"$tmp/work/$1"; }

# One branch per scenario, each a single commit on top of the built commit.
branch_from_built() {
	local name="$1" msg="$2"
	shift 2
	w checkout -q --detach "$built"
	"$@"
	w add -A
	w commit -q -m "$msg"
	w push -q "$remote" "HEAD:refs/heads/$name"
}
branch_from_built moved-clean "board only" \
	put board/config "board v2"
branch_from_built moved-wf "edit release.yml" \
	put .github/workflows/release.yml "release v2"
branch_from_built moved-wf-added "add a workflow" \
	put .github/workflows/new.yml "new"
branch_from_built moved-wf-deleted "delete ci.yml" \
	rm -- "$tmp/work/.github/workflows/ci.yml"
# Two commits that change a workflow and change it back: the trees match.
branch_from_built moved-wf-reverted "edit ci.yml" \
	put .github/workflows/ci.yml "ci v2"
echo "ci v1" >"$tmp/work/.github/workflows/ci.yml"
w commit -q -am "revert ci.yml"
w push -q "$remote" HEAD:refs/heads/moved-wf-reverted --force

# The publish job's checkout: depth 1, the built commit only.
git clone -q --depth 1 --branch same "file://$remote" "$tmp/clone"

failures=0
# check NAME WANT_STATUS WANT_OUTPUT ARGS... — WANT_OUTPUT is a fixed string
# the combined output must contain ("" = anything). Runs in the clone.
check() {
	local name="$1" want_status="$2" want_output="$3"
	shift 3
	local status=0 output
	output="$(cd "$tmp/clone" && "$GUARD" "$@" 2>&1)" || status=$?
	if [ "$status" != "$want_status" ]; then
		printf 'FAIL %s: exit %s, want %s\n%s\n' "$name" "$status" "$want_status" "$output"
		failures=$((failures + 1))
	elif [ -n "$want_output" ] && ! grep -qF -- "$want_output" <<<"$output"; then
		printf 'FAIL %s: output lacks %q\n%s\n' "$name" "$want_output" "$output"
		failures=$((failures + 1))
	else
		printf 'ok   %s\n' "$name"
	fi
}

url="file://$remote"
tag=2026.10.1-dev.343
check "branch still on the built commit passes" 0 "still at the built commit" "$url" same "$tag" "$built"
check "branch moved with no workflow change passes" 0 ".github/workflows matches" "$url" moved-clean "$tag" "$built"
check "branch moved with a workflow change and back passes" 0 ".github/workflows matches" "$url" moved-wf-reverted "$tag" "$built"
check "a workflow edited on the branch fails" 1 "with workflow changes (.github/workflows/release.yml)" "$url" moved-wf "$tag" "$built"
check "the failure names the tag and the fix" 1 "cannot create $tag there. Nothing was published. Re-dispatch the release on moved-wf." "$url" moved-wf "$tag" "$built"
check "the failure is an ::error:: annotation" 1 "::error::" "$url" moved-wf "$tag" "$built"
check "a workflow added on the branch fails" 1 ".github/workflows/new.yml" "$url" moved-wf-added "$tag" "$built"
check "a workflow deleted on the branch fails" 1 ".github/workflows/ci.yml" "$url" moved-wf-deleted "$tag" "$built"
check "a plain path remote works too" 1 "with workflow changes" "$remote" moved-wf "$tag" "$built"
check "an unreadable remote is status 2, never 'same'" 2 "could not fetch" "$tmp/no-such-remote.git" same "$tag" "$built"
check "a missing branch is status 2, never 'same'" 2 "could not fetch" "$url" no-such-branch "$tag" "$built"
check "a built commit absent from the clone is status 2" 2 "is not in this clone" "$url" same "$tag" "$(printf '%040d' 0 | tr 0 a)"
check "a short SHA is refused" 2 "not a full 40-character SHA" "$url" same "$tag" "${built:0:7}"
check "an upper-case SHA is refused" 2 "not a full 40-character SHA" "$url" same "$tag" "$(tr 'a-f' 'A-F' <<<"$built")"
check "a branch name starting with a dash is refused" 2 "refusing branch name" "$url" '-same' "$tag" "$built"
check "a branch name with glob characters is refused" 2 "refusing branch name" "$url" 'same*' "$tag" "$built"
check "a tag name with glob characters is refused" 2 "refusing tag name" "$url" same 'v*' "$built"
check "missing arguments are a usage error" 2 "usage" "$url" same "$tag"

if [ "$failures" -ne 0 ]; then
	echo "$failures release-workflow-race-guard test(s) failed"
	exit 1
fi
echo "all release-workflow-race-guard tests passed"
