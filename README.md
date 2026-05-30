# rasputin-os

Buildroot external tree for the **Rasputin OS** image — the base OS that
boots on every Rasputin **compute** and **controlplane** node. One tree,
two architectures (CM5 arm64, N100 amd64), one rootfs whose role is chosen
at provision time.

> The firewall node runs **OpenWrt**, not this image — see the
> [`rasputin-openwrt-firewall`](https://github.com/geekdojo/rasputin-openwrt-firewall)
> repo.

## Design docs (source of truth)

This repo implements the design in the geekdojo wiki:

- [OS Images — Overview](https://github.com/geekdojo/geekdojo-wiki/blob/main/projects/rasputin/design/os-images/overview.md)
- [Buildroot OS](https://github.com/geekdojo/geekdojo-wiki/blob/main/projects/rasputin/design/os-images/buildroot-os.md) — external tree, RAUC A/B per SoC, dual output
- [Provisioning & Role-at-Runtime](https://github.com/geekdojo/geekdojo-wiki/blob/main/projects/rasputin/design/os-images/provisioning.md)
- [Release Pipeline](https://github.com/geekdojo/geekdojo-wiki/blob/main/projects/rasputin/design/os-images/release-pipeline.md)

## Status

**Signed releases shipping end-to-end (2026-05-30).** Both SKU builds are
green in CI, the n100 `.img` boots to a Rasputin login prompt in the
`smoke-amd64` job (systemd + journal + network + containerd all up), and
the `sign-and-release` job runs `rauc bundle` against the YubiKey-backed
PKI (root → intermediate → leaf) and publishes `.raucb` + `.img.xz` +
`manifest.json` to GitHub Releases. First green release:
[2026.05.0-dev.3](https://github.com/geekdojo/rasputin-os/releases/tag/2026.05.0-dev.3).
Warm-cache iterations are ~50 min per SKU (cold ~2–3 h); ccache + a split
restore/save-on-failure keeps the loop usable.

**v1 scope (2026-05-30): N100-only.** Sourcing/hardware-vendor priorities
favor N100 for first ship; CM5 is deferred post-v1. The cm5 entry is
commented out of `.github/workflows/release.yml`'s build matrix, but
`board/rasputin/cm5/`, `configs/rasputin_cm5_defconfig`, and the package
.mks stay in place so a local `make rasputin_cm5_defconfig` still works
and the CI matrix entry can be uncommented when CM5 sourcing aligns.

The smaller open items are tracked in the
[wiki backlog](https://github.com/geekdojo/geekdojo-wiki/blob/main/projects/rasputin/backlog.md#designos-imagesbuildroot-osmd-6);
the big v1 ones, in order:

- **dm-verity + initramfs.** Today the kernel mounts the squashfs root
  directly (`rootfstype=squashfs ro`); verity hashes need to be wired in
  `post-image.sh` and a small initramfs added to run `veritysetup` before
  `switch_root`.
- **Restore the RAUC GRUB slot logic** (n100). `board/rasputin/n100/grub.cfg`
  is scaffolded as a hardcoded `default=rootfs.0` because Buildroot's
  default EFI grub doesn't embed `test`/`loadenv`/`serial`/`terminal`. Add
  those to `BR2_TARGET_GRUB2_BUILTIN_MODULES_EFI` and restore the
  ORDER/A_TRY/B_TRY loop with a `default=""` guard so the first match
  wins (pairs with dm-verity).
- **Populate slot B at flash time.** `genimage.cfg` leaves rootfs-1 empty
  (RAUC fills it on first OTA); if slot A fails before any OTA the kernel
  panics. Cleaner: write the same squashfs into B at flash.

**Post-v1:** CM5 hardware bring-up — confirm Pi 5 firmware variant + blob
set in `genimage.cfg` (starter list with `BRING-UP:` markers in
`configs/rasputin_cm5_defconfig`), swap DTS to a CM5 carrier
(`bcm2712-rpi-cm5-*`), write `tryboot` RAUC hook scripts under
`board/rasputin/cm5/rauc-hooks/`, re-enable the cm5 matrix entry.

## Cutting a release

`sign-and-release` triggers on any CalVer tag matching
`YYYY.MM.MICRO[-suffix]`. Use a `-dev.N` suffix to land a prerelease
(marked as such on GitHub and tagged `channel=dev` in `manifest.json`);
bare CalVer is stable.

```sh
git tag -a 2026.06.0 -m "first stable cut"
git push origin 2026.06.0
# → build × 2 → smoke-amd64 → sign-and-release → GitHub Release with
#   2 × .raucb + 2 × .img.xz + manifest.json
```

## Layout

```
external.desc / external.mk / Config.in    BR2_EXTERNAL entry points
configs/                                    per-SoC defconfigs (BR2_CCACHE on)
board/rasputin/common/                      rootfs overlay, post-build, post-image
                                            (dual .img/.raucb), seed template,
                                            firstboot units + role-provisioning script
board/rasputin/n100/                        genimage.cfg + grub.cfg + linux.fragment
                                            + RAUC system.conf
board/rasputin/cm5/                         genimage.cfg + config.txt + linux.fragment
                                            + RAUC system.conf  (autoboot.txt is
                                            generated in post-image.sh)
package/rasputin-{agent,api}/               vendored release-binary packages
scripts/init-buildroot.sh                   add the pinned Buildroot LTS submodule
.github/workflows/release.yml               CalVer matrix build → QEMU smoke (amd64)
                                            → sign → GitHub Release
```

## Quick start (dev)

> **Host OS:** Buildroot needs Linux (it can't build on macOS or Windows
> natively). On a Mac or Windows box, either build inside a Linux VM /
> container, or use the CI — `gh workflow run release.yml -f full_build=true`
> is the canonical loop, and warm cache keeps iterations to ~50 min/SKU.

Local build (Linux host):

```sh
git clone https://github.com/geekdojo/rasputin-os
cd rasputin-os
./scripts/init-buildroot.sh        # adds Buildroot 2025.02.x LTS as a submodule

# vendored agent/api binaries live in a private control-plane release; pre-
# fetch them into Buildroot's dl/ so the package step finds them locally:
gh release download v0.1.0 \
  --repo geekdojo/rasputin-control-plane \
  --pattern 'rasputin-agent-0.1.0-linux-amd64.tar.gz' --dir dl/rasputin-agent
gh release download v0.1.0 \
  --repo geekdojo/rasputin-control-plane \
  --pattern 'rasputin-api-0.1.0-linux-amd64.tar.gz'   --dir dl/rasputin-api

# build the amd64 image (also the QEMU dev target)
make -C buildroot BR2_EXTERNAL=$PWD O=$PWD/output/n100 BR2_DL_DIR=$PWD/dl rasputin_n100_defconfig
make -C buildroot BR2_EXTERNAL=$PWD O=$PWD/output/n100 BR2_DL_DIR=$PWD/dl

# artifacts land in output/n100/images/:
#   rasputin-os-n100-<version>.img     (flash this)
#   rasputin-os-n100-<version>.raucb   (OTA bundle; sign before shipping)
```

For arm64, swap `n100` → `cm5` and `linux-amd64` → `linux-arm64` in the
`gh release download` patterns. Buildroot cross-compiles arm64 on an amd64
host — no arm64 machine needed.

Boot the amd64 image under QEMU (matches the CI smoke):

```sh
qemu-system-x86_64 -machine q35 -m 2048 -smp 2 -cpu max -nographic \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=/tmp/vars.fd \
  -drive file=output/n100/images/rasputin-os-n100-*.img,format=raw,if=virtio \
  -serial mon:stdio
```

The build target is Nehalem-baseline (SSE4.2); `-cpu max` is required
under QEMU's default TCG, harmless on real silicon.

## Provisioning a flashed node

Mount the image's FAT seed region and edit `rasputin-seed.env`:

```sh
RASPUTIN_NODE_ROLE=compute            # or controlplane
RASPUTIN_NATS_URL=nats://cp-1.rasputin.tailnet:4222
RASPUTIN_CP_JOIN_TOKEN=...            # from the controlplane
```

The first controlplane needs no token — it self-inits against its own
embedded NATS. See [provisioning.md](https://github.com/geekdojo/geekdojo-wiki/blob/main/projects/rasputin/design/os-images/provisioning.md).

## License

TODO: confirm license (the control-plane repo's choice should match).
