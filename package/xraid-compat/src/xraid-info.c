/*
 * xraid-info: READ-ONLY analysis of X-RAID disks (ReadyNAS Duo v1,
 * RAIDiator-Sparc 4.x) for the Linux 6.18 compatibility layer.
 *
 * Written from the functional description of the format (docs/XRAID.md);
 * no Infrant/NETGEAR code is reused. The program never opens a disk for
 * writing.
 *
 *   xraid-info [--json] [--samples K] DISK...
 *        "WGao" superblock (current at N-4096, backup at N-4048, and their
 *        copies), role of each disk, sections, partitions of the base disk,
 *        state (clean, synchronisation, disks), comparison of K blocks of
 *        64 KiB per section at the same LBAs on both disks, and verdict:
 *        rw (mirror can be assembled), ro (one disk read-only) or none.
 *        Text output = KEY='value' lines that sh can eval (nas-raid).
 *   xraid-info verify [--json] [--zone MIB] DISK_A DISK_B
 *        compares the whole content of the sections of both disks
 *        (read-only); exit code 0 = identical, 1 = differences, 2 = errors.
 *   xraid-info quick [--json] [--samples K] [--seed S] [--list] BASE MIRROR
 *        quick check (1 to 3 minutes on the NAS): compares the areas a power
 *        cut while writing most likely leaves different (ext3 journals and
 *        metadata of p1 and of the LV "c", LVM metadata, EBRs) plus K random
 *        64 KiB blocks per section; --list prints the ranges without reading
 *        the mirror's data. Exit 0 = identical, 1 = differences, 2 = errors,
 *        3 = identical but incomplete (a file system was not located).
 *   xraid-info smart [--json] DISK
 *        SMART through ATA PASS-THROUGH (SG_IO): health, reallocated,
 *        pending, uncorrectable sectors, hours (format of /var/run/smart.sdX).
 *
 * Superblock integers: 32-bit big-endian (written as is by the SPARC).
 * MBR partition table: little-endian, as on a PC.
 * Built for SPARC v7 (Buildroot): no sdiv nor casa instruction, checked by
 * board/readynas-duo-v1/post-image.sh.
 */
#define _FILE_OFFSET_BITS 64
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <scsi/sg.h>

typedef unsigned long long u64;

#define SB_LEN     0x24E0
#define WGAO       0x5747616Fu	/* valid configuration */
#define WGAN       0x5747616Eu	/* disk initialised, ready to be added */
#define MD_MAGIC   0xa92b4efcu
#define MAXD       4		/* the Duo has only 2 bays; 4 for the NV */
#define MAXP       16
#define SAMPLE_LEN (64 * 1024)	/* sampling block */

/* the 4 copies: current, current bis, backup, backup bis (N - x) */
static const unsigned COPY[4] = { 4096, 4072, 4048, 4024 };
static const char *COPY_NAME[4] = { "current", "current_bis", "backup", "backup_bis" };

static int json;

static unsigned be32(const unsigned char *p) { return (unsigned)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
static unsigned le32(const unsigned char *p) { return (unsigned)p[3] << 24 | p[2] << 16 | p[1] << 8 | p[0]; }

static const char *state_name(unsigned e)
{
	switch (e) {
	case 0: return "faulty";
	case 1: return "online";
	case 2: return "spare";
	case 8: return "ready";
	}
	return "unknown";
}

struct disk {
	const char *path;
	int fd;
	u64 n;				/* native sectors */
	unsigned char sb[4][SB_LEN];
	unsigned magic[4];
	int wgam;			/* "WGam" mark at N-2 */
	int md;				/* md superblock found (already migrated) */
	unsigned char mbr[512];
	int mbr_ok;
	int channel;			/* hwif index from this_disk (1 = SATA 0) */
	int role;			/* 'b' base, 'm' mirror, 0 unknown */
	int ref;			/* copy used (0 current, 2 backup), -1 none */
};

struct section { unsigned start, nb, end, raid, init, dmap, init_mark, alive; };
struct part { int num; unsigned start, nb, type; int sec; unsigned off; };

static int read_at(int fd, u64 byte, void *buf, size_t len)
{
	size_t f = 0;
	while (f < len) {
		ssize_t r = pread(fd, (char *)buf + f, len - f, (off_t)(byte + f));
		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0)
			return -1;
		f += (size_t)r;
	}
	return 0;
}

static void die(const char *fmt, ...)
{
	va_list a;
	va_start(a, fmt);
	fputs("xraid-info: ", stderr);
	vfprintf(stderr, fmt, a);
	fputc('\n', stderr);
	va_end(a);
	exit(2);
}

static void open_disk(struct disk *d, const char *path)
{
	off_t t;
	memset(d, 0, sizeof(*d));
	/* the path is fed back to sh between single quotes: no quote allowed */
	if (strchr(path, '\'') || strchr(path, '"') || strchr(path, '\\'))
		die("path refused: %s", path);
	d->path = path;
	d->ref = -1;
	d->fd = open(path, O_RDONLY);
	if (d->fd < 0)
		die("%s: %s", path, strerror(errno));
	t = lseek(d->fd, 0, SEEK_END);
	if (t < 0)
		die("%s: unreadable size", path);
	d->n = (u64)t / 512;
}

/* md superblock (1.0 at the end, 1.1 at the start, 1.2 at 4 KiB, 0.90 at the end, 64 KiB) */
static void find_md(struct disk *d)
{
	unsigned char b[4];
	u64 size = d->n * 512, pos[4];
	int i;
	pos[0] = 0;
	pos[1] = 4096;
	pos[2] = size >= 8192 ? (size - 8192) & ~(u64)4095 : 0;
	pos[3] = size >= 65536 ? (size & ~(u64)65535) - 65536 : 0;
	for (i = 0; i < 4; i++)
		if (read_at(d->fd, pos[i], b, 4) == 0 && (le32(b) == MD_MAGIC || be32(b) == MD_MAGIC))
			d->md = 1;
}

static void read_disk(struct disk *d)
{
	unsigned char b[4];
	int c;
	if (d->n < 0x200000)	/* < 1 GB: X-RAID does not configure it (§2) */
		return;
	for (c = 0; c < 4; c++) {
		if (read_at(d->fd, (d->n - COPY[c]) * 512, d->sb[c], SB_LEN) == 0)
			d->magic[c] = be32(d->sb[c]);
	}
	if (read_at(d->fd, (d->n - 2) * 512, b, 4) == 0)
		d->wgam = memcmp(b, "WGam", 4) == 0;
	if (read_at(d->fd, 0, d->mbr, 512) == 0)
		d->mbr_ok = d->mbr[510] == 0x55 && d->mbr[511] == 0xAA;
	find_md(d);
	if (d->magic[0] == WGAO)
		d->ref = 0;
	else if (d->magic[2] == WGAO)
		d->ref = 2;
	if (d->ref >= 0) {
		const unsigned char *t = d->sb[d->ref] + 0x1460;	/* this_disk */
		d->channel = t[2];
		d->role = t[1] ? 'b' : t[0] ? 'm' : 0;
	}
}

/* same configuration: everything but this_disk (0x0F80 .. 0x14DF) */
static int same_sb(const unsigned char *a, const unsigned char *b)
{
	return memcmp(a, b, 0xF80) == 0 && memcmp(a + 0x14E0, b + 0x14E0, SB_LEN - 0x14E0) == 0;
}

