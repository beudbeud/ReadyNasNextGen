/*
 * essai-fp : même programme construit en statique (essai-fp-s) et en
 * dynamique PIE (essai-fp-d) pour comparer l'émulation FPU du noyau Padre.
 * Chaque étape affiche le double en hexadécimal (attendu entre crochets),
 * puis OK/FAUX, sans dépendre de printf("%f") sauf à l'étape 9.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int faux;

static void h(const char *nom, double d, unsigned int ah, unsigned int al)
{
	union { double d; unsigned int w[2]; } u;

	u.d = d;
	printf("%-28s %08x %08x [%08x %08x] %s\n", nom, u.w[0], u.w[1], ah, al,
	       u.w[0] == ah && u.w[1] == al ? "OK" : "FAUX");
	faux += !(u.w[0] == ah && u.w[1] == al);
}

static void b(const char *nom, int v, int attendu)
{
	printf("%-28s %d [%d] %s\n", nom, v, attendu, v == attendu ? "OK" : "FAUX");
	faux += v != attendu;
}

int main(void)
{
	volatile double un = 1.0, deux = 2.0, trois = 3.0, zero = 0.0;
	volatile double r;
	volatile int i = 7;
	char t[32];

	h("1 strtod(\"1.5\")", strtod("1.5", NULL), 0x3ff80000, 0);
	h("2 strtod(\"2\")", strtod("2", NULL), 0x40000000, 0);
	h("3 strtod(\"2\") (2e appel)", strtod("2", NULL), 0x40000000, 0);
	r = un + un;
	h("4 1.0+1.0", r, 0x40000000, 0);
	r = trois / deux;
	h("5 3.0/2.0", r, 0x3ff80000, 0);
	r = i;
	h("6 (double)7 (fitod)", r, 0x401c0000, 0);
	b("7 (int)(3.0/2.0) (fdtoi)", (int)(trois / deux), 1);
	b("8a 1.0 < 2.0", un < deux, 1);
	b("8b 2.0 < 1.0", deux < un, 0);
	b("8c 1.0 == 1.0", un == un, 1);
	b("8d 2.0 != 0.0", deux != zero, 1);
	b("8e 2.0 >= 2.0", deux >= deux, 1);
	r = 0.1;	/* constante en .rodata (adresse PIC dans essai-fp-d) */
	h("8f constante 0.1", r, 0x3fb99999, 0x9999999a);
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
	       strcmp(t, "1.50") ? "FAUX" : "OK");
	faux += strcmp(t, "1.50") != 0;
	snprintf(t, sizeof(t), "%g", 2.5e9);
	printf("%-28s %s [2.5e+09] %s\n", "10 printf(\"%g\", 2.5e9)", t,
	       strcmp(t, "2.5e+09") ? "FAUX" : "OK");
	faux += strcmp(t, "2.5e+09") != 0;
	printf("essai-fp : %d étape(s) fausse(s)\n", faux);
	return faux != 0;
}
