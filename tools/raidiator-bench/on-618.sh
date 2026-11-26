#!/bin/sh
# End-to-end test of nas-raid on the NAS under Linux 6.18, next to the NAS's
# own volume: the "base" scenario of on-nas.sh (md5 RAID 1 rbc, md6 RAID 0
# rbd, made by RAIDiator's kernel and tools) is mounted by the real nas-raid
# with the real device-mapper, md, LVM 2.03 and ext4, read-only, then with
# FLEXRAID_RW=yes: files are written on both volumes (rbc through a mirror
# without metadata: both legs compared after the stop, the md superblocks
# must not have changed), then a crash of ours replayed (mark left, role 1
# altered: md must resync it from role 0). PHASE=fail, a separate run after
# RAIDiator checked the first one: rbc's role 1 failed by mdadm while
# writing, the stop records it on role 0 (flexraid-sb fail). The 6.18 kernel
# has no loop driver: the members are partitions of a USB key (type 0xfd,
# sized as the members), each fake disk a dm device made of the key's
# partition 1 (the fake disks' MBR) and two member partitions. RAIDiator's
# kernel then finds the same partitions (on-nas.sh check618: autorun, as at
# its boot).
#
#   [PHASE=write|fail] sh on-618.sh BIN_DIR KEY WORK_DIR
#
# BIN_DIR: nas-raid, xraid-info and flexraid-sb (SPARC build) of this version.
# KEY: the test USB key (e.g. /dev/sdd): KEY1 the fake disks' MBR, KEY5 KEY6
# disk 0's p1 p2, KEY7 KEY8 disk 1's (on-nas.sh's base scenario written there).
# WORK_DIR: an empty folder (state, log, settings, mount points of this test).
# Uses dm devices rb618-disk0/1, fr-md5/6 and frl-md5-*, md105, VGs rbc and
# rbd: never the NAS's disks nor its X-RAID or VG "c".
set -eu
B=$1; KEY=$2; W=$3; PHASE=${PHASE:-write}
case $PHASE in write|fail) ;; *) echo "PHASE: write or fail"; exit 1;; esac
LOG=$W/618.log
OK=0; KO=0
say() { echo "$*"; echo "$*" >> "$LOG"; }
check() {	# check "description" command...
	d=$1; shift
	if "$@" >> "$LOG" 2>&1; then OK=$((OK + 1)); say "ok   $d"; else KO=$((KO + 1)); say "FAIL $d"; fi
}
[ -d "$W" ] && [ -z "$(ls -A "$W" 2>/dev/null)" ] || { echo "$W missing or not empty: refusing"; exit 1; }
for n in 1 5 6 7 8; do [ -b "$KEY$n" ] || { echo "$KEY$n missing"; exit 1; }; done
if grep -q "^$KEY" /proc/mounts; then echo "a partition of $KEY is mounted: refusing"; exit 1; fi
sz() { cat "/sys/class/block/${1##*/}/size"; }
[ "$(sz ${KEY}5)" = "$(sz ${KEY}7)" ] && [ "$(sz ${KEY}6)" = "$(sz ${KEY}8)" ] && [ "$(sz ${KEY}1)" -ge 2048 ] \
	|| { echo "$KEY: partitions not laid out as expected: refusing"; exit 1; }
if dmsetup ls 2>/dev/null | grep -q '^rb618-\|^fr-md\|^frl-md'; then echo "rb618-*, fr-md* or frl-md* dm devices exist: refusing"; exit 1; fi
if grep -q '^md105 ' /proc/mdstat 2>/dev/null; then echo "md105 exists: refusing"; exit 1; fi
: > "$LOG"
mkdir -p "$W/run" "$W/state" "$W/mnt"
export NAS_RAID_BIN=$B NAS_RAID_RUN=$W/run NAS_RAID_STATE=$W/state NAS_RAID_CONF=$W/nas-raid.conf
export NAS_RAID_MNT=$W/mnt NAS_RAID_VG_PATTERN='rb[a-z]'
export NAS_RAID_DISKS="/dev/mapper/rb618-disk0 /dev/mapper/rb618-disk1"
NR="sh $B/nas-raid"

cleanup() {
	$NR unmount >> "$LOG" 2>&1 || true
	for d in 0 1; do dmsetup remove "rb618-disk$d" 2> /dev/null || true; done
}
trap cleanup EXIT

