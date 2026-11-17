# DIET on Linux 6.18

The DIET web dashboard (project
[ReadyNASDuoSparc](https://github.com/mfe-/ReadyNASDuoSparc), 2.6.17 system) is
ported to the 6.18 system: it is the `package/diet` package, enabled in
`readynas_ng_defconfig` and `readynas_ng_rapide_defconfig`. The sources are
in `package/diet/src/`, laid out as on the target system.

## Origin and licence

- **DIET** was written by **davemmi** for the ReadyNAS NV+ v1 and published in the
  [mfe-/ReadyNASDuoSparc](https://github.com/mfe-/ReadyNASDuoSparc) repository
  ([PR #15](https://github.com/mfe-/ReadyNASDuoSparc/pull/15)).
- ReadyNAS Duo v1 support (X-RAID, languages, notifications…) comes from
  [mfe-/ReadyNASDuoSparc#16](https://github.com/mfe-/ReadyNASDuoSparc/pull/16).
- `package/diet/src/` is derived from this code (interface, API, scripts), adapted here to Linux 6.18.
- **Licence**: the original repository declares **no licence** so far. The code derived from
  DIET is therefore **not** covered by this repository's GPL-2.0; it remains subject to its
  author's rights. A licence will be stated here as soon as the original project has one.

## Getting started on the NAS

1. At first boot, `S50lighttpd` creates a self-signed HTTPS certificate
   (ECDSA P-256, 10 years, host name and eth0 address). No key is in the
   image. After a name or address change:
   `/etc/init.d/S50lighttpd newcert` then `restart`.
2. Over SSH, run `diet-webpass` (user `admin` by default) to
   choose the interface password (`/etc/lighttpd/htpasswd`). Without
   this file, all access is refused.
3. Open `https://<NAS address>/` (port 80 redirects to HTTPS).
   Access is limited to private networks.

## What changes compared with the old DIET

| Topic | Old DIET (2.6.17) | DIET on 6.18 |
|---|---|---|
| Web server | busybox httpd behind a static lighttpd | lighttpd alone: mbedTLS TLS, `mod_auth` (SHA-512 htpasswd), `mod_cgi` |
| Shares | Samba 3.6, `smb.conf` + `shares.conf`, `smbpasswd` | ksmbd: `/etc/ksmbd/ksmbd.conf`, `ksmbd.adduser` (password on standard input), `ksmbd.control -r` |
| NFS | RAIDiator programs in a chroot (`diet-nfs`) | kernel nfsd + nfs-utils 2.x: the interface edits `/etc/exports` and runs `exportfs -ra` |
| Storage | X-RAID (`/proc/xraid`), LVM `/dev/c/c` | md (`/proc/mdstat`, `mdadm --detail`), `df /c`, libata disks `sda`/`sdb` (bay = ata port); existing X-RAID through `nas-raid` (docs/XRAID.md); md: disabled for now (docs/XRAID-MIGRATION.md) |
| Temperatures | `smartctl` every 5 min | drivetemp (`/sys/block/sdX/device/hwmon/*/temp1_input`); `smartctl` used only if present |
| Fan | controlled by `diet-hwmon` | controlled by `padre-fan` (S03fan); the interface shows its state (`/var/run/fan.state`) and edits `/etc/fan.conf` (curve, period, thresholds), then restarts the service |
| `diet-hwmon` | control, SMART, history, alerts, emergency shutdown | monitoring only: history, SMART if present, Telegram alerts. The emergency shutdown is done by `padre-fan` |
| Power button | `diet-hotplug` (`/proc/sys/kernel/hotplug`) | `/sbin/hotplug` → `diet-hotplug` (CONFIG_UEVENT_HELPER): held 3 s = power off |
| Network | `/etc/diet-net.conf` + `S41diet-net` | `/etc/network/interfaces` (busybox ifupdown), applied at next boot |
| Time | `ntpd -q` at boot | `ntpd` in the background + "Update the time" button |
| Log | `/var/log/boot.log` | `/var/log/diet.log`, `/var/log/messages` (syslog), `dmesg` |

What is kept: the same tabs, the fr/de/en languages (page and
messages, `/etc/diet-lang`), Telegram notifications (token and
ID entered in the interface, stored in `/etc/diet-notify.conf`
on the NAS, never in the image), disk standby, LEDs
(bays, power), power off and reboot, `diet-status` on the
console.

Removed: everything specific to X-RAID, Samba 3.6, RAIDiator
(`zu-raidiator`, `init-weiche`, `install-weiche`), the flash, the LCD screen
(not on the Duo), `rsyncd`, LVM and `diet-import`.

## Services

"Services" card of the Shares tab (API: `GET ?a=services`,
`POST ?a=svc_set|dlna_set|dlna_scan|rsync_pw|rsync_c`, `X-Diet` header required).

| Service | What the interface sets | Files |
|---|---|---|
| MiniDLNA | on/off; displayed name (`friendly_name`); folders (`media_dir`, one per line, optional prefix `A,` `V,` `P,`, existing folders under `/c`, letters, digits, space, `-` and `_`, no link that leaves `/c`); "Rescan" (`S60minidlnad force-reload` = `minidlnad -R`) | `/etc/minidlna.conf` (`.bak` copy), database in `/var/lib/minidlna` |
| Avahi | on/off; the announced name (`<name>.local`) follows the NAS name (avahi is restarted when it changes) | `/etc/avahi/services/*.service` |
| rsync | on/off; user accounts (see below); administrator module `[c]` (all of `/c`, as root, account `sauvegarde`) **only if checked** (`RSYNC_C=1`), with its password and the command `rsync -av folder/ sauvegarde@<name>.local::c/backups/` | `/etc/rsyncd.conf` (generated), `/etc/rsyncd.secrets` (600) |
| WebDAV | on/off of the `S51webdav` instance; addresses `https://<name>.local/webdav/<user>/` and `/webdav/<share>/` | `/etc/lighttpd/webdav.conf` (generated), `/etc/lighttpd/htpasswd-users` |
| NFS | on/off of the kernel NFS server (`S60nfs`: statd, nfsd, mountd; running = nfsd threads in `/proc/fs/nfsd/threads`). Stopped: the "NFS exports" card says so and stays editable (`/etc/exports` written, `exportfs` not run: read again at start); "Restart NFS" of the Overview is disabled (`nfs_on` in `?a=status`, refused with 409) | `/etc/exports` |

State: running or stopped; for MiniDLNA, the number of indexed files
(audio, video, images) read from its status page `http://127.0.0.1:8200/status` (no
`sqlite3` on the NAS) and the size of `files.db`.

Persistence: `SVC_MINIDLNA`, `SVC_AVAHI`, `SVC_RSYNC`, `SVC_WEBDAV`, `SVC_NFS` in
`/etc/diet.conf` (`0` = stopped, `1` or missing = running). The shipped `diet.conf` sets
all five to `0`: out of the box only SMB (ksmbd), the web interface and SSH run, and rpcbind
(`S30rpcbind`) only starts with NFS. `S50avahi-daemon`,
`S60minidlnad`, `S60nfs` (which replace the Buildroot ones; `S60nfs` also stops
the nfsd kernel threads with `rpc.nfsd 0`, which the Buildroot `killall nfsd`
could not do; rpcbind is left running), `S61rsyncd` (in
`board/readynas-duo-v1/rootfs-overlay/etc/init.d/`) and `S51webdav` (diet
package) do not start a service set to `0`. A stopped service also loses its
Avahi announcement (`rsync.service`, `webdav.service` renamed to `.service.off`,
then `avahi-daemon -r`).

### WebDAV and rsync: local accounts

The users of the Shares tab have a single password for SMB,
WebDAV and rsync. When the API creates an account or changes its password
(`user_set`, password in the POST body), it writes it in one go:
ksmbd (`ksmbd.adduser`, standard input), `/etc/lighttpd/htpasswd-users`
(SHA-512 crypt through `mkpasswd`, `root:nas` 640, separate from the
interface's `/etc/lighttpd/htpasswd`) and `/etc/rsyncd.secrets`
(`root` 600). `user_del` removes the account everywhere (its folder is kept).
Never a password in the URL, the logs or the image. An account created
before this version has neither WebDAV nor rsync: the interface shows "set
the password again to enable WebDAV/rsync".

After each user or share change, the API regenerates:

- `/etc/rsyncd.conf`: one `[<name>]` module per user (`path =
  /c/home/<name>`, `uid`/`gid = <name>`, `auth users = <name>`,
  `munge symlinks`), one module per writable share (`uid = nas`,
  `gid = users`, `auth users` = all accounts; a share that has the
  name of a user has no module), and `[c]` only if
  `RSYNC_C=1`. Example: `rsync -av folder/ <name>@<nas>.local::<name>/`.
- `/etc/lighttpd/webdav.conf`, checked by `lighttpd -tt` before being put in
  place (otherwise the old one is kept and the message says so), then `S51webdav
  restart`. It is a **second lighttpd instance** running as the system user
  `nas` (created by `DIET_USERS` in `diet.mk`), on
  `127.0.0.1:8081`, with `umask 002` and `server.follow-symlink = "disable"`.
  The main lighttpd (root, HTTPS) forwards `/webdav` to it (`mod_proxy`,
  body streamed) and does not ask for the interface account on this path;
  the WebDAV instance authenticates:
  `/webdav/<name>/` = home folder, `"require" => "user=<name>"`;
  `/webdav/<share>/` = share, any local account (`valid-user`),
  read-only if the share is; everything else is refused.
  The interface administrator has no WebDAV access. `mod_webdav` does not
  submit the `Destination` header (COPY/MOVE) to `mod_auth`: each block
  refuses a destination outside its own space, or with `..` or
  `%2e`/`%2f`. `mod_extforward` (trusted proxy 127.0.0.1) gives the
  `https` scheme back to the instance so that the `Destination` matches.
  The interface lighttpd is never reloaded for WebDAV.

Permission model on `/c`:

| Folder | Owner, mode | Who writes |
|---|---|---|
| `/c/home` | `root:root` 755 | — |
| `/c/home/<name>` | `<name>:<name>` 2770 | `<name>` (SMB, rsync), `nas` (WebDAV): the personal group `<name>` (primary group of the account) has `nas` as its only other member; setgid + umask 002: WebDAV files are `nas:<name>` 664, writable by `<name>`; other accounts cannot enter |
| `/c/<share>` (created by the interface) | `root:users` 2777, no sticky bit | everyone (SMB guest or account, WebDAV `nas`, rsync `nas`): common space; ksmbd forces 0666/0777 |

A share created earlier (`nobody` 1777, sticky bit) stays as it is: an account
then cannot delete another account's files; to align it:
`chown root:users /c/<share> && chmod 2777 /c/<share>`.
A new account has its personal group as primary group (same number
as its uid if free); an account created earlier switches to it when its password
is set again. Refused names: those of a system group (`audio`, `video`,
`users`…), `sauvegarde`, `nas`, `c`, `home`, `webdav`, `root`.

## System update (Settings page)

The USB stick holds two **system slots**: `rootfs-6.18` (the first install) and
`rootfs-b`. One is active; the other holds the previous (or the next) version.
`nas-update` (`/usr/sbin`, called by the API) installs a new version into the slot that
is not active and has it tried once at the next restart:

1. **Package** (`make update-package`, from `output-rapide/images`):
   `readynasng-update-<version>.tar`, an uncompressed tar of `manifest` (`VERSION=`,
   `ROOTFS_KB=` room needed once extracted), `SHA256SUMS`, `rootfs.tar.gz` and
   `vmlinux.bin`, plus a `.sha256` file next to it.
2. **Upload** from the browser (`POST ?a=update_upload`, the body is the file): lighttpd
   streams it to the API (`server.stream-request-body = 2` for this URL only, nothing
   in `/tmp`, which is RAM), which writes it to `/update/package.tar` on the stick after
   checking the room left (16 MB margin). Or **download** (`?a=update_url`): only
   `https://github.com/…/releases/download/…` addresses, and the SHA-256 of the package
   is required (busybox wget checks no certificate). 512 MB at most.
3. **Check** in the background: the four members exactly, version and size in the manifest,
   SHA-256 of `rootfs.tar.gz` and `vmlinux.bin`, room (free + what the old slot takes ≥
   new slot + kernel + 16 MB). Any refusal leaves the active slot untouched.
4. **Extraction** into the other slot (deleted first, marked `.incomplete` until the end),
   kernel into `<slot>/boot/vmlinux.bin` (+ `.md5` for the relay), version into
   `<slot>/etc/system-version`.
5. **Settings of this NAS** copied into it: `diet.conf`, `fan.conf`, `exports`,
   `rsyncd.conf`, `rsyncd.secrets`, `minidlna.conf`, `nas-raid.conf`, `hostname`, `TZ`,
   `diet-lang`, `diet-notify.conf`, `network/interfaces`, `ksmbd/ksmbd.conf`,
   `ksmbd/ksmbdpwd.db`, `lighttpd/htpasswd`, `lighttpd/htpasswd-users`,
   `lighttpd/webdav.conf` (in `/etc`); the folders `/etc/dropbear` (host keys),
   `/etc/lighttpd/ssl` (certificate), `/root/.ssh`, `/var/lib/nas-raid`,
   `/var/lib/nas-update`; `passwd`, `group` and `shadow` merged by name (the lines of this
   NAS win: users, uids, passwords; system accounts new in the image are added); the
   Avahi announcements of stopped services stay `*.service.off`. They are copied again
   at shutdown (`S99relay-confirm stop`, `nas-update sync`), so a setting changed before
   the restart is not lost. Not copied: the MiniDLNA database (rebuilt), WebDAV locks.
6. **Trial**: `/boot/slot.try` names the slot. At the next power-on `relay-switch`
   boots it once (marker `.relay_pending` written in it first) with its own kernel; the
   6.18 initramfs mounts the same slot. When its boot completes, `S99relay-confirm`
   (`nas-update confirm`) makes it the active slot (`/boot/slot`). Otherwise (hang: cut
   the power; refused kernel; any failure) the next power-on finds the marker, drops the
   trial, writes `/boot/slot.failed` (shown in the interface) and boots the active slot
   again, not RAIDiator.

**Going back**: “Switch to the other version” copies the settings into the other slot
and tries it the same way (so a failed version can also be tried again). “Cancel the
trial” removes `/boot/slot.try`. Nothing is installed while the running system is not
the active slot (a trial that has not completed yet).

The trial needs the relay add-on **1.1** (`relay-switch` with slots, which writes
`/boot/relay-slots` on the stick): with 1.0 the version is installed but not scheduled,
and the interface asks for the new add-on. A stick of the first install (only
`/rootfs-6.18` and `/boot/vmlinux.bin`) boots unchanged with either. Installing into
`rootfs-6.18` removes `/boot/vmlinux.bin`, unused from then on; going back to the relay
add-on 1.0 afterwards would no longer boot 6.18 (RAIDiator starts).

Written: only the stick that holds `/` (checked: ext2/3/4 on a USB disk, mounted a second
time in `/var/run/nas-update/`), never the data disks nor the flash. Log:
`/var/lib/nas-update/log` (Logs page, “Update log”).

## Storage: writing to the X-RAID

The "Storage /c" card shows the X-RAID state as RAIDiator sees it (superblock
clean or in use, each disk online/faulty/ready, counters, sections in sync) and,
in X-RAID mode only (not in md), the "Allow writing on the X-RAID" switch,
checked if `XRAID_RW=yes` in `/etc/nas-raid.conf` (`xraid_rw` field of
`GET ?a=storage`). It is disabled when the superblock writer `xraid-sb` is
missing (`sb_writer` field): read-only only. md actions (migrate, create) are
disabled for now: `POST ?a=raid_plan|raid_run` answer 409
(docs/XRAID-MIGRATION.md).

- **Enable**: warning dialog (writing through the kernel ext4 driver to the RAIDiator ext3 with
  16 KB blocks, backup recommended), checkbox **and**
  the word `WRITE` to type; `POST ?a=xraid_rw` with `on=1&confirm=WRITE&yes=1`.
- **Disable**: simple confirmation, `on=0`.
- The API writes `XRAID_RW=yes|no` to `/etc/nas-raid.conf` (other lines
  kept, temporary file then `mv`, `.bak` copy), stops WebDAV, rsync,
  MiniDLNA, NFS and ksmbd, runs `nas-raid remount`, then restarts these services
  (their scripts respect `SVC_*=0`).
- `nas-raid remount` first unmounts `/c` alone: if a file is still
  open there (`umount` refused), nothing is undone, the volume stays mounted as it is,
  the old setting is restored and the API answers 409. This refusal was preferred to a
  forced unmount.
- The nas-raid safeguards decide: if the volume stays read-only
  (unclean shutdown, mismatched mirror…), the response and the card give the mode
  and the reason ("writing requested, refused by the safeguards").
- The remount is done during the request (reading the samples of both
  disks, mounting): a few tens of seconds on the NAS.

## Speed: collector and cache

Starting a program costs ~60 ms on this SPARC and floating point is emulated by
the kernel. So:

- **Collector**: `S95diet` starts the API itself in the background
  (`DIET_COLLECT=1 /www/cgi-bin/api`, pid in `/var/run/diet/pid`). It writes
  ready JSON responses to `/var/run/diet/<key>.json` (temporary file
  then `mv`): `status` every 5 s and the rest (`storage services shares nfs
  sys users config`) every 60 s when the interface is open (request seen
  less than 2 min ago); otherwise 60 s and 5 min. `all.json` = status + storage +
  history, read in one request when the page loads.
- **Read**: at the top of the API, before the rest of the script, a GET of these keys
  does `exec cat` of the file if the collector is running (shell built-in commands
  only). Without a collector or without a file: direct computation, as before.
- **Wake-up**: FIFO `/var/run/diet/wake` (wait through `read -t`, no
  process). The read path writes `seen` to it when the collector is idle (no
  `active` file); a successful POST clears the cache, sets `invalid` (a computation
  started earlier is discarded) and writes `all`: everything is recomputed at once.
- **Computation**: `/proc`, `/sys` and the configuration files are read by the
  shell (`read`, variable expansions, `$((…))` in 64-bit integers):
  `status` starts 2 programs (`ifconfig`, `df`) instead of about sixty;
  no `printf %f` and no computation in awk.
- **busybox**: `FEATURE_SH_STANDALONE`, `FEATURE_PREFER_APPLETS` and
  `FEATURE_SH_NOFORK` (in `DIET_BUSYBOX_CONFIG_FIXUPS`): ash starts its applets
  without searching the `PATH`, and the "nofork" applets (`cat`, `echo`,
  `printf`, `test`…) without creating a process. A program with the same name as an
  applet is only started through its full path.

`/etc/init.d/S95diet restart-collector` restarts the collector.

## Packages and applets used

lighttpd (with mbedTLS; only `gen_key` and `cert_write` are kept among
the mbedTLS programs), ksmbd-tools, nfs-utils, mdadm. The package enables
`ntpd` and HTTPS wget (Telegram) in busybox. The rest is busybox
(`sh`, `awk`, `sed`, `hdparm`, `mkpasswd`, `start-stop-daemon`…).
`smartctl` is not in the image: smartmontools needs a C++ toolchain,
which neither the internal toolchain nor the prebuilt toolchain has.

## Test on the PC

    sh package/diet/tests/test-api.sh

creates a fake root (`DIET_ROOT`) with simulated `/proc`, `/sys` and `/etc`
(healthy then degraded RAID1, drivetemp, ksmbd.conf, exports), replaces
the NAS commands with scripts that record their arguments, calls
the API as lighttpd would and checks the JSON and the written files.
System updates run against a folder standing for the USB stick (`DIET_STICK`); the
boot side of the slots (relay-switch, initramfs) is checked by
`board/readynas-duo-v1/relay/test-slots.sh`.
`--serve` starts the interface on http://127.0.0.1:8080/ with this data
(busybox httpd of the host).

## Known limits

- The API runs as root (like the old DIET): protected by the
  password, the private network filter and the `X-Diet` header against CSRF.
- busybox wget does not check the Telegram certificate.
- WebDAV: files are created by `nas` (not by the account that
  connects); COPY/MOVE only inside the same space (home
  folder or share); a client on the NAS itself (127.0.0.1) cannot
  do MOVE/COPY (scheme not forwarded); the lock database is
  `/var/lib/lighttpd-webdav/webdav.db`. The rsync module `[c]` (on request)
  writes as root. MiniDLNA folders
  with accented names are not accepted by the interface (write
  them by hand in `/etc/minidlna.conf`); the number of indexed files
  depends on the format of the minidlnad status page.
- `/c` is mounted by `S35storage` (xraid-compat package, docs/XRAID.md):
  existing X-RAID (read-only by default, writing through the switch of
  the Storage card) or md. Without a mounted volume,
  the interface does not create shares and shows "not mounted".
