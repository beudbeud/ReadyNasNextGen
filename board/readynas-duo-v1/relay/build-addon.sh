#!/bin/sh
# Builds the RAIDiator 4.1 add-ons of the relay from padre_relay.ko:
#   output-relay/ReadyNasNextGen_relay_<VERSION>.bin         installs the relay
#   output-relay/ReadyNasNextGen_relay_remove_<VERSION>.bin  removes it
# Format (same as DIET's build_addon.sh): a 512-byte header
#   "addon::name=..,version=..,time=..,size=<bytes>,md5sum=<md5>,unencrypted=1\n"
# zero padded (bytes 384-511 would be NETGEAR's signature: left empty, RAIDiator
# warns "not signed" and installs anyway), then an uncompressed tar holding
# install.sh. size and md5sum are those of everything after the header.
# KO=/path/padre_relay.ko (default output-relay/padre_relay.ko), VERSION=x.y.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../../.." && pwd)
OUT=${OUT:-$TOP/output-relay}
KO=${KO:-$OUT/padre_relay.ko}
VERSION=${VERSION:-1.1}
[ -f "$KO" ] || { echo "$KO not found: run 'make relay' first (or KO=/path/padre_relay.ko)" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

mkbin() {	# mkbin <name> <directory> <output>
	tar --format=gnu --owner=0 --group=0 --numeric-owner -C "$2" -cf "$T/payload.tar" .
	size=$(stat -c %s "$T/payload.tar")
	md5=$(md5sum < "$T/payload.tar" | cut -d' ' -f1)
	hdr="addon::name=$1,version=$VERSION,time=$(date +%s),size=$size,md5sum=$md5,unencrypted=1"
	[ ${#hdr} -lt 384 ] || { echo "header too long" >&2; exit 1; }
	{ printf '%s\n' "$hdr"; head -c $((512 - ${#hdr} - 1)) /dev/zero; cat "$T/payload.tar"; } > "$3"
	# same check as Frontview
	[ "$(dd if="$3" skip=1 bs=512 2>/dev/null | md5sum | cut -d' ' -f1)" = "$md5" ]
	echo "$3: $(stat -c %s "$3") bytes, md5 $md5"
}

I=$T/ReadyNasNextGen_relay
D=$T/ReadyNasNextGen_relay_remove
mkdir -p "$I" "$D" "$OUT"
cp "$HERE/addon/install.sh" "$HERE/relay-switch" "$HERE/relay-init" "$I/"
cp "$KO" "$I/padre_relay.ko"
echo "$VERSION" > "$I/relay-version"
cp "$HERE/addon/remove.sh" "$D/install.sh"
chmod 755 "$I/install.sh" "$I/relay-switch" "$I/relay-init" "$D/install.sh"
chmod 644 "$I/padre_relay.ko" "$I/relay-version"

mkbin ReadyNasNextGen_relay "$I" "$OUT/ReadyNasNextGen_relay_$VERSION.bin"
mkbin ReadyNasNextGen_relay_remove "$D" "$OUT/ReadyNasNextGen_relay_remove_$VERSION.bin"
