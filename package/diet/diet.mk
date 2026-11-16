################################################################################
#
# diet : tableau de bord web du ReadyNAS Duo v1 (Linux 6.18)
#
################################################################################

# Sources dans ce dépôt (package/diet/src, arborescence du système cible) :
# scripts shell/awk et page HTML, rien à compiler.
DIET_VERSION = 3.0
DIET_SITE = $(BR2_EXTERNAL_READYNAS_NG_PATH)/package/diet/src
DIET_SITE_METHOD = local
DIET_LICENSE = GPL-2.0
DIET_DEPENDENCIES = busybox lighttpd mbedtls ksmbd-tools nfs-utils mdadm

# Compte système de l'instance lighttpd WebDAV (S51webdav) : les fichiers
# déposés par WebDAV lui appartiennent, jamais à root ; il est membre du groupe
# personnel de chaque utilisateur (ajouté par l'API).
define DIET_USERS
	nas -1 nas -1 * - - - DIET WebDAV
endef

# Applets busybox utilisés par les scripts, absents du busybox.config par défaut.
# Shell « standalone » : ash lance ses applets sans chercher dans le PATH, les
# applets « nofork » (cat, echo, printf, test, mkdir…) sans fork ni exec et les
# « noexec » (rm, mv…) sans exec. Sur ce SPARC, lancer busybox (dynamique) coûte
# environ 60 ms : l'API et les scripts de démarrage en profitent. Le busybox
# statique de l'initramfs (package/readynas-initramfs) n'est pas concerné.
define DIET_BUSYBOX_CONFIG_FIXUPS
	$(call KCONFIG_ENABLE_OPT,CONFIG_NTPD)
	$(call KCONFIG_ENABLE_OPT,CONFIG_FEATURE_WGET_HTTPS)
	$(call KCONFIG_ENABLE_OPT,CONFIG_FEATURE_PREFER_APPLETS)
	$(call KCONFIG_ENABLE_OPT,CONFIG_FEATURE_SH_STANDALONE)
	$(call KCONFIG_ENABLE_OPT,CONFIG_FEATURE_SH_NOFORK)
	$(if $(BR2_PACKAGE_HDPARM),$(call KCONFIG_DISABLE_OPT,CONFIG_HDPARM))
	$(if $(BR2_PACKAGE_E2FSPROGS),$(call KCONFIG_DISABLE_OPT,CONFIG_MKE2FS))
	$(if $(BR2_PACKAGE_E2FSPROGS),$(call KCONFIG_DISABLE_OPT,CONFIG_CHATTR))
	$(if $(BR2_PACKAGE_E2FSPROGS),$(call KCONFIG_DISABLE_OPT,CONFIG_LSATTR))
	$(if $(BR2_PACKAGE_E2FSPROGS_FSCK),$(call KCONFIG_DISABLE_OPT,CONFIG_FSCK))
endef
# Avec ce shell, un applet passe avant le programme du même nom dans le PATH :
# les applets doublés par un vrai programme de l'image (hdparm, e2fsprogs) sont
# retirés, pour que les scripts gardent le vrai programme.

# S50lighttpd et lighttpd.conf remplacent ceux de Buildroot : recopiés dans
# DIET_FINALIZE, car avec les répertoires par paquet l'assemblage final de
# target/ peut repasser les fichiers de lighttpd après les nôtres.
define DIET_INSTALL_TARGET_CMDS
	for d in etc sbin usr www; do \
		cp -dR --no-preserve=ownership $(@D)/$$d $(TARGET_DIR)/ || exit 1; \
	done
	echo "$(DIET_VERSION)" > $(TARGET_DIR)/etc/diet-version
	ln -sf diet-hotplug $(TARGET_DIR)/sbin/hotplug
	mkdir -p -m 0700 $(TARGET_DIR)/etc/lighttpd/ssl
	mkdir -p $(TARGET_DIR)/c
endef

# mbedTLS installe une quarantaine de programmes d'exemple : garder seulement
# ceux du certificat HTTPS (S50lighttpd). Configuration annotée de lighttpd inutile.
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
