################################################################################
#
# xraid-compat : X-RAID du ReadyNAS Duo v1 sous Linux 6.18, bascule vers md
#
################################################################################

# Sources dans ce dépôt (package/xraid-compat/src) : un programme C, des scripts.
XRAID_COMPAT_VERSION = 1.0
XRAID_COMPAT_SITE = $(BR2_EXTERNAL_READYNAS_NG_PATH)/package/xraid-compat/src
XRAID_COMPAT_SITE_METHOD = local
XRAID_COMPAT_LICENSE = GPL-2.0
XRAID_COMPAT_DEPENDENCIES = lvm2 mdadm e2fsprogs rsync

# nas-raid utilise aussi flock et partprobe de busybox (actifs par défaut)
define XRAID_COMPAT_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -Wall \
		-o $(@D)/xraid-info $(@D)/xraid-info.c
endef

define XRAID_COMPAT_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/xraid-info $(TARGET_DIR)/usr/sbin/xraid-info
	$(INSTALL) -D -m 0755 $(@D)/nas-raid $(TARGET_DIR)/usr/sbin/nas-raid
	$(INSTALL) -D -m 0755 $(@D)/S35stockage $(TARGET_DIR)/etc/init.d/S35stockage
	mkdir -p $(TARGET_DIR)/var/lib/nas-raid $(TARGET_DIR)/mnt/md $(TARGET_DIR)/c
endef

$(eval $(generic-package))
