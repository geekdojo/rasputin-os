#!/usr/bin/env bash
#
# bake-mesh-images.sh — pull the pinned mesh container images for one
# architecture, save them as tarballs for post-build.sh to bake into the rootfs,
# and record the image ID of each one.
#
# Usage: scripts/bake-mesh-images.sh <amd64|arm64> <out-dir>
#   MESH_PIN_FILE=<path>  use this mesh-images.json instead of downloading one
#                         (for running this locally against an unreleased pin)
# Needs: docker (with buildx), jq, gh (authenticated) unless MESH_PIN_FILE is set.
#
# WHERE THE REFS COME FROM, AND WHY NOT FROM HERE
#
# board/rasputin/common/mesh-images.list used to carry them, with a comment
# saying in capitals that the headscale ref "MUST match defaultImage" in
# rasputin-control-plane — a sync contract enforced by nobody. When the two
# drifted the baked tarball simply was not matched by the supervisor and it fell
# back to pulling at runtime: no error, no alert, just a controlplane that
# silently needs internet on its first boot, which is the one thing baking the
# image exists to prevent (geekdojo/geekdojo-brain#210, #211).
#
# The pin now comes from the SAME control-plane release this image vendors its
# api from, so the api that reads the pin at runtime and the build that bakes it
# are one version and cannot disagree.
#
# WHY IT RECORDS AN IMAGE ID, AND WHERE THAT ID COMES FROM
#
# `docker load` records no RepoDigest in the classic image store — there was no
# registry pull to record one from — so on the device the digest in the
# reference cannot be checked against the loaded image at all, and `docker image
# inspect <ref>` succeeding proves only that SOMETHING is tagged with that name.
# The identity that IS preserved through `docker save`/`docker load` is the
# image config digest, which the classic store reports as the image ID. So that
# is what is recorded, and the api refuses to start the mesh server from an
# image whose ID is not the one named in loaded-ids.tsv.
#
# It is read out of the SAVED TARBALL (manifest.json -> .Config), not from
# `docker image inspect --format {{.Id}}`. That is not fussiness: under the
# containerd image store `.Id` reports the manifest/index digest instead of the
# config digest, so a build on a containerd-backed runner would record a value
# no classic-store `docker load` ever produces, and every node would then refuse
# the image it was shipped. Measured on Rancher Desktop 29.1.3 with the
# containerd snapshotter: `.Id` gave the index digest 51b1b918..., while the
# tarball's config blob — what `docker load` hashes to make the ID — was
# 8432a58c.... The tarball is the thing the device loads, so the tarball is
# where the answer is.

set -euo pipefail

ARCH="${1:?usage: $0 <amd64|arm64> <out-dir>}"
OUT="${2:?usage: $0 <amd64|arm64> <out-dir>}"
case "$ARCH" in amd64 | arm64) ;; *) echo "::error::bake-mesh-images: unknown arch $ARCH" >&2; exit 1 ;; esac

ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$OUT"

die() { echo "::error::bake-mesh-images: $*" >&2; exit 1; }

PIN="${MESH_PIN_FILE:-}"
if [ -z "$PIN" ]; then
	# The control-plane release this image vendors its api from.
	ver=$(sed -n 's/^RASPUTIN_API_VERSION = //p' "$ROOT/package/rasputin-api/rasputin-api.mk" | tr -d '[:space:]')
	[ -n "$ver" ] || die "could not parse RASPUTIN_API_VERSION from package/rasputin-api/rasputin-api.mk"
	echo "bake-mesh-images: pin from control-plane v$ver"
	work=$(mktemp -d)
	trap 'rm -rf "$work"' EXIT
	gh release download "v$ver" \
		--repo geekdojo/rasputin-control-plane \
		--pattern mesh-images.json \
		--pattern mesh-images.json.sha256 \
		--dir "$work" --clobber \
		|| die "control-plane v$ver publishes no mesh-images.json. The pinned api release must be one that carries it (geekdojo/geekdojo-brain#534); bump RASPUTIN_API_VERSION to such a release."
	if [ -f "$work/mesh-images.json.sha256" ]; then
		want=$(tr -d '[:space:]' < "$work/mesh-images.json.sha256")
		got=$(sha256sum "$work/mesh-images.json" | awk '{print $1}')
		[ "$want" = "$got" ] || die "mesh-images.json is $got, its published .sha256 says $want"
		echo "bake-mesh-images: mesh-images.json sha256 $got (matches the published .sha256)"
	else
		echo "::warning::bake-mesh-images: no published mesh-images.json.sha256 to cross-check"
	fi
	PIN="$work/mesh-images.json"
fi
[ -f "$PIN" ] || die "no pin file at $PIN"

schema=$(jq -r '.schema // empty' "$PIN")
[ "$schema" = "1" ] || die "mesh-images.json schema is '${schema:-<absent>}', this build understands 1"
count=$(jq -r '.images | length' "$PIN")
[ "$count" -gt 0 ] || die "mesh-images.json names no images"

