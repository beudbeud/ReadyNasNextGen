/*
 * fenetres : test de mise au point (9e essai). Provoque des débordements
 * de fenêtres de registres (récursion profonde) et une page de pile neuve,
 * puis dort, puis revient : « fenetres OK n » si tout est revenu.
 *   fenetres 1 : récursion 64 + nanosleep 0,1 s
 *   fenetres 2 : récursion 64 + nanosleep 1 s
 *   fenetres 3 : 256 Ko de pile neuve touchés juste avant nanosleep 1 s
 * Construit statique par le paquet readynas-initramfs (chaîne Buildroot).
 */
#include <stdio.h>
#include <time.h>
#include <unistd.h>

static volatile int puits;

static void dormir(long ns)
{
	struct timespec t = { ns / 1000000000L, ns % 1000000000L };

	nanosleep(&t, NULL);
}

static int __attribute__((noinline)) rec(int n, long ns)
{
	volatile char tampon[64];
	int r;

	tampon[0] = (char)n;
	if (n == 0) {
		dormir(ns);
		return tampon[0];
	}
	r = rec(n - 1, ns) + tampon[0];
	puits = r;
	return r;
}

static void __attribute__((noinline)) page_neuve(void)
{
	volatile char gros[256 * 1024];
	unsigned int i;

	for (i = 0; i < sizeof(gros); i += 4096)
		gros[i] = (char)i;
	dormir(1000000000L);
	puits = gros[0] + gros[sizeof(gros) - 4096];
}

int main(int argc, char **argv)
{
	char m = argc > 1 ? argv[1][0] : '1';

	printf("fenetres %c : début\n", m);
	fflush(stdout);
	if (m == '1')
		rec(64, 100000000L);
	else if (m == '2')
		rec(64, 1000000000L);
	else
		page_neuve();
	printf("fenetres OK %c\n", m);
	return 0;
}
