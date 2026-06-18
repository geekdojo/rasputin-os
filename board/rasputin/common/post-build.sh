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

# tailscaled (mesh / remote access). The upstream Buildroot tailscale package
# installs the unit at /usr/lib/systemd/system/tailscaled.service but does not
# enable it; enable it on every image so it's up before the agent runs
# `tailscale up` on mesh enrollment. (`systemctl restart tailscaled` from the
# agent then talks to a daemon that's already running.) It idles harmlessly
# until enrolled — no state until `tailscale up`. The SSL_CERT_FILE drop-in
# that points tailscaled at the per-installation Mesh CA lives in the overlay
# at etc/systemd/system/tailscaled.service.d/.
ln -sf /usr/lib/systemd/system/tailscaled.service \
	"$TARGET_DIR/etc/systemd/system/multi-user.target.wants/tailscaled.service"

# dropbear: key-only SSH for support/debugging a headless controlplane. Enable
# the overlay unit (etc/systemd/system/dropbear.service, runs with -s = no
# password auth). Bake root's authorized_keys from RASPUTIN_SSH_AUTHORIZED_KEY
# so the image ships key-only — mirrors the firewall's RASPUTIN_SSH_AUTHORIZED_KEY
# baking. No key → no network SSH (console still works), never passwordless
# root over the network.
ln -sf /etc/systemd/system/dropbear.service \
	"$TARGET_DIR/etc/systemd/system/multi-user.target.wants/dropbear.service"
mkdir -p "$TARGET_DIR/root/.ssh"
chmod 700 "$TARGET_DIR/root/.ssh"
if [ -n "${RASPUTIN_SSH_AUTHORIZED_KEY:-}" ]; then
	printf '%s\n' "$RASPUTIN_SSH_AUTHORIZED_KEY" > "$TARGET_DIR/root/.ssh/authorized_keys"
	chmod 600 "$TARGET_DIR/root/.ssh/authorized_keys"
	echo "post-build: baked $(grep -c . "$TARGET_DIR/root/.ssh/authorized_keys") authorized SSH key line(s) — image is key-only"
else
	: > "$TARGET_DIR/root/.ssh/authorized_keys"
	chmod 600 "$TARGET_DIR/root/.ssh/authorized_keys"
	echo "post-build: WARNING — RASPUTIN_SSH_AUTHORIZED_KEY unset; no SSH key baked. Network SSH will be unusable (console only). Set the variable to enable key-only SSH."
fi

# Bake mesh container images (self-hosted Headscale) into the rootfs so the
# controlplane forms its mesh on FIRST BOOT WITHOUT INTERNET. CI's "Bake mesh
# container images" step docker-saved the refs from
# board/rasputin/common/mesh-images.list into $RASPUTIN_MESH_IMAGES_DIR; copy
# the tarballs in, and rasputin-mesh-images.service `docker load`s them before
# rasputin-api so the supervisor's `docker image inspect` finds the image and
# skips the pull. No dir set (local dev build) → nothing baked; the supervisor
# pulls at runtime as before (graceful). The loader unit is controlplane- and
# images-present-gated, so enabling it unconditionally here is safe.
if [ -n "${RASPUTIN_MESH_IMAGES_DIR:-}" ] && ls "$RASPUTIN_MESH_IMAGES_DIR"/*.tar >/dev/null 2>&1; then
	mkdir -p "$TARGET_DIR/usr/share/rasputin/mesh-images"
	cp "$RASPUTIN_MESH_IMAGES_DIR"/*.tar "$TARGET_DIR/usr/share/rasputin/mesh-images/"
	echo "post-build: baked $(ls "$RASPUTIN_MESH_IMAGES_DIR"/*.tar | wc -l | tr -d ' ') mesh image tarball(s) into /usr/share/rasputin/mesh-images — controlplane forms its mesh offline"
else
	echo "post-build: no mesh images baked (RASPUTIN_MESH_IMAGES_DIR unset/empty) — controlplane will pull Headscale at runtime (needs internet)"
fi
ln -sf /etc/systemd/system/rasputin-mesh-images.service \
	"$TARGET_DIR/etc/systemd/system/multi-user.target.wants/rasputin-mesh-images.service"

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

# Route /etc/resolv.conf through systemd-resolved's STUB (127.0.0.53), not the
# uplink file (which lists the upstream DNS directly). nss "resolve" already
# sends getaddrinfo() callers to resolved (so mDNS .local works for them), but
# a PURE-GO resolver — which tailscale binaries are (CGO_ENABLED=0) — reads
# /etc/resolv.conf directly and would query the upstream DNS, getting NXDOMAIN
# for rasputin.local. Pointing at the stub makes every resolver, cgo or not,
# go through resolved (mDNS for .local, forward for everything else). This is
# what lets tailscaled reach the mesh login server at https://rasputin.local
# (see rasputin-api.service RASPUTIN_HEADSCALE_URL). /etc is read-only squashfs,
# so the symlink is baked here.
ln -sf ../run/systemd/resolve/stub-resolv.conf "$TARGET_DIR/etc/resolv.conf"

# Bake the OS image version (CalVer) into a uniform runtime file. The agent
# reads /etc/rasputin/image-version at startup and reports it on registration
# so the control-plane UI can show which image each node is running — critical
# for troubleshooting and support. The OpenWrt firewall image writes the same
# file at its build time. CI exports RASPUTIN_VERSION as the CalVer tag; a
# local build with no export falls back to 0.0.0-dev. /etc/rasputin already
# holds node.env and trust/, so it's the right home for this.
mkdir -p "$TARGET_DIR/etc/rasputin"
printf '%s\n' "${RASPUTIN_VERSION:-0.0.0-dev}" > "$TARGET_DIR/etc/rasputin/image-version"
