################################################################################
#
# diet: ReadyNAS Duo v1 web dashboard (Linux 6.18)
#
################################################################################

# Sources in this repository (package/diet/src, target file system layout):
# shell/awk scripts and an HTML page, nothing to compile.
DIET_VERSION = 3.0
DIET_SITE = $(BR2_EXTERNAL_READYNAS_NG_PATH)/package/diet/src
DIET_SITE_METHOD = local
DIET_LICENSE = GPL-2.0
DIET_DEPENDENCIES = busybox lighttpd mbedtls ksmbd-tools nfs-utils mdadm libcurl ca-certificates

# System account of the WebDAV lighttpd instance (S51webdav): files uploaded
# through WebDAV belong to it, never to root; it is a member of each user's
# personal group (added by the API).
define DIET_USERS
	nas -1 nas -1 * - - - DIET WebDAV
endef

# Busybox applets used by the scripts, missing from the default busybox.config.
# "Standalone" shell: ash runs its applets without searching PATH, "nofork"
# applets (cat, echo, printf, test, mkdir...) without fork or exec and "noexec"
# ones (rm, mv...) without exec. On this SPARC, starting (dynamic) busybox costs
# about 60 ms: the API and the init scripts benefit from it. The static busybox
# of the initramfs (package/readynas-initramfs) is not affected.
define DIET_BUSYBOX_CONFIG_FIXUPS
	$(call KCONFIG_ENABLE_OPT,CONFIG_NTPD)
	$(call KCONFIG_DISABLE_OPT,CONFIG_FEATURE_WGET_HTTPS)
	$(call KCONFIG_ENABLE_OPT,CONFIG_FEATURE_PREFER_APPLETS)
	$(call KCONFIG_ENABLE_OPT,CONFIG_FEATURE_SH_STANDALONE)
	$(call KCONFIG_ENABLE_OPT,CONFIG_FEATURE_SH_NOFORK)
	$(if $(BR2_PACKAGE_HDPARM),$(call KCONFIG_DISABLE_OPT,CONFIG_HDPARM))
	$(if $(BR2_PACKAGE_E2FSPROGS),$(call KCONFIG_DISABLE_OPT,CONFIG_MKE2FS))
	$(if $(BR2_PACKAGE_E2FSPROGS),$(call KCONFIG_DISABLE_OPT,CONFIG_CHATTR))
	$(if $(BR2_PACKAGE_E2FSPROGS),$(call KCONFIG_DISABLE_OPT,CONFIG_LSATTR))
	$(if $(BR2_PACKAGE_E2FSPROGS_FSCK),$(call KCONFIG_DISABLE_OPT,CONFIG_FSCK))
endef
# With this shell an applet wins over the program of the same name in PATH:
# applets duplicated by a real program of the image (hdparm, e2fsprogs) are
# removed, so that the scripts keep the real program.

# S50lighttpd and lighttpd.conf replace Buildroot's: copied again in
# DIET_FINALIZE, because with per-package directories the final assembly of
# target/ may put lighttpd's files back after ours.
define DIET_INSTALL_TARGET_CMDS
	for d in etc sbin usr www; do \
		cp -dR --no-preserve=ownership $(@D)/$$d $(TARGET_DIR)/ || exit 1; \
	done
	echo "$(DIET_VERSION)" > $(TARGET_DIR)/etc/diet-version
	ln -sf diet-hotplug $(TARGET_DIR)/sbin/hotplug
	mkdir -p -m 0700 $(TARGET_DIR)/etc/lighttpd/ssl
	mkdir -p $(TARGET_DIR)/c
endef

# mbedTLS installs about forty example programs: keep only the HTTPS
# certificate ones (S50lighttpd). The annotated lighttpd configuration is useless.
define DIET_FINALIZE
	for f in $$(sed -n 's#.*/usr/bin/##p' $(MBEDTLS_DIR)/install_manifest.txt \
			$(MBEDTLS_DIR)/buildroot-build/install_manifest.txt 2>/dev/null | sort -u); do \
		case "$$f" in gen_key|cert_write) ;; *) rm -f "$(TARGET_DIR)/usr/bin/$$f" ;; esac; \
	done
	rm -f $(TARGET_DIR)/etc/lighttpd/lighttpd.annotated.conf
	$(INSTALL) -m 0644 $(DIET_PKGDIR)/src/etc/lighttpd/lighttpd.conf $(TARGET_DIR)/etc/lighttpd/lighttpd.conf
	$(INSTALL) -m 0755 $(DIET_PKGDIR)/src/etc/init.d/S50lighttpd $(TARGET_DIR)/etc/init.d/S50lighttpd
endef
DIET_TARGET_FINALIZE_HOOKS += DIET_FINALIZE

$(eval $(generic-package))
