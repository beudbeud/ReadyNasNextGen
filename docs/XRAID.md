# X-RAID on Linux 6.18: compatibility, safeguards, switch to md

This document describes the `package/xraid-compat` package: read **and write** the
X-RAID volume created by RAIDiator (ReadyNAS Duo v1, 2 mirrored disks) without
converting it, then, if wanted, move to the Linux software RAID `md`.

**Status: nothing has been tried on the NAS yet.** Everything was written from the
functional description of the format (summarised in §1, established for
interoperability, without reusing any Infrant/NETGEAR code) and tried on a PC
with fake disk images (§8). The readings to take on the NAS before
any write are in §9.

By default the X-RAID is mounted **read-only** (`XRAID_RW=no`). Writing
is only enabled after validation, by writing `XRAID_RW=yes` to
`/etc/nas-raid.conf` (by hand then `nas-raid remount`, or through the DIET switch
"Allow writing on the X-RAID", §7).

## 1. The X-RAID format in brief

- X-RAID is **not** `md`. The RAIDiator driver (`padre_io`) copies each
  write falling into a **section** to the other disk, **at the same LBAs**.
  No offset, no stripe, no metadata between the data.
- The **base** disk has an ordinary MBR: `p1` RAIDiator root (ext3),
  `p2` swap, `p3` extended, `p5` LVM physical volume (group `c`, volume `c`,
  ext3 with **16 KiB blocks**, mounted on `/c`). The **mirror** disk has **no
  MBR** (sector 0 zeroed) but holds the same image from sector 1 on.
- Sections set up by RAIDiator (512-byte LBAs): section 0 =
  [32, 32 + 4096000), section 1 = [4096032, V − 2 + 30). V is the
  "visible" size: N − 20,480 sectors in general, or a fixed size per disk
  class (750 GB: V = 1,465,128,688 for N = 1,465,149,168).
- The end of each disk (beyond V, ~10 MiB) is the **protected area**:
  current superblock at N − 4096 (copy at N − 4072), backup superblock at
  N − 4048 (copy at N − 4024), "WGam" marker at N − 2.
- Superblock (9,440 bytes, **big-endian** 32-bit integers): magic
  `WGao` (0x5747616F) at 0, version 0.1.0, identifier (end of the NAS MAC
  address) at 0x14, creation date at 0x18, V at 0x20, number of disks at
  0x24/0x28, dummy disk at 0x33, **bit 0 of 0x84 = clean shutdown**, number of
  sections at 0x100; disk table (12 × 128 bytes at 0x200, entry 1 =
  SATA 0, entry 2 = SATA 1: base/mirror role, **state** at +0x10:
  0 failed, 1 online, 2 spare, 8 rebuilding, copy of the partition
  table at +0x18); section table (32 bytes at 0x800: level at +5,
  carrier disks (`dmap`, 3 = both) at +4, used at +6, **initialised**
  (mirror synchronised, driver `initialized`) at +7; +8 stays non-zero on
  a healthy volume and is not read as a synchronisation state; start at
  +0x10, size at +0x18); entry of the carrier disk (`this_disk`) at 0x1460.
- On Linux 6.18 the disks are named `sda`/`sdb` in SATA port
  order; the base disk can be either one (on a Duo installed with
  the second port as base, the base is `sdb`). The tools rely on the
  superblock (`this_disk`), never on the name.

## 2. What the compatibility layer does

At boot, `S35storage` runs `nas-raid mount` (before NFS and SMB):

1. **Analysis** (`xraid-info`, C, read-only) of the SATA disks (not the USB
   stick): the four superblock copies, choice of the reference superblock
   (identical on the disks, otherwise the most recent), role of each disk,
   sections bounded to V, partitions (MBR of the **base** disk; if missing,
   table copied in the superblock and EBRs read on the mirror), then
   **comparison of 256 blocks of 64 KiB per section** at the same LBAs on both
   disks. Verdict: `rw`, `ro` or `none`, with the reasons.
