/*
 * flexraid-sb: records on the surviving members of a RAIDiator RAID 1 ("Flex-
 * RAID", X-RAID off) that the other members failed while Linux 6.18 wrote on
 * the mirror (docs/XRAID.md §10, docs/XRAID-FORMAT.md §6). Nothing else: a
 * healthy mirror written under 6.18 keeps its superblocks as they were.
 *
 *   flexraid-sb [--dry-run] fail SURVIVOR...
 *
 * SURVIVOR = PATH:START:DATA[:...] as xraid-info flexraid prints it (START the
 * partition start, DATA the sectors before the superblock); every member of
 * the array not given is the failed one(s). The words written are those
 * RAIDiator's md leaves on a survivor once a member is gone (seen on the NAS
 * with 2 disks, bench scenario "failed"): nr_disks, active and working = the
 * survivors, failed = the others, each failed member's descriptor "removed,
 * faulty" (state 9, major/minor 0), the event count + 2 (cp_events too, as at
 * a clean stop): RAIDiator's md accepts a member one event behind at assembly,
 * two behind it leaves it out (degraded), and xraid-info finds it stale.
 * Every survivor is read and checked before anything is written: md 0.90 in
 * RAIDiator's layout (little-endian words in the SPARC word order), the same
 * RAID 1 of 2 to 27 disks, each one healthy (all members active, in sync) at
 * the same event count, or already holding this failure two events above (a
 * call stopped halfway: the rest is written). Refuses otherwise (exit 1).
 * The checksum is corrected by the difference of each word changed, in ones'
 * complement over the little-endian words (the rule RAIDiator's kernel checks).
 * O_DIRECT|O_SYNC, fsync (disk cache flush), read back and compared.
 * Already recorded on every survivor: nothing written, exit 0.
 * Exit: 0 written or already recorded, 1 refused, 2 usage or I/O error.
 */
#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SB_BYTES 4096
#define MD_MAGIC 0xa92b4efcu
#define W_NR     9
#define W_ACTIVE 34
#define W_WORK   35
#define W_FAILED 36
#define W_CSUM   38
#define W_EV_HI  39		/* RAIDiator keeps the SPARC word order */
#define W_EV_LO  40
#define W_CP_EV  42		/* big-endian */

struct member {
	const char *path;
	unsigned long long off;	/* byte offset of the superblock */
	int fd;
	unsigned char *sb;
};

static int dry;

