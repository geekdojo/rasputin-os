################################################################################
#
# keycloak
#
# The identity service (geekdojo/geekdojo-brain#971, Identity 2.3;
# platform.md §2.2, §2.3). Keycloak's Quarkus distribution from Maven Central,
# built at image build time and installed to /usr/lib/keycloak.
#
# The build runs, in $(@D), on the build host's own JVM (host-temurin-jre),
# never emulated:
#   1. check-pins.sh (a pre-build hook) compares the api tarball's
#      identity/pins.json with this tree's pins: KEYCLOAK_VERSION and the dist
#      line of keycloak.hash, TEMURIN_JRE_VERSION and the x64 line of
#      temurin-jre.hash. Any difference fails the build, because the image
#      would ship a Keycloak and JRE pairing control-plane CI never ran.
#   2. kc.sh build with --config-file set to the api tarball's
#      identity/keycloak-build.conf, installed by rasputin-api.
#   3. check-build-options.sh compares that conf, as an exact set, with what
#      Keycloak persisted in lib/quarkus/generated-bytecode.jar. kc.sh build
#      accepts an unknown option silently, so this is what fails the build on
#      one. The conf is then the record of the built options (§2.3): nothing
#      else writes a copy.
#
# The install is exactly the dist's top level, plus two links: data to
# /var/lib/rasputin/keycloak/data and themes/rasputin to the api's theme
# directory. conf/truststores/ stays empty and providers/ holds no jar, as
# upstream ships them.
#
# HOW TO BUMP THE PIN. Control-plane first: its identitytest/pin.go moves, a
# control-plane release is cut, and the OS api pin moves to it. Only then
# KEYCLOAK_VERSION here, or check-pins.sh fails the build. V is the version.
#   1. Run geekdojo-brain's projects/rasputin/research/identity-evidence/958/
#      verify-signatures.sh with KC_V=V. It checks the dist's Maven Central
#      .asc against the key whose fingerprint keycloak.org/keys lists for
#      Maven artifacts (KEYCLOAK_SIGNER_FPR), with negative controls. Commit
#      its transcript beside the existing ones and cite it, with its sha256,
#      in keycloak.hash's header.
#   2. If the signing key changed or its expiry moved, re-fetch it by
#      fingerprint from keyserver.ubuntu.com into keycloak-signing-key.asc,
#      check `gpg --show-keys --with-colons` gives KEYCLOAK_SIGNER_FPR and that
#      keycloak.org/keys/keycloak-2.asc is the same key, and update the anchor
#      if keycloak.org lists a new one.
#   3. Take the dist line from the verified transcript only. Take the GitHub
#      source archive's line and LICENSE.txt's line from local downloads, and
#      each -sources.jar line from a download whose sha1 equals Maven
#      Central's published .sha1.
#   4. Scan every jar for GPL-family licences (pom.xml licences,
#      Bundle-License, top-level licence text) and make KEYCLOAK_GPL_JARS
#      exactly that list. test/keycloak-functional.sh runs the same scan and
#      fails on any difference.
#
################################################################################

KEYCLOAK_VERSION = 26.8.2
KEYCLOAK_SITE = https://repo1.maven.org/maven2/org/keycloak/keycloak-quarkus-dist/$(KEYCLOAK_VERSION)
KEYCLOAK_SOURCE = keycloak-quarkus-dist-$(KEYCLOAK_VERSION).tar.gz

# The dist is a binary, so legal-info saves Keycloak's source archive instead
# of it (pkg-generic.mk), and the -sources.jar of every GPL-family jar.
KEYCLOAK_ACTUAL_SOURCE_TARBALL = keycloak-$(KEYCLOAK_VERSION).tar.gz
KEYCLOAK_ACTUAL_SOURCE_SITE = $(call github,keycloak,keycloak,$(KEYCLOAK_VERSION))

# Every jar in the dist whose licence names the GNU GPL or LGPL, as
# groupId:artifactId:version. The dist names each jar
# lib/lib/*/<groupId>.<artifactId>-<version>.jar.
KEYCLOAK_GPL_JARS = \
	com.mysql:mysql-connector-j:9.7.0 \
	io.smallrye.classfile:jdk-classfile-backport:26 \
	jakarta.annotation:jakarta.annotation-api:3.0.0 \
	jakarta.el:jakarta.el-api:6.0.1 \
	jakarta.interceptor:jakarta.interceptor-api:2.2.0 \
	jakarta.json:jakarta.json-api:2.1.3 \
	jakarta.mail:jakarta.mail-api:2.1.1 \
	jakarta.persistence:jakarta.persistence-api:3.2.0 \
	jakarta.resource:jakarta.resource-api:2.1.0 \
	jakarta.servlet:jakarta.servlet-api:6.0.0 \
	jakarta.transaction:jakarta.transaction-api:2.0.1 \
	jakarta.ws.rs:jakarta.ws.rs-api:3.1.0 \
	net.java.dev.jna:jna:5.8.0 \
	org.eclipse.angus:angus-mail:2.0.5 \
	org.eclipse.parsson:parsson:1.1.9 \
	org.mariadb.jdbc:mariadb-java-client:3.5.10

