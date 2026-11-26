################################################################################
#
# xraid-compat: ReadyNAS Duo v1 X-RAID under Linux 6.18
#
################################################################################

# Sources in this repository (package/xraid-compat/src): three C programs, scripts.
XRAID_COMPAT_VERSION = 1.0
XRAID_COMPAT_SITE = $(BR2_EXTERNAL_READYNAS_NG_PATH)/package/xraid-compat/src
XRAID_COMPAT_SITE_METHOD = local
XRAID_COMPAT_LICENSE = GPL-2.0
XRAID_COMPAT_DEPENDENCIES = lvm2 mdadm e2fsprogs rsync

# nas-raid also uses busybox's flock and partprobe (enabled by default)
define XRAID_COMPAT_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -Wall \
		-o $(@D)/xraid-info $(@D)/xraid-info.c
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -Wall \
		-o $(@D)/xraid-sb $(@D)/xraid-sb.c
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -Wall \
		-o $(@D)/flexraid-sb $(@D)/flexraid-sb.c
endef

define XRAID_COMPAT_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/xraid-info $(TARGET_DIR)/usr/sbin/xraid-info
	$(INSTALL) -D -m 0755 $(@D)/xraid-sb $(TARGET_DIR)/usr/sbin/xraid-sb
	$(INSTALL) -D -m 0755 $(@D)/flexraid-sb $(TARGET_DIR)/usr/sbin/flexraid-sb
	$(INSTALL) -D -m 0755 $(@D)/nas-raid $(TARGET_DIR)/usr/sbin/nas-raid
	$(INSTALL) -D -m 0755 $(@D)/S35storage $(TARGET_DIR)/etc/init.d/S35storage
	mkdir -p $(TARGET_DIR)/var/lib/nas-raid $(TARGET_DIR)/c
endef

$(eval $(generic-package))
