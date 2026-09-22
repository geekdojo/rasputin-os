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
# Give systemd-timesyncd a WRITABLE timestamp file stamped at the image build
# date, before it starts. Without it a no-RTC board keeps systemd's own
# compiled-in build time (fifteen months stale on 2026.09.4) and an offline
# controlplane mints an already-expired HTTPS leaf. sysinit.target.wants, not
# multi-user: timesyncd runs inside sysinit and this has to precede it.
# geekdojo/rasputin-os#1.
mkdir -p "$TARGET_DIR/etc/systemd/system/sysinit.target.wants"
ln -sf /etc/systemd/system/rasputin-clock-floor.service \
	"$TARGET_DIR/etc/systemd/system/sysinit.target.wants/rasputin-clock-floor.service"
# Apply the seed's RASPUTIN_NTP_SERVER (if any) to systemd-timesyncd, every boot
# (/run drop-in; /etc is read-only). No-op when unset — the baked numeric
# FallbackNTP (usr/lib/systemd/timesyncd.conf.d) still gets a no-RTC node correct
# time on a DNS-less network so it doesn't mint an "expired" TLS leaf.
ln -sf /etc/systemd/system/rasputin-timesync-apply.service \
	"$TARGET_DIR/etc/systemd/system/multi-user.target.wants/rasputin-timesync-apply.service"
# Backfill RASPUTIN_CLUSTER_ID into a pre-E2 node.env, every boot, before the
# api derives its identity from it. No-op on fresh >=E2 installs (firstboot
# already wrote the key) and on dev (no node.env). One-time migration for
# clusters provisioned before per-cluster naming — control-plane #75.
ln -sf /etc/systemd/system/rasputin-clusterid-backfill.service \
	"$TARGET_DIR/etc/systemd/system/multi-user.target.wants/rasputin-clusterid-backfill.service"
# Move the bus join token out of node.env into its own 0600 file, every boot,
# before the agent reads either. No-op on a node provisioned by this image's
# firstboot (already the new form), on a controlplane (its api mints its
# agent's token into a file) and on dev (no node.env). One-time migration for
# nodes provisioned before the token file — geekdojo/geekdojo-brain#537.
ln -sf /etc/systemd/system/rasputin-jointoken-file.service \
	"$TARGET_DIR/etc/systemd/system/multi-user.target.wants/rasputin-jointoken-file.service"
# Bind the persistent coredump store over /var/lib/systemd/coredump so
# systemd-coredump can write cores on the read-only rootfs (diagnostic for the
# rauc double-free, rasputin-os#8). See the unit for why a bind mount and not a
# baked symlink. Best-effort: ConditionPathIsMountPoint skips it if persistent
# didn't mount, and it's a plain Wants — a failure never blocks boot.
ln -sf /etc/systemd/system/rasputin-coredump-store.service \
	"$TARGET_DIR/etc/systemd/system/multi-user.target.wants/rasputin-coredump-store.service"
# Commit this node's machine-id to the persistent partition, so the PID 1 shim
# below can hand the same value back to systemd on the next boot. Once per node
# and a logged no-op after. geekdojo/geekdojo-brain#600.
ln -sf /etc/systemd/system/rasputin-machine-id-commit.service \
	"$TARGET_DIR/etc/systemd/system/multi-user.target.wants/rasputin-machine-id-commit.service"

# ── /sbin/init ───────────────────────────────────────────────────────────────
#
# Point the KERNEL's default init at our shim, which restores the committed
# machine-id and then execs the real systemd. See
# rootfs-overlay/usr/lib/rasputin/machine-id/rasputin-init for why this has to
# happen before systemd rather than in a unit: /etc is a read-only squashfs, so
# PID 1 mints a fresh machine-id into tmpfs and bind-mounts it over
# /etc/machine-id in machine_id_setup(), before any generator or unit exists —
# so nothing that runs as a unit can change the value without leaving PID 1 and
# journald on the old one. There is no initrd on this image and the boot media
# is not OTA-updatable, which rules out every other hook earlier than systemd.
#
# WHY HERE and not a symlink in the rootfs overlay: this way the build can
# REFUSE to ship a rootfs whose /sbin/init is not what we think it is. A silent
# overlay symlink would still look right after systemd moved its binary, and
# would hand PID 1 to a shim that execs a path that no longer exists — which is
# an unbootable node with no fallback (the kernel panics with "Requested init
# … failed"). Fail the build instead.
INIT_LINK="$TARGET_DIR/sbin/init"
INIT_SHIM=/usr/lib/rasputin/machine-id/rasputin-init
INIT_REAL=/usr/lib/systemd/systemd
if [ ! -L "$INIT_LINK" ]; then
	echo "post-build: $INIT_LINK is not a symlink — refusing to replace it" >&2
	exit 1
