################################################################################
#
# readynas-initramfs : busybox statique sans flottant + tests, pour
# l'initramfs intégré au noyau (voir external.mk)
#
################################################################################

READYNAS_INITRAMFS_VERSION = $(BUSYBOX_VERSION)
READYNAS_INITRAMFS_SOURCE = $(BUSYBOX_SOURCE)
READYNAS_INITRAMFS_SITE = $(BUSYBOX_SITE)
READYNAS_INITRAMFS_DL_SUBDIR = busybox
READYNAS_INITRAMFS_LICENSE = GPL-2.0
READYNAS_INITRAMFS_LICENSE_FILES = LICENSE
READYNAS_INITRAMFS_INSTALL_TARGET = NO
READYNAS_INITRAMFS_INSTALL_IMAGES = YES
READYNAS_INITRAMFS_BOARD = $(BR2_EXTERNAL_READYNAS_NG_PATH)/board/readynas-duo-v1/initramfs

# mêmes correctifs que le paquet busybox de Buildroot
define READYNAS_INITRAMFS_BUSYBOX_PATCHES
	$(APPLY_PATCHES) $(@D) $(TOPDIR)/package/busybox \*.patch
endef
READYNAS_INITRAMFS_POST_PATCH_HOOKS += READYNAS_INITRAMFS_BUSYBOX_PATCHES

# busybox.config : CONFIG_STATIC=y, CONFIG_FLOAT_DURATION non (sleep en
# entiers : chaque instruction flottante est émulée par le noyau)
define READYNAS_INITRAMFS_BUILD_CMDS
	cp $(READYNAS_INITRAMFS_BOARD)/busybox.config $(@D)/.config
	yes "" | $(TARGET_MAKE_ENV) $(MAKE) -C $(@D) \
		CROSS_COMPILE="$(TARGET_CROSS)" oldconfig >/dev/null
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) CROSS_COMPILE="$(TARGET_CROSS)" busybox
	for p in fenetres charge flottant; do \
		$(TARGET_CC) -O2 -static -o $(@D)/padre-$$p \
			$(READYNAS_INITRAMFS_BOARD)/$$p.c || exit 1; \
	done
endef

define READYNAS_INITRAMFS_INSTALL_IMAGES_CMDS
	mkdir -p $(BINARIES_DIR)/readynas-initramfs
	$(INSTALL) -m 0755 $(@D)/busybox $(BINARIES_DIR)/readynas-initramfs/busybox
	for p in fenetres charge flottant; do \
		$(INSTALL) -m 0755 $(@D)/padre-$$p \
			$(BINARIES_DIR)/readynas-initramfs/$$p || exit 1; \
	done
endef

$(eval $(generic-package))
