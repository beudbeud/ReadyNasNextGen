/*
 * windows: debugging test (9th test). Causes register window overflows
 * (deep recursion) and a fresh stack page, then sleeps, then returns:
 * "windows OK n" if everything came back.
 *   windows 1: recursion 64 + nanosleep 0.1 s
 *   windows 2: recursion 64 + nanosleep 1 s
 *   windows 3: 256 KiB of fresh stack touched right before nanosleep 1 s
 * Built static by the readynas-initramfs package (Buildroot toolchain).
 */
#include <stdio.h>
#include <time.h>
#include <unistd.h>

static volatile int sink;

static void sleep_ns(long ns)
{
	struct timespec t = { ns / 1000000000L, ns % 1000000000L };

	nanosleep(&t, NULL);
}

static int __attribute__((noinline)) rec(int n, long ns)
{
	volatile char buf[64];
	int r;

	buf[0] = (char)n;
	if (n == 0) {
		sleep_ns(ns);
		return buf[0];
	}
	r = rec(n - 1, ns) + buf[0];
	sink = r;
	return r;
}

static void __attribute__((noinline)) fresh_page(void)
{
	volatile char big[256 * 1024];
	unsigned int i;

	for (i = 0; i < sizeof(big); i += 4096)
		big[i] = (char)i;
	sleep_ns(1000000000L);
	sink = big[0] + big[sizeof(big) - 4096];
}

int main(int argc, char **argv)
{
	char m = argc > 1 ? argv[1][0] : '1';

	printf("windows %c: start\n", m);
	fflush(stdout);
	if (m == '1')
		rec(64, 100000000L);
	else if (m == '2')
		rec(64, 1000000000L);
	else
		fresh_page();
	printf("windows OK %c\n", m);
	return 0;
}
