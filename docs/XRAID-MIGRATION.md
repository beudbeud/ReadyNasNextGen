# X-RAID → md migration that keeps the RAIDiator system volume ("track A")

Study and design. **Nothing described in §4–§6 is implemented**; what is implemented is the
safeguard of §9 (`nas-raid` refuses `migrate`/`create` while the relay is installed, DIET greys
the buttons). Format details of X-RAID: [XRAID.md](XRAID.md) §1 (and XRAID-FORMAT.md when it
exists). Relay: [board/readynas-duo-v1/relay/README.md](../board/readynas-duo-v1/relay/README.md).

## 0. Verdict

**Feasible, under conditions.** An md RAID 1 can live **inside partition p5 of both disks, at
the same LBAs**, with md metadata 1.2, while p1 (RAIDiator root with the relay), p2 (swap), the
MBR/EBR, the X-RAID superblocks and the "WGam" marker stay exactly as RAIDiator left them. iboot,
the 2.6.17 kernel, `linuxrc` and the X-RAID driver then still find everything they need to start
`/sbin/init`, so the relay keeps working and RAIDiator stays usable as a rescue system (without
`/c`).

Conditions (each one argued below):

1. The X-RAID superblocks are **never modified** (no section removed, no disk state changed):
   both disks stay "online" and both sections keep `inited` = 1, section 1 stays declared.
   With that, the 2.6.17 driver copies nothing at boot (it only copies sections whose `inited`
   is 0, XRAID-FORMAT.md §4.4).
2. The partition table (MBR of the base disk, EBR at LBA 4,608,032) is **never modified**:
   p5 keeps its start and size.
3. The md metadata sits inside section 1, so any **X-RAID copy** done by 2.6.17 (resync after an
   unclean RAIDiator shutdown, disk rebuild) turns the mirror member into a byte copy of the
   base member. Linux 6.18 must detect that and re-add the member (full md resync). Data are
   not lost **as long as the md is clean when 2.6.17 copies**.
4. During the migration window (mirror converted, base still X-RAID), **any boot that runs
   RAIDiator or DIET beyond `linuxrc`** may copy the base over the half-built md. Such boots are
   detected from the relay log and restart the migration (§5.2).
5. A **disk incident seen by 2.6.17** (a disk missing or failing at any boot, relay boots
   included) sets `inited` = 0 on every section; from then on **every** boot through 2.6.17
   starts copying base → mirror from the start of each section, until a copy completes. Track A
   then needs an incident procedure (§4.5) instead of a plain md re-add.

Still to validate on spare disks before use: §8.

## 1. Why the current `nas-raid migrate`/`create` is dangerous

`migrate` (XRAID.md §6.1) and `create` (§6.2) zero the first MiB and the last 4,096 sectors of
each disk and build an md on the **whole** disks. On this NAS every normal power-on runs iboot →
2.6.17 → `linuxrc` from the flash, whatever is on the disks. Then:

| Step (`linuxrc` of RAIDiator-Sparc 4.1.16, initrd `/linuxrc`) | Effect after `migrate --finalize` or `create` |
|---|---|
| l. 357–403: `X_RAID_START`, then `ROOTDEV` = first `hdX1` that is ext3 (else `/dev/hdc1` by default) | no MBR any more → no `hdX1` |
| l. 539–549: root device missing: if `/proc/sys/dev/raid/infrant_drives` = 1 → "Bad firmware" (halt, blinking LEDs); **otherwise `PARTITION=1`** ("Factory default initiated with unmarked drives and no root device!") | `infrant_drives` is the GPL `sysctl_speed_limit_old` (`drivers/md/md.c` l. 331) that `padre_io` sets through `padre_NSPIO.ssl_old` (l. 5551); set when the "WGam" marker at N − 2 is found (XRAID-FORMAT.md §1, "sure"), which the wipe erases |
| l. 764–830: factory default waits ~9 min for RAIDar, then continues with the defaults | |
| l. 832–1189: `X_RAID_CLEAR`, `sfdisk`, `mke2fs` p1, `mkswap`, `pvcreate` p5, `mke2fs` on LV `c` | **the md and the data are overwritten** |

