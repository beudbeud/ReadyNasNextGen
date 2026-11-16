include $(sort $(wildcard $(BR2_EXTERNAL_READYNAS_NG_PATH)/package/*/*.mk))

# Initramfs minimal intégré au noyau (CONFIG_INITRAMFS_SOURCE =
# usr/padre-initramfs.list, cf. board/readynas-duo-v1/linux-padre-nas.fragment) :
# /init vient de board/…/initramfs, les binaires (busybox statique, tests) du
# paquet readynas-initramfs, construit avant la configuration du noyau.
ifeq ($(BR2_PACKAGE_READYNAS_INITRAMFS),y)
define READYNAS_NG_INITRAMFS_LIST
	sed -e 's|@SRC@|$(READYNAS_INITRAMFS_BOARD)|' \
	    -e 's|@BIN@|$(BINARIES_DIR)/readynas-initramfs|' \
		$(READYNAS_INITRAMFS_BOARD)/liste > $(LINUX_DIR)/usr/padre-initramfs.list
endef
LINUX_PRE_BUILD_HOOKS += READYNAS_NG_INITRAMFS_LIST
# LINUX_DEPENDENCIES est déjà évalué quand external.mk est lu : ordre explicite
$(LINUX_TARGET_CONFIGURE): | readynas-initramfs
endif
