# Trust root

`root-ca.pem` (the Rasputin Root CA certificate) is **injected at build
time**, not committed here — it's per-deployment trust material.

The release pipeline copies the public root CA cert into this directory
before the rootfs is assembled, so every image ships with the trust root
the agent/api use to verify signed OS-update bundles. See:

- `os-images/release-pipeline.md` §3 (signing)
- `control-plane/updates.md` §6 (PKI)

For a local dev build, drop your `root-ca.pem` here (it's `.gitignore`d) or
let the build run in dev-permissive mode without it.
