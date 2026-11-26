#!/bin/sh
# RAIDiator md tests on the NAS's own 2.6.17 kernel (RAIDiator or old DIET):
# the superblocks are written by RAIDiator's patched md.c, the arrays handled
# by RAIDiator's mdconfig, the volumes by its LVM 2.02.07 and mke2fs. Fake
# disks: one file per member partition (dDISKpPART.img), on a USB key, one
# folder per scenario. Read back on the PC with "bench.sh nas-verify" (README.md).
#
#   sh on-nas.sh TOOLS_DIR WORK_DIR [SCENARIO...]
#
# TOOLS_DIR: RAIDiator's mdconfig, lvm, mke2fs, tune2fs and their libraries.
# WORK_DIR: an empty folder on the USB key. Scenarios: base failed rebuild
# spare single snapshot delete (all by default).
# Uses /dev/loop0-7, md5 and md6, VGs rb*: never the NAS's disks nor its VG
# "c" (the LVM filter only sees md5 and md6).
set -eu
T=$1; W=$2; shift 2
SCENARIOS=${*:-base failed rebuild spare single snapshot delete}
LD="$T/lib/ld-linux.so.2 --library-path $T/lib"
export LVM_SYSTEM_DIR=$T	# RAIDiator's lvm.conf, not the NAS's
CF='devices { filter = [ "a|^/dev/md[56]$|", "r|.*|" ] write_cache_state = 0 } backup { backup = 0 archive = 0 }'
LOG=$W/nas.log
MTAB=

say() { echo "$*"; echo "$*" >> "$LOG"; }
run() { echo "+ $*" >> "$LOG"; "$@" >> "$LOG" 2>&1; }
tool() { t=$1; shift; run $LD "$T/bin/$t" "$@"; }
lvm() { tool lvm "$@" --config "$CF"; }
# Never an LVM command without a VG name: given none, RAIDiator's LVM acts on
# every VG it sees, the NAS's "c" included (seen: "Can't deactivate volume
# group c", refused only because /c was mounted). The test VGs are listed in
# $VGS (a file: the scenarios run in subshells) and must start with "rb".
VGS=$W/test-vgs
vg_off() {
	[ -r "$VGS" ] || return 0
	for v in $(cat "$VGS"); do
		case "$v" in rb*) lvm vgchange -an "$v" || true ;; *) echo "refusing VG $v" ;; esac
	done
}
mdc() { tool mdconfig "$@"; }
# raidtools (raidhotadd, raidsetfaulty, raidhotremove) insist on a raidtab:
# a minimal one for md5 in TOOLS_DIR (-c), never the NAS's /etc
rt() {		# rt TOOL MEMBER: TOOL on md5, raidtab listing $RT_DEVS
	r=$1; shift
	{ echo "raiddev /dev/md5"; echo "raid-level 1"; echo "nr-raid-disks 2"; echo "persistent-superblock 1"
	  echo "chunk-size 16"; i=0; for d in $RT_DEVS; do echo "device $d"; echo "raid-disk $i"; i=$((i + 1)); done; } > "$T/raidtab"
	tool "$r" -c "$T/raidtab" /dev/md5 "$@"
}

for n in 5 6; do if grep -q "^md$n " /proc/mdstat; then echo "md$n in use: refusing"; exit 1; fi; done
for i in 0 1 2 3 4 5 6 7; do if losetup /dev/loop$i > /dev/null 2>&1; then echo "loop$i in use: refusing"; exit 1; fi; done
[ -d "$W" ] && [ -z "$(ls -A "$W" 2>/dev/null)" ] || { echo "$W missing or not empty: refusing"; exit 1; }
: > "$LOG"

stop_all() {
	vg_off
	umount /tmp/rbmnt 2> /dev/null || true
	for n in 5 6; do if grep -q "^md$n " /proc/mdstat; then mdc -a stop -m /dev/md$n || true; fi; done
	for i in 0 1 2 3 4 5 6 7; do losetup -d /dev/loop$i 2> /dev/null || true; done
}
cleanup() {
	stop_all
	if [ -n "$MTAB" ] && [ -L /etc/mtab ]; then rm -f /etc/mtab; MTAB=; fi
}
trap 'cleanup' EXIT
# old DIET has no /etc/mtab and e2fsprogs 1.40 stops on it: the usual link to
# /proc/mounts for the time of the test, removed by cleanup (only if made here)
if [ ! -e /etc/mtab ]; then ln -s /proc/mounts /etc/mtab; MTAB=1; fi

