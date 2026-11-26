#!/usr/bin/env python3
"""Makes fake X-RAID disk images (sparse files) for the tests.

Layout taken from docs/XRAID.md (RAIDiator install, Duo, RAID 1):
"WGao" superblock at N-4096 (+ copies at N-4072, N-4048, N-4024), "WGam"
mark at N-2, MBR on the base disk only, sections 0 (32, 4 096 000) and
1 (4 096 032, V - 4 096 002), p1/p2/p3 extended/p5 LVM.
Nothing comes from a real disk: identifiers and dates are made up.

  make-images.py FOLDER SCENARIO [N]
SCENARIO: clean | dirty | degraded | sync | different | big | reinstall
          | counters | torn | fs | fsdirty
          | flexraid | flexraid-be | flexraid-degraded | flexraid-stale
          | flexraid-oldxraid | flexraid-lvm1 | flexraid-x86 | flexraid-3
            (RAIDiator md mode, X-RAID off: see flexraid() below)
          | tools (exits 77 if mke2fs, debugfs or dumpe2fs is missing)
          (any other name: same as clean)
"fs" (clean superblock) and "fsdirty" (unclean shutdown) add real ext3 file
systems with 16 KiB blocks (host mke2fs, every option explicit, no
mke2fs.conf, fixed UUIDs and dates: the same bytes on every host), built once
and copied identically on both disks: p1, and LV "c" of an LVM PV on p5
(text metadata, two segments swapped on the PV); system.fs and data.fs stay
in FOLDER.
  make-images.py FOLDER poke journal|sysjournal|bitmap|itable|lvm|data
changes one byte on the mirror (sda.img) in that area (located with
debugfs/dumpe2fs and an independent LV mapping) and prints its LBA.
Writes FOLDER/sda.img (mirror, SATA channel 0) and FOLDER/sdb.img (base,
SATA channel 1), as on the Duo where the base was hde; "degraded" writes
only sdb.img.
"""
import os
import re
import shutil
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


E2FS = ("mke2fs", "debugfs", "dumpe2fs")
E2FS_PATH = os.environ.get("PATH", "") + ":/usr/sbin:/sbin"
FAKE_TIME = 1200000000


def e2fs(args, **kw):
    """runs an e2fsprogs tool, independent of the host settings and language"""
    env = dict(os.environ, PATH=E2FS_PATH, LC_ALL="C", MKE2FS_CONFIG=os.devnull,
               E2FSPROGS_FAKE_TIME=str(FAKE_TIME), SOURCE_DATE_EPOCH=str(FAKE_TIME))
    return subprocess.run(args, env=env, **kw)


