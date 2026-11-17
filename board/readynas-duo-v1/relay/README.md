# Relay: boot Linux 6.18 from the stock 2.6.17 kernel

Without the relay, Linux 6.18 only starts when iboot is interrupted on the serial console
and the kernel is loaded by TFTP. With it, the NAS boots on its own:

```
power on → iboot (flash) → NETGEAR 2.6.17 kernel (flash) → linuxrc → system volume:
  /sbin/init = relay-init → /relay/relay-switch → padre_relay.ko
  → Linux 6.18 from the USB stick (/boot/vmlinux.bin, root /rootfs-6.18)
  otherwise → /sbin/init.before-relay (RAIDiator's init, or DIET's boot switch)
```

`padre_relay.ko` is a module for the running 2.6.17 kernel that loads the raw 6.18 image
(`vmlinux.bin`: linked at 0x8000_4000, initramfs and command line built in) and jumps to it
in the state iboot leaves after `go 0x80004000` (sparc32 has no kexec). `relay-init`
and `relay-switch` decide at each boot, with an automatic fallback to the system that was
there before (stock RAIDiator 4.1.x, or DIET if installed). **Nothing writes the
flash**: no code here touches `/dev/mtd*` or the NAND controller.

The hand-over (module + `relay-switch`) was validated on a ReadyNAS Duo v1, started from
DIET's boot switch (2.6.17 uses 16 KiB pages, handled); `relay-init` and the add-ons are
checked in simulation only (`test-addon.sh`).

| File | Role |
|---|---|
| `padre_relay/relay.c` | module: staging, checks, `/proc/padre_relay/{image,control}`, shutdown |
| `padre_relay/trampoline.S` | last step: caches off, copy to 0x8000_4000, MMU/PSR, jump |
| `relay-init` | boot switch installed as `/sbin/init` on the system volume |
| `relay-switch` | finds the stick, checks and starts 6.18 (2.6.17 side) |
| `Module.symvers` | CRCs of the 37 kernel symbols the module uses, as exported by the stock kernel |
| `build-module.sh`, `build/` | builds the module in NETGEAR's SPARC compile environment (QEMU) |
| `addon/`, `build-addon.sh` | RAIDiator add-ons that install / remove the relay |
| `test-addon.sh` | checks the add-ons on the PC (simulated system volume) |
| `../rootfs-overlay/etc/init.d/S99relay-confirm` | 6.18 side: removes the "boot pending" marker |

Licence: GPL-2.0, like the rest of the repository. The module is written from the GPL
sources of the 2.6.17 kernel published by NETGEAR (`arch/padre`); iboot and the proprietary
modules were neither copied nor decompiled.

## Building

```sh
make relay          # output-relay/padre_relay.ko   (~10 min, downloads ~800 MB once)
make relay-addon    # output-relay/ReadyNasNextGen_relay_<v>.bin and _relay_remove_<v>.bin,
                    # then runs test-addon.sh       (VERSION=x.y, KO=/path/padre_relay.ko)
```

### The module

The module must match the stock kernel exactly (`2.6.17.14ReadyNAS`, `CONFIG_MODVERSIONS`,
gcc 3.3, no hardware `sdiv`), so it is built with NETGEAR's own tools. `build-module.sh`:

1. downloads, once, into `dl/relay/` (SHA-256 checked):
   - NETGEAR's GPL archive `RNR4_RND4_RND2_4.1.6_WW_src.zip` (the NETGEAR link is dead;
     official mirror on SourceForge:
     `https://sourceforge.net/projects/officialnetgearfirmware/files/ReadyNAS/RNR4_RND4_RND2_4.1.6_WW_src.zip/download`);
     only `linux-2.6.17.8/` is used;
   - NETGEAR's ReadyNAS SPARC compile environment, a Debian SPARC QEMU image with
     gcc 3.3.5 / binutils 2.15 (`https://www.readynas.com/download/development/readynas_compile_environment.qcow.gz`,
     fallback: its Wayback Machine copy). Local copies: `GPL_ZIP=…`, `QCOW_GZ=…` or `QCOW=…`
     (already decompressed);