# member DIR NAME MiB: a zeroed partition file on the next free loop -> $L
NEXT=0
member() {
	run dd if=/dev/zero of="$1/$2.img" bs=1048576 count=$3
	L=/dev/loop$NEXT; NEXT=$((NEXT + 1))
	run losetup "$L" "$1/$2.img"
	echo "$L $2" >> "$1/loops"
}
wait_sync() { while grep -q "resync\|recovery" /proc/mdstat; do sleep 3; done; }
# volume VG MD PE_SIZE [EXTENTS]: RAIDiator's LVM and mke2fs, as Frontview's
# _VolumeAdd_ (-s 4M: its choice when 32M gives 2 extents or fewer); LV of
# EXTENTS (default: all), then a file written through the 2.6.17 kernel
volume() {
	vg=$1; md=$2
	case "$vg" in rb*) ;; *) echo "test VG names start with rb: $vg refused"; return 1 ;; esac
	echo "$vg" >> "$VGS"
	lvm pvcreate -ff -y "$md"
	lvm vgcreate -An -s"$3" "$vg" "$md"
	pe=${4:-$($LD "$T/bin/lvm" vgdisplay -c "$vg" --config "$CF" 2> /dev/null | cut -d: -f14 | tr -d ' ')}
	lvm lvcreate -An -l "$pe" -n "$vg" "$vg"
	tool mke2fs -m 0 -j -L "$vg" -b 16384 "/dev/$vg/$vg"
	tool tune2fs -c0 -i0 "/dev/$vg/$vg"
	put "$vg" hello.txt "volume $vg on $md"
}
put() {		# put VG FILE TEXT: write a file on the volume
	mkdir -p /tmp/rbmnt
	run mount -t ext3 "/dev/$1/$1" /tmp/rbmnt
	echo "$3" > "/tmp/rbmnt/$2"
	run umount /tmp/rbmnt
}
super() {	# super DIR: superblocks as RAIDiator's mdconfig shows them
	while read -r l n; do
		echo "== $n ($l)" >> "$LOG"
		run losetup "$l" "$1/$n.img" || true
		mdc -a super -d "$l" || true
		losetup -d "$l" 2> /dev/null || true
	done < "$1/loops"
}
finish() {	# finish DIR: arrays stopped, loops freed, superblocks logged
	vg_off
	cat /proc/mdstat >> "$LOG"
	stop_all; NEXT=0
	super "$1"
}

