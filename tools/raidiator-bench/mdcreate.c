/*
 * mdcreate: create an md array with a 0.90 superblock the way RAIDiator's
 * mdconfig does ("mdconfig -a new"): the legacy md ioctls SET_ARRAY_INFO,
 * ADD_NEW_DISK for each member, RUN_ARRAY; the kernel writes the superblocks.
 * Used by bench.sh for every array: mdconfig cannot run under QEMU user mode
 * (no md ioctls there), and mdadm 4.x refuses RAID 0 on 0.90 ("0.90 metadata
 * does not support layouts for RAID0"). Test bench only.
 *
 *   mdcreate /dev/mdN LEVEL CHUNK_KB MEMBER...
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <linux/fs.h>
#include <linux/major.h>
#include <linux/raid/md_p.h>
#include <linux/raid/md_u.h>

static void die(const char *what)
{
	fprintf(stderr, "mdcreate: %s: %s\n", what, strerror(errno));
	exit(1);
}

int main(int argc, char **argv)
{
	mdu_array_info_t a;
	unsigned long long kb, min_kb = 0;
	struct stat st;
	int fd, i, n = argc - 4, level, chunk_kb;

	if (argc < 5) {
		fprintf(stderr, "usage: mdcreate /dev/mdN LEVEL CHUNK_KB MEMBER...\n");
		return 2;
	}
	level = atoi(argv[2]);
	chunk_kb = atoi(argv[3]);
	if (chunk_kb < 4 || (chunk_kb & (chunk_kb - 1))) {
		fprintf(stderr, "mdcreate: chunk must be a power of 2, at least 4 KiB\n");
		return 2;
	}
	/* size of each member as md 0.90 sees it: up to its superblock, in KiB,
	 * rounded down to the chunk */
	for (i = 0; i < n; i++) {
		unsigned long long bytes;
		int m = open(argv[4 + i], O_RDONLY);
		if (m < 0 || ioctl(m, BLKGETSIZE64, &bytes))
			die(argv[4 + i]);
		close(m);
		kb = (MD_NEW_SIZE_SECTORS(bytes / 512) / 2) & ~(unsigned long long)(chunk_kb - 1);
		if (!min_kb || kb < min_kb)
			min_kb = kb;
	}
	if (stat(argv[1], &st)) {
		int minor = atoi(argv[1] + strcspn(argv[1], "0123456789"));
		if (mknod(argv[1], S_IFBLK | 0600, makedev(MD_MAJOR, minor)))
			die(argv[1]);
	}
	fd = open(argv[1], O_RDWR);
	if (fd < 0 || fstat(fd, &st))
		die(argv[1]);
	memset(&a, 0, sizeof(a));
	a.major_version = 0;
	a.minor_version = 90;
	a.level = level;
	a.size = (int)min_kb;
	a.nr_disks = n;
	a.raid_disks = n;
	a.md_minor = minor(st.st_rdev);
	a.not_persistent = 0;
	a.state = 1 << MD_SB_CLEAN;
	a.layout = 0;
	a.chunk_size = chunk_kb * 1024;
	if (ioctl(fd, SET_ARRAY_INFO, &a))
		die("SET_ARRAY_INFO");
	for (i = 0; i < n; i++) {
		mdu_disk_info_t d;
		if (stat(argv[4 + i], &st))
			die(argv[4 + i]);
		memset(&d, 0, sizeof(d));
		d.number = i;
		d.raid_disk = i;
		d.major = major(st.st_rdev);
		d.minor = minor(st.st_rdev);
		d.state = (1 << MD_DISK_ACTIVE) | (1 << MD_DISK_SYNC);
		if (ioctl(fd, ADD_NEW_DISK, &d))
			die("ADD_NEW_DISK");
	}
	if (ioctl(fd, RUN_ARRAY, 0))
		die("RUN_ARRAY");
	close(fd);
	return 0;
}
