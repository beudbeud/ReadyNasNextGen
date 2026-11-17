# ReadyNasNextGen

[![tests](https://github.com/beudbeud/ReadyNasNextGen/actions/workflows/tests.yml/badge.svg)](https://github.com/beudbeud/ReadyNasNextGen/actions/workflows/tests.yml)

A modern system to bring the **NETGEAR ReadyNAS Duo v1** back to life: Linux 6.18, file
sharing for Windows/macOS (SMB) and Linux (NFS), and a web administration interface, without
touching the original firmware.

> **Experimental project.** It boots on its own from a USB stick through the original
> firmware and serves files (see [Current limitations](#current-limitations)). Keep a backup
> of your data.

## What you get

- **Network shares**: SMB 3 (Windows, macOS, Linux, through ksmbd), and NFS v3/v4.
- **Web interface** over HTTPS (French, German, English), derived from
  [DIET](https://github.com/mfe-/ReadyNASDuoSparc): NAS status, disks, shares, users,
  services, logs.
- **Optional services**, each switched on from the web interface: NFS, MiniDLNA (TVs,
  media players), automatic discovery on the network (`<name>.local`), per-user rsync and
  WebDAV. Out of the box only SMB, the web interface and SSH run.
- **Your existing X-RAID disks** are used as they are, read-only by default, and stay
  readable by RAIDiator (its superblock is kept up to date). Planned: switching to a
  standard Linux RAID1 (md), disabled for now.
- **Temperature-controlled fan**: the NAS stays quiet when idle.
- **Hardware clock** read at boot, then kept accurate over the network (NTP).
- The **original firmware stays intact**: without the USB stick, the NAS starts RAIDiator
  again.

## Required hardware

- A **ReadyNAS Duo v1** (Infrant SPARC processor; the Duo v2 is different hardware).
- A **USB stick** of at least 1 GB, plugged into the NAS.
- The NAS running its original firmware, **RAIDiator 4.1.x** (DIET installed on top of it
  also works).
- A **Linux PC** to build the system and prepare the stick (see
  [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#build), ~15 GB free; Docker for the relay module).
- For development only: a **3.3 V USB-to-serial adapter** on the NAS internal serial header
  (9600 baud) and a TFTP server on the PC.

## Installation

The NAS keeps booting its original firmware from flash; on the system disk, the **relay**
(a RAIDiator add-on) hands the NAS over to Linux 6.18 on the USB stick (details in
[board/readynas-duo-v1/relay/](board/readynas-duo-v1/relay/README.md)). Without the stick, or
if 6.18 failed to boot last time, RAIDiator starts as usual.

1. **Build the system and the relay add-ons** on the PC:
   ```sh
   git clone --recursive https://github.com/beudbeud/ReadyNasNextGen.git
   cd ReadyNasNextGen
   make rapide        # downloads the prebuilt toolchain, then builds
   make relay         # relay module for the original kernel (Docker + QEMU, ~10 min)
   make relay-addon   # RAIDiator add-ons, checked on the PC
   ```
   Output: `output-rapide/images/vmlinux.bin` (the kernel), `rootfs.tar` (the system), and
   the add-ons `output-relay/ReadyNasNextGen_relay_<version>.bin` and
   `ReadyNasNextGen_relay_remove_<version>.bin`.

2. **Prepare the USB stick** on the PC: one **ext3** partition (the original kernel cannot
   read ext4, and the relay reads the stick), then, as root:
   ```sh
   mkfs.ext3 -I 128 -L nas618 /dev/sdX1
   mount /dev/sdX1 /mnt
   mkdir /mnt/rootfs-6.18 /mnt/boot
   tar -xpf output-rapide/images/rootfs.tar -C /mnt/rootfs-6.18
   cp output-rapide/images/vmlinux.bin /mnt/boot/
   (cd /mnt/boot && md5sum vmlinux.bin > vmlinux.bin.md5)
   umount /mnt
   ```
   To update later, use the web interface (below); by hand, extract into a new empty
   `rootfs-6.18` rather than over the previous system, and copy the new `vmlinux.bin`
   (and its `.md5`).

3. **Install the relay add-on** `ReadyNasNextGen_relay_<version>.bin`, in either of two ways:

   - **From RAIDiator's web interface (Frontview)**: **System → Update → Local**, select the
     `.bin`, **Upload and verify image** (RAIDiator warns that the add-on is not signed by
     NETGEAR: expected), then **Perform System Update**, and restart the NAS when asked.
     Frontview only speaks TLS 1.0 with an old cipher: recent browsers refuse to connect, so
     you may need an old browser, or the script below.
   - **From the PC with the script** (no browser needed):
     ```sh
     sh tools/frontview-upload.sh <NAS-IP> ReadyNasNextGen_relay_<version>.bin
     ```
     It asks for the Frontview `admin` password, uploads and verifies the add-on, asks
     before performing the update, then restarts the NAS as Frontview's **System → Shutdown**
     page would. Without a terminal, set `FRONTVIEW_PASSWORD=…` and `FRONTVIEW_YES=1`;
     `FRONTVIEW_NO_REBOOT=1` skips the restart (do it yourself: power button or Frontview).

   RAIDiator does not restart by itself after **Perform System Update**. On the next boot it
   installs the add-on, then the NAS restarts once more by itself about 2 minutes later: wait
   for both restarts, without powering it off. Install log on the NAS: `/var/log/relay-install.log`. (With DIET installed, start
   RAIDiator once from DIET to reach Frontview; the relay then starts before DIET's own boot
   switch.)

4. **Plug the stick into the NAS and restart it.** The original kernel starts, then Linux 6.18
   from the stick. Without the stick, RAIDiator (or DIET) starts as before.

5. **First access**: log in over SSH (`ssh root@<NAS-IP>`), set the web interface password with
   `diet-webpass`, then open `https://<NAS-IP>/` (user `admin`; accept the self-signed
   certificate).

### Updating

`make update-package` builds `readynasng-update-<version>.tar` (and its `.sha256`) from
`output-rapide/images`. In the web interface, **Settings → System update**: upload it (or
give its GitHub release address and SHA-256), then **Restart to try it**. The new version
goes into the second system slot of the stick with the settings of this NAS; if it does not
start completely (cut the power if it hangs), the next power-on goes back to the current
version. **Switch to the other version** goes back to the previous one. Needs the relay
add-on 1.1 or later (`make relay-addon`, installed like step 3). Details:
[docs/DIET.md](docs/DIET.md#system-update-settings-page).

### Development: booting by TFTP

Without the relay, 6.18 can be started from the PC: start the TFTP server
(`tools/tftp-server.sh output-rapide/images`), open the serial console, power on the NAS and
interrupt `iboot` during boot. At the `iboot>` prompt:
```
tftp <NAS-MAC> <NAS-IP> <PC-IP> vmlinux.k3 0x80004000
go 0x80004000
```
`tools/iboot-cmd.py` does these steps automatically. The stick may then also be ext4.

## Your data (X-RAID)

Disks formatted by the original firmware (X-RAID) are detected and mounted on `/c`
**read-only** by default: nothing is written to your data. Before any mount, the system
checks the mirror state (failed disk, unclean shutdown, mismatched superblocks, unfinished
synchronisation) and refuses when in doubt.

Writing to an X-RAID volume (a switch in the Storage card of the web interface) is possible;
it is described, with its precautions, in [docs/XRAID.md](docs/XRAID.md). Migrating to a
standard Linux RAID1 is disabled for now ([docs/XRAID-MIGRATION.md](docs/XRAID-MIGRATION.md)).

## Current limitations

- **Boot through the original firmware**: the NAS boots RAIDiator's 2.6.17 kernel first, then
  the relay hands over to 6.18 (the stick must be ext3). The hand-over was validated on one NAS
  (started from DIET); the add-on's own boot switch is tested in simulation only so far. If a
  6.18 boot fails, the next power-on starts RAIDiator.
- **Writing to an X-RAID volume**: reading is validated; writing (Storage card switch) has
  only been tried in simulation so far.

## Going back to the original system

Unplug the stick and restart: RAIDiator starts. With the stick plugged in, RAIDiator once:
`touch /.relay_skip_once` in 6.18. Never relay again: `touch /relay/disabled` on the system
volume (from RAIDiator over SSH), or install `ReadyNasNextGen_relay_remove_<version>.bin` the
same way as the relay add-on: it puts the previous `/sbin/init` back and deletes `/relay`.
The flash memory, where the original firmware lives, is never modified.

**Never write to the flash** (`iboot` NAND write commands, `/dev/mtd*`): a corrupted flash
makes the NAS unusable without recovery hardware.

## Further reading

Detailed documentation:

- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): build, toolchain, detailed porting status,
  kernel parameters, source tree.
- [docs/DIET.md](docs/DIET.md): the web interface and its differences from DIET.
- [docs/XRAID.md](docs/XRAID.md): using X-RAID disks, writing, migrating to md.
- [board/readynas-duo-v1/relay/](board/readynas-duo-v1/relay/README.md): the relay (boot
  from the original kernel), its build and its add-ons.
- [FEASIBILITY.md](FEASIBILITY.md): initial study.

## Credits and licences

- Kernel, drivers, relay module and scripts: **GPL-2.0** (see `LICENSE`), written from the
  GPL sources of the 2.6.17 kernel published by NETGEAR; the LP coprocessor firmware
  (`arch/sparc/kernel/padre_lpram.c`) comes from the same GPL sources.
- Web interface: derived from [DIET](https://github.com/mfe-/ReadyNASDuoSparc) by davemmi
  (Duo v1 support: [mfe-/ReadyNASDuoSparc#16](https://github.com/mfe-/ReadyNASDuoSparc/pull/16)).
  The original repository declares no licence, so this code is **not** under this repository's
  GPL-2.0 (see [docs/DIET.md](docs/DIET.md#origin-and-licence)).
- `readynas_crypto`: GPL-2.0+ (Henrik Nordström); `des.c`: LGPL-2.1 (Christophe Devine).
- Buildroot, Linux and the built packages keep their own licences.

No proprietary Infrant/NETGEAR binary or code is included.