static unsigned le32(const unsigned char *p) { return (unsigned)p[3] << 24 | p[2] << 16 | p[1] << 8 | p[0]; }
static void put_le32(unsigned char *p, unsigned v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
static unsigned w(const struct member *m, int i) { return le32(m->sb + 4 * i); }

/* ones' complement addition (end-around carry) */
static unsigned add1c(unsigned a, unsigned b)
{
	unsigned long long s = (unsigned long long)a + b;
	return (unsigned)((s & 0xffffffffu) + (s >> 32));
}

/* word i := v, the checksum corrected by the difference */
static void set_word(struct member *m, int i, unsigned v)
{
	unsigned old = w(m, i), c = w(m, W_CSUM);
	c = add1c(add1c(c, v), ~old);
	put_le32(m->sb + 4 * i, v);
	put_le32(m->sb + 4 * W_CSUM, c);
}

/* word i stored big-endian (cp_events_lo, 42), counted so in the checksum */
static void set_be_word(struct member *m, int i, unsigned v)
{
	unsigned char *q = m->sb + 4 * i;
	unsigned old = (unsigned)q[0] << 24 | q[1] << 16 | q[2] << 8 | q[3], c = w(m, W_CSUM);
	put_le32(m->sb + 4 * W_CSUM, add1c(add1c(c, v), ~old));
	q[0] = v >> 24; q[1] = v >> 16; q[2] = v >> 8; q[3] = v;
}

static int refuse(const char *path, const char *why)
{
	fprintf(stderr, "flexraid-sb: %s: %s: nothing written\n", path, why);
	return 1;
}

#define MAXR 27			/* descriptors 0..26 fit before word 992 */
static unsigned ds(const struct member *m, unsigned d) { return w(m, 128 + 32 * d + 4); }

static int load(struct member *m, const char *arg)
{
	char *p = strdup(arg), *c1, *c2;
	unsigned long long start, data;
	if (!p || !(c1 = strchr(p, ':')) || !(c2 = strchr(c1 + 1, ':'))) {
		fprintf(stderr, "flexraid-sb: %s: expected PATH:START:DATA\n", arg);
		return 2;
	}
	*c1 = 0;
	start = strtoull(c1 + 1, NULL, 10);
	data = strtoull(c2 + 1, NULL, 10);
	m->path = p;
	m->off = (start + data) * 512;
	m->fd = open(p, O_RDONLY);
	if (m->fd < 0) {
		fprintf(stderr, "flexraid-sb: %s: %s\n", p, strerror(errno));
		return 2;
	}
	if (posix_memalign((void **)&m->sb, 4096, SB_BYTES) || pread(m->fd, m->sb, SB_BYTES, (off_t)m->off) != SB_BYTES) {
		fprintf(stderr, "flexraid-sb: %s: cannot read the superblock\n", p);
		return 2;
	}
	if (w(m, 0) != MD_MAGIC)
		return refuse(p, "no md superblock (little-endian magic) there");
	if (w(m, 1) != 0 || w(m, 2) != 90)
		return refuse(p, "not an md 0.90 superblock");
	if (!(w(m, W_EV_HI) == 0 && w(m, W_EV_LO) != 0))
		return refuse(p, "not RAIDiator's layout (events_hi in word 39)");
	if (w(m, 7) != 1 || w(m, 10) < 2 || w(m, 10) > MAXR || w(m, 992) >= w(m, 10))
		return refuse(p, "not a RAID 1 of 2 or more disks");
	if (w(m, W_EV_LO) >= 0xfffffffdu)
		return refuse(p, "event count at its limit");
	return 0;
}

/* 0 healthy (every member active, in sync), 1 already recorded with the
 * failed set f (f[d] = 1: member d gone), -1 neither */
static int sb_state(const struct member *m, const char *f)
{
	unsigned n = w(m, 10), d, nf = 0, healthy = 1, rec = 1;
	for (d = 0; d < n; d++) {
		nf += f[d];
		if (ds(m, d) != 6)
			healthy = 0;
		if (ds(m, d) != (f[d] ? 9u : 6u))
			rec = 0;
	}
	if (healthy && w(m, W_NR) == n && w(m, W_ACTIVE) == n && w(m, W_WORK) == n && w(m, W_FAILED) == 0)
		return 0;
	if (rec && w(m, W_NR) == n - nf && w(m, W_ACTIVE) == n - nf && w(m, W_WORK) == n - nf && w(m, W_FAILED) == nf)
		return 1;
	return -1;
}

static int store(struct member *m)
{
	unsigned char *back;
	int fd;
	if (dry) {
		printf("flexraid-sb: %s: would write events %u, failed members removed\n", m->path, w(m, W_EV_LO));
		return 0;
	}
	fd = open(m->path, O_RDWR | O_DIRECT | O_SYNC);
	if (fd < 0 && errno == EINVAL)	/* disk images on a file system without O_DIRECT */
		fd = open(m->path, O_RDWR | O_SYNC);
	if (fd < 0) {
		fprintf(stderr, "flexraid-sb: %s: %s\n", m->path, strerror(errno));
		return 2;
	}
	if (pwrite(fd, m->sb, SB_BYTES, (off_t)m->off) != SB_BYTES || fsync(fd)) {
		fprintf(stderr, "flexraid-sb: %s: write or flush failed\n", m->path);
		close(fd);
		return 2;
	}
	close(fd);
	posix_fadvise(m->fd, 0, 0, POSIX_FADV_DONTNEED);	/* read back from the disk */
	if (posix_memalign((void **)&back, 4096, SB_BYTES) || pread(m->fd, back, SB_BYTES, (off_t)m->off) != SB_BYTES
	    || memcmp(back, m->sb, SB_BYTES)) {
		fprintf(stderr, "flexraid-sb: %s: read-back differs\n", m->path);
		return 2;
	}
	free(back);
	printf("flexraid-sb: %s: written and checked (events %u, failed members removed)\n", m->path, w(m, W_EV_LO));
	return 0;
}

int main(int argc, char **argv)
{
	struct member m[MAXR];
	char f[MAXR];
	int st[MAXR], ns, i, r, todo = 0;
	unsigned n, d, ev = 0, evr = 0, target;

	argc--, argv++;
	if (argc && !strcmp(argv[0], "--dry-run"))
		dry = 1, argc--, argv++;
	if (argc < 2 || strcmp(argv[0], "fail") || argc - 1 > MAXR) {
		fprintf(stderr, "usage: flexraid-sb [--dry-run] fail SURVIVOR...\n");
		return 2;
	}
	ns = argc - 1;
	/* everything read and checked before anything is written */
	for (i = 0; i < ns; i++)
		if ((r = load(&m[i], argv[i + 1])) != 0)
			return r;
	n = w(&m[0], 10);
	memset(f, 1, sizeof(f));
	for (i = 0; i < ns; i++) {
		if (w(&m[i], 10) != n || memcmp(m[i].sb + 4 * 5, m[0].sb + 4 * 5, 4)
		    || memcmp(m[i].sb + 4 * 13, m[0].sb + 4 * 13, 12))
			return refuse(m[i].path, "not a member of the same array as the first survivor");
		if (!f[w(&m[i], 992)])
			return refuse(m[i].path, "the same member given twice");
		f[w(&m[i], 992)] = 0;
	}
	if ((unsigned)ns >= n)
		return refuse(m[0].path, "no member left out: nothing failed");
	/* healthy survivors at one event count, already recorded ones (an
	 * earlier call stopped halfway) two above it */
	for (i = 0; i < ns; i++) {
		if ((st[i] = sb_state(&m[i], f)) < 0)
			return refuse(m[i].path, "neither a healthy mirror nor this failure already recorded");
		if (st[i] == 0) {
			if (todo++ && w(&m[i], W_EV_LO) != ev)
				return refuse(m[i].path, "event counts of the survivors differ");
			ev = w(&m[i], W_EV_LO);
		} else {
			if (evr && w(&m[i], W_EV_LO) != evr)
				return refuse(m[i].path, "event counts of the survivors differ");
			evr = w(&m[i], W_EV_LO);
		}
	}
	if (!todo) {
		printf("flexraid-sb: %s: the failure is already recorded\n", m[0].path);
		return 0;
	}
	target = ev + 2;
	if (evr && evr != target)
		return refuse(m[0].path, "event counts of the survivors differ");
	for (i = 0; i < ns; i++) {
		if (st[i])
			continue;
		set_word(&m[i], W_NR, ns);
		set_word(&m[i], W_ACTIVE, ns);
		set_word(&m[i], W_WORK, ns);
		set_word(&m[i], W_FAILED, n - ns);
		for (d = 0; d < n; d++)
			if (f[d]) {
				set_word(&m[i], 128 + 32 * d + 1, 0);
				set_word(&m[i], 128 + 32 * d + 2, 0);
				set_word(&m[i], 128 + 32 * d + 4, 9);
			}
		set_word(&m[i], W_EV_LO, target);
		set_be_word(&m[i], W_CP_EV, target);	/* as at RAIDiator's clean stop */
		if ((r = store(&m[i])) != 0)
			return r;
	}
	return 0;
}