/* ---------- text (KEY='value') or JSON output ---------- */
static int first = 1;
static void key_json(const char *k)	/* JSON keys in lower case */
{
	printf("%s\"", first ? "" : ",");
	for (; *k; k++)
		putchar(*k >= 'A' && *k <= 'Z' ? *k + 32 : *k);
	printf("\":");
}
static void key_s(const char *k, const char *v)
{
	if (json)
		key_json(k), printf("\"%s\"", v);
	else
		printf("XR_%s='%s'\n", k, v);
	first = 0;
}
static void key_n(const char *k, u64 v)
{
	if (json)
		key_json(k), printf("%llu", v);
	else
		printf("XR_%s=%llu\n", k, v);
	first = 0;
}

/* reasons: short code (for sh) and text (for humans) */
#define MAXR 24
static const char *r_code[MAXR], *r_text[MAXR];
static int nr;
static int block_rw, block_all;
static void reason(int severity, const char *code, const char *text)
{
	if (nr < MAXR) {
		r_code[nr] = code;
		r_text[nr] = text;
		nr++;
	}
	if (severity >= 1)
		block_rw = 1;
	if (severity >= 2)
		block_all = 1;
}

/* partitions from an MBR; EBRs read from the read disk (their LBAs kept in ebr_lba) */
static unsigned ebr_lba[64];
static int nebr;
static int read_parts(const unsigned char *mbr, int fd, struct part *p)
{
	int i, n = 0;
	unsigned ext = 0;
	for (i = 0; i < 4; i++) {
		const unsigned char *e = mbr + 0x1BE + 16 * i;
		unsigned type = e[4], st = le32(e + 8), nb = le32(e + 12);
		if (!type || !nb)
			continue;
		if (type == 0x05 || type == 0x0f || type == 0x85) {
			ext = st;
			continue;
		}
		if (n < MAXP) {
			p[n].num = i + 1; p[n].start = st; p[n].nb = nb; p[n].type = type;
			n++;
		}
	}
	if (ext) {
		unsigned ebr = ext, num = 5, guard = 0;
		unsigned char b[512];
		while (ebr && guard++ < 64 && read_at(fd, (u64)ebr * 512, b, 512) == 0
		       && b[510] == 0x55 && b[511] == 0xAA) {
			const unsigned char *e = b + 0x1BE;
			if (nebr < 64)
				ebr_lba[nebr++] = ebr;
			if (e[4] && le32(e + 12) && n < MAXP) {
				p[n].num = num; p[n].start = ebr + le32(e + 8);
				p[n].nb = le32(e + 12); p[n].type = e[4];
				n++;
			}
			num++;
			ebr = e[16 + 4] ? ext + le32(e + 16 + 8) : 0;
		}
	}
	return n;
}

/* compares k blocks of 64 KiB per section; number of differences, -1 on error */
static int sample(int fa, int fb, const struct section *s, int ns, int k)
{
	static unsigned char a[SAMPLE_LEN], b[SAMPLE_LEN];
	int i, j, diff = 0;
	for (i = 0; i < ns; i++) {
		u64 lg = s[i].end - s[i].start, stride;
		if (lg < SAMPLE_LEN / 512 || k < 1)
			continue;
		stride = k > 1 ? (lg - SAMPLE_LEN / 512) / (u64)(k - 1) : 0;
		for (j = 0; j < k; j++) {
			u64 lba = s[i].start + stride * (u64)j;
			if (read_at(fa, lba * 512, a, SAMPLE_LEN) || read_at(fb, lba * 512, b, SAMPLE_LEN))
				return -1;
			diff += memcmp(a, b, SAMPLE_LEN) != 0;
		}
	}
	return diff;
}

