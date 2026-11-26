# X-RAID on-disk format and RAIDiator behaviour (ReadyNAS Duo v1)

Reference for `package/xraid-compat`: what every byte of the X-RAID metadata
means, when RAIDiator 4.1 writes it, and what a Linux 6.18 writer must do to
stay consistent with it. `docs/XRAID.md` describes the compatibility layer
itself; this file is the format behind it.

Every statement carries its source and a certainty level:

| Tag | Source |
|---|---|
| **[bytes]** | the real superblocks of the NAS (2 × 750 GB, X-RAID created by RAIDiator 4.1), read with `dd` from Linux 6.18, read-only (Nov. 2026) |
| **[proc]** | a real `/proc/xraid/configuration` captured under RAIDiator |
| **[GPL]** | NETGEAR GPL kernel 2.6.17.8 (`drivers/md/md.c`, `drivers/ide/*`) |
| **[script]** | RAIDiator 4.1 scripts: `linuxrc` (initrd), `/etc/init.d/rc3`, `/etc/init.d/powerdown`, `/etc/hotplug/sata.agent`, `/etc/default/services` |
| **[dec]** | behaviour of the proprietary `padre_io` driver, understood from a local decompilation for interoperability only. Described in our own words; nothing from it is copied here or in the code |

Certainty: **sure** (two independent sources, or the real bytes), **likely**
(one source, consistent with the rest), **uncertain**.

All values in the examples below are the real ones except the volume
identifier and the disk serial numbers, which are replaced by examples.

## 1. Where the metadata lives

LBAs in 512-byte sectors; N = native size of the disk (IDENTIFY words
100–103), V = visible size (§3.1).

| LBA | Size | Content | Source, certainty |
|---|---|---|---|
| N − 4096 | 24 sectors | **current superblock** (the only copy read at boot) | [bytes][dec], sure |
| N − 4072 | 24 sectors | copy of the current superblock, written just **before** it | [bytes][dec], sure |
| N − 4048 | 24 sectors | **backup** superblock (read only by `X_RAID_COD_BACK READ`, used by `linuxrc` when the array refuses to start) | [bytes][dec][script], sure |
| N − 4024 | 24 sectors | copy of the backup, written just before it | [bytes][dec], sure |
| N − 2 | 1 sector | `WGam` followed by zeros | [bytes][dec][GPL], sure |
| rest of the last 10 MiB | — | zeros | [bytes], sure (on this NAS) |

- The superblock is 9,440 bytes (0x24E0); the rest of the 24 sectors is
  zero on the real disks [bytes].
- On the real disks the four copies are **byte-identical** on each disk, and
  the two disks only differ in `this_disk` (§2.5) [bytes].
- `WGam` means "disk prepared by an Infrant/NETGEAR NAS": at boot the driver
  sets `/proc/sys/dev/raid/infrant_drives` to 1 when it finds it, and `linuxrc`
  then refuses to re-create the volume (it shows "Bad firmware" instead of
  erasing the disks) when no system partition is found [GPL][dec][script],
  sure. **Never erase it** while a way back to RAIDiator is wanted.
- Integers are 32-bit **big-endian**: the SPARC writes its structure as it is
  in memory [bytes], sure.

## 2. Superblock layout

The header copies the names and layout of the md 0.90 superblock, but the
magic, size, position and meaning differ: mdadm must never be pointed at it
[dec], sure.

### 2.1 Header

