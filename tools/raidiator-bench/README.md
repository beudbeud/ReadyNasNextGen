# RAIDiator md-mode ("Flex-RAID") test bench

Builds fake disks the way RAIDiator 4.1.16 does with X-RAID switched off, using
**RAIDiator's own SPARC binaries** run under QEMU user mode on the PC, then reads
them back with `xraid-info flexraid` (docs/XRAID.md §10) and checks the result
against what Linux md assembles from the same disks. This is the independent
check the unit tests (`package/xraid-compat/tests`, self-made images) cannot give.

## What runs where

| Step | Tool | Notes |
|---|---|---|
| partition table | RAIDiator's `sfdisk`, under QEMU | the `linuxrc` "MD install" layout: p1 root, p2 swap, p3 data, type 0xfd |
| md arrays | `mdcreate.c`: the same legacy md ioctls as RAIDiator's `mdconfig` (`SET_ARRAY_INFO`, `ADD_NEW_DISK`, `RUN_ARRAY`, 0.90, chunk 16 KiB). `mdconfig` itself cannot run under QEMU user mode, which does not pass md ioctls through ("Unsupported ioctl" on `SET_ARRAY_INFO`); mdadm 4.x refuses RAID 0 on 0.90 | the kernel writes the md 0.90 superblocks in both cases: the host's, little-endian, like RAIDiator's patched kernel (docs/XRAID-FORMAT.md §6) |
| LVM | host `lvm` (lvm2 format, as RAIDiator's 2.02.07) | VG = LV = volume name, 32 MiB extents |
| file system | RAIDiator's `mke2fs -m 0 -j -L NAME -b 16384` and `tune2fs -c0 -i0`, under QEMU | a known file written with the host's `debugfs` (16 KiB blocks: no mount needed) |
| check | `xraid-info flexraid` built for the host, `dmsetup --readonly`, host `lvm` (read-only), `debugfs` | every usable array mapped with **our** dm table must have the same sha256 as md's array; the file must be read back through our maps |

The superblocks are written by the PC's kernel, not RAIDiator's: the bench
validates the layout (partitions, members, chunk, LVM, ext3), not RAIDiator's
byte swapping. That one still needs a real NAS.

## Use

Needs: `mdadm`, `lvm2`, `e2fsprogs` (debugfs), `xz-utils`, a C compiler, and
the decrypted RAIDiator 4.1.16 `root.tgz` (not in this repository: NETGEAR's).
QEMU is not installed: `prepare` unpacks the `qemu-user` package in `work/`.

    sh tools/raidiator-bench/bench.sh prepare /path/to/root.tgz
    sudo sh tools/raidiator-bench/bench.sh run                 # every scenario
    sudo sh tools/raidiator-bench/bench.sh run factory-raid0   # one of them
    sudo sh tools/raidiator-bench/bench.sh clean               # after an interrupted run

`run` refuses when md0-md9 are in use on the PC; it only touches the loop
devices it creates, md0-md9 and dm devices named `rb-*`. Everything goes to
`work/` (git-ignored): images, `bench.log`, the outputs of `xraid-info`.

## Scenarios

| Name | Disks | Built | Expected from xraid-info |
|---|---|---|---|
| `factory-raid1` | 2 | linuxrc default: md0 RAID 1, md1 RAID 1, md2 RAID 1 (volume c) | all usable; still all usable with one disk |
| `factory-raid0` | 2 | install with RAIDLEVEL=0: md1 and md2 RAID 0 | all usable; with one disk the RAID 0 arrays are refused |
| `single` | 1 | one-disk install: md2 RAID 0 on one member | all usable |
| `stale` | 2 | md2's first member failed before volume c was written | md2 read from the up-to-date member |
| `split` | 2 | Frontview's two volumes on both disks: p3 RAID 1 (c), p4 RAID 0 (d) | all usable; with one disk, d (RAID 0) refused, c read |
| `snapshot` | 2 | factory RAID 1 with Frontview's snapshot reserve and an active snapshot LV `c_YYYY_MM_DD_HH_MM` | all usable, volume c read |
| `lvm1` | 2 | volume c in LVM1 format (a VG left by an older firmware: RAIDiator's own LVM 2.02.07 creates LVM2, as seen on the NAS), by that LVM under QEMU with `-M1` | md2 reported `lvm1`. Skipped for now: that LVM crashes under QEMU user mode (once its sysfs filter, fooled by QEMU's device numbers, is turned off); the unit tests cover the detection |

The list of layouts RAIDiator can produce on a Duo, and where each one comes
from (linuxrc, Frontview disassembled under QEMU), is in docs/XRAID-FORMAT.md §6.

## On the NAS's own kernel (on-nas.sh, nas-check.py)

The QEMU bench cannot check what only RAIDiator's kernel does: its md.c writes
the md 0.90 superblocks in a mixed byte order (docs/XRAID-FORMAT.md §6), which
the PC's kernel does not reproduce. `on-nas.sh` runs on the Duo itself, booted
on RAIDiator or the old DIET (both use RAIDiator's 2.6.17 kernel), with
RAIDiator's own `mdconfig`, `raidhotadd`/`raidsetfaulty`/`raidhotremove`, LVM
2.02.07, `mke2fs` and `tune2fs` (copied from the sysroot with their libraries,
run through their `ld-linux.so.2`, nothing installed). Fake disks: one file
per member partition (`dDISKpPART.img`) on a USB key, never the NAS's disks.

Safety: loops 0-7 and md5/md6 only (refused if in use); LVM filtered to
md5/md6 and **always called with a VG name** (unnamed, RAIDiator's LVM acts on
every VG it sees, the NAS's own `c` included); test VGs must start with `rb`;
everything is undone at the end, even after a failure (a temporary
`/etc/mtab` link, needed by e2fsprogs 1.40 on DIET, included).

    # on the NAS (root), TOOLS = the bundle, WORK = an empty folder on the key
    sh on-nas.sh TOOLS WORK [base failed rebuild spare single snapshot delete]
    # back on the PC, no root: rebuilds the disks, reads them with xraid-info,
    # follows LVM and reads the files the NAS wrote, with debugfs
    python3 nas-check.py path/to/xraid-info WORK

| Scenario | Made on the NAS | What xraid-info must see |
|---|---|---|
| `base` | md5 RAID 1 (rbc) and md6 RAID 0 (rbd), chunk 16 KiB, 2 disks | both usable, RAIDiator byte order, files read back |
| `failed` | a RAID 1 member removed (`mdconfig -a remove`), then the volume written again | that member stale, read from the other one, the later file read back |
| `rebuild` | a member failed, removed, a blank one hot-added, array stopped during the recovery | the new member not in sync (spare), read from the other one |
| `spare` | a third member hot-added to a complete RAID 1 | a spare, not degraded |
| `single` | RAID 1 and RAID 0 of one member | both usable |
| `snapshot` | a RAIDiator snapshot (`v_YYYY_MM_DD_HH_MM`, chunk 256K), then the origin written again | the origin read with its current files |
| `delete` | `mdconfig -a delete` of a stopped array | reported: its superblocks stay (Frontview also clears the MBR slot) |

Seen there and not reproducible on the PC: the RAID 0 chunk stored
big-endian (a PC's md reads 4096K and assembles a RAIDiator RAID 0 wrongly),
the SPARC word order of the event count, the clean bit left at 0 on every
RAID 0, and that `mdconfig -a add` needs a whole disk (it repartitions it
first: a loop device has no geometry), so replacements are done with
`raidhotadd` as RAIDiator does for spares.

## End to end: nas-raid under 6.18, then RAIDiator again (on-618.sh, check618)

The 6.18 kernel has neither a loop driver nor vfat: the test USB key is
partitioned instead (partition 1: the fake disks' MBR; logical partitions 5-8,
type 0xfd, the exact size of the base scenario's members, their contents
written there). Under 6.18 each fake disk is a dm device (partition 1 + two
member partitions) and the real nas-raid runs on them, next to the NAS's own
X-RAID, through test-only variables (NAS_RAID_BIN/RUN/STATE/CONF/MNT and
NAS_RAID_VG_PATTERN, which needs NAS_RAID_MNT: never a test volume at the
root):

    # under 6.18: BIN = nas-raid, xraid-info, flexraid-sb (SPARC build), mbr.img; KEY = the test key
    sh on-618.sh BIN /dev/sdX WORK      # read-only, then FLEXRAID_RW=yes: writes on rbd and rbc
                                        # (legs compared, superblocks unchanged), a crash replayed
                                        # (role 1 altered, mark left: md resyncs it from role 0)
    PHASE=fail sh on-618.sh BIN /dev/sdX WORK2   # later, a second run: rbc's role 1 failed
                                        # while writing, recorded on role 0 (flexraid-sb)

Then the NAS booted on DIET or RAIDiator, the key still plugged in: the kernel
notes its 0xfd partitions, `mdconfig -a autorun` assembles them as at
RAIDiator's boot, and RAIDiator's e2fsck and kernel check what 6.18 wrote:

    CHECK_DIR=<WORK of the write phase> sh on-nas.sh TOOLS WORK check618              # md5 on both members, no resync
    PHASE=fail CHECK_DIR=<same> sh on-nas.sh TOOLS WORK check618   # after the fail phase: md5 on role 0 alone

Seen on the NAS: write phase 18/19 under 6.18 (both read, both written, rbc's
legs identical and the superblocks unchanged, the crash resynchronised in
19 s; the failed check compared role 0 with its state before the read-write
mount, which ext4 changes: fixed since, the legs checked identical by hand), 11/11 back under RAIDiator (md5 on both members without a resync,
e2fsck 1.40 clean on both file systems written by 6.18's ext4, the files
identical); fail phase 6/6 under 6.18 (role 1 failed through md's sysfs:
mdadm --fail answers "No such device" on a --build array; recorded on role 0),
11/11 under RAIDiator ("kicking non-fresh sda7", md5 [2/1] [U_]).
