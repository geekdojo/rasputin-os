#!/bin/sh
# Tests that release.yml signs only from main or a pushed tag
# (geekdojo/geekdojo-brain#524).
#
# Why this is tested at all. The sign job holds the release leaf. A dispatch
# runs the workflow and tree of whatever ref it names, so the only thing that
# keeps a branch (or a tag named with --ref) from signing is the ref clause in
# sign's `if:` and the "Signing ref check" step in validate that refuses
# publish=true off main. Losing either to a rebase looks identical in the
# Actions UI: the run is green and the build is signed. Nothing evaluates
# GitHub expressions offline, so this pins the text the probe repo proved.
#
# Run:  sh test/signing-ref-gate-test.sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REL="$ROOT/.github/workflows/release.yml"
[ -f "$REL" ] || { echo "missing: $REL"; exit 1; }

fails=0
ok()  { echo "ok   — $1"; }
bad() { echo "FAIL — $1"; fails=$((fails + 1)); }

# job_block NAME — the lines of release.yml's job NAME, up to the next job.
job_block() {
	awk -v j="  $1:" '$0 == j {f=1; next} f && /^  [A-Za-z0-9_-]+:$/ {f=0} f' "$REL"
}

sign_if=$(job_block sign | grep -E '^    if:')
case "$sign_if" in
	*"(github.event_name == 'push' && startsWith(github.ref, 'refs/tags/'))"*)
		ok "sign signs a tag only on a push" ;;
	*) bad "sign's if: does not scope the tag branch to event push: $sign_if" ;;
esac
case "$sign_if" in
	*"github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main' && "*)
		ok "sign signs a dispatch only from main" ;;
	*) bad "sign's if: does not limit dispatch signing to refs/heads/main: $sign_if" ;;
esac

check_if=$(job_block validate | grep -A1 -E '^      - name: Signing ref check$' | grep -E '^        if:')
case "$check_if" in
	*"github.event_name == 'workflow_dispatch' && github.ref != 'refs/heads/main'"*)
		ok "validate runs the Signing ref check on every non-main dispatch" ;;
	*) bad "validate has no Signing ref check step guarded by a non-main dispatch: '$check_if'" ;;
esac

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all signing ref gate checks passed"
