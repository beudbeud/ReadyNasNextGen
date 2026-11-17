#!/bin/sh
# Checks on the PC the boot of the system slots (updates), without a NAS:
# relay-switch (2.6.17 side) on a simulated system volume and USB stick
# (mount, insmod... replaced by stubs; "go" stops the script), the slot chosen
# by the 6.18 initramfs (its slot() function) on the same stick, S99relay-confirm
# and nas-update (install, confirm, switch) on the 6.18 side.
# Scenarios: stick of the first install (no slot files), failed 6.18 boot,
# skip once, update tried and failed (back to the active slot, not to the
# previous init), update confirmed, going back, trial whose kernel is refused.
# Runs with sh (dash): a host busybox sh would run its own mount, sleep...
# applets instead of the stubs; it only checks the syntax here.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../../.." && pwd)
NU=$TOP/package/diet/src/usr/sbin/nas-update
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FAILS=0
ok() { echo "  ok   $*"; }
ko() { echo "  FAIL $*"; FAILS=$((FAILS + 1)); }
check() { m=$1; shift; if "$@"; then ok "$m"; else ko "$m"; fi; }

# stubs: the stick (/dev/sdb1) is the folder $SIM; "mount" turns the mount
# point into a link to it, "umount" back into a folder
export P=$T/vol SIM=$T/stick
mkdir -p "$T/bin"
cat > "$T/bin/mount" <<'EOF'
#!/bin/sh
case "$1 $2" in
"-t ext3") [ "$3" = "$P/dev/sdb1" ] && [ -d "$SIM" ] && rmdir "$4" && ln -s "$SIM" "$4" ;;
"-t ext2") exit 1 ;;
*) exit 0 ;;
esac
EOF
cat > "$T/bin/umount" <<'EOF'
#!/bin/sh
case "$1" in */mnt/relay-stick) [ -L "$1" ] && rm "$1" && mkdir "$1" ;; *) exit 1 ;; esac
EOF
printf '#!/bin/sh\nmkdir -p "$P/proc/padre_relay"; : > "$P/proc/padre_relay/control"\n' > "$T/bin/insmod"
for c in rmmod mknod sync sleep; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$c"; done
chmod 755 "$T"/bin/*
# relay-switch: prefix and PATH redirected, "go" records the slot and kernel, then stops
sed -e "s|^P=.*|P=$P|" -e "s|^PATH=.*|PATH=$T/bin:/sbin:/bin:/usr/sbin:/usr/bin|" \
	-e "s|^echo \"go \$SIZE\" > .*|echo \"go \$BOOT \${IMG#\$K/}\" > $T/went; exit 0|" \
	"$HERE/relay-switch" > "$T/relay-switch"
grep -q "$T/went" "$T/relay-switch" || { echo "relay-switch: \"go\" line not found"; exit 1; }
# initramfs: its slot choice, alone
sed -n '/^okslot()/p; /^slot() {/,/^}/p' "$HERE/../initramfs/init" > "$T/slot.sh"
grep -q '^slot() {' "$T/slot.sh" || { echo "initramfs: slot() not found"; exit 1; }

newvol() {
	rm -rf "$P" "$SIM"
	mkdir -p "$P/relay" "$P/proc" "$P/dev" "$P/mnt/relay-stick" "$SIM/rootfs-6.18/sbin" "$SIM/boot"
	: > "$P/relay/padre_relay.ko"
	printf 'major minor  #blocks  name\n\n   3     0  488386584 hda\n   8    16    3915776 sdb\n   8    17    3915744 sdb1\n' > "$P/proc/partitions"
	printf 'scsi_mod 1 0\nsd_mod 1 0\nehci_hcd 1 0\nusb_storage 1 0\n' > "$P/proc/modules"
	echo "init 1.0" > "$SIM/rootfs-6.18/sbin/init"
	head -c 70000 /dev/urandom > "$SIM/boot/vmlinux.bin"
	(cd "$SIM/boot" && md5sum vmlinux.bin > vmlinux.bin.md5)
}
# boot: relay-switch once; prints "go <slot> <kernel>" or "previous"
boot() {
	rm -f "$T/went"
	$SH "$T/relay-switch" >/dev/null 2>&1 || true
	if [ -f "$T/went" ]; then cat "$T/went"; else echo previous; fi
}
initramfs() { (ROOTDIR=${1:-}; . "$T/slot.sh"; slot "$SIM"); }
# up <slot>: the 6.18 boot of <slot> completes (S99relay-confirm start)
up() { rm -f "$SIM/$1/.relay_pending"; running "$1"; nu confirm; }
# 6.18 side: nas-update on a minimal running system
N=$T/nas
running() { echo "25 1 8:33 /$1 / rw,noatime shared:1 - ext4 /dev/sdc1 rw" > "$N/proc/self/mountinfo"; }
nu() { DIET_ROOT=$N DIET_STICK=$SIM NAS_UPDATE_SYNC=1 L=en $SH "$NU" "$@"; }
mkdir -p "$N/bin" "$N/etc" "$N/proc/self"
printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/sdc1 1900000 1 1000000 1%% /s"\n' > "$N/bin/df"
chmod 755 "$N/bin/df"
echo "SPINDOWN_MIN=5" > "$N/etc/diet.conf"; echo nas1 > "$N/etc/hostname"
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$N/etc/passwd"
# update packages 2.0 and 3.0 (mkupdate.sh, fake images)
mkdir -p "$T/img/root/sbin" "$T/img/root/etc"
echo "init new" > "$T/img/root/sbin/init"; printf 'root:x:0:0:root:/root:/bin/sh\n' > "$T/img/root/etc/passwd"
tar -C "$T/img/root" -cf "$T/img/rootfs.tar" .
head -c 80000 /dev/urandom > "$T/img/vmlinux.bin"
VERSION=2.0 sh "$HERE/../mkupdate.sh" "$T/img" "$T/img" >/dev/null
VERSION=3.0 sh "$HERE/../mkupdate.sh" "$T/img" "$T/img" >/dev/null
install() { nu receive "$(stat -c %s "$1")" < "$1" >/dev/null; }

SH=sh
for _ in 1; do
	echo "-- stick of the first install (rootfs-6.18, /boot/vmlinux.bin, no slot files)"
	newvol
	check "boots rootfs-6.18 with /boot/vmlinux.bin" test "$(boot)" = "go rootfs-6.18 boot/vmlinux.bin"
	check "boot marker in rootfs-6.18, relay-slots written, nothing else on the stick" \
		sh -c 'test -f "$1/rootfs-6.18/.relay_pending" -a -f "$1/boot/relay-slots" -a ! -e "$1/boot/slot" -a ! -e "$1/boot/slot.try"' - "$SIM"
	check "initramfs: /rootfs-6.18" test "$(initramfs)" = /rootfs-6.18
	check "initramfs: rootdir= on the command line wins" test "$(initramfs /other)" = /other
	check "boot not complete: next power-on starts the previous init, marker removed" \
		sh -c 'test "$1" = previous && test ! -e "$2/rootfs-6.18/.relay_pending"' - "$(boot)" "$SIM"
	boot >/dev/null; up rootfs-6.18
	check "boot complete (S99relay-confirm): 6.18 again, still the first-install layout" \
		sh -c 'test "$1" = "go rootfs-6.18 boot/vmlinux.bin" && test ! -e "$2/boot/slot"' - "$(boot)" "$SIM"
	up rootfs-6.18
	touch "$SIM/rootfs-6.18/.relay_skip_once"
	check "/.relay_skip_once from 6.18: previous init once" test "$(boot)" = previous
	check "then 6.18 again" test "$(boot)" = "go rootfs-6.18 boot/vmlinux.bin"
	up rootfs-6.18

	echo "-- update 2.0 tried, boot not complete"
	install "$T/img/readynasng-update-2.0.tar"
	check "nas-update: rootfs-b installed with its kernel, trial scheduled" \
		sh -c 'test "$(cat "$1/boot/slot.try")" = rootfs-b -a -f "$1/rootfs-b/boot/vmlinux.bin"' - "$SIM"
	check "relay boots rootfs-b with its own kernel" test "$(boot)" = "go rootfs-b rootfs-b/boot/vmlinux.bin"
	check "initramfs agrees: /rootfs-b" test "$(initramfs)" = /rootfs-b
	check "next power-on: back to rootfs-6.18 (not the previous init), trial dropped, failure noted" \
		sh -c 'test "$1" = "go rootfs-6.18 boot/vmlinux.bin" && test ! -e "$2/boot/slot.try" -a ! -e "$2/rootfs-b/.relay_pending" && test "$(cat "$2/boot/slot.failed")" = rootfs-b' - "$(boot)" "$SIM"
	check "initramfs agrees: /rootfs-6.18" test "$(initramfs)" = /rootfs-6.18
	up rootfs-6.18
	check "nas-update status: rootfs-6.18 active, failure of rootfs-b reported" \
		sh -c 'case "$1" in *"\"active\":\"rootfs-6.18\""*"\"failed\":\"rootfs-b\""*) true;; *) false;; esac' - "$(nu status)"
	echo rootfs-b > "$SIM/boot/slot.try"
	check "initramfs: a trial not marked by the relay (TFTP boot) is not taken" test "$(initramfs)" = /rootfs-6.18
	rm "$SIM/boot/slot.try"

	echo "-- tried again (switch), boot complete"
	nu switch >/dev/null
	check "relay boots rootfs-b" test "$(boot)" = "go rootfs-b rootfs-b/boot/vmlinux.bin"
	up rootfs-b
	check "confirmed: rootfs-b active, no trial, no failure left" \
		sh -c 'test "$(cat "$1/boot/slot")" = rootfs-b -a ! -e "$1/boot/slot.try" -a ! -e "$1/boot/slot.failed"' - "$SIM"
	check "next power-on: rootfs-b (active)" test "$(boot)" = "go rootfs-b rootfs-b/boot/vmlinux.bin"
	check "initramfs: /rootfs-b" test "$(initramfs)" = /rootfs-b
	up rootfs-b
	check "settings carried over (diet.conf)" cmp -s "$N/etc/diet.conf" "$SIM/rootfs-b/etc/diet.conf"
	boot >/dev/null
	check "boot of the active slot not complete: previous init (as before)" test "$(boot)" = previous

	echo "-- update 3.0 into rootfs-6.18, kernel refused by the relay"
	install "$T/img/readynasng-update-3.0.tar"
	check "first-install kernel removed, 3.0 has its own" \
		sh -c 'test ! -e "$1/boot/vmlinux.bin" -a -f "$1/rootfs-6.18/boot/vmlinux.bin" -a "$(cat "$1/boot/slot.try")" = rootfs-6.18' - "$SIM"
	echo 00000000000000000000000000000000 > "$SIM/rootfs-6.18/boot/vmlinux.bin.md5"
	check "kernel does not match its md5: previous init this time" test "$(boot)" = previous
	check "next power-on: back to rootfs-b, failure noted" \
		sh -c 'test "$1" = "go rootfs-b rootfs-b/boot/vmlinux.bin" && test "$(cat "$2/boot/slot.failed")" = rootfs-6.18 -a ! -e "$2/boot/slot.try"' - "$(boot)" "$SIM"
	up rootfs-b

	echo "-- going back to the previous version"
	(cd "$SIM/rootfs-6.18/boot" && md5sum vmlinux.bin > vmlinux.bin.md5)
	nu switch >/dev/null
	check "relay boots rootfs-6.18 with its own kernel" test "$(boot)" = "go rootfs-6.18 rootfs-6.18/boot/vmlinux.bin"
	up rootfs-6.18
	check "rootfs-6.18 active again, rootfs-b kept as the other version" \
		sh -c 'test "$(cat "$1/boot/slot")" = rootfs-6.18 -a -f "$1/rootfs-b/sbin/init"' - "$SIM"
	check "relay.log tells the story" sh -c 'grep -q "trying rootfs-b once" "$1" && grep -q "trial of rootfs-b did not complete: back to rootfs-6.18" "$1"' - "$P/relay/relay.log"
done
for s in sh "busybox sh"; do
	command -v ${s% *} >/dev/null 2>&1 || continue
	check "syntax ($s): relay-switch, initramfs init, nas-update" \
		sh -c '$1 -n "$2" && $1 -n "$3" && $1 -n "$4"' - "$s" "$HERE/relay-switch" "$HERE/../initramfs/init" "$NU"
done
[ $FAILS = 0 ] && echo "== all checks passed" || { echo "== $FAILS check(s) failed"; exit 1; }
