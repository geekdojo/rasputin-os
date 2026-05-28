#!/usr/bin/env bash
#
# init-buildroot.sh — add the pinned Buildroot LTS as a submodule.
#
# We keep Buildroot a pristine pinned checkout (os-images/buildroot-os.md §1)
# and put all customization in this external tree. Run once after cloning.
#
set -euo pipefail

# Pin: Buildroot 2025.02.x LTS (3-year CVE backport window). Bump to the
# next LTS (2027.02) as a deliberate maintenance step — update BR_TAG and
# the cache key in .github/workflows/release.yml together.
BR_REPO="https://gitlab.com/buildroot.org/buildroot.git"
BR_TAG="2025.02.3"   # TODO: confirm the latest 2025.02.x point release

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
