#!/usr/bin/env python3
"""Small X-RAID for the test USB key (on-618-xraid.sh): the two disks of a
RAIDiator X-RAID as make-images.py writes them, sized as the key's fake
disks (base = KEY5+KEY6, mirror = KEY7+KEY8). Holds the MBR (base only), the
EBR, the four superblock copies and the "WGam" mark; the LVM and the ext3 are
made on the NAS by on-618-xraid.sh.

    python3 mkxraid-key.py FOLDER SECTORS
      -> FOLDER/{base,mirror}_<LBA>.bin (blocks to write at LBA), FOLDER/layout
"""
import importlib.util
import os
import sys

sys.dont_write_bytecode = True     # no __pycache__ next to make-images.py

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "make_images", os.path.join(HERE, "../../package/xraid-compat/tests/make-images.py"))
mi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mi)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    folder, n = sys.argv[1], int(sys.argv[2])
    v = mi.visible_size(n)
    s0 = 65536                      # section 0 (p1, the "system"): 32 MiB
    p2 = 8192                       # swap
    p5 = 32 + s0 + p2               # extended partition, in section 1
    data = v - p5 - 16352           # as make-images.py (4624384 = 4608032 + 16352)
    parts = [(0x83, 32, s0), (0x82, 32 + s0, p2), (0x05, p5, data)]
    table = mi.mbr(parts)
    ebr = mi.mbr([(0x8E, 8, data - 8)])
    sections = [(32, s0), (32 + s0, v - s0 - 2)]
    disks = {1: (True, 1), 2: (False, 1)}       # channel 1 mirror, channel 2 base
    os.makedirs(folder, exist_ok=True)
    for name, channel in (("mirror", 1), ("base", 2)):
        chunks = {}                 # sector -> bytes: everything else is left as it is
        if name == "base":
            chunks[0] = bytes(table)
        chunks[p5] = bytes(ebr)
        sb = bytes(mi.superblock(n, v, sections, disks, clean=True, this=channel, mbr_table=table)).ljust(24 * 512, b"\0")	# each copy fills its 24 sectors
        for off in (4096, 4072, 4048, 4024):
            chunks[n - off] = sb
        chunks[n - 2] = b"WGam".ljust(512, b"\0")
        for lba, blk in chunks.items():
            with open(os.path.join(folder, "%s_%d.bin" % (name, lba)), "wb") as f:
                f.write(blk)
    with open(os.path.join(folder, "layout"), "w") as f:
        f.write("N=%d\nV=%d\nP5=%d\nDATA=%d\n" % (n, v, p5, data))
    print("N=%d V=%d P5=%d DATA=%d" % (n, v, p5, data))


if __name__ == "__main__":
    main()
