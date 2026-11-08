################################################################################
#
# temurin-jre — SPIKE ONLY (geekdojo-brain#957), platform.md §2.1
#
################################################################################

TEMURIN_JRE_VERSION = 25.0.5_8
TEMURIN_JRE_RELEASE = jdk-25.0.5%2B8
TEMURIN_JRE_SITE = https://github.com/adoptium/temurin25-binaries/releases/download/$(TEMURIN_JRE_RELEASE)
ifeq ($(BR2_aarch64),y)
TEMURIN_JRE_ARCH = aarch64
else
TEMURIN_JRE_ARCH = x64
endif
TEMURIN_JRE_SOURCE = OpenJDK25U-jre_$(TEMURIN_JRE_ARCH)_linux_hotspot_$(TEMURIN_JRE_VERSION).tar.gz
# The build host is the x86_64 runner.
HOST_TEMURIN_JRE_SOURCE = OpenJDK25U-jre_x64_linux_hotspot_$(TEMURIN_JRE_VERSION).tar.gz
TEMURIN_JRE_LICENSE = GPL-2.0 with Classpath exception
TEMURIN_JRE_LICENSE_FILES = legal/java.base/LICENSE

define TEMURIN_JRE_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/usr/lib/temurin-jre
	cp -a $(@D)/. $(TARGET_DIR)/usr/lib/temurin-jre/
endef

define HOST_TEMURIN_JRE_INSTALL_CMDS
	mkdir -p $(HOST_DIR)/lib/temurin-jre
	cp -a $(@D)/. $(HOST_DIR)/lib/temurin-jre/
endef

$(eval $(generic-package))
$(eval $(host-generic-package))
