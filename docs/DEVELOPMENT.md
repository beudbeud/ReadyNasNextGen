# Development

Technical notes to build, debug and extend ReadyNasNextGen. For using the NAS, see the
[README](../README.md).

The kernel is a port of Linux sparc32 to the Padre platform, written from the GPL sources of
the 2.6.17 kernel published by NETGEAR (see [FEASIBILITY.md](../FEASIBILITY.md)).

Hardware: **Infrant IT3107 "Padre"** SoC, a SPARC v8 without FPU whose signed division
(`sdiv`) is wrong, an Infrant-specific MMU, 256 MB of DDR, USB through a VIA VT6212 (EHCI) on PCI,
two SATA disks.

## Detailed status

| Item | Status |
|---|---|
| Boot through iboot + TFTP, serial console ttyS1 (9600 baud) | works |
| MMU, caches, interrupts, timer, task sleep/wakeup | works |
| FPU emulation (the Padre has none): hardware floating-point programs, `printf("%f")`, awk | works (fmovs/fnegs/fabss fixed in `math-emu/math_32.c`: the Padre emulates everything, including these copies) |
| Built-in initramfs, `/init`, busybox, fork/exec, page faults | works |
| SATA disks (libata, PIO; optional DMA through the LP coprocessor) | detected |
| Ethernet, LEDs, button, fan/temperature (`drivers/platform/padre`) | ported, to be validated |
| USB EHCI (VIA VT6212) | works: AHB arbitration from 2.6.17 restored; the VT6212 never re-reads the horizontal link of the head QH once the CPU has rewritten it, so a permanent dummy QH follows the head and the real QHs are chained after it |
| Boot from the USB stick (`/rootfs-6.18`), `quiet` console | works: root reached about 3 s after the kernel starts |
| Dynamic programs (ld-uClibc) | works: ld.so runs `flush` after rewriting the PLT (uClibc patch), the kernel handles this `flush` (D-cache write-back, I-cache invalidation) |
| Unaligned integer accesses in user space | emulated by the kernel (`user_unaligned_trap`, `unaligned_32.c`), like 2.6.17 and sparc64; the original sparc32 sent SIGBUS. The first 10 are logged in `dmesg` (`padre: emulated unaligned access, …`) |
| Hardware clock (Dallas DS1337, I2C 0x68) | works: `padre_rtc` (`/dev/rtc0`), time read at boot (`RTC_HCTOSYS`), written back after NTP (`S41time`, `hwclock -w`, and `RTC_SYSTOHC`); the 16 registers are shown in `dmesg` at boot |
| LVM (lvm2 2.03.31) | works: `board/readynas-duo-v1/patches/lvm2/` aligns the `dm_task_get_device_list()` list on 8 bytes (64-bit `dev_t`: SIGBUS from `lvm pvs` on SPARC) |
| ksmbd, NFS v3/v4, mdadm, fuse2fs (X-RAID ext3 with 16 KB blocks) | built, not tested |
| [DIET](DIET.md) web dashboard (lighttpd HTTPS) | ported, tested in simulation |

## Build

Prerequisites (Linux machine): those of Buildroot — `git make gcc g++ patch perl python3 rsync
cpio unzip bc file wget curl xz` — and ~15 GB free. Buildroot is a **git submodule**
(official repository `https://gitlab.com/buildroot.org/buildroot.git`, tag 2026.08.1):

```sh
git clone --recursive https://github.com/beudbeud/ReadyNasNextGen.git
cd ReadyNasNextGen        # (already cloned without --recursive: git submodule update --init)
make            # applies patches/buildroot/, loads the defconfig, builds everything (~1 h the 1st time)
make prepare    # preparation only (patched Buildroot + output/.config)
make menuconfig / make linux-menuconfig / make linux-rebuild / make clean / make distclean
make JOBS=4     # limits parallelism (default: number of processors)
make ccache-stats
make buildroot-reset      # resets buildroot/ to the tag state (removes our patches)
```

The submodule stays clean in git: `patches/buildroot/*.patch` (SPARC v7 variant) is applied to
the working tree at build time, only once (`git apply --reverse --check`); `.gitmodules`
declares `ignore = dirty`.

The build is parallel at the Buildroot level (`BR2_PER_PACKAGE_DIRECTORIES=y`, `make
-j$(JOBS)`) and uses **ccache** (`BR2_CCACHE=y`) with a cache outside the repository,
`~/.buildroot-ccache` by default (`BR2_CCACHE_DIR`): a rebuild after `make clean` is much
faster.

Output in `output/images/`:

* `vmlinux.bin`: raw kernel linked at 0x8000_4000, with the built-in initramfs;
* `vmlinux.k3`: the same, encrypted for iboot (`readynas_crypto -k3`, built during
  `post-image.sh`);
* `rootfs.tar`: the system, to extract into `/rootfs-6.18` on an ext3/ext4 partition of a USB
  stick (the initramfs looks for this directory and switches to it).

`post-image.sh` also checks the load address, the absence of `sdiv`/`sdivcc`/`casa` in the
kernel, the system and the initramfs, that no floating-point instruction is executed by the
kernel FPU emulation path, and that the built-in command line is shorter than 256 characters.

The toolchain applies `board/readynas-duo-v1/patches/uclibc/`: `flush` after each instruction
rewrite by ld-uClibc (PLT). Without it, the Padre instruction cache ran the old PLT (segfaults
in `_dl_linux_resolver`).

### Prebuilt toolchain (fast build)

