#!/bin/sh
# Builds a ready-to-write USB stick image, without root:
#   mkstick.sh [IMAGES [OUT]]    (default: output-rapide/images, written next to it)
#   VERSION=x.y                  (default: git describe, else the date; as mkupdate.sh)
#   SIZE_MB=1024                 (whole image; the partition can be grown later)
# Output: readynasng-stick-<VERSION>.img, .img.xz (xz -T0 -9) and their .sha256.
# Layout: MBR, one primary Linux partition (type 83) from 1 MiB to the end, ext3
# "usbroot" readable by the stock 2.6.17 kernel (relay-switch) and by 6.18:
#   /rootfs-6.18/              rootfs.tar (owners kept through fakeroot), the first slot
#   /boot/vmlinux.bin(.md5)    kernel started by the relay
#   /README.txt                what to do with the stick
# The other slot (/rootfs-b) and /update are made later by nas-update.
set -eu
TOP=$(cd "$(dirname "$0")/../.." && pwd)
IMG=${1:-$TOP/output-rapide/images}
OUT=${2:-$IMG}
VERSION=${VERSION:-$(git -C "$TOP" describe --tags --always --dirty 2>/dev/null || date +%Y%m%d)}
SIZE_MB=${SIZE_MB:-1024}
case $VERSION in ''|*[!A-Za-z0-9._+-]*) echo "VERSION: letters, digits, . _ + - only" >&2; exit 1;; esac
case $SIZE_MB in ''|*[!0-9]*) echo "SIZE_MB: a number" >&2; exit 1;; esac
[ "$SIZE_MB" -ge 256 ] || { echo "SIZE_MB: 256 at least (two system slots and a package)" >&2; exit 1; }
for f in rootfs.tar vmlinux.bin; do [ -f "$IMG/$f" ] || { echo "$IMG/$f missing: build first (make rapide)" >&2; exit 1; }; done
FAKEROOT=$TOP/output-rapide/host/bin/fakeroot
[ -x "$FAKEROOT" ] || FAKEROOT=$(command -v fakeroot) || { echo "fakeroot missing" >&2; exit 1; }
PATH=$PATH:/sbin:/usr/sbin
for t in sfdisk mke2fs e2fsck debugfs dumpe2fs xz; do command -v $t >/dev/null || { echo "$t missing (util-linux, e2fsprogs, xz)" >&2; exit 1; }; done

T=$(mktemp -d)
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
NAME=readynasng-stick-$VERSION
P=$OUT/$NAME.img
START=2048                                  # sectors: partition aligned to 1 MiB
SECTORS=$((SIZE_MB * 2048))
BLOCKS=$(((SECTORS - START) / 8))           # 4 KiB blocks of the partition

# stick tree, built and turned into ext3 in one fakeroot session (owners, modes)
mkdir -p "$T/root/rootfs-6.18" "$T/root/boot"
cp "$IMG/vmlinux.bin" "$T/root/boot/"
(cd "$T/root/boot" && md5sum vmlinux.bin > vmlinux.bin.md5)
sed "s/@VERSION@/$VERSION/" > "$T/root/README.txt" <<'EOF'
ReadyNasNextGen @VERSION@ - USB stick for the NETGEAR ReadyNAS Duo v1
=====================================================================

This stick holds Linux 6.18 and the ReadyNasNextGen system. The NAS keeps
booting its original firmware (RAIDiator 4.1.x) from flash; the relay add-on,
installed on the NAS system disk, starts Linux 6.18 from this stick.

1. Write the image to a USB stick (1 GB or more), for example with Etcher, or
   on Linux:  xzcat readynasng-stick-@VERSION@.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync
2. Install the add-on ReadyNasNextGen_relay_<version>.bin on the NAS, from
   RAIDiator's web interface (System > Update > Local) or with
   tools/frontview-upload.sh, and let the NAS restart twice.
3. Plug this stick into the NAS and restart it. Without the stick, or after a
   failed start, the NAS starts RAIDiator as before.
4. First access, right after the first boot, from your local network: open
   https://<NAS-IP>/ and accept the self-signed certificate. A "First setup"
   page (shown only until it is done, no login) asks for the web interface
   administrator password (user admin) and the NAS name and, optionally, a
   root password and/or an SSH public key for ssh root@<NAS-IP> (SSH refuses
   root while it has neither). Both can be set later in Settings > SSH access.
   The system has no password and no key of its own; SSH host keys and the
   HTTPS certificate are created by the NAS at first boot: none are in this
   image. (Also possible: the serial console, root without a password.)

Layout (ext3, label usbroot; the 2.6.17 kernel of RAIDiator must read it, so
never convert it to ext4):
  /rootfs-6.18/              the system (first slot)
  /boot/vmlinux.bin (+ .md5) the kernel started by the relay
  /rootfs-b, /boot/slot...   made later by system updates from the web interface