2. **Read-write** (all safeguards pass and `XRAID_RW=yes`):

        base disk     ──dm-linear [start, start+len)──┐
                                                     ├─ mdadm --build (RAID 1, NO superblock)
        mirror disk   ──dm-linear [start, start+len)──┘        = /dev/md10 (section 0), /dev/md11 (section 1)
        base disk partitions ── dm-linear on md1x ── /dev/mapper/xr-p1, xr-p2, xr-p5
        xr-p5 ── LVM (vgchange -ay c, read-only metadata) ── /dev/mapper/c-c
        /dev/mapper/c-c ── fuse2fs (ext3 with 16 KiB blocks) ── /c

   Each write therefore goes to both disks at the same LBAs, exactly
   as RAIDiator did, and only **inside the sections bounded to V**.
   The base disk is the first member (source of a repair).
3. **Read-only** (a safeguard refuses writing): no md; the
   partitions are mapped directly onto a single disk (the base if it is
   "online", otherwise the mirror) with `dmsetup --readonly`, LVM with
   `read_only_volume_list`, and `fuse2fs -o ro`.
4. If a disk carries an md superblock (already migrated), the md is mounted
   on `/c` (`mdadm --assemble --scan`, VG `donnees`, ext4).

At shutdown (`nas-raid unmount`): unmount, LVM deactivated, md stopped, dm
removed.

`nas-raid remount` (X-RAID only, not during a migration): first unmounts
`/c` alone and stops there if `umount` is refused (open file: the
volume stays mounted as it is), otherwise `unmount` then `mount` with all the
safeguards. Used after a change of `XRAID_RW`.

The swap (`p2`) and the RAIDiator root (`p1`) are not used (the RAIDiator
swap has 16 KiB pages).

## 3. Safeguards

| Situation | Effect |
|---|---|
| `XRAID_RW` ≠ `yes` (default) | read-only (reason `rw_disabled`) |
| Superblock missing, version ≠ 0.1.0, inconsistent sections, two "base" disks | nothing is mounted |
| Current superblock missing (backup only) or different from one disk to the other | read-only |
| **Unclean shutdown** recorded by RAIDiator (bit 0 of 0x84 at 0) | read-only, until a successful full check (§4) |
| **A disk is missing** or single-disk configuration | read-only on the present disk |
| **Unfinished synchronisation** (resume point ≠ 0, disk rebuilding/spare) | read-only |
| Section that is not a mirror (NV+ RAID 4) | read-only |
| **Mismatched samples** at the same LBAs | read-only |
| Partition that overflows the sections or V | read-only |
| Crash **under Linux** (marker `/var/lib/nas-raid/xraid-dirty` left behind) | read-only, until a successful full check |
| X-RAID md degraded at shutdown (a disk failed along the way) | the marker stays: read-only at next boot |
| Migration in progress | X-RAID read-only |

Always: `xraid-info` opens the disks read-only only; `nas-raid` **never** writes
the X-RAID superblock or the protected area in compatibility mode (no
dm table goes beyond V; checked by the tests); no md superblock
(`--build`); read-only LVM metadata (`metadata_read_only`).
Only one `nas-raid` action at a time (lock).

## 4. Risks and limits

- **No resynchronisation tracking**: without an md superblock or an update of the
  X-RAID superblock, a power cut during a write can leave
  the two disks different, with nothing recording it on the disks. The
  `xraid-dirty` marker (on the USB stick) detects it and switches back to read-only;
  then `nas-raid verify` is needed. If the USB stick is replaced, the marker is
  lost: run a full check.
- After a run under Linux, RAIDiator still sees its superblock as before
  (nothing is written to it): it does not know that the data changed; the data is
  at the same places on both disks, so it can read it back.
- A disk that fails **along the way**: md continues on the other one; the
  marker stays and the next boot is read-only. Do not reassemble
  by hand with `--assume-clean`.
- `fuse2fs` in user space on a ~200 MHz SPARC: slow. An ext3 journal
  to replay can prevent a read-write mount (run fsck on a PC first).
- LVM: if group `c` contains RAIDiator snapshots, it needs
  `CONFIG_DM_SNAPSHOT` (not in the kernel); to be checked with the readings.
- SMART is read through ATA PASS-THROUGH (`xraid-info smart`), not through smartctl
  (missing: toolchain without C++): not checked on the NAS.
- Byte order of the superblock as seen by Linux: assumed big-endian,
  to be confirmed by the readings.

## 5. Checking and repairing the mirror

