################################################################################
#
# temurin-jre
#
# The Java runtime for the identity service (geekdojo/geekdojo-brain#969,
# Identity 2.1; platform.md §2.1). Adoptium's pre-built Eclipse Temurin JRE,
# per arch, installed to /usr/lib/temurin-jre with an empty PKCS-12
# lib/security/jssecacerts (platform.md §3.7) and its licences under
# /usr/share/licenses/temurin-jre/. The host variant, at the same pin, goes to
# $(HOST_DIR)/lib/temurin-jre: the target install runs its keytool, and the
# image build's `kc.sh build` (Identity 2.3) runs its java.
#
# The binaries are linked against glibc, so check-needed.sh runs as a
# target-finalize hook and fails the build when any ELF in the installed JRE
# names a NEEDED library the image does not carry. The four desktop libraries
# (TEMURIN_JRE_DESKTOP_LIBS) need X11 or ALSA and never load in a headless
# JVM, so they are removed rather than allowlisted.
#
# HOW THE HASHES IN temurin-jre.hash ARE TAKEN. Never from a download alone:
# only from a tarball whose Adoptium signature verified. V is the version
# (25.0.5+8), F the file version (25.0.5_8), M the major (25). The anchor is
# Adoptium's signing key, whose fingerprint adoptium.net publishes
# (adoptium.net/news/2022/07/gpg-signed-releases/) and which
# TEMURIN_JRE_ADOPTIUM_SIGNER_FPR records. In an empty scratch dir, for each of
# OpenJDK${M}U-jre_aarch64_linux_hotspot_$F.tar.gz,
# OpenJDK${M}U-jre_x64_linux_hotspot_$F.tar.gz and
# OpenJDK${M}U-jdk-sources_$F.tar.gz:
#
#   1. export GNUPGHOME="$(mktemp -d)"
#   2. curl -fsSLO <TEMURIN_JRE_SITE>/<file> and curl -fsSLO <...>/<file>.sig
#   3. gpg --import package/temurin-jre/adoptium-signing-key.asc
#      `gpg --show-keys --with-colons` on that file must give the primary
#      fingerprint TEMURIN_JRE_ADOPTIUM_SIGNER_FPR.
#   4. gpg --status-fd 1 --verify <file>.sig <file>
#      must exit 0 and print GOODSIG and VALIDSIG ... <the fingerprint>.
#   5. Only then copy `sha256sum <file>` into temurin-jre.hash. The licence
#      lines are computed from the files extracted from the verified x64
#      tarball; legal-info's hash check proves the aarch64 copies match.
#
# geekdojo-brain's projects/rasputin/research/identity-evidence/958/
# verify-signatures.sh runs every step above plus negative controls. Its runs
# for this pin are the transcripts cited in temurin-jre.hash's header.
# test/temurin-jre-functional.sh repeats steps 2-4 against the committed key
# on every CI run, for every tarball the build downloads.
#
# To bump: run the procedure, set TEMURIN_JRE_VERSION (everything else is
# derived from it), and replace the three tarball lines and, if they changed,
# the licence lines in temurin-jre.hash.
#
################################################################################

TEMURIN_JRE_VERSION = 25.0.5+8
# The host variant is pinned to the same release, never its own.
HOST_TEMURIN_JRE_VERSION = $(TEMURIN_JRE_VERSION)
# Adoptium's file names write the build separator as "_" (25.0.5_8).
TEMURIN_JRE_FILE_VERSION = $(subst +,_,$(TEMURIN_JRE_VERSION))
TEMURIN_JRE_VERSION_MAJOR = $(firstword $(subst ., ,$(TEMURIN_JRE_VERSION)))
TEMURIN_JRE_SITE = https://github.com/adoptium/temurin$(TEMURIN_JRE_VERSION_MAJOR)-binaries/releases/download/jdk-$(subst +,%2B,$(TEMURIN_JRE_VERSION))

# Only when the package is on: a defconfig without the runtime must build on
# any architecture, and one with it must never fall through to an empty arch.
ifeq ($(BR2_PACKAGE_TEMURIN_JRE),y)
ifeq ($(BR2_aarch64),y)
TEMURIN_JRE_ARCH = aarch64
else ifeq ($(BR2_x86_64),y)
TEMURIN_JRE_ARCH = x64
else
# No closing full stop: GNU make appends ".  Stop." to every $(error).
$(error Temurin JRE has no release tarball mapped for the target architecture $(BR2_ARCH). Add the architecture to the map in package/temurin-jre/temurin-jre.mk and its sha256 to temurin-jre.hash)
endif
ifeq ($(HOSTARCH),x86_64)
HOST_TEMURIN_JRE_ARCH = x64
else ifeq ($(HOSTARCH),aarch64)
HOST_TEMURIN_JRE_ARCH = aarch64
else
$(error Temurin JRE has no release tarball mapped for the build host architecture $(HOSTARCH). Add the architecture to the map in package/temurin-jre/temurin-jre.mk and its sha256 to temurin-jre.hash)
endif
endif

TEMURIN_JRE_SOURCE = OpenJDK$(TEMURIN_JRE_VERSION_MAJOR)U-jre_$(TEMURIN_JRE_ARCH)_linux_hotspot_$(TEMURIN_JRE_FILE_VERSION).tar.gz
HOST_TEMURIN_JRE_SOURCE = OpenJDK$(TEMURIN_JRE_VERSION_MAJOR)U-jre_$(HOST_TEMURIN_JRE_ARCH)_linux_hotspot_$(TEMURIN_JRE_FILE_VERSION).tar.gz