def mkfs(path, mb, groups, files, uuid):
    """the same ext3 on every host: every mke2fs option explicit, no mke2fs.conf"""
    tree = path + ".d"
    os.makedirs(tree, exist_ok=True)
    for i in range(files):
        with open(os.path.join(tree, "f%03d" % i), "w") as f:
            f.write("file %d\n" % i)
        os.utime(os.path.join(tree, "f%03d" % i), (FAKE_TIME, FAKE_TIME))
    os.utime(tree, (FAKE_TIME, FAKE_TIME))
    with open(path, "wb") as f:
        f.truncate(mb << 20)
    r = e2fs(["mke2fs", "-q", "-F", "-o", "Linux", "-b", "16384", "-I", "256", "-g", str(groups),
          "-N", "4096", "-m", "5", "-O", "none,has_journal,ext_attr,resize_inode,dir_index,"
          "filetype,sparse_super,large_file", "-J", "size=64", "-U", uuid,
          "-E", "hash_seed=%s,nodiscard,lazy_itable_init=0,lazy_journal_init=0" % uuid,
          "-d", tree, path], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if r.returncode:
        sys.exit("make-images: mke2fs failed on %s:\n%s" % (path, r.stderr))
    out = e2fs(["dumpe2fs", "-h", path], capture_output=True, text=True).stdout
    if not re.search(r"^Journal inode:\s+8$", out, re.M):
        sys.exit("make-images: mke2fs made no ext3 journal in " + path)


def copy_sparse(src, files, lba_of):
    """copies the data parts of src into every file (same bytes, read once);
    lba_of(byte) = destination LBA"""
    fd = os.open(src, os.O_RDONLY)
    try:
        os.fsync(fd)        # holes reported by SEEK_DATA match what was written
        size, pos = os.fstat(fd).st_size, 0
        while pos < size:
            try:
                pos = os.lseek(fd, pos, os.SEEK_DATA)
            except OSError:
                break
            end = os.lseek(fd, pos, os.SEEK_HOLE)
            while pos < end:
                n = min(end - pos, 1 << 20, 4 * 1024 * 1024 - pos % (4 * 1024 * 1024))   # stays in an extent
                data = os.pread(fd, n, pos)
                for f in files:
                    write(f, lba_of(pos), data)
                pos += n
    finally:
        os.close(fd)


def fs_build(folder, data):
    """one build of each file system, copied identically on both disks"""
    label, mda, text = lvm_pv(data - 8)
    mkfs(os.path.join(folder, "system.fs"), 4096000 // 2048, 2048, 8, "5a5a5a5a-0000-4000-8000-000000000001")
    mkfs(os.path.join(folder, "data.fs"), LV_EXTENTS * EXT // 2048, 2048, 300, "5a5a5a5a-0000-4000-8000-000000000002")
    with open(os.path.join(folder, "sda.img"), "r+b") as a, open(os.path.join(folder, "sdb.img"), "r+b") as b:
        for f in (a, b):
            write(f, P5 + 1, label)
            write(f, P5 + 8, mda)
            write(f, P5 + 9, text)
        copy_sparse(os.path.join(folder, "system.fs"), (a, b), lambda x: 32 + x // 512)
        copy_sparse(os.path.join(folder, "data.fs"), (a, b), lv_lba)


def poke(folder, what):
    """changes one byte on the mirror (sda.img) in the given area; prints its LBA"""
    def dump(fs, pat):
        out = e2fs(["dumpe2fs", os.path.join(folder, fs)], capture_output=True, text=True).stdout
        return [int(x) for x in re.findall(pat, out)]
    def jblock(n):
        out = e2fs(["debugfs", "-R", "bmap <8> %d" % n, os.path.join(folder, "data.fs")],
                             capture_output=True, text=True).stdout
        return int(out.split()[0])
    bs = 16384
    if what == "journal":           # journal block 3000: second run of the journal
        lba = lv_lba(jblock(3000) * bs + 100)
    elif what == "sysjournal":
        out = e2fs(["debugfs", "-R", "bmap <8> 10", os.path.join(folder, "system.fs")],
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


# ---------- "flexraid*" scenarios: RAIDiator md mode (X-RAID off) ----------
# As RAIDiator's linuxrc partitions both disks alike (type 0xfd): md0 root
# RAID 1 (p1), md1 swap RAID 1 (p2), md2 data RAID 1 (p3, volume c), and a
# second data volume md3 RAID 0 (p5, logical, volume d). md 0.90 superblocks
# in the last 64 KiB of each partition, as RAIDiator's kernel stores them (seen
# on the NAS): words little-endian in the SPARC word order (events_hi in word
# 39), personality section (chunk_size) big-endian. "flexraid-x86": as a PC
# writes them; "flexraid-be": native big-endian. Roles are swapped on md3 (sda =
# role 1) so that the stripe order is not the disk order. Every logical chunk
# k < FR_CHUNKS of md3 starts with b"CHUNK%04d" % k, and md2 starts with
# b"VOLUME-C", so that a test can read them back through the dm tables.
# md2 carries an LVM2 label in sector 1 ("flexraid-lvm1": an LVM1 header
# instead, as a VG left by an older firmware). "flexraid-3": three disks
# sda, sdb, sdc (roles 0, 1, 2 on every array, md3 a 3-disk RAID 0), as a
# 4-bay RAIDiator would leave them.
# "flexraid-oldxraid" also keeps, at the end of the disks, the clean X-RAID
# superblocks of an earlier install: RAIDiator's md install erases only the
# start of the disks (linuxrc: no X_RAID_CLEAR on that path).
FR_CHUNK = 32           # sectors (RAIDiator: mdconfig -c 16, 16 KiB)
FR_CHUNKS = 8
FR_EXT = 6193184        # extended partition (p4), p5 at FR_EXT + 8


def fr_parts(n):
    p5 = n - 16384 - (FR_EXT + 8)
    return [(1, 0xFD, 32, 4096000), (2, 0xFD, 4096032, 1048576),
            (3, 0xFD, 5144608, 1048576), (5, 0xFD, FR_EXT + 8, p5)]


def md90(le, uuid, level, size_kib, minor, chunk, role, events, clean=True, dstate=6, raidiator=False, nd=2):
    w = [0] * 1024
    w[0], w[1], w[2], w[4] = 0xa92b4efc, 0, 90, 32
    w[5], w[13], w[14], w[15] = uuid
    w[6], w[7], w[8], w[9], w[10], w[11] = 0x4A000000, level & 0xFFFFFFFF, size_kib, nd, nd, minor
    w[33] = 1 if clean else 0
    w[34], w[35] = nd, nd
    lo, hi = events & 0xFFFFFFFF, events >> 32
    w[39], w[40] = (lo, hi) if le and not raidiator else (hi, lo)
    w[65] = chunk * 512
    for r in range(nd):
        w[128 + 32 * r: 128 + 32 * r + 5] = [r, 9, r, r, 6]
    w[992:997] = [role, 9, role, role, dstate]
    b = bytearray(struct.pack(("<" if le else ">") + "1024I", *w))
    if raidiator:   # RAIDiator's swab_sb leaves the personality section (words 64-127) big-endian
        b[256:512] = struct.pack(">64I", *w[64:128])
    return bytes(b)


def flexraid(folder, scen, n):
    le = scen != "flexraid-be"
    raidiator = le and scen != "flexraid-x86"   # x86: superblocks as a PC writes them
    parts = fr_parts(n)
    os.makedirs(folder, exist_ok=True)
    names = ("sda", "sdb", "sdc") if scen == "flexraid-3" else ("sda", "sdb")
    nd = len(names)
    for name in names:
        path = os.path.join(folder, name + ".img")
        if os.path.exists(path):
            os.unlink(path)
        if scen == "flexraid-degraded" and name == "sdb":
            continue
        with open(path, "wb") as f:
            f.truncate(n * 512)
            write(f, 0, mbr([(t, s, nb) for num, t, s, nb in parts if num < 5]
                            + [(0x05, FR_EXT, n - 16384 - FR_EXT)]))
            write(f, FR_EXT, mbr([(0xFD, 8, parts[3][3])]))
            for num, typ, start, nb in parts:
                data = (nb & ~127) - 128
                raid0 = num == 5
                role = names.index(name)
                if raid0 and nd == 2:
                    role = 1 - role
                events = 7 if scen == "flexraid-stale" and name == "sda" and num == 3 else 40
                sb = md90(le, (0x1000 + num, 2, 3, 4), 0 if raid0 else 1,
                          0 if raid0 else data // 2, num - 1 if num < 5 else 3, FR_CHUNK, role, events, raidiator=raidiator, nd=nd)
                write(f, start + data, sb)
                if num == 3 and not (scen == "flexraid-stale" and name == "sda"):
                    write(f, start, b"VOLUME-C")
                    if scen == "flexraid-lvm1":     # LVM1 pv_disk: "HM", version 2
                        write(f, start, b"HM\x02\x00")
                    else:                           # LVM2 label in sector 1
                        write(f, start + 1, b"LABELONE")
                if raid0 and role == 0:     # LVM2 label at the array's sector 1 (chunk 0)
                    write(f, start + 1, b"LABELONE")
                if raid0:   # md RAID 0, one zone: chunk k on role k % nd, at (k // nd) chunks
                    for k in range(FR_CHUNKS):
                        if k % nd == role:
                            write(f, start + (k // nd) * FR_CHUNK, b"CHUNK%04d" % k)
        if scen == "flexraid-oldxraid":
            v = visible_size(n)
            old = superblock(n, v, [(32, 4096000), (4096032, v - 4096000 - 2)],
                             {1: (True, 1), 2: (False, 1)}, this=1 if name == "sda" else 2)
            with open(path, "r+b") as f:
                for off in (4096, 4072, 4048, 4024):
                    write(f, n - off, old)
                write(f, n - 2, b"WGam")
    print("N=%d flexraid" % n)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    folder, scen = sys.argv[1], sys.argv[2]
    if scen.startswith("flexraid"):
        return flexraid(folder, scen, int(sys.argv[3]) if len(sys.argv) > 3 else 8388608)
    if scen in ("fs", "fsdirty", "poke", "tools"):
        missing = [t for t in E2FS if not shutil.which(t, path=E2FS_PATH)]
        if missing:
            print("make-images: %s missing (e2fsprogs)" % " ".join(missing), file=sys.stderr)
            sys.exit(77)
        if scen == "tools":
            return
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
    if scen in ("fs", "fsdirty"):
        fs_build(folder, data)
    print("N=%d V=%d data=%d" % (n, v, data))


if __name__ == "__main__":
    main()