So, independently of the relay, a migrated or "created" NAS that powers on normally (power cut,
forgotten TFTP interruption) most probably reinstalls itself and erases the data. The chain is
read from the scripts, the GPL kernel and the driver's functional notes (XRAID-FORMAT.md §1),
not observed on a NAS. Track A never touches the superblock either; note that its byte 0x80
(`utime`) must stay 0: at 1 `linuxrc` reinstalls the NAS (XRAID-FORMAT.md §2). With the relay installed, normal power-on is the
**everyday** path, and the relay itself (on p1) is gone anyway. Hence the safeguard of §9; it
should arguably cover every X-RAID NAS, not only those with the relay (decision left open).

## 2. What `linuxrc` and RAIDiator do with the disks (question 1)

Sources: RAIDiator-Sparc 4.1.16 (`initrd.img` `/linuxrc`, `root.tgz` `/etc/init.d/rc3`,
`/etc/hotplug/sata.agent`, `/etc/lvm/lvm.conf`), and `/frontview/bin/expand_xraid` and
`check_fsck_needed` read from this NAS's system volume (read-only, `fuse2fs -o ro` on `xr-p1`).

### 2.1 `linuxrc`, in boot order

| Lines | What | Track A impact |
|---|---|---|
| 173–185 | boot cause "diag": telnet + tunnel, stops | none |
| 220–227 | `boot_function_check` 1/2: rewrites the X-RAID feature bit in flash, reboots | not triggered by disk content we touch |
| 317–321 | `/proc/xraid` present → X-RAID mode; `RAID_INFO` state = 1 → `XRAID_INSTALL` | depends on the superblock only: **must stay untouched** |
| 323–354 | factory default if button, `XRAID_INSTALL`, or register 0x72000000 = 11111 | none |
| 357–364 | `X_RAID_START`; if not running: backup superblock (`X_RAID_COD_BACK READ`, `X_RAID_START_BACK`) | none |
| 365–405 | root = ext3 `hdX1` of the base disk; swap = `hdX2` of 256,000 KiB | p1/p2 kept |
| 539–549 | no root partition → halt or factory default (§1) | p1 kept |
| 557–597 | mount root; **`/sbin/init` missing** → `e2fsck`, then factory default unless `infrant_drives` = 1 or `/proc/lvm/VGs/c/LVs/c` exists (an LVM1 path that never exists with LVM2), otherwise firmware reinstall (`UPDATE=1`); mount fails → halt or `CREATE=1` | unchanged by track A (LV `c` never protected anything); the relay installer already keeps `/sbin/init` present at every moment |
| 602–633 | `os_reinstall` button, `.os_install` flags | user action only |
| 634–730 | flash update (`.cf_update_in_progress`) | user action only |
| 1191–1258 | firmware reinstall (`.os_update`): extracts `root.tgz` over p1 | puts RAIDiator's `/sbin/init` back (relay displaced, not the data) |
| 1597–1650 | after `pivot_root`: `vgscan`, `vgchange -ay`; LVs not in `fstab` are added; **`fstab` lines `/dev/[c-z]/…` whose LV is not active are deleted** and the mount point removed; `vgchange -an` | VG `c` gone → `/dev/c/c /c` removed from RAIDiator's `fstab` (a write to p1 only) |
| 1681–1710 | uploaded add-ons extracted to `/tmp/addons` | unchanged |
| 1788–1790 | `swapon` p2 | p2 kept |
| 1799–1800 | `chroot . /sbin/init` = `relay-init` | unchanged |

