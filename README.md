# ReadyNasNextGen

Linux 6.18 et un système Buildroot récent (ksmbd, NFS du noyau, mdadm) pour le
**NETGEAR ReadyNAS Duo v1** : SoC **Infrant IT3107 « Padre »**, SPARC v8 sans FPU dont la
division signée (`sdiv`) est fausse, MMU propre à Infrant, 256 Mo de DDR, USB par un VIA
VT6212 (EHCI) en PCI, deux disques SATA.

Le noyau est un portage du sparc32 de Linux vers la plateforme Padre, écrit d'après les sources
GPL du noyau 2.6.17 publiées par NETGEAR (voir [FAISABILITE.md](FAISABILITE.md)).

## État (projet expérimental)

| Élément | État |
|---|---|
| Démarrage par iboot + TFTP, console série ttyS1 (9600 bauds) | marche |
| MMU, antémémoires, interruptions, minuterie, sommeil/réveil des tâches | marche |
| Émulation FPU (le Padre n'en a pas) : programmes en flottant matériel, `printf("%f")`, awk | marche (fmovs/fnegs/fabss corrigés dans `math-emu/math_32.c` : le Padre émule tout, y compris ces copies) |
| initramfs intégré, `/init`, busybox, fork/exec, fautes de page | marche |
| Disques SATA (libata, PIO ; DMA par le coprocesseur LP en option) | détectés |
| Ethernet, voyants, bouton, ventilateur/température (`drivers/platform/padre`) | portés, à valider |
| USB EHCI (VIA VT6212) | marche : arbitrage AHB du 2.6.17 rétabli ; le VT6212 ne relit jamais le lien horizontal du QH de tête une fois réécrit par le CPU, un QH factice permanent suit donc la tête et les vrais QH sont chaînés après lui |
| Démarrage sur la clé USB (`/rootfs-6.18`), console `quiet` | marche : racine atteinte vers 3 s après le lancement du noyau |
| Programmes dynamiques (ld-uClibc) | marche : ld.so exécute `flush` après avoir réécrit la PLT (patch uClibc), le noyau traite ce `flush` (écriture de l'antémémoire D, invalidation de la I) |
| ksmbd, NFS v3/v4, mdadm, fuse2fs (ext3 X-RAID à blocs de 16 Ko) | construits, non testés |
| Tableau de bord web [DIET](#tableau-de-bord-web-diet) (lighttpd HTTPS) | porté, testé en simulation |

## Construire

Prérequis (machine Linux) : ceux de Buildroot — `git make gcc g++ patch perl python3 rsync
cpio unzip bc file wget curl xz` — et ~15 Go libres. Buildroot est un **sous-module git**
(dépôt officiel `https://gitlab.com/buildroot.org/buildroot.git`, tag 2026.08.1) :

```sh
git clone --recursive https://github.com/beudbeud/ReadyNasNextGen.git
cd ReadyNasNextGen        # (déjà cloné sans --recursive : git submodule update --init)
make            # applique patches/buildroot/, charge le defconfig, construit tout (~1 h la 1re fois)
make prepare    # seulement la préparation (Buildroot patché + output/.config)
make menuconfig / make linux-menuconfig / make linux-rebuild / make clean / make distclean
make JOBS=4     # limite le parallélisme (défaut : nombre de processeurs)
make ccache-stats
make buildroot-reset      # remet buildroot/ à l'état du tag (retire nos patchs)
```

Le sous-module reste propre dans git : `patches/buildroot/*.patch` (variante SPARC v7) est
appliqué dans l'arbre de travail au moment du build, une seule fois (`git apply --reverse
--check`) ; `.gitmodules` déclare `ignore = dirty`.

La construction est parallèle au niveau Buildroot (`BR2_PER_PACKAGE_DIRECTORIES=y`, `make
-j$(JOBS)`) et utilise **ccache** (`BR2_CCACHE=y`) avec un cache hors du dépôt,
`~/.buildroot-ccache` par défaut (`BR2_CCACHE_DIR`) : une reconstruction après `make clean` est
nettement plus rapide.

Résultat dans `output/images/` :

* `vmlinux.bin` : noyau brut lié à 0x8000_4000, avec l'initramfs intégré ;
* `vmlinux.k3` : le même, chiffré pour iboot (`readynas_crypto -k3`, construit pendant
  `post-image.sh`) ;
* `rootfs.tar` : le système, à extraire dans `/rootfs-6.18` d'une partition ext3/ext4 d'une clé USB
  (l'initramfs cherche ce dossier et y bascule).

`post-image.sh` vérifie aussi l'adresse de chargement, l'absence de `sdiv`/`sdivcc`/`casa` dans le
noyau, le système et l'initramfs, et qu'aucune instruction flottante n'est exécutée par le chemin
d'émulation FPU du noyau, et que la ligne de commande intégrée fait moins de 256 caractères.

La chaîne applique `board/readynas-duo-v1/patches/uclibc/` : `flush` après chaque réécriture
d'instructions par ld-uClibc (PLT), sans quoi l'antémémoire d'instructions du Padre exécutait
l'ancienne PLT (segfaults dans `_dl_linux_resolver`).

### Chaîne précompilée (construction rapide)

La chaîne précompilée est publiée dans la release GitHub
[`toolchain-v7-2026.08.1`](https://github.com/beudbeud/ReadyNasNextGen/releases/tag/toolchain-v7-2026.08.1),
avec ses sources (legal-info) pour la conformité GPL/LGPL et les sommes SHA256 :

```sh
make rapide               # télécharge la chaîne depuis la release, puis construit le système
```

Sans elle, `make` reconstruit tout, chaîne comprise (~1 h la première fois, bien moins ensuite
grâce à ccache).

La chaîne (SPARC v7, uClibc-ng 1.0.59 avec NPTL et WCHAR, gcc 15.3, binutils 2.45.1, en-têtes
Linux 6.18.63, sans C++) se reconstruit sous forme de SDK Buildroot relocalisable :

```sh
make toolchain-sdk        # release/ : SDK .tar.xz, archive legal-info (sources + licences), SHA256SUMS
make rapide TOOLCHAIN_ARCHIVE=release/sparc-v7-readynas-linux-uclibc_sdk-buildroot-2026.08.1.tar.xz
```

`make rapide` construit le même système avec cette chaîne (`readynas_ng_rapide_defconfig`,
sortie dans `output-rapide/`) ; avec `TOOLCHAIN_ARCHIVE`, il utilise une archive locale au lieu de
la release. Le SDK sert aussi seul : l'extraire, lancer
`./relocate-sdk.sh`, puis utiliser `bin/sparc-buildroot-linux-uclibc-gcc` (le C produit appelle
`.div`/`.udiv` au lieu de `sdiv`). L'archive legal-info contient les sources de gcc, binutils,
uClibc-ng, des en-têtes Linux et des outils hôtes avec leurs correctifs, plus
`buildroot-patches/` (notre patch v7 de Buildroot).

## Démarrer (sans toucher à la flash)

1. Console série sur le connecteur interne, 9600 bauds ; un serveur TFTP sur le PC
   (`tools/tftp-serveur.sh output/images`, Docker).
2. Interrompre iboot au démarrage, puis à l'invite `iboot>` :
   ```
   tftp <MAC-du-NAS> <IP-du-NAS> <IP-du-PC> vmlinux.k3 0x80004000
   go 0x80004000
   ```
   `tools/iboot-cmd.py` automatise ces étapes et enregistre la console.
3. Un redémarrage normal rend le système d'origine : rien n'est écrit.

**Sécurité** : ne jamais écrire en flash. N'utilisez aucune commande d'écriture NAND d'iboot et
n'écrivez jamais sur `/dev/mtd*` ; une flash corrompue rend le NAS inutilisable sans matériel
de récupération.

## Paramètres du noyau (ligne de commande intégrée, `board/readynas-duo-v1/linux-padre.config`)

| Paramètre | Rôle |
|---|---|
| `padre.desactive=a,b` | ne pas lancer certains pilotes Padre (mise au point) |
| `padre_sata.dma=0/1` | DMA disque par le coprocesseur LP (0 = PIO, défaut) |
| `padre.trace_faute=N` | affiche les N premières fautes de page utilisateur |
| `padre.trace_tick=1` | état du tic dans `/proc/padre_tic` et lignes `[pouls]`/`[chien]` sur la console (défaut 0) |
| `padre_mm.flush=1/2/0` | traitement de l'instruction `flush` : 1 (défaut) antémémoire D entière + I ; 2 ligne D visée seulement ; 0 sautée (diagnostic). Aussi à chaud : `/sys/module/padre_mm/parameters/flush` |
| `padre.pcibus=<hex>`, `padre.pcifeat=<hex>`, `padre.pciswap=<hex>`, `padre.ahbarb=<n>` | réglages du pont PCI (défauts du 2.6.17) |
| `essais=1` | `/init` lance d'abord les essais de l'initramfs (flottant t1–t11, fenêtres, charge, sommeil) |

Défaut : `console=ttyS1,9600 quiet panic=10` (journal complet dans `dmesg`).

Essais à la console (paquet `readynas-tests`, dans `/usr/bin`) : `essai-flush avec` (antémémoire I
après réécriture de code, 0 erreur attendue ; `sans` doit en montrer), `essai-fp-s`, `essai-fp-d`,
`essai-fp-n` (émulation FPU en statique, dynamique PIE, dynamique non PIE), `essai-ldso 200`
(programmes dynamiques en boucle, 0 échec et 0 segfault ld-uClibc attendus).

## Tableau de bord web (DIET)

Le système embarque une adaptation du tableau de bord web de
[DIET](https://github.com/mfe-/ReadyNASDuoSparc), le système léger pour les ReadyNAS SPARC qui
remplace le firmware RAIDiator (écrit par davemmi ; support du Duo v1 :
[mfe-/ReadyNASDuoSparc#16](https://github.com/mfe-/ReadyNASDuoSparc/pull/16)). Ici il est porté sur Linux 6.18 : ksmbd au lieu de Samba 3.6,
md/RAID1 au lieu de X-RAID, export NFS, régulation du ventilateur par `padre-ventilateur`.
Interface en HTTPS (lighttpd, certificat auto-signé créé au premier démarrage), en français,
allemand et anglais. Détails et différences avec DIET : [docs/DIET.md](docs/DIET.md).

Essai sur le PC, sans le NAS, avec des données simulées :

```sh
sh package/diet/tests/essai-api.sh             # tests de l'API
sh package/diet/tests/essai-api.sh --servir    # interface sur http://127.0.0.1:8080/
```

## Arborescence

```
Makefile                         préparation de Buildroot + passage des cibles
buildroot/                       sous-module : Buildroot 2026.08.1 (dépôt officiel)
patches/buildroot/               variante SPARC v7 pour Buildroot (BR2_sparc_v7)
external.desc, Config.in, external.mk   arbre externe Buildroot (BR2_EXTERNAL = racine du dépôt)
configs/readynas_ng_defconfig            système complet, chaîne construite
configs/readynas_ng_rapide_defconfig     même système, chaîne précompilée (make rapide)
configs/readynas_ng_toolchain_defconfig  chaîne seule (make toolchain-sdk)
package/readynas-initramfs/      busybox statique sans flottant + tests, pour l'initramfs
package/readynas-tests/          essais du portage dans le rootfs (essai-flush, essai-fp-*, essai-ldso)
package/diet/                    tableau de bord web DIET porté sur 6.18 (+ tests/essai-api.sh)
docs/DIET.md                     ce qui change par rapport à DIET
board/readynas-duo-v1/
  linux-padre.config, linux-padre-nas.fragment
  patches/linux/                 plateforme Padre pour Linux 6.18.63 (arch/sparc, pilotes)
  patches/e2fsprogs/             fuse2fs avec uClibc-ng
  patches/uclibc/                flush après réécriture de la PLT par ld-uClibc
  initramfs/                     /init, liste gen_init_cpio, sources des tests
  rootfs-overlay/                ksmbd, NFS, régulation du ventilateur
  readynas_crypto/               outil de chiffrement iboot (GPL), compilé par post-image.sh
  post-image.sh
tools/                           iboot-cmd.py (console série), tftp-serveur.sh
```

## Licences

* Patch du noyau, pilotes et scripts : **GPL-2.0** (voir `LICENSE`). Le portage est écrit
  d'après les sources GPL du noyau 2.6.17 de NETGEAR ; les tableaux du micrologiciel du
  coprocesseur LP (`arch/sparc/kernel/padre_lpram.c`) proviennent de ces mêmes sources GPL
  (`lpram.c`).
* `readynas_crypto` : GPL-2.0+ (Henrik Nordström) ; `des.c` : LGPL-2.1 (Christophe Devine).
* `package/diet/src/` : dérivé de [DIET](https://github.com/mfe-/ReadyNASDuoSparc) (davemmi),
  dont le dépôt d'origine ne déclare aucune licence à ce jour ; ce code n'est donc **pas** sous
  la GPL-2.0 de ce dépôt (voir [docs/DIET.md](docs/DIET.md#origine-et-licence)).
* Buildroot, Linux et les paquets construits gardent leurs propres licences.

Aucun binaire ni code propriétaire Infrant/NETGEAR n'est inclus.
