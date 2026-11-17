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
| Boot through the original 2.6.17 kernel ([relay](#relay-booting-from-the-original-kernel)) | hand-over validated on one NAS (started from DIET's switch); `relay-init` and the add-ons tested in simulation |
| MMU, caches, interrupts, timer, task sleep/wakeup | works |
| 16 KiB pages (`patches/linux/0003`, like the stock 2.6.17 kernel) | works: boot, services, kernel ext4 mount of the X-RAID `/c` and of the system volume `xr-p1` (ext3, 16 KiB blocks), read-only; see [below](#16-kib-pages) |
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
| ksmbd, NFS v3/v4, mdadm | built, not tested |
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
  stick (the initramfs looks for this directory and switches to it); **ext3** when booting
  through the relay.

`post-image.sh` also checks the load address, the absence of `sdiv`/`sdivcc`/`casa` in the
kernel, the system and the initramfs, that no floating-point instruction is executed by the
kernel FPU emulation path, and that the built-in command line is shorter than 256 characters.

The toolchain applies `board/readynas-duo-v1/patches/uclibc/`: `flush` after each instruction
rewrite by ld-uClibc (PLT). Without it, the Padre instruction cache ran the old PLT (segfaults
in `_dl_linux_resolver`). Second patch (generic SPARC32 bug, needs a toolchain rebuild, release
r3): `__longjmp` reloaded the setjmp caller's register window from `JB_SP` and patched the wrong
slot (`+0x48` instead of the `%fp` slot `+56`); if the caller lowered `%sp` after `setjmp`
(alloca, VLA) the window came back with a stale `%fp`/`%i7`. Busybox hits it in
`run_nofork_applet` whenever a NOFORK applet dies in `sh` (`dirname` without argument:
segfault in `memcpy`, address `0x1724`).

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

## 16 KiB pages

The data volume `/c` and the RAIDiator system volume are ext3 with 16 KiB blocks: the kernel
mounts a block size only up to its page size. Like the stock 2.6.17 kernel
(`CONFIG_PADRE_16K_PAGE`), the Padre kernel has 16 KiB pages (`patches/linux/0003`): a Linux
PTE is 4 consecutive 4 KiB entries of the Infrant MMU (`pte_t` holds the 4 words,
`pte_val()`/`__pte()` work on the first one plus the A/D bits the MMU set in the others), a
table of 256 Linux PTEs is one 4 KiB hardware table, directories and tables are 4 KiB blocks of
the uncached pool (`/proc/cpuinfo`: `pagetables`), the TLB probe of a page covers its 4 entries,
the kernel stack is one page, `AT_PAGESZ` is 16384. So `nas-raid` mounts `/c` with the kernel
ext4 driver; fuse2fs is gone.

Measured (200 MiB of a file of `/c`, cold cache, disks in PIO): kernel ext4 11.8 MiB/s, fuse2fs
3.3 MiB/s; same md5 of a 344 MB file both ways. User space needs every `PT_LOAD` congruent
modulo 16 KiB: the binutils default for SPARC (max-page-size 64 KiB) already gives it, and from
the r3 toolchain on the default is 16 KiB (`patches/binutils/0001`, less padding).
`post-image.sh` refuses any ELF of the rootfs that does not comply.

## Relay: booting from the original kernel

Sources, build and assumptions: [board/readynas-duo-v1/relay/](../board/readynas-duo-v1/relay/README.md).

**How it works.** iboot and the NETGEAR 2.6.17 kernel boot from flash as usual, and linuxrc
(RAIDiator's initrd) starts `/sbin/init` of the system volume as pid 1. The relay add-on puts
its own boot switch there, `relay-init`; the previous init (RAIDiator's, or DIET's boot switch
when DIET is installed) is kept as `/sbin/init.before-relay` and started whenever the relay
does not take over. `relay-init` runs `/relay/relay-switch`, which loads the USB storage
modules (nothing has loaded them yet at that point: `scsi_mod`, `sd_mod`, `ehci-hcd`,
`usb-storage` from `/lib/modules/2.6.17.14ReadyNAS/` of the system volume), looks for an
ext3/ext2 partition holding `rootfs-6.18/sbin/init`, checks `boot/vmlinux.bin` (and its
`.md5`), loads `padre_relay.ko`, stages the image and has the trampoline copy it in test mode.
Then it remounts `/` read-only, writes `rootfs-6.18/.relay_pending` on the stick and makes the
module jump: reboot notifiers and `device_shutdown()`, DMA stopped (GMAC, PCI bus mastering),
interrupts and timers off, caches written back and off, copy of the image to 0x8000_4000, MMU
and PSR as iboot leaves them, `jmp 0x80004000`. The console shows `RCJ` (trampoline) then
`LPK` (6.18 head).

What the boot switch respects (from RAIDiator's linuxrc and rc3): linuxrc checks that
`/sbin/init` exists before starting it and repairs or reinstalls the firmware otherwise, so
the add-ons replace it only by `mv` of a checked file; linuxrc extracts uploaded add-ons into
`/tmp/addons/` before starting init, and rc3 installs them, so `relay-init` lets RAIDiator
boot while one is waiting (once per set of waiting add-ons); linuxrc unmounts `/proc` before
starting init, so `relay-init` mounts it for `relay-switch` and unmounts it again.

The USB stick must be **ext3** (or ext2): the 2.6.17 kernel has no ext4 and the marker is
written there. The 6.18 initramfs mounts it with its ext4 driver, which does not change the
ext3 features. Format it with `mkfs.ext3 -I 128` (128-byte inodes for 2.6.17).

**Fallback.** Whenever something is missing or refused (no stick after 15 s, bad image, md5
mismatch, module refused, copy test failed, cannot remount), `relay-switch` returns and the
previous init starts; each boot is logged in `/relay/relay.log`. After the jump nothing can
return to 2.6.17: if 6.18 does not complete its boot, power off/on. 6.18 removes
`/.relay_pending` (its own root on the stick) in `S99relay-confirm`, its last init script; a
marker still there at the next power-on means the 6.18 boot failed: `relay-switch` removes it
and starts the previous init this time.

**Disabling.**

| Where | File | Effect |
|---|---|---|
| system volume (`/mnt/root` from DIET) | `/relay/disabled` | never relay |
| system volume | `/relay/dry-run` | everything except the jump, then the previous init (tests) |
| system volume | `/.relay_skip_once` | no relay once (removed when seen) |
| system volume | `/.raidiator_once` | no relay (DIET's "RAIDiator once", left for DIET's switch) |
| system volume | `/.new_addons`, `/tmp/addons/*/install.sh` | no relay while an add-on waits for installation |
| stick, i.e. `/` in 6.18 | `/.relay_skip_once` | no relay once |
| stick, i.e. `/` in 6.18 | `/.relay_pending` | written before the jump; still there = last 6.18 boot failed: no relay once |

Or remove the stick, or install the `ReadyNasNextGen_relay_remove_<version>.bin` add-on (the
previous `/sbin/init` is moved back). The relay add-on also migrates the hand-made install of
the first tests (two lines in DIET's switch). Installing or updating DIET after the relay puts
DIET's switch in front of `relay-init`: install the relay add-on again afterwards.

**Build.** `make relay` builds `output-relay/padre_relay.ko` with NETGEAR's gcc 3.3.5 in
their SPARC compile environment (QEMU in Docker), from their GPL 2.6.17 tree, both
downloaded once into `dl/relay/`. `make relay-addon` builds the two RAIDiator add-ons from it
and runs `test-addon.sh` (install, reinstall, remove in a simulated system volume) and
`test-slots.sh` (system slots: relay-switch, the initramfs slot choice, nas-update, on a
simulated stick).

**System updates.** `make update-package` (`board/readynas-duo-v1/mkupdate.sh`,
`IMAGES=` and `VERSION=` optional) makes `readynasng-update-<version>.tar` and its
`.sha256` from `output-rapide/images`, installed from the Settings page into the second
system slot of the stick and tried once (docs/DIET.md, “System update”).

## Kernel parameters (built-in command line, `board/readynas-duo-v1/linux-padre.config`)

| Parameter | Purpose |
|---|---|
| `padre.disable=a,b` | do not start some Padre drivers: `i2c`, `rtc`, `led`, `hwmon`, `gmac`, `sata`, `dma`, `pci` (debugging) |
| `padre_sata.dma=0/1` | disk DMA through the LP coprocessor (0 = PIO, default). Booted with 1: switchable at run time in `/sys/module/padre_sata/parameters/dma` (0 = DMA commands run in PIO); `dma_cmds` counts LP commands |
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

## SSH (dropbear)

`board/readynas-duo-v1/rootfs-overlay/etc/default/dropbear` sets
`DROPBEAR_ARGS="-K 30 -I 1800"`, read by Buildroot's `S50dropbear`:

- `-K 30`: once logged in, dropbear sends a keepalive every 30 s; when the client has not
  answered for 3 intervals (90 s, `DEFAULT_KEEPALIVE_LIMIT`), the session exits
  ("Keepalive timeout"). A client that vanished (laptop asleep, network cut) no longer leaves
  a dropbear process behind.
- `-I 1800`: a session with no data in either direction for 30 min is closed ("Idle
  timeout"). Keepalives do not count; command output does. A *silent* command running over
  30 min in the foreground (`mkfs`, a wait loop) is cut off with it: run it with
  `nohup … &` or `setsid`.

Closing the session does not stop what it started: without a pty (`ssh nas 'command'`), the
command gets no SIGHUP and keeps running (checked on the PC with dropbear 2026.94: `sleep`
survives a keepalive timeout); it only dies on SIGPIPE if it writes to its closed output.
For a long command that must stop with the session, use `ssh -t` (the pty hangup sends
SIGHUP), or `timeout <s> command`.

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
  patches/uclibc/                flush after the PLT rewrite by ld-uClibc; SPARC longjmp fix
  patches/binutils/              16 KiB default ELF page size (toolchain from r3)
  patches/lvm2/                  alignment of the dm device list (libdm)
  initramfs/                     /init, `list` (gen_init_cpio), test sources
  rootfs-overlay/                ksmbd, NFS, fan control
  readynas_crypto/               iboot encryption tool (GPL), compiled by post-image.sh
  relay/                         padre_relay.ko (2.6.17 module), relay-init, relay-switch, add-ons, build in QEMU
  post-image.sh
tools/                           iboot-cmd.py (serial console), tftp-server.sh
```
