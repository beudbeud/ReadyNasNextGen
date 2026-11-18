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
| Boot through the original 2.6.17 kernel ([relay](#relay-booting-from-the-original-kernel)) | works on one NAS: relay add-on 1.1 installed from Frontview, boots of 6.18, system updates by slots; not tested yet: the fallback after a power cut during a 6.18 boot (simulated by `test-addon.sh`, `test-slots.sh`) |
| MMU, caches, interrupts, timer, task sleep/wakeup | works |
| 16 KiB pages (`patches/linux/0020`, like the stock 2.6.17 kernel) | works: boot, services, kernel ext4 mount of the X-RAID `/c` (read-write through the Storage switch, validated) and of the system volume `xr-p1` (read-only), ext3 with 16 KiB blocks; see [below](#16-kib-pages) |
| FPU emulation (the Padre has none): hardware floating-point programs, `printf("%f")`, awk | works (fmovs/fnegs/fabss fixed in `math-emu/math_32.c`: the Padre emulates everything, including these copies) |
| Built-in initramfs, `/init`, busybox, fork/exec, page faults | works |
| SATA disks (libata, DMA through the LP coprocessor, on by default) | works: raw read 14.9 MB/s in PIO, 35.5 MB/s in DMA |
| Ethernet, LEDs, button, fan/temperature (`drivers/platform/padre`) | ported, to be validated |
| Ethernet NAPI, GRO, receive checksum by the engine (`patches/linux/0022`) | works: 2 GB written over SMB with the engine checked against a software checksum, 0 disagreements; see [Network driver](#network-driver-padre_gmac) |
| Ethernet transmit checksum by the engine, scatter-gather (`patches/linux/0023`) | written, builds, **off by default, never run on the NAS**: see [Transmit checksum](#transmit-checksum-by-the-engine-patcheslinux0023) and its trial plan |
| USB EHCI (VIA VT6212) | works: AHB arbitration from 2.6.17 restored; the VT6212 never re-reads the horizontal link of the head QH once the CPU has rewritten it, so a permanent dummy QH follows the head and the real QHs are chained after it |
| Boot from the USB stick (`/rootfs-6.18`), `quiet` console | works: root reached about 2.3 s after the kernel starts (see [Kernel tuning](#kernel-tuning)) |
| Dynamic programs (ld-uClibc) | works: ld.so runs `flush` after rewriting the PLT (uClibc patch), the kernel handles this `flush` (D-cache write-back, I-cache invalidation) |
| Unaligned integer accesses in user space | emulated by the kernel (`user_unaligned_trap`, `unaligned_32.c`), like 2.6.17 and sparc64; the original sparc32 sent SIGBUS. The first 10 are logged in `dmesg` (`padre: emulated unaligned access, …`) |
| Hardware clock (Dallas DS1337, I2C 0x68) | works: `padre_rtc` (`/dev/rtc0`), time read at boot (`RTC_HCTOSYS`), written back after NTP (`S41time`, `hwclock -w`, and `RTC_SYSTOHC`); the 16 registers are shown in `dmesg` at boot |
| LVM (lvm2 2.03.31) | works: `board/readynas-duo-v1/patches/lvm2/` aligns the `dm_task_get_device_list()` list on 8 bytes (64-bit `dev_t`: SIGBUS from `lvm pvs` on SPARC) |
| NAND flash, read only (`padre_nand`, `patches-shelved/linux/`, not built; kernel modules: `patches/linux/0021`) | **shelved** (2026-11-18): chip read fine (ID `ec 76`, bad block table, ECC, `mtd0` read twice identical), but reading while the system runs from the USB stick loses the stick, with or without pausing EHCI; see [below](#nand-flash-read-only-backup-shelved) |
| ksmbd, NFS v3/v4, mdadm | built, not tested |
| [DIET](DIET.md) web dashboard (lighttpd HTTPS) | works on the NAS (system updates, X-RAID write switch); every action tested in simulation (`test-api.sh`) |

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
It fails if the kernel, the initramfs (`usr/initramfs_data.cpio`) or `rootfs.tar` contain the
absolute path of the repository or of the output directory, or the builder's `user@host`.
`external.mk` keeps them out: kernel banner `readynasng@build` (`KBUILD_BUILD_USER/HOST`),
`-ffile-prefix-map` for sqlite (`__FILE__` in the shell's asserts), relative paths in the
ffmpeg configure line (`av*_configuration()`); the initramfs test programs are stripped.
`BR2_REPRODUCIBLE` is not used: it rebuilds everything (toolchain wrapper flags), drops the
build-ids, dates every file with the last commit, and leaves the ffmpeg line as it is.

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
[`toolchain-v7-2026.08.1-r3`](https://github.com/beudbeud/ReadyNasNextGen/releases/tag/toolchain-v7-2026.08.1-r3),
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

## Kernel patches

`board/readynas-duo-v1/patches/linux/`, applied in name order by Buildroot
(`BR2_GLOBAL_PATCH_DIR`) to Linux 6.18.63: platform core first, then memory management and
emulation, then the drivers, then the later work on top of them.

| Patch | Content |
|---|---|
| `0001-sparc-add-the-infrant-padre-platform` | `CONFIG_SPARC_PADRE`, `asm/padre.h`, boot from iboot (`head_32.S`), emulated PROM (`padre_prom.c`), interrupts and timer (`padre_kernel.c`), `ioremap()` through the fixed I/O window |
| `0002-sparc-padre-mmu-and-caches` | Infrant MMU and caches (`padre_mm.c`, Padre page tables), window traps and faults with the Padre MMU registers |
| `0003-sparc-padre-emulate-the-user-flush-instruction` | user `flush` (ld-uClibc PLT rewrite): D-cache write-back, I-cache invalidation |
| `0004-sparc-padre-avoid-the-broken-sdiv-instruction` | C built with `-mcpu=v7`, `.mul`/`.div`... in `padre_muldiv.S` |
| `0005-sparc-math-emu-fix-fmovs-fabss-fnegs` | math-emu: the fmovs/fabss/fnegs result was overwritten |
| `0006-sparc-padre-emulate-the-whole-fpu` | no FPU: every floating-point instruction emulated, loads, stores and branches included |
| `0007-sparc-padre-emulate-unaligned-user-accesses` | unaligned integer user accesses emulated instead of SIGBUS |
| `0008-sparc-padre-load-the-list-processor-firmware` | LP coprocessor firmware (`padre_lpram.c`), loaded at boot by `head_32.S` |
| `0009-sparc-padre-pci-host-bridge` | PCI bridge (`padre_pci.c`) of the VIA USB controller |
| `0010-usb-ehci-vt6212-keep-the-async-head-link-fixed` | EHCI: permanent dummy QH after the async head (VT6212) |
| `0011-usb-ehci-pci-padre-pci-bridge-byte-order` | EHCI PCI: register byte order through the Padre bridge, no early handoff |
| `0012-tty-serial-padre_uart` | UART driver and console (ttyS0, ttyS1) |
| `0013-padre_i2c-twsi-controller` | `drivers/platform/padre`, TWSI I2C controller |
| `0014-padre_rtc-ds1337-clock` | DS1337 hardware clock (`/dev/rtc0`) |
| `0015-padre_led-leds-and-backup-button` | LEDs and backup button |
| `0016-padre_hwmon-fan-lm75-power-button` | fan, LM75, power button |
| `0017-padre_gmac-gigabit-ethernet` | GM0 Gigabit Ethernet |
| `0018-padre_sata-sata-disks` | SATA disks (libata SFF, PIO and LP DMA) |
| `0019-padre_sata-dma-run-time-switch-and-command-guard` | SATA DMA switchable at run time, non read/write DMA commands refused |
| `0020-sparc-padre-16-kib-pages` | 16 KiB pages, like the stock 2.6.17 kernel |
| `0021-sparc-padre-modules-can-multiply-and-divide` | modules can use `.mul`/`.div`... (exported as `_Mul`...) |
| `0022-padre_gmac-napi-gro-and-receive-checksum` | Ethernet NAPI, GRO, receive checksum by the engine |
| `0023-padre_gmac-transmit-checksum-by-the-engine` | Ethernet transmit checksum and scatter-gather, off by default |

0001 alone does not link (it needs the MMU code of 0002); from 0002 on, every step builds.
Shelved, not applied: `board/readynas-duo-v1/patches-shelved/linux/padre_nand-read-only-nand-flash-for-backups.patch`
(read-only NAND driver, see [below](#nand-flash-read-only-backup-shelved)); it applies on top of 0023.

## 16 KiB pages

The data volume `/c` and the RAIDiator system volume are ext3 with 16 KiB blocks: the kernel
mounts a block size only up to its page size. Like the stock 2.6.17 kernel
(`CONFIG_PADRE_16K_PAGE`), the Padre kernel has 16 KiB pages (`patches/linux/0020`): a Linux
PTE is 4 consecutive 4 KiB entries of the Infrant MMU (`pte_t` holds the 4 words,
`pte_val()`/`__pte()` work on the first one plus the A/D bits the MMU set in the others), a
table of 256 Linux PTEs is one 4 KiB hardware table, directories and tables are 4 KiB blocks of
the uncached pool (`/proc/cpuinfo`: `pagetables`), the TLB probe of a page covers its 4 entries,
the kernel stack is one page, `AT_PAGESZ` is 16384. So `nas-raid` mounts `/c` with the kernel
ext4 driver; fuse2fs is gone.

Measured (200 MiB of a file of `/c`, cold cache, disks in PIO): kernel ext4 11.8 MiB/s, fuse2fs
(before) 3.3 MiB/s; writing ~3 MB/s against 0.11 MB/s; same md5 of a 344 MB file both ways. User space needs every `PT_LOAD` congruent
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
`.sha256` from `output-rapide/images`, installed from the System page into the second
system slot of the stick and tried once (docs/DIET.md, “System update”).

**Stick image.** `make stick-image` (`board/readynas-duo-v1/mkstick.sh`, `IMAGES=`,
`VERSION=`, `SIZE_MB=` optional, default 1024) makes `readynasng-stick-<version>.img`, its
`.img.xz` and their `.sha256` without root: an MBR with one type 83 partition from 1 MiB, ext3
`usbroot` made by `mke2fs -d` under fakeroot (owners of `rootfs.tar` kept) with
`/rootfs-6.18` (plus `etc/system-version`), `/boot/vmlinux.bin(.md5)` and `/README.txt`.
Features limited to what the 2.6.17 ext3 driver mounts (incompat `filetype`, ro_compat
`sparse_super,large_file`, compat `has_journal,ext_attr,resize_inode,dir_index`; 128-byte
inodes). The script then reads the partition back from the image and checks it: `e2fsck -fn`,
feature list, owners and modes, kernel md5, entry count against `rootfs.tar`.

## NAND flash (read-only backup, shelved)

**Shelved on 2026-11-18**: the driver is kept as source (out of the series, in
`board/readynas-duo-v1/patches-shelved/linux/`, checked by
`tests/test-padre-nand.sh`) but not built (`CONFIG_PADRE_NAND` off), and the backup tool and
its web card are removed. On the NAS, the chip read correctly, but the NAND shares its pins
with PCI, which must be off during each access, and the USB controller (EHCI, root file
system) is on PCI: without a pause the stick was lost while reading `mtd1`; with EHCI halted
around each page and the read refused when it does not halt within 2 ms, the system stayed up
but reads were refused after about 5 MiB; with retries, the stick was lost again after about
6.5 MiB (stopping EHCI thousands of times during transfers). Lead for later: read the flash
from the initramfs at boot, with the EHCI device unbound (no USB activity, the stick not yet
the root), then bind it again. The rest of this section describes the shelved code.

**The flash is never written.** `padre_nand` (`drivers/platform/padre/padre_nand.c`,
`patches-shelved/linux/`, `CONFIG_PADRE_NAND=m`) exists only to back it up: it sends the chip
nothing but READ ID (0x90) and READ0 (0x00), through a single function with a whitelist; it
has no write, erase or bad block marking method, and its MTD devices are not
`MTD_WRITEABLE`. `nandwrite`, `flash_erase` and the mtd-utils are not in the image.
`board/readynas-duo-v1/tests/test-padre-nand.sh` checks this on the source taken from the
patch (and tries the whitelist with all 256 values), and the ECC against the 2.6.17 one.

**Hardware** (GPL 2.6.17 `padre_nand_flash.c` and Infrant `drivers/mtd/nand/nand.c`, "PZERO"
branch): Samsung K9F1208 on this NAS (ID `ec 76`, 64 MiB, 512 + 16 byte pages, 32 pages per
16 KiB block, 4 address cycles). No controller, no LP, no DMA: plain CPU byte accesses on the
ROM bus at bus address 0x0800_0000 (kernel 0x4800_0000): data at +0, command latch at
+0x10000, address latch at +0x20000. Chip enable is `PCI_FEATURE` (APB + 0x10c) bit 10, with
PCI switched off (`PCION`, bit 2) while the chip is selected: the ROM bus shares the PCI pins.
No ready/busy line: fixed wait after READ0 (`tr_us`, 25 µs; 2.6.17: 15).

**PCI and USB.** The VIA EHCI controller (USB stick, root file system) is a PCI bus master.
First test (driver without the pause): `mtd0` (1 MiB) read twice fine, then the NAS lost its
root file system during the 63 MiB of `mtd1` (network and HTTPS up, SSH refused the key:
`authorized_keys` unreadable); the flash itself is not affected (only reads). The driver now
reads each page with interrupts off, the EHCI controller stopped (`USBCMD.RS` cleared,
`HCHalted` awaited, at most 2 ms, otherwise the read fails with nothing sent to the chip), PCI
off, then `PCI_FEATURE` restored as found and EHCI restarted. Not tried on the NAS yet. A
read in progress costs the USB stick at most a few milliseconds per page.

**Layout** (as 2.6.17 shows it): Infrant bad block remapping, page 0 bytes 508–511 =
`0xdead<n>`, block n holds the table (1024 big-endian `{bad, good}` u16 pairs, `0xffff` ends
it; block 8 and no bad block on this NAS). Logical block b reads the replacement block if b is
listed bad; the device ends 1 block per bad block early. `mtd0` "iboot" = first MiB (iboot,
VPD at 0x8000: MAC address, serial number, ECC flag at 0x8188), `mtd1` "firmware" = the rest
(the encrypted NETGEAR container). 2.6.17 wrote a new table when it found none: `padre_nand`
refuses to load instead (`raw=1` gives the physical view, no remapping). ECC: software Hamming,
3 bytes per 256 in spare bytes 6–11, used when the VPD byte at 0x8188 is 0xEC (`ecc=-1` auto,
0, 1); one bit corrected per 256 bytes, counted in `/sys/class/mtd/mtdN/corrected_bits` and
`ecc_failures`; pages whose stored ECC is all 0xff (iboot) are read as is.

**Modules.** The kernel had never loaded a module: gcc `-mcpu=v7` calls `.mul`/`.udiv`...,
which kbuild cannot export. `patches/linux/0021` exports them as `_Mul`, `_Udiv`... (the
names modpost checks) and the module loader renames a module's undefined `.udiv` to `_Udiv`.
A kernel without 0021 (0.1.1) cannot load `mtd.ko`.

**Removed with the shelving**: `nas-flash` (it loaded `padre_nand`, read each partition
twice and compared, then wrote `mtd0.bin`, `mtd1.bin`, `info.txt` and `SHA256SUMS`) and the
web card. Such a backup holds the encrypted NETGEAR firmware and the VPD of the NAS: keep it
private.

## Kernel parameters (built-in command line, `board/readynas-duo-v1/linux-padre.config`)

| Parameter | Purpose |
|---|---|
| `padre.disable=a,b` | do not start some Padre drivers: `i2c`, `rtc`, `led`, `hwmon`, `gmac`, `sata`, `dma`, `pci` (debugging) |
| `padre_sata.dma=0/1` | disk DMA through the LP coprocessor (1 in the built-in command line; 0 = PIO). Booted with 1: switchable at run time in `/sys/module/padre_sata/parameters/dma` (0 = DMA commands run in PIO); `dma_cmds` counts LP commands |
| `padre.trace_fault=N` | shows the first N user page faults |
| `padre.trace_tick=1` | tick state in `/proc/padre_tick` and `[pulse]`/`[watchdog]` lines on the console (default 0) |
| `padre_mm.flush=1/2/0` | handling of the `flush` instruction: 1 (default) whole D-cache + I; 2 targeted D line only; 0 skipped (diagnostics). Also at runtime: `/sys/module/padre_mm/parameters/flush` |
| `padre.pcibus=<hex>`, `padre.pcifeat=<hex>`, `padre.pciswap=<hex>`, `padre.ahbarb=<n>` | PCI bridge settings (2.6.17 defaults) |
| `tests=1` | `/init` first runs the initramfs tests (`float` t1–t11, `windows`, `load`, sleep) |
| `rootdev=/dev/sdXN`, `rootdir=/other` | `/init`: root partition without searching, directory other than `/rootfs-6.18` |
| `padre_hwmon.setpoint=N`, `padre_sata.read_only=1` | fan setpoint at boot (0–255, default 80); refuse any write to the SATA disks |

Default: `console=ttyS1,9600 quiet panic=10 padre_sata.dma=1 usb-storage.delay_use=0` (full log in
`dmesg`; `echo Y > /sys/module/printk/parameters/time` adds the timestamps).

Console tests (`readynas-tests` package, in `/usr/bin`): `test-flush with` (I-cache after code
rewrite, 0 errors expected; `without` must show some), `test-fp-s`, `test-fp-d`,
`test-fp-n` (FPU emulation in static, dynamic PIE, dynamic non-PIE), `test-align` (emulated
unaligned accesses, `malloc` alignment), `test-ldso 200`
(dynamic programs in a loop, 0 failures and 0 ld-uClibc segfaults expected).

## Kernel tuning

Measured on the NAS (2026-11-18) against 0.1.2-rc2, one change set at a time, kernel swapped
in a trial slot (`nas-update`). Only what gave a measurable gain was kept.

**Method.** Size: `vmlinux.bin` and the `Memory:` line of `dmesg`. Boot: `dmesg` timestamps
(`Run /init`, root re-mounted from the stick, `ksmbd: running`) and the time from `reboot` until
SSH and HTTPS answer, seen from the PC. Transfers: 500 MiB of random data with `smbclient -m SMB3`
from a PC on Wi-Fi (write, caches dropped, then read), `--client-protection=off` and `sign`; CPU
from `/proc/stat` sampled every second on the NAS over the transfer window; local disk with `dd`
(1 MiB blocks, `conv=fsync` for the write) on the `/c` LV.

**The CPU is the bottleneck of every transfer**: the NAS is 97–100 % busy (mostly system time
and softirq) during SMB transfers at 6–7 MiB/s, and during local `dd` (17 MiB/s write, 30 MiB/s
read). The Wi-Fi of the PC is not what limits, so CPU seconds per MiB and throughput go together.

| | 0.1.2-rc2 | tuned |
|---|---|---|
| `vmlinux.bin` | 7 244 604 bytes | 8 653 592 bytes (-O2, gzip initramfs) |
| Kernel code / MemTotal | 4759 KiB / 238 528 KiB | 5959 KiB / 237 424 KiB |
| Free memory 40 s after boot | 172 MB | 172 MB |
| `Run /init` | 2.39–2.45 s | 1.33 s |
| Root on the stick | 3.41–3.46 s | 2.26 s |
| `ksmbd: running` | 34.0–34.7 s | 31.8 s |
| `reboot` → SSH answers (PC) | 121–136 s | 120–124 s |
| SMB write, unsigned (3 runs) | 6.1 MiB/s, 0.160 CPU s/MiB | 7.0 MiB/s, 0.137 CPU s/MiB |
| SMB read, unsigned (3 runs) | 6.2 MiB/s, 0.162 CPU s/MiB | 6.7 MiB/s, 0.148 CPU s/MiB |
| SMB write / read, signed (AES-CMAC) | 1.97 / 1.98 MiB/s | 2.18 / 1.81 MiB/s (1 run) |
| `dd` write / read on `/c` | 16.3 / 30 MiB/s | 17.7 / 30 MiB/s |

Most of the `reboot` → SSH time is iboot, the 2.6.17 kernel and the relay (about 90 s, ±8 s
from one boot to the next), then the X-RAID sample check (13 s) and the services: what the
kernel saves is visible in `dmesg`, not in that total.

Kept:

- **`-O2`** (`CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE`, `linux-padre.config`): 14 % less CPU per MiB
  written over SMB, 8 % read, `dd` write 8 % faster; costs 1.2 MB of kernel text (0.5 % of the
  RAM). The signed read sample was lower (single run, within the spread of the reads).
- **Initramfs in gzip** instead of xz (`linux-padre-nas.fragment`): the built-in initramfs is
  unpacked before `/init` runs; xz takes 2.2 s on the Padre, gzip 0.6 s (measured with
  `unxz`/`gunzip` on the NAS). LZ4 would need `host-lz4` in the build for little more: the stick
  is not there before 1 s anyway.
- **`usb-storage.delay_use=0`** (command line): the stick is seen at 0.93 s instead of 2.09 s
  (default 1 s settle delay); `/init` polls for it. Side effect: the stick is now probed before
  the SATA disks and is named `sda` (disks `sdb`, `sdc`); nothing uses fixed names (X-RAID,
  `nas-update` and the initramfs look disks up through sysfs).
- **Empty `CONFIG_UEVENT_HELPER_PATH`**: the 284 uevents of a boot no longer fork
  `/sbin/hotplug` (a shell, 60 ms each on the Padre); `S95diet` sets the helper at the end of
  the boot, so the power button and the `padre_gmac` link events still reach `diet-hotplug`.
  `ksmbd: running` came 2 s earlier (one boot).
- **Unused options off**: `SLUB_DEBUG`, `WLAN` (it selects `WIRELESS`: the former
  `# CONFIG_WIRELESS is not set` alone had no effect), kyber, ksmbd Kerberos, PTP/PPS, PCIe
  ASPM, VGA arbiter: −82 KB of `vmlinux.bin`, +96 KiB of RAM. `RPCSEC_GSS_KRB5` (selected
  by NFSv4, it keeps the krb5/Camellia crypto), `RTC_DRV_M48T59` (sparc32) and
  `NET_SELFTESTS` (phylib) cannot be removed by a fragment. `UEVENT_HELPER` itself stays
  (button), as do `KALLSYMS` and `COREDUMP`.

Measured, not kept:

- `read_ahead_kb` of the `/c` LV at 2048 instead of 512: `dd` read uses 10–15 % less CPU, but
  SMB reads got slower (5.1 and 5.9 MiB/s, 0.17–0.19 CPU s/MiB).
- `vm.dirty_background_bytes=4M`, `vm.dirty_bytes=16M`: SMB writes unchanged (6.8 and
  7.4 MiB/s). TCP buffers were not tuned: `tcp_rmem` already allows 1.8 MB, far above what a LAN
  needs at these speeds.

Not done:

- `NO_HZ_IDLE`: the Padre timer is registered as a periodic-only clockevent (`time_32.c`, no
  `CLOCK_EVT_FEAT_ONESHOT`), so the tick could not stop anyway.
- AES-GMAC signing: ksmbd 6.18 only negotiates HMAC-SHA256 and AES-CMAC (`smb2pdu.c`, signing
  capabilities context); GMAC would need a ksmbd patch, and GHASH is slow on this CPU (mbedTLS
  on the NAS: AES-GCM 420 KiB/s against 1.4–1.9 MiB/s for AES-CMAC). Signing costs 3× the CPU
  of an unsigned transfer (0.45–0.56 against 0.14–0.16 s/MiB); Windows 11 24H2 asks for it.
- Kernel compression: iboot and the relay load a raw kernel.
- Next leads, in the drivers: `padre_gmac` had no NAPI and no hardware checksum (softirq was a
  third of the write CPU): done, see [Network driver](#network-driver-padre_gmac).

## Network driver (`padre_gmac`)

Measured on the NAS on 2026-11-18, same method as [Kernel tuning](#kernel-tuning) (500 MiB over
SMB3 from a PC on Wi-Fi, `/proc/stat` sampled on the NAS), kernel swapped in a trial slot that
was never confirmed (a reboot goes back to the active slot).

**What the hardware can do** (GMAC description from the 2.6.17 driver, checked on the NAS where
noted):

| Feature | Hardware | In the driver |
|---|---|---|
| Descriptor rings | 128 RX + 128 TX descriptors of 16 bytes in the uncached S3 SRAM, chained by address | unchanged |
| Receive buffers | frame written at buffer + 2 (IP header aligned), so the skb is handed over without copy | already so; NAPI buffers from `napi_alloc_skb` |
| Cache | DMA not coherent: write-back + invalidate of each receive buffer, write-back of each sent frame (16-byte lines, about 1 µs per frame) | unchanged |
| Interrupts | one line (41) for RX and TX, mask `M4 imask`; no coalescing register known | NAPI: the interrupt masks the engine and schedules the poll |
| Receive checksum | GMT block (DJ 0x5040 = 4) + `GMAC_CTRL` bit 22: bits 17–22 of the descriptor say IPv4, L4 checked, IP or L4 error | used: `CHECKSUM_UNNECESSARY` for good unfragmented IPv4 TCP/UDP frames (`ethtool -K eth0 rx`) |
| Transmit checksum, scatter-gather | "meta" descriptor switching the engine's checksum state, any number of fragment descriptors (buffers < 8 bytes aligned on 8) | `patches/linux/0023`, **off by default**, to be tried: see [below](#transmit-checksum-by-the-engine-patcheslinux0023) |
| TSO | meta command bit 7, segment size in GMT+4 (1500 on the NAS) | not tried |
| Jumbo frames | receive buffers of 8000 / 9024 bytes, MFL = MTU + 36 | not done: the test PC is on Wi-Fi |

**Receive checksum, validated before trusting it.** `padre_gmac.csum_verify=1` (or
`/sys/module/padre_gmac/parameters/csum_verify`) makes the driver check every TCP/UDP frame in
software and count the disagreements, without trusting the engine; `ethtool -S eth0` shows
`rx_csum_ok`, `rx_csum_bad`, `rx_csum_wrong` (engine said good, software bad) and
`rx_csum_missed`. Results: 2 GB written over SMB, 1 448 885 frames found good by the engine,
`rx_csum_wrong` 0, `rx_csum_missed` 0. 400 TCP and 400 UDP frames with a wrong checksum sent from
the PC (raw socket): all 800 flagged bad by the engine, and counted by the stack
(`InCsumErrors` 400 TCP + 400 UDP), with and without the verification.

**Transmit checksum (meta descriptors): the first attempt failed.** Frames left with a correct
checksum, then the engine's checksum state became the opposite of the one the driver asked for:
TCP frames sent with the pseudo-header seed only, ICMP replies with a zeroed checksum, so TCP
stopped (ping answered, with a bad checksum). Once, the NAS stayed in that state until it was
powered off. That code was not kept; what is known and what replaces it:
[Transmit checksum](#transmit-checksum-by-the-engine-patcheslinux0023).

**Results** (unsigned: 3 runs with NAPI, 2 before; signed: 1 run each; CPU s/MiB = busy CPU
seconds over the transfer window / 500):

| | before (tuned kernel) | NAPI + GRO + RX checksum |
|---|---|---|
| SMB write, unsigned | 7.5 / 6.2 MiB/s, 0.128 / 0.152 CPU s/MiB | 9.0 / 9.0 / 7.7 MiB/s, 0.105 / 0.107 / 0.119 CPU s/MiB |
| — of which softirq (s) | 23.2 / 25.3 | 11.7 / 11.9 / 18.4 |
| SMB read, unsigned | 4.8 / 7.1 MiB/s, 0.202 / 0.136 CPU s/MiB | 5.0 / 5.2 / 5.1 MiB/s, 0.195 / 0.187 / 0.191 CPU s/MiB |
| SMB write / read, signed | 2.19 / 2.16 MiB/s | 2.21 / 2.14 MiB/s |
| eth0 interrupts per frame sent or received (bench) | 0.97 (2.24 M for 2.30 M frames) | 0.28 (0.85 M for 3.06 M frames) |
| TCP segments seen by the stack per received frame | 1 | 0.13 (GRO: 1.45 M frames → 0.18 M segments for the 2 GB write) |
| ping idle / during a write | 7.0 / 18.2 ms average, 0 / 1 % loss | 6.1 / 15.4 ms, 0 / 0 % loss |

The NAS stays 99–100 % busy: writes go faster for less CPU (receive path: half the softirq
time). Reads (the NAS sends) do not change: the time is in the system calls (copy into the
socket, checksum while copying, software segmentation), which only a working transmit checksum
and scatter-gather would remove. Signed transfers are bound by AES-CMAC. The PC is on Wi-Fi: from
one run to the next the read throughput of the old kernel varied from 4.8 to 7.1 MiB/s.

Robustness: 2 GB write + 3 × 500 MB write and read + signed runs, no error in `/proc/net/dev`
(RX `errs` 0, `fifo` 0; 4 `drop`), no warning or oops in `dmesg`, no transmit timeout.

### Transmit checksum by the engine (`patches/linux/0023`)

Off by default, **never run on the NAS** (it builds; the trial plan is below). Reads over SMB
are bound by the transmit path, so this is the only lead left for them.

**How the 2.6.17 driver does it** (GMAC description §5.3, on by default there: checksum,
scatter-gather and TSO):

- The engine has a checksum state, off after the reset done at open (GMT mode 2, MAC reset,
  mode 4; `GMAC_CTRL` = `0x25600300`, bit 21 set; GMT+4 = 1500). The driver keeps a copy of it.
- When an IPv4 frame needs the other state, a "meta" descriptor goes first: control bit 26,
  size 2, no first/last/interrupt bit, buffer of two bytes `{previous command, new command}`
  in uncached memory, one 16-byte slot per ring entry; command bit 6 = insert the checksum
  (bit 7 = TSO, with the segment size in GMT+4). It is handed to the engine at once.
- Then the frame: one descriptor per buffer (head with "first", page fragments, "last" on the
  last one), all with the interrupt bit; the first one is handed over last; the channel is
  restarted when `gmtx_ctrl` bit 1 says it stopped. A buffer under 8 bytes must be 8-byte
  aligned.
- State wanted: on for a frame the stack left to the device (TCP/UDP with the pseudo-header
  sum in the field), off for any other IPv4 frame. Frames that are not IPv4 (ARP) never change
  it. Nothing else is told to the engine: no offsets, it parses the frame itself. Short frames
  are not padded by the driver (the MAC does it).

**What the captures of the first attempt show**, read again
(`tcpdump` on the PC):

- The engine, when on, sums the whole L4 part *including the field* and stores the complement:
  an ICMP reply that already had its checksum went out with 0. It does not add a pseudo-header
  (the stack's seed is needed) and it also acts on ICMP: a complete frame must go out with the
  engine off.
- The inverted state survived many commands in a row (ICMP zeroed after an "off", TCP not
  summed after an "on"). A command that set the state could not stay wrong like that: either
  the engine *flips* its state on a command (the two bytes old/new, one flip lost or doubled
  earlier), or the driver's copy and the commands it built had drifted apart. That code is
  gone, so this is open; the loopback experiment below settles the first point.
- The "incorrect" checksums on 1504-byte frames were not errors: GRO on the PC merges
  segments and leaves the pseudo-header sum in the field (`0x8ab2` = the seed of the bad small
  frames plus the length difference). Captures must be taken with GRO off on the PC.

**What 0023 does**

- Same descriptors, order and command bytes as 2.6.17; command slots in the 2 KiB of SRAM
  after the rings. The command always comes from the wanted state, and the driver's copy only
  changes once the frame is certain to be queued. Only plain TCP/UDP over IPv4 (no options, no
  fragment) is left to the engine; anything else is summed in software first. Scatter-gather
  (`ethtool -K eth0 sg on`, separate, needs `tx`): fragments under 8 bytes and unaligned are
  copied (`skb_linearize`). No TSO. GMT+4 = 1500 is written when the feature is on.
- Switch: `padre_gmac.tx_csum=1` on the command line, `echo 1|0 >
  /sys/module/padre_gmac/parameters/tx_csum`, or `ethtool -K eth0 tx on|off`. **Every change
  restarts the MAC and the engine** (2.6.17 recovery: GMT mode 2, FIFO flush, open sequence,
  about 0.2 s without network), so that turning it off never relies on the engine obeying.
  With the feature off no command is ever sent.
- The driver turns the feature off by itself, resets the same way and logs
  (`transmit checksum by the engine turned off`), on: a transmit timeout; 2 s without a
  completion while frames are pending; 8 FIFO underruns in a second; a descriptor still owned
  when reused; TCP that only retransmits (`tx_guard`, default 4 retransmissions in 4 s making
  at least half of the segments TCP sent; 0 = no such guard). The last one is the guard
  against an inverted engine; it also fires when a client vanishes in the middle of a
  transfer, which only costs the feature until it is turned on again.
- `ethtool -S`: `tx_csum_hw` (frames left to the engine), `tx_csum_sw`, `tx_meta` (commands),
  `tx_underrun`, `tx_csum_fallback`.
- `echo 1 > /sys/module/padre_gmac/parameters/tx_csum_verify` (link up, about 2 s without
  network, result in `dmesg`): test frames to ourselves in MAC loopback (PE-MCX `CFG1` bit 8),
  through the same transmit code, come back through the receive ring and are compared with a
  software checksum. One letter per step: `U` field untouched, `S` summed, `X` anything else,
  `L` lost. Expected `USUSSSSU..S.SU`:

  | Step | Frame | Tells |
  |---|---|---|
  | 0, 1 | UDP after a reset; after command 00→40 | `U`, `S`: the engine sums on command |
  | 2 | UDP after a reset done while on | `U`: a reset clears the engine, the way back is sound |
  | 3–5 | UDP odd length, TCP without data, TCP 1460 bytes | `S` |
  | 6 | ICMP with an empty field | `S` on the NAS so far |
  | 7 | ARP type, engine on | `U`: other frames are left alone |
  | 8, 9 | UDP with IP options; first fragment | whether the software path for these is needed |
  | 10, 11 | command 40→40, then 00→40 while on | `SS`: a command sets the state; `SU`: it flips it when "old" is wrong; `U.`: any command flips it |
  | 12, 13 | reset, 00→40, then 40→00 | `S`, `U`: off works |

  The sum the engine inserts cannot be seen on real frames: it is put in on the way out,
  neither the buffer nor the descriptor keeps it. For those, capture on the peer. If nothing
  comes back (`L`), the MAC loopback does not work on this wrapper and only the capture is
  left. Unknown, hence to read in the result: a UDP sum of 0 (must be sent as `0xffff`).

**Trial plan** (console on the serial port, 9600 baud, `ttyS1`; the NAS in a trial slot that
is never confirmed, so that a power cycle returns to the previous system):

1. *Stock system, read only.* `touch /.relay_skip_once; reboot` in 6.18 starts the stock
   2.6.17 system once. Build `tools/gmpeek.c` (command in its header: static, no libc),
   copy it over SSH (`ssh root@NAS 'cat > /tmp/gmpeek; chmod +x /tmp/gmpeek' < gmpeek`). It
   reads through the register read call of the original driver and writes nothing.
   `/tmp/gmpeek > /tmp/g0.txt` at rest, then `/tmp/gmpeek 50 > /tmp/g1.txt` while the PC
   reads a large file from the NAS and runs `ping -i 0.2` (every reply needs the engine off).
   To check: `gmac` first word = `0x25600300` plus the enable bits; `gmt` = `00000004
   000005dc`; in the ring, descriptors with bit 26, size 2, placed just before a "first"
   descriptor, and their two bytes (`0040…` on, `4000…` off, `c0`/`80` with TSO); frames in
   several descriptors. A difference with the list above goes into the driver before going
   further. Reboot: back to 6.18.
2. *Loopback experiment in 6.18*, feature off: `echo 1 > …/tx_csum_verify`, three times.
   Stop here if step 1 is not `S`, step 2 not `U` (the automatic way back could not be
   trusted), step 7 not `U` or step 13 not `U`.
3. *Short traffic.* On the PC: `ethtool -K <if> gro off`, `tcpdump -ni <if> -vv host <NAS>`.
   On the console: `(sleep 120; echo 0 > /sys/module/padre_gmac/parameters/tx_csum) &` then
   `echo 1 > …/tx_csum`. Ping (also `-s 2000`: fragments), one UDP exchange, an SSH login, the
   dashboard; then `ping -i 0.2` during an SSH transfer (many state changes). Every frame from
   the NAS must show a correct checksum; `tx_meta` grows with the alternations,
   `tx_underrun` and `tx_csum_fallback` stay at 0.
4. *Long transfers*: 3 × 500 MB read over SMB, file compared with its source; then `sg on`
   and the same; CPU s/MiB against the table above.
5. *The way back, on purpose*: `echo 0 > …/tx_csum` during a transfer (it goes on after the
   restart); pull the PC's cable during a read and watch the guard turn the feature off.

Stop at the first wrong checksum from the NAS in the capture, at any `turned off` line in
`dmesg`, at a rising `tx_underrun`, or if ping loses packets. Way back, in order:
`echo 0 > /sys/module/padre_gmac/parameters/tx_csum` on the console (resets the engine);
`ifconfig eth0 down; ifconfig eth0 up` (full open sequence); `reboot` (the feature is off at
boot: never put `padre_gmac.tx_csum=1` on the command line during the trial); power cycle
(the unconfirmed trial slot gives the previous system back).

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
  patches/linux/                 Padre platform for Linux 6.18.63, one patch per subject
                                 (see "Kernel patches" above)
  patches-shelved/linux/         read-only NAND driver (padre_nand), not applied
  patches/uclibc/                flush after the PLT rewrite by ld-uClibc; SPARC longjmp fix
  patches/binutils/              16 KiB default ELF page size (toolchain from r3)
  patches/lvm2/                  alignment of the dm device list (libdm)
  tests/test-padre-nand.sh       padre_nand: read-only checks, command whitelist, ECC
  initramfs/                     /init, `list` (gen_init_cpio), test sources
  rootfs-overlay/                ksmbd, NFS, fan control
  readynas_crypto/               iboot encryption tool (GPL), compiled by post-image.sh
  relay/                         padre_relay.ko (2.6.17 module), relay-init, relay-switch, add-ons, build in QEMU
  post-image.sh
tools/                           iboot-cmd.py (serial console), tftp-server.sh,
                                 gmpeek.c (read-only look at the Ethernet engine under 2.6.17)
```