| Offset | Name | Meaning | Real value | Source, certainty |
|---|---|---|---|---|
| 0x000 | magic | `WGao` (0x5747616F) = valid configuration; `WGan` (0x5747616E) = blank disk initialised by RAIDiator, ready for an expansion | `WGao` | [bytes][dec], sure |
| 0x004–0x00C | version | 0 / 1 / 0 | 0.1.0 | [bytes][proc], sure |
| 0x010 | — | unused | 0 | [bytes], sure |
| 0x014 | set_uuid0 ("ID") | last 4 bytes of the NAS MAC address; rewritten when RAIDiator starts the array (a NAS adopts the disks it starts); used to prefer the superblock of "this" NAS | e.g. 0x0A0B0C0D | [bytes][proc][dec], sure |
| 0x018 | ctime ("create_time") | **time of the last configuration change**, not only the creation: set at creation, when a disk is added and when a disk fails. The "most recent" superblock is chosen on it | 2012 date | [bytes][proc][dec], sure |
| 0x01C | level | always 1 when an X-RAID configuration exists (not the RAID level) | 1 | [bytes][dec], sure |
| 0x020 | size | V: smallest visible size of the members | 1,465,128,688 | [bytes][proc], sure |
| 0x024 / 0x028 | nr_disks / raid_disks | members, a missing ("fake") mirror included | 2 / 2 | [bytes][proc], sure |
| 0x030 (byte) | parity | relative channel (0 = SATA 0) of the parity disk = **the mirror** in RAID 1 | 0 | [bytes][proc], sure |
| 0x031 (byte) | ext_cmd | 1 if every member supports LBA48 | 1 | [bytes][proc][dec], sure |
| 0x032 (byte) | base | relative channel of the base disk | 1 | [bytes][proc], sure |
| 0x033 (byte) | fake | parity + 1 when the mirror is absent (one-disk X-RAID), else 0 | 0 | [bytes][dec], sure |
| 0x034–0x044 | set_uuid1..3, size_hi, l_size_hi | 0 | 0 | [bytes], sure |
| 0x048 | l_size ("lsize") | sum of the **declared** section sizes | 1,465,128,686 | [bytes][proc], sure |
| 0x080 | utime ("update_time") | **not a time**: a flag. `X_RAID_INSTALL` sets it to 1; at the next start the driver refuses to start the array and `linuxrc` performs a **factory reinstall**. Must stay 0 | 0 | [bytes][proc][dec][script], likely |
| 0x084 | state | bit 0 = **clean stop**: set to 1 when the array is stopped (reboot/halt), cleared when it is started. Reads 0 while RAIDiator runs | 1 | [bytes][proc][dec][GPL], sure |
| 0x088 / 0x08C / 0x090 / 0x094 | active / working / failed / spare disks | counters; recomputed and corrected by RAIDiator at each start | 2 / 2 / 0 / 0 | [bytes][proc][dec], sure |
| 0x098 | sb_csum | never computed, never checked: **there is no checksum** | 0 | [bytes][dec], sure |
| 0x09C–0x0B0 | events, recovery_cp, expand_image | inherited from md, unused | 0 | [bytes][dec], sure |
| 0x100 | layout ("luns") | number of sections | 2 | [bytes][proc], sure |
| 0x104–0x1FF | — | unused | 0 | [bytes], sure |

`drive_present` and `expandable_bitmap` in `/proc/xraid/configuration` are not
stored: the first is read from the SATA hardware, the second is the set of
disks whose magic is `WGan` [dec], sure.

### 2.2 Disk table: 12 × 128 bytes at 0x200

Indexed by IDE interface: entry 0 = internal PATA (never a member), **entry 1
= SATA 0** (`hdc` under RAIDiator, `sda` under 6.18), entry 2 = SATA 1 (`hde`,
`sdb`) [bytes][proc], sure.

| Offset | Name | Meaning | Real (entry 1 / entry 2) | Source, certainty |
|---|---|---|---|---|
| +0x00 | p_drive | 1 = parity/mirror disk | 1 / 0 | [bytes], sure |
| +0x01 | b_drive | 1 = base disk | 0 / 1 | [bytes], sure |
| +0x02 | c_chn | interface number (= entry index) | 1 / 2 | [bytes], sure |
| +0x03 | number | rank in the array (index into `diskid`) | 0 / 1 | [bytes][proc], sure |
| +0x07 | major | IDE major (22 = hdc, 33 = hde) | 22 / 33 | [bytes][proc], sure |
| +0x0B | minor | 0 (master) | 0 / 0 | [bytes][proc], sure |
| +0x0C | raid_disk | = number | 0 / 1 | [bytes][proc], sure |
| +0x10 | state | **0 faulty, 1 online, 2 spare, 8 ready** (added or rebuilding, not up to date yet) | 1 / 1 | [bytes][proc][dec], sure |
| +0x14 | present | 1 while the disk belongs to the array; 0 once RAIDiator has taken it out (replacement) | 1 / 1 | [bytes][proc][dec], sure |
| +0x18 | p_table | bytes 0x1C0–0x1FF of the disk's MBR (partition table + 55 AA); zeros for the mirror, which has no MBR | zeros / MBR | [bytes][dec], sure |
| +0x58 | size | V of this disk | 1,465,128,688 | [bytes][proc], sure |
| +0x5C–0x7F | — | 0 | 0 | [bytes], sure |

