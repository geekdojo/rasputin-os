#!/usr/bin/env bash
#
# verify-bundle.sh — verify a signed RAUC bundle the way a node will.
#
# Usage: scripts/verify-bundle.sh <bundle.raucb> <rootfs.img>
#
#   <bundle.raucb>  the signed bundle to check
#   <rootfs.img>    the squashfs rootfs the bundle carries (bundle/rootfs.img
#                   from the build job). The RAUC config is read out of it.
#
# A node checks a bundle against /etc/rauc/system.conf and the keyring that
# config names, both baked into its image. Signing alone does not prove a node
# will accept the result: `rauc bundle` and a bare `rauc info` use RAUC's
# built-in defaults, so a [keyring] setting in the device config (for example
# check-purpose) is not applied, and a bundle CI accepts could still be one
# every node refuses. So this script takes the config from the image itself —
# the system.conf and the trust root the rootfs actually ships — and runs
# `rauc info` with it:
#
#   1. unsquashfs etc/rauc/system.conf and the keyring file(s) it names out of
#      <rootfs.img>;
#   2. rewrite only the keyring path=/directory= keys so they point at the
#      extracted copies (every other key, including check-purpose, is kept
#      byte for byte);
#   3. `rauc --conf=<that> info <bundle>`, which verifies the signature chain
#      and certificate purpose with the device's [keyring] settings;
#   4. check the bundle's compatible matches the device's [system] compatible,
#      which `rauc install` also refuses on mismatch and `rauc info` does not
#      check.
#
# Exit 0 = a node running this rootfs would accept the bundle's signature and
# compatible. Anything else = it would refuse it (or the check could not run);
# the reason is printed as a GitHub Actions ::error:: line.
#
# Needs: rauc, unsquashfs (squashfs-tools), awk.
set -euo pipefail

err() { echo "::error::verify-bundle: $*" >&2; exit 1; }

[ $# -eq 2 ] || err "usage: $0 <bundle.raucb> <rootfs.img>"
BUNDLE=$1
ROOTFS=$2
[ -f "$BUNDLE" ] || err "bundle not found: $BUNDLE"
[ -f "$ROOTFS" ] || err "rootfs not found: $ROOTFS"
command -v rauc >/dev/null || err "rauc not installed"
command -v unsquashfs >/dev/null || err "unsquashfs not installed (squashfs-tools)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/root"

# 1. The device config, from the image.
unsquashfs -q -n -d "$ROOT" "$ROOTFS" etc/rauc/system.conf >/dev/null \
	|| err "could not extract etc/rauc/system.conf from $ROOTFS"
[ -f "$ROOT/etc/rauc/system.conf" ] \
	|| err "$ROOTFS has no etc/rauc/system.conf — a node on this image cannot install anything"

# The keyring keys, read from the [keyring] section only.
keyring_value() {
	awk -v want="$1" '
		/^[ \t]*\[/ { in_kr = ($0 ~ /^[ \t]*\[keyring\][ \t]*$/); next }
		in_kr && $0 ~ "^[ \t]*" want "[ \t]*=" {
			sub(/^[^=]*=[ \t]*/, ""); sub(/[ \t]+$/, ""); print; exit
		}' "$ROOT/etc/rauc/system.conf"
}
KR_PATH=$(keyring_value path)
KR_DIR=$(keyring_value directory)
KR_PURPOSE=$(keyring_value check-purpose)
[ -n "$KR_PATH$KR_DIR" ] || err "the device system.conf has no [keyring] path= or directory= — a node cannot verify any bundle"

for p in "$KR_PATH" "$KR_DIR"; do
	[ -n "$p" ] || continue
	case "$p" in /*) ;; *) err "keyring path '$p' is not absolute; cannot map it into the extracted rootfs" ;; esac
	unsquashfs -q -n -d "$ROOT" -f "$ROOTFS" "${p#/}" >/dev/null \
		|| err "could not extract keyring '$p' from $ROOTFS"
	[ -e "$ROOT$p" ] || err "the device keyring '$p' is not in $ROOTFS — a node on this image cannot verify any bundle"
done

# 2. Same config, keyring keys pointed at the extracted files.
awk -v root="$ROOT" '
	/^[ \t]*\[/ { in_kr = ($0 ~ /^[ \t]*\[keyring\][ \t]*$/) }
	in_kr && /^[ \t]*(path|directory)[ \t]*=/ {
		key = $0; sub(/[ \t]*=.*/, "", key); sub(/^[ \t]*/, "", key)
		val = $0; sub(/^[^=]*=[ \t]*/, "", val); sub(/[ \t]+$/, "", val)
		print key "=" root val; next
	}
	{ print }' "$ROOT/etc/rauc/system.conf" > "$WORK/system.conf"

DEV_COMPAT=$(awk '
	/^[ \t]*\[/ { in_sys = ($0 ~ /^[ \t]*\[system\][ \t]*$/); next }
	in_sys && /^[ \t]*compatible[ \t]*=/ { sub(/^[^=]*=[ \t]*/, ""); sub(/[ \t]+$/, ""); print; exit }' \
	"$WORK/system.conf")
[ -n "$DEV_COMPAT" ] || err "the device system.conf has no [system] compatible="

echo "verify-bundle: $(basename "$BUNDLE") against the device RAUC config from $(basename "$ROOTFS"):/etc/rauc/system.conf"
echo "verify-bundle:   compatible=$DEV_COMPAT keyring=${KR_PATH:-$KR_DIR} check-purpose=${KR_PURPOSE:-<unset: OpenSSL default, smimesign>}"
echo "verify-bundle:   $(rauc --version)"

# 3. Signature + chain + purpose, under the device's [keyring] settings.
if ! out=$(rauc --conf="$WORK/system.conf" info --output-format=shell "$BUNDLE" 2>&1); then
	printf '%s\n' "$out" >&2
	err "$(basename "$BUNDLE") does not verify under the device RAUC config — nodes on this image would refuse it"
fi
printf '%s\n' "$out" | grep -E '^(RAUC_MF_COMPATIBLE|RAUC_MF_VERSION)=' || true
printf '%s\n' "$out" | grep -iE 'verified .*signature|using system config file|using central status file' || true

# 4. Compatible, as `rauc install` checks it.
BUNDLE_COMPAT=$(printf '%s\n' "$out" | sed -n "s/^RAUC_MF_COMPATIBLE='\{0,1\}\([^']*\)'\{0,1\}$/\1/p" | head -1)
[ "$BUNDLE_COMPAT" = "$DEV_COMPAT" ] \
	|| err "bundle compatible '$BUNDLE_COMPAT' != device compatible '$DEV_COMPAT' — rauc install would refuse it"

echo "verify-bundle: OK — a node on this image accepts $(basename "$BUNDLE")"
