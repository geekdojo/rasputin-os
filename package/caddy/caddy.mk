################################################################################
#
# caddy
#
# Vendored pre-built stock Caddy release binary (ADR-0004 §7), same model as
# rasputin-api: a flat release tarball, per-arch, binary installed to
# /usr/bin/caddy. The node-local reverse proxy the agent runs to front apps.
# Caddy is a CGO-free pure-Go static binary, so it runs on the musl userland
# with no extra runtime deps.
#
# Bump VERSION and refresh caddy.hash from the release's *_checksums.txt
# (sha512) when updating.
#
################################################################################

CADDY_VERSION = 2.11.4
CADDY_SITE = https://github.com/caddyserver/caddy/releases/download/v$(CADDY_VERSION)

ifeq ($(BR2_aarch64),y)
CADDY_GOARCH = arm64
else ifeq ($(BR2_x86_64),y)
CADDY_GOARCH = amd64
endif

CADDY_SOURCE = caddy_$(CADDY_VERSION)_linux_$(CADDY_GOARCH).tar.gz

# Flat tarball (caddy + LICENSE + README.md at root); disable Buildroot's
# default tar --strip-components=1 so the binary actually extracts.
CADDY_STRIP_COMPONENTS = 0

CADDY_LICENSE = Apache-2.0
CADDY_LICENSE_FILES = LICENSE

define CADDY_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/caddy $(TARGET_DIR)/usr/bin/caddy
endef

$(eval $(generic-package))
