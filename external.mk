include $(sort $(wildcard $(BR2_EXTERNAL_READYNAS_NG_PATH)/package/*/*.mk))

# Nothing of the build PC in the images (checked by board/readynas-duo-v1/post-image.sh).
# BR2_REPRODUCIBLE would set the kernel user/host and a -ffile-prefix-map, but it
# also changes the toolchain wrapper (everything rebuilt, ccache missed), removes
# the build-ids, dates every file and the kernel with the last commit, and
# leaves the ffmpeg configure line as it is: these three settings are enough.
# - kernel banner: "(readynasng@build)" instead of the builder's user@host
LINUX_MAKE_ENV += KBUILD_BUILD_USER=readynasng KBUILD_BUILD_HOST=build
# - sqlite3 shell: assert() messages carry __FILE__ (absolute path of shell.c)
SQLITE_CFLAGS += -ffile-prefix-map=$(BASE_DIR)/=
# - uClibc's getconf: GETCONF_DIR (where "getconf -v" looks for its specs) is
#   the build folder; glibc's place instead (nothing is installed there)
define READYNAS_NG_UCLIBC_GETCONF_DIR
	sed -i "s|-DGETCONF_DIR='\"\$$(CURDIR)\"'|-DGETCONF_DIR='\"/usr/libexec/getconf\"'|" $(@D)/utils/Makefile.in
endef
UCLIBC_POST_PATCH_HOOKS += READYNAS_NG_UCLIBC_GETCONF_DIR
# - ffmpeg: av*_configuration() return the configure command line, full of
#   absolute paths of output/ (cross-prefix, sysroot, pkg-config): made relative
define READYNAS_NG_FFMPEG_NO_PATHS
	sed -i '/^#define FFMPEG_CONFIGURATION /s|$(BASE_DIR)/||g' $(@D)/config.h
endef
FFMPEG_POST_CONFIGURE_HOOKS += READYNAS_NG_FFMPEG_NO_PATHS

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
