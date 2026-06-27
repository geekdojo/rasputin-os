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
SOC="${2:-unknown}"                 # from BR2_ROOTFS_POST_SCRIPT_ARGS (n100|rpi)
SCRIPT_DIR="$(dirname "$0")"        # board/rasputin/common
BOARD_DIR="$SCRIPT_DIR/../$SOC"     # board/rasputin/<soc>

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

# RAUC system config (A/B slots + GRUB backend + keyring). Per-SoC, so it's
# copied from the board dir rather than the shared overlay. rauc errors without
# it ("failed to load system config"), so any update would fail; see
# os-images/buildroot-os.md §3.
if [ -f "$BOARD_DIR/rauc-system.conf" ]; then
	mkdir -p "$TARGET_DIR/etc/rauc"
	cp "$BOARD_DIR/rauc-system.conf" "$TARGET_DIR/etc/rauc/system.conf"
	echo "post-build: installed $SOC RAUC system.conf → /etc/rauc/system.conf"
else
	echo "post-build: WARNING — no rauc-system.conf for SoC '$SOC'; RAUC updates will fail"
fi

# Mark the running slot good once the OS has booted, resetting the grubenv
# try-counter so a normal reboot doesn't fall back (RAUC GRUB boot-counter,
# defense-in-depth layer 1; the update saga's app health-check is a separate
# layer that can still mark-bad). Runs on every boot via multi-user.target.wants.
ln -sf /etc/systemd/system/rasputin-mark-good.service \
	"$TARGET_DIR/etc/systemd/system/multi-user.target.wants/rasputin-mark-good.service"

# Reconcile a rolled-back RAUC tryboot trial (Raspberry Pi only). Runs before
# mark-good; clears a stale "trial pending" marker and marks the failed slot bad
# when a one-shot trial reverted. ConditionPathExists=/run/rasputin-seed/autoboot.txt
# makes it a silent no-op on the n100 (GRUB backend, no autoboot.txt), so
# enabling it on every image is safe.
ln -sf /etc/systemd/system/rasputin-rauc-reconcile.service \
	"$TARGET_DIR/etc/systemd/system/multi-user.target.wants/rasputin-rauc-reconcile.service"

# Grow the data partition to fill the disk on first boot (genimage ships a fixed
# small data partition; x-systemd.growfs only grows the fs to the partition).
# One-time, idempotent, ordered AFTER mark-good so its reboot doesn't trip the
# boot-counter. See usr/lib/rasputin/growpart/rasputin-growpart.sh.
ln -sf /etc/systemd/system/rasputin-growpart.service \
	"$TARGET_DIR/etc/systemd/system/multi-user.target.wants/rasputin-growpart.service"

# Console login banner shows the node's IP (/etc/issue carries agetty's `\4`).
# This oneshot re-renders agetty once the network is up so the IP isn't blank
# when getty started before DHCP. See rasputin-issue-ip.service.
ln -sf /etc/systemd/system/rasputin-issue-ip.service \
	"$TARGET_DIR/etc/systemd/system/multi-user.target.wants/rasputin-issue-ip.service"

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

# === SECOND kernel for the UNIFIED rpi image: bcm2711 (Pi 4) → kernel8.img ===
# Buildroot built the primary bcm2712 (Pi 5/CM5) kernel + installed its modules
# to $TARGET_DIR/lib/modules/<2712-ver>. Here — after that build, BEFORE the
# rootfs is squashed — we recompile the SAME fork source for bcm2711 (Pi 4) and
# install its modules ALONGSIDE, so one rootfs serves whichever kernel the Pi
# firmware boots. The primary kernel's Image + all three DTBs are already copied
# to images/, so reconfiguring the kernel build dir in place is safe (nothing
# rebuilds the kernel after post-build). post-image.sh stages BOTH Images onto
# the FAT (kernel_2712.img for Pi 5, kernel8.img for Pi 4) and config.txt's
# [pi4]/[pi5] sections select per board. See os-images/buildroot-os.md §3.
if [ "$SOC" = "rpi" ]; then
	O_DIR="$(cd "$(dirname "$TARGET_DIR")" && pwd)"   # output/rpi
	BIN_DIR="$O_DIR/images"
	HOST_DIR="$O_DIR/host"
	KSRC="$O_DIR/build/linux-custom"
	CROSS="$HOST_DIR/bin/aarch64-buildroot-linux-gnu-"
	FRAG="$SCRIPT_DIR/../rpi"
	if [ ! -d "$KSRC" ]; then
		echo "post-build: ERROR — kernel source $KSRC not found for the Pi 4 second kernel" >&2
		exit 1
	fi
	echo "post-build: building the Pi 4 (bcm2711) second kernel for the unified image…"
	MK="make -C $KSRC ARCH=arm64 CROSS_COMPILE=$CROSS KCFLAGS=-Wno-attribute-alias WERROR=0 REGENERATE_PARSERS=1"
	$MK mrproper
	$MK bcm2711_defconfig
	# Our fragments (squashfs / netfilter / CONFIG_MODULE_COMPRESS_NONE / etc.)
	# must apply to the Pi 4 kernel too — appended last so they win, then
	# olddefconfig resolves. 4K-page fragment is a no-op on bcm2711 (already 4K).
	cat "$FRAG/linux-4k-page-size.fragment" "$FRAG/linux.fragment" >> "$KSRC/.config"
	$MK olddefconfig
	$MK -j"$(nproc)" Image modules
	$MK INSTALL_MOD_PATH="$TARGET_DIR" INSTALL_MOD_STRIP=1 DEPMOD="$HOST_DIR/sbin/depmod" modules_install
	cp "$KSRC/arch/arm64/boot/Image" "$BIN_DIR/kernel8.img"
	echo "post-build: Pi 4 kernel → images/kernel8.img; both kernels' modules now in the rootfs"
fi
