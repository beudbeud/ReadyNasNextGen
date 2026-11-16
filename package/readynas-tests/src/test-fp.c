/*
 * test-fp: same program built static (test-fp-s), dynamic PIE (test-fp-d)
 * and dynamic non-PIE (test-fp-n) to compare the Padre kernel FPU emulation.
 * Each step prints the double in hexadecimal (expected value in brackets),
 * then OK/WRONG, without relying on printf("%f") except at step 9.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int wrong;

static void h(const char *name, double d, unsigned int ah, unsigned int al)
{
	union { double d; unsigned int w[2]; } u;

	u.d = d;
	printf("%-28s %08x %08x [%08x %08x] %s\n", name, u.w[0], u.w[1], ah, al,
	       u.w[0] == ah && u.w[1] == al ? "OK" : "WRONG");
	wrong += !(u.w[0] == ah && u.w[1] == al);
}

static void b(const char *name, int v, int expected)
{
	printf("%-28s %d [%d] %s\n", name, v, expected, v == expected ? "OK" : "WRONG");
	wrong += v != expected;
}

int main(void)
{
	volatile double one = 1.0, two = 2.0, three = 3.0, zero = 0.0;
	volatile double r;
	volatile int i = 7;
	char t[32];

	h("1 strtod(\"1.5\")", strtod("1.5", NULL), 0x3ff80000, 0);
	h("2 strtod(\"2\")", strtod("2", NULL), 0x40000000, 0);
	h("3 strtod(\"2\") (2nd call)", strtod("2", NULL), 0x40000000, 0);
	r = one + one;
	h("4 1.0+1.0", r, 0x40000000, 0);
	r = three / two;
	h("5 3.0/2.0", r, 0x3ff80000, 0);
	r = i;
	h("6 (double)7 (fitod)", r, 0x401c0000, 0);
	b("7 (int)(3.0/2.0) (fdtoi)", (int)(three / two), 1);
	b("8a 1.0 < 2.0", one < two, 1);
	b("8b 2.0 < 1.0", two < one, 0);
	b("8c 1.0 == 1.0", one == one, 1);
	b("8d 2.0 != 0.0", two != zero, 1);
	b("8e 2.0 >= 2.0", two >= two, 1);
	r = 0.1;	/* constant in .rodata (PIC address in test-fp-d) */
	h("8f constant 0.1", r, 0x3fb99999, 0x9999999a);
	{
		volatile double m = -2.5;
		double x;

		__asm__ __volatile__("ldd [%1], %%f0\n\tfnegs %%f0, %%f2\n\t"
				     "fmovs %%f1, %%f3\n\tstd %%f2, [%0]"
				     : : "r" (&x), "r" (&m) : "memory", "f0", "f1", "f2", "f3");
		h("8g fnegs+fmovs(-2.5)", x, 0x40040000, 0);
	}
	snprintf(t, sizeof(t), "%.2f", 1.5);
	printf("%-28s %s [1.50] %s\n", "9 printf(\"%.2f\", 1.5)", t,
	       strcmp(t, "1.50") ? "WRONG" : "OK");
	wrong += strcmp(t, "1.50") != 0;
	snprintf(t, sizeof(t), "%g", 2.5e9);
	printf("%-28s %s [2.5e+09] %s\n", "10 printf(\"%g\", 2.5e9)", t,
	       strcmp(t, "2.5e+09") ? "WRONG" : "OK");
	wrong += strcmp(t, "2.5e+09") != 0;
	printf("test-fp: %d wrong step(s)\n", wrong);
	return wrong != 0;
}