### 2.3 Section (LUN) table: 8 × 32 bytes at 0x800

Entries 0–6 are sections; entry 7 is a scratch area for command parsing [dec].

| Offset | Name | Meaning | Real (s0 / s1) | Source, certainty |
|---|---|---|---|---|
| +0x00 | — | 0 | 0 | [bytes] |
| +0x01 | number | section number | 0 / 1 | [bytes], sure |
| +0x02 / +0x03 | base / parity | relative channels | 1 / 0 | [bytes], sure |
| +0x04 | channel_image ("dmap") | bitmap of usable disks (bit n = relative channel n). RAID 1: disks `online` or `ready`. Recomputed by the driver | 3 / 3 | [bytes][proc][dec], sure |
| +0x05 | raid | 1 = mirror, 4 = dedicated parity (NV/NV+) | 1 / 1 | [bytes][proc], sure |
| +0x06 | alive | entry used | 1 / 1 | [bytes], sure |
| +0x07 | inited ("initialized") | **1 = the section is in sync.** 0 = RAIDiator must copy it again from the base: at creation (unless created `NOSYNC` on zeroed disks), and on **every** section when a disk fails or disappears | 1 / 1 | [bytes][proc][dec], sure |
| +0x08 | init_mark | sync watermark (absolute LBA). RAIDiator saves it during a RAID 4 sync and resumes from it; in **RAID 1 it is never used to resume** (a RAID 1 sync always restarts at the section start). It is zeroed when a sync completes or a disk fails, but can stay as a **stale non-zero value on a healthy RAID 1** | 0x00258020 / 0x00E2F020 | [bytes][dec], sure that it must be ignored in RAID 1; origin of the real values uncertain (§4.4) |
| +0x0C, +0x14, +0x1C | — | 0 | 0 | [bytes] |
| +0x10 | start | first LBA | 32 / 4,096,032 | [bytes][proc], sure |
| +0x18 | nr_sects | declared size | 4,096,000 / 1,461,032,686 | [bytes][proc], sure |

Section 1 is declared 30 sectors beyond V (the driver sets it to
`size − 4,096,000 − 2` at creation); nothing past V is ever mirrored
[bytes][dec], sure.

### 2.4 Unused area

0x900–0x145F: zeros [bytes], sure.

### 2.5 this_disk (128 bytes at 0x1460)

Copy of the table entry of the disk that holds this superblock: the **only
difference between the two disks** [bytes][dec], sure. The tools find the
role of a disk here (b_drive / p_drive), never from its Linux name.

### 2.6 diskid (4,096 bytes at 0x14E0)

8 × 512 bytes: the ATA IDENTIFY data of each member, by `number`, as the
2.6.17 kernel stores it after its byte-order fix-up: 16-bit words and
32/64-bit capacities big-endian, model and serial strings in reading order
(e.g. words 100–103 read as one 64-bit big-endian N) [bytes], sure. It holds
the **serial numbers**: never publish a dump. RAIDiator includes it when it
compares the superblocks of the disks [dec], sure.

## 3. Layout of the data

### 3.1 Visible size V

V = N − 20,480, except for a few disk classes where V is fixed so that a
replacement disk of the same nominal size always fits (750 GB: V =
1,465,128,688 for N = 1,465,149,168, as on the real disks) [bytes][dec], sure.
At least 4,096 sectors past V are always hidden.

### 3.2 Sections and partitions

