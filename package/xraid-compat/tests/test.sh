#!/bin/sh
# xraid-compat tests on a PC, without the NAS nor root: fake X-RAID disk
# images (sparse files, make-images.py), xraid-info built for the host,
# nas-raid with simulated dmsetup/mdadm/lvm/mount (they record their
# arguments in cmd.log). No dm or loop device is created.
#   sh package/xraid-compat/tests/test.sh   (dash; the host busybox prefers
# its own applets, mount for instance, to the simulated commands)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/../src
SH=${SH:-sh}
T=$(mktemp -d "${TMPDIR:-/tmp}/xraid-test.XXXXXX")
R=$T/root
FAILS=0; N=0
check() {	# check "description" shell-condition
	N=$((N + 1))
	if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAILS=$((FAILS + 1)); fi
}
mkdir -p "$R/bin" "$R/proc" "$R/var/run" "$R/var/lib" "$R/etc/init.d"
cc -O2 -Wall -Werror -o "$R/bin/xraid-info" "$SRC/xraid-info.c" || exit 1
cc -O2 -Wall -Werror -o "$R/bin/xraid-sb.real" "$SRC/xraid-sb.c" || exit 1
cc -O2 -Wall -Werror -o "$T/flexraid-sb.real" "$SRC/flexraid-sb.c" || exit 1
# ext3 images (fs, fsdirty) need e2fsprogs (mke2fs, debugfs, dumpe2fs): skipped without them
PATH=$PATH:/usr/sbin:/sbin
if python3 "$HERE/make-images.py" "$T" tools; then E2FS="fs fsdirty"; else E2FS=; echo "skip ext3 (quick check) tests: e2fsprogs missing"; fi
for s in clean big dirty degraded sync different reinstall counters torn sbw flexraid flexraid-3 flexraid-r5 flexraid-r5-degraded flexraid-be flexraid-degraded flexraid-stale flexraid-oldxraid flexraid-lvm1 flexraid-x86 $E2FS; do
	python3 "$HERE/make-images.py" "$T/$s" "$s" > /dev/null || exit 1
done

# ---------- image ----------
# /c must be empty in the image: a file there would be hidden by the mount
check "overlay: nothing inside /c" "[ ! -e '$HERE/../../../board/readynas-duo-v1/rootfs-overlay/c' ] || [ -z \"\$(ls -A '$HERE/../../../board/readynas-duo-v1/rootfs-overlay/c')\" ]"

