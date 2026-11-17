# X-RAID on Linux 6.18: compatibility and safeguards

This document describes the `package/xraid-compat` package: read **and write** the
X-RAID volume created by RAIDiator (ReadyNAS Duo v1, 2 mirrored disks) without
converting it, keeping its superblock up to date the way RAIDiator does, so that
RAIDiator can take the disks back at any time. **md (Linux software RAID) is
disabled for now** (§6).

**Status:** reading has been checked on the NAS (real superblocks, read-only
mount). Writing, and the superblock updates that go with it, were only tried on
a PC with disk images (§8); the experiments that will validate them on the
NAS are in §9.

By default the X-RAID is mounted **read-only** (`XRAID_RW=no`). Writing
is only enabled after validation, by writing `XRAID_RW=yes` to
`/etc/nas-raid.conf` (by hand then `nas-raid remount`, or through the DIET switch
"Allow writing on the X-RAID", §7).

## 1. The X-RAID format in brief

Full field-by-field description, with sources and RAIDiator's behaviour:
`docs/XRAID-FORMAT.md`.

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
  address) at 0x14, date of the last configuration change at 0x18, V at 0x20, number of disks at
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
   table copied in the superblock and EBRs read on the mirror). Verdict:
   `rw`, `ro` or `none`, with the reasons. Only if writing is still possible
   (`rw` and `XRAID_RW=yes`): second analysis with the **comparison of
   `SAMPLES` (256) blocks of 64 KiB per section** at the same LBAs on both
   disks; a difference gives read-only (`mirror_differs`). See §2.1.
2. **Read-write** (all safeguards pass and `XRAID_RW=yes`):

        base disk     ──dm-linear [start, start+len)──┐
                                                     ├─ mdadm --build (RAID 1, NO superblock)
        mirror disk   ──dm-linear [start, start+len)──┘        = /dev/md10 (section 0), /dev/md11 (section 1)
        base disk partitions ── dm-linear on md1x ── /dev/mapper/xr-p1, xr-p2, xr-p5
        xr-p5 ── LVM (vgchange -ay c, read-only metadata) ── /dev/mapper/c-c
        /dev/mapper/c-c ── kernel ext4 driver (ext3 with 16 KiB blocks) ── /c

   Each write therefore goes to both disks at the same LBAs, exactly
   as RAIDiator did, and only **inside the sections bounded to V**.
   The base disk is the first member (source of a repair).
   **Before** the md are built, `xraid-sb dirty` marks the superblock of both
   disks "in use", as RAIDiator does while it runs: clean-stop bit (0x84 bit 0)
   at 0 and every section "not in sync" (`inited` 0). If that write fails, the
   volume is mounted read-only (`sb_write_failed`); without `xraid-sb`,
   read-only too (`no_sb_writer`).
3. **Read-only** (a safeguard refuses writing): no md; the
   partitions are mapped directly onto a single disk (the base if it is
   "online", otherwise the mirror) with `dmsetup --readonly`, LVM with
   `read_only_volume_list`, and `mount -t ext4 -o ro` (`ro,noload` if a
   journal is left to replay: it cannot be replayed on a read-only device).
4. If a disk carries an md superblock (made by an earlier version), the md is
   mounted on `/c` (`mdadm --assemble --scan`, VG `donnees`, ext4).

At shutdown (`S35storage stop`, so also reboot and power-off through `rcK`;
`nas-raid unmount`): unmount, LVM deactivated, then, for a read-write X-RAID:

- the state of each md is read **before** stopping it (`/proc/mdstat` and
  `sync_action`);
- md stopped, dm removed (everything flushed);
- both legs `[UU]` and nothing resyncing: `xraid-sb clean` (bit 0 = 1,
  `inited` = 1, watermark 0: what RAIDiator writes at a clean stop) and the
  `xraid-dirty` marker is removed;
- a leg failed: `xraid-sb fail` on the surviving disk (§2.2);
- otherwise (resync/repair still running, md missing, failed assembly): the
  superblock stays "in use". RAIDiator would then copy base → mirror at its
  next start; Linux stays read-only until a successful `nas-raid verify`.

`nas-raid remount` (X-RAID only): first unmounts
`/c` alone and stops there if `umount` is refused (open file: the
volume stays mounted as it is), otherwise `unmount` then `mount` with all the
safeguards. Used after a change of `XRAID_RW`.

### 2.1 Mount time