2. extracts the tree, sets `EXTRAVERSION = .14` (with `CONFIG_LOCALVERSION="ReadyNAS"` of
   `arch/padre/defconfig`, `KERNELRELEASE` is `2.6.17.14ReadyNAS`) and copies `Module.symvers`;
3. makes an ext2 work disk of it (`mke2fs -d`, 128-byte inodes), boots the image in
   `qemu-system-sparc -M SS-5` 7.2 in Docker (`build/Dockerfile`; QEMU 10's esp emulation
   takes the guest disks offline), without network, root disk as a throw-away snapshot;
4. in the guest (`build/guest.sh`): `arch/padre/defconfig`, `oldconfig`, `modules_prepare`,
   recomputes with genksyms the CRCs exported by a few core objects and compares them with
   `Module.symvers` (catches a tree configured differently from the running kernel), builds
   the module, then checks: no undefined symbol, `vermagic=2.6.17.14ReadyNAS mod_unload
   gcc-3.3`, no hardware `mul`/`div` instruction (`sdiv` is wrong on the IT3107);
5. gets the result back with `debugfs` (`output-relay/padre_relay.ko`, `build.log`, `qemu.log`).

`Module.symvers` holds the CRCs of the symbols the module imports, read from the
`__ksymtab`/`__kcrctab` tables of the stock kernel. They are plain numbers; the ones the
guest can recompute are identical. A new kernel symbol used by the module needs its CRC
added there (modpost then stops with `undefined!` until it is).

Host requirements: `docker`, `e2fsprogs` (`mke2fs -d`, `debugfs`), `unzip`, `curl`. Nothing in
git is a binary; the built files stay in `output-relay/`.

### The add-ons