fi
init_target="$(readlink "$INIT_LINK")"
case "$init_target" in
	../lib/systemd/systemd|/lib/systemd/systemd|../usr/lib/systemd/systemd|/usr/lib/systemd/systemd) ;;
	# An incremental `make` re-runs target-finalize over a tree this script has
	# already swapped, and the systemd package is not reinstalled, so the link
	# is already ours. That is the expected state, not a tampered one.
	"$INIT_SHIM") ;;
	*)
		echo "post-build: /sbin/init points at '$init_target', not systemd — refusing to replace it" >&2
		exit 1
		;;
esac
if [ ! -x "$TARGET_DIR$INIT_SHIM" ]; then
	echo "post-build: missing or non-executable $INIT_SHIM in the rootfs" >&2
	exit 1
fi
if [ ! -x "$TARGET_DIR$INIT_REAL" ]; then
	echo "post-build: $INIT_REAL is not an executable — the shim would exec nothing" >&2
	exit 1
fi
ln -sf "$INIT_SHIM" "$INIT_LINK"
echo "post-build: /sbin/init -> $INIT_SHIM (execs $INIT_REAL)"

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

# fstab is PER-SoC too: the persistent partition is addressed by GPT PARTLABEL on
# the n100 but MBR PARTUUID on the rpi (the rpi is MBR because the Pi firmware's
# autoboot.txt boot_partition is broken on GPT — buildroot-os.md §3). Without the
# right fstab line the persistent partition never mounts → firstboot can't write
# node identity → provisioning fails. Replaces Buildroot's generated fstab.
if [ -f "$BOARD_DIR/fstab" ]; then
	cp "$BOARD_DIR/fstab" "$TARGET_DIR/etc/fstab"
	echo "post-build: installed $SOC fstab → /etc/fstab"
else
	echo "post-build: WARNING — no fstab for SoC '$SOC'; persistent partition won't mount"
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

# Controlplane fallback address. Condition-gated inside the unit (controlplane
# only, and only when networkd came up with no DHCPv4 lease), so enabling it on
# every image is a no-op everywhere else. It exists for the bootstrap
# chicken-and-egg: the firewall serves DHCP, but you configure the firewall
# from the control plane. See rasputin-fallback-address.service.
ln -sf /etc/systemd/system/rasputin-fallback-address.service \
	"$TARGET_DIR/etc/systemd/system/multi-user.target.wants/rasputin-fallback-address.service"
# ...and its other half: the path unit that removes the fallback the moment a
# DHCPv4 lease exists, so a lease that arrives after the boot-time decision
# never leaves the controlplane with two LAN addresses (geekdojo-brain#427).
# Not role-gated. It acts only where the fallback drop-in was written.
ln -sf /etc/systemd/system/rasputin-fallback-address-release.path \
	"$TARGET_DIR/etc/systemd/system/multi-user.target.wants/rasputin-fallback-address-release.path"

# Surface the node's IP at boot: this oneshot writes the real routable IP into
# /etc/issue (-> /run/issue) once the network is up and re-renders agetty, AND
# echoes it to the boot console so a chatty boot can't bury it. Deliberately not
# agetty's `\4` (which flashes loopback/link-local pre-DHCP). See
# rasputin-issue-ip.service / usr/lib/rasputin/issue/rasputin-issue-ip.sh.
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
# password auth and -D pointing authorized_keys at the persistent partition).
# NO key is baked at build time — deliberately (the pre-GA vendor-key removal,
# 2026-07-09; there used to be a RASPUTIN_SSH_AUTHORIZED_KEY build hook here).
# The ONLY way a key gets on a node is RASPUTIN_SSH_AUTHORIZED_KEY in
# rasputin-seed.env, merged by firstboot into
# /var/lib/rasputin/dropbear/authorized_keys — same path for us and for end
# users. No seed key → no network SSH (console still works), never
# passwordless root over the network.
ln -sf /etc/systemd/system/dropbear.service \
	"$TARGET_DIR/etc/systemd/system/multi-user.target.wants/dropbear.service"