Measured on the NAS: `xraid-info --samples 256` on both disks takes 34.8 s
cold (20 s warm), `--samples 32` 5.8 s, without samples 0.1–1.2 s; dmsetup,
LVM and the mount about 2 s. The comparison only protects **writing** (two
disks that differ would be written as a mirror): read-only reads the base
disk alone and a difference cannot damage anything. So `nas-raid mount` (and
`remount`) first runs `xraid-info` without samples, decides with all the
other safeguards, and compares the disks only if the result is still `rw`
with `XRAID_RW=yes`. A read-only boot (the default) therefore mounts `/c` in
about 2–3 s instead of ~37 s; a rw boot keeps the full comparison.
`SAMPLES` in `/etc/nas-raid.conf` changes the number of blocks (0 = no
comparison, not recommended for rw).

The swap (`p2`) and the RAIDiator root (`p1`) are not used (the RAIDiator
swap has 16 KiB pages; so does Linux 6.18 now, but nothing needs it).

### 2.2 A leg that fails while writing

`S35storage` runs `nas-raid watch` every 30 s. On a read-write X-RAID, as soon
as an md shows a missing leg (`[U_]` or `[_U]`: I/O error, disk pulled), it
writes on the **surviving** disk what RAIDiator writes when it fails a disk
(`xraid-sb fail`: failed disk state 0, counters 1/1/1, every section not in
sync, `dmap` = survivor, `ctime` = now), stops SMB and NFS, and remounts `/c`:
the safeguards then see the failed disk and mount read-only on the survivor.
If `/c` is busy it stays mounted on the survivor (md keeps working) until it
can be unmounted; the failure is already recorded. Why: RAIDiator reads the
first online disk (on this NAS, the mirror), so a stale disk must never be left
marked online and in sync.

A missing disk at boot: read-only on the present disk (`missing_disk`),
nothing is written.

## 3. Safeguards

| Situation | Effect |
|---|---|
| `XRAID_RW` ≠ `yes` (default) | read-only (reason `rw_disabled`) |
| Superblock missing, version ≠ 0.1.0, inconsistent sections, two "base" disks | nothing is mounted |
| Current superblock missing (backup only) or different from one disk to the other | read-only |
| **Unclean shutdown** recorded by RAIDiator (bit 0 of 0x84 at 0) | read-only, until a successful full check (§4) |
| **A disk is missing** or single-disk configuration | read-only on the present disk |
| **Section not in sync** (`inited` 0: left "in use" by Linux or RAIDiator, disk rebuilding/spare) | read-only, until a successful full check |
| RAIDiator counters show a failed disk, disk not present, `superblock_torn`, `inconsistent_superblock`, `reinstall_pending` (docs/XRAID-FORMAT.md §5) | read-only |
| `xraid-sb` missing or the "in use" mark cannot be written | read-only (`no_sb_writer`, `sb_write_failed`) |
| Section that is not a mirror (NV+ RAID 4) | read-only |
| **Mismatched samples** at the same LBAs (compared only before a rw mount, §2.1) | read-only (`mirror_differs`) |
| Partition that overflows the sections or V | read-only |
| Crash **under Linux** (marker `/var/lib/nas-raid/xraid-dirty` left behind) | read-only, until a successful full check or quick check (§5.1) |
| A leg fails while writing | failure recorded on the survivor, read-only (§2.2) |

Always: `xraid-info` opens the disks read-only only; the protected area is only
written by `xraid-sb`, and only its four superblock copies (no dm table goes
beyond V; checked by the tests). `xraid-sb` refuses (nothing written) unless
every copy on every disk is a valid, untorn, consistent two-disk RAID 1
superblock; it changes only the fields RAIDiator itself changes, keeps
`this_disk`, the IDENTIFY data, the identifier and the reinstall flag, writes
per disk the copy then the main copy (`O_DIRECT|O_SYNC`), flushes the disk
cache, reads back and compares, and writes nothing when nothing changes. No md superblock
(`--build`); read-only LVM metadata (`metadata_read_only`).
Only one `nas-raid` action at a time (lock).

## 4. Risks and limits

- **No partial resynchronisation**: a power cut during a write leaves the
  superblock "in use" (and the `xraid-dirty` marker on the USB stick): read-only
  until `nas-raid verify` (several hours) puts it back clean (or a quick
  check, §5.1, accepted with its residual risk), or RAIDiator
  copies the whole sections base → mirror at its next start (as it does after
  its own crashes). There is no write-intent bitmap, in RAIDiator either.
