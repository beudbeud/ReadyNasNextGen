/*
 * test-flush: I-cache coherency with rewritten code on the Padre.
 * Static, no division. Usage: test-flush [with|without] [rounds]
 *
 * An RWX page is filled with small "retl; mov v, %o0" functions.
 * Each round, a function is called (its line enters the I-cache),
 * rewritten with another value (as ld.so writes the PLT), followed or
 * not by "flush", then called again: the returned value must be the new one.
 *   with:    0 errors expected (correct kernel + flush); exit code 1 otherwise
 *   without: errors prove the hardware is NOT coherent (hence that the
 *            "with" test really measures something)
 * Each round also checks a floating-point computation right after the
 * flush (regression of test r: wrong floating point after ld.so's flushes).
 */
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

#define RETL	0x81c3e008u		/* jmpl %o7+8, %g0 */
#define MOV_O0	0x90102000u		/* or %g0, simm13, %o0 */
#define NFUNC	512			/* 8 bytes each: one page */

static void write_func(volatile unsigned int *f, unsigned int v, int flush)
{
	f[0] = RETL;
	f[1] = MOV_O0 | (v & 0xfff);
	if (flush) {
		__asm__ __volatile__("flush %0" : : "r" (&f[0]) : "memory");
		__asm__ __volatile__("flush %0" : : "r" (&f[1]) : "memory");
	}
}

int main(int argc, char **argv)
{
	int flush = !(argc > 1 && !strcmp(argv[1], "without"));
	unsigned int rounds = 20000, i, err = 0, errf = 0, v;
	unsigned int *page;

	if (argc > 2)
		sscanf(argv[2], "%u", &rounds);
	page = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
		    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (page == MAP_FAILED) {
		perror("mmap");
		return 2;
	}
	for (i = 0; i < NFUNC; i++)		/* clean initial state, always flush */
		write_func(page + 2 * i, 0xfff, 1);

	for (i = 0; i < rounds; i++) {
		unsigned int *f = page + 2 * ((i * 37) & (NFUNC - 1));
		int (*g)(void) = (int (*)(void))f;

		(void)g();			/* line loaded into the I-cache */
		v = (i & 0x7ff) + 1;		/* never 0xfff */
		write_func(f, v, flush);
		{
			volatile double x = v, y = 1.5;

			x = x * y + 0.25;
			if ((unsigned int)(x * 4.0) != 6 * v + 1)
				errf++;
		}
		if ((unsigned int)(g() & 0xfff) != v) {
			if (err < 5)
				printf("  round %u: expected %u, read old code\n", i, v);
			err++;
		}
	}
	printf("test-flush %s: %u rounds, %u errors, %u floating-point errors\n",
	       flush ? "with" : "without", rounds, err, errf);
	return (flush && err) || errf ? 1 : 0;
}
