################################################################################
#
# keycloak — SPIKE ONLY (geekdojo-brain#957), platform.md §2.2-§2.3
#
# 26.8.2 was the latest 26.8.z on Maven Central when this was written
# (maven-metadata.xml <release>26.8.2</release>, read 2026-11-08).
#
################################################################################

KEYCLOAK_VERSION = 26.8.2
KEYCLOAK_SOURCE = keycloak-quarkus-dist-$(KEYCLOAK_VERSION).tar.gz
KEYCLOAK_SITE = https://repo1.maven.org/maven2/org/keycloak/keycloak-quarkus-dist/$(KEYCLOAK_VERSION)
KEYCLOAK_LICENSE = Apache-2.0
KEYCLOAK_LICENSE_FILES = LICENSE.txt
KEYCLOAK_DEPENDENCIES = host-temurin-jre

# kc.sh takes --config-file before the command. The build runs offline and
# freezes the build-time options into lib/quarkus.
define KEYCLOAK_BUILD_CMDS
	JAVA_HOME=$(HOST_DIR)/lib/temurin-jre \
		$(@D)/bin/kc.sh --config-file=$(KEYCLOAK_PKGDIR)/keycloak-build.conf build
endef

# data/ is fixed at the home directory's data, so it becomes a link to the
# scratch directory the footprint probe writes (scratch mode, never an image
# install on a node).
define KEYCLOAK_INSTALL_TARGET_CMDS
	rm -rf $(TARGET_DIR)/usr/lib/keycloak
	mkdir -p $(TARGET_DIR)/usr/lib/keycloak
	cp -a $(@D)/bin $(@D)/conf $(@D)/lib $(@D)/providers $(@D)/themes $(@D)/version.txt $(TARGET_DIR)/usr/lib/keycloak/
	ln -sfn /var/lib/rasputin/spike957/kc-data $(TARGET_DIR)/usr/lib/keycloak/data
endef

$(eval $(generic-package))
