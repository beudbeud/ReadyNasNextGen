// SPDX-License-Identifier: GPL-2.0
/*
 * gmpeek: read-only look at the Ethernet engine of the ReadyNAS Duo v1 while
 * the stock 2.6.17 system (RAIDiator or DIET) runs, to see how the original
 * driver drives the transmit checksum: registers, then the transmit ring in
 * ring order with the two command bytes of every "meta" descriptor.
 *
 * It only uses the register read call of the original driver (private ioctl
 * 0x89f2 on eth0: words read at "GMAC base + offset", any offset), so
 * nothing is written to the hardware. No libc: the stock system and our
 * toolchain do not share one.
 *
 *   output-rapide/host/bin/sparc-buildroot-linux-uclibc-gcc -Os -static \
 *       -nostdlib -ffreestanding -o gmpeek tools/gmpeek.c
 *
 *   gmpeek [snapshots [ram-MiB [s]]] > file     default: 1 snapshot, 64 MiB
 *     ram-MiB  command bytes are only read below that size of RAM
 *              (MemTotal of /proc/meminfo rounded up is fine)
 *     s        also read the GMT state register (+8); the original driver
 *              only reads it when it closes or times out
 *
 * Descriptor words: link, buffer, control, status. Control: 31 owned by the
 * engine, 29 first of frame, 27 interrupt, 26 meta, 25 last of frame,
 * 23-0 size (docs/DEVELOPMENT.md, "Network driver").
 */
typedef unsigned int u32;

#define GM_BASE		0x60010000u
#define SRAM		0x70001000u	/* 8 KiB of descriptors, bus 0x30001000 */
#define BUS2VIRT	0x40000000u

__asm__(".globl _start\n"
	"_start:\n"
	"	mov	%g0, %fp\n"
	"	ld	[%sp + 64], %o0\n"
	"	add	%sp, 68, %o1\n"
	"	call	cmain\n"
	"	 sub	%sp, 32, %sp\n"
	"	mov	1, %g1\n"
	"	ta	0x10\n");

static long sys(long nr, long a, long b, long c)
{
	register long g1 __asm__("g1") = nr;
	register long o0 __asm__("o0") = a;
	register long o1 __asm__("o1") = b;
	register long o2 __asm__("o2") = c;

	__asm__ volatile("ta 0x10\n\tbcc 1f\n\t nop\n\tsub %%g0, %%o0, %%o0\n1:"
			 : "+r" (o0) : "r" (g1), "r" (o1), "r" (o2) : "cc", "memory");
	return o0;
}

static char out[4096];
static unsigned int outn;

static void flush(void)
{
	sys(4, 1, (long)out, outn);		/* write */
	outn = 0;
}

static void putch(char c)
{
	out[outn++] = c;
	if (outn == sizeof(out))
		flush();
}

static void puts_(const char *s)
{
	while (*s)
		putch(*s++);
}

static void hex(u32 v, int digits)
{
	while (digits--)
		putch("0123456789abcdef"[(v >> (digits * 4)) & 15]);
}

static int sock;
static struct {
	char name[16];
	u32 *data;
	char pad[12];
} ifr = { "eth0" };
static u32 buf[2 + 16];

/* n <= 16 words at virtual address a, into buf + 2 */
static int peek(u32 a, u32 n)
{
	buf[0] = a - GM_BASE;
	buf[1] = n;
	ifr.data = buf;
	return sys(54, sock, 0x89f2, (long)&ifr);	/* ioctl */
}

static void dump(const char *tag, u32 a, u32 n)
{
	u32 i;

	puts_(tag);
	putch(' ');
	hex(a, 8);
	putch(':');
	if (peek(a, n) < 0) {
		puts_(" ioctl failed\n");
		return;
	}
	for (i = 0; i < n; i++) {
		putch(' ');
		hex(buf[2 + i], 8);
	}
	putch('\n');
}

static u32 num(const char *s)
{
	u32 v = 0;

	while (*s >= '0' && *s <= '9')
		v = (v << 3) + (v << 1) + (*s++ - '0');
	return v;
}

int cmain(int argc, char **argv)
{
	u32 shots = argc > 1 ? num(argv[1]) : 1;
	u32 ram = (argc > 2 ? num(argv[2]) : 64) << 20;
	u32 d, s, i, w[4];
	static const struct { long sec, nsec; } nap = { 0, 20000000 };

	static long sa[3] = { 2, 2, 0 };	/* AF_INET, SOCK_DGRAM, 0 */

	sock = sys(206, 1, (long)sa, 0);	/* socketcall(SYS_SOCKET): 2.6.17 has no socket (97) */
	if (sock < 0 || peek(GM_BASE + 0x400, 1) < 0) {
		puts_("gmpeek: no eth0 or no 0x89f2 ioctl (not the stock driver?)\n");
		flush();
		return 1;
	}
	dump("gmac", GM_BASE + 0x400, 12);	/* CTRL ... +0x42c */
	dump("gmt ", 0x60005040, 2);		/* mode, segment size */
	if (argc > 3)
		dump("gmt8", 0x60005048, 1);
	dump("m4  ", 0x60000700, 10);		/* rx ctrl/head/filters, flow, tx ctrl/head */
	dump("m4ir", 0x600007e0, 2);		/* pending, mask */
	dump("ff0 ", 0x60002800, 1);		/* MC DMA FFCTRL, RX and TX */
	dump("ff1 ", 0x60002810, 1);
	for (s = 0; s < shots; s++) {
		if (peek(0x60000724, 1) < 0)
			break;
		d = buf[2] + BUS2VIRT;		/* head of the transmit ring */
		puts_("tx ring, snapshot ");
		hex(s, 2);
		putch('\n');
		for (i = 0; i < 128 && d >= SRAM && d < SRAM + 0x2000 && !(d & 15); i++) {
			if (peek(d, 4) < 0)
				break;
			w[0] = buf[2];
			w[1] = buf[3];
			w[2] = buf[4];
			w[3] = buf[5];
			hex(i, 2);
			putch(' ');
			hex(d, 8);
			putch(':');
			putch(' ');
			hex(w[0], 8);
			putch(' ');
			hex(w[1], 8);
			putch(' ');
			hex(w[2], 8);
			putch(' ');
			hex(w[3], 8);
			/* command bytes {old, new} of a meta descriptor */
			/* bit 26 is gone once the engine is done: size 2 then */
			if (((w[2] & (1u << 26)) || (w[2] & 0xffffff) == 2) && w[1] >= 0x40000000u &&
			    w[1] - 0x40000000u < ram - 4 && peek((w[1] & ~3u) + BUS2VIRT, 1) >= 0) {
				puts_(" meta word ");	/* the 2 bytes start at byte (buffer & 3) */
				hex(buf[2], 8);
			}
			putch('\n');
			d = w[0] + BUS2VIRT;
		}
		flush();
		sys(249, (long)&nap, 0, 0);	/* nanosleep, 20 ms */
	}
	flush();
	return 0;
}