Section 0 = [32, 4,096,032) (system, ext3, RAIDiator root `p1`), section 1 =
[4,096,032, V) (swap `p2`, extended `p3`, LVM `p5`). The base disk has an MBR;
the mirror's sector 0 is zero and is never written (outside the sections);
from sector 1 on both disks hold the same image at the same LBAs
[bytes][dec][script], sure.

## 4. RAIDiator behaviour

### 4.1 Writes and reads

- A write inside a section is sent to **every present disk at the same LBA**
  (hardware copy engine); the request completes after all the disks have
  reported [dec], likely.
- A read inside a section always goes to the **first `online` disk in
  channel order** — on this NAS SATA 0, i.e. **the mirror** [dec], likely.
  Consequence: if the two disks ever differ while both are marked online and
  in sync, RAIDiator silently reads the mirror's version.
- RAIDiator enables the disks' write cache on X-RAID (`000_Upgrade`, `rc3`)
  [script], sure; the driver flushes the disk caches before it writes a
  superblock [dec], likely.

### 4.2 When the superblocks are written

All superblock writes are synchronous PIO writes of 24 sectors, disk after
disk; for each disk the "bis" copy first, then the main one [dec], sure (the
real copies are identical, as expected). The driver refuses to write them
when more than one disk is missing [dec].

| Event | What changes | Copies written | Source, certainty |
|---|---|---|---|
| Module load | nothing (reads the current superblock of each disk) | — | [dec], sure |
| `X_RAID_START` (boot, `linuxrc`) | logs disks whose state bit 0 is 0 ("clean shutdown indicator"); clears bit 0; picks the reference superblock (most identical copies, newest ctime, right MAC), corrects the counters, takes a missing disk out (§4.5); MAC → set_uuid0 | current, then backup ("Update backup SB") | [dec][script], sure |
| Reboot / halt | md reboot notifier → driver stop: state bit 0 = 1 | current, then backup | [GPL][dec], sure; matches [bytes] |
| Disk failure | disk state 0, counters, every section inited 0 and init_mark 0, dmap, ctime = now | backup, then current, remaining disks | [dec], sure |
| Disk added / replaced | MBR written on a new non-mirror disk; disk state 8, size, diskid, ext_cmd, ctime = now; sync started (auto-sync) | current | [dec][script], likely |
| Sync of a section done | inited 1, init_mark 0; at the end disk state 1, counters | current, then backup | [dec], sure |
| Base MBR rewritten | p_table updated in memory, saved with the next superblock write | — | [dec], likely |
| `X_RAID_INSTALL` | utime = 1 → factory reinstall at next boot | current | [dec][script], likely |

### 4.3 After an unclean shutdown

- The driver **only logs** a superblock whose state bit 0 is 0; it does not
  resync because of it [dec], sure.
- The resync is decided by the scripts: `rc3` creates
  `/var/lib/quota/check` on the RAIDiator root (section 0) at each boot,
  `powerdown` removes it; if it is still there at boot and
  `RESYNC_UNCLEAN_SHUTDOWN=1` (the default), `rc3` sends `X_RAID_SYNC_FORCE`:
  a **full copy of every section from the base to the mirror**, even the
  sections marked in sync [script][dec], sure.
- So there is no partial resync and no write-intent bitmap.

### 4.4 Synchronisation

- At start (and after `X_RAID_SYNC*`), with every disk online, RAIDiator
  copies **every section whose inited is 0** from the base (or the first
  online disk if the base is not online) to the other disk; `X_RAID_SYNC_FORCE`
  also copies the sections with inited 1 [dec], sure.
- With a disk in state 8 (`ready`), that disk is the target [dec], sure.
- RAID 1 progress is not saved: an interrupted sync restarts at the section
  start. The watermark (+8) is only saved when the sync thread is stopped,
  and only consulted in RAID 4 [dec], sure.
- The real `+8` values (0x00258020 and 0x00E2F020, both 4096-sector
  aligned from their section start) are most likely positions where an
  earlier sync was stopped; why they were not cleared is not explained by
  the decompiled paths [bytes][dec], **uncertain**. Either way they do not
  mean "unsynchronised": `inited` does.
