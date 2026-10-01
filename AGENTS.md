# rasputin-os — agent instructions

Buildroot-based OS image for [Rasputin](https://rasputin.geekdojo.com) compute and
control-plane nodes (arm64 Raspberry Pi 4/5/CM5, amd64 Intel N100). Alpha, AGPL-3.0.

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
- A commit or PR that fixes a tracked issue must use a **closing keyword** —
  `Fixes #N` / `Closes #N` — not a bare `(#N)` reference, so the PR and the issue are
  linked. A merged PR does not close the issue (auto-close is off org-wide since
  2026-09-30): close it deliberately once it is done.

## Engineering standard

This repo follows the [Geekdojo development principles](https://github.com/geekdojo/geekdojo-brain/blob/main/engineering/development-principles.md), the architecture and coding standard for every Geekdojo product (Decided 2026-09-28). Read it before you plan or write code. Plans and code are reviewed against it, and review findings cite its rule IDs (for example `ARCH-IOC`).

- **It applies to all new code.** Legacy code is refactored toward it when a change can reasonably do so.
- **A departure needs an approved exception.** The process is in [Standard exceptions](https://github.com/geekdojo/geekdojo-brain/blob/main/engineering/standard-exceptions.md). Approved exceptions for this repo are listed in `EXCEPTIONS.md` at the repo root. The file is created when the first one is approved.
