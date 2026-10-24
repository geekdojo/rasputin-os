################################################################################
#
# rasputin-api
#
# Vendored pre-built release binary, same model as rasputin-agent.
# Ships on every image; the systemd unit is role-gated to controlplane.
#
# Bump VERSION together with rasputin-agent's — one control-plane tag
# publishes both tarballs — and refresh both .hash files from the
# release's published *.hash assets.
################################################################################

RASPUTIN_API_VERSION = 2026.10.3-dev.199
RASPUTIN_API_SITE = https://github.com/geekdojo/rasputin-control-plane/releases/download/v$(RASPUTIN_API_VERSION)

ifeq ($(BR2_aarch64),y)
RASPUTIN_API_GOARCH = arm64
else ifeq ($(BR2_x86_64),y)
RASPUTIN_API_GOARCH = amd64
endif

RASPUTIN_API_SOURCE = rasputin-api-$(RASPUTIN_API_VERSION)-linux-$(RASPUTIN_API_GOARCH).tar.gz

# Flat tarball (binary at root); disable Buildroot's default
# tar --strip-components=1 so the binary actually extracts.
RASPUTIN_API_STRIP_COMPONENTS = 0

# The api also bundles the built Next.js UI as static assets: the release
# tarball contains `rasputin-api` + a `ui/` dir (static export), installed
# to /usr/share/rasputin/ui — the api's RASPUTIN_UI_DIR default. Real
# since control-plane v0.3.0; the `if` guard keeps older tarballs working.
# It also carries openbao-policy/, the secrets store's policy text, which has
# no such guard (below).

define RASPUTIN_API_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/rasputin-api \
		$(TARGET_DIR)/usr/bin/rasputin-api
	# UI static assets, if present in the tarball:
	if [ -d $(@D)/ui ]; then \
		mkdir -p $(TARGET_DIR)/usr/share/rasputin/ui; \
		cp -a $(@D)/ui/. $(TARGET_DIR)/usr/share/rasputin/ui/; \
	fi
	# The secrets store's fixed policy text (geekdojo/geekdojo-brain#804;
	# ADR-0010 S9), which the store's self-init reads (init.json). No `if`
	# guard, on purpose: a tarball without openbao-policy/ leaves the glob
	# unmatched, install fails and so does the build, rather than shipping a
	# store whose first start fails and never unseals.
	mkdir -p $(TARGET_DIR)/usr/share/rasputin/openbao-policy
	$(INSTALL) -m 0644 $(@D)/openbao-policy/*.hcl \
		$(TARGET_DIR)/usr/share/rasputin/openbao-policy/
endef

$(eval $(generic-package))
