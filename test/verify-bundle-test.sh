#!/usr/bin/env bash
#
# Tests for scripts/verify-bundle.sh, the post-sign check release.yml runs on
# every .raucb before it is published.
#
# Builds a throwaway PKI whose extensions copy the production chain's profile
# (root and intermediate with no EKU; the signing leaf with KU digitalSignature
# and EKU codeSigning + emailProtection + the release OID), signs tiny verity
# bundles with it, and packs each SKU's real board/rasputin/<sku>/rauc-system.conf
# into a squashfs rootfs the same way post-build.sh installs it. No real key is
# involved. Bundles are signed WITHOUT --signing-keyring, so a leaf that the
# signing-time check would stop still produces a bundle, and the case under
# test is the verify step on its own.
#
# Needs: rauc, openssl, mksquashfs/unsquashfs (squashfs-tools).
# Run:   bash test/verify-bundle-test.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERIFY="$ROOT/scripts/verify-bundle.sh"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

fails=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

# --- throwaway PKI ---------------------------------------------------------
key() { openssl ecparam -name secp384r1 -genkey -noout -out "$W/$1.key" 2>/dev/null; }
ext() { printf '%s\n' "$2" > "$W/$1.ext"; }

mkroot() { # mkroot <name>
	key "$1"
	ext "$1" 'basicConstraints=critical,CA:TRUE
keyUsage=critical,digitalSignature,keyCertSign,cRLSign
subjectKeyIdentifier=hash'
	openssl req -new -x509 -key "$W/$1.key" -subj "/CN=Test $1" -days 2 \
		-extensions v3 -config <(printf '[req]\ndistinguished_name=dn\n[dn]\n[v3]\n'; cat "$W/$1.ext") \
		-out "$W/$1.pem" 2>/dev/null
}
mkcert() { # mkcert <name> <issuer> <extensions>
	key "$1"
	ext "$1" "$3
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid"
	openssl req -new -key "$W/$1.key" -subj "/CN=Test $1" -out "$W/$1.csr" 2>/dev/null
	openssl x509 -req -in "$W/$1.csr" -CA "$W/$2.pem" -CAkey "$W/$2.key" -CAcreateserial \
		-days 2 -extfile "$W/$1.ext" -out "$W/$1.pem" 2>/dev/null
}

mkroot root
mkcert inter root 'basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign'
LEAF_KU='basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature'
# The production signing leaf's profile (leaf-003).
mkcert leaf-good inter "$LEAF_KU
extendedKeyUsage=critical,codeSigning,emailProtection,1.3.6.1.4.1.66587.1.1.1"
# Wrong purpose: a TLS server leaf.
mkcert leaf-tls inter "$LEAF_KU
extendedKeyUsage=critical,serverAuth"
# codeSigning + the release OID but no emailProtection (the leaf-002 profile):
# passes RAUC's codesign purpose, fails OpenSSL's default smimesign.
mkcert leaf-nosmime inter "$LEAF_KU
extendedKeyUsage=critical,codeSigning,1.3.6.1.4.1.66587.1.1.1"
# A correct-profile leaf under a root the device does not trust.
mkroot other-root
mkcert other-inter other-root 'basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign'
mkcert leaf-other other-inter "$LEAF_KU
extendedKeyUsage=critical,codeSigning,emailProtection,1.3.6.1.4.1.66587.1.1.1"

# --- rootfs images carrying the device config -------------------------------
# mkrootfs <out.img> <system.conf> [extra [keyring] line]
mkrootfs() {
	local d="$W/rootfs-$(basename "$1" .img)"
	mkdir -p "$d/etc/rauc" "$d/etc/rasputin/trust"
	if [ -n "$2" ]; then
		if [ -n "${3:-}" ]; then
			awk -v extra="$3" '{ print } /^\[keyring\]/ { print extra }' "$2" > "$d/etc/rauc/system.conf"
		else
			cp "$2" "$d/etc/rauc/system.conf"
		fi
	fi
	cp "$W/root.pem" "$d/etc/rasputin/trust/root-ca.pem"
	# RAUC refuses a verity bundle whose squashfs is a single 4 KiB block;
	# incompressible padding keeps the test bundles above that.
	head -c 65536 /dev/urandom > "$d/padding"
	mksquashfs "$d" "$1" -comp xz -all-root -noappend -quiet >/dev/null
}

N100_CONF="$ROOT/board/rasputin/n100/rauc-system.conf"
RPI_CONF="$ROOT/board/rasputin/rpi/rauc-system.conf"
mkrootfs "$W/n100.img" "$N100_CONF"
mkrootfs "$W/rpi.img" "$RPI_CONF"
mkrootfs "$W/noconf.img" ""

# A node that has NOT yet taken the image carrying [keyring]
# check-purpose=codesign: same config, that one line removed. The fleet is
# mixed for as long as one such node is running, and what it enforces --
# OpenSSL's smimesign default -- is what constrains which leaves the pipeline
# may mint. Keeping the case here is what stops that constraint from being
# forgotten once every file in the tree says codesign.
mkrootfs_legacy() { # mkrootfs_legacy <out.img> <system.conf>
	local stripped="$W/legacy-$(basename "$1" .img).conf"
	grep -v '^check-purpose=' "$2" > "$stripped"
	if ! grep -q '^check-purpose=' "$2"; then
		echo "mkrootfs_legacy: $2 has no check-purpose line to strip — this case no longer tests anything" >&2
		exit 1
	fi
	mkrootfs "$1" "$stripped"
}
mkrootfs_legacy "$W/n100-legacy.img" "$N100_CONF"

