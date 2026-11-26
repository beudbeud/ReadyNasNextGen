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
