# rasputin-os

[![Release](https://github.com/geekdojo/rasputin-os/actions/workflows/release.yml/badge.svg)](https://github.com/geekdojo/rasputin-os/actions/workflows/release.yml)
[![Latest](https://img.shields.io/github/v/release/geekdojo/rasputin-os?include_prereleases&label=release)](https://github.com/geekdojo/rasputin-os/releases)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-E8590C.svg)](LICENSE)

The node OS of **Rasputin** — an open-source homelab cluster system: a small
fleet of nodes (Raspberry Pi or Intel N100) plus a dedicated firewall node,
managed from one web UI, with atomic A/B OS updates that roll back on
failure. Opinionated where you want guidance, open where you want control,
and built to work in the first hour.

> **Want to run Rasputin, not build it?** Flashable images and a four-step
> quickstart live at
> [rasputin.geekdojo.com/download](https://rasputin.geekdojo.com/download/).

This repo is the Buildroot external tree that produces the image booting
every Rasputin **compute** and **controlplane** node. One tree, two
architectures (`rpi` arm64, `n100` amd64), one read-only rootfs whose role is
chosen at provision time by a seed file — a compute node and a controlplane
node run the same image.

> **Status: pre-alpha.** Rasputin is in its commodity-hardware proof phase.
> Image layouts, partition schemes, and update formats change without notice.

Rasputin is a modular, node-based homelab system; the system-level overview
lives in
[ARCHITECTURE.md](https://github.com/geekdojo/rasputin-control-plane/blob/main/ARCHITECTURE.md)
in the `rasputin-control-plane` repo. The firewall node runs **OpenWrt**, not
this image — see
[`rasputin-openwrt-firewall`](https://github.com/geekdojo/rasputin-openwrt-firewall).

## What the image is

- **Buildroot 2025.02.x LTS** (pinned as a pristine submodule; all
  customization lives in this external tree — near-zero Buildroot patches).
- **Read-only squashfs rootfs, A/B slots + a persistent data partition.**
  One build emits both a flashable `.img` and a signed **RAUC** `.raucb` OTA
  bundle. The data partition grows to fill the medium on first boot.
- **RAUC atomic A/B updates** with rollback, driven by the control plane's
  update saga (stage → reboot into the new slot → health check → commit or
  roll back). Bundles are verified against a CA baked into every image.
- **Per-arch bootloader backends, honestly different:**
  - `n100` (amd64, UEFI): GRUB with a real boot counter — bootloader-level
    rollback even for a committed slot. Hardware-validated end-to-end
    (install → auto-boot new slot → commit, and mark-bad → auto-revert).
  - `rpi` (arm64): one unified image boots **Pi 4 / Pi 5 / CM5** (two-kernel
    FAT, firmware picks per board; Raspberry Pi kernel fork — mainline can't
    boot current Pi 5 steppings). A/B uses the Pi firmware's one-shot
    `tryboot` flag via a custom RAUC backend. The firmware **cannot count
    boot attempts and won't auto-fall-back from a committed slot**, so the Pi
    relies on defense-in-depth: the one-shot trial, a systemd watchdog on the
    agent, and the update saga's post-reboot health check. Boot, A/B commit,
    simulated-failure rollback, and OTA are hardware-validated (microSD and
    NVMe).
- **Docker** as the app substrate; the control-plane binaries
  (`rasputin-agent`, `rasputin-api`) are vendored as pre-built static
  release binaries from
  [`rasputin-control-plane`](https://github.com/geekdojo/rasputin-control-plane),
  verified by hash — so an OS build takes minutes, not hours.
- **Key-only SSH** (dropbear, password auth disabled; no authorized key = no
  network SSH at all), serial/HDMI console fallback. **The image bakes no SSH
  key and the build pipeline cannot inject one** — you supply your own at
  flash time via `RASPUTIN_SSH_AUTHORIZED_KEY` in `rasputin-seed.env` (first
  boot writes it to the persistent partition, where dropbear reads it). Our
  own bench clusters are provisioned exactly the same way. Published
  releases up to and including `2026.07.1-dev.91` baked a disclosed geekdojo
  support key — the first no-vendor-key release is anything newer (see
  [the releases](https://github.com/geekdojo/rasputin-os/releases)).
  IPv6 is disabled across the stack by design.

Known gaps (tracked, not hidden): dm-verity rootfs integrity + initramfs is
designed but not wired; the console root password is baked at build time and
not yet operator-changeable at runtime.

## Layout

```
external.desc / external.mk / Config.in    BR2_EXTERNAL entry points
configs/                                    rasputin_rpi_defconfig, rasputin_n100_defconfig
board/rasputin/common/                      rootfs overlay (units, trust root, RAUC
                                            config), post-build, post-image
                                            (dual .img/.raucb), seed template,
                                            firstboot role-provisioning
board/rasputin/n100/                        genimage.cfg (GPT) + grub.cfg + kernel
                                            fragment + RAUC system.conf
board/rasputin/rpi/                         genimage.cfg (MBR) + config.txt +
                                            autoboot.txt + cmdline per slot +
                                            tryboot RAUC backend bits
package/rasputin-{agent,api}/               vendored release-binary packages
scripts/init-buildroot.sh                   add the pinned Buildroot LTS submodule
.github/workflows/release.yml               matrix build → QEMU smoke (amd64) →
                                            sign → GitHub Release
```

## Quick start (dev)

> **Host OS:** Buildroot needs Linux (it can't build natively on macOS or
> Windows). On those, build inside a Linux VM/container or use the CI
> workflow. Warm-cache CI iterations are ~50 min per SKU; cold builds run
> hours.

```sh
git clone https://github.com/geekdojo/rasputin-os
cd rasputin-os
./scripts/init-buildroot.sh        # adds Buildroot 2025.02.x LTS as a submodule

# Pre-fetch the vendored agent/api release tarballs into Buildroot's dl/
# so the package step finds them locally (grab the version pinned in
# package/rasputin-agent/rasputin-agent.mk from the rasputin-control-plane
# releases page):
#   dl/rasputin-agent/rasputin-agent-<ver>-linux-amd64.tar.gz
#   dl/rasputin-api/rasputin-api-<ver>-linux-amd64.tar.gz

# build the amd64 image (also the QEMU dev target)
make -C buildroot BR2_EXTERNAL=$PWD O=$PWD/output/n100 BR2_DL_DIR=$PWD/dl rasputin_n100_defconfig
make -C buildroot BR2_EXTERNAL=$PWD O=$PWD/output/n100 BR2_DL_DIR=$PWD/dl

# artifacts land in output/n100/images/:
#   rasputin-os-n100-<version>.img     (flash this)
#   rasputin-os-n100-<version>.raucb   (OTA bundle; sign before shipping)
```

For arm64, swap `n100` → `rpi` and fetch the `linux-arm64` tarballs.
Buildroot cross-compiles arm64 on an amd64 host — no arm64 machine needed.

Boot the amd64 image under QEMU (matches the CI smoke test):

```sh
qemu-system-x86_64 -machine q35 -m 2048 -smp 2 -cpu max -nographic \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=/tmp/vars.fd \
  -drive file=output/n100/images/rasputin-os-n100-*.img,format=raw,if=virtio \
  -serial mon:stdio
```

The build target is Nehalem-baseline (SSE4.2); `-cpu max` is required under
QEMU's default TCG, harmless on real silicon.

Building your own variant is a supported path, not a hack: the defconfigs are
the documented entry point, and a third-party node image is "add a defconfig
+ a board dir."

## Provisioning a flashed node

Mount the image's FAT seed partition and edit `rasputin-seed.env`:

```sh
RASPUTIN_NODE_ROLE=compute            # required; or controlplane
RASPUTIN_NATS_URL=nats://rasputin.local:4222
RASPUTIN_CP_JOIN_TOKEN=...            # required for compute; minted by the controlplane
RASPUTIN_SSH_AUTHORIZED_KEY="ssh-ed25519 AAAA... you@laptop"  # optional; quote it — your SSH key
```

The first controlplane needs no token — it self-initializes against its own
embedded NATS and becomes the authority that mints tokens for everyone else.

## Releases

CI builds both SKUs, boot-smokes the amd64 image under QEMU, signs the RAUC
bundles, and publishes `.raucb` + `.img.xz` + `manifest.json` to GitHub
Releases. Versioning is CalVer (`YYYY.MM.MICRO`, `-dev.N` suffix for
prereleases), shared with the sibling repos so users see one Rasputin
version.

## Contributing

Issues and discussion are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md)
for the PR flow and the CLA (signing is automatic on your first PR).

## AI-assisted development

This project is developed by a human maintainer working with AI coding assistants;
AI-assisted commits carry `Co-Authored-By` trailers naming the model. Approach,
accountability, and provenance: [AI_DISCLOSURE.md](AI_DISCLOSURE.md).

## License

[AGPL-3.0](LICENSE).