`linuxrc` never reads p5 except through LVM (`vgscan`), never writes it, and has no notion of
"section 1 valid": the X-RAID driver does not look inside the sections. The LVM filter
(`lvm.conf`) accepts `hd[cegikmoq][5-9]`, `hd…1[0-5]` and `md[2-9]`; LVM2 looks for its label in
the first 4 sectors of each device, so a PV that starts 1 MiB inside p5 (inside the md) is
invisible to it, and no `md[2-9]` is assembled under 2.6.17 (`raid=noautodetect`, `mdconfig`
only in non-X-RAID mode).

### 2.2 RAIDiator after `linuxrc` (only when the relay does not jump: rescue)

- `rc3` l. 154–164: `vgscan`/`vgchange -ay`: nothing found.
- `rc3` l. 171: `check_fsck_needed` looks at the ext3 lines of `fstab` (none left); `fsck -A`
  checks the root only.
- `rc3` l. 225–230: `expand_xraid` (Perl). With both disks online, no sync and no new disk it
  does nothing. **With a disk marked faulty and present it runs `X_RAID_ADD` (full copy from
  the base)**; with ≥ 60 GB between the X-RAID size and the sections it **creates a section /
  partitions and runs `pvcreate`** (lines 286–420 of the script). Keeping the superblock and
  the partition table unchanged avoids both.
- `rc3` l. 298–303: **`RESYNC_UNCLEAN_SHUTDOWN=1` (default) and `/var/lib/quota/check` present
  (the previous RAIDiator session did not shut down cleanly) → `X_RAID_SYNC_FORCE`**: the
  driver copies every section from the base to the mirror, p5 included (§3.3).
- `sata.agent` l. 13–17: hot-plug actions are ignored when no data volume is mounted, so a
  rescue RAIDiator without `/c` does not hot-add disks.
- `rc3` l. 342–353: pending add-ons are installed (`sh install.sh`), as today: Frontview's
  "update / add-on" upload stores the file on the root volume, so installing or removing the
  relay add-on keeps working without `/c` (to be confirmed, §8).

DIET (if installed) mounts `/c` from LVM on `hd[ce]5` itself: after the migration it finds no
VG and runs without data; during the migration window it would mount the old X-RAID `/c`
read-write (§5.2).

## 3. The X-RAID driver (question 2)

Functional notes of `padre_io` (RAIDiator-Sparc 4.1.16), summarised in XRAID.md §1:

### 3.1 Sections are not "assembled" separately

There is one array per NAS; `X_RAID_START` starts it with every section of the superblock.
A section is only an LBA range: writes falling into it are sent to all online disks **at the
same LBAs**, reads go to the first online disk, outside the sections a request goes to the
requested disk only. The driver does not interpret the content of a section (the only content
check known is an ext3 magic test, which p5 never passed since it holds LVM). Section 0 therefore
works whatever p5 contains.

### 3.2 Changing or removing section 1: rejected

