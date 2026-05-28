################################################################################
#
# rasputin-api
#
# Vendored pre-built release binary, same model as rasputin-agent.
# Ships on every image; the systemd unit is role-gated to controlplane.
#
# TODO(scaffold): real version + per-arch source + sha256 once the
# control-plane repo publishes release binaries.
################################################################################

RASPUTIN_API_VERSION = 0.1.0
RASPUTIN_API_SITE = https://github.com/geekdojo/rasputin-control-plane/releases/download/v$(RASPUTIN_API_VERSION)

ifeq ($(BR2_aarch64),y)
RASPUTIN_API_GOARCH = arm64
else ifeq ($(BR2_x86_64),y)
RASPUTIN_API_GOARCH = amd64
endif

RASPUTIN_API_SOURCE = rasputin-api-$(RASPUTIN_API_VERSION)-linux-$(RASPUTIN_API_GOARCH).tar.gz

# The api also bundles the built Next.js UI as static assets. The release
# tarball is expected to contain `rasputin-api` + a `ui/` dir of static
# export output. TODO(scaffold): confirm the tarball layout when the
# control-plane release pipeline lands.

define RASPUTIN_API_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/rasputin-api \
		$(TARGET_DIR)/usr/bin/rasputin-api
	# UI static assets, if present in the tarball:
	if [ -d $(@D)/ui ]; then \
		mkdir -p $(TARGET_DIR)/usr/share/rasputin/ui; \
		cp -a $(@D)/ui/. $(TARGET_DIR)/usr/share/rasputin/ui/; \
	fi
endef

$(eval $(generic-package))
