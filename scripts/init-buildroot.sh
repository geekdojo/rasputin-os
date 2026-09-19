#!/usr/bin/env bash
#
# init-buildroot.sh — add the pinned Buildroot release as a submodule.
#
# We keep Buildroot a pristine pinned checkout (os-images/buildroot-os.md §1)
# and put all customization in this external tree. Run once after cloning.
#
set -euo pipefail

# Pin: a specific Buildroot release tag, never a branch. Currency policy
# (ADR-0007): track the latest Buildroot release and stay at most two
# quarterly releases behind, rather than holding an LTS series to end of life.
# Bumping is a deliberate maintenance step: change BR_TAG here (the release.yml
# cache key hashes this file, so it rolls over on its own) and run the full
# bench regression before shipping.
BR_REPO="https://gitlab.com/buildroot.org/buildroot.git"
BR_TAG="2026.08"  # Buildroot 2026.08 (quarterly release, tagged 2026-09-04)

cd "$(dirname "$0")/.."

if [ -d buildroot/.git ] || git config --file .gitmodules --get submodule.buildroot.path >/dev/null 2>&1; then
	echo "buildroot submodule already present; fetching pinned tag $BR_TAG"
	git -C buildroot fetch --depth 1 origin "refs/tags/$BR_TAG:refs/tags/$BR_TAG"
	git -C buildroot checkout "$BR_TAG"
else
	echo "adding buildroot submodule at $BR_TAG (shallow)…"
	git submodule add --depth 1 "$BR_REPO" buildroot
	git -C buildroot fetch --depth 1 origin "refs/tags/$BR_TAG:refs/tags/$BR_TAG"
	git -C buildroot checkout "$BR_TAG"
fi

echo
echo "Buildroot ready at tag $BR_TAG."
echo "Next:"
echo "  make -C buildroot BR2_EXTERNAL=\$PWD O=\$PWD/output/n100 rasputin_n100_defconfig"
echo "  make -C buildroot BR2_EXTERNAL=\$PWD O=\$PWD/output/n100"
