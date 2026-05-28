################################################################################
# Rasputin OS external tree — package makefiles
#
# Buildroot sources this automatically when invoked with
#   make BR2_EXTERNAL=/path/to/rasputin-os ...
# The variable $(BR2_EXTERNAL_RASPUTIN_PATH) is set by Buildroot from
# external.desc's `name: RASPUTIN`.
################################################################################

include $(sort $(wildcard $(BR2_EXTERNAL_RASPUTIN_PATH)/package/*/*.mk))
