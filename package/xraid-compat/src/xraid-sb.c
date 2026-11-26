/*
 * xraid-sb: updates the X-RAID superblock the way RAIDiator does, so that a
 * volume written under Linux 6.18 stays what RAIDiator expects
 * (docs/XRAID-FORMAT.md §4.2 and §5.1). The only program of xraid-compat that
 * writes to the disks; it only ever writes the four superblock copies.
 *
 *   xraid-sb [--dry-run] dirty DISK DISK   array in use: clean-stop bit (0x84
 *        bit 0) = 0, every section "not in sync" (inited 0, watermark 0), as
 *        RAIDiator while it runs / after a disk failure.
 *   xraid-sb [--dry-run] clean DISK DISK   clean stop: bit 0 = 1, every section
 *        in sync (inited 1, watermark 0).
 *   xraid-sb [--dry-run] fail DISK         DISK survives, the other member
 *        failed: what RAIDiator writes when it fails a disk (state 0,
 *        counters, sections not in sync, dmap, ctime = now), on DISK only.
 *
 * Refuses (exit 1, nothing written) unless every copy on every disk is a valid,
 * untorn, consistent two-disk RAID 1 superblock (and, for dirty/clean, the two
 * disks agree, both online). Only 0x84, the counters, ctime, one disk state and
 * the section bytes +4/+7/+8 ever change; this_disk, diskid, set_uuid0 and
 * utime are kept. Per disk, like RAIDiator: copy then main copy (current then
 * backup; for "fail" backup first), O_DIRECT|O_SYNC, fsync (disk cache flush),
 * read back and compared. Nothing is written when nothing changes.
 * Exit: 0 done or unchanged, 1 refused, 2 usage or I/O error.
 */
#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define SB_LEN  0x24E0
#define AREA    (24 * 512)	/* each copy occupies 24 sectors */
#define WGAO    0x5747616Fu

/* N - x: current, current bis, backup, backup bis */
static const unsigned COPY[4] = { 4096, 4072, 4048, 4024 };

struct disk {
	const char *path;
	int fd;
	unsigned long long n;
	unsigned char *c[4];	/* the four copies, AREA bytes each, 4 KiB aligned */
	int chn;		/* this_disk c_chn (table entry), 1 = SATA 0 */
};

static int dry;

