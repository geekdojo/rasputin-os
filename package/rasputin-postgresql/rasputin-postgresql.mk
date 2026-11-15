################################################################################
#
# rasputin-postgresql
#
# The identity database's PostgreSQL (geekdojo/geekdojo-brain#972). Our own
# copy of Buildroot's package/postgresql/ at tag 2026.08.1 (commit
# 7fdeadb3b9f12f78e5fccca914d7fef47090ab9a), carried so the major version moves
# only when we move it, never with a Buildroot bump. Buildroot's own
# BR2_PACKAGE_POSTGRESQL stays off.
#
# The copy differs from Buildroot's files only in:
#   * the make identifiers and Kconfig symbols, renamed POSTGRESQL_ ->
#     RASPUTIN_POSTGRESQL_ (the @POSTGRESQL_*@ placeholders in pg_config are
#     Buildroot's and stay as they are);
#   * the three package/postgresql/ install paths, now $(RASPUTIN_POSTGRESQL_PKGDIR);
#   * RASPUTIN_POSTGRESQL_CPE_ID_PRODUCT, so pkg-stats matches the NVD
#     cpe:2.3:a:postgresql:postgresql rather than the package's own name;
#   * this header, the version, the hash line and the major guard below.
# So it stays diffable against Buildroot's package/postgresql/ at every bump.
#
# A BUMP CHANGES RASPUTIN_POSTGRESQL_VERSION AND THE HASH LINE, NOTHING ELSE.
# V is the new 18.x version. Take the hash from upstream's
#   https://ftp.postgresql.org/pub/source/v$V/postgresql-$V.tar.bz2.sha256
# (the source Buildroot uses), then download the tarball and confirm it hashes
# to that value. Never change RASPUTIN_POSTGRESQL_MAJOR: a new major cannot
# open the data an older one wrote, so moving it is the planned major-upgrade
# item (geekdojo-brain lifecycle.md section 1.5), not a bump.
#
################################################################################

RASPUTIN_POSTGRESQL_VERSION = 18.7
RASPUTIN_POSTGRESQL_MAJOR = 18
# Unconditional, so any make that includes the external tree refuses a wrong
# major. No closing full stop: GNU make appends ".  Stop." to every $(error).
ifneq ($(firstword $(subst ., ,$(RASPUTIN_POSTGRESQL_VERSION))),$(RASPUTIN_POSTGRESQL_MAJOR))
$(error The carried PostgreSQL is $(RASPUTIN_POSTGRESQL_VERSION), major $(firstword $(subst ., ,$(RASPUTIN_POSTGRESQL_VERSION))), but this release carries major $(RASPUTIN_POSTGRESQL_MAJOR). A new major cannot open the data an older one wrote, so a major change is the planned upgrade item in geekdojo-brain lifecycle.md §1.5, never a bump)
endif
RASPUTIN_POSTGRESQL_SOURCE = postgresql-$(RASPUTIN_POSTGRESQL_VERSION).tar.bz2
RASPUTIN_POSTGRESQL_SITE = https://ftp.postgresql.org/pub/source/v$(RASPUTIN_POSTGRESQL_VERSION)
RASPUTIN_POSTGRESQL_LICENSE = PostgreSQL
RASPUTIN_POSTGRESQL_LICENSE_FILES = COPYRIGHT
RASPUTIN_POSTGRESQL_CPE_ID_VENDOR = postgresql
RASPUTIN_POSTGRESQL_CPE_ID_PRODUCT = postgresql
RASPUTIN_POSTGRESQL_SELINUX_MODULES = postgresql
RASPUTIN_POSTGRESQL_INSTALL_STAGING = YES
RASPUTIN_POSTGRESQL_CONFIG_SCRIPTS = pg_config
RASPUTIN_POSTGRESQL_LDFLAGS = $(TARGET_LDFLAGS) $(TARGET_NLS_LIBS)
# We have to force invalid paths for xmllint and xsltproc, otherwise
# if detected they get used, even with -Ddocs=disabled and
# -Ddocs_pdf=disabled, and it causes build failures
RASPUTIN_POSTGRESQL_CONF_OPTS = \
	-Drpath=false \
	-Ddocs=disabled \
	-Ddocs_pdf=disabled \
	-DXMLLINT=/nowhere \
	-DXSLTPROC=/nowhere
RASPUTIN_POSTGRESQL_DEPENDENCIES = \
	$(TARGET_NLS_DEPENDENCIES) \
	host-bison \
	host-flex

ifeq ($(BR2_PACKAGE_RASPUTIN_POSTGRESQL_FULL),y)
RASPUTIN_POSTGRESQL_NINJA_OPTS += world
RASPUTIN_POSTGRESQL_INSTALL_TARGET_OPTS += DESTDIR=$(TARGET_DIR) install-world
RASPUTIN_POSTGRESQL_INSTALL_STAGING_OPTS += DESTDIR=$(STAGING_DIR) install-world
endif

ifeq ($(BR2_PACKAGE_READLINE),y)
RASPUTIN_POSTGRESQL_DEPENDENCIES += readline
RASPUTIN_POSTGRESQL_CONF_OPTS += -Dreadline=enabled
else
RASPUTIN_POSTGRESQL_CONF_OPTS += -Dreadline=disabled
endif

ifeq ($(BR2_PACKAGE_ZLIB),y)
RASPUTIN_POSTGRESQL_DEPENDENCIES += zlib
RASPUTIN_POSTGRESQL_CONF_OPTS += -Dzlib=enabled
else
RASPUTIN_POSTGRESQL_CONF_OPTS += -Dzlib=disabled
endif

