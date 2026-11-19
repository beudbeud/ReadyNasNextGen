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
2. Open `https://<NAS address>/` (port 80 redirects to HTTPS).
   Access is limited to private networks.
3. **First setup**: while `/etc/lighttpd/htpasswd` (the administrator account,
   user `admin`) does not exist, `/` redirects to `/cgi-bin/setup`, a page served
   without authentication that asks for the administrator password, the NAS name
   and, optionally, a root password and an SSH public key (see below). Later:
   **System → SSH access**, or `diet-webpass` over SSH for the web password.

### First setup: how it is protected

- **lighttpd** (`lighttpd.conf`): `auth.require` covers everything except
  `/webdav` (accounts checked by the WebDAV instance) and exactly the URL
  `/cgi-bin/setup`, permanently. `/cgi-bin/setup` is a symbolic link to the
  API, which, under that name, serves only the setup page and its action, and
  only while `htpasswd` does not exist: the gate is a file test made at every
  request, not a condition fixed when lighttpd starts, so it closes the moment
  the account is written, without waiting for anything. Afterwards the URL
  answers 403 and nothing else of the API is reachable through it.
- **Redirection** of `/` to the setup page: added to `lighttpd.conf` at start
  (`include_shell "/etc/init.d/S50lighttpd firstconf"`, only without `htpasswd`,
  302); the setup restarts lighttpd, which drops it. `mod_redirect` is loaded
  before `mod_auth` (same request phase, run in order): this also makes port
  80 redirect before any password is asked.
- **Race** (two browsers): every field is checked first; the account line is
  written to a temporary file, then hard-linked to `htpasswd` (`ln` fails if
  the file exists, atomically): the first request wins, the others get 409 and
  write nothing; only the winner applies the name, the root password and the key.
- **CSRF**: the action needs the `X-Diet: 1` header, like the other actions.
- **Secrets**: passwords travel in the POST body (HTTPS), are hashed with
  SHA-512 crypt (`mkpasswd`, password on standard input), never logged; the
  root hash replaces the `root` field of `/etc/shadow` (600, temporary file then
  `mv`). An SSH key is one line `ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp* <base64>
  [comment]` (no options such as `command=`), appended once to
  `/root/.ssh/authorized_keys` (directory 700, file 600). dropbear keeps refusing
  empty passwords (no `-B`).
- `POST ?a=ssh_set` (`rootpw`, `key`) does the same from **System → SSH
  access**, authenticated; `GET ?a=sys` gives `rootpw` (0/1) and `keys` (count).

## What changes compared with the old DIET