# base: two disks, md5 RAID 1 (rbc) and md6 RAID 0 (rbd), chunk 16 KiB
sc_base() {
	member "$1" d0p1 128; a=$L; member "$1" d0p2 256; b=$L
	member "$1" d1p1 128; c=$L; member "$1" d1p2 256; d=$L
	mdc -a new -m /dev/md5 -l 1 -c 16 -r "$a,$c,"
	mdc -a new -m /dev/md6 -l 0 -c 16 -r "$b,$d,"
	wait_sync
	volume rbc /dev/md5 32M
	volume rbd /dev/md6 32M
	lvm vgs -o vg_name,vg_fmt rbc rbd || true
	finish "$1"
}
# failed: a RAID 1 member removed by mdconfig, then the volume written again:
# that member is out of date (its superblock keeps an older event count)
sc_failed() {
	member "$1" d0p1 64; a=$L; member "$1" d1p1 64; c=$L
	mdc -a new -m /dev/md5 -l 1 -c 16 -r "$a,$c,"
	wait_sync
	volume rbf /dev/md5 4M
	mdc -a remove -m /dev/md5 -d "$c"
	put rbf after.txt "written after disk 1 was removed"
	finish "$1"
}
# rebuild: disk 1 fails and is removed, a blank one hot-added in its place
# (raidhotadd, as RAIDiator adds spares and replacement partitions; mdconfig
# -a add repartitions a whole disk first: it needs a disk geometry, that a
# loop device has not), array stopped while the recovery runs
sc_rebuild() {
	member "$1" d0p1 64; a=$L; member "$1" d1p1 64; c=$L
	mdc -a new -m /dev/md5 -l 1 -c 16 -r "$a,$c,"
	wait_sync
	volume rbr /dev/md5 4M
	RT_DEVS="$a $c"
	rt raidsetfaulty "$c"
	rt raidhotremove "$c"
	run dd if=/dev/zero of="$c" bs=1048576 count=64
	rt raidhotadd "$c"
	sleep 2
	cat /proc/mdstat >> "$LOG"
	finish "$1"
}
# spare: a third disk added to a complete RAID 1 becomes a spare
sc_spare() {
	member "$1" d0p1 64; a=$L; member "$1" d1p1 64; c=$L; member "$1" d2p1 64; e=$L
	mdc -a new -m /dev/md5 -l 1 -c 16 -r "$a,$c,"
	wait_sync
	volume rbs /dev/md5 4M
	RT_DEVS="$a $c"
	rt raidhotadd "$e"
	finish "$1"
}
# single: one disk, RAID 1 and RAID 0 of one member (linuxrc's one-disk install)
sc_single() {
	member "$1" d0p1 64; a=$L; member "$1" d0p2 64; b=$L
	mdc -a new -m /dev/md5 -l 1 -c 16 -r "$a,"
	mdc -a new -m /dev/md6 -l 0 -c 16 -r "$b,"
	volume rbo /dev/md6 4M
	finish "$1"
}
# snapshot: Frontview's snapshot (chunk 256K, LV v_YYYY_MM_DD_HH_MM in the free
# extents), then the origin written again (copy-on-write)
sc_snapshot() {
	member "$1" d0p1 64; a=$L; member "$1" d1p1 64; c=$L
	mdc -a new -m /dev/md5 -l 1 -c 16 -r "$a,$c,"
	wait_sync
	volume rbn /dev/md5 4M 8
	lvm lvcreate -s -c 256k -l 4 -n rbn_2026_11_26_12_00 rbn/rbn
	put rbn after.txt "written after the snapshot"
	lvm lvs rbn || true
	finish "$1"
}
# check618: the base scenario's arrays after on-618.sh wrote on rbd under Linux
# 6.18, on the partitions of the test USB key (type 0xfd). They are started by
# RAIDiator's own boot path: the kernel noted the 0xfd partitions when the key
# appeared, "mdconfig -a autorun" (RAID_AUTORUN) assembles them; the volumes
# mounted read-only; RAIDiator's e2fsck -n on rbd. CHECK_DIR holds
# random-618.sha256 (written by on-618.sh).
sc_check618() {
	C=${CHECK_DIR:?CHECK_DIR: the folder holding random-618.sha256}
	[ -r "$C/random-618.sha256" ] || { echo "$C/random-618.sha256 missing"; return 1; }
	grep -q "^md5 \|^md6 " /proc/mdstat || mdc -a autorun
	cat /proc/mdstat >> "$LOG"
	grep -q "^md5 : active" /proc/mdstat && say "ok   RAIDiator's kernel starts md5 (RAID 1)" || say "FAIL md5 not started"
	grep -q "^md6 : active" /proc/mdstat && say "ok   RAIDiator's kernel starts md6 (RAID 0)" || say "FAIL md6 not started"
	echo rbc >> "$VGS"; echo rbd >> "$VGS"
	lvm vgchange -ay rbc
	lvm vgchange -ay rbd
	tool e2fsck -n -f /dev/rbd/rbd && say "ok   RAIDiator's e2fsck -n: rbd (written by Linux 6.18) clean" || say "FAIL e2fsck -n on rbd (see $LOG)"
	mkdir -p /tmp/rbmnt
	run mount -t ext3 -o ro /dev/rbd/rbd /tmp/rbmnt
	if grep -q '^written under Linux 6.18' /tmp/rbmnt/from-618.txt; then say "ok   rbd: from-618.txt read by RAIDiator's kernel"; else say "FAIL rbd: from-618.txt"; fi
	got=$(sha256sum < /tmp/rbmnt/random-618.bin | cut -d' ' -f1)
	if [ "$got" = "$(cat "$C/random-618.sha256")" ]; then say "ok   rbd: random-618.bin, same sha256 as written under 6.18"; else say "FAIL rbd: random-618.bin sha256 $got"; fi
	grep -q '^volume rbd' /tmp/rbmnt/hello.txt && say "ok   rbd: hello.txt (written by RAIDiator) still there" || say "FAIL rbd: hello.txt"
	run umount /tmp/rbmnt
	run mount -t ext3 -o ro /dev/rbc/rbc /tmp/rbmnt
	grep -q '^volume rbc' /tmp/rbmnt/hello.txt && say "ok   rbc (RAID 1): unchanged, hello.txt read" || say "FAIL rbc: hello.txt"
	run umount /tmp/rbmnt
	stop_all; NEXT=0
}
# delete: what mdconfig -a delete leaves on the members of a stopped array
sc_delete() {
	member "$1" d0p1 64; a=$L; member "$1" d1p1 64; c=$L
	mdc -a new -m /dev/md5 -l 1 -c 16 -r "$a,$c,"
	wait_sync
	mdc -a stop -m /dev/md5
	mdc -a delete -m /dev/md5 || true
	finish "$1"
}

for s in $SCENARIOS; do
	say "=== $s"
	mkdir -p "$W/$s"
	# one scenario failing does not stop the others: everything is undone after it
	# (not inside "if": set -e would be ignored in the subshell)
	set +e; (set -e; "sc_$s" "$W/$s"); rc=$?; set -e
	[ $rc = 0 ] || say "FAILED: $s (see $LOG)"
	stop_all; NEXT=0
done
cleanup; trap - EXIT
sync
say "done: copy $W to the PC, then: sudo sh bench.sh nas-verify <that folder>"