- Hotplug events `xraid_sync_started` / `xraid_sync_finished` drive the LEDs
  and the Frontview alerts [script], sure.

### 4.5 Missing, failed and new disks

- One disk missing at start: if it was online or ready it is failed as in
  §4.2 (degraded, every section inited 0); otherwise it is marked offline and
  the sections are also marked not in sync [dec], sure.
- More than one disk missing: the array does not start and no superblock is
  written [dec], sure.
- A new disk: `sata.agent` sends `X_RAID_REPLACE`, `X_RAID_ADD_NO_INIT`
  or `X_RAID_DRIVE_INIT` (zeroing) depending on the case; the disk becomes
  `ready`, is synced, then `online` [script][dec], likely.
- A disk must be at least `l_size + 2` sectors (visible) to be added [dec].
- Vertical expansion (`X_RAID_EXPAND`, run from `rc3`'s `expand_xraid`):
  only when the array is complete; sections are re-created over the new
  size; new disks may carry `WGan` [dec][script], likely; not studied
  further (Duo with 2 disks).

### 4.6 user_command

Accepted commands (exact strings) [dec][script], sure: `X_RAID_START`,
`X_RAID_STOP`, `X_RAID_START_BACK`, `X_RAID_CREATE[_NOSYNC]
lun:parity:start:size:level`, `X_RAID_CLEAR`, `X_RAID_DRIVE_INIT [chn]`,
`X_RAID_DISK_INIT`, `X_RAID_ADD[_NO_INIT] chn`, `X_RAID_KILL`,
`X_RAID_REPLACE from to`, `X_RAID_EXPAND`, `X_RAID_SYNC`,
`X_RAID_SYNC_ALL`, `X_RAID_SYNC_FORCE`, `X_RAID_CHECK[_DISK]`,
`X_RAID_UNCHECK`, `X_RAID_COD READ|WRITE n`, `X_RAID_COD_BACK READ|WRITE n`,
`X_RAID_CHECK_SB`, `X_RAID_INSTALL`, `X_RAID_BDL[_INIT|_ADD]`,
`X_RAID_ORG_SIZE`, `X_RAID_SKIP_INIT`, `X_RAID_DRIVE_RESET`,
`X_RAID_DRIVE_LBA`, plus debug commands. Only meaningful under RAIDiator.

## 5. Consequences for Linux 6.18

What `xraid-info` checks (read-only), each one a reason for read-only:

| Reason | Field |
|---|---|
| `unclean_shutdown` | 0x84 bit 0 = 0 |
| `reinstall_pending` | 0x80 ≠ 0 |
| `degraded` | failed ≠ 0, working < nr_disks or active ≠ working |
| `sync_in_progress` | a section with inited ≠ 1 |
| `disk_not_online` | disk state ≠ 1 or present ≠ 1 |
| `superblock_torn` | a superblock differs from its "bis" copy |
| `inconsistent_superblock` | layout ≠ sections found, l_size ≠ their sum, or header base/parity ≠ disk table |
| (ignored) | init_mark (+8) on a RAID 1 |

### 5.1 Writing coherently

Rules a writer must follow to stay what RAIDiator expects. They are
implemented by `xraid-sb` and `nas-raid` (docs/XRAID.md §2, §3); only
tried on disk images so far:

1. Change only `state` (0x84), the section `inited`/`init_mark` bytes and,
   for disk events, the fields RAIDiator itself changes (§4.2). Keep every
   other byte, `this_disk`, `diskid`, `set_uuid0` and `utime` (0) untouched.
2. Write each disk with `O_DIRECT|O_SYNC`: N − 4072 then N − 4096, then
   N − 4024 then N − 4048; flush the disk cache; read back and compare. Same
   content on both disks except `this_disk`.
3. At a read-write mount, before the first write: `state` bit 0 = 0 **and**
   `inited` = 0 on every section. At a clean unmount (md stopped, no failed
   leg, caches flushed): `inited` = 1, `init_mark` = 0, `state` bit 0 = 1.
   After a crash the sections stay "not in sync": RAIDiator then copies them
   base → mirror at its next start by itself (§4.4), and our safeguards keep
   Linux read-only until `nas-raid verify`/`repair` succeeds, which sets
   them back to 1.
4. A leg that fails under Linux: write on the surviving disk what RAIDiator
   would write (failed disk state 0, counters, inited 0, dmap, ctime = now),
   so that RAIDiator never reads the stale disk (§4.1) and never copies an
   old base over newer mirror data.
5. Disk replacement and expansion: left to RAIDiator (docs/XRAID.md §6).

Tests (`package/xraid-compat/tests/test.sh`): the writer's output compared
byte for byte with the RAIDiator superblock (only the listed fields change,
bis/main identical, `this_disk` and `diskid` kept), a crash between two writes
(`superblock_torn`, refused), inconsistent superblocks refused, idempotence, a
failed leg, and `rw` only after a successful verify.

### 5.2 Experiments that would settle the remaining points

They write to the disks and need the owner's decision (backup first); the
full list, with the new write paths, is in docs/XRAID.md §9:

1. **Clean bit only**: set 0x84 bit 0 = 0 in the four copies of both disks,
   boot RAIDiator, keep `dmesg` and `/proc/xraid/configuration`. Expected:
   "clean shutdown indicator: 0x3", no sync; after a clean RAIDiator
   shutdown the bit is back to 1 in all copies.
2. **Section resync**: set section 0 `inited` = 0 (2 GB) in the four copies
   of both disks, boot RAIDiator. Expected: "Prepare sync raid 1", a
   `RAID_REBUILD::sync=1` phase, then `inited` = 1 and `init_mark` = 0 on
   disk. This validates proposal 3.
3. **After a Linux read-write session** (no superblock writer): boot
   RAIDiator and compare its view with the data written under Linux.

## 6. RAIDiator with X-RAID off (md mode, "Flex-RAID")

Reference for `xraid-info flexraid` and `nas-raid` (docs/XRAID.md §10).
Sources added to those of the header: **[fv]** Frontview's code (`Frontview.pmc`,
ByteLoader bytecode whose op tree is stripped, disassembled op by op under QEMU
user mode, read for interoperability only), **[bin]** RAIDiator's binaries run
under QEMU. Test bench with RAIDiator's own tools: tools/raidiator-bench.
When the X-RAID function bit of the flash is 0, RAIDiator does not use the
X-RAID sections at all: its `linuxrc` builds ordinary Linux md arrays
[script][dec], sure.

