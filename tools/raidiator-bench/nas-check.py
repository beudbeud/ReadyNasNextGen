#!/usr/bin/env python3
"""Checks, without root, the fake disks made on the NAS by on-nas.sh.

  nas-check.py [--keep] XRAID_INFO DIR [SCENARIO...]

For each scenario folder of DIR (files dDISKpPART.img): rebuilds the disks
(MBR, partitions of type 0xfd in PART order), runs `xraid-info flexraid` on
them, reads every usable array through the dm table it printed (linear or
striped, as dm would), follows the LVM2 metadata to each LV of the expected
volumes and reads the files on-nas.sh wrote there with debugfs. Prints one
ok/FAIL line per expectation; exit code = number of failures. The rebuilt
disks and LVs (as large as the scenarios) are deleted at the end, kept with
--keep.
"""
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

# what each scenario of on-nas.sh must give:
#   arrays: {minor: (level, usable, required reasons, forbidden reasons)}
#   files:  {VG: [(file, text the file starts with), ...]}
EXPECT = {
    "base": {"arrays": {5: ("raid1", 1, set(), {"degraded"}), 6: ("raid0", 1, set(), set())},
             "files": {"rbc": [("hello.txt", "volume rbc")], "rbd": [("hello.txt", "volume rbd")]}},
    "failed": {"arrays": {5: ("raid1", 1, {"stale_member"}, set())},
               "files": {"rbf": [("hello.txt", "volume rbf"), ("after.txt", "written after disk 1")]}},
    "rebuild": {"arrays": {5: ("raid1", 1, {"degraded"}, set())},
                "files": {"rbr": [("hello.txt", "volume rbr")]}},
    "spare": {"arrays": {5: ("raid1", 1, set(), {"degraded"})},
              "files": {"rbs": [("hello.txt", "volume rbs")]}},
    "single": {"arrays": {5: ("raid1", 1, set(), set()), 6: ("raid0", 1, set(), set())},
               "files": {"rbo": [("hello.txt", "volume rbo")]}},
    "snapshot": {"arrays": {5: ("raid1", 1, set(), {"degraded"})},
                 "files": {"rbn": [("hello.txt", "volume rbn"), ("after.txt", "written after the snapshot")]}},
    "delete": {"arrays": None, "files": {}},   # what is left is only reported
}

FAILS = 0


def check(desc, ok, detail=""):
    global FAILS
    print(("ok   " if ok else "FAIL ") + desc + ("" if ok or not detail else f" ({detail})"))
    FAILS += not ok


def build_disks(sdir, out):
    parts = {}
    for f in os.listdir(sdir):
        m = re.fullmatch(r"d(\d+)p(\d+)\.img", f)
        if m:
            parts.setdefault(int(m[1]), {})[int(m[2])] = os.path.join(sdir, f)
    disks = []
    for d in sorted(parts):
        img = os.path.join(out, f"disk{d}.img")
        start, table = 2048, []
        for p in sorted(parts[d]):
            n = os.path.getsize(parts[d][p]) // 512
            table.append((start, n, parts[d][p]))
            start += n
        with open(img, "wb") as f:
            f.truncate((start + 16384) * 512)
            mbr = bytearray(512)
            for i, (st, n, _) in enumerate(table):
                e = 0x1BE + 16 * i
                mbr[e + 4] = 0xFD
                struct.pack_into("<II", mbr, e + 8, st, n)
            mbr[510:512] = b"\x55\xaa"
            f.write(mbr)
            for st, _, src in table:
                f.seek(st * 512)
                with open(src, "rb") as s:
                    f.write(s.read())
        disks.append(img)
    return disks


