#!/bin/sh
# X-RAID resync after an unclean stop, end to end under Linux 6.18, on a small
# X-RAID made on the test USB key (mkxraid-key.py): two fake disks of
# 1.5 GiB, raw areas of the key after its partitions (base at 4 GiB, mirror
# right after). The test X-RAID uses the same names as the NAS's own (md10,
# md11, xr-*, VG c, /c): the NAS's /c is taken offline for the test (its
# services stopped, a clean "nas-raid unmount") and mounted again at the end,
# whatever happens. The test nas-raid has its own state, settings and log.
#
#   sh on-618-xraid.sh BIN_DIR KEY WORK_DIR BLOCKS_DIR
#
# BIN_DIR: nas-raid, xraid-info, xraid-sb (SPARC build) of this version.
# KEY: the test USB key (e.g. /dev/sdc). BLOCKS_DIR: mkxraid-key.py's output
# for 3145728 sectors. WORK_DIR: an empty folder.
#   A. the fake X-RAID made: blocks written, LVM and ext3 on the base, the
#      sections copied base -> mirror; mounted read-write, a file written
#   B. a crash replayed (md stopped without the clean stop, superblock left
#      "in use", 64 KiB of the mirror altered): the next mount is read-write
#      with the mirror resynchronised from the base; at the stop the legs are
#      identical and the superblock clean; then an ordinary rw mount
#   C. another crash, the resync slowed down, the base failed during it:
#      nothing recorded on the mirror, read-only (resync_base_failed)
set -u
B=$1; KEY=$2; W=$3; BL=$4
LOG=$W/xraid.log
OK=0; KO=0
say() { echo "$*"; echo "$*" >> "$LOG"; }
check() { d=$1; shift; if "$@" >> "$LOG" 2>&1; then OK=$((OK + 1)); say "ok   $d"; else KO=$((KO + 1)); say "FAIL $d"; fi; }
[ -d "$W" ] && [ -z "$(ls -A "$W" 2>/dev/null)" ] || { echo "$W missing or not empty: refusing"; exit 1; }
[ -r "$BL/layout" ] || { echo "$BL/layout missing"; exit 1; }
. "$BL/layout"
[ "$N" = 3145728 ] || { echo "blocks made for $N sectors, not 3145728"; exit 1; }
k=${KEY##*/}
case "$(readlink -f /sys/block/$k/device)" in *usb*) ;; *) echo "$KEY is not a USB disk: refusing"; exit 1;; esac
if grep -q "^$KEY" /proc/mounts; then echo "a partition of $KEY is mounted: refusing"; exit 1; fi
BASE0=8388608; MIRROR0=$((BASE0 + N))		# 4 GiB, then right after
end=0; for p in /sys/block/$k/$k[0-9]*; do e=$(( $(cat $p/start) + $(cat $p/size) )); [ $e -gt $end ] && end=$e; done
[ $end -le $BASE0 ] && [ $((MIRROR0 + N)) -le "$(cat /sys/block/$k/size)" ] || { echo "$KEY: partitions end at $end, the fake disks would overlap: refusing"; exit 1; }
if dmsetup ls 2>/dev/null | grep -q '^rbx-'; then echo "rbx-* dm devices exist: refusing"; exit 1; fi
read -r REALMODE _ < /var/run/nas-raid.mode
case $REALMODE in xraid-rw|xraid-ro) ;; *) echo "the NAS's own volume is not an X-RAID ($REALMODE): refusing"; exit 1;; esac
: > "$LOG"; mkdir -p "$W/run" "$W/state"
SVC="S51webdav S61rsyncd S60minidlnad S60nfs S70ksmbd"
SPEED=$(cat /proc/sys/dev/raid/speed_limit_max)
XR="xr-p1 xr-p2 xr-p5 xr-a-s0 xr-b-s0 xr-a-s1 xr-b-s1"
LVX='devices { filter = [ "a|^/dev/mapper/xr-p|", "r|.*|" ] use_devicesfile = 0 }'