- Removing section 1 from the superblock (or shrinking it) means rewriting the four superblock
  copies on both disks. Even though `sb_csum` is never checked, (a) the start-up checks ("Fix
  SB", counters, `l_size`) are only partly known, (b) a superblock judged invalid sets
  `RAID_INFO` state 1 → **factory default** in `linuxrc` (l. 319–337), and (c) a rescue
  RAIDiator would see ≥ 60 GB outside the sections and `expand_xraid` would create a section and
  partitions there. Too much risk for no gain.
- Keeping section 1 declared costs nothing: the driver has no idea of "empty", it simply keeps
  mirroring writes **made by 2.6.17** (there are none to p5 after the migration, §2).

### 3.3 When does the driver write into section 1 by itself?

Only when it copies a section from the base to another disk (`djsyncd`). Per XRAID-FORMAT.md
§4.2–4.5 (`X_RAID_START` itself only clears the clean bit, fixes counters and rewrites the
superblock in the protected zone; an unclean bit is only logged):

| Trigger | When | On a track A NAS |
|---|---|---|
| a section with `inited` = 0 and both disks online | `X_RAID_START` in `linuxrc`, i.e. **every boot, relay included, before `/sbin/init`**; a RAID 1 copy always restarts at the section start, and a relay jump stops it | only after a disk incident (below); `inited` is 1 on both sections of this NAS |
| a disk missing or failing at a 2.6.17 boot | driver: disk state 0, **every section `inited` = 0** | possible (cable, power, real failure) → the row above at every later boot |
| `X_RAID_ADD`/`X_RAID_REPLACE` (disk added, replaced, faulty disk back) | RAIDiator `expand_xraid`, `sata.agent`, Frontview | only after an incident |
| `X_RAID_SYNC_FORCE` (all sections, even `inited` = 1) | rescue RAIDiator after an unclean RAIDiator shutdown (§2.2) | possible |
| read error in a section ("XRAIDECC": rewrite from the other disk) | a 2.6.17 read in a section | only the first sectors of p5 are read (LVM scan) |
| `X_RAID_DRIVE_INIT`, factory default | new unmarked disk, `linuxrc` install | as today |

`init_mark` (+8) is ignored in RAID 1 (XRAID-FORMAT.md §2.3): its stale non-zero values on this
NAS are harmless. Reads in a section go to the **first online disk in channel order, on this NAS
SATA 0 = the mirror** (XRAID-FORMAT.md §4.1): under 2.6.17, p1 is read from the mirror (kept
intact by track A) and the LVM scan of `hd[ce]5` sees the mirror's p5.

The relay's hand-over runs the reboot notifiers (`kernel_restart_prepare`), so the X-RAID
"clean shutdown" bit is set before 6.18 starts: relay boots do not cause an unclean state.

A copy turns the mirror's p5 into a byte copy of the base's p5, **md superblock and bitmap
included**: both members then claim the same device role. Because metadata and data are copied
together, the result is consistent (the base member's state) and md can rebuild the mirror from
it (§4.4). Only one case loses data: the md was degraded with the base member stale (the mirror
held newer writes) and 2.6.17 copies the stale base over it. Rule: **never start RAIDiator
(rescue) while the md is degraded**; DIET should say so.

## 4. Design (question 3)

### 4.1 Layout (750 GB disks, both disks identical below V)

| LBA (512 B) | Content | Owner after migration |
|---|---|---|
| 0 | MBR (base only; mirror: zeros) | RAIDiator, untouched |
| 32 – 4,096,031 | p1, RAIDiator root + relay (section 0) | RAIDiator, untouched |
| 4,096,032 – 4,608,031 | p2, swap of 2.6.17 (section 1) | RAIDiator, untouched |
| 4,608,032 | EBR of p3/p5 (section 1) | untouched |
| 4,608,040 – 4,610,087 | p5 + 0 … 1 MiB: zeros, md 1.2 superblock at p5 + 4 KiB, internal bitmap | md |
| 4,610,088 – 1,465,112,335 | md data: LVM PV (VG `donnees`, LV `c`), ext4, 4 KiB blocks | md |
| 1,465,112,336 – V − 1 | end of section 1 outside p5 (8 MiB) | untouched |
| V – N − 1 | protected zone, X-RAID superblocks at N − 4096…, "WGam" at N − 2 | untouched |

Values are taken from `xraid-info` (`XR_P` of partition 5, `XR_V`), never hard-coded.
p5 starts at a multiple of 8 sectors (4 KiB aligned); with a 1 MiB data offset the md data and
the 32 MiB-aligned LVM extents stay 4 KiB aligned. Usable size: p5 − 1 MiB ≈ 696 GiB
(2.2 GiB less than whole-disk md: p1 and p2 are kept).

md parameters: `--metadata=1.2 --data-offset=1024` (KiB) `--level=1 --raid-devices=2
--bitmap=internal --name=donnees`. Metadata 1.2 (superblock at 4 KiB, data at an offset) is
required: with 0.90/1.0 the data, hence the PV label, would start at p5 sector 0 and RAIDiator's
`vgscan` would activate VG `donnees`, add it to its `fstab` (`linuxrc` l. 1630–1639) and run its
old `e2fsck` on ext4.

### 4.2 How Linux 6.18 finds it

The mirror disk has no MBR, so the kernel creates no `sdX5` for it; the base disk's `sdX5`
exists but is not used (it would duplicate a member). Members are dm-linear maps built from the
X-RAID analysis, like `xr-p5` today:

    dmsetup create xrmd-a --table "0 $P5N linear $BASE $P5S"     # base disk
    dmsetup create xrmd-b --table "0 $P5N linear $MIRROR $P5S"   # mirror disk
    mdadm --assemble /dev/md/donnees /dev/mapper/xrmd-a /dev/mapper/xrmd-b

`/etc/mdadm.conf`: `DEVICE /dev/mapper/xrmd-*` plus the `ARRAY` line, so that a scan never picks
`sdX5`. Changes needed in `xraid-compat` (not done):

- `xraid-info`: look for the md magic at p5 + 4 KiB (in addition to the whole-disk offsets) and
  report it (`XR_MD_P5=1`), keep reporting the X-RAID superblock (it stays valid).
- `nas-raid mount`: new mode `md-p5`: X-RAID found **and** md in p5 → the maps above, md
  assembly, LVM `donnees`, ext4 on `/c`; **no** `mdadm --build` of the sections, no fuse2fs.
  The X-RAID guards stay: no write outside p5, never sector 0, never beyond V.
- Same-role members (an X-RAID copy happened, §3.3): mdadm refuses or warns about "very similar
  superblocks". Then assemble with `xrmd-a` only (`--run`), mode `md-p5 member_cloned`, and
  offer "re-add the mirror" (`mdadm --zero-superblock /dev/mapper/xrmd-b`, `mdadm --add`):
  full resync, several hours. Exact mdadm behaviour to be checked on loop devices (§8.1).
- `add`: a disk replacement cannot be done from 6.18 (the new disk needs p1, p2, the EBR and an
  X-RAID superblock that the driver accepts). Procedure: replace the disk under RAIDiator (the
  X-RAID rebuild copies everything, the md member included), then re-add the member under 6.18
  as above. `grow`: not possible (p5 is fixed by the partition table): refused.

### 4.3 How 2.6.17 sees the migrated disks

Same MBR, EBR and partitions; p5 of type 0x8e without an LVM label at its start → no VG `c`.
Relay boots: `linuxrc` mounts p1, drops `/dev/c/c` from RAIDiator's `fstab`, starts
`relay-init`; nothing reads or writes p5. Rescue RAIDiator: §2.2 (no `/c`; copies only in the
cases of §3.3).

### 4.4 Consistency between the two kernels

| Event | Result | Handling |
|---|---|---|
| relay boot | nothing touches p5 | — |
| rescue RAIDiator, clean history | no copy | — |
| rescue RAIDiator after an unclean RAIDiator shutdown, or disk rebuild | mirror p5 = copy of base p5 | 6.18: `member_cloned`, re-add (§4.2) |
| same, md degraded with a stale base | newer writes of the mirror lost | forbidden by procedure; DIET warning |
| 6.18 crash / power loss | md bitmap resync at next 6.18 boot (the boot goes through 2.6.17 first, which does not touch p5 while `inited` = 1) | md |
| a disk missing at a 2.6.17 boot, then back | `inited` = 0: every 2.6.17 boot copies the start of each section base → mirror (the relay jump interrupts it, it restarts at the next boot) | §4.5 |

### 4.5 Disk incident procedure (to implement and test)

While any section has `inited` = 0 (`xraid-info` reports it as `sync_in_progress`), each boot
through 2.6.17 overwrites the beginning of the mirror's p5 (md superblock, bitmap, first GBs)
with the base's: the mirror member is a clone, consistent with the base member. 6.18 must then
assemble the md **from the base member only** (`member_cloned`, never `--add` while 2.6.17 can
still copy). Way out without writing the X-RAID superblock from Linux: one RAIDiator session
(`/.relay_skip_once`) long enough for the X-RAID copy to complete (sections back to
`inited` = 1, both disks online; hours), then under 6.18 re-add the mirror member (md resync,
hours). Writing the "sync done" state into the superblock from Linux (what XRAID-FORMAT.md §4.2
lists: `inited` 1, `init_mark` 0, disk state 1, counters, both copies on both disks) would avoid
the RAIDiator session but is a superblock write: not proposed until validated on spare disks.
A disk replacement follows the same path (RAIDiator rebuild, then md re-add).

## 5. Migration procedure (question 4)

Same logic as XRAID.md §6.1 (break, copy, verify, finalize), but only p5 is touched.
A = base disk, B = mirror disk.

### 5.1 Steps

Prior checks (as today): healthy X-RAID with both disks online and `inited` = 1 on every
section (otherwise every boot, relay included, copies A over B; `init_mark` is ignored), successful full
verification < 7 days, SMART, data in `/c` smaller than p5 − 1 MiB, relay boot working.
Plus: record the number of "starting the previous init" / "not tried" lines of
`/relay/relay.log` and the size of `/diet-boot.log` on p1 (read-only, `fuse2fs -o ro` on
`xr-p1`) in `/var/lib/nas-raid/migration`.

1. **break**: services stopped, X-RAID unmounted; then on B only, inside p5 only:

        dmsetup create xrmd-b --table "0 $P5N linear $B $P5S"
        dd if=/dev/zero of=/dev/mapper/xrmd-b bs=1M count=1        # old PV label of VG c (B's copy)
        mdadm --create /dev/md/donnees --run --metadata=1.2 --data-offset=1024 --level=1 \
              --raid-devices=2 --bitmap=internal --name=donnees /dev/mapper/xrmd-b missing
        # LVM donnees/c, mkfs.ext4 -b 4096, mdadm.conf (DEVICE /dev/mapper/xrmd-*)

   The X-RAID is mounted read-only from A alone (as today). B's MBR area, p1, p2, EBR,
   superblocks and "WGam" are not touched, so 2.6.17 still sees two online disks.
2. **copy**: `rsync -aH --numeric-ids --delete /c/ /mnt/md/` (resumable).
3. **verify**: `rsync -n -c`; stop on any difference.
4. **finalize** (after the checks of §5.2):

        dmsetup create xrmd-a --table "0 $P5N linear $A $P5S"
        dd if=/dev/zero of=/dev/mapper/xrmd-a bs=1M count=1        # PV label of VG c on A
        mdadm /dev/md/donnees --add /dev/mapper/xrmd-a              # resync B → A, hours

   `/c` = md. RAIDiator keeps booting (without `/c`), the relay keeps working.

### 5.2 The migration window

Between break and the end of finalize, the X-RAID still says "section 1 mirrored, both disks
online" while B's p5 holds the new md. A boot that goes further than `linuxrc` under 2.6.17
(relay fallback: no stick, `.relay_pending` after a failed 6.18 boot, `/.relay_skip_once`,
pending add-on; DIET; RAIDiator) can:

- mount the old `/c` read-write (RAIDiator, DIET): each write to A is mirrored **onto B at the
  same LBAs**, silently corrupting the copy;
- run `X_RAID_SYNC_FORCE`, or copy because a disk incident set `inited` = 0 (this one also
  happens on **relay** boots): B's p5 overwritten by A's (the md disappears from B).

Because 2.6.17 reads p5 from the mirror (§3.3), the LVM scan of `linuxrc`, RAIDiator and DIET
finds no VG `c` during the window (B's p5 starts with zeros and the md superblock): the old
`/c` is not mounted under 2.6.17, so the "mounted read-write" case is unlikely, and `linuxrc`
removes `/dev/c/c` from RAIDiator's `fstab` (it re-adds it by itself, l. 1623–1639, once VG `c`
is visible again, e.g. after an abort). The copy cases remain. Converting the **mirror** (not
the base) is what makes them harmless for the data: an X-RAID copy always goes base → mirror,
so it can only destroy the new half, never the original.

A's data are never at risk; B's copy is. Rule implemented by the design: at each mount during the
migration and right before finalize, `nas-raid` re-reads `relay.log` and `diet-boot.log`
(read-only) and the X-RAID superblock (`inited`, disk states, through `xraid-info`); if a 2.6.17
boot went beyond `linuxrc`, or a section is no longer `inited`, since the start, the copy is
untrusted and the migration goes back to **break** (B's p5 re-created, after §4.5 if needed). Finalize also re-runs the full
`rsync -c` comparison if that check cannot be made. The user should keep the stick in and avoid
RAIDiator/DIET until the end.

### 5.3 Going back (before finalize)

`nas-raid migrate --abort` (to write): md stopped, `mdadm --zero-superblock /dev/mapper/xrmd-b`,
migration state removed. B's p5 no longer matches A's: `xraid-info` reports `mirror_differs`
(read-only), and the existing `nas-raid repair` (md `--build` over the sections, `repair`)
copies A onto B where they differ (RAIDiator's own copy, `X_RAID_SYNC_FORCE`, only runs after
an unclean RAIDiator shutdown, so it cannot be relied on). Then `nas-raid verify`. After finalize there is no way back to the X-RAID `/c` (the data are on md);
RAIDiator itself still boots.

## 6. RAIDiator as a rescue system after the migration (question 5)

- **Boots**: yes, on the evidence of §2: p1 and `/sbin/init` are there, the X-RAID superblock is
  unchanged. It has no `/c` (fstab line removed), no shares; swap on p2.
- **Frontview**: should run (it lives on p1); add-on upload/installation is handled by
  `linuxrc` + `rc3` on p1 only. Not verified on a NAS without `/c` (Frontview may complain about
  the missing volume): §8.2.
- **Relay**: unaffected (p1, the stick, `relay-init` before RAIDiator's init).
- **Do not**: use Frontview's volume functions (factory default, volume creation/expansion),
  insert a new disk under RAIDiator unless replacing one (§4.2), boot RAIDiator while the md is
  degraded (§3.3).

## 7. Alternatives considered

| Option | Why not (yet) |
|---|---|
| Whole-disk md (current §6) | erases p1 (relay, RAIDiator, DIET); likely factory reinstall at next normal boot (§1) |
| Remove section 1 from the X-RAID superblock | superblock rewrite with partly known checks; factory default if judged invalid; `expand_xraid` would reuse the space (§3.2) |
| md 1.0 member running from p5 + 1 MiB to N − 4096, metadata beyond V (never copied by X-RAID) | an X-RAID copy would then change the data **without** the metadata noticing (silent divergence); relies on [V, N − 4096) being unused, unknown |
| No md metadata (`mdadm --build` over p5, ext4 inside, as today's compat mode) | X-RAID copies are harmless by construction, but no resync tracking: every crash needs the multi-hour `verify`; keeps today's weakest point |
| Keep X-RAID, only replace ext3 16 KiB by ext4 in LV `c` | needs a second copy of the data (no room) and RAIDiator would run its old `e2fsck` on ext4 |

## 8. To validate, and test plan

### 8.1 On the PC (no NAS)

- Loop devices of the real size layout (sparse): create the md inside "p5" of two images, copy
  member A over member B (simulating `X_RAID_SYNC_FORCE`), check mdadm's exact behaviour on
  assembly, and the `--zero-superblock` + `--add` recovery.
- RAIDiator's LVM2 (from `root.tgz`, under QEMU SPARC like `build-module.sh`, or by reading the
  label scan code): confirm that a PV label 1 MiB inside p5 is not found.
- Extend `make-images.py` with a "track A" scenario (X-RAID superblocks + MBR + md 1.2 at
  p5 + 4 KiB) and the `nas-raid` dry runs (no write before V, nothing outside p5).

### 8.2 On spare disks in the NAS (never on the data disks)

Two spare disks (any size ≤ 2 TiB), RAIDiator factory install, relay add-on, a few GB of test
data, an image of the flash-independent state (`dd` of both disks to a PC) before each step.
Serial console on.

1. Read the X-RAID superblocks (`xraid-info --json`) and record them; record `infrant_drives`
   and `/proc/xraid/configuration` under RAIDiator.
2. Track A migration (once coded), then each of: relay boot ×3; `touch /.relay_skip_once`
   → RAIDiator rescue boot; Frontview: install and remove a test add-on; clean shutdown;
   power cut under RAIDiator then RAIDiator boot (`X_RAID_SYNC_FORCE` expected) then 6.18
   (`member_cloned` expected, re-add); disk pulled under 6.18, then under RAIDiator.
   After each: X-RAID superblocks unchanged except the fields RAIDiator rewrites at every boot
   (`set_uuid0`, clean bit, counters), `inited` still 1, md state, `md5sum` of the test data.
   Key check: after several relay boots, the mirror's md superblock is **not** a clone of the
   base's (proves that `X_RAID_START` copies nothing while `inited` = 1).
3. Incident: one disk unplugged for one boot (relay), plugged back: confirm that each later
   relay boot copies the start of the sections (mirror member cloned), then the §4.5 way out.
4. Window test: break + copy, then a RAIDiator boot with `/c` written → the migration must
   restart (§5.2).
5. Optional, to confirm §1 on spare disks only: whole-disk `nas-raid create`, then a normal
   power-on: does `linuxrc` start a factory reinstall? (serial console: "Factory default
   initiated with unmarked drives and no root device!").

### 8.3 On this NAS, read-only

Nothing more is needed for the design. Already read: p1 holds `/relay` and `relay-init` as
`/sbin/init`; p5 = 1,460,504,296 sectors at 4,608,040 on the base disk `sdb`.

## 9. Immediate safeguard (superseded)

> Superseded: md support is now disabled altogether (`nas-raid migrate`, `create`, `add` and
> `grow` refuse on every NAS, relay or not; DIET no longer shows the md buttons). The relay
> check, its override option and `/var/run/nas-raid.relay` described below were removed with
> it. Kept for the record of the design.

- `nas-raid migrate` (start and `--finalize`) and `nas-raid create` refuse when the relay is
  installed on the RAIDiator system volume, or when that cannot be ruled out (an X-RAID is
  present but `xr-p1` is not mapped, or p1 cannot be read). Check: `fuse2fs -o ro` on
  `/dev/mapper/xr-p1` (read-only dm of an X-RAID mount), looking for `/relay/relay-switch`
  (present in every relay install, with or without DIET). In a dry run the refusal is printed
  and the plan still shown.
- Override, for a user who accepts losing RAIDiator, DIET and the relay (and the risk of §1):
  `--i-know-relay-will-break`. DIET does not offer it.
- `nas-raid mount` stores the result in `/var/run/nas-raid.relay` (`yes`/`no`/`unknown`);
  `nas-raid status --json` reports it as `relay`. DIET greys "Migrate to md", "Finish the
  migration" and "Create an md RAID" with the explanation (en/fr/de), and the API answers 409 to
  `raid_run` for these operations.
- Tests: `package/xraid-compat/tests/test.sh` (refusals, dry run, override, cache, JSON) and
  `package/diet/tests/test-api.sh` (JSON field, 409).