| Item | Value | Source, certainty |
|---|---|---|
| Partitions (factory install) | p1 [32, +4,096,000) root, p2 swap, p3 data, all type `0xfd`, same table on every disk | [script], sure |
| Arrays (factory install) | `md0` root RAID 1, `md1` swap (RAID 1 on 2 disks), `md2` data: RAID 1 on 2 disks, RAID 0 on 1, RAID 5 on 3+ | [script], sure |
| Chunk | `mdconfig … -c 16`: 16 KiB (`mdconfig` usage: "chunk-size … (in KB)") | [script][bin], sure |
| Data volume | LVM on `md2`: VG `c`, LV `c` (32 MiB extents), ext3 mounted on `/c` | [script], sure |
| Other volumes | Frontview's "add volume": name = first free letter from `c` (VG = LV = mount point `/x`); md = lowest free `mdN`, N ≥ 2; one **primary** partition (type `0xfd`, at most 4 per disk, no logical ones) per member disk in its first free slot from 3, start on 8 sectors, whole MiB, never in the last 8 MiB; RAID 0 or RAID 1 on 2 disks, RAID 0 on 1; `vgcreate -s 32M` (16M, 4M fallbacks), LV = all extents but the snapshot reserve; `mke2fs -m0 -j -L x -b 16384`; added at the next boot | [fv], sure |
| `mdconfig` | creates arrays through the legacy md ioctls (`SET_ARRAY_INFO`, `ADD_NEW_DISK`, `RUN_ARRAY`): the kernel writes the 0.90 superblocks | [bin], sure |
| LVM format | **LVM2**: RAIDiator's LVM 2.02.07 with its `lvm.conf` creates LVM2 VGs (observed on the NAS's own kernel, tools/raidiator-bench/on-nas.sh). `rc3` converts LVM1 VGs (`vgconvert -M2`, after removing `x_*` snapshots) at each boot: those come from older firmwares. lvm2 2.03 cannot read LVM1: `xraid-info flexraid` reports such a VG (`content` `lvm1`, reason `lvm1`) | [bin][script], sure for new volumes |
| Snapshots | at most one per VG, LV `x_YYYY_MM_DD_HH_MM` in the free extents after LV `x` (chunk 256K) | [fv], sure |
| md superblock | **0.90**, last 64 KiB of each member, data from sector 0 | [GPL], sure |
| Byte order | **mixed**, seen on the NAS's own kernel (tools/raidiator-bench/on-nas.sh): `md.c` calls `padre_NSPIO.init(padre_1_xm)` around every superblock read and write (`swab_sb`), which byte-swaps the 32-bit words of the generic sections and the disk descriptors **but keeps the SPARC word order** (`events_hi` in word 39, `events_lo` in word 40, where an x86 superblock has them the other way round) and **leaves the personality section big-endian** (`layout`, `chunk_size`: 16 KiB stored as `0x00004000` big-endian). A PC's md reads the magic, levels and sizes right but the chunk as 4096K: it assembles a RAIDiator RAID 1 correctly, **a RAID 0 wrongly**. `xraid-info flexraid` recognises the layout (word 39 = 0 while word 40 ≠ 0; `byte_order` `raidiator`) and reads the chunk big-endian | [bin][GPL][dec], sure |

