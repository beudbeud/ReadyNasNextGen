#!/bin/sh
# xraid-compat tests on a PC, without the NAS nor root: fake X-RAID disk
# images (sparse files, make-images.py), xraid-info built for the host,
# nas-raid with simulated dmsetup/mdadm/lvm/fuse2fs/mount (they record their
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
for s in clean big dirty degraded sync different md; do
	python3 "$HERE/make-images.py" "$T/$s" "$s" > /dev/null || exit 1
done

# ---------- image ----------
# /c must be empty in the image: a file there makes fuse2fs refuse the mount
# ("fuse: if you are sure this is safe, use the 'nonempty' mount option")
check "overlay: nothing inside /c" "[ ! -e '$HERE/../../../board/readynas-duo-v1/rootfs-overlay/c' ] || [ -z \"\$(ls -A '$HERE/../../../board/readynas-duo-v1/rootfs-overlay/c')\" ]"

# ---------- xraid-info ----------
mode() { "$R/bin/xraid-info" --samples 32 "$T/$1"/*.img | sed -n "s/^XR_MODE='\(.*\)'/\1/p"; }
for c in clean:rw big:rw dirty:ro degraded:ro sync:ro different:ro md:ro; do
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
"$R/bin/xraid-info" verify "$T"/clean/sdb.img "$T"/clean/sda.img > "$T/v1" 2>/dev/null; rc=$?
check "verify: identical images -> code 0" "[ $rc = 0 ] && grep -q \"RESULT='identical'\" '$T/v1'"
"$R/bin/xraid-info" verify "$T"/different/sdb.img "$T"/different/sda.img > "$T/v2" 2>/dev/null; rc=$?
check "verify: one difference -> code 1, one zone" "[ $rc = 1 ] && grep -q 'DIFFERENT_ZONES=1' '$T/v2'"
check "xraid-info opens nothing for writing (O_RDONLY only)" "! grep -q 'O_RDWR\|O_WRONLY' '$SRC/xraid-info.c'"
check "smart: clean refusal on an image (no SG_IO)" "! '$R/bin/xraid-info' smart '$T/clean/sda.img' 2>/dev/null"

# ---------- nas-raid with simulated commands ----------
stub() { printf '#!/bin/sh\necho "%s $*" >> "%s/cmd.log"\n%s\n' "$1" "$T" "${2:-}" > "$R/bin/$1"; chmod 755 "$R/bin/$1"; }
for c in dmsetup lvm fuse2fs umount rsync partprobe logger mkfs.ext4 resize2fs; do stub $c; done
stub mdadm
stub mount 'echo "/dev/x $3 ext4 rw 0 0" >> "'"$R"'/proc/mounts"'
: > "$R/proc/mounts"
printf 'Personalities : [raid1]\nmd11 : active raid1 dm-3[1] dm-2[0]\n      100 blocks [2/2] [UU]\n' > "$R/proc/mdstat"
export NAS_RAID_ROOT=$R
nr0() { NAS_RAID_DISKS="$DISKS" $SH "$SRC/nas-raid" "$@"; }
DISKS="$T/big/sda.img $T/big/sdb.img"; : > "$T/cmd.log"; nr0 mount 2>/dev/null >/dev/null
check "XRAID_RW=no (default): read-only even when healthy" "grep -q 'xraid-ro rw_disabled' '$R/var/run/nas-raid.mode' && ! grep -q mdadm '$T/cmd.log'"
nr0 unmount 2>/dev/null >/dev/null
echo XRAID_RW=yes > "$R/etc/nas-raid.conf"
nr() { NAS_RAID_DISKS="$DISKS" $SH "$SRC/nas-raid" "$@"; }
mode_of() { cut -d' ' -f1 "$R/var/run/nas-raid.mode"; }
# every dm table on an image must end before V (protected zone untouched)
within_v() {
	awk -v v="$1" '/^dmsetup create/ { for (i = 1; i <= NF; i++) if ($i == "linear" && $(i+1) ~ /\.img$/) { gsub(/'"'"'/, "", $(i+2)); if ($(i+2) + $(i-1) > v) bad = 1 } } END { exit bad }' "$T/cmd.log"
}

DISKS="$T/big/sda.img $T/big/sdb.img"
: > "$T/cmd.log"; nr mount 2>/dev/null >/dev/null
check "mount (clean): xraid-rw" "[ \"\$(mode_of)\" = xraid-rw ]"
check "mount: mdadm --build RAID 1 without superblock, base first" "grep -q 'mdadm --build /dev/md11 --level=1 --raid-devices=2 --assume-clean /dev/mapper/xr-a-s1 /dev/mapper/xr-b-s1' '$T/cmd.log'"
check "mount: p5 mapped onto md11 at 512008" "grep -q \"dmsetup create xr-p5 --table 0 1460504296 linear /dev/md11 512008\" '$T/cmd.log'"
check "mount: no table beyond V" "within_v 1465128688"
check "mount: LVM metadata read-only, fuse2fs rw" "grep -q 'metadata_read_only = 1' '$T/cmd.log' && grep -q 'fuse2fs -o allow_other /dev/mapper/c-c /c' '$T/cmd.log'"
check "mount: xraid-dirty mark set" "[ -e '$R/var/lib/nas-raid/xraid-dirty' ]"
check "mount: never a direct write (dd)" "! grep -q '^dd' '$T/cmd.log'"
echo "/dev/mapper/c-c /c fuse rw 0 0" > "$R/proc/mounts"
nr unmount 2>/dev/null >/dev/null
check "unmount: md stopped, mark removed" "grep -q 'mdadm --stop /dev/md11' '$T/cmd.log' && [ ! -e '$R/var/lib/nas-raid/xraid-dirty' ]"
# power loss under Linux: the mark stays
echo 1 > "$R/var/lib/nas-raid/xraid-dirty"; : > "$T/cmd.log"
nr mount 2>/dev/null >/dev/null
check "after power loss: read-only (unclean_shutdown_linux)" "grep -q 'xraid-ro unclean_shutdown_linux' '$R/var/run/nas-raid.mode'"
check "read-only: dm --readonly on the base, LVM read_only_volume_list, fuse2fs ro" "grep -q 'dmsetup create xr-p5 --readonly --table 0 1460504296 linear .*big/sdb.img 4608040' '$T/cmd.log' && grep -q 'read_only_volume_list' '$T/cmd.log' && grep -q 'fuse2fs -o ro,allow_other' '$T/cmd.log'"
check "read-only: no md" "! grep -q 'mdadm' '$T/cmd.log'"
DISKS="$T/clean/sda.img $T/clean/sdb.img"
nr verify 2>/dev/null
check "verify (clean): mark removed after full comparison" "[ ! -e '$R/var/lib/nas-raid/xraid-dirty' ] && grep -q '^ok ' '$R/var/lib/nas-raid/verify.state'"
# X-RAID shut down uncleanly under RAIDiator: ro, then rw after a successful verification
DISKS="$T/dirty/sda.img $T/dirty/sdb.img"; rm -f "$R/var/lib/nas-raid/xraid-verified"
nr mount 2>/dev/null >/dev/null
check "dirty superblock: read-only" "grep -q 'xraid-ro unclean_shutdown' '$R/var/run/nas-raid.mode'"
nr verify 2>/dev/null; nr mount 2>/dev/null >/dev/null
check "verified dirty superblock: rw (unclean_shutdown_verified)" "grep -q 'xraid-rw unclean_shutdown_verified' '$R/var/run/nas-raid.mode'"
rm -f "$R/var/lib/nas-raid/xraid-dirty"
DISKS="$T/degraded/sdb.img"; : > "$T/cmd.log"
nr mount 2>/dev/null >/dev/null
check "degraded: read-only on the present disk" "grep -q 'xraid-ro missing_disk' '$R/var/run/nas-raid.mode' && ! grep -q mdadm '$T/cmd.log'"
DISKS="$T/different/sda.img $T/different/sdb.img"
nr mount 2>/dev/null >/dev/null
check "different mirror: read-only" "grep -q 'xraid-ro mirror_differs' '$R/var/run/nas-raid.mode'"
nr repair 2>/dev/null >/dev/null; rc=$?
check "repair: refused without confirmation" "[ $rc != 0 ]"
DISKS="$T/sync/sda.img $T/sync/sdb.img"
nr mount 2>/dev/null >/dev/null
check "unfinished synchronisation: read-only" "grep -q 'xraid-ro sync_in_progress' '$R/var/run/nas-raid.mode'"

# ---------- migration and md ----------
DISKS="$T/big/sda.img $T/big/sdb.img"; rm -f "$R/var/lib/nas-raid/verify.state"
: > "$T/cmd.log"; nr migrate --confirm MIGRATE --yes > "$T/m0" 2>&1; rc=$?
check "migrate: refused without full verification" "[ $rc != 0 ] && grep -q 'full verification' '$T/m0' && [ ! -s '$T/cmd.log' ]"
echo "ok $(date +%s)" > "$R/var/lib/nas-raid/verify.state"
nr migrate --confirm MIGRATE --yes > "$T/m1" 2>&1; rc=$?
check "migrate: refused if SMART unreadable" "[ $rc != 0 ] && grep -q 'SMART unreadable' '$T/m1' && [ ! -s '$T/cmd.log' ]"
echo "health=PASSED realloc=0 pending=3 uncorr=0 hours=1" > "$R/var/run/smart.sdb.img"
echo "health=PASSED realloc=0 pending=0 uncorr=0 hours=1" > "$R/var/run/smart.sda.img"
nr migrate --confirm MIGRATE --yes > "$T/m2" 2>&1; rc=$?
check "migrate: refused if sectors are pending" "[ $rc != 0 ] && grep -q 'pending reallocation' '$T/m2'"
echo "health=PASSED realloc=0 pending=0 uncorr=0 hours=1" > "$R/var/run/smart.sdb.img"
nr migrate --yes > "$T/m3" 2>&1; rc=$?
check "migrate: refused without the confirmation phrase" "[ $rc != 0 ] && grep -q \"confirmation required: --confirm 'MIGRATE' --yes\" '$T/m3' && [ ! -s '$T/cmd.log' ]"
before=$(ls -l --time-style=+%s "$T"/big/*.img | md5sum)
nr migrate --dry-run > "$T/m4" 2>&1; rc=$?
check "migrate dry run: succeeds without running anything" "[ $rc = 0 ] && [ ! -s '$T/cmd.log' ] && [ \"\$(ls -l --time-style=+%s '$T'/big/*.img | md5sum)\" = '$before' ] && [ ! -e '$R/var/lib/nas-raid/migration' ]"
check "migrate dry run: erases mirror sda, degraded md, ext4 4 KiB" "grep -q '^+ dd if=/dev/zero of=.*big/sda.img bs=512 seek=1465145072 count=4096' '$T/m4' && grep -q 'mdadm --create /dev/md/donnees .*sda.img missing' '$T/m4' && grep -q 'mkfs.ext4 -b 4096' '$T/m4'"
check "migrate dry run: copy from the read-only X-RAID on sdb" "grep -q 'xr-p5 --readonly .*big/sdb.img 4608040' '$T/m4' && grep -q 'rsync -aH --numeric-ids --delete /c/ /mnt/md/' '$T/m4'"
check "migrate dry run: never erases the base before --finalize" "! grep -q 'of=.*big/sdb.img' '$T/m4'"
nr migrate --finalize --dry-run > "$T/m5" 2>&1
check "finalize dry run: erases sdb then adds it to the md" "grep -q 'of=.*big/sdb.img bs=1048576' '$T/m5' && grep -q 'mdadm /dev/md/donnees --add .*big/sdb.img' '$T/m5'"
nr create "$T/big/sda.img" "$T/big/sdb.img" --dry-run > "$T/c1" 2>&1
check "create dry run: RAID 1 on both disks" "grep -q 'mdadm --create /dev/md/donnees .*sda.img .*sdb.img$' '$T/c1'"
nr create /dev/sdz --confirm 'ERASE sdz' --yes > "$T/c2" 2>&1; rc=$?
check "create: refuses a disk that is not SATA" "[ $rc != 0 ] && grep -q 'is not a SATA disk' '$T/c2'"
nr grow --dry-run > "$T/g1" 2>&1
check "grow dry run: md, pvresize, lvextend, resize2fs" "grep -q 'mdadm --grow /dev/md/donnees --size=max' '$T/g1' && grep -q 'pvresize' '$T/g1' && grep -q 'resize2fs /dev/mapper/donnees-c' '$T/g1'"
DISKS="$T/md/sda.img $T/md/sdb.img"; : > "$T/cmd.log"
nr mount 2>/dev/null >/dev/null
check "md disk (already migrated): md assembly and ext4 on /c" "[ \"\$(mode_of)\" = md ] && grep -q 'mdadm --assemble --scan' '$T/cmd.log' && grep -q 'mount -t ext4 /dev/mapper/donnees-c /c' '$T/cmd.log'"
nr status --json --refresh > "$T/e1"
check "status --json: valid, mode md" "python3 -c \"import json; j=json.load(open('$T/e1')); assert j['mode']=='md' and j['xraid']['mode']=='ro'\""

# ---------- state left by the earlier (French) version ----------
S=$R/var/lib/nas-raid
printf 'etape=copier\na=/dev/sdb\nb=/dev/sda\n' > "$S/migration"; echo 1 > "$S/xraid-sale"; echo "en_cours 5" > "$S/verif.etat"
nr status > /dev/null 2>&1
check "old state files: dirty mark, migration step and verification state converted" "[ -e '$S/xraid-dirty' ] && [ ! -e '$S/xraid-sale' ] && grep -qx 'step=copy' '$S/migration' && grep -qx 'running 5' '$S/verify.state' && [ ! -e '$S/verif.etat' ]"

echo "$N tests, $FAILS failure(s); files in $T"
[ $FAILS -eq 0 ] && rm -rf "$T"
exit $FAILS
