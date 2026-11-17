# ReadyNasNextGen

A modern system to bring the **NETGEAR ReadyNAS Duo v1** back to life: Linux 6.18, file
sharing for Windows/macOS (SMB) and Linux (NFS), and a web administration interface, without
touching the original firmware.

> **Experimental project.** It boots and serves files, but it is still started from a PC at
> every boot (see [Current limitations](#current-limitations)). Keep a backup of your data.

## What you get

- **Network shares**: SMB 3 (Windows, macOS, Linux, through ksmbd) and NFS v3/v4.
- **Web interface** over HTTPS (French, German, English), derived from
  [DIET](https://github.com/mfe-/ReadyNASDuoSparc): NAS status, disks, shares, users,
  services, logs.
- **Services**: MiniDLNA (TVs, media players), automatic discovery on the network
  (`<name>.local`), per-user rsync and WebDAV.
- **Your existing X-RAID disks** are used as they are, read-only by default; a new RAID can be
  created as a standard Linux RAID1 (md).
- **Temperature-controlled fan**: the NAS stays quiet when idle.
- **Hardware clock** read at boot, then kept accurate over the network (NTP).
- The **original firmware stays intact**: a normal reboot starts RAIDiator or DIET again.

## Required hardware

- A **ReadyNAS Duo v1** (Infrant SPARC processor; the Duo v2 is different hardware).
- A **USB stick** of at least 1 GB, plugged into the NAS.
- A **3.3 V USB-to-serial adapter** connected to the NAS internal serial header (9600 baud).
- A **Linux PC** on the same network, with Docker (TFTP server) and what is needed to build
  the system (see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#construire), ~15 GB free).

## Installation

1. **Build the system** on the PC:
   ```sh
   git clone --recursive https://github.com/beudbeud/ReadyNasNextGen.git
   cd ReadyNasNextGen
   make rapide        # downloads the prebuilt toolchain, then builds
   ```
   Output in `output-rapide/images/`: `vmlinux.k3` (the kernel) and `rootfs.tar` (the system).

2. **Prepare the USB stick**: one ext4 (or ext3) partition, then, as root, extract the system
   into an **empty** `rootfs-6.18` directory at its root:
   ```sh
   mount /dev/sdX1 /mnt
   mkdir /mnt/rootfs-6.18
   tar -xpf output-rapide/images/rootfs.tar -C /mnt/rootfs-6.18
   umount /mnt
   ```
   Plug the stick into the NAS. To update, extract into a new empty directory rather than over
   the previous system.

3. **Boot the NAS on the new system**: start the TFTP server
   (`tools/tftp-server.sh output-rapide/images`), open the serial console, power on the NAS and
   interrupt `iboot` during boot. At the `iboot>` prompt:
   ```
   tftp <NAS-MAC> <NAS-IP> <PC-IP> vmlinux.k3 0x80004000
   go 0x80004000
   ```
   `tools/iboot-cmd.py` does these steps automatically. The system boots from the stick in a
   few seconds.

4. **First access**: log in over SSH (`ssh root@<NAS-IP>`), set the web interface password with
   `diet-webpass`, then open `https://<NAS-IP>/` (user `admin`; accept the self-signed
   certificate).

## Your data (X-RAID)

Disks formatted by the original firmware (X-RAID) are detected and mounted on `/c`
**read-only** by default: nothing is written to your data. Before any mount, the system
checks the mirror state (failed disk, unclean shutdown, mismatched superblocks, unfinished
synchronisation) and refuses when in doubt.

Writing to an X-RAID volume (a switch in the Storage card of the web interface) and migrating
to a standard Linux RAID1 are possible; they are described, with their precautions, in
[docs/XRAID.md](docs/XRAID.md).

## Current limitations

- **Booting from the PC**: every boot needs the serial adapter and the TFTP server.
  Standalone boot (without a PC) is being studied.
- **Writing to an X-RAID volume**: reading is validated; writing (Storage card switch) has
  only been tried in simulation so far.

## Going back to the original system

Just reboot the NAS normally: the original firmware boots from its flash memory, which this
project never modifies.

**Never write to the flash** (`iboot` NAND write commands, `/dev/mtd*`): a corrupted flash
makes the NAS unusable without recovery hardware.

## Further reading

The detailed documentation is in French:

- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): build, toolchain, detailed porting status,
  kernel parameters, source tree.
- [docs/DIET.md](docs/DIET.md): the web interface and its differences from DIET.
- [docs/XRAID.md](docs/XRAID.md): using X-RAID disks, writing, migrating to md.
- [FEASIBILITY.md](FEASIBILITY.md): initial study.

## Credits and licences

- Kernel, drivers and scripts: **GPL-2.0** (see `LICENSE`), written from the GPL sources of
  the 2.6.17 kernel published by NETGEAR; the LP coprocessor firmware
  (`arch/sparc/kernel/padre_lpram.c`) comes from the same GPL sources.
- Web interface: derived from [DIET](https://github.com/mfe-/ReadyNASDuoSparc) by davemmi
  (Duo v1 support: [mfe-/ReadyNASDuoSparc#16](https://github.com/mfe-/ReadyNASDuoSparc/pull/16)).
  The original repository declares no licence, so this code is **not** under this repository's
  GPL-2.0 (see [docs/DIET.md](docs/DIET.md#origine-et-licence)).
- `readynas_crypto`: GPL-2.0+ (Henrik Nordström); `des.c`: LGPL-2.1 (Christophe Devine).
- Buildroot, Linux and the built packages keep their own licences.

No proprietary Infrant/NETGEAR binary or code is included.