- The superblock writes have only been tried on disk images (§9 lists the
  experiments that validate them on the NAS).
- Disk replacement and vertical expansion are left to RAIDiator (§6).
- Do not reassemble the md by hand with `--assume-clean`.
- The ext3 with 16 KiB blocks is mounted by the kernel's ext4 driver: this
  needs pages at least as large as the blocks, hence the 16 KiB pages of the
  Padre kernel (patch `linux/0003`, like the stock 2.6.17 kernel). Before,
  fuse2fs (user space) read 3.3 MiB/s and wrote ~110 KB/s; the kernel reads
  11.8 MiB/s (200 MiB, cold cache, disks in PIO). ext4 does not add any
  ext4 feature to an ext3 it mounts: RAIDiator can still read it. A journal
  to replay still prevents a read-write mount if it fails (run fsck on a PC
  first).
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
  `xraid-dirty` marker and puts the superblock back clean (`xraid-sb clean`,
  refused unless both disks are online and their superblocks agree).
- `nas-raid repair --confirm REPAIR --yes`: only if the reasons are
  "unclean shutdown", "section not in sync" or "mismatched samples". Marks the
  superblock "in use", assembles read-write and
  runs `repair` on each md: the base is copied to the mirror where they
  differ. Then `nas-raid verify`, then reboot.

### 5.1 Quick check

`nas-raid quick-verify` (or "Quick check" in DIET) compares base and mirror in
1 to 3 minutes instead of 10–12 hours, where a power cut in the middle of a
write most likely leaves them different (`xraid-info quick BASE MIRROR`,
read-only; `--list` prints the ranges without comparing them):

