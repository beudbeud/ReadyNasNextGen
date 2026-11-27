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
# writing, the stop records it on role 0 (flexraid-sb fail). PHASE=r5: on-nas.sh
# r5key's RAID 5 of 4 members (KEY5-8, RAIDiator's) read through dm-raid, read
# only, whole then with KEY8 unreadable (degraded: read through the parity),
# nothing on the key written (R5_SHA = its r5-random.sha256). PHASE=r5w: the
# same RAID 5 written with FLEXRAID_RW=yes (parity checked by md, superblocks
# unchanged), then 16 KiB of role 3's parity altered: md's check finds it, a
# crash mark makes the next mount recompute the parity, checked again.
# PHASE=r5fail (after RAIDiator checked r5w): role 3's leg turned into a dm
# error target while writing, the stop records it on roles 0-2. The 6.18 kernel
# has no loop driver: the members are partitions of a USB key (type 0xfd,
# sized as the members), each fake disk a dm device made of the key's
# partition 1 (the fake disks' MBR) and two member partitions. RAIDiator's
# kernel then finds the same partitions (on-nas.sh check618: autorun, as at
# its boot).
#
#   [PHASE=write|fail|r5|r5w|r5fail] [R5_SHA=FILE] sh on-618.sh BIN_DIR KEY WORK_DIR
#
# BIN_DIR: nas-raid, xraid-info and flexraid-sb (SPARC build) of this version.
# KEY: the test USB key (e.g. /dev/sdd): KEY1 the fake disks' MBR, KEY5 KEY6
# disk 0's p1 p2, KEY7 KEY8 disk 1's (on-nas.sh's base scenario written there).
# WORK_DIR: an empty folder (state, log, settings, mount points of this test).
# Uses dm devices rb618-disk0/1, fr-md5/6 and frl-md5-*, md105, VGs rbc and
# rbd: never the NAS's disks nor its X-RAID or VG "c".
set -eu
B=$1; KEY=$2; W=$3; PHASE=${PHASE:-write}
case $PHASE in write|fail|r5|r5w|r5fail) ;; *) echo "PHASE: write, fail, r5, r5w or r5fail"; exit 1;; esac
case $PHASE in r5*) [ -r "${R5_SHA:-}" ] || { echo "R5_SHA: on-nas.sh r5key's r5-random.sha256"; exit 1; };; esac
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

if [ "$PHASE" = r5 ]; then
# D. RAID 5 (4 members, made by RAIDiator): dm-raid over read-only legs, nothing written
D0=$(for n in 5 6 7 8; do datasum $KEY$n; done)
$NR mount >> "$LOG" 2>&1 || true
read -r mode reasons < "$W/run/nas-raid.mode" || mode=?
check "RAID 5 mount: mode flexraid-ro, no reason (got: $mode${reasons:+ $reasons})" sh -c "[ '$mode' = flexraid-ro ] && [ -z '$reasons' ]"
check "fr-md5 = dm-raid raid5 with nosync over 4 legs" sh -c "dmsetup table fr-md5 | grep -q ' raid raid5_.. 2 32 nosync 4 - [^ ]* - [^ ]* - [^ ]* - [^ ]*\$'"
check "the 4 legs and fr-md5 read-only" sh -c "for d in frl-md5-0 frl-md5-1 frl-md5-2 frl-md5-3 fr-md5; do dmsetup info \$d | grep -q 'READ-ONLY' || exit 1; done"
cat /proc/mdstat >> "$LOG"; dmsetup status fr-md5 >> "$LOG" 2>&1 || true
check "rbc (RAID 5, made by RAIDiator) read: hello.txt" grep -q '^volume rbc' "$W/mnt/rbc/hello.txt"
check "rbc: r5-random.bin, same sha256 as written by RAIDiator" sh -c "[ \"\$(sha256sum < '$W/mnt/rbc/r5-random.bin' | cut -d' ' -f1)\" = \"\$(cat '$R5_SHA')\" ]"
check "rbc read-only" sh -c "! touch '$W/mnt/rbc/.w' 2>/dev/null"
$NR unmount >> "$LOG" 2>&1
rwmount
check "FLEXRAID_RW=yes: RAID 5 stays read-only (got: $mode${reasons:+ $reasons})" sh -c "[ '$mode' = flexraid-ro ] && ! touch '$W/mnt/rbc/.w' 2>/dev/null"
$NR unmount >> "$LOG" 2>&1; rm -f "$W/nas-raid.conf"
check "unmounted: no fr-md or frl-md device left" sh -c "! dmsetup ls | grep -q '^fr-md\|^frl-md'"
# KEY8 unreadable (dm error target in disk 1's p2): one member missing, read through the parity
dmsetup remove rb618-disk1
printf '0 2048 linear %s 0\n2048 %s linear %s 0\n%s %s error\n' "${KEY}1" $s1 "${KEY}7" $((2048 + s1)) $s2 | dmsetup create rb618-disk1
$NR mount >> "$LOG" 2>&1 || true
read -r mode reasons < "$W/run/nas-raid.mode" || mode=?
check "one member unreadable: mounted degraded (got: $mode${reasons:+ $reasons})" sh -c "[ '$mode' = flexraid-ro ] && [ '$reasons' = degraded ] && dmsetup table fr-md5 | grep -q ' - -\$'"
check "degraded: r5-random.bin, same sha256 (rebuilt from the parity)" sh -c "[ \"\$(sha256sum < '$W/mnt/rbc/r5-random.bin' | cut -d' ' -f1)\" = \"\$(cat '$R5_SHA')\" ]"
$NR unmount >> "$LOG" 2>&1
check "md superblocks of the 4 members unchanged" test "$(sbsum)" = "$SB0"
check "data areas of the 4 members unchanged" test "$(for n in 5 6 7 8; do datasum $KEY$n; done)" = "$D0"
fi

