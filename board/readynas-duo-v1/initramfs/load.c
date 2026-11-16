/*
 * load: debugging reproducer (test A). A "sleeper" (child doing nanosleep
 * 1 s, 5 times) while the parent loads the kernel:
 *   load c: 2000 fork+_exit, WITHOUT sleeper (control)
 *   load b: sleeper + 2000 rounds of page faults (mmap 64 KiB, touch, munmap)
 *   load a: sleeper + 2000 fork+_exit
 *   load e: sleeper + 300 fork+exec of "/bin/busybox true"
 * Counter every 100 rounds; "load x OK" at the end.
 * Built static by the readynas-initramfs package (Buildroot toolchain).
 */
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>

static void say(const char *fmt, int a, int b)
{
	char buf[96];
	int n = snprintf(buf, sizeof(buf), fmt, a, b);

	write(1, buf, n);
}

static pid_t sleeper(void)
{
	pid_t p = fork();
	int i;

	if (p == 0) {
		for (i = 1; i <= 5; i++) {
			struct timespec t = { 1, 0 };

			nanosleep(&t, NULL);
			say("  sleeper OK %d%c\n", i, ' ');
		}
		_exit(0);
	}
	return p;
}

int main(int argc, char **argv)
{
	char m = argc > 1 ? argv[1][0] : 'c';
	int i, rounds = m == 'e' ? 300 : 2000;
	pid_t d = -1;

	say("load %c: start (%d rounds)\n", m, rounds);
	if (m != 'c')
		d = sleeper();
	for (i = 1; i <= rounds; i++) {
		if (m == 'b') {
			char *p = mmap(NULL, 65536, PROT_READ | PROT_WRITE,
				       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
			int k;

			if (p == MAP_FAILED) {
				say("load: mmap fails at round %d%c\n", i, ' ');
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
				say("load: fork fails at round %d%c\n", i, ' ');
				return 1;
			}
			waitpid(f, NULL, 0);
		}
		if (i % 100 == 0)
			say("  load %c: %d\n", m, i);
	}
	if (d > 0)
		waitpid(d, NULL, 0);
	say("load %c OK%c", m, '\n');
	return 0;
}
