# ReadyNasNextGen: Buildroot system + Linux 6.18 kernel for the ReadyNAS Duo v1.
#   make                 initialises the buildroot/ submodule (tag 2026.08.1),
#                        applies patches/buildroot/, loads the defconfig,
#                        builds everything in output/ (~1 h the first time)
#   make prepare         preparation only (patched Buildroot + .config)
#   make menuconfig      Buildroot configuration (also: linux-menuconfig,
#                        busybox-menuconfig, savedefconfig...)
#   make linux-rebuild   rebuilds the kernel (then "make" for the images)
#   make ccache-stats    compiler cache statistics
#   make rapide          same system with the prebuilt toolchain (output-rapide/)
#                        [TOOLCHAIN_ARCHIVE=/path/sdk.tar.xz for a local archive]
#   make toolchain-sdk   rebuilds the prebuilt toolchain (SDK + legal-info, release/)
#   make clean           removes output*/
#   make buildroot-reset resets buildroot/ to the tag (drops our patches)
#   make distclean       clean + buildroot-reset + removal of dl/
#   make JOBS=4          limits parallelism (default: number of CPUs)
# Any other target goes to Buildroot: make <package>-rebuild, etc.
# The compiler cache (BR2_CCACHE_DIR, default ~/.buildroot-ccache) is
# outside the repository and survives "make clean".

JOBS       ?= $(shell nproc)
BR_VERSION := 2026.08.1
TOP        := $(CURDIR)
BR_DIR     := $(TOP)/buildroot
O          := $(TOP)/output
EXTERNAL   := $(TOP)
DEFCONFIG  := readynas_ng_defconfig
BR_PATCHES := $(sort $(wildcard $(TOP)/patches/buildroot/*.patch))

BR_MAKE = $(MAKE) -C $(BR_DIR) O=$(O) BR2_EXTERNAL=$(EXTERNAL)

.PHONY: all prepare clean distclean buildroot-patch buildroot-reset
# BR2_PER_PACKAGE_DIRECTORIES=y: packages build in parallel
all: $(O)/.config | buildroot-patch
	$(BR_MAKE) -j$(JOBS)
	@echo "Images: $(O)/images/ (vmlinux.k3 for TFTP, rootfs.tar)"

prepare: $(O)/.config

# buildroot/ submodule (official repository, tag 2026.08.1, kept clean in git)
# + patches/buildroot/*.patch applied in the work tree, never twice.
buildroot-patch:
	@test -f $(BR_DIR)/Makefile || git -C $(TOP) submodule update --init buildroot
	@set -e; for p in $(BR_PATCHES); do \
		if git -C $(BR_DIR) apply --reverse --check $$p 2>/dev/null; then :; \
		else echo "buildroot patch: $$(basename $$p)"; git -C $(BR_DIR) apply $$p; fi; \
	done

buildroot-reset:
	git -C $(TOP) submodule update --init --force buildroot

$(O)/.config: $(EXTERNAL)/configs/$(DEFCONFIG) | buildroot-patch
	$(BR_MAKE) $(DEFCONFIG)

# "rapide" (fast) build: same system with the prebuilt toolchain
# (readynas_ng_rapide_defconfig), in output-rapide/. The toolchain is downloaded
# from the toolchain-v7-2026.08.1-r2 release, or taken from TOOLCHAIN_ARCHIVE=...
# (local archive from "make toolchain-sdk").
.PHONY: rapide toolchain-sdk
TC_URL := $(shell sed -n 's/^BR2_TOOLCHAIN_EXTERNAL_URL="\(.*\)"/\1/p' \
		$(EXTERNAL)/configs/readynas_ng_rapide_defconfig)
TOOLCHAIN_ARCHIVE ?=
rapide: | buildroot-patch
	@if [ -n "$(TOOLCHAIN_ARCHIVE)" ]; then \
		test -f "$(TOOLCHAIN_ARCHIVE)" || { echo "TOOLCHAIN_ARCHIVE not found: $(TOOLCHAIN_ARCHIVE)"; exit 1; }; \
	elif ! curl -sfIL -o /dev/null "$(TC_URL)"; then \
		echo "The prebuilt toolchain is not available:"; \
		echo "  $(TC_URL)"; \
		echo "Build everything with make (toolchain included, ~1 h), or give a local"; \
		echo "archive: make rapide TOOLCHAIN_ARCHIVE=/path/$(notdir $(TC_URL))"; \
		exit 1; \
	fi
	$(MAKE) O=$(TOP)/output-rapide DEFCONFIG=readynas_ng_rapide_defconfig prepare
	$(if $(TOOLCHAIN_ARCHIVE),sed -i 's|^BR2_TOOLCHAIN_EXTERNAL_URL=.*|BR2_TOOLCHAIN_EXTERNAL_URL="file://$(abspath $(TOOLCHAIN_ARCHIVE))"|' \
		$(TOP)/output-rapide/.config)
	$(MAKE) O=$(TOP)/output-rapide DEFCONFIG=readynas_ng_rapide_defconfig all

# Rebuild the prebuilt toolchain, in release/: relocatable SDK
# (.tar.xz), toolchain sources and licences (legal-info), SHA256SUMS
SDK_NAME := sparc-v7-readynas-linux-uclibc_sdk-buildroot-$(BR_VERSION)
TC_O     := $(TOP)/output-toolchain
toolchain-sdk: | buildroot-patch
	$(MAKE) O=$(TC_O) DEFCONFIG=readynas_ng_toolchain_defconfig prepare
	$(MAKE) -C $(BR_DIR) O=$(TC_O) BR2_EXTERNAL=$(EXTERNAL) \
		-j$(JOBS) sdk BR2_SDK_PREFIX=$(SDK_NAME)
	# check: limits.h of gcc-final (chained to the libc one)
	printf '#include <limits.h>\nint a = NAME_MAX; long b = LONG_BIT;\n' | \
		$(TC_O)/host/bin/sparc-buildroot-linux-uclibc-gcc -D_GNU_SOURCE -x c -c -o /dev/null -
	$(MAKE) -C $(BR_DIR) O=$(TC_O) BR2_EXTERNAL=$(EXTERNAL) legal-info
	mkdir -p $(TOP)/release $(TC_O)/legal-info/buildroot-patches
	cp $(BR_PATCHES) $(TC_O)/legal-info/buildroot-patches/
	gzip -dc $(TC_O)/images/$(SDK_NAME).tar.gz | xz -T0 -9 > $(TOP)/release/$(SDK_NAME).tar.xz
	tar -C $(TC_O) --transform 's|^legal-info|$(SDK_NAME)_legal-info|' \
		-cf $(TOP)/release/$(SDK_NAME)_legal-info.tar legal-info
	cd $(TOP)/release && sha256sum $(SDK_NAME).tar.xz $(SDK_NAME)_legal-info.tar > SHA256SUMS

clean:
	rm -rf $(O) $(TOP)/output-rapide $(TOP)/output-toolchain

distclean: clean buildroot-reset
	rm -rf $(TOP)/dl

# everything else (menuconfig, linux-rebuild, ccache-stats, <package>-dirclean...)
# goes to Buildroot
Makefile: ;
%: $(O)/.config | buildroot-patch
	$(BR_MAKE) $@