# ── the console root password ────────────────────────────────────────────────
#
# NOT HERE. /etc/shadow becomes a symlink onto the persistent partition, and
# the build's own copy becomes the read-only master that seeds it — but that
# swap CANNOT happen at this stage. Buildroot's rootfs image rule still runs
# `mkusers` over this tree afterwards, and mkusers does
# `sed -i --follow-symlinks` on /etc/shadow, which is a hard error on a
# dangling link ("sed: couldn't readlink /var/lib/rasputin/console/shadow").
# Taking the master copy here would also miss every shadow row mkusers is
# about to add.
#
# So it lives in board/rasputin/common/post-fakeroot.sh
# (BR2_ROOTFS_POST_FAKEROOT_SCRIPT), which runs after mkusers and makedevs and
# immediately before the image command. Read that file for the whole story,
# including the guard that refuses a rootfs with a usable baked root password
# (geekdojo/geekdojo-brain#546).

# Bake mesh container images (self-hosted Headscale) into the rootfs so the
# controlplane forms its mesh on FIRST BOOT WITHOUT INTERNET. CI's "Bake mesh
# container images" step docker-saved the refs from the control-plane release's
# mesh-images.json into $RASPUTIN_MESH_IMAGES_DIR; copy the tarballs in, and
# rasputin-mesh-images.service `docker load`s them before rasputin-api so the
# supervisor's `docker image inspect` finds the image and skips the pull. No
# dir set (local dev build) → nothing baked; the supervisor pulls at runtime as
# before (graceful). The loader unit is controlplane- and images-present-gated,
# so enabling it unconditionally here is safe.
#
# loaded-ids.tsv travels with the tarballs. It records the image ID CI read out
# of each saved tarball, which is what `docker load` will produce here.
#
# It is not belt and braces, it is the only handle this node has. `docker save`
# of a digest-pinned reference writes a tarball whose RepoTags is null, and
# `docker load` records no RepoDigest in the classic image store because there
# was no registry pull to record one from — so the loaded image has no NAME at
# all and `docker image inspect headscale/...@sha256:...` fails on a node
# holding exactly the right bytes. The api finds and pins the image by that ID
# instead, which is a stronger pin than any name: a name is a local label
# anyone with the daemon can move, and an ID is the content.
if [ -n "${RASPUTIN_MESH_IMAGES_DIR:-}" ] && ls "$RASPUTIN_MESH_IMAGES_DIR"/*.tar >/dev/null 2>&1; then
	mkdir -p "$TARGET_DIR/usr/share/rasputin/mesh-images"
	cp "$RASPUTIN_MESH_IMAGES_DIR"/*.tar "$TARGET_DIR/usr/share/rasputin/mesh-images/"
	if [ -f "$RASPUTIN_MESH_IMAGES_DIR/loaded-ids.tsv" ]; then
		cp "$RASPUTIN_MESH_IMAGES_DIR/loaded-ids.tsv" \
			"$TARGET_DIR/usr/share/rasputin/mesh-images/loaded-ids.tsv"
	else
		# The tarballs without the record would bake images the api cannot
		# account for, which is the state this file exists to end.
		echo "post-build: ERROR mesh image tarballs were baked with no loaded-ids.tsv beside them" >&2
		exit 1
	fi
	echo "post-build: baked $(ls "$RASPUTIN_MESH_IMAGES_DIR"/*.tar | wc -l | tr -d ' ') mesh image tarball(s) + their image IDs into /usr/share/rasputin/mesh-images — controlplane forms its mesh offline"
else
	echo "post-build: no mesh images baked (RASPUTIN_MESH_IMAGES_DIR unset/empty) — controlplane will pull Headscale at runtime (needs internet)"
fi
ln -sf /etc/systemd/system/rasputin-mesh-images.service \
	"$TARGET_DIR/etc/systemd/system/multi-user.target.wants/rasputin-mesh-images.service"

# ── the PINNED firewall release manifest ─────────────────────────────────────
#
# Bake the firewall image DESCRIPTOR — manifest.json plus its detached CMS
# signature, ~2.7 KB, NOT the 60 MB image — into the rootfs, so a controlplane
# with no route to the internet can still tell a flashing laptop which firewall
# image to write and what its checksum is.
#
# The loop this closes. rasputin-fallback-address.service hands a controlplane
# 192.168.1.2/24 with NO default gateway, deliberately (rasputin-os#53): that
# path exists for exactly the case where the firewall is not up yet and nothing
# serves DHCP. On it the CP has no internet, and GET /api/cluster/firewall-image
# is a pure lookup against api.github.com — so it fails, flash.sh dies fetching
# the descriptor, and the operator cannot flash the firewall that would restore
# the internet the lookup needed. The api reads this baked pair as its fallback
# and populates manifestB64/manifestSigB64; flash.sh already verifies those
# against a root CA pinned inside itself and refuses a checksum that disagrees,
# so nothing on the client needs to change. geekdojo/geekdojo-brain#595.
#
# This is the same chicken-and-egg removal as the baked mesh images above, and
# what design/principles.md:28 already requires: "Every component must stand
# alone — no chicken-and-egg or hardware-coupled dependencies."
#
# WHY A PIN, NOT "latest at build time". "Latest" is the shape that burned
# 2026.09.2 — an unversioned upstream URL moved between a green pre-flight and
# the tag build, and because release tags are immutable the version was lost
# (geekdojo/geekdojo-brain#208). It also makes the image non-reproducible and
# records nowhere which firewall release a given OS image trusts. The pinned
# version is the compatibility statement; see firewall-pin.txt for the bump
# discipline.
#
# WHY THIS IS FAIL-CLOSED. An image that quietly ships without the descriptor
# boots, looks identical, and fails only later, in front of an operator on an
# isolated segment who now cannot flash anything — the invisible failure this
# whole change exists to remove. So every step below is a hard build failure,
# never a warning: no pin, a malformed pin, a failed fetch, a missing trust
# root, a signature that does not verify, or a manifest for some other version.
# That includes a LOCAL dev build with no root-ca.pem: drop the public root CA
# at board/rasputin/common/rootfs-overlay/etc/rasputin/trust/root-ca.pem as
# that directory's README already describes (CI injects it there from
# vars.RASPUTIN_ROOT_CA_PEM before the build).
#
# The network fetch is not a new dependency for the build job — it already
# downloads the vendored agent/api tarballs and the mesh images from the same
# runner.
FW_PIN="$SCRIPT_DIR/firewall-pin.txt"
FW_ROOT_CA="$TARGET_DIR/etc/rasputin/trust/root-ca.pem"
FW_DEST="$TARGET_DIR/usr/share/rasputin/firewall"
FW_RELEASES="https://github.com/geekdojo/rasputin-openwrt-firewall/releases/download"
FW_TMP=""

fw_die() {
	echo "post-build: ERROR — $1" >&2
	echo "post-build:   Refusing to build an image whose offline firewall descriptor is missing: it would boot fine and strand a greenfield bring-up. geekdojo/geekdojo-brain#595." >&2
	if [ -n "$FW_TMP" ]; then rm -rf "$FW_TMP"; fi
	exit 1
}

[ -f "$FW_PIN" ] || fw_die "no firewall pin file at $FW_PIN — nothing says which firewall release this image trusts"

# Exactly one non-comment, non-blank line. awk prints it stripped and exits
# non-zero for any other count, so an empty pin and a pin somebody appended a
# second version to both fail here rather than baking an arbitrary one.
FW_VERSION="$(awk '
	/^[ \t]*#/ { next }
	/^[ \t]*$/ { next }
	{ sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print; n++ }
	END { exit (n == 1 ? 0 : 1) }' "$FW_PIN")" \
	|| fw_die "$FW_PIN must hold exactly one non-comment, non-blank line naming the firewall version"

# Bare CalVer, no leading "v" — the firewall's tags are bare and this string is
# pasted into the asset URL verbatim, so a "v" here is a 404 at fetch time and
# a wrong-looking version everywhere the api reports it.
printf '%s\n' "$FW_VERSION" | grep -Eq '^[0-9]{4}\.[0-9]{2}\.[0-9]+(-dev\.[0-9]+)?$' \
	|| fw_die "'$FW_VERSION' in $FW_PIN is not a bare CalVer firewall version (YYYY.MM.MICRO[-dev.N], no leading 'v')"

if command -v curl >/dev/null 2>&1; then
	fw_fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
	fw_fetch() { wget -q -O "$2" "$1"; }
else
	fw_die "neither curl nor wget is on PATH; cannot fetch the pinned firewall descriptor"
fi

# Whether an unverifiable manifest is FATAL is declared by the caller, not
# inferred from the tree. release.yml's "Inject trust root" step is
# unconditional in the build job, so every published image has one; what does
# not is a local dev build, or a minimal fixture tree — test/rootfs-shadow-test.sh
# hands this script one of those, and dying here failed four of its cases for a
# reason that had nothing to do with /etc/shadow.
#
# So a release build sets RASPUTIN_REQUIRE_FIREWALL_MANIFEST=1 and an
# unverifiable manifest stops it. Everywhere else it is a loud skip: refusing
# to produce a dev image buys nothing, because the image that must carry the
# descriptor is the one that gets published.
FW_SKIP=0
if [ ! -s "$FW_ROOT_CA" ]; then
	if [ "${RASPUTIN_REQUIRE_FIREWALL_MANIFEST:-0}" = "1" ]; then
		fw_die "no trust root at $FW_ROOT_CA — the firewall manifest's signature cannot be checked, and an unverified descriptor is not going in the image"
	fi
	FW_SKIP=1
	echo "post-build: WARNING — no trust root at $FW_ROOT_CA; SKIPPING the firewall manifest bake." >&2
	echo "post-build:   This image gets no offline firewall descriptor, so a control plane flashed" >&2
	echo "post-build:   from it cannot name a firewall image with no internet. Expected for a local" >&2
	echo "post-build:   build; a release build sets RASPUTIN_REQUIRE_FIREWALL_MANIFEST=1 and fails" >&2
	echo "post-build:   instead. geekdojo/geekdojo-brain#595." >&2
fi

if [ "$FW_SKIP" = "0" ]; then
FW_TMP="$(mktemp -d)"
for fw_asset in manifest.json manifest.json.sig; do
	fw_fetch "$FW_RELEASES/$FW_VERSION/$fw_asset" "$FW_TMP/$fw_asset" \
		|| fw_die "could not fetch $FW_RELEASES/$FW_VERSION/$fw_asset — the pinned firewall release may not exist, or may not publish that asset (releases before 2026.09.4-dev.127 have no manifest.json.sig)"
	[ -s "$FW_TMP/$fw_asset" ] \
		|| fw_die "$fw_asset for firewall $FW_VERSION downloaded empty from $FW_RELEASES/$FW_VERSION/$fw_asset"
done

# Verify BEFORE installing, against the very trust root this image ships — the
# file /etc/rauc/system.conf names as its keyring, already copied into the
# target by the rootfs overlay (Buildroot copies overlays immediately before it
# runs this script). Verifying against the image's own root, rather than a copy
# fetched alongside the manifest, is the point: it proves the descriptor chains
# to the same publisher the node already trusts for its own updates.
# manifest.json.sig is a detached DER CMS signature over manifest.json, the
# same form release.yml emits for this repo's manifest.
command -v openssl >/dev/null 2>&1 \
	|| fw_die "openssl is not on PATH; cannot verify the firewall manifest signature"
if ! openssl cms -verify -binary -inform DER \
	-in "$FW_TMP/manifest.json.sig" \
	-content "$FW_TMP/manifest.json" \
	-CAfile "$FW_ROOT_CA" \
	-out /dev/null 2>"$FW_TMP/verify.err"; then
	sed 's/^/post-build:   openssl: /' "$FW_TMP/verify.err" >&2
	fw_die "the firewall manifest for $FW_VERSION does not verify against $FW_ROOT_CA"
fi

# The pin is a compatibility statement, so the signed bytes must be for the
# release the pin names. A correctly-signed manifest for some OTHER version
# would otherwise install silently and quietly defeat the pin.
grep -Eq "\"version\"[[:space:]]*:[[:space:]]*\"$FW_VERSION\"" "$FW_TMP/manifest.json" \
	|| fw_die "the signed manifest fetched for $FW_VERSION does not name that version — it describes a different firewall release"

mkdir -p "$FW_DEST"
chmod 0755 "$FW_DEST"
cp "$FW_TMP/manifest.json" "$FW_DEST/manifest.json"
cp "$FW_TMP/manifest.json.sig" "$FW_DEST/manifest.json.sig"
chmod 0644 "$FW_DEST/manifest.json" "$FW_DEST/manifest.json.sig"
rm -rf "$FW_TMP"
FW_TMP=""
echo "post-build: baked the firewall image descriptor for $FW_VERSION into /usr/share/rasputin/firewall (signature verified against /etc/rasputin/trust/root-ca.pem) — an offline controlplane can still answer GET /api/cluster/firewall-image"
fi

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
	# Stage as kernel8.bin (NOT .img): the release workflow uploads
	# output/<sku>/images/*.img and the manifest step does `ls *.img | head -1` —
	# a kernel8.img here sorts before rasputin-os-rpi-*.img and would be picked as
	# the disk image. post-image.sh renames it to kernel8.img on the boot FAT,
	# where the Pi 4 firmware expects that name.
	cp "$KSRC/arch/arm64/boot/Image" "$BIN_DIR/kernel8.bin"
	echo "post-build: Pi 4 kernel → images/kernel8.bin; both kernels' modules now in the rootfs"
fi
