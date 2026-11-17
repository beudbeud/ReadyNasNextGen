#!/bin/sh
# Builds padre_relay.ko for the stock kernel of the ReadyNAS Duo v1
# (2.6.17.14ReadyNAS, gcc 3.3) in NETGEAR's SPARC compile environment run by
# QEMU in Docker. See README.md ("Building the module").
#
# Downloads (once, into dl/relay/, checked by SHA-256):
#   - NETGEAR's GPL archive for RAIDiator 4.1.6 (linux-2.6.17.8 tree, arch/padre)
#   - NETGEAR's ReadyNAS SPARC compile environment (QEMU image, gcc 3.3.5)
# Local copies: GPL_ZIP=/path/RNR4_RND4_RND2_4.1.6_WW_src.zip,
#   QCOW_GZ=/path/readynas_compile_environment.qcow.gz (or QCOW=/path/... already
#   decompressed). Output: output-relay/padre_relay.ko (+ build.log, qemu.log).
# Host requirements: docker, e2fsprogs (mke2fs -d, debugfs), unzip, curl.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../../.." && pwd)
DL=${DL:-$TOP/dl/relay}
OUT=${OUT:-$TOP/output-relay}

GPL_NAME=RNR4_RND4_RND2_4.1.6_WW_src.zip
GPL_SHA256=50527f397c77396d884283801f87bb6f3cf0d30eeab0222e323bd60d4e107314
GPL_URL=https://sourceforge.net/projects/officialnetgearfirmware/files/ReadyNAS/$GPL_NAME/download
QCOW_NAME=readynas_compile_environment.qcow.gz
QCOW_SHA256=c2b27587e0e7767ccd8c99144bfeaba153a5bfeec2c096b923766a3b49c72b75
QCOW_URL=https://www.readynas.com/download/development/$QCOW_NAME
QCOW_MIRROR=https://web.archive.org/web/20250627172432id_/https://www.readynas.com/download/development/$QCOW_NAME

GPL_ZIP=${GPL_ZIP:-$DL/$GPL_NAME}
QCOW_GZ=${QCOW_GZ:-$DL/$QCOW_NAME}
QCOW=${QCOW:-$DL/readynas_compile_environment.qcow}

fetch() {	# fetch <file> <sha256> <url>...
	f=$1; sum=$2; shift 2
	if [ ! -f "$f" ]; then
		mkdir -p "$(dirname "$f")"
		for u in "$@"; do
			echo "== downloading $u"
			curl -fL --retry 3 -o "$f.part" "$u" && mv "$f.part" "$f" && break
		done
		[ -f "$f" ] || { echo "cannot download $(basename "$f")" >&2; exit 1; }
	fi
	echo "$sum  $f" | sha256sum -c -
}

fetch "$GPL_ZIP" $GPL_SHA256 "$GPL_URL"
if [ ! -f "$QCOW" ]; then
	fetch "$QCOW_GZ" $QCOW_SHA256 "$QCOW_URL" "$QCOW_MIRROR"
	mkdir -p "$(dirname "$QCOW")"
	gzip -dc "$QCOW_GZ" > "$QCOW.part" && mv "$QCOW.part" "$QCOW"
fi

# Work disk: GPL tree (KERNELRELEASE 2.6.17.14ReadyNAS like the stock kernel:
# EXTRAVERSION .14 + CONFIG_LOCALVERSION="ReadyNAS" of arch/padre/defconfig),
# the stock kernel's CRCs, the module sources, guest.sh. The paths in the
# guest (/mnt/linux, /mnt/src/padre_relay) end up in the module: keep them.
W=$OUT/work
rm -rf "$W" "$OUT/out" "$OUT/work.ext2"
mkdir -p "$W/src" "$W/out"
unzip -q "$GPL_ZIP" 'linux-2.6.17.8/*' -d "$W"
mv "$W/linux-2.6.17.8" "$W/linux"
sed -i 's/^EXTRAVERSION = .*/EXTRAVERSION = .14/' "$W/linux/Makefile"
cp "$HERE/Module.symvers" "$W/linux/"
cp -r "$HERE/padre_relay" "$W/src/"
cp "$HERE/build/guest.sh" "$W/"
# 128-byte inodes for the guest's 2.6.18 kernel
mke2fs -q -t ext2 -I 128 -b 4096 -d "$W" "$OUT/work.ext2" 1200M 2>/dev/null
rm -rf "$W"

docker image inspect rnng-qemu-sparc >/dev/null 2>&1 || docker build -t rnng-qemu-sparc "$HERE/build"
echo "== building in QEMU (about 10 minutes), console in $OUT/qemu.log"
docker run --rm -v "$QCOW:/img/compile_environment.qcow:ro" -v "$OUT:/work" \
	-v "$HERE/build/qemu.exp:/qemu.exp:ro" rnng-qemu-sparc expect -f /qemu.exp > "$OUT/qemu.log" 2>&1 || true

debugfs -R "rdump /out $OUT" "$OUT/work.ext2" 2>/dev/null
rm -f "$OUT/work.ext2" "$OUT/padre_relay.ko"
cp "$OUT/out/build.log" "$OUT/"
tail -4 "$OUT/build.log"
grep -q '^== BUILD OK' "$OUT/build.log" || { echo "build failed, see $OUT/build.log and $OUT/qemu.log" >&2; exit 1; }
cp "$OUT/out/padre_relay.ko" "$OUT/"
rm -rf "$OUT/out"
md5sum "$OUT/padre_relay.ko"