/* ---------- analysis ---------- */
static int analyse(int argc, char **argv, int k)
{
	static struct disk D[MAXD];
	struct section S[7];
	struct part P[MAXP];
	int nd = argc, i, j, ref = -1, ns = 0, np = 0, base = -1, mirror = -1, rd = -1;
	int diffsb = 0, diff = -2, torn = 0;
	const unsigned char *sb;
	unsigned v, nr_disks, raid_disks, fake, clean, nb_lun, ver[3];
	unsigned utime, active, working, failed, spare;
	u64 l_size = 0;
	char buf[64];

	if (nd < 1 || nd > MAXD)
		die("1 to %d disks", MAXD);
	for (i = 0; i < nd; i++) {
		open_disk(&D[i], argv[i]);
		read_disk(&D[i]);
		/* RAIDiator writes the "bis" copy just before its main copy, with
		 * the same bytes: a difference means an interrupted update */
		for (j = 0; j < 4; j += 2)
			if (D[i].magic[j] == WGAO && memcmp(D[i].sb[j], D[i].sb[j + 1], SB_LEN))
				torn = 1;
	}
	/* reference superblock: identical on the majority, otherwise the newest */
	for (i = 0; i < nd; i++) {
		if (D[i].ref < 0)
			continue;
		if (ref < 0) { ref = i; continue; }
		if (!same_sb(D[i].sb[D[i].ref], D[ref].sb[D[ref].ref])) {
			diffsb = 1;
			if (be32(D[i].sb[D[i].ref] + 0x18) > be32(D[ref].sb[D[ref].ref] + 0x18))
				ref = i;
		}
	}

	if (json)
		printf("{");
	if (ref < 0) {
		key_s("MODE", "none");
		for (i = 0; i < nd; i++)
			if (D[i].md) { key_s("MD", "1"); break; }
		if (json) printf(",\"reasons\":[{\"code\":\"no_xraid\",\"text\":\"no X-RAID superblock (WGao)\"}]}\n");
		else printf("XR_REASONS='no_xraid'\n");
		return 0;
	}
	sb = D[ref].sb[D[ref].ref];
	ver[0] = be32(sb + 4); ver[1] = be32(sb + 8); ver[2] = be32(sb + 12);
	v = be32(sb + 0x20);
	nr_disks = be32(sb + 0x24);
	raid_disks = be32(sb + 0x28);
	fake = sb[0x33];
	clean = be32(sb + 0x84) & 1;
	/* 0x80: shown as "update_time" by RAIDiator, but used as a flag: 1 =
	 * reinstall (factory default) requested for the next RAIDiator boot */
	utime = be32(sb + 0x80);
	active = be32(sb + 0x88);
	working = be32(sb + 0x8C);
	failed = be32(sb + 0x90);
	spare = be32(sb + 0x94);
	nb_lun = be32(sb + 0x100);

	/* checks */
	if (ver[0] != 0 || ver[1] != 1 || ver[2] != 0)
		reason(2, "version", "unknown superblock version (expected 0.1.0)");
	if (be32(sb + 0x1C) != 1)
		reason(2, "level", "level field is not 1");
	if (D[ref].ref != 0)
		reason(1, "backup_superblock", "current superblock missing: reading the backup");
	if (diffsb)
		reason(1, "superblocks_differ", "the superblocks of the disks differ");
	if (torn)
		reason(1, "superblock_torn", "a superblock and its copy differ (interrupted superblock update)");
	if (!clean)
		reason(1, "unclean_shutdown", "superblock marked as not cleanly shut down (clean shutdown = 0)");
	if (utime)
		reason(1, "reinstall_pending", "RAIDiator reinstall flag set (0x80): RAIDiator would reset the NAS at its next boot");
	if (failed || working < nr_disks || active != working)
		reason(1, "degraded", "RAIDiator counters: a disk failed or is missing (active/working/failed)");
	if (nr_disks != 2 || raid_disks != 2 || fake)
		reason(1, "not_2_disks", "one-disk configuration (fake mirror) or more than 2 disks");
	if (v == 0 || v > D[ref].n - 4096)
		reason(2, "size", "inconsistent visible size V");
	if (nb_lun < 1 || nb_lun > 7)
		reason(2, "sections", "inconsistent number of sections");

	/* sections, bounded by the visible zone V (never the protected zone) */
	for (i = 0; i < 7; i++) {
		const unsigned char *e = sb + 0x800 + 32 * i;
		if (!e[6])
			continue;
		S[ns].alive = 1;
		S[ns].raid = e[5];
		/* +4 carrying disks (bits 0 and 1: driver dmap), +7 "initialized"
		 * (1 = mirror synchronised; RAIDiator resyncs a section at 0 and
		 * resets it to 0 when a disk fails). +8 is a sync watermark that
		 * RAIDiator only resumes from in RAID 4; on a RAID 1 it can keep a
		 * stale non-zero value on a healthy volume (docs/XRAID-FORMAT.md). */
		S[ns].dmap = e[4];
		S[ns].init = e[7];
		S[ns].init_mark = be32(e + 8);
		S[ns].start = be32(e + 0x10);
		S[ns].nb = be32(e + 0x18);
		S[ns].end = S[ns].start + S[ns].nb;
		l_size += S[ns].nb;
		if (S[ns].end > v || S[ns].end < S[ns].start)
			S[ns].end = v;
		if (S[ns].raid != 1)
			reason(1, "not_raid1", "section that is not a mirror (RAID 4)");
		if (S[ns].init != 1)
			reason(1, "sync_in_progress", "unfinished X-RAID synchronisation (section not initialised)");
		if ((S[ns].dmap & 3) != 3)
			reason(1, "degraded_section", "section carried by a single disk (dmap)");
		if (S[ns].start >= S[ns].end)
			reason(2, "sections", "empty section or outside the visible zone");
		ns++;
	}
	for (i = 1; i < ns; i++)
		if (S[i].start < S[i - 1].end)
			reason(2, "sections", "overlapping sections");
	/* 0x100 = number of sections, 0x48 = sum of their declared sizes */
	if ((unsigned)ns != nb_lun || l_size != be32(sb + 0x48))
		reason(1, "inconsistent_superblock", "section count or total size differs from the header");
	/* header 0x30 parity (mirror) and 0x32 base: relative channels (entry - 1) */
	if (sb[0x30] > 10 || sb[0x32] > 10
	    || (!fake && (sb[0x200 + 128 * (sb[0x30] + 1)] != 1 || sb[0x200 + 128 * (sb[0x32] + 1) + 1] != 1)))
		reason(1, "inconsistent_superblock", "base/mirror in the header differ from the disk table");

	/* disks: role, state in the reference table */
	for (i = 0; i < nd; i++) {
		if (D[i].ref < 0)
			continue;
		/* different sizes allowed: same LBAs, bounded by V (the smallest) */
		if (v > D[i].n - 4096)
			reason(2, "size", "visible size V beyond the end of a disk");
		if (D[i].channel < 1 || D[i].channel > 11) {
			reason(1, "unknown_role", "unreadable this_disk");
			continue;
		}
		if (D[i].role == 'b') {
			if (base >= 0) reason(2, "two_bases", "two disks claim to be \"base\"");
			base = i;
		} else if (D[i].role == 'm') {
			if (mirror >= 0) reason(2, "two_mirrors", "two disks claim to be \"mirror\"");
			mirror = i;
		}
	}
	for (i = 0; i < nd; i++)
		for (j = i + 1; j < nd; j++)
			if (D[i].ref >= 0 && D[j].ref >= 0 && D[i].channel == D[j].channel)
				reason(2, "same_channel", "two disks declare the same channel");
	if (base < 0 || mirror < 0) {
		reason(1, "missing_disk", "one of the two X-RAID disks is missing: read-only");
	}
	for (i = 0; i < nd; i++) {
		unsigned st;
		if (D[i].ref < 0)
			continue;
		st = be32(sb + 0x200 + 128 * D[i].channel + 0x10);
		/* +0x14 "present": 0 once RAIDiator has taken the disk out */
		if (st != 1 || be32(sb + 0x200 + 128 * D[i].channel + 0x14) != 1)
			reason(1, "disk_not_online", "a disk is not \"online\" (rebuilding, spare or faulty)");
	}
	/* disk read in read-only mode: base if online, otherwise mirror if online */
	for (i = 0; i < nd; i++)
		if (i == base && be32(sb + 0x200 + 128 * D[i].channel + 0x10) == 1)
			rd = i;
	if (rd < 0)
		for (i = 0; i < nd; i++)
			if (i == mirror && be32(sb + 0x200 + 128 * D[i].channel + 0x10) == 1)
				rd = i;
	if (rd < 0)
		reason(2, "no_readable_disk", "no \"online\" disk to read");

	/* partitions: MBR of the base disk, otherwise the p_table copied into the superblock */
	if (rd >= 0) {
		unsigned char mbr[512];
		memset(mbr, 0, sizeof(mbr));
		if (base >= 0 && D[base].mbr_ok)
			memcpy(mbr, D[base].mbr, 512);
		else if (base >= 0 || mirror >= 0) {
			/* entry of the base disk in the table: the one with b_drive */
			for (i = 1; i < 12; i++)
				if (sb[0x200 + 128 * i + 1]) {
					memcpy(mbr + 0x1C0, sb + 0x200 + 128 * i + 0x18, 64);
					break;
				}
			reason(1, "mbr_rebuilt", "MBR of the base disk missing: table taken from the superblock");
		}
		if (mbr[510] == 0x55 && mbr[511] == 0xAA)
			np = read_parts(mbr, D[rd].fd, P);
		if (!np)
			reason(2, "no_partition", "no partition found on the base disk");
	}
	for (i = 0; i < np; i++) {
		P[i].sec = -1;
		for (j = 0; j < ns; j++)
			if (P[i].start >= S[j].start && (u64)P[i].start + P[i].nb <= S[j].end) {
				P[i].sec = j;
				P[i].off = P[i].start - S[j].start;
			}
		if (P[i].sec < 0)
			reason(1, "partition_outside_section", "a partition goes beyond the sections (or the visible zone)");
	}

	/* sampling at the same LBAs */
	if (base >= 0 && mirror >= 0 && k > 0 && !block_all) {
		diff = sample(D[base].fd, D[mirror].fd, S, ns, k);
		if (diff < 0)
			reason(1, "read_error", "read error while sampling");
		else if (diff > 0)
			reason(1, "mirror_differs", "blocks differ between the two disks at the same LBAs");
	}

	key_s("MODE", block_all ? "none" : block_rw ? "ro" : "rw");
	for (i = 0; i < nd; i++)
		if (D[i].md) { key_s("MD", "1"); break; }
	key_n("N", D[ref].n);
	key_n("V", v);
	key_n("PROTECTED_ZONE", v);
	snprintf(buf, sizeof(buf), "%u.%u.%u", ver[0], ver[1], ver[2]);
	key_s("VERSION", buf);
	snprintf(buf, sizeof(buf), "%08x", be32(sb + 0x14));
	key_s("ID", buf);
	key_n("CTIME", be32(sb + 0x18));
	key_n("CLEAN", clean);
	key_n("UTIME", utime);
	key_n("ACTIVE_DISKS", active);
	key_n("WORKING_DISKS", working);
	key_n("FAILED_DISKS", failed);
	key_n("SPARE_DISKS", spare);
	key_n("NR_DISKS", nr_disks);
	key_s("BASE", base >= 0 ? D[base].path : "");
	key_s("MIRROR", mirror >= 0 ? D[mirror].path : "");
	key_s("READ_DISK", rd >= 0 ? D[rd].path : "");
	key_n("SAMPLES", (u64)(diff == -2 ? 0 : k));
	if (diff >= 0)
		key_n("DIFFERENCES", (u64)diff);

	/* disks */
	if (json) printf(",\"disks\":[");
	else printf("XR_NR_DISKS_READ=%d\n", nd);
	for (i = 0; i < nd; i++) {
		const char *role = D[i].role == 'b' ? "base" : D[i].role == 'm' ? "mirror" : "";
		const char *st = D[i].ref >= 0 ? state_name(be32(sb + 0x200 + 128 * D[i].channel + 0x10)) : "";
		char copies[64] = "";
		int c;
		for (c = 0; c < 4; c++)
			if (D[i].magic[c] == WGAO || D[i].magic[c] == WGAN) {
				strcat(copies, *copies ? "," : "");
				strcat(copies, COPY_NAME[c]);
			}
		if (json)
			printf("%s{\"path\":\"%s\",\"sectors\":%llu,\"role\":\"%s\",\"channel\":%d,\"state\":\"%s\",\"copies\":\"%s\",\"wgam\":%d,\"mbr\":%d,\"md\":%d}",
			       i ? "," : "", D[i].path, D[i].n, role, D[i].channel - 1, st, copies, D[i].wgam, D[i].mbr_ok, D[i].md);
		else
			printf("XR_D%d='%s %llu %s %d %s %s %d %d %d'\n", i, D[i].path, D[i].n, *role ? role : "-",
			       D[i].channel - 1, *st ? st : "-", *copies ? copies : "-", D[i].wgam, D[i].mbr_ok, D[i].md);
	}
	/* sections: start, usable sectors (bounded by V), level, initialised */
	if (json) printf("],\"sections\":[");
	else printf("XR_NR_SECTIONS=%d\n", ns);
	for (i = 0; i < ns; i++) {
		if (json)
			printf("%s{\"start\":%u,\"sectors\":%u,\"declared_sectors\":%u,\"raid\":%u,\"init\":%u,\"dmap\":%u,\"init_mark\":%u}",
			       i ? "," : "", S[i].start, S[i].end - S[i].start, S[i].nb, S[i].raid, S[i].init, S[i].dmap, S[i].init_mark);
		else
			printf("XR_S%d='%u %u %u %u'\n", i, S[i].start, S[i].end - S[i].start, S[i].raid, S[i].init);
	}
	/* partitions: number, start, size, type, section, offset in the section */
	if (json) printf("],\"partitions\":[");
	else printf("XR_NR_PARTS=%d\n", np);
	for (i = 0; i < np; i++) {
		if (json)
			printf("%s{\"num\":%d,\"start\":%u,\"sectors\":%u,\"type\":\"%02x\",\"section\":%d,\"offset\":%u}",
			       i ? "," : "", P[i].num, P[i].start, P[i].nb, P[i].type, P[i].sec, P[i].off);
		else
			printf("XR_P%d='%d %u %u %02x %d %u'\n", i, P[i].num, P[i].start, P[i].nb, P[i].type, P[i].sec, P[i].off);
	}
	if (json) {
		printf("],\"reasons\":[");
		for (i = 0; i < nr; i++) {
			const char *c;
			printf("%s{\"code\":\"%s\",\"text\":\"", i ? "," : "", r_code[i]);
			for (c = r_text[i]; *c; c++) {	/* some texts quote words */
				if (*c == '"')
					putchar('\\');
				putchar(*c);
			}
			printf("\"}");
		}
		printf("]}\n");
	} else {
		printf("XR_REASONS='");
		for (i = 0; i < nr; i++)
			printf("%s%s", i ? " " : "", r_code[i]);
		printf("'\n");
		for (i = 0; i < nr; i++)
			printf("# %s: %s\n", r_code[i], r_text[i]);
	}
	return 0;
}

