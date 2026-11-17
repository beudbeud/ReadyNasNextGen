#!/usr/bin/env python3
"""Makes fake X-RAID disk images (sparse files) for the tests.

Layout taken from docs/XRAID.md (RAIDiator install, Duo, RAID 1):
"WGao" superblock at N-4096 (+ copies at N-4072, N-4048, N-4024), "WGam"
mark at N-2, MBR on the base disk only, sections 0 (32, 4 096 000) and
1 (4 096 032, V - 4 096 002), p1/p2/p3 extended/p5 LVM.
Nothing comes from a real disk: identifiers and dates are made up.

  make-images.py FOLDER SCENARIO [N]
SCENARIO: clean | dirty | degraded | sync | different | md | big | reinstall
          | counters | torn
          (any other name: same as clean)
Writes FOLDER/sda.img (mirror, SATA channel 0) and FOLDER/sdb.img (base,
SATA channel 1), as on the Duo where the base was hde; "degraded" writes
only sdb.img; "md" adds an md 1.2 superblock on sda.img (already migrated disk).
"""
import os
import struct
import sys

SB_LEN = 0x24E0
FIXED_V = {  # size classes (§2): window of N -> fixed V
    0x575416F0: (0x575426F0, 0x585426EF),
}


def visible_size(n):
    for v, (lo, hi) in FIXED_V.items():
        if lo <= n <= hi:
            return v
    return n - 0x5000


def mbr(parts):
    b = bytearray(512)
    for i, (typ, start, nb) in enumerate(parts):
        o = 0x1BE + 16 * i
        b[o + 4] = typ
        struct.pack_into("<II", b, o + 8, start, nb)
    b[510:512] = b"\x55\xaa"
    return b


def superblock(n, v, sections, disks, clean=True, init_mark=0, this=1, mbr_table=b""):
    sb = bytearray(SB_LEN)
    struct.pack_into(">IIII", sb, 0, 0x5747616F, 0, 1, 0)
    struct.pack_into(">II", sb, 0x14, 0x0A0B0C0D, 1200000000)    # made-up id and date
    struct.pack_into(">IIII", sb, 0x1C, 1, v, 2, 2)
    sb[0x30:0x34] = bytes([0, 1, 1, 0])     # parity = channel 0, LBA48, base = channel 1, no fake
    struct.pack_into(">I", sb, 0x48, sum(nb for _, nb in sections))   # l_size
    struct.pack_into(">I", sb, 0x84, 1 if clean else 0)
    struct.pack_into(">IIII", sb, 0x88, 2, 2, 0, 0)    # active, working, failed, spare
    struct.pack_into(">I", sb, 0x100, len(sections))
    for idx, (mirror, state) in disks.items():
        o = 0x200 + 128 * idx
        sb[o] = 1 if mirror else 0
        sb[o + 1] = 0 if mirror else 1
        sb[o + 2] = idx
        sb[o + 3] = idx - 1
        sb[o + 7] = 22 if idx == 1 else 33
        struct.pack_into(">III", sb, o + 0x0C, idx - 1, state, 1)
        if not mirror:
            sb[o + 0x18:o + 0x58] = mbr_table[0x1C0:0x200]
        struct.pack_into(">I", sb, o + 0x58, v)
    for k, (start, nb) in enumerate(sections):
        o = 0x800 + 32 * k
        # +4 dmap (3 = both disks), +5 level, +6 used, +7 initialised;
        # +8 keeps a non-zero value on a real healthy volume: mimic it.
        sb[o + 1], sb[o + 2], sb[o + 3], sb[o + 4], sb[o + 5], sb[o + 6] = k, 1, 0, 3, 1, 1
        sb[o + 7] = 0 if (init_mark and k == 1) else 1
        struct.pack_into(">I", sb, o + 8, 0x258020 + k)
        struct.pack_into(">I", sb, o + 0x10, start)
        struct.pack_into(">I", sb, o + 0x18, nb)
    sb[0x1460:0x14E0] = sb[0x200 + 128 * this:0x280 + 128 * this]
    # diskid: IDENTIFY of each member as RAIDiator stores it (big-endian words,
    # strings in reading order), made-up model and serial numbers
    for k in range(2):
        o = 0x14E0 + 512 * k
        struct.pack_into(">H", sb, o, 0x427A)
        sb[o + 20:o + 40] = b"EXAMPLE-SERIAL-%04d " % k
        sb[o + 54:o + 94] = b"EXAMPLE MODEL 750GB".ljust(40)
        struct.pack_into(">Q", sb, o + 200, n)        # words 100-103: N
    return sb


def write(f, lba, data):
    f.seek(lba * 512)
    f.write(data)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    folder, scen = sys.argv[1], sys.argv[2]
    n = int(sys.argv[3]) if len(sys.argv) > 3 else (1465149168 if scen == "big" else 8388608)
    v = visible_size(n)
    data = v - 4624384
    parts = [(0x83, 32, 4096000), (0x82, 4096032, 512000), (0x05, 4608032, data)]
    table = mbr(parts)
    ebr = mbr([(0x8E, 8, data - 8)])
    sections = [(32, 4096000), (4096032, v - 4096000 - 2)]
    mirror_state = 8 if scen == "sync" else 1
    disks = {1: (True, mirror_state), 2: (False, 1)}
    os.makedirs(folder, exist_ok=True)
    for name, channel in (("sda", 1), ("sdb", 2)):
        path = os.path.join(folder, name + ".img")
        if os.path.exists(path):
            os.unlink(path)
        if scen == "degraded" and name == "sda":
            continue
        with open(path, "wb") as f:
            f.truncate(n * 512)
            if name == "sdb":
                write(f, 0, table)                        # MBR: base disk only
            write(f, 4608032, ebr)                        # EBR in section 1 (on both)
            write(f, 32 + 2, b"\x53\xef")                 # same content on both
            write(f, 4608040 + 1, b"LABELONE")
            if scen == "different" and name == "sda":
                write(f, 4096032, b"DIFFER")              # 1st sample of section 1
            sb = superblock(n, v, sections, disks, clean=(scen != "dirty"),
                            init_mark=(123456 if scen == "sync" else 0), this=channel, mbr_table=table)
            if scen == "reinstall":
                struct.pack_into(">I", sb, 0x80, 1)       # RAIDiator reinstall flag
            if scen == "counters":
                struct.pack_into(">III", sb, 0x88, 1, 1, 1)   # RAIDiator saw a failed disk
            for off in (4096, 4072, 4048, 4024):
                write(f, n - off, sb)
            if scen == "torn" and name == "sdb":
                write(f, n - 4072, sb[:0x84] + b"\0\0\0\0" + sb[0x88:])   # copy updated, main not
            write(f, n - 2, b"WGam")
            if scen == "md" and name == "sda":
                for off in (4096, 4072, 4048, 4024):      # nas-raid erases the X-RAID zone
                    write(f, n - off, bytes(SB_LEN))
                f.seek(4096)
                f.write(struct.pack("<I", 0xa92b4efc))   # md 1.2 superblock
    print("N=%d V=%d data=%d" % (n, v, data))


if __name__ == "__main__":
    main()
