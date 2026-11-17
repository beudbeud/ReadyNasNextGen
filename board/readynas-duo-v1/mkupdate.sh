#!/bin/sh
# Builds the system update package installed from the web interface (nas-update):
#   mkupdate.sh [IMAGES [OUT]]    (default: output-rapide/images, written next to it)
#   VERSION=x.y                   (default: git describe, else the date)
# Package readynasng-update-<VERSION>.tar (uncompressed tar, in this order):
#   manifest        VERSION=<version>, ROOTFS_KB=<room taken once extracted>
#   SHA256SUMS      sha256sum of the two files below
#   rootfs.tar.gz   the system (rootfs.tar)
#   vmlinux.bin     the raw kernel started by the relay
# plus readynasng-update-<VERSION>.tar.sha256, the SHA-256 to give with a URL.
set -eu
TOP=$(cd "$(dirname "$0")/../.." && pwd)
IMG=${1:-$TOP/output-rapide/images}
OUT=${2:-$IMG}
VERSION=${VERSION:-$(git -C "$TOP" describe --tags --always --dirty 2>/dev/null || date +%Y%m%d)}
case $VERSION in ''|*[!A-Za-z0-9._+-]*) echo "VERSION: letters, digits, . _ + - only" >&2; exit 1;; esac
for f in rootfs.tar vmlinux.bin; do [ -f "$IMG/$f" ] || { echo "$IMG/$f missing: build first (make rapide)" >&2; exit 1; }; done

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
gzip -9n < "$IMG/rootfs.tar" > "$T/rootfs.tar.gz"
cp "$IMG/vmlinux.bin" "$T/"
# room on an ext3 stick: 4 KiB blocks, plus one per entry (inode, directory)
KB=$(tar -tvf "$IMG/rootfs.tar" | awk '{ s += int(($3 + 4095) / 4096) * 4 + 1 } END { print s }')
printf 'VERSION=%s\nROOTFS_KB=%s\n' "$VERSION" "$KB" > "$T/manifest"
(cd "$T" && sha256sum rootfs.tar.gz vmlinux.bin > SHA256SUMS)
P=$OUT/readynasng-update-$VERSION.tar
tar --format=gnu --owner=0 --group=0 --numeric-owner -C "$T" -cf "$P" manifest SHA256SUMS rootfs.tar.gz vmlinux.bin
(cd "$OUT" && sha256sum "${P##*/}" > "${P##*/}.sha256")
echo "$P: $(stat -c %s "$P") bytes, version $VERSION, $((KB / 1024)) MB once installed"
echo "SHA-256: $(cut -d' ' -f1 "$P.sha256")"