ifeq ($(BR2_PACKAGE_TZDATA),y)
RASPUTIN_POSTGRESQL_DEPENDENCIES += tzdata
RASPUTIN_POSTGRESQL_CONF_OPTS += -Dsystem_tzdata=/usr/share/zoneinfo
else
RASPUTIN_POSTGRESQL_DEPENDENCIES += host-zic
RASPUTIN_POSTGRESQL_CONF_ENV += ZIC="$(ZIC)"
endif

ifeq ($(BR2_PACKAGE_OPENSSL),y)
RASPUTIN_POSTGRESQL_DEPENDENCIES += openssl
RASPUTIN_POSTGRESQL_CONF_OPTS += -Dssl=openssl
else
RASPUTIN_POSTGRESQL_CONF_OPTS += -Dssl=none
endif

ifeq ($(BR2_PACKAGE_OPENLDAP),y)
RASPUTIN_POSTGRESQL_DEPENDENCIES += openldap
RASPUTIN_POSTGRESQL_CONF_OPTS += -Dldap=enabled
else
RASPUTIN_POSTGRESQL_CONF_OPTS += -Dldap=disabled
endif

ifeq ($(BR2_PACKAGE_ICU),y)
RASPUTIN_POSTGRESQL_DEPENDENCIES += icu
RASPUTIN_POSTGRESQL_CONF_OPTS += -Dicu=enabled
else
RASPUTIN_POSTGRESQL_CONF_OPTS += -Dicu=disabled
endif

ifeq ($(BR2_PACKAGE_LIBXML2),y)
RASPUTIN_POSTGRESQL_DEPENDENCIES += libxml2
RASPUTIN_POSTGRESQL_CONF_OPTS += -Dlibxml=enabled
RASPUTIN_POSTGRESQL_CONF_ENV += XML2_CONFIG=$(STAGING_DIR)/usr/bin/xml2-config
else
RASPUTIN_POSTGRESQL_CONF_OPTS += -Dlibxml=disabled
endif

ifeq ($(BR2_PACKAGE_ZSTD),y)
RASPUTIN_POSTGRESQL_DEPENDENCIES += host-pkgconf zstd
RASPUTIN_POSTGRESQL_CONF_OPTS += -Dzstd=enabled
else
RASPUTIN_POSTGRESQL_CONF_OPTS += -Dzstd=disabled
endif

ifeq ($(BR2_PACKAGE_LZ4),y)
RASPUTIN_POSTGRESQL_DEPENDENCIES += host-pkgconf lz4
RASPUTIN_POSTGRESQL_CONF_OPTS += -Dlz4=enabled
else
RASPUTIN_POSTGRESQL_CONF_OPTS += -Dlz4=disabled
endif

# required for postgresql.service Type=notify
ifeq ($(BR2_PACKAGE_SYSTEMD),y)
RASPUTIN_POSTGRESQL_DEPENDENCIES += systemd
RASPUTIN_POSTGRESQL_CONF_OPTS += -Dsystemd=enabled
else
RASPUTIN_POSTGRESQL_CONF_OPTS += -Dsystemd=disabled
endif

RASPUTIN_POSTGRESQL_CFLAGS = $(TARGET_CFLAGS)

ifneq ($(BR2_TOOLCHAIN_HAS_GCC_BUG_43744)$(BR2_TOOLCHAIN_HAS_GCC_BUG_85180),)
RASPUTIN_POSTGRESQL_CFLAGS += -O0
endif

RASPUTIN_POSTGRESQL_CONF_ENV += CFLAGS="$(RASPUTIN_POSTGRESQL_CFLAGS)"

define RASPUTIN_POSTGRESQL_USERS
	postgres -1 postgres -1 * /var/lib/pgsql /bin/sh - PostgreSQL Server
endef

define RASPUTIN_POSTGRESQL_INSTALL_TARGET_FIXUP
	$(INSTALL) -dm 0700 $(TARGET_DIR)/var/lib/pgsql
	$(RM) -rf $(TARGET_DIR)/usr/lib/postgresql/pgxs
endef

RASPUTIN_POSTGRESQL_POST_INSTALL_TARGET_HOOKS += RASPUTIN_POSTGRESQL_INSTALL_TARGET_FIXUP

define RASPUTIN_POSTGRESQL_INSTALL_CUSTOM_PG_CONFIG
	$(INSTALL) -m 0755 -D $(RASPUTIN_POSTGRESQL_PKGDIR)/pg_config \
		$(STAGING_DIR)/usr/bin/pg_config
	$(SED) "s|@POSTGRESQL_CONF_OPTIONS@|$(RASPUTIN_POSTGRESQL_CONF_OPTS)|g" $(STAGING_DIR)/usr/bin/pg_config
	$(SED) "s|@POSTGRESQL_VERSION@|$(RASPUTIN_POSTGRESQL_VERSION)|g" $(STAGING_DIR)/usr/bin/pg_config
	$(SED) "s|@TARGET_CFLAGS@|$(TARGET_CFLAGS)|g" $(STAGING_DIR)/usr/bin/pg_config
	$(SED) "s|@TARGET_CC@|$(TARGET_CC)|g" $(STAGING_DIR)/usr/bin/pg_config
endef

RASPUTIN_POSTGRESQL_POST_INSTALL_STAGING_HOOKS += RASPUTIN_POSTGRESQL_INSTALL_CUSTOM_PG_CONFIG

define RASPUTIN_POSTGRESQL_INSTALL_INIT_SYSV
	$(INSTALL) -m 0755 -D $(RASPUTIN_POSTGRESQL_PKGDIR)/S50postgresql \
		$(TARGET_DIR)/etc/init.d/S50postgresql
endef

define RASPUTIN_POSTGRESQL_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 644 $(RASPUTIN_POSTGRESQL_PKGDIR)/postgresql.service \
		$(TARGET_DIR)/usr/lib/systemd/system/postgresql.service
endef

$(eval $(meson-package))
