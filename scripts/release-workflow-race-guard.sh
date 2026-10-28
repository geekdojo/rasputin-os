#!/usr/bin/env bash
#
# release-workflow-race-guard.sh REMOTE BRANCH TAG BUILT_SHA
#
# Refuses to create release tag TAG on BUILT_SHA when BRANCH on REMOTE has
# moved past it with changes under .github/workflows.
#
# GitHub treats creating a tag on a commit whose .github/workflows differs from
# the default-branch head as a workflow change, and a workflow change needs the
# `workflows` permission, which GITHUB_TOKEN can never be given. So when a PR
# that edits a workflow merges while a dispatch-publish run is building, that
# run's `gh release create --target BUILT_SHA` fails at the very end with
# "HTTP 403: Resource not accessible by integration", which says nothing about
# why (run 40559492216, #343: built cb58b72, then #181 merged 6a0248e, which
# changed ci.yml and release.yml). This guard runs first and names the race.
#
# It explains the race; it does not prevent it. The durable fix is a GitHub
# App token with workflows: write for the publish step.
#
# Run from inside a clone that has BUILT_SHA (the publish job's checkout). It
# fetches only BRANCH's head commit from REMOTE (depth 1, no tags) and diffs
# .github/workflows between the two trees. For an https REMOTE, `gh` supplies
# the credentials (GH_TOKEN in Actions), so nothing is written to .git/config.
#
# Exit status:
#   0  .github/workflows is the same at BUILT_SHA and BRANCH's head
#   1  .github/workflows differs: GITHUB_TOKEN cannot create TAG on BUILT_SHA
#   2  usage error, or REMOTE/BRANCH could not be read, or the diff failed
#      (never reported as "same")
#
# test/release-workflow-race-guard-test.sh covers every status.

set -euo pipefail

fail() {
	local status="$1"
	shift
	printf '::error::release-workflow-race-guard: %s\n' "$*" >&2
	exit "$status"
}

[ "$#" -eq 4 ] || fail 2 "usage: release-workflow-race-guard.sh REMOTE BRANCH TAG BUILT_SHA"
remote="$1"
branch="$2"
tag="$3"
built="$4"

# Plain ref-name alphabets only, so nothing here is read as a refspec,
# glob or option by git.
[[ "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || fail 2 "refusing branch name '$branch'"
[[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || fail 2 "refusing tag name '$tag'"
[[ "$built" =~ ^[0-9a-f]{40}$ ]] || fail 2 "built commit '$built' is not a full 40-character SHA"

errfile="$(mktemp)"
trap 'rm -f -- "$errfile"' EXIT

git cat-file -e "$built^{commit}" 2>"$errfile" \
	|| fail 2 "built commit $built is not in this clone: $(tr '\n' ' ' <"$errfile")"

if ! GIT_TERMINAL_PROMPT=0 git \
	-c credential.helper= -c 'credential.helper=!gh auth git-credential' \
	fetch --quiet --no-tags --depth=1 -- "$remote" "refs/heads/$branch" 2>"$errfile"; then
	fail 2 "could not fetch $branch from $remote: $(tr '\n' ' ' <"$errfile")"
fi
head="$(git rev-parse --verify --quiet 'FETCH_HEAD^{commit}')" \
	|| fail 2 "fetched $branch from $remote but FETCH_HEAD is not a commit"

if [ "$head" = "$built" ]; then
	echo "release-workflow-race-guard: $branch is still at the built commit $built"
	exit 0
fi

# git diff --quiet: 0 = same, 1 = differs, anything else = git failed.
rc=0
git diff --quiet "$built" "$head" -- .github/workflows 2>"$errfile" || rc=$?
case "$rc" in
0)
	echo "release-workflow-race-guard: $branch moved to $head, but .github/workflows matches the built commit $built"
	exit 0
	;;
1) ;;
*) fail 2 "could not diff .github/workflows between $built and $head: $(tr '\n' ' ' <"$errfile")" ;;
esac

changed="$(git diff --name-only "$built" "$head" -- .github/workflows 2>"$errfile" | paste -sd ' ' -)" \
	|| fail 2 "could not list the .github/workflows changes between $built and $head: $(tr '\n' ' ' <"$errfile")"
fail 1 "$branch moved past $built to $head with workflow changes ($changed). GitHub counts a new tag on $built as a workflow change, and GITHUB_TOKEN cannot get the workflows permission, so this run cannot create $tag there. Nothing was published. Re-dispatch the release on $branch."
