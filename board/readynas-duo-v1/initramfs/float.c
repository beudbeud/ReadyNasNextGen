/*
 * float: step-by-step test of the kernel FPU emulation (the Padre has no
 * FPU: every floating-point instruction traps as fp_disabled and is emulated).
 * Each step announces itself BEFORE running, then prints its result: the
 * last "tN ..." line without "OK" points at the fatal instruction.
 * Instructions are forced in assembly to know exactly what gets emulated.
 * Built static by the readynas-initramfs package (Buildroot toolchain).
 */
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void say(const char *s)
{
	write(1, s, strlen(s));
}

static void hex(const char *name, unsigned int v)
{
	static const char h[] = "0123456789abcdef";
	char t[12];
	int i;

	for (i = 0; i < 8; i++)
		t[i] = h[(v >> (28 - 4 * i)) & 15];
	t[8] = 0;
	say(name);
	say(t);
}

static void ok(int good)
{
	say(good ? " OK\n" : " WRONG\n");
}

int main(void)
{
	static double a = 1.5, b = 0.0, c = 2.0, r;
	static int i = 3, j;
	static unsigned int fsr;
	int lt;

	say("float t1 ldd/std %f0 ...");
	__asm__ __volatile__("ldd [%0], %%f0\n\tstd %%f0, [%1]"
			     : : "r" (&a), "r" (&b) : "memory");
	ok(memcmp(&a, &b, 8) == 0);

	say("float t1b ld/st %f1 + st %fsr ...");
	__asm__ __volatile__("ld [%0], %%f1\n\tst %%f1, [%1]\n\tst %%fsr, [%2]"
			     : : "r" (&i), "r" (&j), "r" (&fsr) : "memory");
	hex(" fsr ", fsr);
	ok(j == 3);

	say("float t2 fitod/fdtoi ...");
	__asm__ __volatile__("ld [%0], %%f2\n\tfitod %%f2, %%f4\n\t"
			     "fdtoi %%f4, %%f6\n\tst %%f6, [%1]"
			     : : "r" (&i), "r" (&j) : "memory");
	ok(j == 3);

	say("float t3 faddd ...");
	__asm__ __volatile__("ldd [%0], %%f0\n\tldd [%1], %%f2\n\t"
			     "faddd %%f0, %%f2, %%f4\n\tstd %%f4, [%2]"
			     : : "r" (&a), "r" (&c), "r" (&r) : "memory");
	ok(r == 3.5);

	say("float t4 fmuld ...");
	__asm__ __volatile__("ldd [%0], %%f0\n\tldd [%1], %%f2\n\t"
			     "fmuld %%f0, %%f2, %%f4\n\tstd %%f4, [%2]"
			     : : "r" (&a), "r" (&c), "r" (&r) : "memory");
	ok(r == 3.0);

	say("float t5 fdivd ...");
	__asm__ __volatile__("ldd [%0], %%f0\n\tldd [%1], %%f2\n\t"
			     "fdivd %%f0, %%f2, %%f4\n\tstd %%f4, [%2]"
			     : : "r" (&a), "r" (&c), "r" (&r) : "memory");
	ok(r == 0.75);

	say("float t6 fcmpd + fbl ...");
	__asm__ __volatile__("ldd [%1], %%f0\n\tldd [%2], %%f2\n\t"
			     "fcmpd %%f0, %%f2\n\tnop\n\t"
			     "mov 1, %0\n\tfbl 1f\n\tnop\n\tmov 0, %0\n"
			     "1:"
			     : "=&r" (lt) : "r" (&a), "r" (&c) : "memory", "cc");
	ok(lt == 1);

	/* t6b/t6c: what busybox sleep does (sleep_for_duration) */
	say("float t6b fcmped + fbge ...");
	__asm__ __volatile__("ldd [%1], %%f8\n\tldd [%2], %%f10\n\t"
			     "fcmped %%f8, %%f10\n\tnop\n\t"
			     "mov 1, %0\n\tfbge 1f\n\tnop\n\tmov 0, %0\n"
			     "1:"
			     : "=&r" (lt) : "r" (&c), "r" (&a) : "memory", "cc");
	ok(lt == 1);

	say("float t6c fsubd on stack (ldd [%fp-16]) ...");
	{
		volatile double v = 1.25;

		__asm__ __volatile__("ldd [%1], %%f8\n\tfdtoi %%f8, %%f10\n\t"
				     "fitod %%f10, %%f10\n\tfsubd %%f8, %%f10, %%f8\n\t"
				     "std %%f8, [%0]"
				     : : "r" (&r), "r" (&v) : "memory");
		ok(r == 0.25);
	}

	say("float t7 strtod(\"1.5\")*1e9 ...");
	{
		volatile double d = strtod("1.5", NULL) * 1e9;
		long ns = (long)d;

		ok(ns == 1500000000L);
	}
	/* t8/t9: flush (bad_instruction trap -> padre_user_flush) then a
	 * floating-point computation, 200 times: regression of test r (after
	 * ld.so's flushes, wrong floating point in dynamic programs). t9 puts
	 * the address in %l0 (window register: "windows flushed" path of the
	 * padre_mm.flush=2 mode).
	 */
	say("float t8 flush (%o) then faddd x200 ...");
	{
		int n, good = 1;

		for (n = 0; n < 200; n++) {
			r = 0;
			__asm__ __volatile__("flush %3\n\tldd [%0], %%f0\n\tldd [%1], %%f2\n\t"
					     "faddd %%f0, %%f2, %%f4\n\tstd %%f4, [%2]"
					     : : "r" (&a), "r" (&c), "r" (&r), "r" (&main)
					     : "memory");
			good &= r == 3.5;
		}
		ok(good);
	}
	say("float t9 flush (%l0) then faddd x200 ...");
	{
		int n, good = 1;

		for (n = 0; n < 200; n++) {
			r = 0;
			__asm__ __volatile__("mov %3, %%l0\n\tflush %%l0\n\t"
					     "ldd [%0], %%f0\n\tldd [%1], %%f2\n\t"
					     "faddd %%f0, %%f2, %%f4\n\tstd %%f4, [%2]"
					     : : "r" (&a), "r" (&c), "r" (&r), "r" (&main)
					     : "memory", "l0");
			good &= r == 3.5;
		}
		ok(good);
	}
	say("float t10 strtod/printf after flush ...");
	{
		volatile double d;

		__asm__ __volatile__("flush %0" : : "r" (&main) : "memory");
		d = strtod("2", NULL) * strtod("1.5", NULL);
		ok((long)d == 3);
	}
	/* t11: fmovs/fnegs/fabss (result overwritten by IR before the fix:
	 * wrong printf("%f"), "1.5" -> "00000000000.00")
	 */
	say("float t11 fmovs/fnegs/fabss ...");
	{
		static double m = -2.5, x1, x2, x3;

		__asm__ __volatile__("ldd [%0], %%f0\n\t"
				     "fmovs %%f0, %%f2\n\tfmovs %%f1, %%f3\n\tstd %%f2, [%1]\n\t"
				     "fnegs %%f0, %%f4\n\tfmovs %%f1, %%f5\n\tstd %%f4, [%2]\n\t"
				     "fabss %%f0, %%f6\n\tfmovs %%f1, %%f7\n\tstd %%f6, [%3]"
				     : : "r" (&m), "r" (&x1), "r" (&x2), "r" (&x3) : "memory");
		ok(x1 == -2.5 && x2 == 2.5 && x3 == 2.5);
	}
	say("float END\n");
	return 0;
}
