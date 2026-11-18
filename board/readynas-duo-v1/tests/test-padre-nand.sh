#!/bin/sh
# PC tests of padre_nand (shelved kernel patch, patches-shelved/linux/), the read-only NAND driver:
#  - the source taken from the patch cannot send anything but READ ID and READ0:
#    no write/erase method, never MTD_WRITEABLE, exactly two chip writes (command
#    and address latches), commands only through the pn_cmd() whitelist;
#  - the whitelist, compiled on the PC, accepts 0x00 and 0x90 and nothing else
#    (all 256 values tried);
#  - the ECC (same layout as the 2.6.17 nand_ecc.c, reference values computed
#    with it) and the correction of every single-bit error.
#   sh board/readynas-duo-v1/tests/test-padre-nand.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PATCH=$HERE/../patches-shelved/linux/padre_nand-read-only-nand-flash-for-backups.patch
T=$(mktemp -d "${TMPDIR:-/tmp}/padre-nand-test.XXXXXX")
FAILS=0; N=0
check() { N=$((N + 1)); if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAILS=$((FAILS + 1)); fi; }

C=$T/padre_nand.c
sed -n '/^+++ b\/drivers\/platform\/padre\/padre_nand.c$/,/^--- /{/^+++ /d;/^--- /d;/^@@ /d;s/^+//;p}' "$PATCH" > "$C"
code() { sed 's#/\*.*\*/##; s#//.*##' "$C" | grep -v '^[[:space:]]*\*'; }	# without comments

check "source extracted from the patch" '[ "$(wc -l < "$C")" -gt 300 ] && grep -q "^static int pn_read(" "$C"'
check "no write, erase, bad block marking, lock or OOB method" '! code | grep -Eq "\._(write|write_oob|erase|block_markbad|panic_write|lock|unlock|point|read_oob)[[:space:]]*="'
check "only _read is set" '[ "$(code | grep -Ec "\._[a-z_]+[[:space:]]*=")" = 1 ] && code | grep -q "pn_mtd\._read = pn_read;"'
check "MTD_WRITEABLE only masked out, flags = MTD_NO_ERASE" '[ "$(code | grep -c MTD_WRITEABLE)" = 2 ] && [ "$(code | grep MTD_WRITEABLE | grep -vc mask_flags)" = 0 ] && code | grep -q "pn_mtd\.flags = MTD_NO_ERASE;"'
check "exactly two writes to the chip: command latch in pn_cmd, address latch in pn_addr" '[ "$(code | grep -c "__raw_writeb(")" = 2 ] && code | grep -q "__raw_writeb(cmd, PN_CLE);" && code | grep -q "__raw_writeb(a, PN_ALE);" && ! code | grep -E "(writeb|iowrite8|writew|writel)\(" | grep -q PN_DATA'
check "only two command values defined (READ0 0x00, READID 0x90)" '[ "$(code | grep -c "^#define PN_CMD_")" = 2 ] && code | grep -q "^#define PN_CMD_READ0[[:space:]]*0x00$" && code | grep -q "^#define PN_CMD_READID[[:space:]]*0x90$"'
check "pn_cmd goes through the whitelist; pn_op only called with READ0 or READID" 'code | grep -A2 "^static void pn_cmd(" | grep -q "pn_cmd_allowed(cmd)" && [ -z "$(code | grep -o "pn_op([A-Za-z_0-9]*" | grep -v "pn_op(PN_CMD_READ0\|pn_op(PN_CMD_READID\|pn_op(unsigned")" ]'
check "no other command: no NAND_CMD_* macro, pn_cmd only reached from pn_op" '! code | grep -q "NAND_CMD_" && [ -z "$(code | grep -o "pn_cmd([^)]*)" | grep -vx "pn_cmd(cmd)\|pn_cmd(unsigned int cmd)")" ] && [ "$(code | grep -c "pn_cmd(cmd)")" = 1 ]'
op() { code | sed -n '/^static int pn_op(/,/^}/p'; }
check "pn_op: interrupts off, USB (EHCI) stopped before PCI goes off, PCI_FEATURE restored, USB restarted" 'op | grep -q spin_lock_irqsave && [ "$(op | grep -n "pn_usb_pause()" | cut -d: -f1)" -lt "$(op | grep -n "__raw_writel((feat" | cut -d: -f1)" ] && [ "$(op | grep -n "__raw_writel(feat, PN_PCI_FEAT);" | cut -d: -f1)" -lt "$(op | grep -n "pn_usb_resume(usb);" | cut -d: -f1)" ] && op | grep -B1 "break;" | grep -q "if (usb >= 0)" && [ "$(op | grep -c "break;")" = 1 ] && [ "$(op | grep -n "return -EBUSY" | cut -d: -f1)" -lt "$(op | grep -n "__raw_writel((feat" | cut -d: -f1)" ]'

