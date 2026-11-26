/*
 * flexraid-sb: records on the surviving member of a RAIDiator RAID 1 ("Flex-
 * RAID", X-RAID off) that the other member failed while Linux 6.18 wrote on
 * the mirror (docs/XRAID.md §10, docs/XRAID-FORMAT.md §6). Nothing else: a
 * healthy mirror written under 6.18 keeps its superblocks as they were.
 *
 *   flexraid-sb [--dry-run] fail MEMBER
 *
 * MEMBER (the survivor) = PATH:START:DATA[:...] as xraid-info flexraid prints
 * it (START the partition start, DATA the sectors before the superblock). The
 * words written are those RAIDiator's md leaves on the survivor once a member
 * is gone (seen on the NAS, bench scenario "failed"): nr_disks, active and
 * working - 1, failed + 1, the other member's descriptor "removed, faulty"
 * (state 9, major/minor 0), the event count + 2 (cp_events too, as at a
 * clean stop): RAIDiator's md accepts a
 * member one event behind at assembly, two behind it leaves it out (degraded),
 * and xraid-info finds it stale. Refuses (exit 1, nothing written) unless the
 * superblock is md 0.90 in RAIDiator's layout (little-endian words in the
 * SPARC word order), of a 2-disk RAID 1 with both members active and in sync.
 * The checksum is corrected by the difference of each word changed, in ones'
 * complement over the little-endian words (the rule RAIDiator's kernel checks).
 * O_DIRECT|O_SYNC, fsync (disk cache flush), read back and compared.
 * Already recorded (the other member removed, faulty): nothing written, exit 0.
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
	if (w(m, 7) != 1 || w(m, 10) != 2)
		return refuse(p, "not a 2-disk RAID 1");
	if (w(m, W_EV_LO) >= 0xfffffffdu)
		return refuse(p, "event count at its limit");
	if (w(m, 992) <= 1 && w(m, W_NR) == 1 && w(m, W_FAILED) == 1 && w(m, 128 + 32 * (1 - w(m, 992)) + 4) == 9)
		return 3;	/* the other member already recorded as gone */
	if (w(m, 992) > 1 || w(m, W_NR) != 2 || w(m, W_ACTIVE) != 2 || w(m, W_WORK) != 2 || w(m, W_FAILED) != 0
	    || w(m, 128 + 32 * w(m, 992) + 4) != 6 || w(m, 128 + 32 * (1 - w(m, 992)) + 4) != 6)
		return refuse(p, "not a healthy mirror (both members active and in sync)");
	return 0;
}

static int store(struct member *m)
{
	unsigned char *back;
	int fd;
	if (dry) {
		printf("flexraid-sb: %s: would write events %u, other member removed\n", m->path, w(m, W_EV_LO));
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
	printf("flexraid-sb: %s: written and checked (events %u, other member removed)\n", m->path, w(m, W_EV_LO));
	return 0;
}

int main(int argc, char **argv)
{
	struct member m;
	unsigned o;
	int r;

	argc--, argv++;
	if (argc && !strcmp(argv[0], "--dry-run"))
		dry = 1, argc--, argv++;
	if (argc != 2 || strcmp(argv[0], "fail")) {
		fprintf(stderr, "usage: flexraid-sb [--dry-run] fail MEMBER\n");
		return 2;
	}
	if ((r = load(&m, argv[1])) == 3) {
		printf("flexraid-sb: %s: the other member is already recorded as gone\n", m.path);
		return 0;
	}
	if (r != 0)
		return r;
	o = 128 + 32 * (1 - w(&m, 992));	/* the other member's descriptor */
	set_word(&m, W_NR, 1);
	set_word(&m, W_ACTIVE, 1);
	set_word(&m, W_WORK, 1);
	set_word(&m, W_FAILED, 1);
	set_word(&m, o + 1, 0);
	set_word(&m, o + 2, 0);
	set_word(&m, o + 4, 9);
	set_word(&m, W_EV_LO, w(&m, W_EV_LO) + 2);
	set_be_word(&m, W_CP_EV, w(&m, W_EV_LO));	/* as at RAIDiator's clean stop */
	return store(&m);
}