# sha256 of the md superblocks of the 4 members, of a member's data area (page
# cache dropped first: what went through dm/md is not in the partitions' cache)
dropc() { sync; echo 3 > /proc/sys/vm/drop_caches; }
sbsum() { dropc; for n in 5 6 7 8; do s=$(sz "$KEY$n"); dd if="$KEY$n" bs=512 skip=$(( (s & ~127) - 128 )) count=8 2>/dev/null | sha256sum; done; }
datasum() { dropc; s=$(sz "$1"); dd if="$1" bs=65536 count=$(( ((s & ~127) - 128) / 128 )) 2>/dev/null | sha256sum | cut -d' ' -f1; }
rwmount() { echo FLEXRAID_RW=yes > "$W/nas-raid.conf"; $NR mount >> "$LOG" 2>&1 || true; read -r mode reasons < "$W/run/nas-raid.mode" || mode=?; }
romount() { rm -f "$W/nas-raid.conf"; $NR mount >> "$LOG" 2>&1 || true; }
SB0=$(sbsum)

# the fake disks: the MBR (KEY1, 2048 sectors), then p1 and p2
s1=$(sz ${KEY}5); s2=$(sz ${KEY}6)
for d in 0 1; do
	a=${KEY}$((5 + 2 * d)); b=${KEY}$((6 + 2 * d))
	printf '0 2048 linear %s 0\n2048 %s linear %s 0\n%s %s linear %s 0\n' "${KEY}1" $s1 "$a" $((2048 + s1)) $s2 "$b" \
		| dmsetup create "rb618-disk$d"
done
say "fake disks: $NAS_RAID_DISKS ($s1 + $s2 sectors of partitions each)"

if [ "$PHASE" = write ]; then
# A. read-only (FLEXRAID_RW unset)
$NR mount >> "$LOG" 2>&1 || true
read -r mode reasons < "$W/run/nas-raid.mode" || mode=?
check "read-only mount: mode flexraid-ro (got: $mode${reasons:+ $reasons})" test "$mode" = flexraid-ro
check "read-only mount: no reason on md5/md6 (members in sync)" test -z "$reasons"
check "rbc (RAID 1, made by RAIDiator) read: hello.txt" grep -q '^volume rbc' "$W/mnt/rbc/hello.txt"
check "rbd (RAID 0, made by RAIDiator) read: hello.txt" grep -q '^volume rbd' "$W/mnt/rbd/hello.txt"
check "rbd read-only" sh -c "! touch '$W/mnt/rbd/.w' 2>/dev/null"
$NR status --json > "$W/status-ro.json" 2>&1 || true
$NR unmount >> "$LOG" 2>&1
check "unmounted: no fr-md device left" sh -c "! dmsetup ls | grep -q '^fr-md'"

# B. FLEXRAID_RW=yes: rbd (RAID 0) and rbc (RAID 1, mirror md105) writable
rwmount
check "FLEXRAID_RW=yes: mode flexraid-rw (got: $mode${reasons:+ $reasons})" test "$mode" = flexraid-rw
check "rbc (RAID 1): mirror md105 built from both members, crash mark set" sh -c "grep -A1 '^md105 :' /proc/mdstat | grep -q '\[UU\]' && [ -e '$W/state/flexraid-dirty-md5' ]"
{
	echo "written under Linux 6.18 by nas-raid $(date)" > "$W/mnt/rbd/from-618.txt"
	dd if=/dev/urandom of="$W/mnt/rbd/random-618.bin" bs=1048576 count=8 2> /dev/null
	sha256sum "$W/mnt/rbd/random-618.bin" | cut -d' ' -f1 > "$W/random-618.sha256"
	echo "written on the mirror under Linux 6.18 $(date)" > "$W/mnt/rbc/rbc-618.txt"
	dd if=/dev/urandom of="$W/mnt/rbc/rbc-random.bin" bs=1048576 count=4 2> /dev/null
	sha256sum "$W/mnt/rbc/rbc-random.bin" | cut -d' ' -f1 > "$W/rbc-random.sha256"
	sync
} >> "$LOG" 2>&1 || true
check "rbd (RAID 0) and rbc (RAID 1) written" test -s "$W/mnt/rbd/random-618.bin" -a -s "$W/mnt/rbc/rbc-random.bin"
check "no resync while writing (--assume-clean)" sh -c "[ \"\$(cat /sys/block/md105/md/sync_action)\" = idle ]"
$NR status --json > "$W/status-rw.json" 2>&1 || true
$NR unmount >> "$LOG" 2>&1
check "clean stop: md105 stopped, frl legs removed, crash mark removed" sh -c "! grep -q '^md105 ' /proc/mdstat && ! dmsetup ls | grep -q '^frl-' && [ ! -e '$W/state/flexraid-dirty-md5' ]"
check "md superblocks of the 4 members unchanged by the writes" test "$(sbsum)" = "$SB0"
check "rbc's two members hold the same data (both legs written)" test "$(datasum ${KEY}5)" = "$(datasum ${KEY}7)"