# the test X-RAID torn down without its clean stop, as a crash leaves it
crash() {
	umount /c 2>/dev/null; lvm vgchange -an --config "$LVX" c >/dev/null 2>&1
	for d in xr-p1 xr-p2 xr-p5; do dmsetup remove $d 2>/dev/null; done
	for m in md10 md11; do mdadm --stop /dev/$m >/dev/null 2>&1; done
	for d in xr-a-s0 xr-b-s0 xr-a-s1 xr-b-s1; do dmsetup remove $d 2>/dev/null; done
	rm -f "$W/run/nas-raid.mode"
}
restore() {
	echo "$SPEED" > /proc/sys/dev/raid/speed_limit_max
	for s in $SVC; do /etc/init.d/$s stop >> "$LOG" 2>&1; done	# the test watch starts them
	[ -n "${NR:-}" ] && $NR unmount >> "$LOG" 2>&1
	crash
	for d in rbx-p5 rbx-base rbx-mirror; do dmsetup remove $d 2>/dev/null; done
	if [ -n "${REAL_OFF:-}" ]; then
		( unset NAS_RAID_BIN NAS_RAID_RUN NAS_RAID_STATE NAS_RAID_CONF NAS_RAID_DISKS; nas-raid mount ) >> "$LOG" 2>&1
		for s in S70ksmbd S60nfs S60minidlnad S61rsyncd S51webdav; do /etc/init.d/$s start >> "$LOG" 2>&1; done
		read -r m _ < /var/run/nas-raid.mode; say "the NAS's own volume mounted again: $m"
		REAL_OFF=
	fi
}
trap restore EXIT

# the NAS's own /c offline
for s in $SVC; do /etc/init.d/$s stop >> "$LOG" 2>&1; done
REAL_OFF=1
( unset NAS_RAID_BIN NAS_RAID_RUN NAS_RAID_STATE NAS_RAID_CONF NAS_RAID_DISKS; nas-raid unmount ) >> "$LOG" 2>&1
check "the NAS's own /c offline (unmounted, md10/md11 stopped)" sh -c "! grep -q ' /c ' /proc/mounts && ! grep -q '^md1[01] ' /proc/mdstat"
grep -q ' /c ' /proc/mounts && exit 1

