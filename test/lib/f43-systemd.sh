#!/bin/sh
#
# f43-systemd.sh — the container image the systemd functional tests run in:
# Fedora 43 with systemd 258.7, the release Buildroot 2026.08 builds into the
# image. Sourced, never run (geekdojo/geekdojo-brain#754).
#
#   f43_systemd_image TAG
#
# Builds the image as TAG and returns 0 only if systemd in it is exactly
# 258.7. Any other outcome prints a sentence and returns non-zero, so a caller
# that stops on failure never tests against a different systemd.
#
# Why exactly 258.7. What systemd-tmpfiles and journald do with a line here is
# what they do on a node only if they are the same release. Fedora 43 shipped
# 258.7, and the f43 repos have since moved past it, so the exact build comes
# from Fedora's updates-archive repo (fedora-repos-archive), which keeps every
# update build f43 has shipped. It is an ordinary dnf repo with gpgcheck=1, so
# the packages are verified against Fedora's signing keys; installing koji URLs
# directly, as these tests used to, skips that (dnf's localpkg_gpgcheck is 0)
# and failed CI outright while koji was down for Fedora infrastructure
# maintenance (2026-10-02, fedora-infrastructure ticket #13500). The build
# fails loudly if that exact version is no longer installable, and the version
# is checked again in the built image, so a tag that somehow carries another
# build is refused too.
#
# Needs: docker.

F43_SYSTEMD_VERSION=258.7

# f43_systemd_is_pinned IMAGE — 0 when IMAGE's systemd is exactly the pinned
# release. Separate from the build so test/store-paths-functional.sh can show it
# refuses an image that is not (TC-754-17).
f43_systemd_is_pinned() {
	_f43_got=$(docker run --rm "$1" rpm -q --qf '%{VERSION}' systemd 2>/dev/null)
	if [ "$_f43_got" != "$F43_SYSTEMD_VERSION" ]; then
		echo "FAILED: the test image $1 has systemd '${_f43_got:-none}', not $F43_SYSTEMD_VERSION."
		return 1
	fi
	return 0
}

f43_systemd_image() {
	if [ -z "${1:-}" ]; then
		echo "FAILED: f43_systemd_image needs an image tag."
		return 2
	fi
	echo "building test image ($1)"
	docker build -q -t "$1" - >/dev/null <<'DOCKERFILE' || { echo "FAILED: the test image could not be built."; return 1; }
FROM fedora:43
RUN dnf -y install --setopt=install_weak_deps=False fedora-repos-archive \
 && dnf -y install --setopt=install_weak_deps=False \
      systemd-258.7-1.fc43 systemd-libs-258.7-1.fc43 \
      systemd-shared-258.7-1.fc43 systemd-pam-258.7-1.fc43 \
      util-linux findutils \
 && test "$(rpm -q --qf '%{VERSION}' systemd)" = 258.7 \
 && dnf clean all
DOCKERFILE
	f43_systemd_is_pinned "$1"
}
