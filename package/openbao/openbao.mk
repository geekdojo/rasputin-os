################################################################################
#
# openbao — SPIKE ONLY (geekdojo/geekdojo-brain#677)
#
# Vendored stock release binary, same shape as package/caddy: pull the
# upstream linux tarball, verify its sha256, install the binary. Exists only
# to measure squashfs / .raucb growth; no defconfig enables it.
#
################################################################################

OPENBAO_VERSION = 2.7.0
OPENBAO_SITE = https://github.com/openbao/openbao/releases/download/v$(OPENBAO_VERSION)

ifeq ($(BR2_aarch64),y)
OPENBAO_GOARCH = arm64
else ifeq ($(BR2_x86_64),y)
OPENBAO_GOARCH = amd64
endif

OPENBAO_SOURCE = openbao_$(OPENBAO_VERSION)_linux_$(OPENBAO_GOARCH).tar.gz

# The upstream tarball is flat (bao, LICENSE, README.md, CHANGELOG.md).
OPENBAO_STRIP_COMPONENTS = 0

OPENBAO_LICENSE = MPL-2.0
OPENBAO_LICENSE_FILES = LICENSE

define OPENBAO_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/bao $(TARGET_DIR)/usr/bin/bao
endef

$(eval $(generic-package))
