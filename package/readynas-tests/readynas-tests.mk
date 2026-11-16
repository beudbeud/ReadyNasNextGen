################################################################################
#
# readynas-tests : essais du portage Padre (antémémoire I, FPU émulée, ld.so)
#
################################################################################

READYNAS_TESTS_VERSION = 1.0
READYNAS_TESTS_SITE = $(BR2_EXTERNAL_READYNAS_NG_PATH)/package/readynas-tests/src
READYNAS_TESTS_SITE_METHOD = local
READYNAS_TESTS_LICENSE = GPL-2.0

define READYNAS_TESTS_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) -static -o $(@D)/essai-flush $(@D)/essai-flush.c
	$(TARGET_CC) $(TARGET_CFLAGS) -static -o $(@D)/essai-fp-s $(@D)/essai-fp.c
	$(TARGET_CC) $(TARGET_CFLAGS) -fPIE -pie -o $(@D)/essai-fp-d $(@D)/essai-fp.c
	$(TARGET_CC) $(TARGET_CFLAGS) -no-pie -o $(@D)/essai-fp-n $(@D)/essai-fp.c
endef

define READYNAS_TESTS_INSTALL_TARGET_CMDS
	for p in essai-flush essai-fp-s essai-fp-d essai-fp-n essai-ldso; do \
		$(INSTALL) -D -m 0755 $(@D)/$$p $(TARGET_DIR)/usr/bin/$$p || exit 1; \
	done
endef

$(eval $(generic-package))