RAIDiator 4.1 add-on format (same as DIET's): a 512-byte header
`addon::name=NAME,version=V,time=EPOCH,size=N,md5sum=MD5,unencrypted=1\n`, zero padded
(bytes 384–511 would hold NETGEAR's signature: RAIDiator warns that the add-on is not signed
and installs it anyway), followed by an uncompressed tar with `install.sh`. `size` and
`md5sum` are those of everything after the header. Without `unencrypted=1`, linuxrc would
"decrypt" the tar into garbage. Frontview stores the upload, reboots, linuxrc extracts it into
`/tmp/addons/NAME`, rc3 runs `sh install.sh` there; `relay-init` (and DIET's switch) let
RAIDiator start for that boot.

- `ReadyNasNextGen_relay_<v>.bin` (`addon/install.sh`): checks the model (Duo) and the kernel
  (2.6.17), copies `/relay/{padre_relay.ko,relay-switch,relay-init}`, keeps the current
  `/sbin/init` as `/sbin/init.before-relay` and installs `relay-init` as `/sbin/init`. Every
  file is written aside, checked, then moved into place: `/sbin/init` exists at every
  moment (linuxrc reinstalls the firmware when it is missing). Running it again only updates
  the files and keeps `/sbin/init.before-relay`, `/relay/disabled`, `/relay/dry-run`,
  `/relay/relay.log`. It also handles:
  - DIET installed: `/sbin/init` is DIET's boot switch; it becomes the previous init, so
    relay-init chains into it (DIET is not edited);
  - the hand-made install of the first tests (two lines added to DIET's switch, see below):
    the switch without these lines becomes the previous init;
  - DIET installed after the relay: DIET's installer saved `relay-init` as its
    `/sbin/init.real`; that file gets back the init behind it, then relay-init is put in
    front of DIET's switch again.

  Log: `/var/log/relay-install.log` (`/mnt/root/var/log/relay-install.log` from DIET). When
  installed at boot it restarts the NAS after 2 minutes; it deletes its own add-on directory.
- `ReadyNasNextGen_relay_remove_<v>.bin` (`addon/remove.sh`): moves `/sbin/init.before-relay`
  back to `/sbin/init` (byte for byte the previous init; to `/sbin/init.real` if DIET was
  installed after the relay), or removes the two hand-made lines, then deletes `/relay`.

```sh
  # Linux 6.18 on a USB stick (padre_relay): returns only if DIET should start
  [ "$MODE" = "diet" ] && [ -x /relay/relay-switch ] && /relay/relay-switch
```

Installing or updating DIET after the relay puts DIET's switch in front of `relay-init`:
the relay is then only tried when DIET hands over to RAIDiator. Install the relay add-on
again to put it back in front.

The scripts only use what RAIDiator's old userland has (`awk`, `grep -q`, `cp`, `mv`, `sh -n`;
no `grep -F`, `sed -i`, `mktemp`). `test-addon.sh` decodes and checks both headers, extracts
the tars like linuxrc and runs the scripts in simulated system volumes (`ROOT=` prefix), with
`sh` and `busybox sh`: stock RAIDiator, DIET installed, hand-made install, DIET installed after
the relay; install, install again (same files), remove, remove again, previous init back byte
for byte; refusal on another kernel. It also runs `relay-init`'s decisions with stubs.
`DIET_INIT=/path/init-weiche` uses DIET's real switch instead of the built-in stand-in.

## Using it

USB stick: the 6.18 partition must be **ext3** (or ext2), because 2.6.17 has no ext4 and the
boot marker lives on the stick. The 6.18 initramfs mounts it with its ext4 driver, which
handles ext3 without changing its features. 128-byte inodes for the 2.6.17 kernel:

```sh
mkfs.ext3 -I 128 -L nas618 /dev/sdX1
mount /dev/sdX1 /mnt && mkdir /mnt/rootfs-6.18 /mnt/boot
tar -xpf output-rapide/images/rootfs.tar -C /mnt/rootfs-6.18
cp output-rapide/images/vmlinux.bin /mnt/boot/
(cd /mnt/boot && md5sum vmlinux.bin > vmlinux.bin.md5)
umount /mnt
```

At every boot, linuxrc (RAIDiator's initrd) mounts the system volume, extracts uploaded
add-ons into `/tmp/addons/` and starts `/sbin/init` = `relay-init` as pid 1. `relay-init`
starts the previous init directly when `/relay/disabled` or `/.raidiator_once` (DIET's "start
RAIDiator once") exists, or when an add-on waits for installation (`/.new_addons`,
`/tmp/addons/*/install.sh`: RAIDiator's rc3 must install it, e.g. the remove add-on; only once
per set of waiting add-ons, so a broken add-on cannot block the relay). Otherwise it mounts
`/proc` (linuxrc unmounted it; unmounted again afterwards) and runs `relay-switch`, which
returns only when the previous init should start:

1. returns at once if `/.relay_skip_once` exists (removed when seen);
2. loads the USB storage drivers, not loaded yet at this point (RAIDiator loads them later in
   its rc scripts, DIET never does): `scsi_mod`, `sd_mod`, `ehci-hcd`, `usb-storage` from the
   system volume's `/lib/modules/2.6.17.14ReadyNAS/kernel/drivers/{scsi,usb/host,usb/storage}`;
3. waits up to 15 s for an `sd*` partition, mountable as ext3/ext2, holding
   `rootfs-6.18/sbin/init`; none → previous init;
4. on the stick: `rootfs-6.18/.relay_skip_once` → removed, previous init once (can be created
   from 6.18: `touch /.relay_skip_once`); `rootfs-6.18/.relay_pending` still there → the last
   6.18 boot did not complete: removed, previous init this time;
5. checks `boot/vmlinux.bin` against `vmlinux.bin.md5` (if present), loads the module, stages
   the image and runs the trampoline in copy-only mode (`test`); any refusal → previous init;
   `/relay/dry-run` → stops here, previous init;
6. remounts `/` read-only, writes `rootfs-6.18/.relay_pending`, unmounts the stick, `go`.

On the 6.18 side, `S99relay-confirm` (last init script) removes `/.relay_pending`: the boot
is complete. Each boot is logged in `/relay/relay.log` on the system volume.

Back to RAIDiator (or DIET): **cut the power** after a failed 6.18 boot (nothing persistent
is changed by the module; the next power-on starts the previous init), remove the stick,
or `touch /.relay_skip_once` in 6.18 (once). Never relay again: `/relay/disabled` on the
system volume (`touch /relay/disabled` from RAIDiator over SSH, `/mnt/root/relay/disabled`
from DIET), or the remove add-on.

## Module interface

```sh
insmod padre_relay.ko [max_image_mb=32] [shutdown=1] [pci_swap=0]
cat vmlinux.bin > /proc/padre_relay/image      # staged in free pages
cat /proc/padre_relay/control                  # checks, header, machine registers
echo test [size] > /proc/padre_relay/control   # everything but the jump
echo go [size]   > /proc/padre_relay/control   # does not return
echo clear       > /proc/padre_relay/control   # drop the staged image
```

Checks before `test`/`go` (refused with `EINVAL`, nothing changed): the size equals `size`
when given (incomplete write), the first word is a `ba` (trap table), a sparc32 `HdrS` boot
header in the first 64 KiB with a kernel version ≥ 3.x (rejects a 2.6 image), and `_end`
between the image end and the cacheable end of DDR. `test` runs the real trampoline from its
real page in copy-only mode into scratch buffers and compares chunk by chunk; it changes no
machine state.

## How the hand-over works

**Staging.** The image is written into free pages. Every page used (image, page list,
trampoline) lies **above** the copy range `[0x8000_4000, 0x8000_4000 + max_image_mb)`: the
allocator is asked again until it gives such pages, the refused ones are held until unload,
so the copy never overwrites its own source. 2.6.17 uses **16 KiB pages**: the page list has
one entry per 4 KiB chunk (4 per staged page).

**`go`, in C:**

1. `kernel_restart_prepare(NULL)` (through `kallsyms_lookup_name`): reboot notifiers (X-RAID
   clean flag…) and `device_shutdown()` (disk cache flush), what `reboot` does before
   `machine_restart()`.
2. A reboot would reset the chip, the relay does not: DMA masters are stopped by hand. GMAC:
   interrupt mask 0, RX/TX enable bits cleared. PCI (VIA USB): bus mastering off on every
   device (2.6.17's `ehci-hcd` has no `.shutdown`; its schedule would keep writing to memory).
3. Interrupts off; interrupt controller masked, timers stopped; `PCI_SWAP = 0` (iboot's
   value); iboot's parameter block copied back to 0x8000_0000 from 2.6.17's copy
   `padre_boot_param`; whole D-cache written back, I-cache tags cleared (2.6.17's own
   `flush_icache_range()` variants are not in kallsyms).
4. Call the trampoline.

**Trampoline** (position independent, leaf, traps off): PIL 15 → `R` on the console →
D-cache written back and invalidated (probe loop of 2.6.17's `padre_cache.c`) → I and D
caches off → `C` → uncached copy to 0x8000_4000 → page-table walk off (`PGT = 0`), TLB flush,
fixed map kept (`DE|IE`) → `WIM = 0`, `TBR = 0x8000_4000` → `J` → `jmp 0x80004000`. The 6.18
head then prints `L` (LP firmware loaded) or `l` (LP silent), `P`, `K`, then its log.

## iboot's exit state: what is assumed, and why

iboot is not read or decompiled: its exit state is deduced from the code that starts from it,
the GPL 2.6.17 `arch/padre/kernel/head.S`, `setup.c`, `pcic.c`, `mm/` and the 6.18 head and
`padre_*.c` of this repository.

| Item | State given to 6.18 | Reasoning |
|---|---|---|
| Entry | `jmp 0x80004000`, supervisor | `go 0x80004000`; both images start with `b gokernel` |
| MMU | fixed map on (`DE\|IE`), TLB flushed | 0x8000_4000 is already DDR when `go` jumps; both heads write `FL` then `DE\|IE` |
| Page-table walk | off (`PGT = 0`) | **assumption**: iboot has no page tables; 6.18 sets it in `srmmu_paging_init()` |
| Caches | off, clean (written back first) | both heads switch them off and clear the tags **without** write-back |
| PSR | ET=0, PIL=15, S=1 | 6.18 rewrites the whole PSR before using windows or traps; ET=0 makes an early fault visible (error mode) |
| WIM / TBR | 0 / 0x8000_4000 | set by the head; WIM=0 avoids an overflow trap with traps off |
| Boot parameters | 512 bytes at 0x8000_0000 | read by both heads and `padre_prom_setup()`; restored from `padre_boot_param` |
| Interrupts | masked, timers stopped | 6.18 masks and reprograms them anyway |
| LP coprocessor | running 2.6.17's LP firmware, idle | the 6.18 head reloads it (mailbox + `SYS_CTRL = 0x2000`, a start pulse). **Assumption**, shown by the `L`/`l` marker; same GPL firmware in both kernels |
| PCI bridge | `PCI_SWAP = 0`; +0x118/+0x11c left as 2.6.17 leaves them | 6.18 enumerates with iboot's 0, then writes 0x4444 like 2.6.17; `control` dumps +0x118/+0x11c |
| GMAC, SATA | stopped / idle | 6.18 resets the MAC and PHY and COMRESETs the SATA ports |

## Known risks

- **LP restart**: if 6.18 prints `l` instead of `L`, it runs with the 2.6.17 LP instance. Disk
  DMA is off by default (`padre_sata.dma=0`), so PIO disks still work.
- **Unknown DMA master still running** (proprietary drivers): random early 6.18 crash.
  `shutdown=1` covers what drivers do at reboot; GMAC and PCI are stopped by hand.
- **MMU/PGT assumption**: if 6.18 needed iboot's PGT, it would fault before `paging_init`
  (nothing after `K`).
- After `go`, a failure cannot return to 2.6.17: **power off/on** (2.6.17 boots again,
  `relay-switch` sees `.relay_pending` and starts the previous init).
- Before the jump `/` is remounted read-only and synced, as `reboot` would; the X-RAID driver
  runs its reboot notifier.

## Manual test (serial console on ttyS1, 9600 baud)

From RAIDiator (SSH) or DIET (the system volume is then `/mnt/root`). Under DIET, insmod the
USB modules from `/mnt/root/lib/modules/…` by hand to see the stick (USB disks are `sd*`, SATA
`hd*`).

1. **Inspect** (no risk): `insmod padre_relay.ko; cat vmlinux.bin > /proc/padre_relay/image;
   cat /proc/padre_relay/control` → `valid`, version 6.18.x, `mmu control …3` (DE|IE),
   `boot_param intact`.
2. **Dry run** (no risk): `echo test $(stat -c %s vmlinux.bin) > /proc/padre_relay/control` →
   `test OK: N chunks, 0 differ`; `rmmod padre_relay` must work.
3. **Jump**: `sync; mount -o remount,ro /c; sync` (data volume, like a hard reset of synced
   disks), load and stage as above, then
   `echo go <size> > /proc/padre_relay/control`. Expected: 2.6.17 shutdown messages, `RCJ`,
   `LPK`, the 6.18 boot. If it stops, note the last letter and cut the power. Variants:
   `shutdown=0`, `pci_swap=-1`.
4. **Boot switch, dry run**: install the add-on, `touch /relay/dry-run` on the system volume,
   reboot: `relay.log` shows the stick, the `control` state and "dry run"; the previous init
   starts.
5. **For real**: remove `/relay/dry-run`, reboot.

## Possible extensions

- The 6.18 head could reset the LP explicitly (if `l` is seen); `padre_pci` could set the
  bridge +0x118/+0x11c to iboot's 0xf if USB behaves differently after a relay.
