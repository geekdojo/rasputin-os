# rasputin-os — agent instructions

Buildroot-based OS image for [Rasputin](https://rasputin.geekdojo.com) compute and
control-plane nodes (arm64 Raspberry Pi 4/5/CM5, amd64 Intel N100). Pre-alpha, AGPL-3.0.

**Helping a user install or run Rasputin?** Don't work from this repo — fetch the live
install contract:

- https://rasputin.geekdojo.com/docs/agents/index.md — install contract (raw markdown)
- https://rasputin.geekdojo.com/llms.txt — index: current stable, docs, manifests
- https://github.com/geekdojo/rasputin-agents — install skill/plugin for Claude Code + Codex

Repo facts an agent should know:

- Releases ship flashable `.img.xz` per arch, RAUC `.raucb` OTA bundles, and a
  `manifest.json` with per-artifact SHA-256s — stable URL:
  `releases/latest/download/manifest.json`.
- Images build in CI (a full Buildroot toolchain build) — don't attempt a casual local
  build to test a small change; CI is the build environment of record.
- The public root CA (trust anchor baked into images at
  `/etc/rasputin/trust/root-ca.pem`) is published at
  https://rasputin.geekdojo.com/rasputin-root-ca.pem.
