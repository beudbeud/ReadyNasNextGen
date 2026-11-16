/*
 * charge : reproducteur de mise au point (essai A). Un « dormeur » (fils qui
 * fait nanosleep 1 s, 5 fois) pendant que le père charge le noyau :
 *   charge c : 2000 fork+_exit, SANS dormeur (témoin)
 *   charge b : dormeur + 2000 tours de fautes de page (mmap 64 Ko, toucher, munmap)
 *   charge a : dormeur + 2000 fork+_exit
 *   charge e : dormeur + 300 fork+exec de « /bin/busybox true »
 * Compteur tous les 100 tours ; « charge x OK » à la fin.
 * Construit statique par le paquet readynas-initramfs (chaîne Buildroot).
 */
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>

static void dire(const char *fmt, int a, int b)
{
	char buf[96];
	int n = snprintf(buf, sizeof(buf), fmt, a, b);

	write(1, buf, n);
}

static pid_t dormeur(void)
{
	pid_t p = fork();
	int i;

	if (p == 0) {
		for (i = 1; i <= 5; i++) {
			struct timespec t = { 1, 0 };

			nanosleep(&t, NULL);
			dire("  dormeur OK %d%c\n", i, ' ');
		}
		_exit(0);
	}
	return p;
}

int main(int argc, char **argv)
{
	char m = argc > 1 ? argv[1][0] : 'c';
	int i, tours = m == 'e' ? 300 : 2000;
	pid_t d = -1;

	dire("charge %c : début (%d tours)\n", m, tours);
	if (m != 'c')
		d = dormeur();
	for (i = 1; i <= tours; i++) {
		if (m == 'b') {
			char *p = mmap(NULL, 65536, PROT_READ | PROT_WRITE,
				       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
			int k;

			if (p == MAP_FAILED) {
				dire("charge : mmap échoue au tour %d%c\n", i, ' ');
				return 1;
			}
			for (k = 0; k < 65536; k += 4096)
				p[k] = (char)k;
			munmap(p, 65536);
		} else {
			pid_t f = fork();

			if (f == 0) {
				if (m == 'e')
					execl("/bin/busybox", "true", (char *)NULL);
				_exit(0);
			}
			if (f < 0) {
				dire("charge : fork échoue au tour %d%c\n", i, ' ');
				return 1;
			}
			waitpid(f, NULL, 0);
		}
		if (i % 100 == 0)
			dire("  charge %c : %d\n", m, i);
	}
	if (d > 0)
		waitpid(d, NULL, 0);
	dire("charge %c OK%c", m, '\n');
	return 0;
}