- `nas-raid verify` (or "Check the mirror" in DIET) compares **the whole
  content of the sections** of both disks in 1 MiB blocks, read-only
  (`xraid-info verify`), re-reads a mismatched block three times (write in
  progress), records the mismatched 64 MiB areas (`/var/lib/nas-raid/verify.res`)
  and the read errors. Several hours for 2 × 750 GB. Better done
  with the volume read-only. When it succeeds outside writes, it removes the
  `xraid-dirty` marker and accepts an "unclean" RAIDiator superblock.
- `nas-raid repair --confirm REPAIR --yes`: only if the reasons are
  "unclean shutdown" or "mismatched samples". Assembles read-write and
  runs `repair` on each md: the base is copied to the mirror where they
  differ. Then `nas-raid verify`, then reboot.

## 6. Switch to md

All these actions erase disks. They require **two
confirmations**: `--confirm PHRASE` (exact phrase shown on refusal)
**and** `--yes`; in DIET, a checkbox and the phrase to type. Each one has a
**dry-run** mode (`--dry-run`) that shows the commands without running or
writing anything. Log: `/var/lib/nas-raid/log` (DIET Logs tab).

The md created: RAID 1 on whole disks, metadata 1.2, internal bitmap, name
`donnees` (`/dev/md/donnees`, `/etc/mdadm.conf`), LVM (VG `donnees`, LV `c`),
ext4 with 4 KiB blocks, mounted on `/c` by the kernel (no more fuse2fs).

### 6.1 In-place migration of both disks (no 3rd disk)

    nas-raid migrate --dry-run                      # see what will be done
    nas-raid verify                                 # mandatory, < 7 days
    nas-raid migrate --confirm MIGRATE --yes        # steps 1 to 3
    nas-raid migrate --finalize --confirm 'ERASE sdX' --yes   # step 4

Prior checks: healthy X-RAID (two disks online, no synchronisation,
identical samples, no unchecked crash), successful full check
less than 7 days old, SMART of both disks readable and without pending
or unreadable sectors (`--no-smart` to override, not recommended), data
in `/c` small enough for the md.

1. **break**: mirror disk B leaves the X-RAID: start and X-RAID area of B
   erased, **degraded** md RAID 1 on B, LVM, ext4. The X-RAID is remounted
   **read-only** on base disk A alone (still readable by RAIDiator
   as a degraded X-RAID). The md is mounted on `/mnt/md`.
2. **copy**: `rsync -aH --numeric-ids --delete /c/ /mnt/md/`, resumable
   (run the same command again after an interruption; at boot, `S35storage`
   remounts X-RAID read-only and the md on `/mnt/md`). Refused if `/c` is
   not the read-only X-RAID or if `/mnt/md` is not mounted.
3. **verify**: `rsync -n -c` (checksums; `VERIFY_RSYNC=` in
   `/etc/nas-raid.conf` to compare size and date only); any
   difference stops the migration. The migration stops here: check
   `/mnt/md`.
4. **finalise** (`--finalize`, phrase `ERASE <base disk>`): refused if the
   md holds less than half of the X-RAID data; A is erased (start
   and X-RAID area) then added to the md: **resynchronisation** (`/proc/mdstat`);
   `/c` = md. **Going back to X-RAID/RAIDiator is no longer possible.**

Steps and log in `/var/lib/nas-raid/` (`migration`, `log`).

### 6.2 New md RAID (new or existing disks)

    nas-raid create /dev/sda /dev/sdb --confirm 'ERASE sda sdb' --yes

Erases the disks (including an X-RAID), creates the md (a single disk: degraded
md, complete it with `add`), LVM, ext4, mounts `/c`. Only the NAS SATA
disks are accepted.

### 6.3 Replacement and vertical expansion

    nas-raid add /dev/sdb --confirm 'ERASE sdb' --yes         # new disk in place of an old one
    nas-raid grow --confirm GROW --yes                           # when both are larger

Replace one disk at a time (remove the old one, insert the new one,
`add`, wait for the resynchronisation to finish), then `grow`: bitmap
removed, `mdadm --grow --size=max`, bitmap put back, `pvresize`, `lvextend`,
`resize2fs` (ext4 mounted).

## 7. DIET dashboard