static unsigned be32(const unsigned char *p) { return (unsigned)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
static void put32(unsigned char *p, unsigned v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }

static int refuse(const char *path, const char *why)
{
	fprintf(stderr, "xraid-sb: %s: %s: nothing written\n", path, why);
	return 1;
}

static int load(struct disk *d, const char *path)
{
	int i;
	off_t t;
	d->path = path;
	if (strchr(path, '\'') || strchr(path, '"') || strchr(path, '\\'))
		return refuse(path, "path refused");
	d->fd = open(path, O_RDONLY);
	if (d->fd < 0 || (t = lseek(d->fd, 0, SEEK_END)) < 0) {
		fprintf(stderr, "xraid-sb: %s: %s\n", path, strerror(errno));
		exit(2);
	}
	d->n = (unsigned long long)t / 512;
	if (d->n < 0x200000)
		return refuse(path, "disk too small for X-RAID");
	for (i = 0; i < 4; i++) {
		if (posix_memalign((void **)&d->c[i], 4096, AREA))
			exit(2);
		if (pread(d->fd, d->c[i], AREA, (off_t)((d->n - COPY[i]) * 512)) != AREA) {
			fprintf(stderr, "xraid-sb: %s: read error\n", path);
			exit(2);
		}
		if (be32(d->c[i]) != WGAO)
			return refuse(path, "a superblock copy is missing (no WGao)");
	}
	/* RAIDiator writes the bis copy then the main one, same bytes */
	if (memcmp(d->c[0], d->c[1], AREA) || memcmp(d->c[2], d->c[3], AREA))
		return refuse(path, "a superblock differs from its copy (interrupted update)");
	return 0;
}

/* structure checks on the current copy (the one RAIDiator reads) */
static int check(struct disk *d)
{
	const unsigned char *s = d->c[0], *t = s + 0x1460, *e;
	unsigned i, alive = 0;
	unsigned long long lsize = 0;
	if (be32(s + 4) || be32(s + 8) != 1 || be32(s + 12) || be32(s + 0x1C) != 1)
		return refuse(d->path, "unknown superblock version");
	if (be32(s + 0x24) != 2 || be32(s + 0x28) != 2 || s[0x33])
		return refuse(d->path, "not a two-disk X-RAID");
	if (be32(s + 0x80))
		return refuse(d->path, "RAIDiator reinstall flag (0x80) set");
	for (i = 0; i < 7; i++) {
		e = s + 0x800 + 32 * i;
		if (!e[6])
			continue;
		if (e[5] != 1)
			return refuse(d->path, "section that is not a mirror");
		alive++;
		lsize += be32(e + 0x18);
	}
	if (!alive || alive != be32(s + 0x100) || lsize != be32(s + 0x48))
		return refuse(d->path, "section table inconsistent with the header");
	d->chn = t[2];
	if (d->chn < 1 || d->chn > 11 || (t[0] ^ t[1]) != 1 || memcmp(t, s + 0x200 + 128 * d->chn, 4))
		return refuse(d->path, "this_disk inconsistent with the disk table");
	if (s[0x30] > 10 || s[0x32] > 10 || s[0x200 + 128 * (s[0x30] + 1)] != 1 || s[0x200 + 128 * (s[0x32] + 1) + 1] != 1)
		return refuse(d->path, "base/mirror of the header differ from the disk table");
	return 0;
}

static unsigned disk_state(const unsigned char *s, int chn) { return be32(s + 0x200 + 128 * chn + 0x10); }
static unsigned disk_present(const unsigned char *s, int chn) { return be32(s + 0x200 + 128 * chn + 0x14); }
/* the other member: the table entry that is base or mirror and is not chn */
static int other(const unsigned char *s, int chn)
{
	int i;
	for (i = 1; i < 12; i++)
		if (i != chn && (s[0x200 + 128 * i] || s[0x200 + 128 * i + 1]))
			return i;
	return -1;
}

static void sections(unsigned char *s, int inited, int dmap)
{
	int i;
	for (i = 0; i < 7; i++) {
		unsigned char *e = s + 0x800 + 32 * i;
		if (!e[6])
			continue;
		e[7] = inited;
		put32(e + 8, 0);
		if (dmap >= 0)
			e[4] = dmap;
	}
}

/* writes the new superblock into the four copies: order[] = copy indexes */
static int store(struct disk *d, const unsigned char *nsb, const int *order)
{
	unsigned char *b;
	int i, w, k;
	if (posix_memalign((void **)&b, 4096, AREA))
		return 2;
	memcpy(b, d->c[0], AREA);
	memcpy(b, nsb, SB_LEN);
	for (k = 0; k < 4 && !memcmp(d->c[k], b, AREA); k++)
		;
	if (k == 4) {
		printf("xraid-sb: %s: unchanged\n", d->path);
		return 0;
	}
	if (dry) {
		printf("xraid-sb: %s: would write the 4 superblock copies\n", d->path);
		return 0;
	}
	w = open(d->path, O_RDWR | O_DIRECT | O_SYNC);
	if (w < 0 && errno == EINVAL)	/* disk images on a file system without O_DIRECT */
		w = open(d->path, O_RDWR | O_SYNC);
	if (w < 0) {
		fprintf(stderr, "xraid-sb: %s: %s\n", d->path, strerror(errno));
		return 2;
	}
	for (i = 0; i < 4; i++)
		if (pwrite(w, b, AREA, (off_t)((d->n - COPY[order[i]]) * 512)) != AREA) {
			fprintf(stderr, "xraid-sb: %s: write error at N-%u\n", d->path, COPY[order[i]]);
			close(w);
			return 2;
		}
	if (fsync(w)) {		/* on a block device: FLUSH CACHE to the disk */
		fprintf(stderr, "xraid-sb: %s: flush failed\n", d->path);
		close(w);
		return 2;
	}
	close(w);
	posix_fadvise(d->fd, 0, 0, POSIX_FADV_DONTNEED);	/* read back from the disk */
	for (i = 0; i < 4; i++)
		if (pread(d->fd, d->c[i], AREA, (off_t)((d->n - COPY[i]) * 512)) != AREA || memcmp(d->c[i], b, AREA)) {
			fprintf(stderr, "xraid-sb: %s: read-back differs at N-%u\n", d->path, COPY[i]);
			return 2;
		}
	printf("xraid-sb: %s: written and checked\n", d->path);
	free(b);
	return 0;
}

int main(int argc, char **argv)
{
	static struct disk D[2];
	static unsigned char nsb[SB_LEN];
	static const int CUR_FIRST[4] = { 1, 0, 3, 2 }, BACK_FIRST[4] = { 3, 2, 1, 0 };
	const char *cmd;
	int nd, i, rc = 0;

	argc--, argv++;
	if (argc && !strcmp(argv[0], "--dry-run"))
		dry = 1, argc--, argv++;
	if (argc < 2)
		goto usage;
	cmd = argv[0];
	nd = argc - 1;
	if (!(((!strcmp(cmd, "dirty") || !strcmp(cmd, "clean")) && nd == 2) || (!strcmp(cmd, "fail") && nd == 1)))
		goto usage;
	for (i = 0; i < nd; i++)
		if (load(&D[i], argv[i + 1]) || check(&D[i]))
			return 1;

	if (nd == 1) {		/* fail: the other member failed, recorded on the survivor */
		unsigned char *s = nsb;
		int f;
		memcpy(nsb, D[0].c[0], SB_LEN);
		f = other(s, D[0].chn);
		if (f < 0)
			return refuse(D[0].path, "no other member in the disk table");
		if (disk_state(s, D[0].chn) != 1 || !disk_present(s, D[0].chn))
			return refuse(D[0].path, "the surviving disk is not online");
		if (disk_state(s, f) == 0) {
			printf("xraid-sb: %s: failure already recorded\n", D[0].path);
			return 0;
		}
		put32(s + 0x200 + 128 * f + 0x10, 0);
		put32(s + 0x88, 1);	/* active */
		put32(s + 0x8C, 1);	/* working */
		put32(s + 0x90, 1);	/* failed */
		put32(s + 0x18, (unsigned)time(NULL));
		sections(s, 0, 1 << (D[0].chn - 1));
		return store(&D[0], nsb, BACK_FIRST);
	}

	/* dirty / clean: two disks, one base and one mirror, same configuration */
	if (D[0].chn == D[1].chn || D[0].c[0][0x1460 + 1] == D[1].c[0][0x1460 + 1])
		return refuse(D[1].path, "the two disks are not one base and one mirror");
	if (memcmp(D[0].c[0], D[1].c[0], 0x1460) || memcmp(D[0].c[0] + 0x14E0, D[1].c[0] + 0x14E0, SB_LEN - 0x14E0))
		return refuse(D[1].path, "the superblocks of the two disks differ");
	for (i = 0; i < 2; i++)
		if (disk_state(D[0].c[0], D[i].chn) != 1 || disk_present(D[0].c[0], D[i].chn) != 1)
			return refuse(D[i].path, "disk not online in the superblock");
	if (be32(D[0].c[0] + 0x88) != 2 || be32(D[0].c[0] + 0x8C) != 2 || be32(D[0].c[0] + 0x90) || be32(D[0].c[0] + 0x94))
		return refuse(D[0].path, "RAIDiator counters show a degraded array");
	/* channel order, like RAIDiator */
	if (D[0].chn > D[1].chn) {
		struct disk t = D[0];
		D[0] = D[1], D[1] = t;
	}
	for (i = 0; i < 2 && !rc; i++) {
		unsigned st;
		memcpy(nsb, D[i].c[0], SB_LEN);
		st = be32(nsb + 0x84);
		put32(nsb + 0x84, cmd[0] == 'c' ? st | 1 : st & ~1u);
		sections(nsb, cmd[0] == 'c', -1);
		rc = store(&D[i], nsb, CUR_FIRST);
	}
	return rc;
usage:
	fprintf(stderr, "usage: xraid-sb [--dry-run] dirty|clean DISK DISK | fail SURVIVING_DISK\n");
	return 2;
}