| Category | What | Located by |
|---|---|---|
| `partition` | EBRs of the extended partition (the MBR exists on the base only) | MBR, EBR chain |
| `lvm` | start of `p5` up to `pe_start`: LVM label and metadata | `LABELONE` label (`pe_start`) |
| `superblock` | ext3 superblock + group descriptors, and their backups (groups 0, 1, powers of 3, 5, 7) | ext3 superblock |
| `bitmap` | block and inode bitmaps of every group | group descriptors |
| `inode_table` | inode table blocks holding at least one inode in use on either disk (inode bitmaps OR'd; capped at 256 MiB, the rest left to the samples) | inode bitmaps |
| `journal` | the ext3 journal (inode 8), data and indirect blocks | inode 8, `i_block` (direct, IND, DIND, TIND) |
| `sample` | `QUICK_SAMPLES` (512) random 64 KiB blocks per section, new positions at each run (seed printed) | — |

for both file systems: the system one (`p1`, section 0) and the data one (LV
`c`). The data volume is located in C, without LVM tools (nothing is needed
from the running system, it works mounted or not): LVM label on `p5` →
metadata text (circular buffer) → the PV whose `id` is the label's UUID →
`extent_size` and the linear segments of LV `c` (`start_extent`,
`extent_count`, `stripes = [ "pvN", pe ]`) → disk LBA =
`p5 + pe_start + pe × extent_size + offset`, the same on both disks. Every
range is clipped to the sections, sorted by LBA (one pass per disk), read in
1 MiB pieces; a mismatch is read again three times (write in progress) like
`verify`. Output: bytes compared and differing pieces per category, the
differing LBAs with their category and file system, notes. Exit code: 0
identical, 1 differences, 2 read errors, 3 identical but **incomplete** (a
file system, the LVM metadata or a journal could not be located: extent-mapped
journal, segment on another PV, unknown format).

**What it guarantees**: the file system structure is consistent between the
disks: superblocks, descriptors, bitmaps, in-use inodes and the whole journal
(where ext3 writes every metadata change first), plus LVM and the partition
table. **What it does not**: file *data* blocks are not journaled (ext3
`data=ordered`): a file being written at the time of the cut can differ
between the disks outside the compared areas, and only the samples may see it
(on the test images a difference placed in a free data block is not found by
the quick check, and found by `verify`). Directory blocks are not compared
either (they are journaled, so a torn update shows in the journal). After an
accepted quick check such a block would read differently depending on the
disk; `verify` then `repair` remove that risk.

Decision (`nas-raid quick-verify`, same lock and log as `verify`; state in
`/var/lib/nas-raid/quick.state`, result JSON in `quick.res`, progress in
`quick.progress`, all in `nas-raid status --json` under `quick`):

- no difference, superblock **clean** (bit 0 of 0x84 at 1, sections inited),
  only the Linux `xraid-dirty` marker left: the marker is removed (logged),
  writing allowed at the next mount. The superblock is not touched.
- no difference, superblock **unclean** (real crash, or RAIDiator stopped
  uncleanly): nothing is lifted; state `confirm` and a token
  `/var/run/quick.ok` (superblock ID and date) valid for this boot only: it disappears at any
  mount/remount and any read-write assembly. `nas-raid quick-accept --confirm
  ACCEPT --yes` (DIET: dialog with a box to tick and the word `ACCEPT`) then
  does exactly what a successful `verify` does (marker removed,
  `xraid-verified`, `xraid-sb clean`), and only if the superblock has not
  changed, the reasons are only `unclean_shutdown`/`sync_in_progress` and
  nothing is assembled for writing. This is a **residual risk accepted by the
  administrator** (see above), logged as such.
- a difference: nothing is lifted, state `differences` (reason
  `mirror_differs` at the next rw attempt): repair needed as today (§5).
- `incomplete` or `errors`: nothing is lifted.
- the X-RAID mounted read-write: the result is informative, nothing is lifted.

**Volume and duration on the NAS** (750 GB disks, estimates: the
geometry of the data volume was not read on the NAS; `xraid-info quick
--list` gives the exact list). LV `c` ≈ 697 GiB = 45.7 M blocks of 16 KiB,
131,072 blocks per group → ~350 groups. Journal: mke2fs gives a 32,768-block
journal to a volume this size = **512 MiB** (64 MiB for the 2 GB `p1`);
bitmaps 350 × 32 KiB = 11 MiB; superblock/descriptor copies ~20 × 32 KiB;
inode tables in use: a few MiB for some tens of thousands of files (capped at
256 MiB); samples 2 × 512 × 64 KiB = 64 MiB. In all ~0.6–0.9 GiB per disk.
Measured rates: sequential ~35 MB/s for both disks together (full verify:
2 × 700 GB in 10–12 h), random 64 KiB samples ~70 ms each (256 per section:
35 s). Journals ~35–40 s, bitmaps and inode tables (one seek per group,
adjacent ranges) ~25–40 s, samples ~70 s: **about 2–2.5 minutes**.
`QUICK_SAMPLES` in `/etc/nas-raid.conf` trades samples against time (256: −35 s).

## 6. md: disabled for now; replacement and expansion

`nas-raid migrate`, `create`, `add` and `grow` are refused ("md support is
disabled for now: X-RAID only"), and so are the matching DIET actions. The
former versions erased the end of the disks, the "WGam" mark included; without
it RAIDiator's `linuxrc` reinstalls the NAS instead of reporting an error
(docs/XRAID-FORMAT.md §1). A safer path that keeps section 0 is studied in
docs/XRAID-MIGRATION.md (future work). An md volume made by an earlier version
is still mounted.

**Replacing a disk or expanding the volume** is left to RAIDiator, which knows
how to rebuild and keeps its superblock consistent:

1. On 6.18, `touch /.relay_skip_once` (board/readynas-duo-v1/relay), then
   reboot: RAIDiator starts once.
2. In RAIDiator (Frontview), replace the disk (hot swap) and wait for the end
   of the rebuild (`RAID_REBUILD::sync=0` in `/proc/xraid/configuration`, all
   disks `online`). Expansion likewise, one disk at a time.
3. Reboot: the relay starts 6.18 again, which finds a clean, complete X-RAID.

## 7. DIET dashboard

The "Storage /c" card shows the mode (X-RAID read-write, X-RAID
read-only, md RAID), the reasons for a read-only mount, the superblock (clean,
or in use / unclean shutdown), each disk (bay, role, online/faulty/ready), the
RAIDiator counters, the state of each section and the last mirror check. Buttons:
"Check the mirror", "Quick check" (§5.1: state, progress, result, and
"Accept the quick check…" when it is offered) and "Storage log" (no md action: §6). In X-RAID mode, the "Allow writing on the
X-RAID" switch (disabled when `xraid-sb` is missing) writes `XRAID_RW` (enabling: warning, checkbox and
the word `WRITE`), stops the services that use `/c` for the time of a
`nas-raid remount`, then restarts them; if a safeguard refuses, the card stays
read-only with the reason (docs/DIET.md). API: `GET ?a=storage` (`nas-raid status
--json`, without disk access: result cached at mount time), `POST
?a=raid_verify|raid_quick|raid_quick_accept|xraid_rw` (`raid_quick_accept`: `confirm=ACCEPT&yes=1`) (`raid_plan`/`raid_run`: 409, md disabled), log `?a=log&f=storage`.

## 8. Tests on a PC (no NAS, no root)

    sh package/xraid-compat/tests/test.sh
    sh package/diet/tests/test-api.sh

`tests/make-images.py` builds images as sparse files (750 GB
apparent, a few MB real): superblock, copies, backup, "WGam", MBR on
the base only, EBR, sections, made-up IDENTIFY data, with the clean, dirty,
degraded, unfinished synchronisation, mismatched mirror, md disk, reinstall
flag, failed-disk counters and torn superblock scenarios. The tests check
detection, the JSON, the full check, the verdicts, the assembly
commands (no table beyond V), the real `xraid-sb` on the images (byte for byte
against the RAIDiator superblock: only the expected fields change, the four
copies stay identical; idempotence; refusals of torn or inconsistent
superblocks), the sequences "in use" → clean, power loss → verify → clean,
leg failure → `fail` on the survivor → read-only, missing disk → nothing
written, the refusal of the md commands, and the DIET API. dmsetup, mdadm, lvm and mount are simulated: no
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
    nas-raid status; nas-raid mount --dry-run
    cat /var/run/nas-raid.mode; ls /c; df /c                           # read-only mount done by S35storage
    lvm lvs --config 'devices { filter = [ "a|^/dev/mapper/xr-p|", "r|.*|" ] }'

To check: `od -A d -t x1 -j 8388608 -N 4 /end-sdX.bin` gives `57 47 61 6f`
("WGao" at N − 4096, big-endian); `xraid-info` answers `rw` or `ro` with
consistent reasons; sections 32 / 4096000 and 4096032 / 1461032686;
base = the disk that has an MBR; `ls /c` readable; LVM without snapshots; plausible
SMART values (power-on hours). These readings were done (Nov. 2026).

Experiments that write to the disks, to be decided by the owner (backup first;
after each one, read the four copies back with `dd` as above and compare with
`tests/sb.py diff`):

1. **Clean-stop bit**: from 6.18, `xraid-sb dirty` (both disks) without
   mounting rw, then boot RAIDiator once (`.relay_skip_once`). Expected:
   "clean shutdown indicator" in its `dmesg`, a sync of both sections (inited 0)
   base → mirror, then after a clean RAIDiator shutdown all copies clean again
   (bit 0 = 1, inited 1, watermark 0).
2. **Read-write session**: `nas-raid verify`, `XRAID_RW=yes`, remount, write a
   few files, `nas-raid remount` with the switch off: `xraid-info` must show a
   clean superblock again; `nas-raid verify` identical; boot RAIDiator once:
   no sync, files readable from Frontview/SMB.
3. **Power loss under Linux**: rw mount, write, cut the power. At the next 6.18
   boot: read-only (`unclean_shutdown sync_in_progress`). Then either
   `nas-raid verify` (back to clean, rw allowed), or boot RAIDiator once: it
   must resync base → mirror by itself.
4. **Leg failure**: rw mount, pull the mirror disk (hot plug): within 30 s,
   `nas-raid.mode` = `xraid-ro`, the base superblock shows the mirror
   `faulty`. Boot RAIDiator with the disk put back: it must take the base as
   reference and rebuild the mirror.

## Files

| File | Purpose |
|---|---|
| `package/xraid-compat/src/xraid-info.c` | analysis, full and quick check, SMART (read-only) |
| `package/xraid-compat/src/xraid-sb.c` | superblock updates: dirty, clean, fail (the only writer of the protected area) |
| `package/xraid-compat/src/nas-raid` | mount, unmount, watch, check, quick check, repair |
| `package/xraid-compat/src/S35storage` | boot, shutdown, watch every 30 s |
| `package/xraid-compat/tests/` | fake images and tests |
| `/etc/nas-raid.conf` (on the NAS, optional) | `XRAID_RW`, `SAMPLES`, `EXT4_OPTS`… (variables at the top of `nas-raid`) |
| `/var/lib/nas-raid/` (on the NAS) | markers, check, log (`log`) |