The "Storage /c" card shows the mode (X-RAID read-write, X-RAID
read-only, md RAID), the reasons for a read-only mount, the state of the sections,
the last mirror check and the step of a migration. Buttons:
"Check the mirror", "Migrate to md", "Finish the migration",
"Create an md RAID" (wizard: dry run, checkbox, phrase to
type) and "Storage log". In X-RAID mode, the "Allow writing on the
X-RAID" switch writes `XRAID_RW` (enabling: warning, checkbox and
the word `WRITE`), stops the services that use `/c` for the time of a
`nas-raid remount`, then restarts them; if a safeguard refuses, the card stays
read-only with the reason (docs/DIET.md). API: `GET ?a=storage` (`nas-raid status
--json`, without disk access: result cached at mount time), `POST
?a=raid_verify|raid_plan|raid_run|xraid_rw`, log `?a=log&f=storage`.

## 8. Tests on a PC (no NAS, no root)

    sh package/xraid-compat/tests/test.sh
    sh package/diet/tests/test-api.sh

`tests/make-images.py` builds images as sparse files (750 GB
apparent, a few MB real): superblock, copies, backup, "WGam", MBR on
the base only, EBR, sections, with the clean, dirty, degraded,
unfinished synchronisation, mismatched mirror and md disk scenarios. The tests check
detection, the JSON, the full check, the verdicts, the assembly
commands (no table beyond V), the refusals (check, SMART,
confirmations), the dry runs of migration, creation, expansion, and
the DIET API. dmsetup, mdadm, lvm, fuse2fs and mount are simulated: no
dm or loop device is created (that would need root).

## 9. Readings to take on the NAS (read-only)

On the 6.18 system with `XRAID_RW=no` (default). The files produced
contain **serial numbers** (IDENTIFY in the superblock), part
of the **MAC address** and the **host name** (LVM metadata): do not publish them.
Write them to the USB stick, not to the disks. For each disk `X` = `a`,
`b`:

    N=$(cat /sys/block/sdX/size); echo "sdX $N"
    dd if=/dev/sdX of=/start-sdX.bin bs=512 count=128                  # first 64 KiB (MBR)
    dd if=/dev/sdX of=/end-sdX.bin bs=512 skip=$((N - 20480)) count=20480   # last 10 MiB (superblocks)
    xraid-info smart /dev/sdX

then:

    xraid-info --samples 64 /dev/sda /dev/sdb
    xraid-info --json /dev/sda /dev/sdb
    dd if=/dev/sdB of=/pv-start.bin bs=512 skip=4608040 count=2048     # sdB = the base disk: LVM label and metadata
    cat /proc/partitions; dmesg | grep -i -E 'sd[ab]|ata[12]'
    nas-raid status; nas-raid mount --dry-run; nas-raid migrate --dry-run
    cat /var/run/nas-raid.mode; ls /c; df /c                           # read-only mount done by S35storage
    lvm lvs --config 'devices { filter = [ "a|^/dev/mapper/xr-p|", "r|.*|" ] }'

To check: `od -A d -t x1 -j 8388608 -N 4 /end-sdX.bin` gives `57 47 61 6f`
("WGao" at N − 4096, big-endian); `xraid-info` answers `rw` or `ro` with
consistent reasons; sections 32 / 4096000 and 4096032 / 1461032686;
base = the disk that has an MBR; `ls /c` readable; LVM without snapshots; plausible
SMART values (power-on hours). Only then: `nas-raid verify`, then
`XRAID_RW=yes` and a reboot.

## Files

| File | Purpose |
|---|---|
| `package/xraid-compat/src/xraid-info.c` | analysis, full check, SMART (read-only) |
| `package/xraid-compat/src/nas-raid` | mount, unmount, check, repair, migration, md |
| `package/xraid-compat/src/S35storage` | boot and shutdown |
| `package/xraid-compat/tests/` | fake images and tests |
| `/etc/nas-raid.conf` (on the NAS, optional) | `XRAID_RW`, `SAMPLES`, `VERIFY_RSYNC`, `FUSE2FS_OPTS`… (variables at the top of `nas-raid`) |
| `/var/lib/nas-raid/` (on the NAS) | markers, check, migration, log (`log`) |
