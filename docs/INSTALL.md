# Installation details

The [README](../README.md) gives the quick install from a release image. This page
covers building the system yourself, preparing the stick by hand, booting by TFTP for
development and going back to the original system.

## How it boots

The NAS keeps booting its original firmware from flash. On the system disk, the
**relay** (a RAIDiator add-on) hands the NAS over to Linux 6.18 on the USB stick
(details in [board/readynas-duo-v1/relay/](../board/readynas-duo-v1/relay/README.md)).
Without the stick, or if 6.18 failed to boot last time, RAIDiator starts as usual.

## Release image

The image holds one ext3 partition (label `usbroot`) of about 1 GB. On a bigger stick
it can be grown from Linux: `sudo growpart /dev/sdX 1` (or `parted /dev/sdX resizepart
1 100%`), then `sudo e2fsck -f /dev/sdX1 && sudo resize2fs /dev/sdX1`. It must stay
ext3: the original kernel cannot read ext4, and the relay reads the stick.

`make stick-image` builds the same image from your own build (`output-rapide/images`,
no root needed; `VERSION=…`, `SIZE_MB=…`).

## Building it yourself

1. **Build the system and the relay add-ons** on a Linux PC (~15 GB free, Docker for
   the relay module; [DEVELOPMENT.md](DEVELOPMENT.md#build)):
   ```sh
   git clone --recursive https://github.com/beudbeud/ReadyNasNextGen.git
   cd ReadyNasNextGen
   make rapide        # downloads the prebuilt toolchain, then builds
   make relay         # relay module for the original kernel (Docker + QEMU, ~10 min)
   make relay-addon   # RAIDiator add-ons, checked on the PC
   ```
   Output:
   - `output-rapide/images/vmlinux.bin`, the kernel;
   - `output-rapide/images/rootfs.tar`, the system;
   - the add-ons `output-relay/ReadyNasNextGen_relay_<version>.bin` and
     `ReadyNasNextGen_relay_remove_<version>.bin`.

2. **Prepare the USB stick** on the PC with one **ext3** partition, then, as root:
   ```sh
   mkfs.ext3 -I 128 -L usbroot /dev/sdX1
   mount /dev/sdX1 /mnt
   mkdir /mnt/rootfs-6.18 /mnt/boot
   tar -xpf output-rapide/images/rootfs.tar -C /mnt/rootfs-6.18
   cp output-rapide/images/vmlinux.bin /mnt/boot/
   (cd /mnt/boot && md5sum vmlinux.bin > vmlinux.bin.md5)
   umount /mnt
   ```
   Later updates go through the web interface (README, *Updating*). To update by hand,
   extract into a new, empty `rootfs-6.18` rather than over the previous system, and
   copy the new `vmlinux.bin` and its `.md5`.

3. **Install the relay add-on** and plug the stick in, as in the README.

## The relay add-on

There are two ways to install `ReadyNasNextGen_relay_<version>.bin`.

**From RAIDiator's web interface (Frontview):**
1. **System → Update → Local**, select the `.bin`.
2. **Upload and verify image**. RAIDiator warns that the add-on is not signed by
   NETGEAR: this is expected.
3. **Perform System Update**, then restart the NAS when asked.

Frontview only speaks TLS 1.0 with an old cipher, and recent browsers refuse to connect.
You may need an old browser, or the script below.

**From the PC with the script** (no browser needed):
```sh
sh tools/frontview-upload.sh <NAS-IP> ReadyNasNextGen_relay_<version>.bin
```
It asks for the Frontview `admin` password, uploads and verifies the add-on, and asks
before performing the update. It then restarts the NAS, as Frontview's **System →
Shutdown** page would. Without a terminal, set `FRONTVIEW_PASSWORD=…` and
`FRONTVIEW_YES=1`. `FRONTVIEW_NO_REBOOT=1` skips the restart, which you then do
yourself (power button or Frontview).

RAIDiator does not restart by itself after **Perform System Update**. On the next boot
it installs the add-on, then the NAS restarts once more by itself about 2 minutes later.
Wait for both restarts, and do not power it off. The install log is on the NAS, in
`/var/log/relay-install.log`.

With DIET installed, start RAIDiator once from DIET to reach Frontview. The relay then
starts before DIET's own boot switch.

## Other first-access methods

The README covers the **First setup** page. Two other ways:
- The serial console: root, no password. Run `passwd`, then `diet-webpass` for the web
  password.
- An SSH key copied to the stick from a Linux PC, before the first boot:
  ```sh
  sudo mount /dev/sdX1 /mnt
  sudo install -d -m 700 /mnt/rootfs-6.18/root/.ssh
  sudo install -m 600 ~/.ssh/id_ed25519.pub /mnt/rootfs-6.18/root/.ssh/authorized_keys
  sudo umount /mnt
  ```

## Development: booting by TFTP

Without the relay, 6.18 can be started from the PC. You need a 3.3 V USB-to-serial
adapter on the NAS internal serial header (9600 baud).
1. Start the TFTP server: `tools/tftp-server.sh output-rapide/images`.
2. Open the serial console.
3. Power on the NAS and interrupt `iboot` during boot.
4. At the `iboot>` prompt:
   ```
   tftp <NAS-MAC> <NAS-IP> <PC-IP> vmlinux.k3 0x80004000
   go 0x80004000
   ```

`tools/iboot-cmd.py` does these steps automatically. The stick may then also be ext4.

## Going back to the original system

- **Once:** unplug the stick and restart, and RAIDiator starts. With the stick plugged in,
  `touch /.relay_skip_once` in 6.18 starts RAIDiator for one boot.
- **For good:** `touch /relay/disabled` on the system volume (from RAIDiator over SSH).
  Or install `ReadyNasNextGen_relay_remove_<version>.bin` the same way as the relay
  add-on: it puts the previous `/sbin/init` back and deletes `/relay`.

The flash memory, where the original firmware lives, is never written. A read-only
backup of it from Linux 6.18 is shelved for now
([DEVELOPMENT.md](DEVELOPMENT.md#nand-flash-read-only-backup-shelved)).

**Never write to the flash** (`iboot` NAND write commands, `/dev/mtd*`): a corrupted
flash makes the NAS unusable without recovery hardware.