/* sections in use, bounded by V (verify, quick); returns their number */
static int load_sections(const unsigned char *sb, struct section *S)
{
	unsigned v = be32(sb + 0x20);
	int i, ns = 0;
	for (i = 0; i < 7; i++) {
		const unsigned char *e = sb + 0x800 + 32 * i;
		if (!e[6])
			continue;
		S[ns].start = be32(e + 0x10);
		S[ns].end = S[ns].start + be32(e + 0x18);
		if (S[ns].end > v || S[ns].end < S[ns].start)
			S[ns].end = v;
		if (S[ns].end > S[ns].start)
			ns++;
	}
	return ns;
}

/* ---------- full mirror verification (read-only) ---------- */
static int verify(int argc, char **argv, unsigned zone_mib)
{
	static struct disk A, B;
	struct section S[7];
	const unsigned char *sb;
	unsigned char *a, *b;
	int i, ns, errors = 0;
	u64 total = 0, done = 0, zones = 0, first_diff = 0;
	const unsigned block = 1024 * 1024;
	unsigned pct = 101;

	if (argc != 2)
		die("verify: two disks expected");
	open_disk(&A, argv[0]);
	open_disk(&B, argv[1]);
	read_disk(&A);
	read_disk(&B);
	if (A.ref < 0 && B.ref < 0)
		die("no X-RAID superblock");
	sb = A.ref >= 0 ? A.sb[A.ref] : B.sb[B.ref];
	ns = load_sections(sb, S);
	for (i = 0; i < ns; i++)
		total += S[i].end - S[i].start;
	if (!zone_mib)
		zone_mib = 64;
	a = malloc(block);
	b = malloc(block);
	if (!a || !b)
		die("out of memory");
	for (i = 0; i < ns; i++) {
		u64 lba = S[i].start, zone_diff = (u64)-1;
		while (lba < S[i].end) {
			u64 nb = S[i].end - lba;
			size_t len;
			int attempt, d = 1;
			if (nb > block / 512)
				nb = block / 512;
			len = (size_t)nb * 512;
			/* a difference may come from a write in progress: read again 3 times */
			for (attempt = 0; attempt < 3 && d; attempt++) {
				if (attempt)
					sleep(1);
				if (read_at(A.fd, lba * 512, a, len) || read_at(B.fd, lba * 512, b, len)) {
					fprintf(stderr, "read error near LBA %llu\n", lba);
					errors++;
					d = 0;
					break;
				}
				d = memcmp(a, b, len) != 0;
			}
			if (d) {
				u64 z = (lba - S[i].start) / ((u64)zone_mib * 2048);
				if (z != zone_diff) {
					zone_diff = z;
					if (!zones)
						first_diff = lba;
					zones++;
					printf("# difference section %d zone %llu (LBA %llu)\n", i, z,
					       S[i].start + z * (u64)zone_mib * 2048);
				}
			}
			lba += nb;
			done += nb;
			if (done * 100 / total != pct) {
				pct = (unsigned)(done * 100 / total);
				fprintf(stderr, "progress %u%%\n", pct);
			}
		}
	}
	first = 1;
	if (json) printf("{");
	key_s("RESULT", errors ? "errors" : zones ? "differences" : "identical");
	key_n("SECTORS_COMPARED", done);
	key_n("DIFFERENT_ZONES", zones);
	key_n("ZONE_MIB", zone_mib);
	key_n("FIRST_DIFFERENCE", first_diff);
	key_n("READ_ERRORS", (u64)errors);
	if (json) printf("}\n");
	return errors ? 2 : zones ? 1 : 0;
}

