# ReadyNasNextGen : système Buildroot + noyau Linux 6.18 pour ReadyNAS Duo v1.
#   make                 initialise le sous-module buildroot/ (tag 2026.08.1),
#                        applique patches/buildroot/, charge le defconfig,
#                        construit tout dans output/ (~1 h la première fois)
#   make prepare         seulement la préparation (Buildroot patché + .config)
#   make menuconfig      configuration Buildroot (aussi : linux-menuconfig,
#                        busybox-menuconfig, savedefconfig…)
#   make linux-rebuild   reconstruit le noyau (puis « make » pour les images)
#   make ccache-stats    statistiques du cache de compilation
#   make rapide          même système avec la chaîne précompilée (output-rapide/)
#                        [TOOLCHAIN_ARCHIVE=/chemin/sdk.tar.xz pour une archive locale]
#   make toolchain-sdk   reconstruit la chaîne précompilée (SDK + legal-info, release/)
#   make clean           supprime output*/
#   make buildroot-reset remet buildroot/ à l'état du tag (retire nos patchs)
#   make distclean       clean + buildroot-reset + suppression de dl/
#   make JOBS=4          limite le parallélisme (défaut : nombre de processeurs)
# Toute autre cible est passée à Buildroot : make <paquet>-rebuild, etc.
# Le cache de compilation (BR2_CCACHE_DIR, défaut ~/.buildroot-ccache) est
# hors du dépôt et survit à « make clean ».

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
# BR2_PER_PACKAGE_DIRECTORIES=y : les paquets se construisent en parallèle
all: $(O)/.config | buildroot-patch
	$(BR_MAKE) -j$(JOBS)
	@echo "Images : $(O)/images/ (vmlinux.k3 pour TFTP, rootfs.tar)"

prepare: $(O)/.config

# Sous-module buildroot/ (dépôt officiel, tag 2026.08.1, gardé propre dans git)
# + patches/buildroot/*.patch appliqués dans l'arbre de travail, sans doublon.
buildroot-patch:
	@test -f $(BR_DIR)/Makefile || git -C $(TOP) submodule update --init buildroot
	@set -e; for p in $(BR_PATCHES); do \
		if git -C $(BR_DIR) apply --reverse --check $$p 2>/dev/null; then :; \
		else echo "patch buildroot : $$(basename $$p)"; git -C $(BR_DIR) apply $$p; fi; \
	done

buildroot-reset:
	git -C $(TOP) submodule update --init --force buildroot

$(O)/.config: $(EXTERNAL)/configs/$(DEFCONFIG) | buildroot-patch
	$(BR_MAKE) $(DEFCONFIG)

# Construction « rapide » : même système avec la chaîne précompilée
# (readynas_ng_rapide_defconfig), dans output-rapide/. La chaîne est téléchargée
# depuis la release toolchain-v7-2026.08.1-r2, ou prise dans TOOLCHAIN_ARCHIVE=…
# (archive locale de « make toolchain-sdk »).
.PHONY: rapide toolchain-sdk
TC_URL := $(shell sed -n 's/^BR2_TOOLCHAIN_EXTERNAL_URL="\(.*\)"/\1/p' \
		$(EXTERNAL)/configs/readynas_ng_rapide_defconfig)
TOOLCHAIN_ARCHIVE ?=
rapide: | buildroot-patch
	@if [ -n "$(TOOLCHAIN_ARCHIVE)" ]; then \
		test -f "$(TOOLCHAIN_ARCHIVE)" || { echo "TOOLCHAIN_ARCHIVE introuvable : $(TOOLCHAIN_ARCHIVE)"; exit 1; }; \
	elif ! curl -sfIL -o /dev/null "$(TC_URL)"; then \
		echo "La chaîne précompilée n'est pas disponible :"; \
		echo "  $(TC_URL)"; \
		echo "Construisez tout avec « make » (chaîne comprise, ~1 h), ou donnez une archive"; \
		echo "locale : make rapide TOOLCHAIN_ARCHIVE=/chemin/$(notdir $(TC_URL))"; \
		exit 1; \
	fi
	$(MAKE) O=$(TOP)/output-rapide DEFCONFIG=readynas_ng_rapide_defconfig prepare
	$(if $(TOOLCHAIN_ARCHIVE),sed -i 's|^BR2_TOOLCHAIN_EXTERNAL_URL=.*|BR2_TOOLCHAIN_EXTERNAL_URL="file://$(abspath $(TOOLCHAIN_ARCHIVE))"|' \
		$(TOP)/output-rapide/.config)
	$(MAKE) O=$(TOP)/output-rapide DEFCONFIG=readynas_ng_rapide_defconfig all

# Reconstruire la chaîne précompilée, dans release/ : SDK relocalisable
# (.tar.xz), sources et licences de la chaîne (legal-info), SHA256SUMS
SDK_NAME := sparc-v7-readynas-linux-uclibc_sdk-buildroot-$(BR_VERSION)
TC_O     := $(TOP)/output-toolchain
toolchain-sdk: | buildroot-patch
	$(MAKE) O=$(TC_O) DEFCONFIG=readynas_ng_toolchain_defconfig prepare
	$(MAKE) -C $(BR_DIR) O=$(TC_O) BR2_EXTERNAL=$(EXTERNAL) \
		-j$(JOBS) sdk BR2_SDK_PREFIX=$(SDK_NAME)
	# contrôle : limits.h de gcc-final (chaînage vers celui de la libc)
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

# tout le reste (menuconfig, linux-rebuild, ccache-stats, <paquet>-dirclean…)
# va à Buildroot
Makefile: ;
%: $(O)/.config | buildroot-patch
	$(BR_MAKE) $@