| Topic | Old DIET (2.6.17) | DIET on 6.18 |
|---|---|---|
| Web server | busybox httpd behind a static lighttpd | lighttpd alone: mbedTLS TLS, `mod_auth` (SHA-512 htpasswd), `mod_cgi` |
| Shares | Samba 3.6, `smb.conf` + `shares.conf`, `smbpasswd` | ksmbd: `/etc/ksmbd/ksmbd.conf`, `ksmbd.adduser` (password on standard input), `ksmbd.control -r` |
| NFS | RAIDiator programs in a chroot (`diet-nfs`) | kernel nfsd + nfs-utils 2.x: the interface edits `/etc/exports` and runs `exportfs -ra` |
| Storage | X-RAID (`/proc/xraid`), LVM `/dev/c/c` | md (`/proc/mdstat`, `mdadm --detail`), `df /c`, libata disks `sda`/`sdb` (bay = ata port; the system USB stick is never listed); existing X-RAID through `nas-raid` (docs/XRAID.md); md: disabled for now (docs/XRAID-MIGRATION.md) |
| Temperatures, SMART | `smartctl` every 5 min | temperatures from drivetemp (`/sys/block/sdX/device/hwmon/*/temp1_input`); SMART every 5 min by `smart-lite` (see [SMART](#smart)), `smartctl` preferred if present |
| Fan | controlled by `diet-hwmon` | controlled by `padre-fan` (S03fan); the interface shows its state (`/var/run/fan.state`) and edits `/etc/fan.conf` (curve, period, thresholds), then restarts the service |
| `diet-hwmon` | control, SMART, history, alerts, emergency shutdown | monitoring only: history, SMART (disks in standby left asleep), Telegram alerts. The emergency shutdown is done by `padre-fan` |
| Power button | `diet-hotplug` (`/proc/sys/kernel/hotplug`) | `/sbin/hotplug` → `diet-hotplug` (CONFIG_UEVENT_HELPER): held 3 s = power off |
| Network | `/etc/diet-net.conf` + `S41diet-net` | `/etc/network/interfaces` (busybox ifupdown), applied at next boot |
| Time | `ntpd -q` at boot | `ntpd` in the background + "Update the time" button |
| Log | `/var/log/boot.log` | `/var/log/diet.log`, `/var/log/messages` (syslog), `dmesg` |

What is kept: the fr/de/en languages (page and
messages, `/etc/diet-lang`), Telegram notifications (token and
ID entered in the interface, stored in `/etc/diet-notify.conf`
on the NAS, never in the image), disk standby, LEDs
(bays, power), power off and reboot, `diet-status` on the
console.

Removed: everything specific to X-RAID, Samba 3.6, RAIDiator
(`zu-raidiator`, `init-weiche`, `install-weiche`), the flash, the LCD screen
(not on the Duo), `rsyncd`, LVM and `diet-import`.

## Organisation of the page

One page, seven sections, each with its own address (`#dashboard`, `#storage`,
`#shares`, `#users`, `#services`, `#system`, `#logs`): links can point at a section,
the Back button of the browser goes to the previous one, the last section
opened is remembered in this browser (`localStorage`, `dietTab`). The tab bar
is an ARIA tablist (arrows, Home, End); below 520 px it becomes a grid of
4 + 3 tabs. The header holds, right of the interface language menu, the
**power menu** (⋮ button, `aria-haspopup="menu"`/`aria-expanded`): Restart and
Power off with their confirmations and [protections](#protections) (disabled
with the reason while `busy` is not empty), and the reminder about the power
button. Opening it focuses the first usable item (arrows, Home, End move);
Escape closes it back to the button, Tab or a click outside closes it. There
is no log-out entry: the browser keeps the web login (HTTP authentication). A section loads its data when it is opened; the refresh policy is
unchanged (see [Speed](#speed-collector-and-cache): status every 15 s from `/cache/`, nothing
while the browser tab is hidden).

| Section | Content |
|---|---|
| Dashboard | reading and harmless actions only: front of the NAS (one slot per bay given by the API: 2 on the Duo, 4 on the NV+), **Storage health** (OK / read-only / degraded / rebuilding N %, disks in service and failed, free space, read/write rates, link to Storage), **System** (CPU, temperature, fan in rpm, memory, history), **Network** (rates, service chips). The alarm banner (above the tabs, on every section) links to the section where something can be done (Storage, or System for the fan). |
| Storage | **Volume /c**: state, mode and its reasons, level and member disks (from `storage.layout`, see docs/API.md), full and quick consistency checks with their progress, "Storage log" (opens Logs on that log); folded **Sensitive zone** (X-RAID writing switch, accepting a quick check, repair instructions); folded **Technical details** (superblock, base/mirror roles of a RAID 1, counters, sections, `mdadm --detail`). **Disks**: one line per bay with its SMART report, spin-down delay, "Spin down disks". |
| Shares | **Network shares (SMB)**: SMB service state, shares, SMB3 encryption. **NFS exports**: NFS on/off, exports. |
| Users | accounts (SMB, WebDAV and rsync password, WebDAV/rsync addresses). |
| Services | MiniDLNA, Avahi, rsync, WebDAV; Prometheus metrics; API access tokens. |
| System | General (name, time zone, system language and interface language, network), Telegram notifications, hardware (fan, temperature thresholds), SSH access, system update and versions, maintenance (restart SMB/NFS, update the time). Restart / Power off are in the power menu of the header. |
| Logs | one log at a time: DIET, system (`messages`), kernel (`dmesg`), storage, update; "Reload". Loaded when the section opens. |

Labels are generic, whatever the number of disks ("member disk", "check the
volume consistency", "N disks in service / M failed"); "base" and "mirror"
only appear in the technical details of a RAID 1. Every text of the page has
its French and German translation in `I18N`: `test-api.sh` checks the texts
of the markup, every `t('…')` of the script and the tables passed to `t()`.
Screenshots (1280 and 390 px, light and dark) are made with headless Chrome
on a fake API and are not kept in the repository.

## SMB3 encryption (Shares page)

"Network shares (SMB)" card: the **SMB3 encryption** switch writes `smb3 encryption` in
the `[global]` section of `/etc/ksmbd/ksmbd.conf` (`POST ?a=smb_enc`, `on=0|1`,
`X-Diet` header): `disabled` (shipped: the 280 MHz CPU encrypts without
hardware help, which caps transfers far below the disks) or `auto` (a client
that asks for encryption gets it). Only that line changes (temporary file then
`mv`, `.bak` copy; comments and share sections kept); a ksmbd.conf without the
key (older installs: ksmbd default `auto`, shown as on) gets it at the end of
`[global]`. ksmbd is then restarted (global settings are read at start).
`GET ?a=sys` gives the value (`smbenc`).

## SMB signing (Shares page)

Same card, **SMB signing** selector: `server signing` in `[global]`
(`POST ?a=smb_sign`, `v=auto|mandatory`, `X-Diet` header; written and ksmbd
restarted as for the encryption, journal line `SMB: server signing = …`).
`GET ?a=sys` gives `smbsign` (`auto` or `mandatory`).

What ksmbd 6.18 + ksmbd-tools 3.5.2 really do (`fs/smb/server/smb2pdu.c`,
`ksmbd.conf(5)`): the negotiate answer always offers signing
(`SIGNING_ENABLED`); only `mandatory` adds `SIGNING_REQUIRED`. Every other
value (`auto`, `disabled`, `enabled`, key missing) behaves the same: a session
is signed exactly when the client requires it, and a signed request always
gets a signed answer. So the client decides, and **signing cannot be turned off
on the server**; `disabled` is not offered (it would change nothing, and a
`disabled` already in the file is shown as `auto`).

| Client (default settings) | `auto` (shipped) | `mandatory` |
|---|---|---|
| Windows 11 24H2 (requires signing) | connects, signed | connects, signed |
| macOS (requires signing) | connects, signed | connects, signed |
| Linux libsmbclient / GNOME Files, `smbclient` (`client signing = default` = if required) | connects, **unsigned** | connects, signed |
| Linux `mount.cifs` (no `sign` option) | connects, **unsigned** | connects, signed |

Signing is AES-CMAC computed by the CPU: about 2.2 MiB/s signed against
7–9 MiB/s unsigned (docs/DEVELOPMENT.md). A Linux PC that still gets signed
transfers with `auto` asks for them itself: `client signing` /
`client protection` / `client min protocol` in `/etc/samba/smb.conf` or
`~/.smb/smb.conf` (`desired`, `required`, `sign`), the `sign` option of
`mount.cifs`, or `/proc/fs/cifs/SecurityFlags`.

## Services

Services page; the NFS on/off is in the "NFS exports" card of the Shares page (API: `GET ?a=services`,
`POST ?a=svc_set|dlna_set|dlna_scan|rsync_pw|rsync_c`, `X-Diet` header required).

| Service | What the interface sets | Files |
|---|---|---|
| SMB | on/off of ksmbd (`S70ksmbd`, which does not start it while `SVC_SMB=0`, also after an SMB setting or an X-RAID remount); the Bonjour announcement of SMB is set aside while it is off; the dashboard shows SMB as "disabled" (grey, `smb_on` 0 in `?a=status`), not as failed. Shares and SMB settings stay on the Shares page | `/etc/ksmbd/ksmbd.conf` |
| MiniDLNA | on/off; displayed name (`friendly_name`); folders (`media_dir`, one per line, optional prefix `A,` `V,` `P,`, existing folders under `/c`, letters, digits, space, `-` and `_`, no link that leaves `/c`); "Rescan" (`S60minidlnad force-reload` = `minidlnad -R`) | `/etc/minidlna.conf` (`.bak` copy), database in `/var/lib/minidlna` |
| Avahi | on/off; the announced name (`<name>.local`) follows the NAS name (avahi is restarted when it changes) | `/etc/avahi/services/*.service` |
| rsync | on/off; user accounts (see below); administrator module `[c]` (all of `/c`, as root, account `sauvegarde`) **only if checked** (`RSYNC_C=1`), with its password and the command `rsync -av folder/ sauvegarde@<name>.local::c/backups/` | `/etc/rsyncd.conf` (generated), `/etc/rsyncd.secrets` (600) |
| WebDAV | on/off of the `S51webdav` instance; addresses `https://<name>.local/webdav/<user>/` and `/webdav/<share>/` | `/etc/lighttpd/webdav.conf` (generated), `/etc/lighttpd/htpasswd-users` |
| NFS | on/off of the kernel NFS server (`S60nfs`: statd, nfsd, mountd; running = nfsd threads in `/proc/fs/nfsd/threads`). Stopped: the "NFS exports" card says so and stays editable (`/etc/exports` written, `exportfs` not run: read again at start); "Restart NFS" (System → Maintenance) is disabled (`nfs_on` in `?a=status`, refused with 409) | `/etc/exports` |

State: running or stopped; for MiniDLNA, the number of indexed files
(audio, video, images) read from its status page `http://127.0.0.1:8200/status` (no
`sqlite3` process started) and the size of `files.db`.

Persistence: `SVC_SMB`, `SVC_MINIDLNA`, `SVC_AVAHI`, `SVC_RSYNC`, `SVC_WEBDAV`, `SVC_NFS` in
`/etc/diet.conf` (`0` = stopped, `1` or missing = running). The shipped `diet.conf` sets
the last five to `0`: out of the box only SMB (ksmbd), the web interface and SSH run, and rpcbind
(`S30rpcbind`) only starts with NFS. `S50avahi-daemon`,
`S60minidlnad`, `S60nfs` (which replace the Buildroot ones; `S60nfs` also stops
the nfsd kernel threads with `rpc.nfsd 0`, which the Buildroot `killall nfsd`
could not do; rpcbind is left running), `S61rsyncd` (in
`board/readynas-duo-v1/rootfs-overlay/etc/init.d/`) and `S51webdav` (diet
package) do not start a service set to `0`. A stopped service also loses its
Avahi announcement (`rsync.service`, `webdav.service` renamed to `.service.off`,
then `avahi-daemon -r`).

### WebDAV and rsync: local accounts

The users of the Users page have a single password for SMB,
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

## System update (System page)

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
   is required. Downloaded with curl, which checks the certificate (CA bundle
   `/etc/ssl/certs/ca-certificates.crt`) and follows redirects only to https. 512 MB at most.
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
`/var/lib/nas-update/log` (Logs, “Update log”).

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

### Checking the mirror after a crash

- **Check the volume consistency** (`POST ?a=raid_verify`): full comparison, 10–12 h.
- **Quick check** (`POST ?a=raid_quick`, background `nas-raid quick-verify`,
  1 to 3 minutes, docs/XRAID.md §5.1): compares the ext3 journals, the file
  system and LVM metadata, the partition table and random samples. The
  confirmation before starting says what it guarantees (structure and journal
  identical) and what it does not (file data written at the time of the cut,
  outside the compared areas). The card shows progress (`quick.progress`,
  refreshed every 5 s while it runs), then the result: identical, differences
  (with their category: repair needed), incomplete, or "no difference, unclean
  superblock: confirmation needed". With a clean superblock and only the
  Linux `xraid-dirty` marker, the marker is lifted automatically.
- **Accept the quick check…** (only when `quick.accept` = 1: unclean
  superblock, no difference, same boot, nothing remounted since): dialog
  describing the residual risk, checkbox **and** the word `ACCEPT`;
  `POST ?a=raid_quick_accept` with `confirm=ACCEPT&yes=1` runs `nas-raid
  quick-accept --confirm ACCEPT --yes` (what a successful full check does:
  marker removed, superblock clean). Refused (400) without the word or the
  box, 409 if nas-raid refuses.

## Protections

- **Restart, power off, trying another version.** `POST ?a=reboot`,
  `?a=poweroff` and `?a=update_switch` answer **409** with the reason while:
  a system update job runs (nas-update state `busy` with its process alive),
  a full or quick mirror check runs (`/var/lib/nas-raid/verify.state` or
  `quick.state` = `running`, started during this boot), or an md
  resync/recovery/check/repair shows in `/proc/mdstat` (`nas-raid repair`).
  `force=1&confirm=FORCE` overrides it (logged in the DIET log; docs/API.md).
  The same test fills `busy` in `GET ?a=status` (`update`, `verify`, `quick`,
  `sync`): the page then disables Restart, Power off, "Restart to try it" and
  "Switch to the other version" and says why; the power button of the device
  (hold 3 s) still works.
- **Sensitive zone.** "Allow writing on the X-RAID" and "Accept the quick
  check…" are in a folded "Sensitive zone" of the Storage card, under a
  warning; their dialogs (box and typed word, which stays in English) are
  unchanged. When a check finds differences, the card gives the repair
  command (`nas-raid repair --confirm REPAIR --yes`, docs/XRAID.md §5).
- **One saving rule.** A form (shares, users, NFS, tokens, settings) is saved
  with its button; the button is disabled while the request runs and the
  fields are emptied only when the NAS accepted. A switch that restarts or
  stops a service (SMB3 encryption, share options, Prometheus, the Services
  switches) applies at once after a short confirmation naming that service;
  cancelling puts the switch back.
- Errors stay on screen 8 s (or until clicked) and are announced to screen
  readers (`role=alert`); other messages are polite (`role=status`).

## Speed: collector and cache

Starting a program costs ~60 ms on this SPARC and floating point is emulated by
the kernel. So:

- **Collector**: `S95diet` starts the API itself in the background
  (`DIET_COLLECT=1 /www/cgi-bin/api`, pid in `/var/run/diet/pid`). It writes
  ready JSON responses to `/var/run/diet/<key>.json` (temporary file
  then `mv`): `status` every 15 s and the rest (`storage services shares nfs
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

- **Static answers, no CGI**: lighttpd serves the collector files as static
  files under `/cache/<key>.json` (`alias.url` to `/var/run/diet/`, only
  `^/cache/[a-z]+\.json$`: never the FIFO, the pid, `seen`/`active` or the
  temporary files; same Basic authentication as the page;
  `Cache-Control: no-store`, `application/json`). Each CGI request starts
  `/bin/sh api` (~60 ms of process creation plus reading the script): with the
  tab open, lighttpd took ~45 % of the CPU when the page asked the API every 5 s.
- **Password cache** (`auth.cache`, 10 min): the administrator password is a
  SHA-512 crypt, which lighttpd checked again on every request (page, API, every
  `/cache/*.json`): 0.35 s of CPU each on the Padre, in the single lighttpd process,
  so a page load queued several of them. Measured on the NAS (2026-11-19, test
  instance, one keep-alive connection): 0.355 s per authenticated request without
  the cache, 0.006 s with it. A cached user who sends another password is refused
  until the entry expires, so a password change restarts lighttpd (first setup,
  `diet-webpass`).
- **Page refresh** (`poll()` in `index.html`): only while the tab is visible
  (`visibilitychange`: stopped when hidden, immediate refresh when shown again);
  every **15 s** the status from `/cache/status.json`; every 4th time (1 min)
  `?a=status` through the API instead, which writes `seen` and so keeps the
  collector in its fast pace (it slows down after 2 min without a request);
  every 8th time (2 min) `?a=all` (status + storage + history) through the API.
  Shares, users, services, settings and logs are only loaded when their page
  is opened (logs: on demand). After an action the cache is emptied (POST):
  the next reads fall back to the API, so the refresh shown right after an
  action is up to date.
- **Staleness rule**: a static answer is used only if
  `Date − Last-Modified` (both from the server clock, so no clock skew with
  the browser) is at most **45 s** (3 collector periods); older (collector
  slowed down or stopped) or missing (404: cache emptied by a POST, collector
  not running): the page asks the API, which also wakes the collector.
- **Connections**: `server.max-keep-alive-idle = 120` (> 15 s refresh + margin:
  one TLS handshake per visit, not per request), HTTP/2 (`server.h2proto`,
  default of lighttpd 1.4.84, written explicitly), TLS session tickets
  (`Options` … `SessionTicket`, default of mod_mbedtls, mbedTLS 3.6 built with
  `MBEDTLS_SSL_SESSION_TICKETS`): a connection reopened after the idle limit
  resumes the session instead of a full ECDHE + ECDSA handshake. Checked with
  a host build of lighttpd 1.4.84 + mbedTLS 3.6.7 and this configuration
  (`LIGHTTPD=… sh package/diet/tests/test-api.sh`, `tests/tls-reuse.py`): 10
  requests 15 s apart = 1 handshake; a new connection is resumed (TLS 1.3).
- **Expected load with the tab open** (per minute; before → after): HTTPS
  requests 12 → 4; CGI processes (`sh api`) 12 → 1; collector `status`
  computations 12 → 4; TLS handshakes unchanged (keep-alive) or resumed.
  The CGI starts were the main cost: lighttpd + CGI should go from ~45 % to
  roughly 5–10 % of the CPU with the tab visible, and ~0 when the tab is
  hidden (estimate, to be measured with `top` on the NAS).

`/etc/init.d/S95diet restart-collector` restarts the collector.

## Prometheus

`node_exporter` (Go) does not run on sparc32. Instead the collector writes
`/var/run/diet/metrics.prom` in the Prometheus text format (0.0.4) and
lighttpd serves it as `https://<nas>/metrics`. No Grafana or exporter on the
NAS: Prometheus (and Grafana) run elsewhere and scrape it.

**Setting** (Services → Prometheus metrics, `METRICS` in `/etc/diet.conf`):

| | `/metrics` |
|---|---|
| off (default, `METRICS=0`) | 403; the collector writes nothing |
| with authentication (`1`, recommended) | `Authorization: Bearer <token>`: a read-only token from Services → API access tokens (docs/API.md). lighttpd rewrites `/metrics` to the API (`/cgi-bin/v1?a=metrics`), which checks the token and sends the file with `exec cat` (one CGI start and one `sha256sum` per scrape) |
| without authentication (`2`, explicit box) | the file served as a **static file** by lighttpd, no CGI; any device of the local network can read it (the private networks rule still applies) |

The rule is written by `S50lighttpd metricsconf` (`include_shell` in
`lighttpd.conf`) when lighttpd starts; the API restarts lighttpd when the
setting changes.

**Collector**: one more file per `status` round, written atomically
(temporary file then `mv`), only when the setting is on: every 15 s while the
interface is open, otherwise every 60 s (a scrape does not speed it up).
`readynas_time_seconds` tells when it was written. Stopping the collector
removes the file: the open mode then answers 404 (`up` goes to 0), the token
mode computes the metrics at each scrape (slower, still correct).
The values are those `status` already reads, plus `/proc/stat`,
`/proc/net/dev`, `/proc/diskstats`, `nas-raid.mode`, `xraid.json` (written by
nas-raid) and the check states: shell only, integer arithmetic (CPU seconds
from jiffies printed as `N.NN`, no awk, no `printf %f`).

Metrics (prefix `readynas_`, base units):

| Metric | Type | Labels |
|---|---|---|
| `info` (version and model, 1) | gauge | `version`, `model` |
| `time_seconds`, `uptime_seconds`, `load1`, `load5`, `load15` | gauge | |
| `cpu_seconds_total` | counter | `mode` (user, nice, system, idle, iowait, irq, softirq) |
| `memory_{total,free,available,buffers,cached}_bytes`, `swap_used_bytes` | gauge | |
| `temperature_celsius` | gauge | `sensor` (board, sda, sdb) |
| `fan_pwm` (setpoint 0-255), `fan_speed_rpm` | gauge | |
| `network_{receive,transmit}_{bytes,packets,errors}_total` | counter | `device` (eth0) |
| `disk_{read,written}_bytes_total`, `disk_{reads,writes}_completed_total` | counter | `device` |
| `filesystem_size_bytes`, `filesystem_free_bytes` | gauge | `mountpoint` (/c) |
| `disk_smart_passed`, `disk_{reallocated,pending,offline_uncorrectable}_sectors`, `disk_power_on_seconds`, `disk_power_cycles`, `disk_smart_temperature_celsius` (last reading of diet-hwmon, see [SMART](#smart)) | gauge | `device` |
| `service_up` | gauge | `service` (ksmbd, web, ssh, ntpd, fan, hwmon, nfs) |
| `storage_mode_info` (1) | gauge | `mode` (xraid-rw, xraid-ro, md…), `reasons` |
| `xraid_writable`, `xraid_superblock_clean`, `xraid_disks_online`, `xraid_disks_failed`, `xraid_sections`, `xraid_sections_synced` | gauge | |
| `xraid_check_result` (1), `xraid_check_timestamp_seconds` | gauge | `check` (full, quick), `result` (ok, differences, errors, incomplete, confirm, accepted, running) |

`scrape_config` (the NAS certificate is self-signed: copy
`/etc/lighttpd/ssl/server.pem` next to Prometheus, or use
`insecure_skip_verify: true`):

```yaml
scrape_configs:
  - job_name: readynas
    scheme: https
    scrape_interval: 60s          # the collector refreshes every 60 s when the interface is closed
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/readynas.token   # a read-only token
    tls_config:
      ca_file: /etc/prometheus/readynas.pem
      # the certificate names the NAS by its host name and eth0 address
    static_configs:
      - targets: ['nas.local:443']
```

Without authentication, drop the `authorization` block. Alert examples:
`readynas_xraid_disks_failed > 0`, `readynas_xraid_writable == 0`,
`time() - readynas_xraid_check_timestamp_seconds{check="full"} > 90*86400`,
`readynas_temperature_celsius{sensor=~"sd.*"} > 50`,
`time() - readynas_time_seconds > 300` (collector stopped).

## Packages and applets used

lighttpd (with mbedTLS; only `gen_key` and `cert_write` are kept among
the mbedTLS programs), ksmbd-tools, nfs-utils, mdadm, curl (mbedTLS) with the CA
certificates for HTTPS (Telegram, system update downloads: certificate checked). The
package enables `ntpd` in busybox and turns off its HTTPS wget, which checks no certificate. The rest is busybox
(`sh`, `awk`, `sed`, `hdparm`, `mkpasswd`, `start-stop-daemon`…).
## SMART

`smartctl` is not in the image: smartmontools needs a C++ toolchain,
which neither the internal toolchain nor the prebuilt toolchain has
(libstdc++ alone is about 1.5 MB, plus a new toolchain release), and
libatasmart needs libudev (the system uses mdev). SMART is read by
`smart-lite` (package/smart-lite, one C file, 18 KB on the NAS): SG_IO with ATA
PASS-THROUGH (16), which libata (`padre_sata`) translates. It only sends
CHECK POWER MODE, IDENTIFY DEVICE, SMART READ DATA, SMART READ THRESHOLDS
and SMART RETURN STATUS, plus SMART EXECUTE OFF-LINE IMMEDIATE with `-t` only
(self-test): never SMART ENABLE/DISABLE or SET FEATURES.

    smart-lite /dev/sda        identity, health, temperature, attribute table
    smart-lite -s /dev/sda     one line: health= realloc= pending= uncorr= hours= cycles= celsius=
                               selftest= left= short_min= long_min=
    smart-lite -t short|long|abort /dev/sda   start (or abort) a self-test
    smart-lite -f /dev/sda     also read a disk in standby (may spin it up)
    smart-lite -F id.bin smart.bin thresh.bin [PASSED|FAILED]   decode saved sectors

Exit status: 0 read, 1 error, 2 disk in standby (not read, `power=standby`).
`diet-hwmon` runs `smart-lite -s` every 5 minutes and writes the line to
`/var/run/smart.sdX` (kept as it is while the disk sleeps); `diet-alerts`,
the disk list and the metrics read that file. The "SMART report" buttons
call `smart-lite -f` (the user asked for it). If `/usr/sbin/smartctl` exists
(an image built with C++), it is used instead, with `-n standby`.

**Self-tests** (Storage page, disk list: "Short test", "Long test", "Stop the
test" while one runs; `POST ?a=smart_test`, docs/API.md). The disk runs the
test itself, in the background: the data are not written, the disk keeps
serving requests (slower), and the NAS can be used meanwhile. `smart-lite -t`
reads SMART first and refuses when the disk has no self-test or one is
already running; it wakes a disk in standby. The API then refreshes
`/var/run/smart.sdX` at once (`diet-hwmon` keeps it up to date every 5 min):
the list shows "self-test running, N % left", then "last self-test aborted" or
"last self-test failed" (a failure also raises the "Disk to watch" banner;
not a Telegram alert: `diet-alerts` does not read it yet; status
0, "done without error", cannot be told apart from "never run" by this field).
Durations given by the disks of the test NAS (WD7500AADS): short 2 min,
extended 184 and 208 min. On some disks the spin-down timer (`hdparm -S`)
may interrupt a long test (not checked here): it then shows as "aborted".
Every start is a journal line (`SMART self-test short on sda`).

On the WD7500AADS disks of the test NAS, neither CHECK POWER MODE, SMART
READ DATA nor drivetemp spins up a disk in standby (`hdparm -C` stays
`standby`); other disks may differ, hence the power check.

Test on the PC: `sh package/smart-lite/tests/test.sh` (sample sectors,
made-up serial number).

## Test on the PC

    sh package/diet/tests/test-api.sh

creates a fake root (`DIET_ROOT`) with simulated `/proc`, `/sys` and `/etc`
(healthy then degraded RAID1, drivetemp, ksmbd.conf, exports), replaces
the NAS commands with scripts that record their arguments, calls
the API as lighttpd would and checks the JSON and the written files.
The first setup is called through its `setup` name: page and action allowed
without an account, refused once it exists, no password in clear in any file
of the fake root, three concurrent requests (one winner) repeated six times.
System updates run against a folder standing for the USB stick (`DIET_STICK`); the
boot side of the slots (relay-switch, initramfs) is checked by
`board/readynas-duo-v1/relay/test-slots.sh`.
Metrics: `tests/promcheck.py` checks the exposition format of the file
(HELP/TYPE, contiguous families, counters `_total`, no NaN, no duplicate
series; `promtool check metrics` too when installed) and the values are
compared with the simulated `/proc`. Tokens: hashed storage, read-only refusing
POST, revocation, no value in any log. With `LIGHTTPD=/path/to/lighttpd` (a host
build of lighttpd with mod_mbedtls and mod_cgi) the real `lighttpd.conf` is
also checked with the API as CGI: Basic for the interface, Bearer for
`/api/v1/` and `/metrics`, and the three `/metrics` modes.
`--serve` starts the interface on http://127.0.0.1:8080/ with this data
(busybox httpd of the host).

## Known limits

- The API runs as root (like the old DIET): protected by the
  password, the private network filter and the `X-Diet` header against CSRF.
- API tokens (docs/API.md): a full-access token can do everything the
  interface does; tokens have no expiry date (revoke them). `/metrics` and
  `/api/v1/` cost one CGI start and one `sha256sum` per request (lighttpd
  cannot check a hashed Bearer token by itself); the open `/metrics` mode is a
  static file but readable by the whole local network.
- First setup: until the administrator password is chosen, anyone on the
  local (private) network who opens the interface first can choose it. Set it
  up right after the first boot.
- Removing an SSH key: by hand (`/root/.ssh/authorized_keys`), the interface
  only adds keys.
- HTTPS checks (Telegram, update downloads) need the right time: a NAS whose clock is
  far off (hardware clock lost, no NTP yet) refuses the certificates until NTP sets it.
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
