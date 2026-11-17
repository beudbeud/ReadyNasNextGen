#!/bin/sh
# Runs INSIDE the QEMU guest (Debian SPARC, gcc 3.3.5), work disk mounted on /mnt.
# Prepares the NETGEAR 2.6.17 tree with arch/padre/defconfig, checks that it
# gives the same symbol CRCs as the stock kernel (Module.symvers), builds
# /mnt/src/padre_relay and checks the module.
K=/mnt/linux
MK="make ARCH=padre CROSS_COMPILE="
echo "== tools"; gcc --version | head -1; as --version | head -1; make --version | head -1
cd $K || exit 1
echo "== preparing the tree"
cp arch/padre/defconfig .config
yes '' | $MK oldconfig >/dev/null || exit 1
$MK modules_prepare || exit 1
echo "== KERNELRELEASE: $($MK -s kernelrelease)"

# The CRCs in Module.symvers are those of the stock kernel. The ones exported
# by these objects are recomputed by genksyms from the tree: a difference means
# the configured tree does not match the running kernel (structure layouts).
echo "== genksyms CRCs of the tree vs Module.symvers"
OBJS="kernel/printk.o kernel/kallsyms.o kernel/module.o lib/vsprintf.o arch/padre/kernel/sparc_ksyms.o"
$MK $OBJS >/dev/null 2>&1 || $MK $OBJS || exit 1
for o in $OBJS; do nm $o | sed -n 's/^\([0-9a-f]*\) A __crc_\(.*\)/0x\1 \2/p'; done > /mnt/out/crc-tree.txt
ERR=0; n=0
while read crc sym rest; do
	t=`sed -n "s/^\(0x[0-9a-f]*\) $sym\$/\1/p" /mnt/out/crc-tree.txt`
	[ -n "$t" ] || continue
	n=`expr $n + 1`
	[ "$t" = "$crc" ] || { echo "ERROR: CRC of $sym: tree $t, stock kernel $crc"; ERR=1; }
done < Module.symvers
echo "$n CRCs compared"
[ $n -gt 0 ] || ERR=1

d=/mnt/src/padre_relay
echo "== module $d"
$MK -C $K M=$d modules > $d/make.log 2>&1 || ERR=1
cat $d/make.log
grep -q 'undefined!' $d/make.log && { echo "ERROR: undefined symbol (missing from Module.symvers)"; ERR=1; }
ko=$d/padre_relay.ko
if [ -f $ko ]; then
	strings -a $ko | grep '^vermagic='
	strings -a $ko | grep -q '^vermagic=2.6.17.14ReadyNAS mod_unload gcc-3.3$' || { echo "ERROR: vermagic"; ERR=1; }
	# sdiv is wrong on the IT3107: no hardware mul/div instruction at all
	n=`objdump -d $ko | grep -cE '[[:space:]](sdiv|udiv|smul|umul)(cc)?[[:space:]]'`
	echo "hardware mul/div instructions: $n"
	[ "$n" = 0 ] || { echo "ERROR: hardware mul/div instruction"; ERR=1; }
	cp $ko /mnt/out/
else
	ERR=1
fi
[ $ERR = 0 ] && echo "== BUILD OK" || echo "== BUILD ERROR"
