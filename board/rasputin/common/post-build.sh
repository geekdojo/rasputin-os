#!/bin/sh
#
# post-build.sh — runs after the rootfs is assembled, before image packing.
# Buildroot calls this via BR2_ROOTFS_POST_BUILD_SCRIPT with TARGET_DIR as $1.
#
# Responsibilities:
#   - enable the always-on units (agent + firstboot) for every role
#   - leave rasputin-api.service installed-but-not-enabled (firstboot enables
#     it only on the controlplane role)
#
set -eu
TARGET_DIR="$1"

# Enable agent + firstboot on every image. systemd's "enabled" state is just
# a symlink in <target>.wants/; create that dir first — `ln` won't make
# parents, and a freshly-assembled target has no multi-user.target.wants yet.
mkdir -p "$TARGET_DIR/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/rasputin-firstboot.service \
	"$TARGET_DIR/etc/systemd/system/multi-user.target.wants/rasputin-firstboot.service"
ln -sf /etc/systemd/system/rasputin-agent.service \
	"$TARGET_DIR/etc/systemd/system/multi-user.target.wants/rasputin-agent.service"

# rasputin-api.service is intentionally NOT symlinked here — rasputin-firstboot
# enables it at runtime only when role==controlplane (provisioning.md §2).

# Ensure the persistent data dir exists as a mountpoint.
mkdir -p "$TARGET_DIR/var/lib/rasputin"
