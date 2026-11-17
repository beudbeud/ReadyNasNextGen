/*
 * test-align: unaligned integer accesses in user space (the Padre kernel
 * emulates them; stock sparc32 sends SIGBUS) and uClibc malloc alignment.
 * Static, no division. Exit code 0 = all OK.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int wrong;

static void ok(const char *name, int good)
{
	printf("%-36s %s\n", name, good ? "OK" : "WRONG");
	wrong += !good;
}

int main(void)
{
	static unsigned char b[32] __attribute__((aligned(8)));
	unsigned int hi, lo, v;
	int i, s, bad = 0;
	void *p;

	for (i = 0; i < 32; i++)
		b[i] = i + 1;
	/* ldd on a 4-byte (not 8-byte) aligned address: fixed %o2/%o3 */
	__asm__ __volatile__("ldd [%2], %%o2\n\tmov %%o2, %0\n\tmov %%o3, %1"
			     : "=r" (hi), "=r" (lo) : "r" (b + 4) : "o2", "o3");
	ok("ldd [addr%8 == 4]", hi == 0x05060708 && lo == 0x090a0b0c);
	/* ldd into %l2/%l3 (window registers) */
	__asm__ __volatile__("ldd [%2], %%l2\n\tmov %%l2, %0\n\tmov %%l3, %1"
			     : "=r" (hi), "=r" (lo) : "r" (b + 12) : "l2", "l3");
	ok("ldd [addr%8 == 4] -> %l2/%l3", hi == 0x0d0e0f10 && lo == 0x11121314);
	__asm__ __volatile__("ld [%1], %0" : "=r" (v) : "r" (b + 2));
	ok("ld [addr%4 == 2]", v == 0x03040506);
	__asm__ __volatile__("lduh [%1], %0" : "=r" (v) : "r" (b + 1));
	ok("lduh [odd addr]", v == 0x0203);
	b[20] = 0xff; b[21] = 0xfe;
	__asm__ __volatile__("ldsh [%1], %0" : "=r" (s) : "r" (b + 20));
	ok("ldsh [addr%4 == 0, signed]", s == (short)0xfffe);
	__asm__ __volatile__("ldsh [%1], %0" : "=r" (s) : "r" (b + 21));
	ok("ldsh [odd addr]", s == (short)0xfe17);
	__asm__ __volatile__("mov %0, %%o2\n\tmov %1, %%o3\n\tstd %%o2, [%2]"
			     : : "r" (0xa1a2a3a4), "r" (0xb1b2b3b4), "r" (b + 4)
			     : "o2", "o3", "memory");
	ok("std [addr%8 == 4]", b[4] == 0xa1 && b[7] == 0xa4 && b[8] == 0xb1 && b[11] == 0xb4);
	__asm__ __volatile__("st %0, [%1]" : : "r" (0xc1c2c3c4), "r" (b + 13) : "memory");
	ok("st [odd addr]", b[13] == 0xc1 && b[16] == 0xc4);
	__asm__ __volatile__("sth %0, [%1]" : : "r" (0xd1d2), "r" (b + 25) : "memory");
	ok("sth [odd addr]", b[25] == 0xd1 && b[26] == 0xd2);

	for (i = 1; i <= 4096; i += (i < 64 ? 1 : 61)) {
		p = malloc(i);
		bad |= ((unsigned long)p & 7) != 0;
		free(p);
	}
	ok("malloc(1..4096) 8-byte aligned", !bad);
	ok("posix_memalign(4096)", !posix_memalign(&p, 4096, 8192) &&
	   !((unsigned long)p & 4095));
	printf("test-align: %d wrong\n", wrong);
	return wrong != 0;
}
