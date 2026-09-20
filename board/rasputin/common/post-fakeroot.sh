#!/bin/sh
#
# post-fakeroot.sh — runs INSIDE the fakeroot environment, at the end of the
# fakeroot script, immediately before the filesystem image command runs.
# Buildroot calls this via BR2_ROOTFS_POST_FAKEROOT_SCRIPT with the (per-image
# copy of the) target dir as $1.
#
# WHY THIS STAGE AND NOT post-build.sh.
#
# Buildroot does not stop touching /etc/shadow when post-build.sh finishes.
# post-build runs at the end of `target-finalize`; the rootfs image rule then
# runs `support/scripts/mkusers` over the SAME tree to add every package's
# system users, and mkusers does this for each one (support/scripts/mkusers):
#
#     sed -r -i --follow-symlinks -e '/^user:.*/d;' "$TARGET_DIR/etc/shadow"
#
# --follow-symlinks on a link whose target does not exist is a hard error —
#
#     sed: couldn't readlink /var/lib/rasputin/console/shadow
#
# — so a /etc/shadow replaced by a DANGLING symlink in post-build.sh kills the
# build in squashfs generation, on both arches, every time. That is what
# happened between #96 and this change: no build reached squashfs while PR #95's
# mesh-pin gate was failing early and masking it.
#
# Buildroot's fakeroot script is ordered: chown -h -R 0:0, then the mkusers
# output, then makedevs (which applies system/device_table.txt's
# `/etc/shadow f 600 0 0`), then ROOTFS_PRE_CMD_HOOKS, then THIS script, then
# the image command (fs/common.mk). Doing the swap here means every step that
# wants a real /etc/shadow gets one, and the image still ships the symlink.
#
# It also fixes a second, quieter bug the old placement had: the master copy
# taken in post-build.sh predated mkusers, so it was missing the shadow row of
# every package user mkusers adds. Taken here, the master is the finished file.
#
# Note the tree this runs against is the per-image COPY
# ($(BUILD_DIR)/buildroot-fs/squashfs/target), not output/<sku>/target — so a
# rebuild always starts from a real /etc/shadow and this script is never handed
# its own previous output.
#
# ── the console root password: /etc/shadow onto the persistent partition ────
#
# The control plane delivers a root password HASH to every node over its own
# command lane (console.root_hash, rasputin-control-plane#363) and the agent
# applies it with /usr/lib/rasputin/set-root-hash. On this image that write has
# always failed with EROFS: the rootfs is a read-only squashfs, so /etc/shadow
# is part of the image and root's password is whatever the build baked. That is
# why the image used to bake one — a single public password, the same on every
# download, reachable over BMC serial-over-LAN. geekdojo/geekdojo-brain#546.
#
# So /etc/shadow becomes a symlink onto the persistent partition, the way
# /var/lib/docker and /var/lib/tailscale already are, and the file the build
# produced is kept as the read-only master copy that seeds it. tmpfiles.d
# copies the master in on first boot (C line, which only acts when the
# destination does not exist) so an already-delivered hash is never reverted by
# a reboot or an A/B update.
#
# Fail-closed in every window this opens:
#   - before the copy runs, /etc/shadow dangles, and a dangling shadow means
#     NO password authenticates — login refuses rather than admits;
#   - the master copy ships root LOCKED (BR2_TARGET_ENABLE_ROOT_LOGIN=n writes
#     root:*:), so a node that has never been given a hash has no console
#     password rather than a public one;
#   - key-only SSH is untouched: dropbear's public-key path never reads the
#     password field (verified on the firewall image, geekdojo-brain#468).
#
# /etc/gshadow is left alone: nothing delivers a group password, and it carries
# no credential this image ever sets.
#
# The ordering this depends on is pinned at PR time by test/rootfs-shadow-test.sh,
# which runs the pinned Buildroot's own mkusers over a target dir prepared by
# these two scripts, in the build's order.
#
# POSIX sh: no arrays, no [[ ]], no local.

set -eu
TARGET_DIR="$1"
SOC="${2:-unknown}"                 # from BR2_ROOTFS_POST_SCRIPT_ARGS (n100|rpi)

FACTORY_DIR="$TARGET_DIR/usr/share/factory/rasputin"
mkdir -p "$FACTORY_DIR"
# The symlink test comes FIRST. Once this script has run, /etc/shadow is a
# DANGLING link, so `-f` is false for it too — checking -f first would report a
# rootfs with no shadow file at all, which is not what happened and sends the
# next reader to the wrong place.
if [ -L "$TARGET_DIR/etc/shadow" ]; then
	echo "post-fakeroot: ERROR — /etc/shadow is already a symlink; the build's own copy is gone" >&2
	exit 1
fi
if [ ! -f "$TARGET_DIR/etc/shadow" ]; then
	echo "post-fakeroot: ERROR — no /etc/shadow in the rootfs to seed the console password from" >&2
	exit 1
fi
# Refuse to ship a rootfs whose root account has a usable password baked in.
# This is the check that keeps the defconfig honest: someone re-adding
# BR2_TARGET_GENERIC_ROOT_PASSWD gets a failed build, not a quiet regression
# to one password on every image (geekdojo/geekdojo-brain#546, F14).
baked_field="$(awk -F: '$1=="root"{print $2; exit}' "$TARGET_DIR/etc/shadow")"
case "$baked_field" in
	'*'|'!'|'!!' ) : ;;
	'' )
		echo "post-fakeroot: ERROR — root's baked password field is EMPTY (any password, or none, would open a console)" >&2
		exit 1 ;;
	* )
		echo "post-fakeroot: ERROR — root has a usable password baked into the image; the console password is delivered by the control plane, never baked (geekdojo/geekdojo-brain#546)" >&2
		exit 1 ;;
esac
cp "$TARGET_DIR/etc/shadow" "$FACTORY_DIR/shadow"
chmod 600 "$FACTORY_DIR/shadow"
rm -f "$TARGET_DIR/etc/shadow"
ln -s /var/lib/rasputin/console/shadow "$TARGET_DIR/etc/shadow"
echo "post-fakeroot: /etc/shadow -> /var/lib/rasputin/console/shadow for $SOC (root locked; the control plane delivers the hash)"