/* ---------- quick check: the areas a power cut most likely leaves different ----------
 * Ranges (disk LBAs, clipped to the sections) compared base / mirror:
 *   partition  EBRs of the extended partition (the MBR is on the base only)
 *   lvm        start of p5 up to pe_start: LVM label and metadata
 *   superblock ext3 superblock and group descriptors, and their backups
 *   bitmap     block and inode bitmaps of every group
 *   inode_table inode table blocks holding an inode in use (either disk)
 *   journal    the ext3 journal (inode 8) and its indirect blocks
 *   sample     random 64 KiB blocks over the whole sections
 * for the system file system (p1, section 0) and the data one (LV "c" in the
 * LVM group on p5, located through the LVM text metadata). Structures are read
 * on the first disk (the base). File data outside these areas is only covered
 * by the samples. Exit: 0 identical, 1 differences, 2 errors, 3 identical but
 * incomplete (a file system or its journal could not be located). */
enum { C_PART, C_LVM, C_SB, C_BITMAP, C_ITABLE, C_JOURNAL, C_SAMPLE, NCAT };
static const char *CAT[NCAT] = { "partition", "lvm", "superblock", "bitmap", "inode_table", "journal", "sample" };
static const char *FSN[3] = { "-", "system", "data" };
#define XR_LV "c"			/* RAIDiator's logical volume */
#define ITABLE_MAX (256ULL << 20)	/* ponytail: inode tables beyond this are left to the samples */

struct rng { u64 lba, n; int cat, fs; };
static struct rng *rg;
static int nrg, rg_cap;
static struct section QS[7];
static int qns;
static u64 unmapped, itable_bytes, itable_skipped;
static const char *notes[16];
static int nnotes, incomplete;

static void note(int fatal, const char *s)
{
	if (nnotes < 16)
		notes[nnotes++] = s;
	incomplete |= fatal;
}

static u64 le64(const unsigned char *p) { return (u64)le32(p + 4) << 32 | le32(p); }
static unsigned le16(const unsigned char *p) { return (unsigned)p[1] << 8 | p[0]; }

/* adds [lba, lba+n) clipped to the sections; merges with the previous one when contiguous */
static void add(int cat, int fs, u64 lba, u64 n)
{
	int i;
	for (i = 0; i < qns; i++) {
		u64 a = lba > QS[i].start ? lba : QS[i].start, b = lba + n < QS[i].end ? lba + n : QS[i].end;
		struct rng *l = nrg ? &rg[nrg - 1] : NULL;
		if (a >= b)
			continue;
		if (l && l->cat == cat && l->fs == fs && l->lba + l->n == a && cat != C_SAMPLE) {
			l->n += b - a;
			continue;
		}
		if (nrg == rg_cap) {
			rg_cap = rg_cap ? 2 * rg_cap : 1024;
			rg = realloc(rg, rg_cap * sizeof(*rg));
			if (!rg)
				die("out of memory");
		}
		rg[nrg].lba = a; rg[nrg].n = b - a; rg[nrg].cat = cat; rg[nrg].fs = fs;
		nrg++;
	}
}

/* a volume: a partition (nseg < 0) or a linear LV on the PV of a partition */
struct vol {
	u64 part, pe, ext;		/* sectors: partition start, pe_start, extent size */
	int nseg, fs;
	struct { u64 le, n, pe; } seg[32];
};

/* disk byte of volume byte off, *len cut to what is contiguous; -1 if unmapped */
static u64 vmap(const struct vol *v, u64 off, u64 *len)
{
	int i;
	if (v->nseg < 0)
		return v->part * 512 + off;
	for (i = 0; i < v->nseg; i++) {
		u64 a = v->seg[i].le * v->ext * 512, b = a + v->seg[i].n * v->ext * 512;
		if (off >= a && off < b) {
			if (*len > b - off)
				*len = b - off;
			return (v->part + v->pe + v->seg[i].pe * v->ext) * 512 + off - a;
		}
	}
	for (i = 0; i < v->nseg; i++) {	/* unmapped up to the next segment */
		u64 a = v->seg[i].le * v->ext * 512;
		if (a > off && *len > a - off)
			*len = a - off;
	}
	return (u64)-1;
}

static int vread(int fd, const struct vol *v, u64 off, void *buf, u64 len)
{
	while (len) {
		u64 l = len, d = vmap(v, off, &l);
		if (d == (u64)-1 || read_at(fd, d, buf, (size_t)l))
			return -1;
		buf = (char *)buf + l; off += l; len -= l;
	}
	return 0;
}

static void vadd(int cat, const struct vol *v, u64 off, u64 len)
{
	while (len) {
		u64 l = len, d = vmap(v, off, &l);
		if (d == (u64)-1)
			unmapped += l;
		else
			add(cat, v->fs, d / 512, (d % 512 + l + 511) / 512);
		off += l; len -= l;
	}
}

/* ext3 journal (or any indirect-mapped inode): data and indirect blocks */
static u64 jleft;
static void jwalk(int fd, const struct vol *v, unsigned bs, unsigned blk, int level)
{
	unsigned char *b;
	unsigned i;
	if (!blk || !jleft)
		return;
	vadd(C_JOURNAL, v, (u64)blk * bs, bs);
	if (!level) {
		jleft--;
		return;
	}
	b = malloc(bs);
	if (!b || vread(fd, v, (u64)blk * bs, b, bs))
		die("cannot read an indirect block of the journal");
	for (i = 0; i < bs / 4 && jleft; i++)
		jwalk(fd, v, bs, le32(b + 4 * i), level - 1);
	free(b);
}

static int backup_group(unsigned g, int sparse)
{
	unsigned p;
	if (g <= 1 || !sparse)
		return 1;
	for (p = 3; p <= 7; p += 2) {
		u64 x = p;
		while (x < g)
			x *= p;
		if (x == g)
			return 1;
	}
	return 0;
}

