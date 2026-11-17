#!/usr/bin/env python3
"""Reads the X-RAID superblock copies of a disk image (tests only).

  sb.py diff OLD.img NEW.img   offsets (hex, comma-separated) where the current
                               superblock of NEW differs from OLD; exit 1 if the
                               4 copies of NEW (24 sectors each) are not identical
"""
import os
import sys

SB_LEN, AREA = 0x24E0, 24 * 512


def copies(path):
    n = os.path.getsize(path) // 512
    with open(path, "rb") as f:
        out = []
        for off in (4096, 4072, 4048, 4024):
            f.seek((n - off) * 512)
            out.append(f.read(AREA))
        return out


def main():
    if len(sys.argv) != 4 or sys.argv[1] != "diff":
        sys.exit(__doc__)
    old, new = copies(sys.argv[2])[0], copies(sys.argv[3])
    print(",".join(hex(i) for i in range(SB_LEN) if old[i] != new[0][i]))
    sys.exit(0 if all(c == new[0] for c in new) else 1)


if __name__ == "__main__":
    main()
