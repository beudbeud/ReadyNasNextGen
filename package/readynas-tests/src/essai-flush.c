/*
 * essai-flush : cohérence antémémoire I / code réécrit sur le Padre.
 * Statique, sans division. Usage : essai-flush [avec|sans] [tours]
 *
 * Une page RWX est remplie de petites fonctions « retl ; mov v, %o0 ».
 * À chaque tour, une fonction est appelée (sa ligne entre dans
 * l'antémémoire I), réécrite avec une autre valeur (comme ld.so écrit la
 * PLT), suivie ou non de « flush », puis rappelée : la valeur rendue doit
 * être la nouvelle.
 *   avec : 0 erreur attendue (noyau + flush corrects) ; code de sortie 1 sinon
 *   sans : des erreurs prouvent que le matériel n'est PAS cohérent (donc
 *          que l'essai « avec » mesure bien quelque chose)
 * Chaque tour vérifie aussi un calcul flottant juste après le flush
 * (régression de l'essai r : flottant faux après les flush de ld.so).
 */
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

#define RETL	0x81c3e008u		/* jmpl %o7+8, %g0 */
#define MOV_O0	0x90102000u		/* or %g0, simm13, %o0 */
#define NFONC	512			/* 8 octets chacune : une page */

static void ecrit(volatile unsigned int *f, unsigned int v, int flush)
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
	int flush = !(argc > 1 && !strcmp(argv[1], "sans"));
	unsigned int tours = 20000, i, err = 0, errf = 0, v;
	unsigned int *page;

	if (argc > 2)
		sscanf(argv[2], "%u", &tours);
	page = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
		    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (page == MAP_FAILED) {
		perror("mmap");
		return 2;
	}
	for (i = 0; i < NFONC; i++)		/* état initial propre, toujours flush */
		ecrit(page + 2 * i, 0xfff, 1);

	for (i = 0; i < tours; i++) {
		unsigned int *f = page + 2 * ((i * 37) & (NFONC - 1));
		int (*g)(void) = (int (*)(void))f;

		(void)g();			/* ligne chargée dans l'antémémoire I */
		v = (i & 0x7ff) + 1;		/* jamais 0xfff */
		ecrit(f, v, flush);
		{
			volatile double x = v, y = 1.5;

			x = x * y + 0.25;
			if ((unsigned int)(x * 4.0) != 6 * v + 1)
				errf++;
		}
		if ((unsigned int)(g() & 0xfff) != v) {
			if (err < 5)
				printf("  tour %u : attendu %u, lu ancien code\n", i, v);
			err++;
		}
	}
	printf("essai-flush %s : %u tours, %u erreurs, %u erreurs flottantes\n",
	       flush ? "avec" : "sans", tours, err, errf);
	return (flush && err) || errf ? 1 : 0;
}