def reader(table):
    """read(offset, length) of the device a dm linear/striped table describes"""
    t = table.split()
    files = {}
    def fh(dev):
        if dev not in files:
            files[dev] = open(dev, "rb")
        return files[dev]
    if t[2] == "linear":
        dev, base = t[3], int(t[4])
        def rd(off, n):
            f = fh(dev)
            f.seek(base * 512 + off)
            return f.read(n)
        return rd
    k, cs = int(t[3]), int(t[4]) * 512
    devs = [(t[5 + 2 * i], int(t[6 + 2 * i])) for i in range(k)]
    def rd(off, n):
        out = []
        while n:
            c, r = divmod(off, cs)
            dev, base = devs[c % k]
            m = min(n, cs - r)
            f = fh(dev)
            f.seek(base * 512 + (c // k) * cs + r)
            out.append(f.read(m))
            off, n = off + m, n - m
        return b"".join(out)
    return rd


def parse_lvm(text):
    """LVM text metadata (blocks "name {...}", "key = value") as nested dicts,
    whatever the indentation (LVM 2.02.07 writes none)."""
    root, stack = {}, []
    cur, pending = root, None
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if pending is not None:		# a list value over several lines: "[", items, "]"
            k, v = pending
            v += " " + line
            if line.endswith("]"):
                cur[k], pending = v, None
            else:
                pending = (k, v)
            continue
        if line.endswith("{"):
            new = {}
            cur[line[:-1].strip()] = new
            stack.append(cur)
            cur = new
        elif line == "}":
            if not stack:
                break
            cur = stack.pop()
        elif "=" in line:
            k, v = (x.strip() for x in line.split("=", 1))
            if v.startswith("[") and not v.endswith("]"):
                pending = (k, v)
            else:
                cur[k] = v
    return root


def lvm_meta(rd):
    """VG name, extent size, pe_start and LV segments from the newest LVM2 text metadata."""
    blob = rd(0, 1 << 20)
    best, seq = None, -1
    for m in re.finditer(rb'(?:^|[\n\0])(\w+) \{\s*id = "[^"]+"\s*seqno = (\d+)', blob):
        if int(m[2]) > seq:
            best, seq = m.start(1), int(m[2])
    if best is None:
        return None, None
    text = blob[best:best + 262144].split(b"\0")[0].decode("latin-1")
    tree = parse_lvm(text)
    vg = next(k for k, v in tree.items() if isinstance(v, dict))
    t = tree[vg]
    pv = next(v for v in t["physical_volumes"].values() if isinstance(v, dict))
    meta = {"ext": int(t["extent_size"]), "pe_start": int(pv["pe_start"]), "lvs": {}}
    for name, lv in t.get("logical_volumes", {}).items():
        if not isinstance(lv, dict):
            continue
        segs = []
        for sk, seg in lv.items():
            if sk.startswith("segment") and isinstance(seg, dict) and "stripes" in seg:
                pv_ext = int(re.search(r'"pv\d+",\s*(\d+)', seg["stripes"])[1])
                segs.append((int(seg["start_extent"]), int(seg["extent_count"]), pv_ext))
        meta["lvs"][name] = segs
    return vg, meta


def lv_image(rd, meta, lv, path):
    ext, pe = meta["ext"] * 512, meta["pe_start"] * 512
    with open(path, "wb") as f:
        for start, count, pv_ext in meta["lvs"][lv]:
            f.seek(start * ext)
            f.write(rd(pe + pv_ext * ext, count * ext))


def debugfs_cat(img, name):
    r = subprocess.run(["debugfs", "-R", f"cat {name}", img], capture_output=True, text=True)
    return r.stdout


def scenario(xi, sdir, name, work):
    exp = EXPECT.get(name)
    out = os.path.join(work, name)
    os.makedirs(out, exist_ok=True)
    disks = build_disks(sdir, out)
    j = json.loads(subprocess.run([xi, "flexraid", "--json"] + disks, capture_output=True, text=True, check=True).stdout)
    txt = subprocess.run([xi, "flexraid"] + disks, capture_output=True, text=True, check=True).stdout
    tables = dict(re.findall(r"FR_A(\d+)_TABLE='([^']*)'", txt))
    arrays = {a["minor"]: (i, a) for i, a in enumerate(j["arrays"])}
    print(f"=== {name}: " + (", ".join(
        f"md{a['minor']} {a['level']} usable={a['usable']} {a['byte_order']} {a['content'] or '-'} "
        f"[{' '.join(m['state'] for m in a['members'])}] {' '.join(a['reasons'])}" for a in j["arrays"]) or "no md 0.90 array"))
    if exp is None or exp["arrays"] is None:
        return
    check(f"{name}: md 0.90 arrays = {sorted(exp['arrays'])}", sorted(arrays) == sorted(exp["arrays"]),
          f"got {sorted(arrays)}")
    for minor, (level, usable, need, forbid) in exp["arrays"].items():
        if minor not in arrays:
            continue
        a = arrays[minor][1]
        reasons = set(a["reasons"])
        check(f"{name}: md{minor} {level}, usable={usable}, RAIDiator byte order",
              a["level"] == level and a["usable"] == usable and a["byte_order"] == "raidiator",
              f"{a['level']} usable={a['usable']} {a['byte_order']}")
        if need or forbid:
            check(f"{name}: md{minor} reasons include {sorted(need) or '-'}, exclude {sorted(forbid) or '-'}",
                  need <= reasons and not (forbid & reasons), " ".join(sorted(reasons)) or "none")
    found = {}
    for minor, (i, a) in arrays.items():
        if a["usable"] and str(i) in tables:
            rd = reader(tables[str(i)])
            vg, meta = lvm_meta(rd)
            if vg:
                found[vg] = (rd, meta)
    for vg, files in exp["files"].items():
        if vg not in found:
            check(f"{name}: VG {vg} found through our tables", False, f"found {sorted(found)}")
            continue
        rd, meta = found[vg]
        if vg not in meta["lvs"]:
            check(f"{name}: LV {vg}/{vg} in the metadata", False, f"LVs {sorted(meta['lvs'])}")
            continue
        others = sorted(set(meta["lvs"]) - {vg})
        if others:
            print(f"     VG {vg}: other LVs {others}")
        img = os.path.join(out, f"lv-{vg}.img")
        lv_image(rd, meta, vg, img)
        for f, text in files:
            got = debugfs_cat(img, f)
            check(f"{name}: {vg}/{f} read through our table and LVM", got.startswith(text), got[:60].strip() or "empty")


def main():
    args = sys.argv[1:]
    keep = "--keep" in args
    args = [a for a in args if a != "--keep"]
    if len(args) < 2:
        sys.exit(__doc__)
    xi, top = args[0], args[1]
    names = args[2:] or [n for n in EXPECT if os.path.isdir(os.path.join(top, n))]
    work = tempfile.mkdtemp(prefix="nas-check.", dir=os.environ.get("TMPDIR"))
    try:
        for n in names:
            scenario(xi, os.path.join(top, n), n, work)
    finally:
        if not keep:
            shutil.rmtree(work, ignore_errors=True)
    print(f"{FAILS} failure(s)" + (f"; rebuilt disks and LVs in {work}" if keep else ""))
    sys.exit(min(FAILS, 100))


if __name__ == "__main__":
    main()
