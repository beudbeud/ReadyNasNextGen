#!/bin/sh
# RAIDiator md-mode ("Flex-RAID") test bench: fake disks built with RAIDiator's
# own tools run under QEMU user mode (sfdisk, mdconfig, mke2fs, tune2fs), then
# read back with xraid-info flexraid and compared with what Linux md assembles.
# See README.md next to this file.
#
#   sh bench.sh prepare FIRMWARE_ROOT_TGZ      (no root) sysroot + qemu-sparc
#   sudo sh bench.sh run [SCENARIO...]          build the disks and check them
#   sudo sh bench.sh clean                      undo what an interrupted run left
#   sudo sh bench.sh nas-verify DIR             arrays made on the NAS by on-nas.sh
#
# Only loop devices this script created, md0-md9 (refused if one is in use) and
# dm devices named rb-* are touched. Nothing outside $WORK is written.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK=${WORK:-$HERE/work}
SYS=$WORK/sysroot
DISK_MB=${DISK_MB:-4096}		# disk size; root (2 GB) + swap (512 MB) are fixed
STATE=$WORK/state			# loops, md, VGs and dm devices of the current run
LOG=$WORK/bench.log

say() { echo "$*"; echo "$*" >> "$LOG"; }
die() { say "ERROR: $*"; exit 1; }
OK=0; KO=0
check() {	# check "description" command...
	d=$1; shift
	if "$@" >> "$LOG" 2>&1; then OK=$((OK + 1)); say "ok   $d"; else KO=$((KO + 1)); say "FAIL $d"; fi
}