/* ext3 metadata ranges of a volume; fa = base (structures), fb = mirror */
static void ext3_ranges(int fa, int fb, const struct vol *v, const char *what)
{
	unsigned char s[1024], ino[1024], *gdt, *ba, *bb;
	unsigned bs, bpg, ipg, isz, ds, first, ng, gdtb, g, j, k, ipb, jino, flags;
	u64 blocks;
	static char msg[2][96];
	char *m = msg[v->fs - 1];

	if (vread(fa, v, 1024, s, 1024) || le16(s + 0x38) != 0xEF53 || le32(s + 0x18) > 6) {
		snprintf(m, 96, "%s: no ext3 superblock found", what);
		note(1, m);
		return;
	}
	bs = 1024u << le32(s + 0x18);
	blocks = le32(s + 4);
	first = le32(s + 0x14);
	bpg = le32(s + 0x20);
	ipg = le32(s + 0x28);
	isz = le32(s + 0x4C) ? le16(s + 0x58) : 128;
	ds = (le32(s + 0x60) & 0x80) && le16(s + 0xFE) >= 32 ? le16(s + 0xFE) : 32;
	if (!bpg || !ipg || isz < 128 || isz > 1024 || isz > bs || ipg % (bs / isz) || blocks <= first) {
		snprintf(m, 96, "%s: inconsistent ext3 superblock", what);
		note(1, m);
		return;
	}
	ng = (unsigned)((blocks - first + bpg - 1) / bpg);
	gdtb = (unsigned)(((u64)ng * ds + bs - 1) / bs);
	ipb = bs / isz;
	gdt = malloc((size_t)gdtb * bs);
	ba = malloc(bs);
	bb = malloc(bs);
	if (!gdt || !ba || !bb)
		die("out of memory");
	if (vread(fa, v, (u64)(first + 1) * bs, gdt, (u64)gdtb * bs))
		die("%s: cannot read the group descriptors", what);
	for (g = 0; g < ng; g++) {
		const unsigned char *d = gdt + (size_t)g * ds;
		unsigned it = le32(d + 8), ib = le32(d + 4);
		if (backup_group(g, le32(s + 0x64) & 1))
			vadd(C_SB, v, ((u64)g * bpg + first) * bs, (u64)(1 + gdtb) * bs);
		vadd(C_BITMAP, v, (u64)le32(d) * bs, bs);
		vadd(C_BITMAP, v, (u64)ib * bs, bs);
		/* inode table: the blocks holding an inode in use on either disk */
		if (vread(fa, v, (u64)ib * bs, ba, bs) || vread(fb, v, (u64)ib * bs, bb, bs))
			die("%s: cannot read an inode bitmap", what);
		for (j = 0; j < ipg / ipb; j++) {
			int used = 0;
			for (k = j * ipb; k < (j + 1) * ipb && !used; k++)
				used = (ba[k / 8] | bb[k / 8]) >> (k % 8) & 1;
			if (!used)
				continue;
			if (itable_bytes + bs > ITABLE_MAX) {
				itable_skipped += bs;
				continue;
			}
			itable_bytes += bs;
			vadd(C_ITABLE, v, (u64)(it + j) * bs, bs);
		}
	}
	/* journal: has_journal, inode s_journal_inum, indirect blocks (ext3) */
	jino = le32(s + 0xE0);
	if (!(le32(s + 0x5C) & 4) || !jino || jino > ng * ipg) {
		snprintf(m, 96, "%s: no internal journal", what);
		note(1, m);
	} else {
		const unsigned char *d = gdt + (size_t)((jino - 1) / ipg) * ds;
		if (vread(fa, v, (u64)le32(d + 8) * bs + (u64)((jino - 1) % ipg) * isz, ino, isz))
			die("%s: cannot read the journal inode", what);
		flags = le32(ino + 0x20);
		jleft = le32(ino + 4) / bs;
		if (flags & 0x80000) {	/* ponytail: extent-mapped journal (ext4) not walked */
			snprintf(m, 96, "%s: extent-mapped journal not supported", what);
			note(1, m);
		} else {
			for (k = 0; k < 12; k++)
				jwalk(fa, v, bs, le32(ino + 0x28 + 4 * k), 0);
			for (k = 0; k < 3; k++)
				jwalk(fa, v, bs, le32(ino + 0x28 + 4 * (12 + k)), k + 1);
			if (jleft) {
				snprintf(m, 96, "%s: journal shorter than its size", what);
				note(1, m);
			}
		}
	}
	free(gdt); free(ba); free(bb);
}

/* LVM text metadata: end of the block opened at p ('{'), or NULL */
static const char *blk_end(const char *p, const char *e)
{
	int d = 0;
	for (; p < e; p++) {
		if (*p == '"') {
			for (p++; p < e && *p != '"'; p++)
				if (*p == '\\')
					p++;
		} else if (*p == '#') {
			while (p < e && *p != '\n')
				p++;
		} else if (*p == '{')
			d++;
		else if (*p == '}' && !--d)
			return p;
	}
	return NULL;
}

