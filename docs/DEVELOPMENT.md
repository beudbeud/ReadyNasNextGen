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
| SATA disks (libata, DMA through the LP coprocessor, on by default) | works: raw read 14.9 MB/s in PIO, 35.5 MB/s in DMA (about 70 MB/s per disk with direct I/O); always `sda` (bay 1) and `sdb` (bay 2), the USB stick after them (`patches/linux/0027`) |
| Both LP channels at once (`patches/linux/0025`, `padre_sata.lp_parallel`, on by default) | works: reading both disks ×1.75 (15.2 s → 8.7 s for 2 × 512 MB), X-RAID writes +10–16 %; reads compared with PIO, written files and both mirror legs compared byte for byte; see [Parallel LP channels](#parallel-lp-channels-patcheslinux0025) |
| Ethernet, LEDs, button, fan/temperature (`drivers/platform/padre`) | ported, to be validated |
| Ethernet NAPI, GRO, receive checksum by the engine (`patches/linux/0022`) | works: 2 GB written over SMB with the engine checked against a software checksum, 0 disagreements; see [Network driver](#network-driver-padre_gmac) |
| Ethernet transmit checksum by the engine, scatter-gather (`patches/linux/0023`) | works, on by default: loopback experiment as expected, TCP/SSH/SMB transfers byte for byte, no checksum error on the peer; see [Transmit checksum](#transmit-checksum-by-the-engine-patcheslinux0023) |
| SMB reads without copy (`patches/linux/0026`, ksmbd `zerocopy_read`) | works, on by default: SMB reads 17–20 MiB/s instead of 5–7 (Wi-Fi), system time ÷ 10; see [SMB](#smb-zero-copy-reads-and-signing) |
| SMB signing, AES-CMAC for SPARC v7 (`patches/linux/0024`) | works: `cmac-aes-sparc32` passes the kernel self-tests; signed reads 3.4–3.6 MiB/s instead of 2.2–2.3 |
| USB EHCI (VIA VT6212) | works: AHB arbitration from 2.6.17 restored; the VT6212 never re-reads the horizontal link of the head QH once the CPU has rewritten it, so a permanent dummy QH follows the head and the real QHs are chained after it |
| Boot from the USB stick (`/rootfs-6.18`), `quiet` console | works: root reached about 2.3 s after the kernel starts (see [Kernel tuning](#kernel-tuning)) |
| Dynamic programs (ld-uClibc) | works: ld.so runs `flush` after rewriting the PLT (uClibc patch), the kernel handles this `flush` (D-cache write-back, I-cache invalidation) |
| Unaligned integer accesses in user space | emulated by the kernel (`user_unaligned_trap`, `unaligned_32.c`), like 2.6.17 and sparc64; the original sparc32 sent SIGBUS. The first 10 are logged in `dmesg` (`padre: emulated unaligned access, …`) |
| Hardware clock (Dallas DS1337, I2C 0x68) | works: `padre_rtc` (`/dev/rtc0`), time read at boot (`RTC_HCTOSYS`), written back after NTP (`S41time`, `hwclock -w`, and `RTC_SYSTOHC`); the 16 registers are shown in `dmesg` at boot |
| LVM (lvm2 2.03.31) | works: `board/readynas-duo-v1/patches/lvm2/` aligns the `dm_task_get_device_list()` list on 8 bytes (64-bit `dev_t`: SIGBUS from `lvm pvs` on SPARC) |
| NAND flash, read only (`padre_nand`, `patches-shelved/linux/`, not built; kernel modules: `patches/linux/0021`) | **shelved** (2026-11-18): chip read fine (ID `ec 76`, bad block table, ECC, `mtd0` read twice identical), but reading while the system runs from the USB stick loses the stick, with or without pausing EHCI; see [below](#nand-flash-read-only-backup-shelved) |
| ksmbd, NFS v3/v4, mdadm | ksmbd and md RAID 1 in daily use (see [SMB](#smb-zero-copy-reads-and-signing)); NFS built, not measured |
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
| `0023-padre_gmac-transmit-checksum-by-the-engine` | Ethernet transmit checksum and scatter-gather by the engine, on by default (`tx_csum`, `sg`) |
| `0024-crypto-sparc32-fast-aes-cmac-for-sparc-v7` | `cmac-aes-sparc32`: the whole CMAC chain in one function, 4 KiB of tables (SMB 3 signing) |
| `0025-padre_sata-x-raid-writes-on-parallel-lp-channels` | one LP list per SATA channel at once (`lp_parallel`, on by default, back to one at a time on any LP error) |
| `0026-ksmbd-zero-copy-reads-from-the-page-cache` | ksmbd sends SMB reads from the page cache (splice + `MSG_SPLICE_PAGES`, `zerocopy_read`) |
| `0027-padre_sata-disks-named-before-the-usb-stick` | `padre_sata` at `fs_initcall`, usb-storage waits for the disk probes: disks `sda`/`sdb`, stick after them |

0001 alone does not link (it needs the MMU code of 0002); from 0002 on, every step builds.
Shelved, not applied: `board/readynas-duo-v1/patches-shelved/linux/padre_nand-read-only-nand-flash-for-backups.patch`
(read-only NAND driver, see [below](#nand-flash-read-only-backup-shelved)); it applied on top of 0023.

`board/readynas-duo-v1/post-image.sh` refuses a kernel or a program with `sdiv`/`sdivcc`
(wrong on the Padre) or `casa`; `sdiv …, %g0` is not refused: its result is thrown away, and
jump tables in `.init.text` whose entries are kernel addresses `0x8079xxxx` decode exactly as
that.

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
| Transmit checksum, scatter-gather | "meta" descriptor switching the engine's checksum state, any number of fragment descriptors (buffers < 8 bytes aligned on 8) | `patches/linux/0023`, on by default: see [below](#transmit-checksum-by-the-engine-patcheslinux0023) |
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
powered off. The cause, found in 0.1.3: the command bytes were in the SRAM, where the engine
misreads them; see [Transmit checksum](#transmit-checksum-by-the-engine-patcheslinux0023).

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

On by default since 0.1.3, with scatter-gather. Off: `padre_gmac.tx_csum=0` on the command
line, `echo 0 > /sys/module/padre_gmac/parameters/tx_csum`, or `ethtool -K eth0 tx off`;
scatter-gather alone: the `sg` parameter or `ethtool -K eth0 sg`.

**How the 2.6.17 driver does it**, read on the NAS with `tools/gmpeek` (stock system started
once with `touch /.relay_skip_once; reboot`; the tool only uses the register read call of the
original driver, private ioctl 0x89f2, and needs `socketcall` there):

- A "meta" descriptor goes before a frame that needs another engine state: control bit 26,
  size 2, no first/last/interrupt bit, a buffer of two bytes `{previous command, new command}`
  **in ordinary memory** (one 16-byte slot per ring entry). Once the engine is done the
  descriptor reads `00000002`: bit 26 is gone.
- Command bit 6 = insert the checksum, bit 7 = TSO (segment size in GMT+4 = 1500). Its resting
  state is `c0`; it leaves it for one frame only: `c0→00` (frame) `00→c0`, `c0→80`/`80→c0`,
  `00→40`/`40→c0`. It never sends `40→00`, and only TCP goes to the engine (UDP, ICMP: `00`).
- Then the frame: one descriptor per buffer (66-byte header, then data), the first one handed
  over last.

**Why the first attempt failed: the command bytes were in the SRAM after the rings.** Read from
there, the engine misreads them: the frame right after a command came back (MAC loopback) with
the 16-bit word before its checksum field copied into the field (`636a` = bytes 14–15 of the
TCP header, `0800` = the ICMP type), and no command turned the engine off (only a reset did).
With the bytes in RAM (`meta_ddr=1`, the default; `meta_ddr=0` brings the old behaviour back
for comparison), every step of `tx_csum_verify` is as expected and 40 alternations `00↔c0` are
all right, three runs out of three.

What 0023 does: commands `c0` (TCP left to the engine, frames never above the 1500-byte
segment size so TSO never splits) and `00` (any other frame), sent only when the state
changes; UDP (summed wrong by the engine), IP options and fragments are summed in software.
Every change of the feature restarts the MAC and the engine (GMT mode 2, FIFO flush, open
sequence). The driver turns it off by itself, resets and logs (`transmit checksum by the engine
turned off`) on a transmit timeout, 2 s without completion with frames pending, 8 FIFO
underruns in a second, a descriptor still owned when reused, or TCP that only retransmits
(`tx_guard`). `ethtool -S`: `tx_csum_hw`, `tx_csum_sw`, `tx_meta`, `tx_underrun`,
`tx_csum_fallback`.

`echo 1 > /sys/module/padre_gmac/parameters/tx_csum_verify` (link up, about 2 s without
network, result in `dmesg`): test frames to ourselves in MAC loopback (PE-MCX `CFG1` bit 8)
through the same transmit code, compared with a software checksum: `U` field untouched, `S`
summed, `X` anything else, `L` lost. Expected `USSSSSUUUSUSUSUSSU` followed by 40 alternations
`SU…`.

**Results on the NAS** (Wi-Fi PC; every file read back compared with its source; the PC's
`InCsumErrors` counters in `/proc/net/snmp` unchanged throughout, so no frame with a wrong
checksum reached it; no `turned off` in `dmesg`):

| 300 MB over raw TCP | write() | sendfile() | NAS CPU |
|---|---|---|---|
| off | 5.96 / 6.04 MiB/s | 12.4 / 11.6 MiB/s | 99–100 % |
| checksum only | 5.81 / 5.85 MiB/s | 11.5 / 11.8 MiB/s | 99–100 % |
| checksum + scatter-gather | 8.34 / 8.25 MiB/s (+38 %) | 19.6 / 18.6 MiB/s (+60 %) | 99 % / 80–88 % |

The checksum alone does not help (the copy into the socket sums for free); with scatter-gather
the copy disappears. Ping (also fragmented), SSH, HTTPS and SMB work; no ping lost during
transfers.

## SMB: zero-copy reads and signing

**Reads without copy (`patches/linux/0026`).** ksmbd answered an SMB2 READ by zeroing a buffer
of up to 4 MiB (`kvzalloc`), copying the file into it (`kernel_read`) and copying it again into
the socket (`kernel_sendmsg`). It now takes the page cache pages through splice
(`splice_direct_to_actor`, as nfsd does), keeps a reference to them until the response is
freed, points the response kvecs at them, and the TCP transport sends those with
`MSG_SPLICE_PAGES` (zero copy with the scatter-gather of 0023). Signing covers the header and
every data kvec. Not used for SMB 3 encryption (in place), compound requests, RDMA, streams,
reads under one page: the copying path, which no longer zeroes its buffer. Switch:
`/sys/module/ksmbd/parameters/zerocopy_read` (default 1).

**Signing (`patches/linux/0024`).** SMB 3 signing is `cmac(aes)`, which resolved to the
`cmac` template over `aes-generic`: two calls per 16-byte block, byte loads and stores, an
encryption unrolled for every key size over 8 KiB of tables. `cmac-aes-sparc32` (priority 200,
`CONFIG_CRYPTO_CMAC_AES_SPARC32`) runs the whole chain in one function with the state in
registers, encryption only, 4 KiB of tables. User-space bench on the NAS (same code): 4.90 MiB/s
against 3.72 for today's path (×1.32), 2.15 for the fixed-time AES, 3.03 for HMAC-SHA256 (SMB
2.x); bitsliced AES does not suit CMAC (one block at a time). The kernel self-tests pass
(`/proc/crypto`: `selftest : passed`, with `CONFIG_CRYPTO_SELFTESTS_FULL` on a test kernel).
Table-based like `aes-generic`, so the same cache-timing exposure, with half the tables.

**`smb2 max read`:** the default (4 MiB) is the fastest: 9.6 / 8.8 MiB/s against 7.1 (1 MiB),
5.6 (256 KiB) and 4.8–6.3 (64 KiB), measured before 0026: the cost per request dominates.

**Results** (500 MB SMB3 reads from a Wi-Fi PC, files compared byte for byte):

| | 0.1.2 | 0.1.3 |
|---|---|---|
| read, unsigned | 5–7 MiB/s, CPU 100 %, ~60–73 s system time | 17–20 MiB/s, CPU 88–92 %, 5–8 s system time |
| read, signed | 2.2–2.3 MiB/s | 3.4–3.6 MiB/s |

## Parallel LP channels (`patches/linux/0025`)

The driver let only one port at a time have a list on the List Processor (`lp_owner` and
`ATA_DEFER_PORT`), so both halves of every RAID 1 write went to the disks one after the other,
and the deferred port only retried after a SCSI host-busy requeue (one jiffy at least). The LP
firmware, disassembled again as big-endian SPARC, keeps one state machine per channel and, for
lists without the "meta" flag (this driver never sets it), touches only that channel's SATA
block, MC FIFO, DJ route and interrupt bit; only "meta" lists (the 2.6.17 X-RAID multi-disk
commands) wait on the other disks.

`padre_sata.lp_parallel` (default 1): one list per channel in flight; 0 = one at a time as
before. Any LP timeout or DMA error sets it back to 0 with a warning. `dma_overlap` counts the
lists started while the other channel had one.

Tried on the NAS: both disks read with direct I/O, 2 × 512 MB, 15.2 s one after the other,
8.6–8.8 s at once (×1.75, about 2 300 overlapping lists per run); 128 MB at four places read on
both disks at once and in PIO, identical; 256 MB files written to `/c` 20.9 MiB/s serial, 22.9 /
24.1 MiB/s parallel (the CPU, ext4 and md, is the limit there), read back identical, and both
mirror legs (`dm-2`, `dm-3`) identical over every extent of the files (from `filefrag`); 32
files of 1 MiB written during a concurrent read, all identical; no LP timeout, the mirror stayed
`[UU]`.

## Disk names

With `usb-storage.delay_use=0` (fast boot, 0.1.2) the system stick was scanned before
`padre_sata` even started, so it became `sda` and the disks `sdb`/`sdc`. `patches/linux/0027`
starts `padre_sata` at `fs_initcall` (after libata and SCSI, before `sd`, EHCI and
usb-storage), so the ports are probed in the background before USB is up, and usb-storage waits
for pending async probes before scanning a device: the disks are always `sda` (bay 1) and `sdb`
(bay 2), the stick `sdc`. The DIET interface and `nas-raid` find the disks by their ATA port,
not their name, and never list a USB device as a disk.

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