The prebuilt toolchain is published in the GitHub release
[`toolchain-v7-2026.08.1-r2`](https://github.com/beudbeud/ReadyNasNextGen/releases/tag/toolchain-v7-2026.08.1-r2),
with its sources (legal-info) for GPL/LGPL compliance and the SHA256 sums:

```sh
make rapide               # downloads the toolchain from the release, then builds the system
```

Without it, `make` rebuilds everything, toolchain included (~1 h the first time, much less
afterwards thanks to ccache).

The toolchain (SPARC v7, uClibc-ng 1.0.59 with NPTL and WCHAR, gcc 15.3, binutils 2.45.1, Linux
6.18.63 headers, no C++) can be rebuilt as a relocatable Buildroot SDK:

```sh
make toolchain-sdk        # release/: SDK .tar.xz, legal-info archive (sources + licences), SHA256SUMS
make rapide TOOLCHAIN_ARCHIVE=release/sparc-v7-readynas-linux-uclibc_sdk-buildroot-2026.08.1.tar.xz
```

`make rapide` builds the same system with this toolchain (`readynas_ng_rapide_defconfig`,
output in `output-rapide/`); with `TOOLCHAIN_ARCHIVE`, it uses a local archive instead of the
release. The SDK can also be used on its own: extract it, run
`./relocate-sdk.sh`, then use `bin/sparc-buildroot-linux-uclibc-gcc` (the generated C calls
`.div`/`.udiv` instead of `sdiv`). The legal-info archive contains the sources of gcc, binutils,
uClibc-ng, the Linux headers and the host tools with their patches, plus
`buildroot-patches/` (our v7 patch for Buildroot).

## Kernel parameters (built-in command line, `board/readynas-duo-v1/linux-padre.config`)

| Parameter | Purpose |
|---|---|
| `padre.disable=a,b` | do not start some Padre drivers: `i2c`, `rtc`, `led`, `hwmon`, `gmac`, `sata`, `dma`, `pci` (debugging) |
| `padre_sata.dma=0/1` | disk DMA through the LP coprocessor (0 = PIO, default) |
| `padre.trace_fault=N` | shows the first N user page faults |
| `padre.trace_tick=1` | tick state in `/proc/padre_tick` and `[pulse]`/`[watchdog]` lines on the console (default 0) |
| `padre_mm.flush=1/2/0` | handling of the `flush` instruction: 1 (default) whole D-cache + I; 2 targeted D line only; 0 skipped (diagnostics). Also at runtime: `/sys/module/padre_mm/parameters/flush` |
| `padre.pcibus=<hex>`, `padre.pcifeat=<hex>`, `padre.pciswap=<hex>`, `padre.ahbarb=<n>` | PCI bridge settings (2.6.17 defaults) |
| `tests=1` | `/init` first runs the initramfs tests (`float` t1–t11, `windows`, `load`, sleep) |
| `rootdev=/dev/sdXN`, `rootdir=/other` | `/init`: root partition without searching, directory other than `/rootfs-6.18` |
| `padre_hwmon.setpoint=N`, `padre_sata.read_only=1` | fan setpoint at boot (0–255, default 80); refuse any write to the SATA disks |

Default: `console=ttyS1,9600 quiet panic=10` (full log in `dmesg`).

Console tests (`readynas-tests` package, in `/usr/bin`): `test-flush with` (I-cache after code
rewrite, 0 errors expected; `without` must show some), `test-fp-s`, `test-fp-d`,
`test-fp-n` (FPU emulation in static, dynamic PIE, dynamic non-PIE), `test-align` (emulated
unaligned accesses, `malloc` alignment), `test-ldso 200`
(dynamic programs in a loop, 0 failures and 0 ld-uClibc segfaults expected).

## Dashboard: tests on the PC

```sh
sh package/diet/tests/test-api.sh              # API tests
sh package/diet/tests/test-api.sh --serve      # interface on http://127.0.0.1:8080/
```

## Source tree

```
Makefile                         Buildroot preparation + target passthrough
buildroot/                       submodule: Buildroot 2026.08.1 (official repository)
patches/buildroot/               SPARC v7 variant for Buildroot (BR2_sparc_v7)
external.desc, Config.in, external.mk   Buildroot external tree (BR2_EXTERNAL = repository root)
configs/readynas_ng_defconfig            full system, toolchain built
configs/readynas_ng_rapide_defconfig     same system, prebuilt toolchain (make rapide)
configs/readynas_ng_toolchain_defconfig  toolchain only (make toolchain-sdk)
package/readynas-initramfs/      static busybox without floating point + tests, for the initramfs
package/readynas-tests/          port tests in the rootfs (test-flush, test-fp-*, test-align, test-ldso)
package/diet/                    DIET web dashboard ported to 6.18 (+ tests/test-api.sh)
docs/DIET.md                     what changes compared with DIET
board/readynas-duo-v1/
  linux-padre.config, linux-padre-nas.fragment
  patches/linux/                 Padre platform for Linux 6.18.63 (arch/sparc, drivers)
  patches/e2fsprogs/             fuse2fs with uClibc-ng
  patches/uclibc/                flush after the PLT rewrite by ld-uClibc
  patches/lvm2/                  alignment of the dm device list (libdm)
  initramfs/                     /init, `list` (gen_init_cpio), test sources
  rootfs-overlay/                ksmbd, NFS, fan control
  readynas_crypto/               iboot encryption tool (GPL), compiled by post-image.sh
  post-image.sh
tools/                           iboot-cmd.py (serial console), tftp-server.sh
```