# A. the fake X-RAID
printf '0 %s linear %s %s\n' $N "$KEY" $BASE0 | dmsetup create rbx-base
printf '0 %s linear %s %s\n' $N "$KEY" $MIRROR0 | dmsetup create rbx-mirror
for f in "$BL"/base_*.bin; do l=${f##*/base_}; dd if="$f" of=/dev/mapper/rbx-base bs=512 seek=${l%.bin} conv=notrunc 2>/dev/null; done
for f in "$BL"/mirror_*.bin; do l=${f##*/mirror_}; dd if="$f" of=/dev/mapper/rbx-mirror bs=512 seek=${l%.bin} conv=notrunc 2>/dev/null; done
sync	# xraid-sb reads with O_DIRECT: everything on the key first
# LVM and ext3 on the base's p5 (PV from P5 + 8, as the EBR says)
printf '0 %s linear /dev/mapper/rbx-base %s\n' $((DATA - 8)) $((P5 + 8)) | dmsetup create rbx-p5
LVP='devices { filter = [ "a|^/dev/mapper/rbx-p5$|", "r|.*|" ] use_devicesfile = 0 }'
{ lvm pvcreate -ff -y --config "$LVP" /dev/mapper/rbx-p5 && lvm vgcreate -s 4M --config "$LVP" c /dev/mapper/rbx-p5 &&
  lvm lvcreate -y -l 100%FREE -n c --config "$LVP" c && mke2fs -q -F -t ext3 -b 16384 -m 0 -L c /dev/mapper/c-c &&
  mkdir -p "$W/fs" && mount -t ext4 /dev/mapper/c-c "$W/fs" && echo "volume c of the test X-RAID" > "$W/fs/hello.txt" &&
  umount "$W/fs" && lvm vgchange -an --config "$LVP" c; } >> "$LOG" 2>&1
dmsetup remove rbx-p5
# sections base -> mirror (sector 32 to V; the superblocks, past V, stay each disk's own)
dd if=/dev/mapper/rbx-base of=/dev/mapper/rbx-mirror bs=16384 skip=1 seek=1 count=$((V / 32 - 1)) conv=notrunc 2>> "$LOG"
sync; echo 3 > /proc/sys/vm/drop_caches
check "fake X-RAID read by xraid-info: rw, no reason" sh -c "$B/xraid-info /dev/mapper/rbx-base /dev/mapper/rbx-mirror | grep -qx \"XR_MODE='rw'\" && $B/xraid-info /dev/mapper/rbx-base /dev/mapper/rbx-mirror | grep -qx \"XR_REASONS=''\""

export NAS_RAID_BIN=$B NAS_RAID_RUN=$W/run NAS_RAID_STATE=$W/state NAS_RAID_CONF=$W/nas-raid.conf
export NAS_RAID_DISKS="/dev/mapper/rbx-base /dev/mapper/rbx-mirror"
NR="sh $B/nas-raid"
echo XRAID_RW=yes > "$W/nas-raid.conf"
sbsum() { $B/xraid-info /dev/mapper/rbx-base /dev/mapper/rbx-mirror | sed -n "s/^XR_REASONS='\(.*\)'/\1/p"; }
legs() { for d in rbx-base rbx-mirror; do sync; echo 3 > /proc/sys/vm/drop_caches; dd if=/dev/mapper/$d bs=16384 skip=1 count=$((V / 32 - 1)) 2>/dev/null | sha256sum | cut -d' ' -f1; done | uniq | wc -l; }
$NR mount >> "$LOG" 2>&1
read -r mode why < "$W/run/nas-raid.mode"
check "test X-RAID mounted read-write (got: $mode${why:+ $why})" sh -c "[ '$mode' = xraid-rw ] && [ -z '$why' ] && grep -q 'mdadm --build /dev/md11 --level=1 --raid-devices=2 --assume-clean' '$W/state/log'"
dd if=/dev/urandom of=/c/before-crash.bin bs=1048576 count=8 2>/dev/null; sync
sha256sum < /c/before-crash.bin | cut -d' ' -f1 > "$W/before-crash.sha256"

# B. a crash, the mirror altered (64 KiB at 1 GiB in section 1), then the resync
crash
dd if=/dev/urandom of=/dev/mapper/rbx-mirror bs=65536 seek=16384 count=1 conv=notrunc 2>/dev/null; sync
r=$(sbsum); l=$(legs)
check "after the crash: superblock in use, the legs differ ($r; $l)" sh -c "echo '$r' | grep -q unclean_shutdown && [ '$l' = 2 ]"
$NR mount >> "$LOG" 2>&1
read -r mode why < "$W/run/nas-raid.mode"
check "next mount: read-write, the mirror resynchronised from the base (got: $mode${why:+ $why})" sh -c "[ '$mode' = xraid-rw ] && [ '$why' = resync_after_unclean_stop ] && [ -e '$W/state/xraid-resync' ] && grep -q 'mdadm --build /dev/md11 --level=1 --raid-devices=2 /dev/mapper/xr-a-s1' '$W/state/log'"
check "during the resync: the file written before the crash read back, same sha256" sh -c "[ \"\$(sha256sum < /c/before-crash.bin | cut -d' ' -f1)\" = \"\$(cat '$W/before-crash.sha256')\" ]"
n=0; while grep -q 'resync' /proc/mdstat && [ $n -lt 1200 ]; do sleep 2; n=$((n + 2)); done
check "resync over in $n s ([UU] both)" sh -c "! grep -q resync /proc/mdstat && [ \$(grep -c '\[UU\]' /proc/mdstat) -ge 2 ]"
echo "written after the resync" > /c/after.txt; sync
$NR unmount >> "$LOG" 2>&1
r=$(sbsum)
check "clean stop after the resync: superblock clean, both marks removed (reasons: ${r:-none})" sh -c "[ -z '$r' ] && [ ! -e '$W/state/xraid-dirty' ] && [ ! -e '$W/state/xraid-resync' ]"
check "the two legs identical (sections)" test "$(legs)" = 1
$NR mount >> "$LOG" 2>&1
read -r mode why < "$W/run/nas-raid.mode"
check "then an ordinary read-write mount, the files there" sh -c "[ '$mode' = xraid-rw ] && [ -z '$why' ] && grep -q '^written after the resync' /c/after.txt && grep -q '^volume c of the test' /c/hello.txt"

# C. another crash; the base fails during the resync
crash
echo 200 > /proc/sys/dev/raid/speed_limit_max	# KiB/s: the resync lasts
$NR mount >> "$LOG" 2>&1
sleep 3
check "resync running again" grep -q 'resync' /proc/mdstat
echo faulty > /sys/block/md11/md/rd0/state 2>> "$LOG"		# rd0 = xr-a-s1, the base
check "the base failed for md (md11 [_U])" sh -c "grep -A1 '^md11 :' /proc/mdstat | grep -q '\[_U\]'"
: > "$W/state/watch.log"
$NR watch >> "$LOG" 2>&1
echo "$SPEED" > /proc/sys/dev/raid/speed_limit_max
read -r mode why < "$W/run/nas-raid.mode"
check "watch: nothing recorded on the incomplete mirror, read-only (got: $mode${why:+ $why})" sh -c "grep -q 'base failed during the resync' '$W/state/log' && ! grep -q 'xraid-sb fail' '$W/state/log' && [ '$mode' = xraid-ro ] && echo '$why' | grep -q resync_base_failed"
r=$(sbsum)
check "no failure written on the superblocks (reasons: $r)" sh -c "! echo '$r' | grep -q degraded"
$NR unmount >> "$LOG" 2>&1
restore; trap - EXIT
check "the NAS's own /c back" grep -q ' /c ' /proc/mounts
say "$OK ok, $KO failed (log: $LOG)"
[ "$KO" = 0 ]
