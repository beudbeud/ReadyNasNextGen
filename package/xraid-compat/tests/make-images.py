#!/usr/bin/env python3
"""Makes fake X-RAID disk images (sparse files) for the tests.

Layout taken from docs/XRAID.md (RAIDiator install, Duo, RAID 1):
"WGao" superblock at N-4096 (+ copies at N-4072, N-4048, N-4024), "WGam"
mark at N-2, MBR on the base disk only, sections 0 (32, 4 096 000) and
1 (4 096 032, V - 4 096 002), p1/p2/p3 extended/p5 LVM.
Nothing comes from a real disk: identifiers and dates are made up.

  make-images.py FOLDER SCENARIO [N]
SCENARIO: clean | dirty | degraded | sync | different | md | big | reinstall
          | counters | torn | fs | fsdirty
          (any other name: same as clean)
"fs" (clean superblock) and "fsdirty" (unclean shutdown) add real ext3 file
systems with 16 KiB blocks (host mke2fs): p1, and LV "c" of an LVM PV on p5
(text metadata, two segments swapped on the PV); system.fs and data.fs stay
in FOLDER.
  make-images.py FOLDER poke journal|sysjournal|bitmap|itable|lvm|data
changes one byte on the mirror (sda.img) in that area (located with
debugfs/dumpe2fs and an independent LV mapping) and prints its LBA.
Writes FOLDER/sda.img (mirror, SATA channel 0) and FOLDER/sdb.img (base,
SATA channel 1), as on the Duo where the base was hde; "degraded" writes
only sdb.img; "md" adds an md 1.2 superblock on sda.img (already migrated disk).
"""
import os
import re
import struct
import subprocess
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


# ---------- "fs" scenario: ext3 (16 KiB blocks) in p1 and in LV c of an LVM PV on p5 ----------
P5 = 4608040
PE_START = 384          # sectors
EXT = 8192              # 4 MiB extents
LV_EXTENTS = 128        # 512 MiB
# the LV in two segments, swapped on the PV: (first LE, count, first PE)
SEGS = [(0, 64, 300), (64, 64, 10)]
PV_UUID = "AbCdEfGhIjKlMnOpQrStUvWxYz012345"


def dashed(u):
    return "-".join((u[:6], u[6:10], u[10:14], u[14:18], u[18:22], u[22:26], u[26:]))


def lvm_pv(pv_sectors):
    """label (sector 1) and metadata area at 4 KiB, as LVM2 writes them"""
    pe_count = (pv_sectors - PE_START) // EXT
    segs = "".join(
        '\t\t\tsegment%d {\n\t\t\t\tstart_extent = %d\n\t\t\t\textent_count = %d\n\n'
        '\t\t\t\ttype = "striped"\n\t\t\t\tstripe_count = 1\t# linear\n\n'
        '\t\t\t\tstripes = [\n\t\t\t\t\t"pv0", %d\n\t\t\t\t]\n\t\t\t}\n' % (i + 1, le, n, pe)
        for i, (le, n, pe) in enumerate(SEGS))
    # an unrelated PV listed first: the PV must be found by its id
    text = ('c {\nid = "zzzzzz-zzzz-zzzz-zzzz-zzzz-zzzz-zzzzzz"\nseqno = 3\n'
            'status = ["RESIZEABLE", "READ", "WRITE"]\nextent_size = %d\t# 4 Megabytes\n'
            'max_lv = 0\nmax_pv = 0\n\nphysical_volumes {\n\n'
            '\tpv1 {\n\t\tid = "yyyyyy-yyyy-yyyy-yyyy-yyyy-yyyy-yyyyyy"\n\t\tdevice = "/dev/other"\n'
            '\t\tstatus = ["ALLOCATABLE"]\n\t\tpe_start = %d\n\t\tpe_count = 10\n\t}\n'
            '\tpv0 {\n\t\tid = "%s"\n\t\tdevice = "/dev/hdc5"\t# Hint only\n\n'
            '\t\tstatus = ["ALLOCATABLE"]\n\t\tpe_start = %d\n\t\tpe_count = %d\n\t}\n}\n\n'
            'logical_volumes {\n\n\tc {\n\t\tid = "xxxxxx-xxxx-xxxx-xxxx-xxxx-xxxx-xxxxxx"\n'
            '\t\tstatus = ["READ", "WRITE", "VISIBLE"]\n\t\tsegment_count = %d\n\n%s\t}\n}\n}\n'
            '# Generated by LVM2: made up for the tests\n\ncontents = "Text Format Volume Group"\n'
            'version = 1\n\ndescription = ""\n\ncreation_host = "example"\ncreation_time = 1200000000\n'
            % (EXT, PE_START, dashed(PV_UUID), PE_START, pe_count, len(SEGS), segs)).encode() + b"\0"
    label = bytearray(512)
    label[0:8] = b"LABELONE"
    struct.pack_into("<QII", label, 8, 1, 0, 32)
    label[24:32] = b"LVM2 001"
    label[32:64] = PV_UUID.encode()
    struct.pack_into("<Q", label, 64, pv_sectors * 512)
    struct.pack_into("<QQQQQQQQ", label, 72, PE_START * 512, 0, 0, 0, 4096, PE_START * 512 - 4096, 0, 0)
    mda = bytearray(512)
    mda[4:20] = b" LVM2 x[5A%r0N*>"
    struct.pack_into("<IQQQQII", mda, 20, 1, 4096, PE_START * 512 - 4096, 512, len(text), 0, 0)
    return label, mda, text


