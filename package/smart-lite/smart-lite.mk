################################################################################
#
# smart-lite: ATA SMART reader and self-test starter (SG_IO, ATA PASS-THROUGH 16), plain C
#
################################################################################

SMART_LITE_VERSION = 1.0
SMART_LITE_SITE = $(BR2_EXTERNAL_READYNAS_NG_PATH)/package/smart-lite/src
SMART_LITE_SITE_METHOD = local
SMART_LITE_LICENSE = GPL-2.0

define SMART_LITE_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -o $(@D)/smart-lite $(@D)/smart-lite.c
endef

define SMART_LITE_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/smart-lite $(TARGET_DIR)/usr/sbin/smart-lite
endef

$(eval $(generic-package))