The partition fills a 1 GB image. On a bigger stick it can be grown from a
Linux PC (stick not mounted):
  sudo growpart /dev/sdX 1    (or: parted /dev/sdX resizepart 1 100%)
  sudo e2fsck -f /dev/sdX1 && sudo resize2fs /dev/sdX1

Project, sources and licences: https://github.com/beudbeud/ReadyNasNextGen
EOF
cat > "$T/mkfs.sh" <<EOF
set -e
tar -xpf "$IMG/rootfs.tar" -C "$T/root/rootfs-6.18"
echo "$VERSION" > "$T/root/rootfs-6.18/etc/system-version"
chmod 644 "$T/root/rootfs-6.18/etc/system-version"
chown 0:0 "$T/root" "$T/root/rootfs-6.18" "$T/root/boot" "$T/root/boot/"* "$T/root/README.txt"
chmod 755 "$T/root" "$T/root/rootfs-6.18" "$T/root/boot"
chmod 644 "$T/root/boot/"* "$T/root/README.txt"
# ext3 as the 2.6.17 kernel knows it: incompat filetype (+recover/meta_bg), ro_compat
# sparse_super/large_file, compat has_journal/ext_attr/resize_inode/dir_index;
# 128-byte inodes. Anything newer (extent, flex_bg, 64bit, huge_file, dir_nlink,
# extra_isize, metadata_csum, orphan_file...) and 2.6.17 refuses to mount it.
mke2fs -q -F -t ext3 -b 4096 -I 128 -L usbroot -m 1 \
	-O none,has_journal,ext_attr,resize_inode,dir_index,filetype,sparse_super,large_file \
	-E root_owner=0:0 -d "$T/root" "$T/part.img" $BLOCKS
EOF
"$FAKEROOT" -- sh "$T/mkfs.sh"

rm -f "$P"
truncate -s $((SECTORS * 512)) "$P"
echo "start=$START, type=83" | sfdisk -q --label dos "$P"
dd if="$T/part.img" of="$P" bs=1M seek=1 conv=notrunc,sparse status=none

# checks, on the partition read back from the image
dd if="$P" of="$T/check.img" bs=1M skip=1 status=none
cmp "$T/part.img" "$T/check.img"
e2fsck -fn "$T/check.img" >/dev/null || { echo "e2fsck found errors" >&2; exit 1; }
FEAT=$(dumpe2fs -h "$T/check.img" 2>/dev/null | sed -n 's/^Filesystem features: *//p')
for f in $FEAT; do
	case $f in has_journal|ext_attr|resize_inode|dir_index|filetype|sparse_super|large_file) ;;
	*) echo "feature $f unknown to 2.6.17" >&2; exit 1;; esac
done
dumpe2fs -h "$T/check.img" 2>/dev/null | grep -q '^Inode size: *128$' || { echo "inodes are not 128 bytes" >&2; exit 1; }
dbg() { debugfs -R "$1" "$T/check.img" 2>/dev/null; }
# stat of a file: "uid gid mode" (octal permission bits)
own() { dbg "stat $1" | awk '{ for (i = 1; i < NF; i++) { if ($i == "Mode:") m = $(i + 1); if ($i == "User:") u = $(i + 1); if ($i == "Group:") g = $(i + 1) } } END { print u, g, m }'; }
for f in / /rootfs-6.18 /boot /rootfs-6.18/bin/busybox /rootfs-6.18/root; do
	case $(own "$f") in "0 0 "*) ;; *) echo "$f not owned by root: $(own "$f")" >&2; exit 1;; esac
done
[ "$(own /rootfs-6.18/etc/shadow)" = "0 0 0600" ] || { echo "/etc/shadow: $(own /rootfs-6.18/etc/shadow)" >&2; exit 1; }
dbg "dump /boot/vmlinux.bin $T/k" && cmp "$T/k" "$IMG/vmlinux.bin"
dbg "dump /boot/vmlinux.bin.md5 $T/k.md5" && (cd "$T" && sed 's/vmlinux.bin$/k/' k.md5 | md5sum -c --quiet)
[ "$(dbg 'ls -p /rootfs-6.18/sbin' | grep -c '/init/')" = 1 ] || { echo "no /rootfs-6.18/sbin/init" >&2; exit 1; }
# same file count as rootfs.tar (+ etc/system-version)
n=$(tar -tf "$IMG/rootfs.tar" | grep -vc '^\./$')
m=$(dbg 'rdump /rootfs-6.18 '"$T" >/dev/null; find "$T/rootfs-6.18" -mindepth 1 | wc -l)
[ "$m" = $((n + 1)) ] || { echo "rootfs-6.18: $m entries, rootfs.tar: $n" >&2; exit 1; }
echo "checked: e2fsck clean, features: $FEAT, owners, kernel md5, $m entries"

xz -T0 -9 -k -f "$P"
(cd "$OUT" && sha256sum "$NAME.img" > "$NAME.img.sha256" && sha256sum "$NAME.img.xz" > "$NAME.img.xz.sha256")
echo "$P: $SIZE_MB MiB, $P.xz: $(stat -c %s "$P.xz") bytes, version $VERSION"
