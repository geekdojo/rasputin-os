################################################################################
#
# rasputin-agent
#
# Vendored pre-built release binary (locked decision #4 — see
# os-images/buildroot-os.md §5). We do NOT compile Go inside the image
# build; we pull a statically-linked binary built + tested by the
# rasputin-control-plane repo's own CI, verify its sha256, and install it.
#
# TODO(scaffold): wire the real version + per-arch source + sha256 once the
# control-plane repo publishes release binaries. The values below are
# placeholders that will NOT download until pointed at a real release.
################################################################################

RASPUTIN_AGENT_VERSION = 0.1.0-dev
RASPUTIN_AGENT_SITE = https://github.com/geekdojo/rasputin-control-plane/releases/download/v$(RASPUTIN_AGENT_VERSION)

# Buildroot maps the target arch; the control-plane CI publishes one
# tarball per Go arch. BR2_aarch64 → arm64, BR2_x86_64 → amd64.
ifeq ($(BR2_aarch64),y)
RASPUTIN_AGENT_GOARCH = arm64
else ifeq ($(BR2_x86_64),y)
RASPUTIN_AGENT_GOARCH = amd64
endif

RASPUTIN_AGENT_SOURCE = rasputin-agent-$(RASPUTIN_AGENT_VERSION)-linux-$(RASPUTIN_AGENT_GOARCH).tar.gz

# TODO(scaffold): add the real hash once a release exists. Until then,
# leave the hash file absent so Buildroot warns rather than silently
# trusting an unverified download.
# RASPUTIN_AGENT_SOURCE checksum lives in rasputin-agent.hash

define RASPUTIN_AGENT_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/rasputin-agent \
		$(TARGET_DIR)/usr/bin/rasputin-agent
endef

$(eval $(generic-package))