# dm-raid's status: 0 LEN raid TYPE N HEALTH RATIO ACTION MISMATCH ...
r5st() { dmsetup status fr-md5 | cut -d' ' -f"$1"; }
r5idle() { n=0; while [ "$(r5st 8)" != idle ] && [ $n -lt 1800 ]; do sleep 2; n=$((n + 2)); done; }
r5check() { dmsetup message fr-md5 0 check; sleep 2; r5idle; r5st 9; }	# mismatched sectors
r5sha() { [ "$(sha256sum < "$1" | cut -d' ' -f1)" = "$(cat "$2")" ]; }

if [ "$PHASE" = r5w ]; then
# E. RAID 5 written (FLEXRAID_RW=yes), parity checked, then a crash of ours replayed
rwmount
check "RAID 5, FLEXRAID_RW=yes: mode flexraid-rw (got: $mode${reasons:+ $reasons})" test "$mode" = flexraid-rw
check "fr-md5 writable, nosync, crash mark set" sh -c "dmsetup table fr-md5 | grep -q ' raid raid5_la 2 32 nosync 4 ' && ! dmsetup info fr-md5 | grep -q READ-ONLY && [ -e '$W/state/flexraid-dirty-md5' ]"
{
	echo "written on the RAID 5 under Linux 6.18 $(date)" > "$W/mnt/rbc/r5-618.txt"
	dd if=/dev/urandom of="$W/mnt/rbc/r5-618.bin" bs=1048576 count=16 2> /dev/null
	sha256sum < "$W/mnt/rbc/r5-618.bin" | cut -d' ' -f1 > "$W/r5-618.sha256"
	sync
} >> "$LOG" 2>&1 || true
check "rbc (RAID 5) written" test -s "$W/mnt/rbc/r5-618.bin"
mm=$(r5check 2>> "$LOG")
check "md's check after the writes: parity consistent (mismatch $mm)" test "$mm" = 0
$NR unmount >> "$LOG" 2>&1
check "clean stop: no fr-md/frl-md left, crash mark removed" sh -c "! dmsetup ls | grep -q '^fr-md\|^frl-md' && [ ! -e '$W/state/flexraid-dirty-md5' ]"
check "md superblocks of the 4 members unchanged by the writes" test "$(sbsum)" = "$SB0"
# 16 KiB of role 3's parity altered: stripe 100 (left-asymmetric: parity on role 3 - 100 mod 4 = 3), 3200 sectors in
dd if=/dev/urandom of=${KEY}8 bs=512 seek=3200 count=32 conv=notrunc 2>> "$LOG" || true
rwmount
mm=$(r5check 2>> "$LOG")
check "parity altered by hand: md's check finds it (mismatch $mm)" sh -c "[ '$mm' -gt 0 ]"
$NR unmount >> "$LOG" 2>&1
date +%s > "$W/state/flexraid-dirty-md5"
rwmount
check "after a crash (mark left): sync, the parity recomputed" sh -c "grep -q 'parity of the whole array recomputed' '$W/state/log' && dmsetup table fr-md5 | grep -q ' 2 32 sync 4 '"
r5idle
check "resync over ($(r5st 6), $(r5st 8))" sh -c "[ \"\$(dmsetup status fr-md5 | cut -d' ' -f6)\" = AAAA ]"
mm=$(r5check 2>> "$LOG")
check "md's check after the resync: parity consistent again (mismatch $mm)" test "$mm" = 0
$NR unmount >> "$LOG" 2>&1
check "mark removed, md superblocks still unchanged" sh -c "[ ! -e '$W/state/flexraid-dirty-md5' ] && [ \"$(sbsum)\" = \"$SB0\" ]"
romount
check "read-only again: RAIDiator's file and the one written by 6.18, same sha256" sh -c "$(command -v sha256sum) < '$W/mnt/rbc/r5-random.bin' | grep -q \"\$(cat '$R5_SHA')\" && $(command -v sha256sum) < '$W/mnt/rbc/r5-618.bin' | grep -q \"\$(cat '$W/r5-618.sha256')\""
$NR unmount >> "$LOG" 2>&1
fi