# keycloak-gav COORD,N: field N of groupId:artifactId:version.
keycloak-gav = $(word $(2),$(subst :, ,$(1)))
keycloak-sources-url = https://repo1.maven.org/maven2/$(subst .,/,$(call keycloak-gav,$(1),1))/$(call keycloak-gav,$(1),2)/$(call keycloak-gav,$(1),3)/$(call keycloak-gav,$(1),2)-$(call keycloak-gav,$(1),3)-sources.jar
KEYCLOAK_EXTRA_DOWNLOADS = $(foreach c,$(KEYCLOAK_GPL_JARS),$(call keycloak-sources-url,$(c)))

KEYCLOAK_LICENSE = Apache-2.0, \
	LGPL-2.1+ (mariadb-java-client), \
	GPL-2.0 with Universal-FOSS-exception-1.0 (mysql-connector-j), \
	GPL-2.0 with Classpath-exception-2.0 (jdk-classfile-backport), \
	EPL-2.0 or GPL-2.0 with Classpath-exception-2.0 (Jakarta APIs, parsson, angus-mail), \
	LGPL-2.1+ or Apache-2.0 (jna)
KEYCLOAK_LICENSE_FILES = LICENSE.txt

# NVD files upstream Keycloak's ranges under redhat:keycloak (for example
# CVE-2026-0871, versionEndExcluding 26.4.0); redhat:build_of_keycloak carries
# Red Hat's own build versions. test/keycloak-functional.sh proves the match
# with Buildroot's own matcher.
KEYCLOAK_CPE_ID_VENDOR = redhat

# The build runs the host JRE; the pin check reads pins.json with the host jq;
# rasputin-api installs identity/ into the target first.
KEYCLOAK_DEPENDENCIES = host-temurin-jre rasputin-api host-jq

# Keycloak's Maven signing key, the anchor of the dist line in keycloak.hash.
# Only the functional test reads it, so the fingerprint is written once.
KEYCLOAK_SIGNER_FPR = 861AB50E8CC6611FB6BC01A6B8F12EA26FD6EEBA

# Exactly the dist's top level: never $(@D)/., which carries Buildroot's
# .stamp_* and .files-list* files into the image.
KEYCLOAK_INSTALL_LIST = bin conf lib providers themes LICENSE.txt README.md version.txt
KEYCLOAK_TARGET_HOME = $(TARGET_DIR)/usr/lib/keycloak
KEYCLOAK_IDENTITY_DIR = $(TARGET_DIR)/usr/share/rasputin/identity
KEYCLOAK_BUILD_CONF = $(KEYCLOAK_IDENTITY_DIR)/keycloak-build.conf

# The x64 JRE tarball's name, which pins.json's jre.linux_x64_sha256 covers,
# whatever the target architecture. temurin-jre.mk owns the name's pattern.
# Every variable from temurin-jre.mk is used only in recipes: external.mk
# parses keycloak.mk first, so all of them are recursive (=).
KEYCLOAK_JRE_X64_TARBALL = $(subst _$(TEMURIN_JRE_ARCH)_linux_,_x64_linux_,$(TEMURIN_JRE_SOURCE))

define KEYCLOAK_CHECK_PINS
	JQ="$(HOST_DIR)/bin/jq" $(KEYCLOAK_PKGDIR)/check-pins.sh \
		$(KEYCLOAK_IDENTITY_DIR)/pins.json \
		$(KEYCLOAK_VERSION) $(KEYCLOAK_PKGDIR)/keycloak.hash $(KEYCLOAK_SOURCE) \
		$(TEMURIN_JRE_VERSION) $(TEMURIN_JRE_PKGDIR)/temurin-jre.hash $(KEYCLOAK_JRE_X64_TARBALL)
endef
KEYCLOAK_PRE_BUILD_HOOKS += KEYCLOAK_CHECK_PINS

define KEYCLOAK_BUILD_CMDS
	JAVA_HOME=$(HOST_DIR)/lib/temurin-jre $(@D)/bin/kc.sh \
		--config-file=$(KEYCLOAK_BUILD_CONF) build || \
	{ rc=$$?; echo "kc.sh build exited $$rc on the build options in $(KEYCLOAK_BUILD_CONF), so Keycloak cannot be built with them; its own output is above." >&2; exit 1; }
	$(KEYCLOAK_PKGDIR)/check-build-options.sh $(KEYCLOAK_BUILD_CONF) \
		$(@D)/lib/quarkus/generated-bytecode.jar
endef

define KEYCLOAK_INSTALL_TARGET_CMDS
	mkdir -p $(KEYCLOAK_TARGET_HOME)
	cp -af $(addprefix $(@D)/,$(KEYCLOAK_INSTALL_LIST)) $(KEYCLOAK_TARGET_HOME)/
	ln -sfn /var/lib/rasputin/keycloak/data $(KEYCLOAK_TARGET_HOME)/data
	ln -sfn /usr/share/rasputin/identity/theme $(KEYCLOAK_TARGET_HOME)/themes/rasputin
	$(INSTALL) -D -m 0644 $(@D)/LICENSE.txt $(TARGET_DIR)/usr/share/licenses/keycloak/LICENSE.txt
	$(INSTALL) -D -m 0644 $(KEYCLOAK_PKGDIR)/SOURCE $(TARGET_DIR)/usr/share/licenses/keycloak/SOURCE
endef

$(eval $(generic-package))
