################################################################################
#
# tailscale-bin
#
# EXPERIMENT (spike/own-tailscale): Tailscale's official static release
# tarballs, installed instead of Buildroot's package/tailscale. Modelled on
# package/rasputin-agent: no Go toolchain, a pinned version, a pinned sha256
# per arch (tailscale-bin.hash).
#
# To bump: set VERSION, download both tarballs from
# https://pkgs.tailscale.com/stable/, compute their sha256 and check each one
# against the .sha256 file Tailscale publishes beside it, then update the
# .hash file. test/boot-smoke.sh reads VERSION from this file and fails the
# smoke if the booted daemon reports anything else.
#
################################################################################

TAILSCALE_BIN_VERSION = 1.102.4
TAILSCALE_BIN_SITE = https://pkgs.tailscale.com/stable

ifeq ($(BR2_aarch64),y)
TAILSCALE_BIN_ARCH = arm64
else ifeq ($(BR2_x86_64),y)
TAILSCALE_BIN_ARCH = amd64
endif

# Tarball layout: tailscale_<ver>_<arch>/{tailscale,tailscaled,systemd/...}.
# The default --strip-components=1 drops the top-level directory.
TAILSCALE_BIN_SOURCE = tailscale_$(TAILSCALE_BIN_VERSION)_$(TAILSCALE_BIN_ARCH).tgz
TAILSCALE_BIN_LICENSE = BSD-3-Clause
TAILSCALE_BIN_CPE_ID_VENDOR = tailscale
TAILSCALE_BIN_CPE_ID_PRODUCT = tailscale

# Both binaries go to /usr/bin. Under BR2_ROOTFS_MERGED_BIN (selected by
# systemd on 2026.08) /usr/sbin is a symlink to bin, so the unit's
# ExecStart=/usr/sbin/tailscaled already resolves to the real file. Buildroot's
# package/tailscale instead ran `ln -f -s ../bin/tailscaled usr/sbin/tailscaled`,
# which under merged-bin writes usr/bin/tailscaled -> ../bin/tailscaled, a link
# to itself (ELOOP at exec). Only when /usr/sbin is a real directory is a link
# needed, and then it points from sbin into bin, never into itself.
define TAILSCALE_BIN_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/tailscale $(TARGET_DIR)/usr/bin/tailscale
	$(INSTALL) -D -m 0755 $(@D)/tailscaled $(TARGET_DIR)/usr/bin/tailscaled
	if [ ! -L $(TARGET_DIR)/usr/sbin ]; then \
		mkdir -p $(TARGET_DIR)/usr/sbin && \
		ln -sf ../bin/tailscaled $(TARGET_DIR)/usr/sbin/tailscaled; \
	fi
endef

# The upstream unit and its EnvironmentFile (required, not optional, in the
# shipped unit). Same paths Buildroot's package used, so post-build.sh's
# enable symlink and the overlay drop-ins in tailscaled.service.d are unchanged.
define TAILSCALE_BIN_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 0644 $(@D)/systemd/tailscaled.defaults \
		$(TARGET_DIR)/etc/default/tailscaled
	$(INSTALL) -D -m 0644 $(@D)/systemd/tailscaled.service \
		$(TARGET_DIR)/usr/lib/systemd/system/tailscaled.service
endef

$(eval $(generic-package))