# The source tarball is what legal-info saves; the binary is never saved as
# source. The host variant does not inherit these (pkg-generic.mk), so it
# carries its own pair.
TEMURIN_JRE_ACTUAL_SOURCE_TARBALL = OpenJDK$(TEMURIN_JRE_VERSION_MAJOR)U-jdk-sources_$(TEMURIN_JRE_FILE_VERSION).tar.gz
TEMURIN_JRE_ACTUAL_SOURCE_SITE = $(TEMURIN_JRE_SITE)
HOST_TEMURIN_JRE_ACTUAL_SOURCE_TARBALL = $(TEMURIN_JRE_ACTUAL_SOURCE_TARBALL)
HOST_TEMURIN_JRE_ACTUAL_SOURCE_SITE = $(TEMURIN_JRE_SITE)

TEMURIN_JRE_LICENSE = GPL-2.0 with Classpath-exception-2.0
TEMURIN_JRE_LICENSE_FILES = \
	legal/java.base/LICENSE \
	legal/java.base/ASSEMBLY_EXCEPTION \
	legal/java.base/ADDITIONAL_LICENSE_INFO

# NVD files Java SE 25 under cpe:2.3:a:oracle:jre (CVE-2025-53057,
# CVE-2026-21932), not oracle:openjdk. test/temurin-jre-functional.sh proves it
# with Buildroot's own matcher. The version is the pin without its build.
TEMURIN_JRE_CPE_ID_VENDOR = oracle
TEMURIN_JRE_CPE_ID_PRODUCT = jre
TEMURIN_JRE_CPE_ID_VERSION = $(firstword $(subst +, ,$(TEMURIN_JRE_VERSION)))

# The target install runs the host keytool.
TEMURIN_JRE_DEPENDENCIES = host-temurin-jre

# Adoptium's signing key, the anchor of every hash in temurin-jre.hash. Only
# the functional test reads it, so the fingerprint is written once.
TEMURIN_JRE_ADOPTIUM_SIGNER_FPR = 3B04D753C9050D9A5D343F39843C48A565F8F04B

# Exactly the release's top level: never $(@D)/., which carries Buildroot's
# .stamp_* and .files-list* files into the image.
TEMURIN_JRE_INSTALL_LIST = bin conf lib legal NOTICE release
TEMURIN_JRE_DESKTOP_LIBS = libawt_xawt.so libjawt.so libsplashscreen.so libjsound.so

TEMURIN_JRE_TARGET_HOME = $(TARGET_DIR)/usr/lib/temurin-jre
TEMURIN_JRE_HOST_KEYTOOL = $(HOST_DIR)/lib/temurin-jre/bin/keytool
# changeit is the JDK's public default password, protecting an empty store.
TEMURIN_JRE_JSSECACERTS_ARGS = -storetype PKCS12 -storepass changeit \
	-keystore $(TEMURIN_JRE_TARGET_HOME)/lib/security/jssecacerts

# keytool cannot create an empty store directly: add one throwaway entry,
# delete it, and require the listing to show no entries.
define TEMURIN_JRE_INSTALL_EMPTY_JSSECACERTS
	rm -f $(TEMURIN_JRE_TARGET_HOME)/lib/security/jssecacerts
	{ $(TEMURIN_JRE_HOST_KEYTOOL) -genkeypair -alias temurin-jre-empty \
		-keyalg EC -groupname secp256r1 -dname CN=empty -keypass changeit \
		$(TEMURIN_JRE_JSSECACERTS_ARGS) && \
	  $(TEMURIN_JRE_HOST_KEYTOOL) -delete -alias temurin-jre-empty \
		$(TEMURIN_JRE_JSSECACERTS_ARGS) && \
	  $(TEMURIN_JRE_HOST_KEYTOOL) -list $(TEMURIN_JRE_JSSECACERTS_ARGS) \
		| grep -qx 'Your keystore contains 0 entries'; } || \
	{ echo "Could not create an empty jssecacerts trust store for the Temurin JRE: the host keytool failed or the store is not empty, and Keycloak will not start with a wrong store." >&2; exit 1; }
endef

define TEMURIN_JRE_INSTALL_TARGET_CMDS
	mkdir -p $(TEMURIN_JRE_TARGET_HOME)
	cp -af $(addprefix $(@D)/,$(TEMURIN_JRE_INSTALL_LIST)) $(TEMURIN_JRE_TARGET_HOME)/
	rm -f $(addprefix $(TEMURIN_JRE_TARGET_HOME)/lib/,$(TEMURIN_JRE_DESKTOP_LIBS))
	$(TEMURIN_JRE_INSTALL_EMPTY_JSSECACERTS)
	$(foreach f,$(TEMURIN_JRE_LICENSE_FILES),\
		$(INSTALL) -D -m 0644 $(@D)/$(f) $(TARGET_DIR)/usr/share/licenses/temurin-jre/$(notdir $(f))$(sep))
endef

define HOST_TEMURIN_JRE_INSTALL_CMDS
	mkdir -p $(HOST_DIR)/lib/temurin-jre
	cp -af $(addprefix $(@D)/,$(TEMURIN_JRE_INSTALL_LIST)) $(HOST_DIR)/lib/temurin-jre/
endef

define TEMURIN_JRE_CHECK_NEEDED
	READELF="$(TARGET_READELF)" $(TEMURIN_JRE_PKGDIR)/check-needed.sh $(TARGET_DIR) usr/lib/temurin-jre
endef
TEMURIN_JRE_TARGET_FINALIZE_HOOKS += TEMURIN_JRE_CHECK_NEEDED

$(eval $(generic-package))
$(eval $(host-generic-package))
