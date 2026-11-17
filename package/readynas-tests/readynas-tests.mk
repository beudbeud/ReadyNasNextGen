################################################################################
#
# readynas-tests: Padre port tests (I-cache, emulated FPU, unaligned accesses, ld.so)
#
################################################################################

READYNAS_TESTS_VERSION = 1.0
READYNAS_TESTS_SITE = $(BR2_EXTERNAL_READYNAS_NG_PATH)/package/readynas-tests/src
READYNAS_TESTS_SITE_METHOD = local
READYNAS_TESTS_LICENSE = GPL-2.0

define READYNAS_TESTS_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) -static -o $(@D)/test-flush $(@D)/test-flush.c
	$(TARGET_CC) $(TARGET_CFLAGS) -static -o $(@D)/test-fp-s $(@D)/test-fp.c
	$(TARGET_CC) $(TARGET_CFLAGS) -fPIE -pie -o $(@D)/test-fp-d $(@D)/test-fp.c
	$(TARGET_CC) $(TARGET_CFLAGS) -no-pie -o $(@D)/test-fp-n $(@D)/test-fp.c
	$(TARGET_CC) $(TARGET_CFLAGS) -static -o $(@D)/test-align $(@D)/test-align.c
endef

define READYNAS_TESTS_INSTALL_TARGET_CMDS
	for p in test-flush test-fp-s test-fp-d test-fp-n test-align test-ldso; do \
		$(INSTALL) -D -m 0755 $(@D)/$$p $(TARGET_DIR)/usr/bin/$$p || exit 1; \
	done
endef

$(eval $(generic-package))