# ---------- qemu-sparc and RAIDiator's sysroot ----------
qemu_bin() {
	for q in "$WORK/qemu/usr/bin/qemu-sparc" "$(command -v qemu-sparc-static || true)" "$(command -v qemu-sparc || true)"; do
		[ -n "$q" ] && [ -x "$q" ] && { echo "$q"; return; }
	done
	return 1
}
prepare() {
	[ $# = 1 ] && [ -r "$1" ] || die "usage: bench.sh prepare path/to/root.tgz (RAIDiator 4.1.16, decrypted)"
	mkdir -p "$WORK"; : >> "$LOG"
	if ! qemu_bin > /dev/null; then
		say "qemu-sparc: unpacking the qemu-user package into $WORK/qemu (nothing installed)"
		rm -rf "$WORK/qemu.dl"; mkdir -p "$WORK/qemu.dl"
		(cd "$WORK/qemu.dl" && apt-get download qemu-user > /dev/null) || die "apt-get download qemu-user failed (or install qemu-user-static)"
		dpkg-deb -x "$WORK"/qemu.dl/qemu-user_*.deb "$WORK/qemu"
	fi
	say "sysroot: $SYS"
	rm -rf "$SYS"; mkdir -p "$SYS"
	tar -xzf "$1" -C "$SYS" 2> /dev/null || true
	# Frontview and part of /usr ship as a second archive inside root.tgz
	if [ -r "$SYS/tmp/partial.tar.lzma" ]; then
		xz --format=lzma -dc "$SYS/tmp/partial.tar.lzma" | tar -x -C "$SYS" 2> /dev/null || true
	fi
	[ -x "$SYS/sbin/mdconfig" ] && [ -x "$SYS/sbin/mke2fs" ] && [ -x "$SYS/sbin/sfdisk" ] || die "not a RAIDiator root.tgz"
	# qemu -L serves any path that exists in the sysroot: its empty /dev (no
	# device nodes without root), /proc and /sys would hide the host's
	rm -rf "$SYS/dev" "$SYS/proc" "$SYS/sys"
	Q=$(qemu_bin); "$Q" -L "$SYS" "$SYS/sbin/mke2fs" -V 2>&1 | head -n 1 | sed 's/^/RAIDiator mke2fs under qemu: /'
}

# r CMD ARGS...: a RAIDiator binary run under qemu
r() {
	c=$1; shift
	for d in sbin usr/sbin bin usr/bin; do [ -x "$SYS/$d/$c" ] && break; done
	echo "+ [raidiator] $c $*" >> "$LOG"
	"$QEMU" ${QEMU_OPTS:-} -L "$SYS" "$SYS/$d/$c" "$@"
}
h() { echo "+ $*" >> "$LOG"; "$@"; }
# on a failed step (set -e): the end of the log, then everything undone
on_exit() {
	rc=$?
	if [ $rc != 0 ]; then echo "--- last lines of $LOG:"; tail -n 15 "$LOG"; fi
	stopall; clean_state; rm -f "$STATE"
	exit $rc
}

# ---------- disks ----------
mkdisks() {	# mkdisks NAME COUNT: sparse images on new loop devices -> $DISKS
	DISKS=
	i=0
	while [ $i -lt "$2" ]; do
		f=$WORK/img/$1-$i.img
		mkdir -p "$WORK/img"; rm -f "$f"; truncate -s "${DISK_MB}M" "$f"
		l=$(losetup -fP --show "$f")
		DISKS="$DISKS $l"
		echo "loop $l" >> "$STATE"
		i=$((i + 1))
	done
}
part() { echo "${1}p$2"; }

# RAIDiator's linuxrc, "MD install": same partitions on every disk, type 0xfd,
# written by RAIDiator's own sfdisk
factory_partition() {	# disks...
	ROOT=4096000; SWAP=1048576; OFFSET=32; DATA=0
	for d in "$@"; do
		kb=$(r sfdisk -s "$d")
		d1=$((kb - ROOT / 2 - SWAP / 2 - 8192))
		if [ $DATA -eq 0 ] || [ $d1 -lt $DATA ]; then DATA=$d1; fi
	done
	DATA=$((DATA * 2))
	for d in "$@"; do
		dd if=/dev/zero of="$d" count=32 2> /dev/null
		printf '%s,%s,fd\n%s,%s,fd\n%s,%s,fd\n,0\n' $OFFSET $ROOT $((ROOT + OFFSET)) $SWAP \
			$((ROOT + SWAP + OFFSET)) $DATA | r sfdisk -uS --force "$d" > /dev/null 2>&1 || true
		h blockdev --rereadpt "$d"
	done
}

# md array as RAIDiator's mdconfig makes it: the legacy md ioctls
# SET_ARRAY_INFO, ADD_NEW_DISK, RUN_ARRAY, 0.90, chunk 16 KiB; the kernel writes
# the superblocks. mdconfig itself cannot run under qemu user mode (qemu does
# not pass the md ioctls through: "Unsupported ioctl" on SET_ARRAY_INFO), so
# mdcreate.c sends the same ioctls from the host.
mkmd() {	# mkmd /dev/mdN LEVEL members...
	md=$1; lv=$2; shift 2
	echo "md $md" >> "$STATE"
	h "$WORK/mdcreate" "$md" "$lv" 16 "$@" >> "$LOG" 2>&1
	h mdadm --wait "$md" >> "$LOG" 2>&1 || true
}

# LVM + ext3 as Frontview's _VolumeAdd_ and linuxrc do: VG = LV = volume name,
# 32 MiB extents, mke2fs -m 0 -j -L NAME -b 16384 (RAIDiator's mke2fs), then a
# known file written with the host's debugfs (no mount: 16 KiB blocks)
LVMCF="devices { filter = [ \"a|^/dev/md[0-9]$|\", \"r|.*|\" ] }"
mkvolume() {	# mkvolume NAME /dev/mdN
	v=$1; md=$2
	echo "vg $v" >> "$STATE"
	h lvm pvcreate -ffy --config "$LVMCF" "$md" >> "$LOG" 2>&1
	h lvm vgcreate -s 32M --config "$LVMCF" "$v" "$md" >> "$LOG" 2>&1
	pe=$(lvm vgdisplay -c --config "$LVMCF" "$v" 2> /dev/null | cut -d: -f14 | tr -d ' ')
	# SNAP_PE: extents left free for a snapshot (Frontview's snapshot reserve)
	h lvm lvcreate -y -l $((pe - ${SNAP_PE:-0})) -n "$v" --config "$LVMCF" "$v" >> "$LOG" 2>&1
	r mke2fs -F -m 0 -j -L "$v" -b 16384 "/dev/mapper/$v-$v" >> "$LOG" 2>&1 || die "RAIDiator mke2fs on $v failed"
	r tune2fs -c0 -i0 "/dev/mapper/$v-$v" >> "$LOG" 2>&1 || true
	printf 'volume %s on %s\n' "$v" "$md" > "$WORK/hello"
	h debugfs -w -R "write $WORK/hello hello.txt" "/dev/mapper/$v-$v" >> "$LOG" 2>&1
	h lvm vgchange -an --config "$LVMCF" "$v" >> "$LOG" 2>&1
}

# reference: sha256 of what md assembles, array by array
remember() {	# remember SCENARIO /dev/mdN...
	s=$1; shift
	for md in "$@"; do sha256sum < "$md" | cut -d' ' -f1 > "$WORK/ref-$s-${md#/dev/}"; done
}
stopall() {
	for v in $(sed -n 's/^vg //p' "$STATE" 2> /dev/null); do lvm vgchange -an --config "$LVMCF" "$v" > /dev/null 2>&1 || true; done
	for md in $(sed -n 's/^md //p' "$STATE" 2> /dev/null); do [ -b "$md" ] && mdadm --stop "$md" > /dev/null 2>&1 || true; done
}

# ---------- reading back with our code ----------
XI=$WORK/xraid-info
verify() {	# verify SCENARIO "minor:level:usable ..." disks...
	s=$1; exp=$2; shift 2
	"$XI" flexraid "$@" > "$WORK/fr-$s.txt"
	"$XI" flexraid --json "$@" > "$WORK/fr-$s.json"
	got=$( (set +u; . "$WORK/fr-$s.txt"; i=0; g=
		while [ $i -lt "$FR_NR_ARRAYS" ]; do eval "set -- \$FR_A$i"; g="$g $1:$2:$3"; i=$((i + 1)); done
		echo "${g# }") )
	check "$s ($*): arrays found = $exp" test "$got" = "$exp"
	# every usable array mapped read-only with OUR table, compared with md's content
	maps=$( (set +u; . "$WORK/fr-$s.txt"; i=0
		while [ $i -lt "$FR_NR_ARRAYS" ]; do
			eval "set -- \$FR_A$i; t=\$FR_A${i}_TABLE"
			[ "$3" = 1 ] && echo "md$1|$t"
			i=$((i + 1))
		done) )
	echo "$maps" | while IFS='|' read -r m t; do
		[ -n "$m" ] || continue
		dmsetup create "rb-$m" --readonly --table "$t"
		echo "dm rb-$m" >> "$STATE"
	done
	for m in $(echo "$maps" | cut -d'|' -f1); do
		ref=$WORK/ref-$s-$m
		[ -r "$ref" ] || continue
		check "$s: $m through our read-only dm table = md's content (sha256)" \
			test "$(sha256sum < "/dev/mapper/rb-$m" | cut -d' ' -f1)" = "$(cat "$ref")"
	done
	# LVM and the file system on top of our maps, read-only
	for v in $(sed -n 's/^vg //p' "$STATE"); do
		cf="devices { filter = [ \"a|^/dev/mapper/rb-md|\", \"r|.*|\" ] } global { metadata_read_only = 1 } activation { read_only_volume_list = [ \"$v\" ] }"
		if lvm vgchange -ay --config "$cf" "$v" > /dev/null 2>&1; then
			check "$s: volume $v: file written at build time read back" \
				sh -c "debugfs -R 'cat hello.txt' /dev/mapper/$v-$v 2>/dev/null | grep -q '^volume $v '"
			lvm vgchange -an --config "$cf" "$v" > /dev/null 2>&1 || true
		else
			echo "volume $v not activated on our maps" >> "$LOG"
		fi
	done
	for d in $(sed -n 's/^dm //p' "$STATE"); do dmsetup remove "$d" 2> /dev/null || true; done
	sed -i '/^dm /d' "$STATE"
}

# ---------- scenarios ----------
# factory-raid1: linuxrc's default on 2 disks (md0 root, md1 swap, md2 data c)
sc_factory_raid1() {
	mkdisks raid1 2; set -- $DISKS
	factory_partition "$@"
	mkmd /dev/md0 1 "$(part "$1" 1)" "$(part "$2" 1)"
	mkmd /dev/md1 1 "$(part "$1" 2)" "$(part "$2" 2)"
	mkmd /dev/md2 1 "$(part "$1" 3)" "$(part "$2" 3)"
	mkvolume c /dev/md2
	remember factory-raid1 /dev/md0 /dev/md1 /dev/md2
	stopall
	verify factory-raid1 "0:raid1:1 1:raid1:1 2:raid1:1" "$@"
	verify factory-raid1 "0:raid1:1 1:raid1:1 2:raid1:1" "$2"	# one disk gone
}
# factory-raid0: RAIDLEVEL=0 chosen at install
sc_factory_raid0() {
	mkdisks raid0 2; set -- $DISKS
	factory_partition "$@"
	mkmd /dev/md0 1 "$(part "$1" 1)" "$(part "$2" 1)"
	mkmd /dev/md1 0 "$(part "$1" 2)" "$(part "$2" 2)"
	mkmd /dev/md2 0 "$(part "$1" 3)" "$(part "$2" 3)"
	mkvolume c /dev/md2
	remember factory-raid0 /dev/md0 /dev/md1 /dev/md2
	stopall
	verify factory-raid0 "0:raid1:1 1:raid0:1 2:raid0:1" "$@"
	verify factory-raid0 "0:raid1:1 1:raid0:0 2:raid0:0" "$1"	# one disk gone
}
# single: one disk (linuxrc: RAIDLEVEL 0 on a single member)
sc_single() {
	mkdisks single 1; set -- $DISKS
	factory_partition "$@"
	mkmd /dev/md0 1 "$(part "$1" 1)"
	mkmd /dev/md1 0 "$(part "$1" 2)"
	mkmd /dev/md2 0 "$(part "$1" 3)"
	mkvolume c /dev/md2
	remember single /dev/md0 /dev/md1 /dev/md2
	stopall
	verify single "0:raid1:1 1:raid0:1 2:raid0:1" "$@"
}
# stale: RAID 1 whose first member failed before the volume was written
sc_stale() {
	mkdisks stale 2; set -- $DISKS
	factory_partition "$@"
	mkmd /dev/md0 1 "$(part "$1" 1)" "$(part "$2" 1)"
	mkmd /dev/md1 1 "$(part "$1" 2)" "$(part "$2" 2)"
	mkmd /dev/md2 1 "$(part "$1" 3)" "$(part "$2" 3)"
	h mdadm /dev/md2 --fail "$(part "$1" 3)" >> "$LOG" 2>&1
	mkvolume c /dev/md2		# only on disk 2 now
	remember stale /dev/md2
	stopall
	verify stale "0:raid1:1 1:raid1:1 2:raid1:1" "$@"
}

# split: the issue's layout (Frontview, docs/XRAID.md §10): volume c deleted and
# two volumes added on both disks, p3 RAID 1 (c) and p4 RAID 0 (d); primary
# partitions, starts on 8 sectors, whole MiB, the last 8 MiB never used
sc_split() {
	mkdisks split 2; set -- $DISKS
	S=$(blockdev --getsz "$1"); END=$((S - 16384))
	P3=5144608; L3=$(( (END - P3) / 3 / 2048 * 2048 ))
	P4=$(( (P3 + L3 + 7) / 8 * 8 )); L4=$(( (END - P4) / 2048 * 2048 ))
	for d in "$@"; do
		dd if=/dev/zero of="$d" count=32 2> /dev/null
		printf '32,4096000,fd\n4096032,1048576,fd\n%s,%s,fd\n%s,%s,fd\n' $P3 $L3 $P4 $L4 | r sfdisk -uS --force "$d" > /dev/null 2>&1 || true
		h blockdev --rereadpt "$d"
	done
	mkmd /dev/md0 1 "$(part "$1" 1)" "$(part "$2" 1)"
	mkmd /dev/md1 1 "$(part "$1" 2)" "$(part "$2" 2)"
	mkmd /dev/md2 1 "$(part "$1" 3)" "$(part "$2" 3)"
	mkmd /dev/md3 0 "$(part "$1" 4)" "$(part "$2" 4)"
	mkvolume c /dev/md2
	mkvolume d /dev/md3
	remember split /dev/md2 /dev/md3
	stopall
	verify split "0:raid1:1 1:raid1:1 2:raid1:1 3:raid0:1" "$@"
	verify split "0:raid1:1 1:raid1:1 2:raid1:1 3:raid0:0" "$1"	# one disk: c only
}
# snapshot: Frontview's snapshot reserve and an active snapshot LV c_YYYY_MM_DD_HH_MM
sc_snapshot() {
	mkdisks snap 2; set -- $DISKS
	factory_partition "$@"
	mkmd /dev/md0 1 "$(part "$1" 1)" "$(part "$2" 1)"
	mkmd /dev/md1 1 "$(part "$1" 2)" "$(part "$2" 2)"
	mkmd /dev/md2 1 "$(part "$1" 3)" "$(part "$2" 3)"
	SNAP_PE=8 mkvolume c /dev/md2
	h lvm vgchange -ay --config "$LVMCF" c >> "$LOG" 2>&1
	h lvm lvcreate -s -c 256k -l 8 -n c_2026_11_26_10_00 --config "$LVMCF" c/c >> "$LOG" 2>&1
	h lvm vgchange -an --config "$LVMCF" c >> "$LOG" 2>&1
	remember snapshot /dev/md2
	stopall
	verify snapshot "0:raid1:1 1:raid1:1 2:raid1:1" "$@"
}
# lvm1: a volume RAIDiator created and did not reboot since: LVM1 metadata,
# written by RAIDiator's own LVM 2.02.07 under qemu (pvcreate -M1); lvm2 2.03
# cannot read it: xraid-info must say lvm1, nothing is mounted
# RAIDiator's LVM under qemu: its sysfs filter compares device numbers that
# qemu's stat translation changes, and its persistent cache keeps the refusal
LVM1CF='devices { sysfs_scan = 0 write_cache_state = 0 cache = "/nonexistent/rb-lvm-cache" filter = [ "a|^/dev/md[0-9]$|", "r|.*|" ] }'
sc_lvm1() {
	mkdisks lvm1 2; set -- $DISKS
	factory_partition "$@"
	mkmd /dev/md0 1 "$(part "$1" 1)" "$(part "$2" 1)"
	mkmd /dev/md1 1 "$(part "$1" 2)" "$(part "$2" 2)"
	mkmd /dev/md2 1 "$(part "$1" 3)" "$(part "$2" 3)"
	if ! "$QEMU" -L "$SYS" "$SYS/lib/lvm-200/lvm" pvcreate ${LVM_TRACE:+-vvvv} --config "$LVM1CF" -M1 -ff -y /dev/md2 >> "$LOG" 2>&1; then
		say "skip lvm1: RAIDiator's LVM 2.02.07 crashes under qemu user mode (see $LOG); LVM1 detection is covered by the unit tests"
		stopall; return 0
	fi
	"$QEMU" -L "$SYS" "$SYS/lib/lvm-200/lvm" vgcreate --config "$LVM1CF" -M1 -An -s32M c /dev/md2 >> "$LOG" 2>&1 || true
	stopall
	verify lvm1 "0:raid1:1 1:raid1:1 2:raid1:1" "$@"
	check "lvm1: md2 reported as LVM1 (reason lvm1)" \
		sh -c "grep -qx \"FR_A2_CONTENT='lvm1'\" '$WORK/fr-lvm1.txt' && grep -q \"FR_A2_REASONS='.*lvm1\" '$WORK/fr-lvm1.txt'"
}

SCENARIOS="factory-raid1 factory-raid0 single stale split snapshot lvm1"

run() {
	[ "$(id -u)" = 0 ] || die "run needs root (loop, md and dm devices)"
	QEMU=$(qemu_bin) || die "no qemu-sparc: sh bench.sh prepare ROOT_TGZ first"
	[ -x "$SYS/sbin/mdconfig" ] || die "no sysroot: sh bench.sh prepare ROOT_TGZ first"
	for t in mdadm lvm dmsetup losetup debugfs blockdev sha256sum cc xz; do command -v $t > /dev/null || die "$t missing"; done
	for n in 0 1 2 3 4 5 6 7 8 9; do
		if grep -q "^md$n " /proc/mdstat 2> /dev/null; then die "md$n is in use on this machine: refusing"; fi
	done
	[ -e "$STATE" ] && die "a previous run left devices: sudo sh bench.sh clean"
	mkdir -p "$WORK"; : > "$LOG"; : > "$STATE"
	cc -O2 -Wall -o "$XI" "$REPO/package/xraid-compat/src/xraid-info.c"
	cc -O2 -Wall -o "$WORK/mdcreate" "$HERE/mdcreate.c"
	trap on_exit EXIT
	for s in ${*:-$SCENARIOS}; do
		say "=== $s"
		"sc_$(echo "$s" | tr - _)"
		stopall; clean_state; : > "$STATE"
	done
	trap - EXIT; rm -f "$STATE"
	say "$OK ok, $KO failed (log: $LOG)"
	[ "$KO" = 0 ]
}
clean_state() {
	[ -r "$STATE" ] || return 0
	for d in $(sed -n 's/^dm //p' "$STATE"); do dmsetup remove "$d" 2> /dev/null || true; done
	for l in $(sed -n 's/^loop //p' "$STATE"); do losetup -d "$l" 2> /dev/null || true; done
}
clean() { stopall; clean_state; rm -f "$STATE"; }

# ---------- arrays made on the NAS by on-nas.sh (RAIDiator's own kernel) ----------
# DIR holds d0p1.img d0p2.img d1p1.img d1p2.img: member partitions whose md
# 0.90 superblocks were written by RAIDiator's md.c. Two disks are rebuilt
# around them (MBR, p1 and p2 of type 0xfd) for xraid-info, then compared with
# what the PC's md assembles from the very same partitions.
nas_verify() {
	[ "$(id -u)" = 0 ] || die "nas-verify needs root (loop, md and dm devices)"
	D=$1
	for f in d0p1 d0p2 d1p1 d1p2; do [ -r "$D/$f.img" ] || die "$D/$f.img missing"; done
	for n in 5 6; do
		if grep -q "^md$n " /proc/mdstat 2> /dev/null; then die "md$n is in use on this machine: refusing"; fi
	done
	[ -e "$STATE" ] && die "a previous run left devices: sudo sh bench.sh clean"
	mkdir -p "$WORK/nas"; : > "$LOG"; : > "$STATE"
	cc -O2 -Wall -o "$XI" "$REPO/package/xraid-compat/src/xraid-info.c"
	trap on_exit EXIT
	s1=$(($(stat -c %s "$D/d0p1.img") / 512)); s2=$(($(stat -c %s "$D/d0p2.img") / 512))
	# 1. byte order: the PC's md (little-endian host) reads them as they are?
	m=; for f in d0p1 d0p2 d1p1 d1p2; do l=$(losetup -f --show -r "$D/$f.img"); echo "loop $l" >> "$STATE"; m="$m $l"; done
	set -- $m
	for l in "$@"; do mdadm --examine "$l" >> "$LOG" 2>&1 || true; done
	check "superblocks written by RAIDiator's kernel read by the PC's md as they are (little-endian)" \
		sh -c "mdadm --examine $1 2>&1 | grep -q 'Version : 0.90'"
	# RAIDiator leaves chunk_size big-endian: the PC's md reads 4096K instead
	# of 16K, so it is a reference for the RAID 1 only (no chunk there); the
	# RAID 0 is checked through its content (LVM, ext3, the file of on-nas.sh)
	check "RAID 0 made by RAIDiator: the PC's md misreads its chunk (4096K, byte-swapped 16K)" \
		sh -c "mdadm --examine $2 2>&1 | grep -q 'Chunk Size : 4096K'"
	echo "md /dev/md5" >> "$STATE"
	h mdadm --assemble --readonly /dev/md5 "$1" "$3" >> "$LOG" 2>&1 || true
	if [ -b /dev/md5 ] && grep -q "^md5 " /proc/mdstat; then
		sha256sum < /dev/md5 | cut -d' ' -f1 > "$WORK/ref-nas-md5"
	fi
	check "the PC's md assembles the RAID 1 made by RAIDiator (md5)" test -r "$WORK/ref-nas-md5"
	stopall; for l in "$@"; do losetup -d "$l"; done; sed -i '/^loop /d' "$STATE"
	# 2. our code on two disks rebuilt around the same partitions
	disks=
	for d in 0 1; do
		img=$WORK/nas/disk$d.img; rm -f "$img"
		truncate -s $(( (2048 + s1 + s2 + 16384) * 512 )) "$img"
		printf '2048,%s,fd\n%s,%s,fd\n' $s1 $((2048 + s1)) $s2 | sfdisk -q -uS --force "$img" > /dev/null 2>&1 \
			|| printf 'start=2048, size=%s, type=fd\nstart=%s, size=%s, type=fd\n' $s1 $((2048 + s1)) $s2 | sfdisk -q "$img" >> "$LOG" 2>&1
		dd if="$D/d${d}p1.img" of="$img" bs=512 seek=2048 conv=notrunc,sparse status=none
		dd if="$D/d${d}p2.img" of="$img" bs=512 seek=$((2048 + s1)) conv=notrunc,sparse status=none
		l=$(losetup -f --show -r "$img"); echo "loop $l" >> "$STATE"; disks="$disks $l"
	done
	echo "vg rbc" >> "$STATE"; echo "vg rbd" >> "$STATE"
	verify nas "5:raid1:1 6:raid0:1" $disks
	check "nas: superblocks recognised as RAIDiator's (little-endian words, SPARC order)" grep -q '"byte_order":"raidiator"' "$WORK/fr-nas.json"
	check "nas: both volumes, made by RAIDiator's LVM 2.02.07, reported LVM2" \
		sh -c "grep -qx \"FR_A0_CONTENT='lvm2'\" '$WORK/fr-nas.txt' && grep -qx \"FR_A1_CONTENT='lvm2'\" '$WORK/fr-nas.txt'"
	trap - EXIT; stopall; clean_state; rm -f "$STATE"
	say "$OK ok, $KO failed (log: $LOG, xraid-info: $WORK/fr-nas.json)"
	[ "$KO" = 0 ]
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
prepare) prepare "$@" ;;
run) run "$@" ;;
nas-verify) [ $# = 1 ] || die "usage: sudo sh bench.sh nas-verify DIR (made by on-nas.sh)"; nas_verify "$1" ;;
clean) [ "$(id -u)" = 0 ] || die "clean needs root"; clean ;;
*) sed -n '2,13p' "$0"; exit 2 ;;
esac