# B2. a crash of ours: mark left, 64 KiB of role 1 altered (at 4 MiB), md
# must resync role 1 from role 0
D0=$(datasum ${KEY}5)
dd if=/dev/urandom of=${KEY}7 bs=65536 seek=64 count=1 conv=notrunc 2>> "$LOG" || true
check "crash replay: role 1 now differs" test "$(datasum ${KEY}7)" != "$D0"
date +%s > "$W/state/flexraid-dirty-md5"
rwmount
check "after a crash: mirror built without --assume-clean (resync)" grep -q 'role 1 resynchronised from role 0' "$W/state/log"
n=0; while [ "$(cat /sys/block/md105/md/sync_action 2>/dev/null)" != idle ] && [ $n -lt 600 ]; do sleep 1; n=$((n + 1)); done
check "resync finished ($n s)" sh -c "[ \"\$(cat /sys/block/md105/md/sync_action)\" = idle ] && grep -A1 '^md105 :' /proc/mdstat | grep -q '\[UU\]'"
$NR unmount >> "$LOG" 2>&1
# (role 0 itself changed: mounting ext4 read-write writes on it)
check "after the resync: mark removed, role 1 equal to role 0 again" sh -c "[ ! -e '$W/state/flexraid-dirty-md5' ] && [ \"$(datasum ${KEY}5)\" = \"$(datasum ${KEY}7)\" ]"
check "md superblocks still unchanged" test "$(sbsum)" = "$SB0"

# and read back once more, read-only
romount
check "remounted read-only: the files written are there, same sha256" \
	sh -c "grep -q '^written under Linux 6.18' '$W/mnt/rbd/from-618.txt' && [ \"\$(sha256sum < '$W/mnt/rbd/random-618.bin' | cut -d' ' -f1)\" = \"\$(cat '$W/random-618.sha256')\" ] && [ \"\$(sha256sum < '$W/mnt/rbc/rbc-random.bin' | cut -d' ' -f1)\" = \"\$(cat '$W/rbc-random.sha256')\" ]"
$NR unmount >> "$LOG" 2>&1
fi

if [ "$PHASE" = fail ]; then
# C. rbc's role 1 fails while writing: recorded on role 0 at the stop
rwmount
check "FLEXRAID_RW=yes: mode flexraid-rw (got: $mode${reasons:+ $reasons})" test "$mode" = flexraid-rw
# (mdadm --fail answers "No such device" on a --build array: md's sysfs instead)
echo faulty > /sys/block/md105/md/rd1/state 2>> "$LOG" || true	# slot 1 = role 1's leg
check "rbc's role 1 failed by md (md105 [U_])" sh -c "grep -A1 '^md105 :' /proc/mdstat | grep -q '\[U_\]'"
{ echo "written on role 0 alone after role 1 failed $(date)" > "$W/mnt/rbc/rbc-after-fail.txt"; sync; } >> "$LOG" 2>&1 || true
$NR unmount >> "$LOG" 2>&1
check "role 1 failed: recorded on role 0 (flexraid-sb fail), mark removed" sh -c "grep -q 'role 1 failed, recording it on role 0' '$W/state/log' && [ ! -e '$W/state/flexraid-dirty-md5' ]"
check "xraid-info: md5 degraded, role 1 stale" sh -c "$B/xraid-info flexraid $NAS_RAID_DISKS | grep -qx \"FR_A[0-9]*_REASONS='degraded stale_member'\""
romount
check "read-only next time: rbc read from role 0, the file written after the failure there" grep -q '^written on role 0 alone' "$W/mnt/rbc/rbc-after-fail.txt"
check "rbc read-only (stale member)" sh -c "! touch '$W/mnt/rbc/.w' 2>/dev/null"
$NR unmount >> "$LOG" 2>&1
fi
cleanup; trap - EXIT
sync
say "$OK ok, $KO failed (log: $LOG; keep $W/*.sha256); next: boot DIET/RAIDiator, PHASE=$PHASE CHECK_DIR=<folder with the .sha256 of the write phase> sh on-nas.sh TOOLS WORK check618"
[ "$KO" = 0 ]