# ---------- xraid-info ----------
mode() { "$R/bin/xraid-info" --samples 32 "$T/$1"/*.img | sed -n "s/^XR_MODE='\(.*\)'/\1/p"; }
for c in clean:rw big:rw dirty:ro degraded:ro sync:ro different:ro; do
	check "xraid-info: ${c%%:*} -> ${c#*:}" "[ \"\$(mode ${c%%:*})\" = ${c#*:} ]"
done
J=$("$R/bin/xraid-info" --json --samples 4 "$T"/big/*.img)
js() { printf '%s' "$J" | python3 -c "import json,sys; j=json.load(sys.stdin); sys.exit(0 if ($1) else 1)"; }
check "JSON: valid, V = 1 465 128 688 (750 GB)" "js 'j[\"v\"]==1465128688 and j[\"n\"]==1465149168'"
check "JSON: section 1 bounded by V (protected zone excluded)" "js 'j[\"sections\"][1][\"start\"]+j[\"sections\"][1][\"sectors\"]==j[\"v\"] and j[\"sections\"][1][\"declared_sectors\"]==1461032686'"
check "JSON: base = sdb (MBR), mirror = sda (no MBR)" "js '[(d[\"role\"],d[\"mbr\"]) for d in j[\"disks\"]]==[(\"mirror\",0),(\"base\",1)]'"
check "JSON: LVM p5 at 4 608 040 = section 1 + 512 008" "js '[(p[\"num\"],p[\"type\"],p[\"section\"],p[\"offset\"]) for p in j[\"partitions\"]][2]==(5,\"8e\",1,512008)'"
J=$("$R/bin/xraid-info" --json "$T"/degraded/sdb.img)
check "JSON: degraded, reason missing_disk, reading from the base" "js 'j[\"mode\"]==\"ro\" and j[\"reasons\"][0][\"code\"]==\"missing_disk\" and j[\"read_disk\"].endswith(\"sdb.img\")'"
"$R/bin/xraid-info" --samples 4 "$T"/dirty/*.img > "$T/dirty.txt"
check "text: reason unclean_shutdown" "grep -q \"^XR_REASONS='unclean_shutdown'\" '$T/dirty.txt'"
check "text: can be evaluated by sh" "(set -e; eval \"\$(cat '$T/dirty.txt')\"; [ \"\$XR_V\" = 8368128 ])"
# superblock fields decoded per docs/XRAID-FORMAT.md
reasons() { "$R/bin/xraid-info" "$T/$1"/*.img | sed -n "s/^XR_REASONS='\(.*\)'/\1/p"; }
J=$("$R/bin/xraid-info" --json "$T"/clean/*.img)
check "format: stale +8 watermark with initialized=1 stays rw" "[ \"\$(mode clean)\" = rw ] && js 'all(s[\"init\"]==1 and s[\"init_mark\"]!=0 for s in j[\"sections\"])'"
check "format: counters and reinstall flag exported" "js 'j[\"utime\"]==0 and (j[\"active_disks\"],j[\"working_disks\"],j[\"failed_disks\"],j[\"spare_disks\"])==(2,2,0,0)'"
check "format: reinstall flag (0x80) -> ro, reinstall_pending" "[ \"\$(reasons reinstall)\" = reinstall_pending ]"
check "format: RAIDiator counters show a failed disk -> ro, degraded" "[ \"\$(reasons counters)\" = degraded ]"
check "format: superblock and its copy differ -> ro, superblock_torn" "[ \"\$(reasons torn)\" = superblock_torn ]"
"$R/bin/xraid-info" verify "$T"/clean/sdb.img "$T"/clean/sda.img > "$T/v1" 2>/dev/null; rc=$?
check "verify: identical images -> code 0" "[ $rc = 0 ] && grep -q \"RESULT='identical'\" '$T/v1'"
"$R/bin/xraid-info" verify "$T"/different/sdb.img "$T"/different/sda.img > "$T/v2" 2>/dev/null; rc=$?
check "verify: one difference -> code 1, one zone" "[ $rc = 1 ] && grep -q 'DIFFERENT_ZONES=1' '$T/v2'"
# ---------- quick check: ext3 (16 KiB blocks) in LVM in X-RAID (make-images.py fs) ----------
q() { "$R/bin/xraid-info" quick --json --seed 7 "$@" 2>/dev/null; }
jtotal() { LC_ALL=C debugfs -R 'stat <8>' "$T/fs/$1.fs" 2>/dev/null | sed -n 's/^TOTAL: //p'; }
if [ -n "$E2FS" ]; then
J=$(q --samples 64 "$T"/fs/sdb.img "$T"/fs/sda.img); rc=$?
check "quick: identical images -> code 0, complete, valid JSON" "[ $rc = 0 ] && js 'j[\"result\"]==\"identical\" and j[\"complete\"]==1'"
cat_b() { python3 -c "import json,sys; j=json.loads(sys.argv[1]); print([c['bytes'] for c in j['categories'] if c['name']==sys.argv[2]][0])" "$J" "$1"; }
check "quick: both journals located (inode 8, indirect blocks, as debugfs counts them)" "[ \"\$(cat_b journal)\" = \$(( (\$(jtotal system) + \$(jtotal data)) * 16384 )) ]"
"$R/bin/xraid-info" quick --list --samples 0 "$T"/fs/sdb.img "$T"/fs/sda.img > "$T/qlist"
check "quick --list: data journal = debugfs block count, LVM area = pe_start, 1 EBR" "[ \$(awk '\$1==\"journal\" && \$2==\"data\" { n += \$4 } END { print n }' '$T/qlist') = \$((\$(jtotal data) * 32)) ] && grep -qx 'lvm - 4608040 384' '$T/qlist' && grep -qx 'partition - 4608032 1' '$T/qlist'"
check "quick: superblocks, bitmaps and in-use inode tables of both file systems listed" "for c in superblock bitmap inode_table; do grep -q \"^\$c system \" '$T/qlist' && grep -q \"^\$c data \" '$T/qlist' || exit 1; done"
for w in journal:journal:data sysjournal:journal:system bitmap:bitmap:data itable:inode_table:data lvm:lvm:-; do
	set -- $(echo $w | tr : ' ')
	python3 "$HERE/make-images.py" "$T/q-$1" fs > /dev/null; lba=$(python3 "$HERE/make-images.py" "$T/q-$1" poke $1)
	J=$(q --samples 0 "$T/q-$1"/sdb.img "$T/q-$1"/sda.img); rc=$?
	check "quick: a difference in the $1 area is found (code 1, zone $2/$3, its LBA)" "[ $rc = 1 ] && js 'j[\"zones\"]==[{\"category\":\"$2\",\"fs\":\"$3\",\"lba\":$lba}]'"
done
# file data outside the targeted areas: only the samples can see it (documented limit)
python3 "$HERE/make-images.py" "$T/q-data" fs > /dev/null; python3 "$HERE/make-images.py" "$T/q-data" poke data > /dev/null
J=$(q --samples 0 "$T"/q-data/sdb.img "$T"/q-data/sda.img); rc=$?
"$R/bin/xraid-info" verify "$T"/q-data/sdb.img "$T"/q-data/sda.img > /dev/null 2>&1; rc2=$?
check "quick: a difference in unsampled file data is NOT found (limit); the full verify finds it" "[ $rc = 0 ] && [ $rc2 = 1 ]"
fi
J=$(q --samples 8 "$T"/clean/sdb.img "$T"/clean/sda.img); rc=$?
check "quick: no ext3/LVM found -> code 3 (incomplete), notes say why" "[ $rc = 3 ] && js 'j[\"result\"]==\"incomplete\" and j[\"complete\"]==0 and len(j[\"notes\"])>=2'"
check "xraid-info opens nothing for writing (O_RDONLY only)" "! grep -q 'O_RDWR\|O_WRONLY' '$SRC/xraid-info.c'"

# ---------- xraid-sb (superblock writer) on images ----------
XS=$R/bin/xraid-sb.real
D=$T/sbw; cp --sparse=always "$D/sda.img" "$T/ref-sda.img"; cp --sparse=always "$D/sdb.img" "$T/ref-sdb.img"
sbd() { python3 "$HERE/sb.py" diff "$T/ref-$1.img" "$D/$1.img"; }	# offsets changed since the RAIDiator reference
SEC="0x807,0x809,0x80a,0x80b,0x827,0x829,0x82a,0x82b"
"$XS" dirty "$D/sda.img" "$D/sdb.img" > /dev/null
check "xraid-sb dirty: only 0x84 bit 0 and inited/+8 of both sections change, 4 copies identical" "[ \"\$(sbd sda)\" = 0x87,$SEC ] && [ \"\$(sbd sdb)\" = 0x87,$SEC ]"
check "xraid-sb dirty: xraid-info sees an unclean, unsynced X-RAID" "[ \"\$(reasons sbw)\" = 'unclean_shutdown sync_in_progress sync_in_progress' ]"
h=$(md5sum "$D"/*.img); "$XS" dirty "$D/sda.img" "$D/sdb.img" > "$T/x1"
check "xraid-sb: idempotent (second dirty: unchanged, nothing written)" "[ \"\$(md5sum '$D'/*.img)\" = \"$h\" ] && [ \$(grep -c unchanged '$T/x1') = 2 ]"
"$XS" clean "$D/sda.img" "$D/sdb.img" > /dev/null
check "xraid-sb clean: RAIDiator superblock back, stale +8 cleared, this_disk and diskid kept" "[ \"\$(sbd sda)\" = 0x809,0x80a,0x80b,0x829,0x82a,0x82b ] && [ \"\$(sbd sdb)\" = 0x809,0x80a,0x80b,0x829,0x82a,0x82b ] && [ -z \"\$(reasons sbw)\" ]"
h=$(md5sum "$T"/torn/*.img); "$XS" dirty "$T/torn/sda.img" "$T/torn/sdb.img" 2> "$T/x2"; rc=$?
check "xraid-sb: refuses a torn superblock (crash between two writes), nothing written" "[ $rc = 1 ] && grep -q 'interrupted update' '$T/x2' && [ \"\$(md5sum '$T'/torn/*.img)\" = \"$h\" ]"
for c in counters reinstall; do
	h=$(md5sum "$T/$c"/*.img); "$XS" dirty "$T/$c/sda.img" "$T/$c/sdb.img" 2>/dev/null; rc=$?
	check "xraid-sb: refuses an inconsistent superblock ($c), nothing written" "[ $rc = 1 ] && [ \"\$(md5sum '$T/$c'/*.img)\" = \"$h\" ]"
done
cp --sparse=always "$T/ref-sda.img" "$T/f-sda.img"; cp --sparse=always "$T/ref-sdb.img" "$T/f-sdb.img"
"$XS" fail "$T/f-sdb.img" > /dev/null
F=$(python3 "$HERE/sb.py" diff "$T/ref-sdb.img" "$T/f-sdb.img")
check "xraid-sb fail: on the survivor only ctime, counters, the failed disk state and the sections change" "python3 -c \"import sys; f=[int(x,16) for x in '$F'.split(',')]; ok=lambda o: 0x18<=o<0x1c or 0x88<=o<0x94 or 0x290<=o<0x294 or o in (0x804,0x807,0x824,0x827) or 0x808<o<0x80c or 0x828<o<0x82c; sys.exit(0 if 0x293 in f and all(map(ok,f)) else 1)\" && [ -z \"\$(python3 '$HERE/sb.py' diff '$T/ref-sda.img' '$T/f-sda.img')\" ]"
J=$("$R/bin/xraid-info" --json "$T/f-sda.img" "$T/f-sdb.img")
check "xraid-sb fail: mirror faulty, newest superblock wins, read from the base" "js 'j[\"mode\"]==\"ro\" and [d[\"state\"] for d in j[\"disks\"]]==[\"faulty\",\"online\"] and j[\"failed_disks\"]==1 and j[\"read_disk\"].endswith(\"f-sdb.img\")'"
# flexraid-sb on a RAIDiator superblock with its real checksum (docs/XRAID-FORMAT.md §6)
cp --sparse=always "$T/flexraid/sda.img" "$T/fsb.img"
fsb() {	# fsb csum|check|words|disks [IMAGE]: md2's superblock in IMAGE (fsb.img; sector 5144608 + 1048448)
	python3 - "$1" "${2:-$T/fsb.img}" <<'PY'
import sys, struct
f = open(sys.argv[2], "r+b"); o = (5144608 + 1048448) * 512; f.seek(o); b = bytearray(f.read(4096))
def cs(b):
    s = sum(struct.unpack_from(">I" if i in (42, 65) else "<I", b, 4 * i)[0] for i in range(1024) if i != 38)
    while s >> 32: s = (s & 0xffffffff) + (s >> 32)
    return s
w = lambda i: struct.unpack_from("<I", b, 4 * i)[0]
if sys.argv[1] == "csum":
    struct.pack_into("<I", b, 152, cs(b)); f.seek(o); f.write(b)
elif sys.argv[1] == "check":
    sys.exit(0 if cs(b) == w(38) else 1)
elif sys.argv[1] == "disks":   # counters, events, cp_events, then major:minor:state of each descriptor
    print(w(9), w(34), w(35), w(36), w(40), struct.unpack_from(">I", b, 168)[0],
          *["%d:%d:%d" % (w(129 + 32 * d), w(130 + 32 * d), w(132 + 32 * d)) for d in range(w(10))])
else:
    print(w(9), w(34), w(35), w(36), w(40), struct.unpack_from(">I", b, 168)[0], w(161), w(162), w(164))
PY
}
fsb csum; "$T/flexraid-sb.real" fail "$T/fsb.img:5144608:1048448:0:in_sync" > /dev/null
check "flexraid-sb fail: RAIDiator's words on the survivor (1 disk, other removed, events + 2), checksum still right" "fsb check && [ \"\$(fsb words)\" = '1 1 1 1 42 42 0 0 9' ]"
h=$(md5sum "$T/fsb.img"); "$T/flexraid-sb.real" fail "$T/fsb.img:5144608:1048448" > "$T/fsb2"; rc=$?
check "flexraid-sb fail again: already recorded, nothing written, success" "[ $rc = 0 ] && grep -q 'already recorded' '$T/fsb2' && [ \"\$(md5sum '$T/fsb.img')\" = \"$h\" ]"
"$T/flexraid-sb.real" --dry-run fail "$T/flexraid/sda.img:5144608:1048448" > "$T/fsb4"; rc2=$?
check "flexraid-sb: --dry-run writes nothing" "[ $rc2 = 0 ] && grep -q 'would write events 42' '$T/fsb4'"
h=$(md5sum "$T/clean/sda.img"); "$T/flexraid-sb.real" fail "$T/clean/sda.img:5144608:1048448" 2>/dev/null; rc=$?
check "flexraid-sb fail: refused where there is no md superblock" "[ $rc = 1 ] && [ \"\$(md5sum '$T/clean/sda.img')\" = \"$h\" ]"
# a RAID 1 of three disks (flexraid-3): every survivor written, the failed ones removed
F3=$T/fsb3; cp -r "$T/flexraid-3" "$F3"; for d in sda sdb sdc; do fsb csum "$F3/$d.img"; done; cp -r "$F3" "$T/fsb3-fresh"
m3() { echo "$F3/$1.img:5144608:1048448"; }
h=$(md5sum "$F3/sdc.img"); "$T/flexraid-sb.real" fail "$(m3 sda)" "$(m3 sdb)" > /dev/null; rc=$?
check "flexraid-sb, 3 disks, role 2 failed: both survivors = 2 disks, role 2 removed, events + 2, checksums right; role 2 untouched" "[ $rc = 0 ] && for d in sda sdb; do fsb check '$F3/'\$d.img && [ \"\$(fsb disks '$F3/'\$d.img)\" = '2 2 2 1 42 42 9:0:6 9:1:6 0:0:9' ] || exit 1; done && [ \"\$(md5sum '$F3/sdc.img')\" = \"$h\" ]"
check "flexraid-sb, 3 disks: xraid-info then finds role 2 stale (read-only, degraded)" "[ \"\$('$R/bin/xraid-info' flexraid '$F3'/*.img | sed -n \"s/^FR_A2_REASONS='\(.*\)'/\1/p\")\" = 'degraded stale_member' ]"
h=$(md5sum "$F3"/*.img); "$T/flexraid-sb.real" fail "$(m3 sda)" "$(m3 sdb)" > "$T/fsb5"; rc=$?
check "flexraid-sb, 3 disks, again: already recorded, nothing written" "[ $rc = 0 ] && grep -q 'already recorded' '$T/fsb5' && [ \"\$(md5sum '$F3'/*.img)\" = \"$h\" ]"
cp "$T/fsb3-fresh/sdb.img" "$F3/sdb.img"; "$T/flexraid-sb.real" fail "$(m3 sda)" "$(m3 sdb)" > /dev/null; rc=$?
check "flexraid-sb, 3 disks, stopped halfway (sda written, sdb not): sdb written alike" "[ $rc = 0 ] && fsb check '$F3/sdb.img' && [ \"\$(fsb disks '$F3/sdb.img')\" = '2 2 2 1 42 42 9:0:6 9:1:6 0:0:9' ]"
rm -rf "$F3"; cp -r "$T/fsb3-fresh" "$F3"; "$T/flexraid-sb.real" fail "$(m3 sdb)" > /dev/null; rc=$?
check "flexraid-sb, 3 disks, roles 0 and 2 failed: the survivor = 1 disk, both removed" "[ $rc = 0 ] && fsb check '$F3/sdb.img' && [ \"\$(fsb disks '$F3/sdb.img')\" = '1 1 1 2 42 42 0:0:9 9:1:6 0:0:9' ]"
rm -rf "$F3"; cp -r "$T/fsb3-fresh" "$F3"; h=$(md5sum "$F3"/*.img)
"$T/flexraid-sb.real" fail "$(m3 sda)" "$(m3 sdb)" "$(m3 sdc)" 2>/dev/null; rc=$?
"$T/flexraid-sb.real" fail "$(m3 sda)" "$F3/sdb.img:6193192:2178816" 2>/dev/null; rc2=$?
"$T/flexraid-sb.real" fail "$(m3 sda)" "$(m3 sda)" 2>/dev/null; rc3=$?
check "flexraid-sb, 3 disks: refused (nothing written) with every member, another array's member, or a member twice" "[ $rc = 1 ] && [ $rc2 = 1 ] && [ $rc3 = 1 ] && [ \"\$(md5sum '$F3'/*.img)\" = \"$h\" ]"
check "smart: clean refusal on an image (no SG_IO)" "! '$R/bin/xraid-info' smart '$T/clean/sda.img' 2>/dev/null"

# ---------- nas-raid with simulated commands ----------
stub() { printf '#!/bin/sh\necho "%s $*" >> "%s/cmd.log"\n%s\n' "$1" "$T" "${2:-}" > "$R/bin/$1"; chmod 755 "$R/bin/$1"; }
for c in dmsetup lvm umount logger; do stub $c; done
stub mdadm
stub mount 'echo "/dev/x $3 ext4 rw 0 0" >> "'"$R"'/proc/mounts"'
: > "$R/proc/mounts"
# md state seen by nas-raid: /proc/mdstat and sync_action, both legs healthy
mdstat() { printf 'Personalities : [raid1]\nmd10 : active raid1 dm-1[1] dm-0[0]\n      100 blocks [2/2] [UU]\nmd11 : active raid1 dm-3[1] dm-2[0]\n      100 blocks [2/2] %s\n' "$1" > "$R/proc/mdstat"; }
mdstat '[UU]'
for i in 0 1; do mkdir -p "$R/sys/block/md1$i/md"; echo idle > "$R/sys/block/md1$i/md/sync_action"; done
export NAS_RAID_ROOT=$R
# xraid-info and xraid-sb wrapped: their arguments go to xi.log / cmd.log
mv "$R/bin/xraid-info" "$R/bin/xraid-info.real"
printf '#!/bin/sh\necho "xraid-info $*" >> "%s/xi.log"\nexec "%s/bin/xraid-info.real" "$@"\n' "$T" "$R" > "$R/bin/xraid-info"; chmod 755 "$R/bin/xraid-info"
printf '#!/bin/sh\necho "xraid-sb $*" >> "%s/cmd.log"\nexec "%s/bin/xraid-sb.real" "$@"\n' "$T" "$R" > "$R/bin/xraid-sb"; chmod 755 "$R/bin/xraid-sb"
sampled() { grep -q -- '--samples [1-9]' "$T/xi.log"; }
nr() { NAS_RAID_DISKS="$DISKS" $SH "$SRC/nas-raid" "$@"; }
mode_of() { cut -d' ' -f1 "$R/var/run/nas-raid.mode"; }
DISKS="$T/big/sda.img $T/big/sdb.img"; : > "$T/cmd.log"; : > "$T/xi.log"; nr mount 2>/dev/null >/dev/null
check "XRAID_RW=no (default): read-only even when healthy" "grep -q 'xraid-ro rw_disabled' '$R/var/run/nas-raid.mode' && ! grep -q 'mdadm\|xraid-sb' '$T/cmd.log'"
check "read-only mount: no disk comparison (xraid-info --samples 0 only)" "grep -q -- '--samples 0' '$T/xi.log' && ! sampled"
nr unmount 2>/dev/null >/dev/null
# the read-only safeguards first (XRAID_RESYNC=no); the resync after an unclean stop below
printf 'XRAID_RW=yes\nXRAID_RESYNC=no\n' > "$R/etc/nas-raid.conf"
# every dm table on an image must end before V (protected zone untouched)
within_v() {
	awk -v v="$1" '/^dmsetup create/ { for (i = 1; i <= NF; i++) if ($i == "linear" && $(i+1) ~ /\.img$/) { gsub(/'"'"'/, "", $(i+2)); if ($(i+2) + $(i-1) > v) bad = 1 } } END { exit bad }' "$T/cmd.log"
}

: > "$T/cmd.log"; : > "$T/xi.log"; nr mount 2>/dev/null >/dev/null
check "mount (clean): xraid-rw" "[ \"\$(mode_of)\" = xraid-rw ]"
check "rw mount: fast analysis first, then comparison with SAMPLES (256)" "grep -n -- '--samples' '$T/xi.log' | sed -n '1p' | grep -q -- '--samples 0 ' && grep -q -- '--samples 256 ' '$T/xi.log'"
check "rw mount: superblock marked dirty BEFORE the md is built" "grep -n 'xraid-sb dirty .*big/sdb.img .*big/sda.img\|mdadm --build' '$T/cmd.log' | head -n 1 | grep -q 'xraid-sb dirty'"
check "rw mount: superblock on the disks is dirty (unclean, sections not in sync)" "[ \"\$(reasons big)\" = 'unclean_shutdown sync_in_progress sync_in_progress' ]"
check "mount: mdadm --build RAID 1 without superblock, base first" "grep -q 'mdadm --build /dev/md11 --level=1 --raid-devices=2 --assume-clean /dev/mapper/xr-a-s1 /dev/mapper/xr-b-s1' '$T/cmd.log'"
check "mount: p5 mapped onto md11 at 512008" "grep -q \"dmsetup create xr-p5 --table 0 1460504296 linear /dev/md11 512008\" '$T/cmd.log'"
check "mount: no table beyond V" "within_v 1465128688"
check "mount: LVM metadata read-only, kernel ext4 rw" "grep -q 'metadata_read_only = 1' '$T/cmd.log' && grep -q 'mount -t ext4 -o noatime /dev/mapper/c-c /c' '$T/cmd.log' && ! grep -q fuse2fs '$T/cmd.log'"
check "mount: xraid-dirty mark set" "[ -e '$R/var/lib/nas-raid/xraid-dirty' ]"
check "mount: never a direct write (dd)" "! grep -q '^dd' '$T/cmd.log'"
echo "/dev/mapper/c-c /c ext4 rw 0 0" > "$R/proc/mounts"
nr unmount 2>/dev/null >/dev/null
check "clean unmount: md stopped, THEN superblock clean, mark removed" "grep -n 'mdadm --stop /dev/md11\|xraid-sb clean' '$T/cmd.log' | head -n 1 | grep -q 'mdadm --stop' && grep -q 'xraid-sb clean' '$T/cmd.log' && [ -z \"\$(reasons big)\" ] && [ ! -e '$R/var/lib/nas-raid/xraid-dirty' ]"
# a repair still running at unmount: superblock left dirty
nr mount 2>/dev/null >/dev/null; echo repair > "$R/sys/block/md11/md/sync_action"; : > "$T/cmd.log"
nr unmount 2>/dev/null >/dev/null; echo idle > "$R/sys/block/md11/md/sync_action"
check "unmount with a resync running: superblock and mark stay dirty" "! grep -q 'xraid-sb clean' '$T/cmd.log' && [ \"\$(reasons big)\" = 'unclean_shutdown sync_in_progress sync_in_progress' ] && [ -e '$R/var/lib/nas-raid/xraid-dirty' ]"
# power loss under Linux: superblock dirty and mark: ro, then verify puts it back clean
: > "$T/cmd.log"; nr mount 2>/dev/null >/dev/null
check "after power loss: read-only (superblock unclean, sections not in sync)" "grep -qx 'xraid-ro unclean_shutdown sync_in_progress sync_in_progress' '$R/var/run/nas-raid.mode' && ! grep -q 'xraid-sb\|mdadm' '$T/cmd.log'"
check "read-only: dm --readonly on the base, LVM read_only_volume_list, ext4 ro" "grep -q 'dmsetup create xr-p5 --readonly --table 0 1460504296 linear .*big/sdb.img 4608040' '$T/cmd.log' && grep -q 'read_only_volume_list' '$T/cmd.log' && grep -q 'mount -t ext4 -o ro,noatime /dev/mapper/c-c /c' '$T/cmd.log' && ! grep -q 'noload' '$T/cmd.log'"
nr unmount 2>/dev/null >/dev/null
# same on small images (a full verify of the 750 GB ones would take too long)
DISKS="$T/clean/sda.img $T/clean/sdb.img"; nr mount 2>/dev/null >/dev/null
echo repair > "$R/sys/block/md11/md/sync_action"; nr unmount 2>/dev/null >/dev/null; echo idle > "$R/sys/block/md11/md/sync_action"
nr mount 2>/dev/null >/dev/null
check "small images, dirty superblock left by Linux: read-only" "[ \"\$(mode_of)\" = xraid-ro ]"
nr unmount 2>/dev/null >/dev/null; nr verify 2>/dev/null >/dev/null; nr mount 2>/dev/null >/dev/null
check "verify after power loss: superblock clean again, mark removed, rw" "[ \"\$(mode_of)\" = xraid-rw ] && grep -q '^ok ' '$R/var/lib/nas-raid/verify.state'"
# XRAID_RESYNC=yes (the default): an unclean stop is resynchronised base -> mirror under 6.18, as RAIDiator does
nr unmount 2>/dev/null >/dev/null; echo XRAID_RW=yes > "$R/etc/nas-raid.conf"
nr mount 2>/dev/null >/dev/null; echo repair > "$R/sys/block/md11/md/sync_action"; nr unmount 2>/dev/null >/dev/null
echo idle > "$R/sys/block/md11/md/sync_action"; : > "$T/cmd.log"; : > "$T/xi.log"; nr mount 2>/dev/null >/dev/null
check "unclean stop, XRAID_RESYNC=yes: rw (resync_after_unclean_stop), no sample comparison" "grep -qx 'xraid-rw resync_after_unclean_stop' '$R/var/run/nas-raid.mode' && ! sampled"
check "unclean stop: the mirror resynchronised from the base (built without --assume-clean, base first), resync mark set" "grep -q '^mdadm --build /dev/md11 --level=1 --raid-devices=2 /dev/mapper/xr-a-s1 /dev/mapper/xr-b-s1\$' '$T/cmd.log' && [ -e '$R/var/lib/nas-raid/xraid-resync' ] && grep -q 'resynchronised from the base while in use' '$R/var/lib/nas-raid/log'"
echo resync > "$R/sys/block/md11/md/sync_action"; : > "$T/cmd.log"; nr unmount 2>/dev/null >/dev/null
check "stopped during the resync: superblock dirty, both marks kept (resync again next time)" "! grep -q 'xraid-sb clean' '$T/cmd.log' && [ -e '$R/var/lib/nas-raid/xraid-dirty' ] && [ -e '$R/var/lib/nas-raid/xraid-resync' ]"
echo idle > "$R/sys/block/md11/md/sync_action"; nr mount 2>/dev/null >/dev/null; : > "$T/cmd.log"; nr unmount 2>/dev/null >/dev/null
check "resync over at the stop: superblock clean, both marks removed" "grep -q 'xraid-sb clean' '$T/cmd.log' && [ ! -e '$R/var/lib/nas-raid/xraid-dirty' ] && [ ! -e '$R/var/lib/nas-raid/xraid-resync' ]"
: > "$T/cmd.log"; nr mount 2>/dev/null >/dev/null
check "clean again: an ordinary rw mount (--assume-clean)" "[ \"\$(mode_of)\" = xraid-rw ] && grep -q 'mdadm --build /dev/md11 --level=1 --raid-devices=2 --assume-clean' '$T/cmd.log'"
echo repair > "$R/sys/block/md11/md/sync_action"; nr unmount 2>/dev/null >/dev/null; echo idle > "$R/sys/block/md11/md/sync_action"
nr mount 2>/dev/null >/dev/null; mdstat '[_U]'; : > "$T/cmd.log"
echo "/dev/mapper/c-c /c ext4 rw 0 0" > "$R/proc/mounts"; nr watch 2>/dev/null >/dev/null; mdstat '[UU]'; : > "$R/proc/mounts"
check "base fails during the resync: nothing recorded on the incomplete mirror, read-only" "! grep -q 'xraid-sb fail' '$T/cmd.log' && grep -q 'base failed during the resync' '$R/var/lib/nas-raid/log' && [ \"\$(mode_of)\" = xraid-ro ]"
nr unmount 2>/dev/null >/dev/null
check "base failed during the resync, at the stop too: nothing recorded" "! grep -q 'xraid-sb fail' '$T/cmd.log'"
rm -f "$R/var/lib/nas-raid/xraid-resync" "$R/var/lib/nas-raid/xraid-dirty"; nr verify 2>/dev/null >/dev/null
printf 'XRAID_RW=yes\nXRAID_RESYNC=no\n' > "$R/etc/nas-raid.conf"; nr mount 2>/dev/null >/dev/null
# a leg fails while writing: watch records it on the survivor and goes read-only
mdstat '[U_]'; : > "$T/cmd.log"
nr watch 2>/dev/null >/dev/null; mdstat '[UU]'
check "leg failure (mirror): xraid-sb fail on the base, then read-only" "grep -q 'xraid-sb fail .*clean/sdb.img' '$T/cmd.log' && [ \"\$(mode_of)\" = xraid-ro ] && ! grep -q 'xraid-sb clean' '$T/cmd.log'"
J=$("$R/bin/xraid-info.real" --json "$T"/clean/*.img)
check "leg failure: mirror recorded faulty, base keeps the volume" "js '[d[\"state\"] for d in j[\"disks\"]]==[\"faulty\",\"online\"] and j[\"read_disk\"].endswith(\"sdb.img\") and j[\"mode\"]==\"ro\"'"
: > "$T/cmd.log"; nr watch 2>/dev/null >/dev/null
check "watch: nothing to do on a read-only X-RAID" "[ ! -s '$T/cmd.log' ]"
nr unmount 2>/dev/null >/dev/null
# X-RAID shut down uncleanly under RAIDiator: ro, then rw after a successful verification
DISKS="$T/dirty/sda.img $T/dirty/sdb.img"; rm -f "$R/var/lib/nas-raid/xraid-verified" "$R/var/lib/nas-raid/xraid-dirty"
: > "$T/xi.log"; nr mount 2>/dev/null >/dev/null
check "dirty superblock: read-only" "grep -q 'xraid-ro unclean_shutdown' '$R/var/run/nas-raid.mode'"
check "read-only forced by another safeguard (XRAID_RW=yes): no comparison" "! sampled"
nr unmount 2>/dev/null >/dev/null; nr verify 2>/dev/null >/dev/null; nr mount 2>/dev/null >/dev/null
check "verified RAIDiator dirty superblock: put back clean, rw" "[ \"\$(mode_of)\" = xraid-rw ]"
nr unmount 2>/dev/null >/dev/null
# quick check: clean superblock, only the Linux mark left -> the mark is lifted
S=$R/var/lib/nas-raid
if [ -n "$E2FS" ]; then
DISKS="$T/fs/sda.img $T/fs/sdb.img"; date +%s > "$S/xraid-dirty"; : > "$T/cmd.log"
nr mount 2>/dev/null >/dev/null
check "quick-verify setup: clean superblock + xraid-dirty mark -> read-only" "grep -q 'xraid-ro unclean_shutdown_linux' '$R/var/run/nas-raid.mode'"
nr quick-verify 2>/dev/null >/dev/null; rc=$?
check "quick-verify, clean superblock, no difference: mark lifted, state ok, superblock untouched" "[ $rc = 0 ] && [ ! -e '$S/xraid-dirty' ] && grep -q '^ok ' '$S/quick.state' && ! grep -q 'xraid-sb' '$T/cmd.log' && grep -q 'xraid-dirty mark removed' '$S/log'"
nr status --json > "$T/e2"
check "status --json: quick result (state, categories, accept 0)" "python3 -c \"import json; q=json.load(open('$T/e2'))['quick']; assert q['state']=='ok' and q['accept']==0 and q['result']['complete']==1 and len(q['result']['categories'])==7\""
nr unmount 2>/dev/null >/dev/null; nr mount 2>/dev/null >/dev/null
check "after the quick check: rw allowed" "[ \"\$(mode_of)\" = xraid-rw ]"
nr unmount 2>/dev/null >/dev/null
# unclean superblock (real crash) -> nothing lifted without an explicit confirmation
DISKS="$T/fsdirty/sda.img $T/fsdirty/sdb.img"; date +%s > "$S/xraid-dirty"; rm -f "$S/xraid-verified"
nr mount 2>/dev/null >/dev/null; : > "$T/cmd.log"
nr quick-verify 2>/dev/null >/dev/null; rc=$?
check "quick-verify, unclean superblock: no difference, but nothing lifted (state confirm)" "[ $rc = 0 ] && grep -q '^confirm ' '$S/quick.state' && [ -e '$S/xraid-dirty' ] && ! grep -q 'xraid-sb' '$T/cmd.log' && [ \"\$(reasons fsdirty)\" = unclean_shutdown ]"
nr quick-accept 2>/dev/null >/dev/null; rc=$?
nr quick-accept --confirm accept --yes 2>/dev/null >/dev/null; rc2=$?
check "quick-accept: refused without the word ACCEPT and --yes, nothing changed" "[ $rc != 0 ] && [ $rc2 != 0 ] && [ -e '$S/xraid-dirty' ] && ! grep -q 'xraid-sb' '$T/cmd.log'"
nr status --json > "$T/e3"
check "status --json: accept offered" "python3 -c \"import json; q=json.load(open('$T/e3'))['quick']; assert q['state']=='confirm' and q['accept']==1\""
nr unmount 2>/dev/null >/dev/null; nr mount 2>/dev/null >/dev/null
nr quick-accept --confirm ACCEPT --yes 2>/dev/null >/dev/null; rc=$?
check "quick-accept: refused after a (re)mount (token valid for one boot, before any mount)" "[ $rc != 0 ] && [ -e '$S/xraid-dirty' ]"
nr quick-verify 2>/dev/null >/dev/null; : > "$T/cmd.log"
nr quick-accept --confirm ACCEPT --yes 2>/dev/null >/dev/null; rc=$?
check "quick-accept confirmed: mark removed, superblock clean (as verify), state accepted" "[ $rc = 0 ] && [ ! -e '$S/xraid-dirty' ] && grep -q 'xraid-sb clean' '$T/cmd.log' && [ -z \"\$(reasons fsdirty)\" ] && grep -q '^accepted ' '$S/quick.state'"
nr unmount 2>/dev/null >/dev/null
# a difference in the journal: nothing lifted, repair needed
python3 "$HERE/make-images.py" "$T/qd" fsdirty > /dev/null; python3 "$HERE/make-images.py" "$T/qd" poke journal > /dev/null
DISKS="$T/qd/sda.img $T/qd/sdb.img"; date +%s > "$S/xraid-dirty"
nr mount 2>/dev/null >/dev/null; nr quick-verify 2>/dev/null >/dev/null; rc=$?
nr quick-accept --confirm ACCEPT --yes 2>/dev/null >/dev/null; rc2=$?
check "quick-verify, difference in the journal: code 1, state differences, mark kept, accept refused" "[ $rc = 1 ] && grep -q '^differences ' '$S/quick.state' && [ -e '$S/xraid-dirty' ] && [ $rc2 != 0 ]"
nr unmount 2>/dev/null >/dev/null; rm -f "$S/xraid-dirty"
fi
DISKS="$T/degraded/sdb.img"; : > "$T/cmd.log"
nr mount 2>/dev/null >/dev/null
check "missing disk at boot: read-only on the present disk, nothing written" "grep -q 'xraid-ro missing_disk' '$R/var/run/nas-raid.mode' && ! grep -q 'mdadm\|xraid-sb' '$T/cmd.log'"
nr unmount 2>/dev/null >/dev/null
DISKS="$T/different/sda.img $T/different/sdb.img"
: > "$T/cmd.log"; : > "$T/xi.log"; nr mount 2>/dev/null >/dev/null
check "different mirror: read-only" "grep -q 'xraid-ro mirror_differs' '$R/var/run/nas-raid.mode'"
check "different mirror: found by the comparison before rw, nothing written" "sampled && ! grep -q 'mdadm\|xraid-sb' '$T/cmd.log'"
nr repair 2>/dev/null >/dev/null; rc=$?
check "repair: refused without confirmation" "[ $rc != 0 ]"
nr unmount 2>/dev/null >/dev/null
DISKS="$T/sync/sda.img $T/sync/sdb.img"
nr mount 2>/dev/null >/dev/null
check "unfinished synchronisation: read-only" "grep -q 'xraid-ro sync_in_progress' '$R/var/run/nas-raid.mode'"
nr unmount 2>/dev/null >/dev/null
# without the writer: no rw
python3 "$HERE/make-images.py" "$T/c2" clean > /dev/null; DISKS="$T/c2/sda.img $T/c2/sdb.img"; mv "$R/bin/xraid-sb" "$R/bin/xraid-sb.off"; : > "$T/cmd.log"
nr mount 2>/dev/null >/dev/null; mv "$R/bin/xraid-sb.off" "$R/bin/xraid-sb"
check "no superblock writer: read-only (no_sb_writer)" "grep -q 'xraid-ro no_sb_writer' '$R/var/run/nas-raid.mode' && ! grep -q mdadm '$T/cmd.log'"
nr status --json > "$T/e0"
check "status --json: valid, superblock writer reported" "python3 -c \"import json; j=json.load(open('$T/e0')); assert j['sb_writer']=='yes' and 'migration' not in j and 'relay' not in j\""
nr unmount 2>/dev/null >/dev/null

# ---------- Flex-RAID: RAIDiator md volumes (X-RAID off), read-only ----------
fr() { "$R/bin/xraid-info.real" flexraid "$T/$1"/*.img; }
frv() { fr "$1" | sed -n "s/^FR_$2='\(.*\)'/\1/p"; }
check "flexraid: X-RAID images hold no md 0.90 array" "[ \"\$(fr clean | head -n 1)\" = FR_NR_ARRAYS=0 ]"
check "flexraid images: no X-RAID superblock" "[ \"\$(reasons flexraid)\" = no_xraid ]"
check "flexraid: 4 arrays (root, swap, data RAID 1, data RAID 0), all usable" "fr flexraid | grep -qx FR_NR_ARRAYS=4 && [ \"\$(frv flexraid A2)\" = '2 raid1 1 1048448' ] && [ \"\$(frv flexraid A3)\" = '3 raid0 1 4357632' ]"
check "flexraid: RAID 1 = linear on the first in-sync member, RAID 0 = striped in role order, 16 KiB chunk" "[ \"\$(frv flexraid A2_TABLE)\" = '0 1048448 linear $T/flexraid/sda.img 5144608' ] && [ \"\$(frv flexraid A3_TABLE)\" = '0 4357632 striped 2 32 $T/flexraid/sdb.img 6193192 $T/flexraid/sda.img 6193192' ]"
check "flexraid: superblocks as a PC writes them (x86 layout) read alike" "[ \"\$(fr flexraid-x86 | grep -v _FORMAT= | sed 's/flexraid-x86/X/g')\" = \"\$(fr flexraid | grep -v _FORMAT= | sed 's/flexraid/X/g')\" ]"
check "flexraid: big-endian superblocks read alike" "[ \"\$(fr flexraid-be | grep -v _FORMAT= | sed 's/flexraid-be/X/g')\" = \"\$(fr flexraid | grep -v _FORMAT= | sed 's/flexraid/X/g')\" ]"
# the dm tables, read back the way dm linear/striped map them, find what the images hold
dmread() {	# dmread TABLE SECTOR LENGTH: bytes at SECTOR of the mapped device
	python3 - "$@" <<'EOF'
import sys
t, s, n = sys.argv[1].split(), int(sys.argv[2]), int(sys.argv[3])
if t[2] == "linear":
    dev, off = t[3], int(t[4]) + s
else:
    k, cs = int(t[3]), int(t[4])
    c, r = divmod(s, cs)
    dev, off = t[5 + 2 * (c % k)], int(t[6 + 2 * (c % k)]) + (c // k) * cs + r
with open(dev, "rb") as f:
    f.seek(off * 512)
    sys.stdout.write(f.read(n).decode("latin-1"))
EOF
}
t3=$(frv flexraid A3_TABLE); ok=1
for k in 0 1 2 3 4 5 6 7; do [ "$(dmread "$t3" $((k * 32)) 9)" = "$(printf 'CHUNK%04d' $k)" ] || ok=; done
check "flexraid: RAID 0 table gives the 8 logical chunks in order" "[ -n '$ok' ]"
check "flexraid: RAID 1 table gives the data volume" "[ \"\$(dmread \"\$(frv flexraid A2_TABLE)\" 0 8)\" = VOLUME-C ]"
check "flexraid degraded (one disk): RAID 1 read from it, RAID 0 refused" "[ \"\$(frv flexraid-degraded A2)\" = '2 raid1 1 1048448' ] && [ \"\$(frv flexraid-degraded A2_REASONS)\" = degraded ] && [ \"\$(frv flexraid-degraded A3)\" = '3 raid0 0 0' ] && [ \"\$(frv flexraid-degraded A3_REASONS)\" = missing_member ] && [ -z \"\$(frv flexraid-degraded A3_TABLE)\" ]"
check "flexraid stale member (older events): read from the up-to-date one" "[ \"\$(dmread \"\$(frv flexraid-stale A2_TABLE)\" 0 8)\" = VOLUME-C ] && [ \"\$(frv flexraid-stale A2_REASONS)\" = 'degraded stale_member' ]"
check "flexraid: what the arrays hold (md2: LVM2 label)" "[ \"\$(frv flexraid A2_CONTENT)\" = lvm2 ]"
check "flexraid: a volume still in LVM1 (created, RAIDiator not rebooted since) is reported" "[ \"\$(frv flexraid-lvm1 A2_CONTENT)\" = lvm1 ] && [ \"\$(frv flexraid-lvm1 A2_REASONS)\" = lvm1 ] && [ \"\$(frv flexraid-lvm1 A2)\" = '2 raid1 1 1048448' ]"
J=$("$R/bin/xraid-info.real" flexraid --json "$T"/flexraid/*.img)
check "flexraid --json: valid, levels, RAIDiator's byte order, members" "js '[a[\"level\"] for a in j[\"arrays\"]]==[\"raid1\"]*3+[\"raid0\"] and all(a[\"byte_order\"]==\"raidiator\" and a[\"usable\"]==1 and [m[\"state\"] for m in a[\"members\"]]==[\"in_sync\"]*2 for a in j[\"arrays\"])'"
# nas-raid: VGs c and d (plus a snapshot LV) seen by the simulated lvm
stub lvm 'case "$1" in lvs) printf "  c c owi-a-----\n  c snap swi-a-s---\n  d d -wi-a-----\n";; pvs) printf "  /dev/mapper/fr-md2 c\n  /dev/mapper/fr-md3 d\n";; esac'
DISKS="$T/flexraid/sda.img $T/flexraid/sdb.img"; h=$(md5sum "$T"/flexraid/*.img)
: > "$T/cmd.log"; : > "$T/xi.log"; nr mount 2>/dev/null >/dev/null
check "Flex-RAID mount: mode flexraid-ro, 4 arrays mapped" "[ \"\$(mode_of)\" = flexraid-ro ] && [ \$(grep -c '^dmsetup create fr-md[0-3] --readonly --table' '$T/cmd.log') = 4 ]"
check "Flex-RAID mount: every dm table read-only, never md, xraid-sb nor dd" "! grep '^dmsetup create' '$T/cmd.log' | grep -qv -- --readonly && ! grep -q '^mdadm\|^xraid-sb\|^dd' '$T/cmd.log'"
check "Flex-RAID mount: LVM read-only (metadata and both VGs), c on /c and d on /d read-only, no snapshot" "grep -q 'metadata_read_only = 1.*read_only_volume_list = \[ \"c\", \"d\" \] } c d' '$T/cmd.log' && grep -q 'mount -t ext4 -o ro,noatime /dev/mapper/c-c /c' '$T/cmd.log' && grep -q 'mount -t ext4 -o ro,noatime /dev/mapper/d-d /d' '$T/cmd.log' && ! grep -q snap '$T/cmd.log'"
printf '/dev/mapper/c-c /c ext4 ro 0 0\n/dev/mapper/d-d /d ext4 ro 0 0\n' > "$R/proc/mounts"; : > "$T/cmd.log"
nr status --json > "$T/fr1"
check "status --json: valid, mode flexraid-ro, arrays listed, xraid stays the last key" "python3 -c \"import json; j=json.load(open('$T/fr1')); assert j['mode']=='flexraid-ro' and len(j['flexraid']['arrays'])==4 and list(j)[-1]=='xraid'\""
nr unmount 2>/dev/null >/dev/null
check "Flex-RAID unmount: /c and /d unmounted, VGs off, arrays removed" "grep -q '^umount /c' '$T/cmd.log' && grep -q '^umount /d' '$T/cmd.log' && grep -q 'vgchange -an .* c d' '$T/cmd.log' && [ \$(grep -c '^dmsetup remove fr-md' '$T/cmd.log') = 4 ] && [ \"\$(cat '$R/var/run/nas-raid.mode')\" = 'none stopped' ] && [ ! -e '$R/var/run/flexraid.state' ]"
check "Flex-RAID: the disk images were never written" "[ \"\$(md5sum '$T'/flexraid/*.img)\" = \"$h\" ]"
# RAID 5 (a 4-bay RAIDiator's data volume on 3 disks or more): dm-raid over read-only legs, no metadata, nosync
check "flexraid RAID 5: 3 disks, left-asymmetric (RAIDiator's), (3 - 1) x the member size, dm-raid table on the legs, nosync" "[ \"\$(frv flexraid-r5 A2)\" = '2 raid5 1 2096896' ] && [ \"\$(frv flexraid-r5 A2_TABLE)\" = '0 2096896 raid raid5_la 2 32 nosync 3 - /dev/mapper/frl-md2-0 - /dev/mapper/frl-md2-1 - /dev/mapper/frl-md2-2' ] && [ \"\$(frv flexraid-r5 A2_LEGS)\" = '0:$T/flexraid-r5/sda.img:5144608:1048448 1:$T/flexraid-r5/sdb.img:5144608:1048448 2:$T/flexraid-r5/sdc.img:5144608:1048448' ] && [ -z \"\$(frv flexraid-r5 A2_REASONS)\" ] && [ \"\$(frv flexraid-r5 A2_CONTENT)\" = lvm2 ]"
r5read() {	# r5read TABLE LEGS SECTOR LENGTH: bytes at SECTOR of the dm-raid device (raid5_* layouts, as md maps them)
	python3 - "$@" <<'EOF'
import sys
t, legs, s, n = sys.argv[1].split(), sys.argv[2].split(), int(sys.argv[3]), int(sys.argv[4])
alg, cs, nd = t[3], int(t[5]), int(t[7])
leg = {int(l.split(":")[0]): l.split(":")[1:3] for l in legs}
c, r = divmod(s, cs)
st, dd = divmod(c, nd - 1)
pd = (nd - 1 - st % nd) if alg in ("raid5_la", "raid5_ls") else st % nd
dk = (pd + 1 + dd) % nd if alg in ("raid5_ls", "raid5_rs") else dd + (dd >= pd)
assert t[9 + 2 * dk] == "/dev/mapper/frl-md2-%d" % dk
path, start = leg[dk]
with open(path, "rb") as f:
    f.seek((int(start) + st * cs + r) * 512)
    sys.stdout.write(f.read(n).decode("latin-1"))
EOF
}
t5=$(frv flexraid-r5 A2_TABLE); l5=$(frv flexraid-r5 A2_LEGS); ok=1
for k in 0 1 2 3 4 5 6 7; do [ "$(r5read "$t5" "$l5" $((k * 32)) 9)" = "$(printf 'CHUNK%04d' $k)" ] || ok=; done
check "flexraid RAID 5: the table and legs give the 8 logical chunks in order (parity rotating as md's left-asymmetric)" "[ -n '$ok' ]"
check "flexraid RAID 5, one disk missing: read degraded, its slot '- -', no leg for it" "[ \"\$(frv flexraid-r5-degraded A2)\" = '2 raid5 1 2096896' ] && [ \"\$(frv flexraid-r5-degraded A2_REASONS)\" = degraded ] && [ \"\$(frv flexraid-r5-degraded A2_TABLE)\" = '0 2096896 raid raid5_la 2 32 nosync 3 - /dev/mapper/frl-md2-0 - /dev/mapper/frl-md2-1 - -' ] && ! frv flexraid-r5-degraded A2_LEGS | grep -q sdc"
check "flexraid RAID 5, two disks missing: not readable" "[ \"\$('$R/bin/xraid-info.real' flexraid '$T/flexraid-r5/sda.img' | sed -n \"s/^FR_A2='\(.*\)'/\1/p\")\" = '2 raid5 0 0' ] && '$R/bin/xraid-info.real' flexraid '$T/flexraid-r5/sda.img' | grep -qx \"FR_A2_REASONS='missing_member'\""
stub lvm 'case "$1" in lvs) printf "  c c -wi-a-----\n  d d -wi-a-----\n";; pvs) printf "  /dev/mapper/fr-md2 c\n  /dev/mapper/fr-md3 d\n";; esac'
DISKS="$T/flexraid-r5/sda.img $T/flexraid-r5/sdb.img $T/flexraid-r5/sdc.img"; h=$(md5sum "$T"/flexraid-r5/*.img)
cp "$R/etc/nas-raid.conf" "$T/nrconf.r5" 2>/dev/null; echo FLEXRAID_RW=yes > "$R/etc/nas-raid.conf"
: > "$T/cmd.log"; : > "$R/proc/mounts"; nr mount 2>/dev/null >/dev/null
check "Flex-RAID RAID 5 mount: read-only legs first, then fr-md2 read-only on them, never md nor flexraid-sb" "[ \"\$(grep -n '^dmsetup create frl-md2-\|^dmsetup create fr-md2 ' '$T/cmd.log' | cut -d: -f2- | cut -d' ' -f3-5 | tr '\\n' '|')\" = 'frl-md2-0 --readonly --table|frl-md2-1 --readonly --table|frl-md2-2 --readonly --table|fr-md2 --readonly --table|' ] && grep -q '^dmsetup create frl-md2-2 --readonly --table 0 1048448 linear $T/flexraid-r5/sdc.img 5144608\$' '$T/cmd.log' && grep -q '^dmsetup create fr-md2 --readonly --table 0 2096896 raid raid5_la ' '$T/cmd.log' && ! grep -q '^mdadm\|^flexraid-sb' '$T/cmd.log'"
check "Flex-RAID RAID 5 with FLEXRAID_RW=yes but no flexraid-sb: c (RAID 5) read-only, d (3-disk RAID 0) writable" "grep -q 'mount -t ext4 -o ro,noatime /dev/mapper/c-c /c' '$T/cmd.log' && grep -q 'errors=remount-ro,noatime /dev/mapper/d-d /d' '$T/cmd.log'"
: > "$T/cmd.log"; nr unmount 2>/dev/null >/dev/null
check "Flex-RAID RAID 5 unmount: fr-md2 removed before its legs, images never written" "[ \"\$(grep -n '^dmsetup remove fr-md2\$\|^dmsetup remove frl-md2-' '$T/cmd.log' | cut -d: -f2- | tr '\\n' '|')\" = 'dmsetup remove fr-md2|dmsetup remove frl-md2-0|dmsetup remove frl-md2-1|dmsetup remove frl-md2-2|' ] && [ \"\$(md5sum '$T'/flexraid-r5/*.img)\" = \"$h\" ]"
if [ -e "$T/nrconf.r5" ]; then mv "$T/nrconf.r5" "$R/etc/nas-raid.conf"; else rm -f "$R/etc/nas-raid.conf"; fi
: > "$R/proc/mounts"
: > "$R/proc/mounts"
DISKS="$T/flexraid-degraded/sda.img"; : > "$T/cmd.log"; nr mount 2>/dev/null >/dev/null
check "Flex-RAID one disk: RAID 0 array not mapped, mode flexraid-ro (degraded missing_member)" "grep -qx 'flexraid-ro degraded missing_member' '$R/var/run/nas-raid.mode' && ! grep -q 'fr-md3' '$T/cmd.log'"
nr unmount 2>/dev/null >/dev/null
# FLEXRAID_RW=yes: the RAID 0 volume d (md3) writable, the RAID 1 volume c read-only
cp "$R/etc/nas-raid.conf" "$T/nrconf.bak"; echo FLEXRAID_RW=yes >> "$R/etc/nas-raid.conf"
DISKS="$T/flexraid/sda.img $T/flexraid/sdb.img"; h=$(md5sum "$T"/flexraid/*.img); : > "$T/cmd.log"; : > "$R/proc/mounts"
nr mount 2>/dev/null >/dev/null
check "FLEXRAID_RW=yes: only the RAID 0 array (md3) mapped writable" "grep -q '^dmsetup create fr-md3 --table' '$T/cmd.log' && grep -q '^dmsetup create fr-md2 --readonly' '$T/cmd.log' && [ \$(grep -c '^dmsetup create fr-md[0-3] --readonly' '$T/cmd.log') = 3 ]"
check "FLEXRAID_RW=yes: VG d out of read_only_volume_list, c in it; d mounted rw (errors=remount-ro), c ro" "grep -q 'read_only_volume_list = \[ \"c\" \] } c d' '$T/cmd.log' && grep -q 'mount -t ext4 -o errors=remount-ro,noatime /dev/mapper/d-d /d' '$T/cmd.log' && grep -q 'mount -t ext4 -o ro,noatime /dev/mapper/c-c /c' '$T/cmd.log'"
check "FLEXRAID_RW=yes: mode flexraid-rw, nothing written on the disks (no md, no superblock)" "[ \"\$(mode_of)\" = flexraid-rw ] && ! grep -q '^mdadm\\|^xraid-sb\\|^dd' '$T/cmd.log' && [ \"\$(md5sum '$T'/flexraid/*.img)\" = \"$h\" ]"
printf '/dev/mapper/c-c /c ext4 ro 0 0\n/dev/mapper/d-d /d ext4 rw 0 0\n' > "$R/proc/mounts"
nr status --json > "$T/frw"
check "status --json: flexraid_rw yes, /d read-write" "python3 -c \"import json; j=json.load(open('$T/frw')); assert j['flexraid_rw']=='yes' and j['flexraid_rw_mounts']=='/d' and j['mode']=='flexraid-rw'\""
nr unmount 2>/dev/null >/dev/null; : > "$R/proc/mounts"
# a snapshot in VG d: read-only, reason snapshot
stub lvm 'case "$1" in lvs) printf "  c c -wi-a-----\n  d d owi-a-----\n  d d_2026_11_26_12_00 swi-a-s---\n";; pvs) printf "  /dev/mapper/fr-md2 c\n  /dev/mapper/fr-md3 d\n";; esac'
: > "$T/cmd.log"; nr mount 2>/dev/null >/dev/null
check "FLEXRAID_RW=yes, snapshot in VG d: d read-only, reason snapshot" "grep -q 'flexraid-ro.*snapshot' '$R/var/run/nas-raid.mode' && grep -q 'mount -t ext4 -o ro,noatime /dev/mapper/d-d /d' '$T/cmd.log' && ! grep -q errors=remount-ro '$T/cmd.log'"
nr unmount 2>/dev/null >/dev/null
# one disk: the RAID 0 array is not usable, nothing writable
stub lvm 'case "$1" in lvs) printf "  c c -wi-a-----\n";; pvs) printf "  /dev/mapper/fr-md2 c\n";; esac'
DISKS="$T/flexraid-degraded/sda.img"; : > "$T/cmd.log"; nr mount 2>/dev/null >/dev/null
check "FLEXRAID_RW=yes, one disk: no writable array, c read-only" "grep -q '^flexraid-ro' '$R/var/run/nas-raid.mode' && ! grep -q '^dmsetup create fr-md[0-9]* --table' '$T/cmd.log'"
nr unmount 2>/dev/null >/dev/null
# RAID 1 read-write (flexraid-sb present): a mirror without metadata, a crash mark of ours
printf '#!/bin/sh\necho "flexraid-sb $*" >> "%s/cmd.log"\nexec "%s/flexraid-sb.real" "$@"\n' "$T" "$T" > "$R/bin/flexraid-sb"; chmod 755 "$R/bin/flexraid-sb"
stub lvm 'case "$1" in lvs) printf "  c c -wi-a-----\n  d d -wi-a-----\n";; pvs) printf "  /dev/mapper/fr-md2 c\n  /dev/mapper/fr-md3 d\n";; esac'
mkdir -p "$R/sys/block/md102/md"; echo idle > "$R/sys/block/md102/md/sync_action"
fr1stat() { mdstat '[UU]'; printf 'md102 : active raid1 dm-5[1] dm-4[0]\n      100 blocks [2/2] %s\n' "$1" >> "$R/proc/mdstat"; }
FRW=$T/fr-rw; cp -r "$T/flexraid" "$FRW"; DISKS="$FRW/sda.img $FRW/sdb.img"; h=$(md5sum "$FRW"/*.img)
S=$R/var/lib/nas-raid; MK=$S/flexraid-dirty-md2; rm -f "$MK"; fr1stat '[UU]'
: > "$T/cmd.log"; : > "$R/proc/mounts"; nr mount 2>/dev/null >/dev/null
check "RAID 1 rw: legs = the members' data areas, outside the LVM filter (frl-)" "grep -q '^dmsetup create frl-md2-0 --table 0 1048448 linear $FRW/sda.img 5144608\$' '$T/cmd.log' && grep -q '^dmsetup create frl-md2-1 --table 0 1048448 linear $FRW/sdb.img 5144608\$' '$T/cmd.log'"
check "RAID 1 rw: mdadm --build, no superblock, role 0 first, --assume-clean; fr-md2 writable on it" "grep -q '^mdadm --build /dev/md102 --level=1 --raid-devices=2 --assume-clean /dev/mapper/frl-md2-0 /dev/mapper/frl-md2-1\$' '$T/cmd.log' && grep -q '^dmsetup create fr-md2 --table 0 1048448 linear /dev/md102 0\$' '$T/cmd.log'"
check "RAID 1 rw: c and d mounted read-write, md0/md1 (no LVM) stay read-only, crash mark set" "grep -q 'mount -t ext4 -o errors=remount-ro,noatime /dev/mapper/c-c /c' '$T/cmd.log' && grep -q 'mount -t ext4 -o errors=remount-ro,noatime /dev/mapper/d-d /d' '$T/cmd.log' && grep -q '^dmsetup create fr-md0 --readonly' '$T/cmd.log' && grep -q '^dmsetup create fr-md1 --readonly' '$T/cmd.log' && [ -e '$MK' ] && [ \"\$(mode_of)\" = flexraid-rw ]"
: > "$T/cmd.log"; nr unmount 2>/dev/null >/dev/null
check "RAID 1 clean stop: fr-md2, then md, then legs removed; mark removed; superblocks untouched" "[ \"\$(grep -n '^dmsetup remove fr-md2\$\|^mdadm --stop /dev/md102\|^dmsetup remove frl-md2-1' '$T/cmd.log' | cut -d: -f2- | tr '\\n' '|')\" = 'dmsetup remove fr-md2|mdadm --stop /dev/md102|dmsetup remove frl-md2-1|' ] && [ ! -e '$MK' ] && ! grep -q '^flexraid-sb\|^xraid-sb' '$T/cmd.log' && [ \"\$(md5sum '$FRW'/*.img)\" = \"$h\" ]"
echo 1 > "$MK"; : > "$T/cmd.log"; nr mount 2>/dev/null >/dev/null
check "RAID 1 after a Linux crash (mark left): built without --assume-clean (md resyncs role 1 from role 0)" "grep -q '^mdadm --build /dev/md102 --level=1 --raid-devices=2 /dev/mapper/frl-md2-0' '$T/cmd.log' && grep -q 'resynchronised from role 0' '$S/log'"
echo resync > "$R/sys/block/md102/md/sync_action"; nr unmount 2>/dev/null >/dev/null
check "RAID 1 stopped while resyncing: mark kept, nothing written" "[ -e '$MK' ] && ! grep -q '^flexraid-sb fail' '$T/cmd.log' && [ \"\$(md5sum '$FRW'/*.img)\" = \"$h\" ]"
echo idle > "$R/sys/block/md102/md/sync_action"; rm -f "$MK"
nr mount 2>/dev/null >/dev/null; fr1stat '[U_]'; : > "$T/cmd.log"; nr unmount 2>/dev/null >/dev/null
check "RAID 1 role 1 failed at stop: recorded on role 0 (flexraid-sb fail), mark removed" "grep -q '^flexraid-sb fail $FRW/sda.img:5144608:1048448:0:in_sync\$' '$T/cmd.log' && [ ! -e '$MK' ]"
check "RAID 1 after the failure: role 1 stale, read from role 0, c read-only next time" "[ \"\$(frv fr-rw A2_REASONS)\" = 'degraded stale_member' ] && [ \"\$(frv fr-rw A2_TABLE)\" = '0 1048448 linear $FRW/sda.img 5144608' ]"
fr1stat '[UU]'; : > "$T/cmd.log"; nr mount 2>/dev/null >/dev/null
check "RAID 1 with a stale member: no mirror built, fr-md2 read-only" "! grep -q '^mdadm' '$T/cmd.log' && grep -q '^dmsetup create fr-md2 --readonly' '$T/cmd.log'"
nr unmount 2>/dev/null >/dev/null
# a leg failing while mounted read-write: nas-raid watch records it at once and remounts
rm -rf "$FRW"; cp -r "$T/flexraid" "$FRW"; rm -f "$MK"; : > "$R/proc/mounts"
nr mount 2>/dev/null >/dev/null; fr1stat '[_U]'; : > "$T/cmd.log"
printf '/dev/mapper/c-c /c ext4 rw 0 0\n/dev/mapper/d-d /d ext4 rw 0 0\n' > "$R/proc/mounts"; nr watch 2>/dev/null >/dev/null
check "watch: role 0 failed while writing: recorded on role 1, volumes remounted, c read-only" "grep -q '^flexraid-sb fail $FRW/sdb.img:5144608:1048448:1:in_sync\$' '$T/cmd.log' && grep -q '^umount /c' '$T/cmd.log' && grep -q '^dmsetup create fr-md2 --readonly' '$T/cmd.log' && [ \"\$(frv fr-rw A2_TABLE)\" = '0 1048448 linear $FRW/sdb.img 5144608' ]"
fr1stat '[UU]'; nr unmount 2>/dev/null >/dev/null; : > "$R/proc/mounts"
check "watch: failure recorded, mark removed" "[ ! -e '$MK' ]"
# the failure cannot be written: the mark keeps the failed role, never a resync afterwards
rm -rf "$FRW"; cp -r "$T/flexraid" "$FRW"; h=$(md5sum "$FRW"/*.img)
printf '#!/bin/sh\necho "flexraid-sb $*" >> "%s/cmd.log"\n[ "$1" = fail ] && exit 2\nexec "%s/flexraid-sb.real" "$@"\n' "$T" "$T" > "$R/bin/flexraid-sb"
nr mount 2>/dev/null >/dev/null; fr1stat '[U_]'; nr unmount 2>/dev/null >/dev/null; fr1stat '[UU]'; : > "$T/cmd.log"
nr mount 2>/dev/null >/dev/null
check "failure not recorded: mark 'failed role 1' kept, next mount read-only (failure_unrecorded), no mirror" "grep -q '^failed role 1' '$MK' && ! grep -q '^mdadm' '$T/cmd.log' && grep -q '^dmsetup create fr-md2 --readonly' '$T/cmd.log' && grep -q failure_unrecorded '$R/var/run/nas-raid.mode' && [ \"\$(md5sum '$FRW'/*.img)\" = \"$h\" ]"
nr unmount 2>/dev/null >/dev/null; rm -f "$MK"
# a volume still busy at the stop: the md is not known to be stopped, the mark stays
printf '#!/bin/sh\necho "flexraid-sb $*" >> "%s/cmd.log"\nexec "%s/flexraid-sb.real" "$@"\n' "$T" "$T" > "$R/bin/flexraid-sb"
stub umount 'case "$1" in /c) exit 1;; esac'
nr mount 2>/dev/null >/dev/null; printf '/dev/mapper/c-c /c ext4 rw 0 0\n' > "$R/proc/mounts"; nr unmount 2>/dev/null >/dev/null
check "RAID 1 volume busy at the stop: crash mark kept" "[ -e '$MK' ]"
# RAID 1 of three disks read-write: three legs, a 3-disk mirror; one or two legs failed
stub umount; : > "$R/proc/mounts"; rm -f "$MK"
fr3stat() { mdstat '[UU]'; printf 'md102 : active raid1 dm-6[2] dm-5[1] dm-4[0]\n      100 blocks [3/3] %s\n' "$1" >> "$R/proc/mdstat"; }
FR3=$T/fr-rw3; cp -r "$T/flexraid-3" "$FR3"; DISKS="$FR3/sda.img $FR3/sdb.img $FR3/sdc.img"; h=$(md5sum "$FR3"/*.img)
fr3stat '[UUU]'; : > "$T/cmd.log"; nr mount 2>/dev/null >/dev/null
check "RAID 1, 3 disks, rw: three legs, mdadm --build of 3 devices in role order, --assume-clean, c and d (3-disk RAID 0) writable" "grep -q '^dmsetup create frl-md2-2 --table 0 1048448 linear $FR3/sdc.img 5144608\$' '$T/cmd.log' && grep -q '^mdadm --build /dev/md102 --level=1 --raid-devices=3 --assume-clean /dev/mapper/frl-md2-0 /dev/mapper/frl-md2-1 /dev/mapper/frl-md2-2\$' '$T/cmd.log' && grep -q 'errors=remount-ro,noatime /dev/mapper/c-c /c' '$T/cmd.log' && grep -q 'errors=remount-ro,noatime /dev/mapper/d-d /d' '$T/cmd.log' && [ -e '$MK' ]"
: > "$T/cmd.log"; nr unmount 2>/dev/null >/dev/null
check "RAID 1, 3 disks, clean stop: the three legs removed, mark removed, superblocks untouched" "grep -q '^dmsetup remove frl-md2-2\$' '$T/cmd.log' && [ ! -e '$MK' ] && ! grep -q '^flexraid-sb fail' '$T/cmd.log' && [ \"\$(md5sum '$FR3'/*.img)\" = \"$h\" ]"
nr mount 2>/dev/null >/dev/null; fr3stat '[U_U]'; : > "$T/cmd.log"; nr unmount 2>/dev/null >/dev/null
check "RAID 1, 3 disks, role 1 failed: recorded on roles 0 and 2, mark removed, role 1 stale next time" "grep -q '^flexraid-sb fail $FR3/sda.img:5144608:1048448:0:in_sync $FR3/sdc.img:5144608:1048448:2:in_sync\$' '$T/cmd.log' && grep -q 'role 1 failed, recording it on role 0,2' '$S/log' && [ ! -e '$MK' ] && [ \"\$(frv fr-rw3 A2_REASONS)\" = 'degraded stale_member' ]"
rm -rf "$FR3"; cp -r "$T/flexraid-3" "$FR3"; fr3stat '[UUU]'
nr mount 2>/dev/null >/dev/null; fr3stat '[__U]'; : > "$T/cmd.log"; nr unmount 2>/dev/null >/dev/null
check "RAID 1, 3 disks, roles 0 and 1 failed: recorded on role 2 alone, read from role 2 next time" "grep -q '^flexraid-sb fail $FR3/sdc.img:5144608:1048448:2:in_sync\$' '$T/cmd.log' && [ \"\$(frv fr-rw3 A2_TABLE)\" = '0 1048448 linear $FR3/sdc.img 5144608' ]"
rm -rf "$FR3"; cp -r "$T/flexraid-3" "$FR3"; fr3stat '[UUU]'
nr mount 2>/dev/null >/dev/null; fr3stat '[___]'; : > "$T/cmd.log"; nr unmount 2>/dev/null >/dev/null
check "RAID 1, 3 disks, every leg failed: nothing written, mark kept" "! grep -q '^flexraid-sb fail' '$T/cmd.log' && [ -e '$MK' ]"
rm -f "$MK"
# RAID 5 read-write: dm-raid on writable legs, the crash mark, its health from dmsetup status
dst() { echo "0 2096896 raid raid5_la 3 $1 1048448/1048448 $2 0 0 -" > "$R/dmst-fr-md2"; }
stub dmsetup 'case "$1" in status) cat "'"$R"'/dmst-$2" 2>/dev/null;; esac'
FR5=$T/fr-rw5; cp -r "$T/flexraid-r5" "$FR5"; DISKS="$FR5/sda.img $FR5/sdb.img $FR5/sdc.img"; h=$(md5sum "$FR5"/*.img)
mdstat '[UU]'; dst AAA idle; : > "$T/cmd.log"; : > "$R/proc/mounts"; nr mount 2>/dev/null >/dev/null
check "RAID 5 rw: legs and fr-md2 writable, nosync (no resync), c mounted read-write, crash mark set" "grep -q '^dmsetup create frl-md2-0 --table 0 1048448 linear $FR5/sda.img 5144608\$' '$T/cmd.log' && grep -q '^dmsetup create fr-md2 --table 0 2096896 raid raid5_la 2 32 nosync 3 ' '$T/cmd.log' && grep -q 'errors=remount-ro,noatime /dev/mapper/c-c /c' '$T/cmd.log' && [ -e '$MK' ] && [ \"\$(mode_of)\" = flexraid-rw ]"
check "RAID 5 rw: a failure checked recordable for every member (dry run, the other two)" "[ \$(grep -c '^flexraid-sb --dry-run fail [^ ]* [^ ]*\$' '$T/cmd.log') = 3 ]"
dst aaa resync; nr watch 2>/dev/null >/dev/null; nr status --json > "$T/fr5s"
check "RAID 5 rw: its live state noted (dm-raid is not in /proc/mdstat), in status --json" "[ \"\$(cat '$R/var/run/flexraid.sync')\" = '2 aaa resync 100' ] && python3 -c \"import json; j=json.load(open('$T/fr5s')); assert j['flexraid_sync']==[{'minor':2,'health':'aaa','action':'resync','percent':100}] and list(j)[-1]=='xraid'\""
dst AAA idle
: > "$T/cmd.log"; nr unmount 2>/dev/null >/dev/null
check "RAID 5 clean stop: the live note removed" "[ ! -e '$R/var/run/flexraid.sync' ]"
check "RAID 5 clean stop: fr-md2 then its legs removed, mark removed, superblocks untouched" "[ \"\$(grep -n '^dmsetup remove fr-md2\$\|^dmsetup remove frl-md2-0' '$T/cmd.log' | cut -d: -f2- | tr '\\n' '|')\" = 'dmsetup remove fr-md2|dmsetup remove frl-md2-0|' ] && [ ! -e '$MK' ] && ! grep -q '^flexraid-sb fail' '$T/cmd.log' && [ \"\$(md5sum '$FR5'/*.img)\" = \"$h\" ]"
echo 1 > "$MK"; : > "$T/cmd.log"; nr mount 2>/dev/null >/dev/null
check "RAID 5 after a Linux crash (mark left): sync instead of nosync, md recomputes the whole parity" "grep -q '^dmsetup create fr-md2 --table 0 2096896 raid raid5_la 2 32 sync 3 - ' '$T/cmd.log' && grep -q 'parity of the whole array recomputed' '$S/log'"
dst aaa resync; nr unmount 2>/dev/null >/dev/null
check "RAID 5 stopped while resyncing: mark kept, nothing written" "[ -e '$MK' ] && ! grep -q '^flexraid-sb fail' '$T/cmd.log' && [ \"\$(md5sum '$FR5'/*.img)\" = \"$h\" ]"
rm -f "$MK"; dst AAA idle; nr mount 2>/dev/null >/dev/null; dst ADA idle; : > "$T/cmd.log"; nr unmount 2>/dev/null >/dev/null
check "RAID 5 role 1 failed at stop: recorded on roles 0 and 2, mark removed, role 1 stale and its slot '- -' next time" "grep -q '^flexraid-sb fail $FR5/sda.img:5144608:1048448:0:in_sync $FR5/sdc.img:5144608:1048448:2:in_sync\$' '$T/cmd.log' && grep -q 'role 1 failed, recording it on role 0,2' '$S/log' && [ ! -e '$MK' ] && [ \"\$(frv fr-rw5 A2_REASONS)\" = 'degraded stale_member' ] && frv fr-rw5 A2_TABLE | grep -q 'frl-md2-0 - - - '"
dst AAA idle; : > "$T/cmd.log"; nr mount 2>/dev/null >/dev/null
check "RAID 5 with a stale member: read-only, degraded through the parity" "grep -q '^dmsetup create fr-md2 --readonly --table' '$T/cmd.log' && grep -q 'mount -t ext4 -o ro,noatime /dev/mapper/c-c /c' '$T/cmd.log'"
nr unmount 2>/dev/null >/dev/null
rm -rf "$FR5"; cp -r "$T/flexraid-r5" "$FR5"; h=$(md5sum "$FR5"/*.img); dst AAA idle; : > "$R/proc/mounts"
nr mount 2>/dev/null >/dev/null; dst DDA idle; : > "$T/cmd.log"; nr unmount 2>/dev/null >/dev/null
check "RAID 5, two members failed: not recordable (flexraid-sb refuses), mark 'failed role 0,1', nothing written" "grep -q '^failed role 0,1' '$MK' && [ \"\$(md5sum '$FR5'/*.img)\" = \"$h\" ]"
dst AAA idle; : > "$T/cmd.log"; nr mount 2>/dev/null >/dev/null
check "RAID 5 after an unrecorded failure: read-only (failure_unrecorded)" "grep -q failure_unrecorded '$R/var/run/nas-raid.mode' && grep -q '^dmsetup create fr-md2 --readonly' '$T/cmd.log'"
nr unmount 2>/dev/null >/dev/null; rm -f "$MK"
stub dmsetup 'case "$1" in status) cat "'"$R"'/dmst-$2" 2>/dev/null;; remove) [ "$2" = fr-md2 ] && exit 1;; esac'
nr mount 2>/dev/null >/dev/null; nr unmount 2>/dev/null >/dev/null
check "RAID 5 still in use at the stop (fr-md2 not removed): crash mark kept" "[ -e '$MK' ]"
stub dmsetup 'case "$1" in status) cat "'"$R"'/dmst-$2" 2>/dev/null;; esac'; rm -f "$MK"; : > "$R/proc/mounts"
nr mount 2>/dev/null >/dev/null; dst AAD idle; : > "$T/cmd.log"
printf '/dev/mapper/c-c /c ext4 rw 0 0\n/dev/mapper/d-d /d ext4 rw 0 0\n' > "$R/proc/mounts"; nr watch 2>/dev/null >/dev/null
check "watch: RAID 5 role 2 failed while writing: recorded on roles 0 and 1, volumes remounted, c read-only" "grep -q '^flexraid-sb fail $FR5/sda.img:5144608:1048448:0:in_sync $FR5/sdb.img:5144608:1048448:1:in_sync\$' '$T/cmd.log' && grep -q '^umount /c' '$T/cmd.log' && grep -q '^dmsetup create fr-md2 --readonly' '$T/cmd.log'"
dst AAA idle; nr unmount 2>/dev/null >/dev/null; : > "$R/proc/mounts"; rm -f "$MK"; stub dmsetup
stub umount; : > "$R/proc/mounts"; rm -f "$MK" "$R/bin/flexraid-sb"; mdstat '[UU]'
cp "$T/nrconf.bak" "$R/etc/nas-raid.conf"
stub lvm 'case "$1" in lvs) printf "  c c owi-a-----\n  c snap swi-a-s---\n  d d -wi-a-----\n";; pvs) printf "  /dev/mapper/fr-md2 c\n  /dev/mapper/fr-md3 d\n";; esac'
# on the NAS next to its own volume (on-618.sh): test VG names, mounted under NAS_RAID_MNT
stub lvm 'case "$1" in lvs) printf "  rbc rbc -wi-a-----\n  rbd rbd -wi-a-----\n";; pvs) printf "  /dev/mapper/fr-md2 rbc\n  /dev/mapper/fr-md3 rbd\n";; esac'
DISKS="$T/flexraid/sda.img $T/flexraid/sdb.img"; : > "$T/cmd.log"
NAS_RAID_MNT=$T/mnt NAS_RAID_VG_PATTERN='rb[a-z]' NAS_RAID_RUN=$T/run618 nr mount 2>/dev/null >/dev/null
check "NAS_RAID_MNT + NAS_RAID_VG_PATTERN: rbc, rbd mounted under the test folder, own run dir, /c untouched" "grep -q 'mount -t ext4 -o ro,noatime /dev/mapper/rbc-rbc $T/mnt/rbc' '$T/cmd.log' && grep -q 'mount -t ext4 -o ro,noatime /dev/mapper/rbd-rbd $T/mnt/rbd' '$T/cmd.log' && ! grep -q ' /c\$\| /d\$' '$T/cmd.log' && grep -q '^flexraid-ro' '$T/run618/nas-raid.mode'"
NAS_RAID_MNT=$T/mnt NAS_RAID_VG_PATTERN='rb[a-z]' NAS_RAID_RUN=$T/run618 nr unmount 2>/dev/null >/dev/null
: > "$T/cmd.log"; NAS_RAID_VG_PATTERN='rb[a-z]' nr mount > /dev/null 2>&1; rc=$?
check "NAS_RAID_VG_PATTERN without NAS_RAID_MNT: refused before anything (never a test volume at the root)" "[ $rc = 2 ] && [ ! -s '$T/cmd.log' ]"
stub lvm 'case "$1" in lvs) printf "  c c owi-a-----\n  c snap swi-a-s---\n  d d -wi-a-----\n";; pvs) printf "  /dev/mapper/fr-md2 c\n  /dev/mapper/fr-md3 d\n";; esac'
# disks reinstalled by RAIDiator in md mode keep the X-RAID superblock of an earlier
# install at their end: Flex-RAID must win, even with XRAID_RW=yes (set above)
DISKS="$T/flexraid-oldxraid/sda.img $T/flexraid-oldxraid/sdb.img"; h=$(md5sum "$T"/flexraid-oldxraid/*.img); : > "$T/cmd.log"
nr mount 2>/dev/null >/dev/null
check "leftover X-RAID superblock on Flex-RAID disks: Flex-RAID wins, read-only, nothing written" "grep -qx XRAID_RW=yes '$R/etc/nas-raid.conf' && [ \"\$(mode_of)\" = flexraid-ro ] && ! grep -q '^mdadm\\|^xraid-sb\\|xr-p' '$T/cmd.log' && [ \"\$(md5sum '$T'/flexraid-oldxraid/*.img)\" = \"$h\" ] && grep -q 'X-RAID superblock of an earlier install ignored' '$R/var/lib/nas-raid/log'"
nr unmount 2>/dev/null >/dev/null
stub lvm; DISKS="$T/flexraid/sda.img $T/flexraid/sdb.img"; : > "$T/cmd.log"; nr mount 2>/dev/null >/dev/null
check "Flex-RAID without any LV: nothing mounted, everything undone" "grep -q '^none flexraid_failed' '$R/var/run/nas-raid.mode' && [ \$(grep -c '^dmsetup remove fr-md' '$T/cmd.log') = 4 ] && [ ! -e '$R/var/run/flexraid.state' ]"
nr unmount 2>/dev/null >/dev/null
DISKS="$T/clean/sda.img $T/clean/sdb.img"; : > "$T/cmd.log"; nr mount 2>/dev/null >/dev/null
check "X-RAID present: no Flex-RAID array mapped, its status cached anyway (empty)" "mode_of | grep -q '^xraid-' && ! grep -q 'fr-md' '$T/cmd.log' && [ \"\$(cat '$R/var/run/flexraid.json')\" = '{\"arrays\":[]}' ]"
nr unmount 2>/dev/null >/dev/null

# ---------- md: disabled for now ----------
DISKS="$T/big/sda.img $T/big/sdb.img"
for op in migrate create add grow; do
	h=$(stat -c %Y.%s "$T"/big/*.img); : > "$T/cmd.log"
	nr $op "$T/big/sda.img" --confirm x --yes > "$T/d-$op" 2>&1; rc=$?
	check "md disabled: $op refused, nothing run" "[ $rc != 0 ] && grep -q 'md support is disabled for now: X-RAID only' '$T/d-$op' && grep -q WGam '$T/d-$op' && [ ! -s '$T/cmd.log' ] && [ \"\$(stat -c %Y.%s '$T'/big/*.img)\" = \"$h\" ]"
done
check "md disabled: --i-know-relay-will-break no longer exists" "! nr migrate --i-know-relay-will-break 2>&1 | grep -q 'md support'"

# ---------- state left by the earlier (French) version ----------
S=$R/var/lib/nas-raid
printf 'etape=copier\na=/dev/sdb\nb=/dev/sda\n' > "$S/migration"; echo 1 > "$S/xraid-sale"; echo "en_cours 5" > "$S/verif.etat"
nr status > /dev/null 2>&1
check "old state files: dirty mark, migration step and verification state converted" "[ -e '$S/xraid-dirty' ] && [ ! -e '$S/xraid-sale' ] && grep -qx 'step=copy' '$S/migration' && grep -qx 'running 5' '$S/verify.state' && [ ! -e '$S/verif.etat' ]"

echo "$N tests, $FAILS failure(s); files in $T"
[ $FAILS -eq 0 ] && rm -rf "$T"
exit $FAILS