def lv_lba(byte):
    """disk LBA of an LV byte (independent of xraid-info's mapping)"""
    s = byte // 512
    for le, n, pe in SEGS:
        if le * EXT <= s < (le + n) * EXT:
            return P5 + PE_START + pe * EXT + (s - le * EXT)
    raise ValueError(byte)


def mkfs(path, mb, groups, files):
    tree = path + ".d"
    os.makedirs(tree, exist_ok=True)
    for i in range(files):
        with open(os.path.join(tree, "f%03d" % i), "w") as f:
            f.write("file %d\n" % i)
    with open(path, "wb") as f:
        f.truncate(mb << 20)
    subprocess.run(["mke2fs", "-q", "-F", "-t", "ext3", "-b", "16384", "-g", str(groups),
                    "-N", "4096", "-d", tree, path], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def copy_sparse(src, f, lba_of):
    """copies the data parts of src into f; lba_of(byte) = destination LBA"""
    with open(src, "rb") as s:
        fd, size, pos = s.fileno(), os.fstat(s.fileno()).st_size, 0
        while pos < size:
            try:
                pos = os.lseek(fd, pos, os.SEEK_DATA)
            except OSError:
                break
            end = os.lseek(fd, pos, os.SEEK_HOLE)
            while pos < end:
                n = min(end - pos, 1 << 20, 4 * 1024 * 1024 - pos % (4 * 1024 * 1024))   # stays in an extent
                s.seek(pos)
                write(f, lba_of(pos), s.read(n))
                pos += n


def fs_build(folder, data):
    label, mda, text = lvm_pv(data - 8)
    mkfs(os.path.join(folder, "system.fs"), 4096000 // 2048, 2048, 8)
    mkfs(os.path.join(folder, "data.fs"), LV_EXTENTS * EXT // 2048, 2048, 300)
    for name in ("sda", "sdb"):
        with open(os.path.join(folder, name + ".img"), "r+b") as f:
            write(f, P5 + 1, label)
            write(f, P5 + 8, mda)
            write(f, P5 + 9, text)
            copy_sparse(os.path.join(folder, "system.fs"), f, lambda b: 32 + b // 512)
            copy_sparse(os.path.join(folder, "data.fs"), f, lv_lba)


def poke(folder, what):
    """changes one byte on the mirror (sda.img) in the given area; prints its LBA"""
    os.environ["LC_ALL"] = "C"     # dumpe2fs output parsed below
    def dump(fs, pat):
        out = subprocess.run(["dumpe2fs", os.path.join(folder, fs)], capture_output=True, text=True).stdout
        return [int(x) for x in re.findall(pat, out)]
    def jblock(n):
        out = subprocess.run(["debugfs", "-R", "bmap <8> %d" % n, os.path.join(folder, "data.fs")],
                             capture_output=True, text=True).stdout
        return int(out.split()[0])
    bs = 16384
    if what == "journal":           # journal block 3000: second run of the journal
        lba = lv_lba(jblock(3000) * bs + 100)
    elif what == "sysjournal":
        out = subprocess.run(["debugfs", "-R", "bmap <8> 10", os.path.join(folder, "system.fs")],
                             capture_output=True, text=True).stdout
        lba = 32 + int(out.split()[0]) * bs // 512
    elif what == "bitmap":          # block bitmap of group 12
        lba = lv_lba(dump("data.fs", r"Block bitmap at (\d+)")[12] * bs)
    elif what == "itable":          # first inode table block of group 0 (root inode)
        lba = lv_lba(dump("data.fs", r"Inode table at (\d+)")[0] * bs + 256)
    elif what == "lvm":
        lba = P5 + 9
    elif what == "data":            # a free block in group 10, outside any metadata
        lba = lv_lba((10 * 2048 + 1500) * bs)
    else:
        sys.exit("poke: journal | sysjournal | bitmap | itable | lvm | data")
    with open(os.path.join(folder, "sda.img"), "r+b") as f:
        f.seek(lba * 512 + 7)
        c = f.read(1)
        f.seek(lba * 512 + 7)
        f.write(bytes([c[0] ^ 0xFF]))
    print(lba)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    folder, scen = sys.argv[1], sys.argv[2]
    if scen == "poke":
        return poke(folder, sys.argv[3])
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
            sb = superblock(n, v, sections, disks, clean=(scen not in ("dirty", "fsdirty")),
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
    if scen in ("fs", "fsdirty"):
        fs_build(folder, data)
    print("N=%d V=%d data=%d" % (n, v, data))


if __name__ == "__main__":
    main()
