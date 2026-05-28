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

**Scaffold (2026-05-28).** Structure, documented stubs, and CI are in
place; this does **not** yet produce a verified-booting image. Every spot
needing real values before a first build is marked `TODO(scaffold)`. The
known gaps:

- Buildroot kernel/BSP options in both defconfigs are starters — refine via
  `menuconfig` + `savedefconfig`.
- The CM5 RPi-firmware `tryboot` RAUC backend hook scripts aren't written
  (`board/rasputin/cm5/rauc-hooks/`).
- The package `.mk` files point at control-plane release binaries that
  don't exist yet (no `.hash` ⇒ they won't download until pointed at a real
  release).
- The CI signing + release-publish steps are stubbed.

## Layout

```
external.desc / external.mk / Config.in    BR2_EXTERNAL entry points
configs/                                    per-SoC defconfigs (starters)
board/rasputin/common/                      rootfs overlay, post-build, post-image (dual .img/.raucb)
board/rasputin/{cm5,n100}/                  genimage.cfg + RAUC system.conf + bootloader cfg
package/rasputin-{agent,api}/               vendored release-binary packages
scripts/init-buildroot.sh                   add the pinned Buildroot LTS submodule
.github/workflows/release.yml               CalVer matrix build → sign → GitHub Release
```

## Quick start (dev)

```sh
git clone https://github.com/geekdojo/rasputin-os
cd rasputin-os
./scripts/init-buildroot.sh        # adds Buildroot 2025.02.x LTS as a submodule

# build the amd64 image (also the QEMU dev target)
make -C buildroot BR2_EXTERNAL=$PWD O=$PWD/output/n100 rasputin_n100_defconfig
make -C buildroot BR2_EXTERNAL=$PWD O=$PWD/output/n100

# artifacts land in output/n100/images/:
#   rasputin-os-n100-<version>.img     (flash this)
#   rasputin-os-n100-<version>.raucb   (OTA bundle; sign before shipping)
```

For arm64, swap `n100` → `cm5`. Buildroot cross-compiles arm64 on an amd64
host — no arm64 machine needed.

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
