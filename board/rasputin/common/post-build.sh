#!/bin/sh
#
# post-build.sh — runs after the rootfs is assembled, before image packing.
# Buildroot calls this via BR2_ROOTFS_POST_BUILD_SCRIPT with TARGET_DIR as $1.
#
# Responsibilities:
#   - enable the always-on units (agent + firstboot + hostname) for every role
#   - rasputin-api.service gets no symlink here: Buildroot's `systemctl
#     preset-all` default-enables it at build time (no preset rule matches),
#     and ConditionPathExists=/var/lib/rasputin/role.controlplane gates it to
#     the controlplane at runtime (provisioning.md §2)
#
# systemd-resolved.service (mDNS responder for rasputin.local) needs nothing
# here either: upstream 90-systemd.preset says `enable systemd-resolved.service`
# and Buildroot runs preset-all as a rootfs pre-cmd hook.
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
# Per-role transient hostname, every boot (firstboot is run-once; a transient
# hostname isn't). Only the controlplane may answer rasputin.local via mDNS.
ln -sf /etc/systemd/system/rasputin-hostname.service \
	"$TARGET_DIR/etc/systemd/system/multi-user.target.wants/rasputin-hostname.service"

# rasputin-api.service is intentionally NOT symlinked here — preset-all
# enables it; the role.controlplane marker condition gates the actual start
# (provisioning.md §2).

# Login prompt on the local display. systemd only autospawns gettys on VTs
# via getty@tty1 enablement (logind's autovt@ handles tty2+); without this,
# HDMI shows console output but no way to log in — serial was the only getty
# on the first Mu bring-up (2026-06-11).
mkdir -p "$TARGET_DIR/etc/systemd/system/getty.target.wants"
ln -sf /usr/lib/systemd/system/getty@.service \
	"$TARGET_DIR/etc/systemd/system/getty.target.wants/getty@tty1.service"

# Ensure the persistent data dir exists as a mountpoint.
mkdir -p "$TARGET_DIR/var/lib/rasputin"