static int wordc(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.' || c == '+'; }

/* at this level of [p, e): block "name {" (blk: points at '{'; name NULL = the
 * first block, *nm gets its name) or value of "name =" (points after '=') */
static const char *lv_find(const char *p, const char *e, const char *name, int blk, char *nm)
{
	while (p < e) {
		if (*p == '#') {
			while (p < e && *p != '\n')
				p++;
		} else if (*p == '"') {
			for (p++; p < e && *p != '"'; p++)
				if (*p == '\\')
					p++;
			p++;
		} else if (wordc(*p)) {
			const char *w = p, *q;
			int match;
			while (p < e && wordc(*p))
				p++;
			for (q = p; q < e && (*q == ' ' || *q == '\t' || *q == '\n' || *q == '\r'); q++)
				;
			match = name ? (size_t)(p - w) == strlen(name) && !memcmp(w, name, (size_t)(p - w)) : 1;
			if (q < e && *q == '{') {
				if (blk && match) {
					if (nm)
						snprintf(nm, 64, "%.*s", (int)(p - w), w);
					return q;
				}
				p = blk_end(q, e);
				if (!p)
					return NULL;
				p++;
			} else if (q < e && *q == '=' && !blk && match) {
				for (q++; q < e && (*q == ' ' || *q == '\t'); q++)
					;
				return q;
			}
		} else
			p++;
	}
	return NULL;
}

static u64 lv_num(const char *p, const char *e, const char *name, int *bad)
{
	const char *v = lv_find(p, e, name, 0, NULL);
	if (!v || *v < '0' || *v > '9') {
		*bad = 1;
		return 0;
	}
	return strtoull(v, NULL, 10);
}

/* LV "c" on the PV of partition p5 (lba): label, metadata area, text */
static int lvm_vol(int fd, u64 part, u64 psize, struct vol *v)
{
	unsigned char s[512], m[512];
	const unsigned char *d;
	char id[40], nm[64], pvname[64] = "", *t;
	const char *e, *vg, *ve, *x, *xe, *lv, *le;
	u64 mda, mdasz, off, size, first;
	int i, k, bad = 0;

	for (i = 0; i < 4; i++)
		if (!read_at(fd, (part + i) * 512, s, 512) && !memcmp(s, "LABELONE", 8) && !memcmp(s + 24, "LVM2 001", 8))
			break;
	if (i == 4 || le32(s + 20) != 32)
		return -1;
	/* pv_header at +32: uuid[32], device size, data areas, 0, metadata areas, 0 */
	snprintf(id, sizeof(id), "%.6s-%.4s-%.4s-%.4s-%.4s-%.4s-%.6s", s + 32, s + 38, s + 42, s + 46, s + 50, s + 54, s + 58);
	d = s + 32 + 40;
	v->pe = le64(d) / 512;
	while (le64(d) && d < s + 480)
		d += 16;
	d += 16;
	mda = le64(d); mdasz = le64(d + 8);
	if (!mda || mdasz < 1024 || mda + mdasz > psize * 512 || read_at(fd, part * 512 + mda, m, 512)
	    || memcmp(m + 4, " LVM2 x[5A%r0N*>", 16))
		return -1;
	off = le64(m + 40); size = le64(m + 48);	/* raw_locn[0], relative to the area */
	if (off < 512 || off >= mdasz || !size || size > mdasz - 512)
		return -1;
	t = malloc(size + 1);
	if (!t)
		die("out of memory");
	first = size < mdasz - off ? size : mdasz - off;	/* circular buffer */
	if (read_at(fd, part * 512 + mda + off, t, first)
	    || (first < size && read_at(fd, part * 512 + mda + 512, t + first, size - first))) {
		free(t);
		return -1;
	}
	t[size] = 0;
	e = t + strlen(t);
	vg = lv_find(t, e, NULL, 1, NULL);
	ve = vg ? blk_end(vg, e) : NULL;
	if (!ve)
		goto bad;
	v->ext = lv_num(vg + 1, ve, "extent_size", &bad);
	/* our PV: the one whose id is the label's uuid */
	x = lv_find(vg + 1, ve, "physical_volumes", 1, NULL);
	xe = x ? blk_end(x, ve) : NULL;
	for (x = x ? x + 1 : NULL; x && xe && (x = lv_find(x, xe, NULL, 1, nm)); x = blk_end(x, xe) + 1) {
		const char *pe = blk_end(x, xe), *q = pe ? lv_find(x + 1, pe, "id", 0, NULL) : NULL;
		if (q && *q == '"' && !strncmp(q + 1, id, strlen(id)) && q[1 + strlen(id)] == '"') {
			snprintf(pvname, sizeof(pvname), "%s", nm);
			break;
		}
		if (!pe)
			break;
	}
	x = lv_find(vg + 1, ve, "logical_volumes", 1, NULL);
	xe = x ? blk_end(x, ve) : NULL;
	lv = xe ? lv_find(x + 1, xe, XR_LV, 1, NULL) : NULL;
	le = lv ? blk_end(lv, xe) : NULL;
	if (!le || !*pvname || bad || !v->ext)
		goto bad;
	v->nseg = 0;
	for (k = 1; k <= 32; k++) {
		const char *sg, *se, *q;
		char segn[16], pv[64];
		unsigned long long pe;
		snprintf(segn, sizeof(segn), "segment%d", k);
		sg = lv_find(lv + 1, le, segn, 1, NULL);
		se = sg ? blk_end(sg, le) : NULL;
		if (!se)
			break;
		q = lv_find(sg + 1, se, "type", 0, NULL);
		if (!q || strncmp(q, "\"striped\"", 9) || lv_num(sg + 1, se, "stripe_count", &bad) != 1)
			goto bad;
		q = lv_find(sg + 1, se, "stripes", 0, NULL);
		if (!q || sscanf(q, "[ \"%63[^\"]\" , %llu", pv, &pe) != 2)
			goto bad;
		if (strcmp(pv, pvname)) {	/* on another PV: left to the samples */
			note(1, "data: part of the volume is on another PV");
			continue;
		}
		v->seg[v->nseg].le = lv_num(sg + 1, se, "start_extent", &bad);
		v->seg[v->nseg].n = lv_num(sg + 1, se, "extent_count", &bad);
		v->seg[v->nseg].pe = pe;
		v->nseg++;
	}
	if (bad || !v->nseg)
		goto bad;
	free(t);
	return 0;
bad:
	free(t);
	return -1;
}

static int rng_cmp(const void *a, const void *b)
{
	const struct rng *x = a, *y = b;
	return x->lba < y->lba ? -1 : x->lba > y->lba;
}

static int quick(int argc, char **argv, int k, unsigned long long seed, int list)
{
	static struct disk A, B;
	static struct part P[MAXP];
	static unsigned char a[1 << 20], b[1 << 20];
	struct vol sys, dat;
	u64 bytes[NCAT] = { 0 }, total = 0, done = 0, x;
	int diffs[NCAT] = { 0 }, np, i, j, errors = 0, nd = 0, ndiff = 0;
	unsigned pct = 101;
	struct { int cat, fs; u64 lba; } zone[32];

	if (argc != 2)
		die("quick: two disks expected (base, then mirror)");
	open_disk(&A, argv[0]);
	open_disk(&B, argv[1]);
	read_disk(&A);
	read_disk(&B);
	if (A.ref < 0)
		die("no X-RAID superblock on the base disk");
	if (!A.mbr_ok)
		die("the first disk has no MBR: give the base disk first");
	qns = load_sections(A.sb[A.ref], QS);
	np = read_parts(A.mbr, A.fd, P);

	for (i = 0; i < nebr; i++)
		add(C_PART, 0, ebr_lba[i], 1);
	memset(&sys, 0, sizeof(sys));
	memset(&dat, 0, sizeof(dat));
	sys.nseg = -1; sys.fs = 1; dat.fs = 2;
	for (i = 0; i < np && !sys.part; i++)
		if (P[i].num == 1)
			sys.part = P[i].start;
	if (sys.part)
		ext3_ranges(A.fd, B.fd, &sys, "system");
	else
		note(1, "system: no partition 1");
	for (i = 0; i < np && !dat.part; i++)
		if (P[i].type == 0x8e) {
			dat.part = P[i].start;
			if (lvm_vol(A.fd, P[i].start, P[i].nb, &dat) == 0) {
				add(C_LVM, 0, P[i].start, dat.pe);
				ext3_ranges(A.fd, B.fd, &dat, "data");
			} else {
				add(C_LVM, 0, P[i].start, 2048);	/* label and usual metadata area */
				note(1, "data: LVM metadata or LV \"" XR_LV "\" not understood");
			}
		}
	if (!dat.part)
		note(1, "data: no LVM partition");
	if (unmapped)
		note(1, "data: part of the file system is outside the LVM segments");
	if (itable_skipped)
		note(0, "inode tables: in-use blocks beyond 256 MiB left to the samples");
	/* random 64 KiB samples, aligned, over each section */
	if (!seed)
		seed = (unsigned long long)time(NULL) ^ (unsigned long long)getpid() << 32;
	x = seed;
	for (i = 0; i < qns; i++) {
		u64 lg = QS[i].end - QS[i].start;
		if (lg < SAMPLE_LEN / 512)
			continue;
		for (j = 0; j < k; j++) {
			x ^= x << 13; x ^= x >> 7; x ^= x << 17;	/* xorshift64 */
			add(C_SAMPLE, 0, QS[i].start + x % (lg / (SAMPLE_LEN / 512)) * (SAMPLE_LEN / 512), SAMPLE_LEN / 512);
		}
	}
	qsort(rg, (size_t)nrg, sizeof(*rg), rng_cmp);	/* one pass over each disk */
	for (i = 0; i < nrg; i++)
		total += rg[i].n;
	if (list) {
		for (i = 0; i < nrg; i++)
			printf("%s %s %llu %llu\n", CAT[rg[i].cat], FSN[rg[i].fs], rg[i].lba, rg[i].n);
		return 0;
	}

	for (i = 0; i < nrg; i++) {
		u64 lba = rg[i].lba, end = rg[i].lba + rg[i].n;
		bytes[rg[i].cat] += rg[i].n * 512;
		while (lba < end) {
			u64 n = end - lba > sizeof(a) / 512 ? sizeof(a) / 512 : end - lba;
			size_t len = (size_t)n * 512, o = 0;
			int attempt, d = 1;
			/* a difference may come from a write in progress: read again 3 times */
			for (attempt = 0; attempt < 3 && d; attempt++) {
				if (attempt)
					sleep(1);
				if (read_at(A.fd, lba * 512, a, len) || read_at(B.fd, lba * 512, b, len)) {
					fprintf(stderr, "read error near LBA %llu\n", lba);
					errors++;
					d = 0;
					break;
				}
				d = memcmp(a, b, len) != 0;
			}
			if (d) {
				while (o < len && a[o] == b[o])
					o++;
				diffs[rg[i].cat]++;
				ndiff++;
				if (nd < 32) {
					zone[nd].cat = rg[i].cat; zone[nd].fs = rg[i].fs; zone[nd].lba = lba + o / 512;
					nd++;
				}
			}
			lba += n;
			done += n;
			if (done * 100 / total != pct) {
				pct = (unsigned)(done * 100 / total);
				fprintf(stderr, "progress %u%%\n", pct);
			}
		}
	}

	first = 1;
	if (json) printf("{");
	key_s("RESULT", errors ? "errors" : ndiff ? "differences" : incomplete ? "incomplete" : "identical");
	key_n("COMPLETE", !incomplete);
	key_n("SEED", seed);
	key_n("BYTES", total * 512);
	key_n("DIFFERENCES", (u64)ndiff);
	key_n("READ_ERRORS", (u64)errors);
	if (json) {
		printf(",\"categories\":[");
		for (i = 0; i < NCAT; i++)
			printf("%s{\"name\":\"%s\",\"bytes\":%llu,\"differences\":%d}", i ? "," : "", CAT[i], bytes[i], diffs[i]);
		printf("],\"zones\":[");
		for (i = 0; i < nd; i++)
			printf("%s{\"category\":\"%s\",\"fs\":\"%s\",\"lba\":%llu}", i ? "," : "", CAT[zone[i].cat], FSN[zone[i].fs], zone[i].lba);
		printf("],\"notes\":[");
		for (i = 0; i < nnotes; i++) {
			const char *c;
			printf("%s\"", i ? "," : "");
			for (c = notes[i]; *c; c++)
				printf(*c == '"' || *c == '\\' ? "\\%c" : "%c", *c);
			putchar('"');
		}
		printf("]}\n");
	} else {
		for (i = 0; i < NCAT; i++)	/* bytes compared, differing chunks */
			printf("XR_CAT_%s='%llu %d'\n", CAT[i], bytes[i], diffs[i]);
		for (i = 0; i < nd; i++)
			printf("# difference %s %s LBA %llu\n", CAT[zone[i].cat], FSN[zone[i].fs], zone[i].lba);
		for (i = 0; i < nnotes; i++)
			printf("# note: %s\n", notes[i]);
	}
	return errors ? 2 : ndiff ? 1 : incomplete ? 3 : 0;
}

/* ---------- SMART through ATA PASS-THROUGH (16), without smartctl ---------- */
static int ata16(int fd, unsigned char *cdb, unsigned char *data, int lg, unsigned char *sense)
{
	sg_io_hdr_t h;
	memset(&h, 0, sizeof(h));
	memset(sense, 0, 32);
	h.interface_id = 'S';
	h.cmd_len = 16;
	h.cmdp = cdb;
	h.dxfer_direction = lg ? SG_DXFER_FROM_DEV : SG_DXFER_NONE;
	h.dxferp = data;
	h.dxfer_len = (unsigned)lg;
	h.sbp = sense;
	h.mx_sb_len = 32;
	h.timeout = 15000;
	return ioctl(fd, SG_IO, &h);
}

static int smart(const char *path)
{
	unsigned char cdb[16], data[512], sense[32], sum = 0, mid = 0, high = 0;
	unsigned long long realloc = 0, pending = 0, uncorr = 0, hours = 0;
	const char *health = "";
	int fd = open(path, O_RDONLY | O_NONBLOCK), i;
	if (fd < 0)
		die("%s: %s", path, strerror(errno));
	/* SMART READ DATA: PIO data-in, 1 sector */
	memset(cdb, 0, 16);
	cdb[0] = 0x85; cdb[1] = 4 << 1; cdb[2] = 0x0e;
	cdb[4] = 0xD0; cdb[6] = 1; cdb[10] = 0x4f; cdb[12] = 0xc2; cdb[14] = 0xB0;
	if (ata16(fd, cdb, data, 512, sense) < 0)
		die("%s: SG_IO refused (%s)", path, strerror(errno));
	for (i = 0; i < 512; i++)
		sum += data[i];
	if (sum)
		die("%s: unreadable SMART data (checksum)", path);
	for (i = 0; i < 30; i++) {
		const unsigned char *e = data + 2 + 12 * i;
		u64 raw = (u64)e[5] | (u64)e[6] << 8 | (u64)e[7] << 16 | (u64)e[8] << 24;
		switch (e[0]) {
		case 5: realloc = raw; break;
		case 9: hours = raw; break;
		case 197: pending = raw; break;
		case 198: uncorr = raw; break;
		}
	}
	/* SMART RETURN STATUS: non-data, CK_COND to read back LBA mid/high */
	memset(cdb, 0, 16);
	cdb[0] = 0x85; cdb[1] = 3 << 1; cdb[2] = 0x20;
	cdb[4] = 0xDA; cdb[10] = 0x4f; cdb[12] = 0xc2; cdb[14] = 0xB0;
	if (ata16(fd, cdb, NULL, 0, sense) == 0) {
		if ((sense[0] & 0x7f) == 0x72 && sense[8] == 0x09) {	/* ATA descriptor */
			mid = sense[8 + 9]; high = sense[8 + 11];
		} else if ((sense[0] & 0x7f) == 0x70) {			/* fixed format (libata) */
			mid = sense[10]; high = sense[11];
		}
		if (mid == 0x4f && high == 0xc2)
			health = "PASSED";
		else if (mid == 0xf4 && high == 0x2c)
			health = "FAILED";
	}
	close(fd);
	if (json)
		printf("{\"health\":\"%s\",\"realloc\":%llu,\"pending\":%llu,\"uncorr\":%llu,\"hours\":%llu}\n",
		       health, realloc, pending, uncorr, hours);
	else	/* same format as /var/run/smart.sdX (diet-hwmon) */
		printf("health=%s realloc=%llu pending=%llu uncorr=%llu hours=%llu\n",
		       health, realloc, pending, uncorr, hours);
	return 0;
}

int main(int argc, char **argv)
{
	int k = 0, list = 0;
	unsigned zone = 0;
	unsigned long long seed = 0;
	const char *cmd = "analyse";

	argc--, argv++;
	if (argc && (!strcmp(argv[0], "verify") || !strcmp(argv[0], "smart") || !strcmp(argv[0], "quick")))
		cmd = argv[0], argc--, argv++;
	while (argc && argv[0][0] == '-' && argv[0][1] == '-') {
		if (!strcmp(argv[0], "--json"))
			json = 1;
		else if (!strcmp(argv[0], "--samples") && argc > 1)
			k = atoi(argv[1]), argc--, argv++;
		else if (!strcmp(argv[0], "--seed") && argc > 1)
			seed = strtoull(argv[1], NULL, 0), argc--, argv++;
		else if (!strcmp(argv[0], "--list"))
			list = 1;
		else if (!strcmp(argv[0], "--zone") && argc > 1)
			zone = (unsigned)atoi(argv[1]), argc--, argv++;
		else
			die("unknown option %s (see the header of xraid-info.c)", argv[0]);
		argc--, argv++;
	}
	if (k < 0 || k > 100000)
		die("--samples: 0..100000");
	if (!strcmp(cmd, "verify"))
		return verify(argc, argv, zone);
	if (!strcmp(cmd, "quick"))
		return quick(argc, argv, k, seed, list);
	if (!strcmp(cmd, "smart")) {
		if (argc != 1)
			die("smart: one disk");
		return smart(argv[0]);
	}
	return analyse(argc, argv, k);
}