# --- bundles -----------------------------------------------------------------
# mkbundle <out.raucb> <compatible> <rootfs.img> <leaf> <intermediate>
mkbundle() {
	local d="$W/bundle-$(basename "$1" .raucb)"
	mkdir -p "$d"
	cp "$3" "$d/rootfs.img"
	printf '[update]\ncompatible=%s\nversion=0.0.0-test\n\n[bundle]\nformat=verity\n\n[image.rootfs]\nfilename=rootfs.img\n' "$2" > "$d/manifest.raucm"
	rauc bundle --cert="$W/$4.pem" --intermediate="$W/$5.pem" --key="$W/$4.key" \
		"$d" "$1" >"$W/bundle.log" 2>&1 || { echo "could not build test bundle $1"; cat "$W/bundle.log"; exit 1; }
}

# expect <ok|refuse> <description> <bundle> <rootfs> [text the output must contain]
expect() {
	local out rc=0
	out=$(bash "$VERIFY" "$3" "$4" 2>&1) || rc=$?
	if [ "$1" = ok ] && [ "$rc" -ne 0 ]; then fail "$2 (exit $rc)"; printf '%s\n' "$out" | sed 's/^/       /'; return; fi
	if [ "$1" = refuse ] && [ "$rc" -eq 0 ]; then fail "$2 (accepted)"; printf '%s\n' "$out" | sed 's/^/       /'; return; fi
	if [ -n "${5:-}" ] && ! printf '%s\n' "$out" | grep -qiF -- "$5"; then
		fail "$2 (output lacks: $5)"; printf '%s\n' "$out" | sed 's/^/       /'; return
	fi
	pass "$2"
}

echo "rauc: $(rauc --version)"
echo "verify-bundle.sh:"

mkbundle "$W/n100-good.raucb" rasputin-n100 "$W/n100.img" leaf-good inter
expect ok "n100: production-profile leaf is accepted under the n100 device config" \
	"$W/n100-good.raucb" "$W/n100.img" "device RAUC config"

mkbundle "$W/rpi-good.raucb" rasputin-rpi-arm64 "$W/rpi.img" leaf-good inter
expect ok "rpi: production-profile leaf is accepted under the rpi device config" \
	"$W/rpi-good.raucb" "$W/rpi.img" "device RAUC config"

mkbundle "$W/n100-tls.raucb" rasputin-n100 "$W/n100.img" leaf-tls inter
expect refuse "wrong purpose (serverAuth leaf) is refused" \
	"$W/n100-tls.raucb" "$W/n100.img" "unsuitable certificate purpose"

# ONE bundle, signed by a leaf-002-shaped leaf (codeSigning + the release OID,
# no emailProtection), checked against two device configs. The pair is the
# whole mixed-fleet story, and each half fails for a reason worth keeping:
#
#   - under the image in this tree (check-purpose=codesign) it is accepted;
#   - under an already-deployed image (no check-purpose, so smimesign) it is
#     refused, which is why a new leaf must keep emailProtection until no such
#     node remains.
#
# It also shows the verify step applies the config it reads out of the image
# rather than RAUC's built-in default: same bundle, same runner, two verdicts.
mkbundle "$W/n100-nosmime.raucb" rasputin-n100 "$W/n100.img" leaf-nosmime inter
expect ok "codeSigning leaf without emailProtection is accepted under this image's config (check-purpose=codesign)" \
	"$W/n100-nosmime.raucb" "$W/n100.img" "check-purpose=codesign"
expect refuse "the same leaf is refused by a node still on an image with no check-purpose (smimesign)" \
	"$W/n100-nosmime.raucb" "$W/n100-legacy.img" "unsuitable certificate purpose"

# The production leaf profile must satisfy BOTH configs for as long as the
# fleet is mixed. This is the case that would catch a leaf minted for the new
# config alone.
expect ok "the production leaf profile is accepted by a node still on an image with no check-purpose" \
	"$W/n100-good.raucb" "$W/n100-legacy.img" "device RAUC config"

mkbundle "$W/n100-other.raucb" rasputin-n100 "$W/n100.img" leaf-other other-inter
expect refuse "a chain to a root the image does not trust is refused" \
	"$W/n100-other.raucb" "$W/n100.img" "signature verification failed"

expect refuse "an n100 bundle is refused against the rpi image's config (compatible)" \
	"$W/n100-good.raucb" "$W/rpi.img" "bundle compatible 'rasputin-n100' != device compatible 'rasputin-rpi-arm64'"

expect refuse "a rootfs with no etc/rauc/system.conf is refused" \
	"$W/n100-good.raucb" "$W/noconf.img" "no etc/rauc/system.conf"

if [ "$fails" -ne 0 ]; then echo "$fails verify-bundle test(s) failed"; exit 1; fi
echo "all verify-bundle tests passed"
