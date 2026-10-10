################################################################################
#
# openbao
#
# The node secrets store (ADR-0010; geekdojo/geekdojo-brain#798). Upstream's
# pre-built release binary, per arch, from a flat tarball (bao, LICENSE,
# README.md, CHANGELOG.md at the root), installed to /usr/bin/bao with its
# licence and an MPL-2.0 source notice. CGO-free static Go (GOARM64=v8.0,
# GOAMD64=v1), so it runs on the musl userland on a Pi 4's A72 and an N100.
# No systemd unit and no config here: nothing starts the binary yet.
#
# The version must equal rasputin-control-plane's
# go-const:api/internal/secretstoretest/pin.go#OpenBaoRelease, the release the
# store's tests run against.
#
# HOW THE HASHES IN openbao.hash ARE TAKEN. Never from a download alone: only
# from upstream's checksums.txt after its signature is verified two ways. V is
# the version (2.7.1) and M the minor (2.7). The anchors are from
# geekdojo/geekdojo-brain#678, re-checked against install.mdx at the tag. In
# an empty scratch dir:
#
#   1. export GNUPGHOME="$(mktemp -d)"
#   2. gh release download "v$V" --repo openbao/openbao -p checksums.txt \
#        -p checksums.txt.gpgsig -p checksums.txt.sigstore.json
#   3. curl -fsSO https://openbao.org/assets/openbao-gpg-pub-20240618.asc
#      `gpg --show-keys --with-colons` must give the primary fingerprint
#      66D15FDD87287219C8E15478D200CD702853E6D0.
#   4. gpg --import openbao-gpg-pub-20240618.asc
#      gpg --status-fd 1 --verify checksums.txt.gpgsig checksums.txt
#      must print VALIDSIG E617DCD4065C2AFC0B2CF7A7BA8BC08C0F691F94 ...
#      66D15FDD87287219C8E15478D200CD702853E6D0.
#   5. cosign verify-blob --bundle checksums.txt.sigstore.json \
#        --certificate-oidc-issuer https://token.actions.githubusercontent.com \
#        --certificate-identity "https://github.com/openbao/openbao/.github/workflows/release.yml@refs/heads/release/$M.x" \
#        checksums.txt
#      must print Verified OK.
#   6. Only then copy the two openbao_${V}_linux_(amd64|arm64).tar.gz lines
#      into openbao.hash, and update LICENSE's line from the extracted file.
#
# geekdojo-brain's projects/rasputin/research/openbao-evidence/678/
# verify-signatures.sh runs every step above plus negative controls
# (V=<version> OUT=<path>). Its run for this pin is committed as
# openbao-evidence/798/raw/signature-verification-v2.7.1.txt.
#
# To bump: run the procedure, set VERSION, update openbao.hash and the version
# in SOURCE (test/openbao-package-test.sh fails if they disagree), and bump
# the control-plane const in the same batch.
#
################################################################################

OPENBAO_VERSION = 2.7.1
OPENBAO_SITE = https://github.com/openbao/openbao/releases/download/v$(OPENBAO_VERSION)

# Only when the package is on: a defconfig without the store must build on any
# architecture, and one with it must never fall through to an empty arch.
ifeq ($(BR2_PACKAGE_OPENBAO),y)
ifeq ($(BR2_aarch64),y)
OPENBAO_GOARCH = arm64
else ifeq ($(BR2_x86_64),y)
OPENBAO_GOARCH = amd64
else
$(error OpenBao has no release tarball mapped for the target architecture $(BR2_ARCH). Add the architecture to the map in package/openbao/openbao.mk and its sha256 to openbao.hash.)
endif
endif

OPENBAO_SOURCE = openbao_$(OPENBAO_VERSION)_linux_$(OPENBAO_GOARCH).tar.gz

# Flat tarball; disable Buildroot's default --strip-components=1.
OPENBAO_STRIP_COMPONENTS = 0

OPENBAO_LICENSE = MPL-2.0
OPENBAO_LICENSE_FILES = LICENSE
# NVD: cpe:2.3:a:openbao:openbao. Product and version are Buildroot's defaults.
OPENBAO_CPE_ID_VENDOR = openbao

# Static ids (S7): the store's paths and the api's client identity (#754) need
# a fixed number. 990 is free on both SKUs (dynamic ids are 100-111 on
# 2026.10.0), and mkusers assigns static ids before dynamic ones, so no
# existing id moves across an OTA. No home, no shell, no login.
OPENBAO_USERS = openbao 990 openbao 990 * - - - OpenBao secrets store

define OPENBAO_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/bao $(TARGET_DIR)/usr/bin/bao
	$(INSTALL) -D -m 0644 $(@D)/LICENSE $(TARGET_DIR)/usr/share/licenses/openbao/LICENSE
	$(INSTALL) -D -m 0644 $(OPENBAO_PKGDIR)/SOURCE $(TARGET_DIR)/usr/share/licenses/openbao/SOURCE
endef

$(eval $(generic-package))
