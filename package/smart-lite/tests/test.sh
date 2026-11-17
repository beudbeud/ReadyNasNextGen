#!/bin/sh
# smart-lite decoding test on a PC: builds the tool for the host, writes
# sample IDENTIFY / SMART READ DATA / READ THRESHOLDS sectors (WD-like disk,
# made-up serial) and checks the table and the shell line.
#   sh package/smart-lite/tests/test.sh
set -e
H=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
${CC:-cc} -Wall -Wextra -Werror -O2 -o "$T/smart-lite" "$H/src/smart-lite.c"

python3 - "$T" <<'EOF'
import struct, sys
d = sys.argv[1]
def ata_str(s, n):                      # ATA strings: bytes swapped in each word
    s = s.ljust(n).encode()
    return b"".join(s[i+1:i+2] + s[i:i+1] for i in range(0, n, 2))
def sector(b):                          # byte 511 = checksum (sum of the 512 = 0)
    b = bytearray(b.ljust(511, b"\0")); b.append((-sum(b)) & 0xff); return bytes(b)
idf = bytearray(512)
idf[20:40] = ata_str("TEST-SERIAL-0001", 20)
idf[46:54] = ata_str("01.00A01", 8)
idf[54:94] = ata_str("WDC WD7500AADS-00M2B0", 40)
struct.pack_into("<H", idf, 166, 1 << 10)          # word 83: LBA48
struct.pack_into("<Q", idf, 200, 1465149168)       # words 100-103: 750 GB
open(d + "/id.bin", "wb").write(sector(bytes(idf[:511])))
# id, flags, value, worst, raw (48 bits), threshold
attrs = [(1, 0x2f, 200, 200, 0, 51), (3, 0x27, 195, 187, 6250, 21),
         (5, 0x33, 200, 200, 3, 140), (9, 0x32, 97, 97, 2551, 0),
         (12, 0x32, 100, 100, 369, 0), (193, 0x32, 168, 168, 97971, 0),
         (194, 0x22, 114, 100, 0x002d00140021, 0), (197, 0x32, 200, 200, 2, 0),
         (198, 0x30, 200, 200, 1, 0), (199, 0x32, 200, 200, 0, 0)]
sm = bytearray(b"\x10\x00"); th = bytearray(b"\x10\x00")
for i, f, v, w, raw, t in attrs:
    sm += struct.pack("<BHBB", i, f, v, w) + raw.to_bytes(6, "little") + b"\0"
    th += bytes([i, t]) + bytes(10)
open(d + "/smart.bin", "wb").write(sector(bytes(sm)))
open(d + "/thr.bin", "wb").write(sector(bytes(th)))
# failing disk: attribute 5 at its threshold (pre-fail)
sm[2 + 2 * 12 + 3] = 140
open(d + "/bad.bin", "wb").write(sector(bytes(sm)))
open(d + "/corrupt.bin", "wb").write(sector(bytes(sm))[:511] + b"\0")
EOF

fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; echo "$OUT"; fails=$((fails + 1)); fi; }
S="$T/smart-lite -F"
OUT=$($S "$T/id.bin" "$T/smart.bin" "$T/thr.bin" PASSED)
check "identity" 'echo "$OUT" | grep -q "^Model:    WDC WD7500AADS-00M2B0$" && echo "$OUT" | grep -q "^Capacity: 750 GB$" && echo "$OUT" | grep -q "^Firmware: 01.00A01$"'
check "health and temperature" 'echo "$OUT" | grep -q "result: PASSED" && echo "$OUT" | grep -q "^Temperature: 33 C$"'
check "attribute rows" 'echo "$OUT" | grep -q "^  5 Reallocated_Sector_Ct   0x0033   200   200   140   Pre-fail -           3$" && echo "$OUT" | grep -q "^194 Temperature_Celsius .* 33$"'
check "checksum ok" '! echo "$OUT" | grep -q checksum'
OUT=$($S -s "$T/id.bin" "$T/smart.bin" "$T/thr.bin" PASSED)
check "shell line" '[ "$OUT" = "health=PASSED realloc=3 pending=2 uncorr=1 hours=2551 cycles=369 celsius=33" ]'
OUT=$($S -s "$T/id.bin" "$T/bad.bin" "$T/thr.bin")
check "no RETURN STATUS: health from thresholds" 'case "$OUT" in health=FAILED*) true;; *) false;; esac'
OUT=$($S "$T/id.bin" "$T/bad.bin" "$T/thr.bin")
check "failing attribute flagged" 'echo "$OUT" | grep -q "^  5 .*FAILING_NOW"'
OUT=$($S "$T/id.bin" "$T/corrupt.bin" "$T/thr.bin")
check "bad checksum flagged" 'echo "$OUT" | grep -q "checksum mismatch"'
OUT=$($S "$T/id.bin" "$T/smart.bin" 2>&1) && fails=$((fails + 1))
check "usage on missing sector" 'echo "$OUT" | grep -q usage'
[ $fails -eq 0 ] && echo "all smart-lite tests passed" || { echo "$fails failure(s)"; exit 1; }
