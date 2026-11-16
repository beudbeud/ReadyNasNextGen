include $(sort $(wildcard $(BR2_EXTERNAL_READYNAS_NG_PATH)/package/*/*.mk))

# Minimal initramfs built into the kernel (CONFIG_INITRAMFS_SOURCE =
# usr/padre-initramfs.list, see board/readynas-duo-v1/linux-padre-nas.fragment):
# /init comes from board/.../initramfs, the binaries (static busybox, tests)
# from the readynas-initramfs package, built before the kernel configuration.
ifeq ($(BR2_PACKAGE_READYNAS_INITRAMFS),y)
define READYNAS_NG_INITRAMFS_LIST
	sed -e 's|@SRC@|$(READYNAS_INITRAMFS_BOARD)|' \
	    -e 's|@BIN@|$(BINARIES_DIR)/readynas-initramfs|' \
		$(READYNAS_INITRAMFS_BOARD)/list > $(LINUX_DIR)/usr/padre-initramfs.list
endef
LINUX_PRE_BUILD_HOOKS += READYNAS_NG_INITRAMFS_LIST
# LINUX_DEPENDENCIES is already evaluated when external.mk is read: explicit order
$(LINUX_TARGET_CONFIGURE): | readynas-initramfs
endif
