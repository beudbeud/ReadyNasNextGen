# Recent Linux kernel on the ReadyNAS Duo v1 (Infrant IT3107 "Padre"): feasibility

Study based on the GPL sources published by NETGEAR for the ReadyNAS 2.6.17 kernel
(`arch/padre`, `include/asm-padre`) and on the 6.18.63 kernel.

## Short answer

* **Feasible**: the Padre is close enough to Linux sparc32 (register windows, traps,
  identical system calls) to be a *platform* of `arch/sparc` rather than a new
  architecture. What differs (MMU, caches, interrupts, no PROM) fits in about
  fifteen files.
* **Version: 6.18 LTS (6.18.63)**. sparc32 is maintained there (LEON); ksmbd is in-tree.
* The port boots on the NAS up to user space (see the status in README.md).

## 1. What the 2.6.17 GPL code says

| Point | Padre (NETGEAR 2.6.17) | mainline sparc32 | Consequence for the port |
|---|---|---|---|
| Instruction set | SPARC v8 without `casa`, **wrong `sdiv`**, **no FPU** | gcc `-mcpu=v8` | C compiled with **`-mcpu=v7`**; `.mul .umul .div .udiv .rem .urem` provided by `lib/padre_muldiv.S` (umul/smul/udiv are correct). FPU emulated by the kernel (fp_disabled trap). |
| Atomics | `ldstub`, `swap` | sparc32: hashed spinlocks (`ldstub`) | nothing to do. |
| MMU | **Infrant-specific** (ASI 0x10): 1024 × 4 MB directory + 1024-entry tables, 4 KB pages, hardware walk, no contexts, TLB probe (ASI 0x11) | 3-level SRMMU | `mm/padre_mm.c` instead of `srmmu.c`, 2-level tables (`pgtable-nopmd`). |
| Address map | user 0–1 GB; 0x4000_0000+ fixed I/O window; 0x8000_0000+ fixed DDR window (bus address 0x4000_0000) | `PAGE_OFFSET` 0xf000_0000 | `PAGE_OFFSET` 0x8000_0000, `TASK_SIZE` 1 GB, `phys_base` 0x4000_0000. |
| Caches | write-back D-cache **not coherent** with DMA; operations through probes (ASI 0x15); I-cache flushed by the MBIST engine; the last 16 MB of DDR **uncached** (CACHEABLE threshold) | coherent | page tables and coherent DMA in the uncached area, `arch_sync_dma_*` for streaming DMA. |
| Interrupts | Infrant INTC (APB 0x6000_0000), 48 sources over two words | IRQMP / sun4m | `kernel/padre_kernel.c` (`irq_chip`). |
| Timer | timer 1, 50,000 ticks/s, IRQ 46 | GPTIMER / sun4m | same file (periodic clockevent + clocksource). |
| UART | LEON2-style registers, console ttyS1 | APBUART | `drivers/tty/serial/padre_uart.c`. |
| Loader | iboot: `go 0x80004000`, **no PROM**, no command line | OpenBoot PROM | emulated PROM (`kernel/padre_prom.c`), `CONFIG_CMDLINE`, built-in initramfs. |
| "LP" coprocessor | firmware loaded by `head.S` (arrays from `lpram.c`) | — | loaded the same way (`kernel/padre_lpram.c`, arrays taken from the NETGEAR GPL sources); used for disk DMA. |
| PCI (VIA USB) | Padre bridge, `PCI_SWAP`, `PCI_FEATURE` | — | `kernel/padre_pci.c` + EHCI. |

## 2. Known limits

* **`.ko` modules**: kbuild cannot export a symbol whose name starts with a dot
  (`.div`…): the Padre drivers are **built in** (`=y`).
* No SMP and no HIGHMEM (256 MB fit in the fixed window).
* User space: uClibc-ng, NPTL on `ldstub`, WCHAR, shared libraries; glibc
  excluded (v9/`casa`). Hardware floating point in programs is emulated by the kernel: correct but slow.

## 3. Why not the other paths

* **Bringing the 2.6.17 `arch/padre` up to date**: twelve years of API changes to catch up on a
  whole architecture, much longer than plugging a platform into `arch/sparc`.
* **Older version (5.15/6.1)**: no gain for this port.
