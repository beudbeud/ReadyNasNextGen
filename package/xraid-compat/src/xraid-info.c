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

/* partitions from an MBR; EBRs read from the read disk */
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

/* ---------- full mirror verification (read-only) ---------- */
static int verify(int argc, char **argv, unsigned zone_mib)
{
	static struct disk A, B;
	struct section S[7];
	const unsigned char *sb;
	unsigned char *a, *b;
	unsigned v;
	int i, ns = 0, errors = 0;
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
	v = be32(sb + 0x20);
	for (i = 0; i < 7; i++) {
		const unsigned char *e = sb + 0x800 + 32 * i;
		if (!e[6])
			continue;
		S[ns].start = be32(e + 0x10);
		S[ns].end = S[ns].start + be32(e + 0x18);
		if (S[ns].end > v || S[ns].end < S[ns].start)
			S[ns].end = v;
		if (S[ns].end > S[ns].start)
			total += S[ns].end - S[ns].start, ns++;
	}
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
	int k = 0;
	unsigned zone = 0;
	const char *cmd = "analyse";

	argc--, argv++;
	if (argc && (!strcmp(argv[0], "verify") || !strcmp(argv[0], "smart")))
		cmd = argv[0], argc--, argv++;
	while (argc && argv[0][0] == '-' && argv[0][1] == '-') {
		if (!strcmp(argv[0], "--json"))
			json = 1;
		else if (!strcmp(argv[0], "--samples") && argc > 1)
			k = atoi(argv[1]), argc--, argv++;
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
	if (!strcmp(cmd, "smart")) {
		if (argc != 1)
			die("smart: one disk");
		return smart(argv[0]);
	}
	return analyse(argc, argv, k);
}