IDS="$OUT/loaded-ids.tsv"
{
	printf '# ref\timage id — written by the rasputin-os build.\n'
	printf '# The api refuses to start the mesh server from an image whose ID is not named here.\n'
} > "$IDS"

jq -r --arg a "linux/$ARCH" \
	'.images | to_entries[] | [.key, .value.ref, (.value.platforms[$a] // "")] | @tsv' "$PIN" \
	> "$OUT/.plan"

while IFS=$'\t' read -r name ref want_digest; do
	[ -n "$ref" ] || die "$name has no ref in mesh-images.json"
	[ -n "$want_digest" ] || die "$name has no linux/$ARCH digest in mesh-images.json"

	# The pin's per-architecture digests must agree with the index the ref
	# names. That ref is digest-pinned, so the index is immutable — which makes
	# this a consistency check on the pin FILE, and the one that catches a
	# platforms map edited by hand or left stale after a version bump.
	got_digest=$(docker buildx imagetools inspect "$ref" --raw \
		| jq -r --arg a "$ARCH" \
			'.manifests[] | select(.platform.os=="linux" and .platform.architecture==$a) | .digest' \
		| head -1)
	[ -n "$got_digest" ] || die "$ref has no linux/$ARCH manifest"
	[ "$got_digest" = "$want_digest" ] \
		|| die "$name linux/$ARCH is $got_digest in the pinned index, but mesh-images.json says $want_digest"
	echo "bake-mesh-images: $name linux/$ARCH digest $got_digest (matches the pin)"

	# Pull and save the PER-ARCHITECTURE reference, not the index one. `docker
	# save` of a multi-platform reference does not mean the same thing in both
	# image stores: under the containerd store it exports whatever platforms
	# the local store happens to hold, which after an `--platform` pull of the
	# index ref was the HOST platform and not the requested one. Measured on
	# Rancher Desktop 29.1.3: the arm64 save came back carrying only the amd64
	# config. Naming the architecture's own manifest digest leaves nothing to
	# choose.
	archRef="${ref%@*}@${want_digest}"
	file="$(printf '%s' "$ref" | tr '/:@' '___')-${ARCH}.tar"
	# --platform as well as the digest: belt and braces, and it is what makes
	# the pull legible in a build log. The image is only saved here, never run.
	docker pull --platform "linux/$ARCH" "$archRef" >/dev/null
	docker save "$archRef" -o "$OUT/$file"

	# The config blob inside the tarball: exactly what `docker load` hashes to
	# produce the image ID in the classic store. Store-independent, because it
	# is a property of the file, not of this runner's daemon.
	#
	# The entry is chosen by the ARCHITECTURE recorded in each config blob, not
	# by taking manifest.json[0]. A tarball can hold more than one platform --
	# `docker save` under the containerd image store exports every platform the
	# local store happens to hold, so after pulling amd64 and then arm64 the
	# second save carries both and [0] is whichever was pulled first. Measured:
	# the arm64 save came out 61 MB against amd64's 32 MB and both reported the
	# same [0] config digest. Recording that would mean every arm64 node
	# refusing the image it was shipped.
	# Even with a single-platform reference, assert the config's architecture
	# rather than trusting the export. This is the check that would have caught
	# the containerd behaviour above, and it costs one tar read.
	entries=$(tar -xOf "$OUT/$file" manifest.json | jq -r '.[].Config')
	[ -n "$entries" ] || die "$file has no Config entry in its manifest.json"
	nentries=$(printf '%s\n' "$entries" | wc -l | tr -d ' ')
	if [ "$nentries" -gt 1 ]; then
		# Not fatal -- the right entry is still selectable -- but it is dead
		# weight in a rootfs with an image budget, and worth seeing in a log.
		echo "::warning::bake-mesh-images: $file carries $nentries platforms; only linux/$ARCH is needed"
	fi
	id=""
	for cfg in $entries; do
		got_arch=$(tar -xOf "$OUT/$file" "$cfg" | jq -r '.architecture // empty')
		if [ "$got_arch" = "$ARCH" ]; then
			id="sha256:$(basename "$cfg")"
			break
		fi
	done
	[ -n "$id" ] || die "$file carries no linux/$ARCH image (configs: $(printf '%s' "$entries" | tr '\n' ' '))"
	case "$id" in
		sha256:????????????????????????????????????????????????????????????????) ;;
		*) die "$file names a config blob that is not a sha256 digest: $id" ;;
	esac
	printf '%s\t%s\n' "$ref" "$id" >> "$IDS"
	echo "bake-mesh-images: saved $file (image id $id, linux/$ARCH)"
done < "$OUT/.plan"
rm -f "$OUT/.plan"

echo "----- baked mesh image tarballs -----"
ls -lh "$OUT"
echo "----- loaded-ids.tsv -----"
cat "$IDS"