if [ "$PHASE" = r5fail ]; then
# F. role 3 fails while the RAID 5 is written: recorded on roles 0-2 at the stop
rwmount
check "RAID 5, FLEXRAID_RW=yes: mode flexraid-rw (got: $mode${reasons:+ $reasons})" test "$mode" = flexraid-rw
n3=$(dmsetup table frl-md5-3 | cut -d' ' -f2)
{ dmsetup suspend frl-md5-3 && echo "0 $n3 error" | dmsetup load frl-md5-3 && dmsetup resume frl-md5-3; } >> "$LOG" 2>&1 || true
{
	echo "written on the RAID 5 after role 3 failed $(date)" > "$W/mnt/rbc/r5-after-fail.txt"
	dd if=/dev/urandom of="$W/mnt/rbc/r5-after-fail.bin" bs=1048576 count=4 2> /dev/null
	sha256sum < "$W/mnt/rbc/r5-after-fail.bin" | cut -d' ' -f1 > "$W/r5-after-fail.sha256"
	sync
} >> "$LOG" 2>&1 || true
check "role 3 dead for md (health $(r5st 6))" sh -c "dmsetup status fr-md5 | cut -d' ' -f6 | grep -q '^AAAD\$'"
$NR unmount >> "$LOG" 2>&1
check "role 3 failed: recorded on roles 0-2 (flexraid-sb fail), mark removed" sh -c "grep -q 'role 3 failed, recording it on role 0,1,2' '$W/state/log' && [ ! -e '$W/state/flexraid-dirty-md5' ]"
check "xraid-info: md5 degraded, role 3 stale" sh -c "$B/xraid-info flexraid $NAS_RAID_DISKS | grep -qx \"FR_A[0-9]*_REASONS='degraded stale_member'\""
romount
check "read-only next time, degraded: the files written after the failure there" sh -c "grep -q '^written on the RAID 5 after role 3' '$W/mnt/rbc/r5-after-fail.txt' && $(command -v sha256sum) < '$W/mnt/rbc/r5-after-fail.bin' | grep -q \"\$(cat '$W/r5-after-fail.sha256')\""
check "rbc read-only (stale member)" sh -c "! touch '$W/mnt/rbc/.w' 2>/dev/null"
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
if [ "$PHASE" = r5 ]; then say "$OK ok, $KO failed (log: $LOG); nothing written on the key"
elif [ "$PHASE" = r5w ] || [ "$PHASE" = r5fail ]; then say "$OK ok, $KO failed (log: $LOG; keep $W/*.sha256); next: boot RAIDiator, PHASE=$PHASE CHECK_DIR=$W sh on-nas.sh TOOLS WORK check5"
else say "$OK ok, $KO failed (log: $LOG; keep $W/*.sha256); next: boot DIET/RAIDiator, PHASE=$PHASE CHECK_DIR=<folder with the .sha256 of the write phase> sh on-nas.sh TOOLS WORK check618"; fi
[ "$KO" = 0 ]
