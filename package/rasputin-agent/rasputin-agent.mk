################################################################################
#
# rasputin-agent
#
# Vendored pre-built release binary (locked decision #4 — see
# os-images/buildroot-os.md §5). We do NOT compile Go inside the image
# build; we pull a statically-linked binary built + tested by the
# rasputin-control-plane repo's own CI, verify its sha256, and install it.
#
# Bump VERSION together with rasputin-api's — one control-plane tag
# publishes both tarballs — and refresh both .hash files from the
# release's published *.hash assets.
################################################################################

RASPUTIN_AGENT_VERSION = 2026.07.2-dev.46
RASPUTIN_AGENT_SITE = https://github.com/geekdojo/rasputin-control-plane/releases/download/v$(RASPUTIN_AGENT_VERSION)

# Buildroot maps the target arch; the control-plane CI publishes one
# tarball per Go arch. BR2_aarch64 → arm64, BR2_x86_64 → amd64.
ifeq ($(BR2_aarch64),y)
RASPUTIN_AGENT_GOARCH = arm64
else ifeq ($(BR2_x86_64),y)
RASPUTIN_AGENT_GOARCH = amd64
endif

RASPUTIN_AGENT_SOURCE = rasputin-agent-$(RASPUTIN_AGENT_VERSION)-linux-$(RASPUTIN_AGENT_GOARCH).tar.gz

# Our release tarballs are FLAT (just the binary at the root, no top-level
# dir). Buildroot's generic-package defaults to tar --strip-components=1,
# which would strip the binary itself and extract nothing. Disable it.
RASPUTIN_AGENT_STRIP_COMPONENTS = 0

# Download verification: rasputin-agent.hash, copied from the release's
# published .hash assets (build-release.sh emits Buildroot's format).

define RASPUTIN_AGENT_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/rasputin-agent \
		$(TARGET_DIR)/usr/bin/rasputin-agent
endef

$(eval $(generic-package))
