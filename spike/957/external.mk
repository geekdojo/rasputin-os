################################################################################
# SPIKE ONLY — geekdojo/geekdojo-brain#957. A second BR2_EXTERNAL tree that
# adds the identity runtime (Temurin JRE, Keycloak) beside Buildroot's own
# PostgreSQL, so the spike workflow can measure what they add to the image.
# Never merged, tagged or published.
################################################################################

include $(sort $(wildcard $(BR2_EXTERNAL_SPIKE957_PATH)/package/*/*.mk))

# Buildroot's postgresql package installs postgresql.service with an [Install]
# section, and preset-all would enable it (initdb into the read-only
# /var/lib/pgsql). Mask it, as platform.md §2.4 plans for the product.
define SPIKE957_MASK_POSTGRESQL_SERVICE
	mkdir -p $(TARGET_DIR)/etc/systemd/system
	ln -sf /dev/null $(TARGET_DIR)/etc/systemd/system/postgresql.service
endef
POSTGRESQL_POST_INSTALL_TARGET_HOOKS += SPIKE957_MASK_POSTGRESQL_SERVICE