# host build of the block between host-test-begin and host-test-end
{
	printf '#include <stdio.h>\n#include <string.h>\n#include <stdlib.h>\ntypedef unsigned char u8;\ntypedef int bool;\n'
	sed -n '/host-test-begin/,/host-test-end/p' "$C"
	cat <<'EOF'
static int fails;
#define T(c, m) do { if (!(c)) { printf("  %s\n", m); fails++; } } while (0)
int main(int argc, char **argv)
{
	u8 d[256], e[256], c[3], k[3];
	unsigned int v, i, j, n;

	if (argc > 1 && !strcmp(argv[1], "cmd")) {
		for (v = 0; v < 256; v++)
			T(pn_cmd_allowed(v) == (v == 0x00 || v == 0x90), "command whitelist");
		return fails != 0;
	}
	/* reference values: 2.6.17 nand_calculate_ecc() */
	for (i = 0; i < 256; i++) d[i] = 0;
	pn_ecc_calc(d, c); T(!memcmp(c, "\xff\xff\xff", 3), "ECC of zeros");
	d[37] = 0x10; pn_ecc_calc(d, c); T(!memcmp(c, "\xa6\x99\x6b", 3), "ECC vector 1");
	for (i = 0; i < 256; i++) d[i] = (i * 13 + (i >> 3)) & 0xff;
	pn_ecc_calc(d, c); T(!memcmp(c, "\xf0\x00\xff", 3), "ECC vector 2");
	srand(7);
	for (n = 0; n < 50; n++) {
		for (i = 0; i < 256; i++) d[i] = rand();
		pn_ecc_calc(d, c);
		memcpy(e, d, 256); T(pn_ecc_correct(e, c, c) == 0, "clean");
		for (i = 0; i < 2048; i++) {	/* every single data bit */
			memcpy(e, d, 256); e[i >> 3] ^= 1 << (i & 7);
			pn_ecc_calc(e, k);
			T(pn_ecc_correct(e, c, k) == 1 && !memcmp(e, d, 256), "single bit corrected");
		}
		for (i = 0; i < 24; i++) {	/* a bit of the stored code */
			u8 r[3]; memcpy(r, c, 3); r[i / 8] ^= 1 << (i % 8);
			memcpy(e, d, 256); pn_ecc_calc(e, k);
			T(pn_ecc_correct(e, r, k) == 1 && !memcmp(e, d, 256), "code bit");
		}
		for (j = 0; j < 200; j++) {	/* two data bits: detected, never "corrected" */
			unsigned int a = rand() % 2048, b = rand() % 2048;
			if (a == b) continue;
			memcpy(e, d, 256); e[a >> 3] ^= 1 << (a & 7); e[b >> 3] ^= 1 << (b & 7);
			pn_ecc_calc(e, k);
			T(pn_ecc_correct(e, c, k) == -1, "double bit detected");
		}
	}
	return fails != 0;
}
EOF
} > "$T/host.c"
check "host build of the whitelist and the ECC" 'gcc -O1 -Wall -Wno-unused-function -o "$T/host" "$T/host.c" 2> "$T/cc.log" || { cat "$T/cc.log"; false; }'
check "whitelist: of the 256 command values only 0x00 and 0x90 pass" '"$T/host" cmd'
check "ECC: 2.6.17 reference values, every single-bit error corrected, double errors detected" '"$T/host"'

echo "$((N - FAILS))/$N tests passed"
[ $FAILS -eq 0 ] && rm -rf "$T"
[ $FAILS -eq 0 ]
