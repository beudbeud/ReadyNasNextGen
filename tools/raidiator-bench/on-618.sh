#!/bin/sh
# End-to-end test of nas-raid on the NAS under Linux 6.18, next to the NAS's
# own volume: the "base" scenario of on-nas.sh (md5 RAID 1 rbc, md6 RAID 0
# rbd, made by RAIDiator's kernel and tools) is mounted by the real nas-raid
# with the real device-mapper, LVM 2.03 and ext4, read-only, then with
# FLEXRAID_RW=yes: files are written on the RAID 0 volume. The 6.18 kernel has
# no loop driver: the members are partitions of a USB key (type 0xfd, sized
# as the members), each fake disk a dm device made of the key's partition 1
# (the fake disks' MBR) and two member partitions. RAIDiator's kernel then
# finds the same partitions (on-nas.sh check618: autorun, as at its boot).
#
#   sh on-618.sh BIN_DIR KEY WORK_DIR
#
# BIN_DIR: nas-raid and xraid-info (SPARC build) of this version. KEY: the test
# USB key (e.g. /dev/sdd): KEY1 the fake disks' MBR, KEY5 KEY6 disk 0's p1 p2,
# KEY7 KEY8 disk 1's (on-nas.sh's base scenario written there). WORK_DIR: an
# empty folder (state, log, settings, mount points of this test).
# Uses dm devices rb618-disk0/1 and fr-md5/6, VGs rbc and rbd: never the
# NAS's disks nor its X-RAID or VG "c".
set -eu
B=$1; KEY=$2; W=$3
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
if dmsetup ls 2>/dev/null | grep -q '^rb618-\|^fr-md'; then echo "rb618-* or fr-md* dm devices exist: refusing"; exit 1; fi
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

# the fake disks: the MBR (KEY1, 2048 sectors), then p1 and p2
s1=$(sz ${KEY}5); s2=$(sz ${KEY}6)
for d in 0 1; do
	a=${KEY}$((5 + 2 * d)); b=${KEY}$((6 + 2 * d))
	printf '0 2048 linear %s 0\n2048 %s linear %s 0\n%s %s linear %s 0\n' "${KEY}1" $s1 "$a" $((2048 + s1)) $s2 "$b" \
		| dmsetup create "rb618-disk$d"
done
say "fake disks: $NAS_RAID_DISKS ($s1 + $s2 sectors of partitions each)"

# A. read-only (FLEXRAID_RW unset)
$NR mount >> "$LOG" 2>&1 || true
read -r mode reasons < "$W/run/nas-raid.mode" || mode=?
check "read-only mount: mode flexraid-ro (got: $mode${reasons:+ $reasons})" test "$mode" = flexraid-ro
check "rbc (RAID 1, made by RAIDiator) read: hello.txt" grep -q '^volume rbc' "$W/mnt/rbc/hello.txt"
check "rbd (RAID 0, made by RAIDiator) read: hello.txt" grep -q '^volume rbd' "$W/mnt/rbd/hello.txt"
check "rbd read-only" sh -c "! touch '$W/mnt/rbd/.w' 2>/dev/null"
$NR status --json > "$W/status-ro.json" 2>&1 || true
$NR unmount >> "$LOG" 2>&1
check "unmounted: no fr-md device left" sh -c "! dmsetup ls | grep -q '^fr-md'"

# B. FLEXRAID_RW=yes: rbd (RAID 0) writable, rbc (RAID 1) still read-only
echo FLEXRAID_RW=yes > "$W/nas-raid.conf"
$NR mount >> "$LOG" 2>&1 || true
read -r mode reasons < "$W/run/nas-raid.mode" || mode=?
check "FLEXRAID_RW=yes: mode flexraid-rw (got: $mode${reasons:+ $reasons})" test "$mode" = flexraid-rw
check "rbc (RAID 1) stays read-only" sh -c "! touch '$W/mnt/rbc/.w' 2>/dev/null"
echo "written under Linux 6.18 by nas-raid $(date)" > "$W/mnt/rbd/from-618.txt"
dd if=/dev/urandom of="$W/mnt/rbd/random-618.bin" bs=1048576 count=8 2> /dev/null
sha256sum "$W/mnt/rbd/random-618.bin" | cut -d' ' -f1 > "$W/random-618.sha256"
sync
check "rbd (RAID 0) written: two files" test -s "$W/mnt/rbd/from-618.txt" -a -s "$W/mnt/rbd/random-618.bin"
$NR status --json > "$W/status-rw.json" 2>&1 || true
$NR unmount >> "$LOG" 2>&1
# and read back once more, read-only, after the unmount
rm -f "$W/nas-raid.conf"
$NR mount >> "$LOG" 2>&1 || true
check "remounted read-only: the files written are there, same sha256" \
	sh -c "grep -q '^written under Linux 6.18' '$W/mnt/rbd/from-618.txt' && [ \"\$(sha256sum < '$W/mnt/rbd/random-618.bin' | cut -d' ' -f1)\" = \"\$(cat '$W/random-618.sha256')\" ]"
$NR unmount >> "$LOG" 2>&1
cleanup; trap - EXIT
sync
say "$OK ok, $KO failed (log: $LOG; keep $W/random-618.sha256); next: boot DIET/RAIDiator, CHECK_DIR=<folder with random-618.sha256> sh on-nas.sh TOOLS WORK check618"
[ "$KO" = 0 ]
