# ReadyNasNextGen

[![tests](https://github.com/beudbeud/ReadyNasNextGen/actions/workflows/tests.yml/badge.svg)](https://github.com/beudbeud/ReadyNasNextGen/actions/workflows/tests.yml)

A modern system to bring the **NETGEAR ReadyNAS Duo v1** back to life: Linux 6.18, file
sharing for Windows/macOS (SMB) and Linux (NFS), and a web administration interface,
without touching the original firmware.

> **Experimental project.** It boots on its own from a USB stick through the original
> firmware and serves files (see [Limitations](#limitations)). Keep a backup of your data.

## Features

- **Network shares**: SMB 3 (Windows, macOS, Linux, through ksmbd) and NFS v3/v4. Reads
  reach about 30 MiB/s, writes about 12 MiB/s; signed SMB (Windows and macOS by default)
  is slower, about 4 MiB/s ([measurements](docs/DEVELOPMENT.md#measured-throughput)).
- **Web interface** over HTTPS (English, French, German), derived from
  [DIET](https://github.com/mfe-/ReadyNASDuoSparc): NAS status, disks, shares, users,
  services, logs, SMART reports and disk self-tests.
- **Optional services**, each switched on from the web interface: NFS, MiniDLNA (TVs,
  media players), network discovery (`<name>.local`), per-user rsync and WebDAV. Out of
  the box, only SMB, the web interface and SSH run.
- **Your existing disks**, used as RAIDiator left them:
  - **X-RAID**: mounted read-only by default, or read-write behind a switch. RAIDiator's
    superblock is kept up to date, so RAIDiator can still read the disks.
  - **Flex-RAID** (X-RAID switched off): RAID 1, RAID 0 and RAID 5 volumes. They are
    read-only by default, or read-write behind a switch. A RAID 1 or RAID 5 is
    resynchronised after a power cut, and a failed disk is recorded the way RAIDiator does
    it.

  Details: [docs/XRAID.md](docs/XRAID.md).
- **System updates from the web interface**, with a trial boot and a way back to the
  previous version.
- **Temperature-controlled fan**, and the hardware clock kept accurate over the network
  (NTP).
- **The original firmware stays intact**: without the USB stick, the NAS starts RAIDiator
  again.

## Requirements

- A **ReadyNAS Duo v1** (Infrant SPARC processor). The Duo v2 is different hardware.
- The NAS running its original firmware, **RAIDiator 4.1.x**. DIET installed on top of it
  also works.
- A **USB stick** of at least 1 GB, plugged into the NAS.
- A PC to write the stick image. Building the system yourself needs a Linux PC
  ([docs/INSTALL.md](docs/INSTALL.md#building-it-yourself)).

## Installation

1. **Download** from the [releases](https://github.com/beudbeud/ReadyNasNextGen/releases)
   page `readynasng-stick-<version>.img.xz` and `ReadyNasNextGen_relay_<version>.bin`,
   and check them against `SHA256SUMS`.
2. **Write the image** to the USB stick, with [Etcher](https://etcher.balena.io/) or on
   Linux. Replace `sdX` with the stick: every byte on it is lost.
   ```sh
   xzcat readynasng-stick-<version>.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync
   ```
3. **Install the relay add-on** `ReadyNasNextGen_relay_<version>.bin` on the NAS. It hands
   the NAS over from the original kernel to Linux 6.18 on the stick. Either way:
   - in RAIDiator's web interface (Frontview): **System → Update → Local**, **Upload and
     verify image**, then **Perform System Update** and restart. RAIDiator warns that the
     add-on is not signed by NETGEAR: this is expected. Recent browsers no longer connect
     to Frontview (TLS 1.0).
   - or from the PC: `sh tools/frontview-upload.sh <NAS-IP> ReadyNasNextGen_relay_<version>.bin`.

   After the restart, RAIDiator installs the add-on and restarts once more by itself,
   about 2 minutes later. Wait for both restarts.
4. **Plug the stick into the NAS and restart it.** The original kernel starts, then
   Linux 6.18 from the stick.

Building the system yourself, preparing the stick by hand, booting by TFTP, more on the
relay add-on: [docs/INSTALL.md](docs/INSTALL.md).

## First boot

The system ships with no password and no key. The NAS creates its SSH host keys and its
HTTPS certificate at first boot.
1. Open `https://<NAS-IP>/` from your local network and accept the self-signed
   certificate.
2. While no administrator exists, the interface shows a **First setup** page, without
   login. On it, set:
   - the **administrator password** of the web interface (user `admin`) and the NAS name;
   - optionally, for **SSH** (user `root`), a root password and/or your public key, for
     example the contents of `~/.ssh/id_ed25519.pub`. SSH refuses root until one of the
     two is set. Both can also be set later, in **System → SSH access**.
3. The page answers only once: as soon as the administrator password is saved, the whole
   interface asks for the password. Do this right after the first boot, from a network
   you trust. The interface only answers private addresses.

Other ways in (serial console, an SSH key copied to the stick):
[docs/INSTALL.md](docs/INSTALL.md#other-first-access-methods).

## Updating

1. Download `readynasng-update-<version>.tar` from the releases, or build it with
   `make update-package`.
2. In the web interface, open **System → System update**. Upload the file, or give its
   GitHub release address and SHA-256.
3. Click **Restart to try it**.

The new version goes into the second system slot of the stick, with this NAS's settings.
If it does not start completely, the next power-on goes back to the current version (cut
the power if it hangs). **Switch to the other version** goes back to the previous one.
This needs the relay add-on 1.1 or later. Details:
[docs/DIET.md](docs/DIET.md#system-update-settings-page).

## Limitations

- **ReadyNAS Duo v1 only, validated on one NAS.** The 4-bay NV+ v1 (same processor) is
  not supported yet.
- **Boot through the original firmware**: the NAS boots RAIDiator's 2.6.17 kernel first,
  and the relay then hands over to 6.18. The stick must stay ext3. Not tested yet: the
  fallback after a power cut during a 6.18 boot.
- **Some disk operations still need RAIDiator**: replacing a disk and rebuilding the
  array, expanding a volume, and creating arrays. Start RAIDiator once for them
  ([docs/XRAID.md §6](docs/XRAID.md#6-md-disabled-for-now-replacement-and-expansion)).
- **X-RAID after an unclean stop** (power cut, forced restart while writing): with writing
  switched on, `/c` comes back read-write and its mirror is copied again from the base
  disk, as RAIDiator does. This takes several hours on big disks, and starts over if the
  NAS stops before the end. A disk pulled while writing has not been tested yet.
- **Flex-RAID**:
  - Only `/c` can hold shares; the other volumes are reachable over SSH.
  - A RAID 5 with a disk missing is readable, but read-only.
  - After a power cut, a RAID 5 recomputes its parity: this takes hours on big disks.
  - A power cut under RAIDiator itself goes unnoticed.
- **Writing is new**: keep a backup of your data before switching it on, on X-RAID as well
  as on Flex-RAID.

## Documentation

- [docs/INSTALL.md](docs/INSTALL.md): building, preparing the stick by hand, the relay
  add-on, TFTP boot, going back to the original system.
- [docs/XRAID.md](docs/XRAID.md): X-RAID and Flex-RAID disks, writing, safeguards.
- [docs/DIET.md](docs/DIET.md): the web interface and its differences from DIET.
- [docs/API.md](docs/API.md): the web interface's API.
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): toolchain, porting status, kernel patches,
  measurements.
- [board/readynas-duo-v1/relay/](board/readynas-duo-v1/relay/README.md): the relay
  (booting from the original kernel) and its add-ons.
- [FEASIBILITY.md](FEASIBILITY.md): initial study.

## Credits and licences

- Kernel, drivers, relay module and scripts: **GPL-2.0** (see `LICENSE`). They are written
  from the GPL sources of the 2.6.17 kernel published by NETGEAR. The LP coprocessor
  firmware (`arch/sparc/kernel/padre_lpram.c`) comes from the same GPL sources.
- Web interface: derived from [DIET](https://github.com/mfe-/ReadyNASDuoSparc) by davemmi
  (Duo v1 support: [mfe-/ReadyNASDuoSparc#16](https://github.com/mfe-/ReadyNASDuoSparc/pull/16)).
  The original repository declares no licence, so this code is **not** under this
  repository's GPL-2.0 (see [docs/DIET.md](docs/DIET.md#origin-and-licence)).
- `readynas_crypto`: GPL-2.0+ (Henrik Nordström); `des.c`: LGPL-2.1 (Christophe Devine).
- Buildroot, Linux and the built packages keep their own licences.

No proprietary Infrant/NETGEAR binary or code is included.