**Checksum and updates, seen on the NAS's own kernel** (tools/raidiator-bench):

- `sb_csum` (word 38) = ones' complement sum (end-around carry) of the 1024
  words of the superblock with word 38 counted as 0, each word **as RAIDiator's
  kernel sees it**: little-endian, except words 42 (`cp_events_lo`) and 65
  (`chunk_size`), stored unswapped (big-endian); 41 and 64 (`cp_events_hi`,
  `layout`) are 0 on every superblock seen. Checked on 19 superblocks out of 19,
  among them ones RAIDiator's kernel wrote at a stop. A word changed without
  this correction: `md: invalid superblock checksum on sdX`, yet the array is
  assembled anyway (a warning, not a refusal).
- RAIDiator's md **does not mark a RAID 1 in use while it is written**: the
  superblock on disk stays the same while the volume is mounted read-write and
  written; at the stop it rewrites it: `utime`, events and `cp_events` + 6,
  the members' device numbers (as found at this assembly), the checksum. A
  superblock with the clean bit cleared and events ahead of `cp_events` does
  not start a resync either (`sync_action` idle): after a crash, RAIDiator does
  not resynchronise a mirror by itself.
- The md driver of RAIDiator's kernel autodetects 0xfd partitions when they
  appear (a USB key included): `mdconfig -a autorun` assembles them without
  needing the device numbers recorded in the superblocks.

Consequences for the big-endian 6.18 kernel: it rejects these superblocks
("invalid raid superblock magic", harmless at autodetect), and
`mdadm --update=byteorder` would rewrite them big-endian, unreadable for
RAIDiator. So `xraid-info flexraid` reads them itself in either byte order
(the 32-bit words swapped; `events_lo`/`events_hi` are words 39/40 in the
x86 layout, 40/39 in the native one) and `nas-raid` maps them with
read-only dm targets, without md: RAID 1 = `linear` on one up-to-date,
in-sync member; RAID 0 = `striped`, members in `raid_disk` order, chunk from
the superblock. md's multi-zone RAID 0 (members of different sizes) is
refused, not mapped: RAIDiator partitions every disk alike.

To settle the uncertain points, `xraid-info flexraid --json`, `fdisk -l`,
`pvs` and `lvs` of a real Flex-RAID Duo (all read-only).
