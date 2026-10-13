#!/bin/sh
#
# api-tarball.sh — fetch the pinned rasputin-api release tarball the way the
# image build does, and take the secrets store's policy text out of it.
# Sourced, never run (geekdojo/geekdojo-brain#804). test/store-unit-functional.sh
# and test/store-policy-live-drift.sh share it.
#
#   api_policy_fetch ROOT BR_ARCH WORK
#       Reads RASPUTIN_API_SITE and RASPUTIN_API_SOURCE from ROOT's
#       package/rasputin-api/rasputin-api.mk with real GNU make (mk-var.sh,
#       which the caller sources), BR_ARCH being BR2_x86_64 or BR2_aarch64;
#       downloads the tarball into WORK; checks its sha256 against the line for
#       it in package/rasputin-api/rasputin-api.hash; and extracts its
#       openbao-policy/ to WORK/openbao-policy. Sets API_VERSION
#       (RASPUTIN_API_VERSION) and API_POLICY (that directory). Returns 0, or
#       non-zero with a sentence on stdout naming what failed: a pin it cannot
#       read, a failed download, a hash that does not match, or a tarball with
#       no openbao-policy/.
#
# TEST-ONLY OVERRIDE. RASPUTIN_API_TARBALL=<path> takes that local tarball
# instead of downloading the pinned one, and skips the hash check, because a
# local build is not the pinned release. It prints a line starting
# "LOCAL OVERRIDE:" saying so, so no log that used it can be read as a run
# against the pin. CI never sets it; it exists so the os side can be shown
# against a control-plane build before that build is released.
#
# Needs: GNU make, curl, openssl, tar.

api_policy_fetch() {
	_af_root=$1 _af_arch=$2 _af_work=$3
	_af_mk="$_af_root/package/rasputin-api/rasputin-api.mk"
	_af_hash="$_af_root/package/rasputin-api/rasputin-api.hash"
	API_VERSION=$(mk_var "$_af_mk" RASPUTIN_API_VERSION) \
		|| { echo "FAILED: could not read RASPUTIN_API_VERSION from $_af_mk."; return 1; }
	_af_src=$(mk_var "$_af_mk" RASPUTIN_API_SOURCE "$_af_arch=y") \
		|| { echo "FAILED: could not read RASPUTIN_API_SOURCE from $_af_mk for $_af_arch."; return 1; }
	_af_site=$(mk_var "$_af_mk" RASPUTIN_API_SITE) \
		|| { echo "FAILED: could not read RASPUTIN_API_SITE from $_af_mk."; return 1; }
	mkdir -p "$_af_work"
	if [ -n "${RASPUTIN_API_TARBALL:-}" ]; then
		echo "LOCAL OVERRIDE: using RASPUTIN_API_TARBALL=$RASPUTIN_API_TARBALL instead of the pinned $_af_src, with no hash check. This run says nothing about the pin."
		cp "$RASPUTIN_API_TARBALL" "$_af_work/$_af_src" \
			|| { echo "FAILED: the local tarball $RASPUTIN_API_TARBALL could not be read."; return 1; }
	else
		_af_want=$(awk -v s="$_af_src" '$1 == "sha256" && $3 == s { print $2 }' "$_af_hash" 2>/dev/null)
		[ -n "$_af_want" ] || { echo "FAILED: $_af_hash has no sha256 line for $_af_src."; return 1; }
		echo "downloading $_af_site/$_af_src"
		curl -fsSL -o "$_af_work/$_af_src" "$_af_site/$_af_src" \
			|| { echo "FAILED: the download of $_af_site/$_af_src failed, so there is no api tarball to take the policy text from."; return 1; }
		_af_got=$(openssl dgst -sha256 -r "$_af_work/$_af_src" | cut -d' ' -f1)
		[ "$_af_got" = "$_af_want" ] \
			|| { echo "FAILED: $_af_src does not match rasputin-api.hash (got $_af_got, want $_af_want)."; return 1; }
		echo "  $_af_src matches rasputin-api.hash"
	fi
	rm -rf "$_af_work/openbao-policy"
	tar -xzf "$_af_work/$_af_src" -C "$_af_work" openbao-policy >/dev/null 2>&1 \
		|| { echo "FAILED: $_af_src (api $API_VERSION) holds no openbao-policy/, so it carries no policy text for the store."; return 1; }
	# shellcheck disable=SC2034 # read by the caller
	API_POLICY="$_af_work/openbao-policy"
	return 0
}
