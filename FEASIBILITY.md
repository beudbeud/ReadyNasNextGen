# Noyau Linux récent sur le ReadyNAS Duo v1 (Infrant IT3107 « Padre ») : faisabilité

Étude faite à partir des sources GPL publiées par NETGEAR pour le noyau 2.6.17 du ReadyNAS
(`arch/padre`, `include/asm-padre`) et du noyau 6.18.63.

## Réponse courte

* **Faisable** : le Padre est assez proche du sparc32 de Linux (fenêtres de registres, pièges,
  appels système identiques) pour être une *plateforme* de `arch/sparc` plutôt qu'une nouvelle
  architecture. Ce qui change (MMU, antémémoires, interruptions, absence de PROM) tient dans une
  quinzaine de fichiers.
* **Version : 6.18 LTS (6.18.63)**. Le sparc32 y est maintenu (LEON) ; ksmbd est en arbre.
* Le portage démarre sur le NAS jusqu'à l'espace utilisateur (voir l'état dans README.md).

## 1. Ce que dit le code GPL du 2.6.17

| Point | Padre (2.6.17 NETGEAR) | sparc32 mainline | Conséquence pour le portage |
|---|---|---|---|
| Jeu d'instructions | SPARC v8 sans `casa`, **`sdiv` faux**, **pas de FPU** | gcc `-mcpu=v8` | C compilé en **`-mcpu=v7`** ; `.mul .umul .div .udiv .rem .urem` fournis par `lib/padre_muldiv.S` (umul/smul/udiv sont justes). FPU émulée par le noyau (piège fp_disabled). |
| Atomiques | `ldstub`, `swap` | sparc32 : spinlocks hachés (`ldstub`) | rien à faire. |
| MMU | **propre à Infrant** (ASI 0x10) : répertoire 1024 × 4 Mo + tables de 1024 entrées, pages de 4 Ko, parcours matériel, pas de contextes, sonde TLB (ASI 0x11) | SRMMU 3 niveaux | `mm/padre_mm.c` à la place de `srmmu.c`, tables à 2 niveaux (`pgtable-nopmd`). |
| Plan d'adresses | utilisateur 0–1 Go ; 0x4000_0000+ fenêtre fixe des E/S ; 0x8000_0000+ fenêtre fixe de la DDR (adresse de bus 0x4000_0000) | `PAGE_OFFSET` 0xf000_0000 | `PAGE_OFFSET` 0x8000_0000, `TASK_SIZE` 1 Go, `phys_base` 0x4000_0000. |
| Antémémoires | D en écriture différée **non cohérente** avec le DMA ; opérations par sondes (ASI 0x15) ; I vidée par le moteur MBIST ; les 16 derniers Mo de DDR **non cachés** (seuil CACHEABLE) | cohérentes | tables de pages et DMA cohérent dans la zone non cachée, `arch_sync_dma_*` pour le DMA en flux. |
| Interruptions | INTC Infrant (APB 0x6000_0000), 48 sources sur deux mots | IRQMP / sun4m | `kernel/padre_kernel.c` (`irq_chip`). |
| Minuterie | minuterie 1, 50 000 tops/s, IRQ 46 | GPTIMER / sun4m | même fichier (clockevent périodique + clocksource). |
| UART | registres type LEON2, console ttyS1 | APBUART | `drivers/tty/serial/padre_uart.c`. |
| Chargeur | iboot : `go 0x80004000`, **pas de PROM**, pas de ligne de commande | PROM OpenBoot | PROM émulée (`kernel/padre_prom.c`), `CONFIG_CMDLINE`, initramfs intégré. |
| Coprocesseur « LP » | micrologiciel chargé par `head.S` (tableaux de `lpram.c`) | — | chargé de la même façon (`kernel/padre_lpram.c`, tableaux repris des sources GPL de NETGEAR) ; sert au DMA disque. |
| PCI (USB VIA) | pont Padre, `PCI_SWAP`, `PCI_FEATURE` | — | `kernel/padre_pci.c` + EHCI. |

## 2. Limites connues

* **Modules `.ko`** : kbuild ne sait pas exporter un symbole dont le nom commence par un point
  (`.div`…) : les pilotes Padre sont compilés **en dur** (`=y`).
* Pas de SMP ni de HIGHMEM (256 Mo tiennent dans la fenêtre fixe).
* Espace utilisateur : uClibc-ng, NPTL sur `ldstub`, WCHAR, bibliothèques partagées ; glibc
  exclue (v9/`casa`). Le flottant matériel des programmes est émulé par le noyau : correct mais lent.

## 3. Pourquoi pas les autres voies

* **Monter `arch/padre` du 2.6.17 de version** : douze ans d'API à rattraper sur une architecture
  entière, bien plus long que de brancher une plateforme dans `arch/sparc`.
* **Version plus ancienne (5.15/6.1)** : aucun gain pour ce portage.
