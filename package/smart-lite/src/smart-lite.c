/*
 * smart-lite: read-only ATA SMART reader for libata disks (SG_IO, ATA
 * PASS-THROUGH (16)), without C++ (smartmontools) nor udev (libatasmart).
 *
 *   smart-lite [-f] [-s] /dev/sdX    read a disk
 *   smart-lite -t short|long|abort /dev/sdX
 *                                    start (or abort) a SMART self-test
 *   smart-lite -F [-s] identify.bin smart.bin thresh.bin [PASSED|FAILED]
 *                                    decode saved sectors (tests on a PC)
 *
 * Commands sent: CHECK POWER MODE, IDENTIFY DEVICE, SMART READ DATA,
 * SMART READ THRESHOLDS, SMART RETURN STATUS; with -t only, SMART EXECUTE
 * OFF-LINE IMMEDIATE (self-test in the background on the disk: data untouched,
 * the disk keeps serving requests). Nothing else changes the disk.
 * A disk in standby is left asleep (prints STANDBY, exit 2) unless -f.
 * -s prints one shell line (health= realloc= pending= uncorr= hours= celsius=
 * cycles= selftest= left= short_min= long_min=), the format of
 * /var/run/smart.sdX read by DIET. selftest = last self-test status nibble
 * (0 done without error or never run, 1 aborted by host, 2 interrupted by a
 * reset, 3-8 failed, 15 running), left = percent still to do while running.
 * Exit: 0 read, 1 error, 2 disk in standby (not read).
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <scsi/sg.h>
#include <sys/ioctl.h>

typedef unsigned char u8;

static const struct { u8 id; const char *name; } names[] = {
	{1, "Raw_Read_Error_Rate"}, {2, "Throughput_Performance"},
	{3, "Spin_Up_Time"}, {4, "Start_Stop_Count"},
	{5, "Reallocated_Sector_Ct"}, {7, "Seek_Error_Rate"},
	{8, "Seek_Time_Performance"}, {9, "Power_On_Hours"},
	{10, "Spin_Retry_Count"}, {11, "Calibration_Retry_Count"},
	{12, "Power_Cycle_Count"}, {183, "Runtime_Bad_Block"},
	{184, "End-to-End_Error"}, {187, "Reported_Uncorrect"},
	{188, "Command_Timeout"}, {189, "High_Fly_Writes"},
	{190, "Airflow_Temperature_Cel"}, {191, "G-Sense_Error_Rate"},
	{192, "Power-Off_Retract_Count"}, {193, "Load_Cycle_Count"},
	{194, "Temperature_Celsius"}, {195, "Hardware_ECC_Recovered"},
	{196, "Reallocated_Event_Count"}, {197, "Current_Pending_Sector"},
	{198, "Offline_Uncorrectable"}, {199, "UDMA_CRC_Error_Count"},
	{200, "Multi_Zone_Error_Rate"}, {240, "Head_Flying_Hours"},
	{241, "Total_LBAs_Written"}, {242, "Total_LBAs_Read"},
};

static const char *attr_name(u8 id)
{
	for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++)
		if (names[i].id == id)
			return names[i].name;
	return "Unknown_Attribute";
}

/* ATA string (IDENTIFY words, bytes swapped) without trailing spaces */
static void ata_string(const u8 *id, int word, int nwords, char *out)
{
	int n = 0;
	for (int i = 0; i < nwords * 2; i++)
		out[n++] = id[word * 2 + (i ^ 1)];
	while (n > 0 && (out[n - 1] == ' ' || out[n - 1] == 0))
		n--;
	out[n] = 0;
	for (char *p = out; *p == ' '; ) memmove(p, p + 1, strlen(p));
}

static int checksum_ok(const u8 *s)
{
	u8 sum = 0;
	for (int i = 0; i < 512; i++)
		sum += s[i];
	return sum == 0;
}

/* ATA PASS-THROUGH (16), CK_COND set: the result registers come back in the
 * sense data. data = NULL: non-data command; otherwise one 512-byte sector
 * read (PIO data-in). Returns 0 and fills r[] = {error, count, lba low, mid,
 * high, status}, 1 if the command succeeded without returning registers,
 * -1 on failure. */
static int ata_cmd(int fd, u8 cmd, u8 feature, u8 lbal, u8 *data, u8 r[6])
{
	u8 cdb[16] = {0}, sb[32] = {0};
	sg_io_hdr_t io;

	cdb[0] = 0x85;
	cdb[1] = (data ? 4 : 3) << 1;           /* PIO data-in : non-data */
	cdb[2] = 0x20 | (data ? 0x0e : 0);      /* CK_COND, T_DIR in, BYT_BLOK, T_LENGTH=count */
	cdb[4] = feature;
	cdb[6] = data ? 1 : 0;
	cdb[8] = lbal;
	if (cmd == 0xb0) {                      /* SMART signature */
		cdb[10] = 0x4f;
		cdb[12] = 0xc2;
	}
	cdb[14] = cmd;

	memset(&io, 0, sizeof(io));
	io.interface_id = 'S';
	io.cmdp = cdb;
	io.cmd_len = sizeof(cdb);
	io.sbp = sb;
	io.mx_sb_len = sizeof(sb);
	io.dxfer_direction = data ? SG_DXFER_FROM_DEV : SG_DXFER_NONE;
	io.dxferp = data;
	io.dxfer_len = data ? 512 : 0;
	io.timeout = 15000;
	if (ioctl(fd, SG_IO, &io) < 0)
		return -1;
	if (io.host_status || (io.driver_status & ~0x08))   /* 0x08: DRIVER_SENSE */
		return -1;
	if (!sb[0])
		return io.status ? -1 : 1;
	if ((sb[0] & 0x7f) == 0x72) {           /* descriptor format: find descriptor 9 */
		for (int i = 8; i + 14 <= 8 + sb[7] && i + 14 <= (int)sizeof(sb); i += 2 + sb[i + 1])
			if (sb[i] == 9) {
				const u8 *d = sb + i;
				r[0] = d[3]; r[1] = d[5]; r[2] = d[7];
				r[3] = d[9]; r[4] = d[11]; r[5] = d[13];
				goto got;
			}
		return -1;
	} else if ((sb[0] & 0x7f) == 0x70) {    /* fixed format */
		r[0] = sb[3]; r[1] = sb[6]; r[2] = sb[9];
		r[3] = sb[10]; r[4] = sb[11]; r[5] = sb[4];
	} else
		return -1;
got:
	return (r[5] & 0x21) ? -1 : 0;           /* ERR or DF */
}

static unsigned long long raw48(const u8 *a)
{
	unsigned long long v = 0;
	for (int i = 10; i >= 5; i--)
		v = v << 8 | a[i];
	return v;
}

static const char *selftest_name(int st)
{
	static const char *n[16] = {
		"completed without error (or never run)", "aborted by the host",
		"interrupted by a reset", "fatal error", "failed (unknown element)",
		"failed (electrical element)", "failed (servo/seek element)",
		"failed (read element)", "failed (handling damage)",
		0, 0, 0, 0, 0, 0, "in progress"};
	return n[st] ? n[st] : "reserved status";
}

/* SMART READ DATA: self-test execution status (byte 363), polling times in
 * minutes (372 short, 373 extended, 0xff there: word 375) */
static void selftest(const u8 *smart, int *st, int *left, int *smin, int *lmin)
{
	*st = smart[363] >> 4;
	*left = *st == 15 ? (smart[363] & 0x0f) * 10 : 0;
	*smin = smart[372];
	*lmin = smart[373] == 0xff ? smart[375] | smart[376] << 8 : smart[373];
}

static void report(const char *dev, const u8 *id, const u8 *smart,
		   const u8 *thr, const char *health, int shell)
{
	long long realloc = 0, pending = 0, uncorr = 0, hours = 0, cycles = 0;
	int temp = -1, failing = 0;

	/* attributes: 30 entries of 12 bytes from offset 2 */
	for (int i = 0; i < 30; i++) {
		const u8 *a = smart + 2 + i * 12;
		unsigned long long raw = raw48(a);
		if (!a[0])
			continue;
		switch (a[0]) {
		case 5: realloc = raw & 0xffffffff; break;
		case 9: hours = raw & 0xffffffff; break;  /* some drives keep minutes above */
		case 12: cycles = raw & 0xffffffff; break;
		case 197: pending = raw & 0xffffffff; break;
		case 198: uncorr = raw & 0xffffffff; break;
		case 194: temp = a[5]; break;
		case 190: if (temp < 0) temp = a[5]; break;
		}
	}
	for (int i = 0; thr && i < 30; i++) {
		const u8 *a = smart + 2 + i * 12, *t = thr + 2 + i * 12;
		if (a[0] && t[0] == a[0] && t[1] && a[3] <= t[1] && (a[1] & 1))
			failing = 1;    /* pre-fail attribute at or under its threshold */
	}
	if (!health)
		health = failing ? "FAILED" : "PASSED";

	int st, left, smin, lmin;
	selftest(smart, &st, &left, &smin, &lmin);

	if (shell) {
		printf("health=%s realloc=%lld pending=%lld uncorr=%lld hours=%lld cycles=%lld",
		       health, realloc, pending, uncorr, hours, cycles);
		if (temp >= 0)
			printf(" celsius=%d", temp);
		printf(" selftest=%d left=%d short_min=%d long_min=%d\n", st, left, smin, lmin);
		return;
	}

	if (id) {
		char model[41], serial[21], fw[9];
		unsigned long long sectors;
		ata_string(id, 27, 20, model);
		ata_string(id, 10, 10, serial);
		ata_string(id, 23, 4, fw);
		if (id[167] & 0x04)     /* word 83 bit 10: LBA48 */
			sectors = (unsigned long long)id[207] << 56 | (unsigned long long)id[206] << 48 |
				  (unsigned long long)id[205] << 40 | (unsigned long long)id[204] << 32 |
				  (unsigned long long)id[203] << 24 | id[202] << 16 | id[201] << 8 | id[200];
		else
			sectors = (unsigned long long)id[123] << 24 | id[122] << 16 | id[121] << 8 | id[120];
		printf("Device:   %s\nModel:    %s\nSerial:   %s\nFirmware: %s\nCapacity: %llu GB\n",
		       dev, model, serial, fw, sectors * 512 / 1000000000);
	}
	printf("SMART overall-health self-assessment test result: %s\n", health);
	if (temp >= 0)
		printf("Temperature: %d C\n", temp);
	printf("Last self-test: %s", selftest_name(st));
	if (st == 15)
		printf(", %d %% left", left);
	printf("\nSelf-test duration: short %d min, extended %d min\n", smin, lmin);
	if (!checksum_ok(smart))
		printf("Warning: SMART data checksum mismatch\n");
	printf("\nID# ATTRIBUTE_NAME          FLAG   VALUE WORST THRESH TYPE     WHEN_FAILED RAW_VALUE\n");
	for (int i = 0; i < 30; i++) {
		const u8 *a = smart + 2 + i * 12;
		int th = -1;
		if (!a[0])
			continue;
		for (int j = 0; thr && j < 30; j++)
			if (thr[2 + j * 12] == a[0])
				th = thr[3 + j * 12];
		const char *when = th > 0 && a[3] <= th ? "FAILING_NOW" : th > 0 && a[4] <= th ? "In_the_past" : "-";
		unsigned long long raw = raw48(a);
		if (a[0] == 194 || a[0] == 190)
			raw = a[5];
		printf("%3d %-23s 0x%02x%02x %5d %5d ", a[0], attr_name(a[0]), a[2], a[1], a[3], a[4]);
		if (th >= 0) printf("  %03d", th); else printf("  ---");
		printf("   %-8s %-11s %llu\n", (a[1] & 1) ? "Pre-fail" : "Old_age", when, raw);
	}
}

static int load(const char *path, u8 *buf)
{
	FILE *f = fopen(path, "rb");
	int n = f ? (int)fread(buf, 1, 512, f) : 0;
	if (f) fclose(f);
	if (n != 512) {
		fprintf(stderr, "smart-lite: %s: need a 512-byte sector\n", path);
		return -1;
	}
	return 0;
}

int main(int argc, char **argv)
{
	int force = 0, shell = 0, files = 0, test = -1, c;
	u8 id[512], smart[512], thr[512], r[6];

	while ((c = getopt(argc, argv, "fsFt:")) != -1)
		switch (c) {
		case 't':       /* SMART EXECUTE OFF-LINE IMMEDIATE subcommand */
			test = !strcmp(optarg, "short") ? 1 : !strcmp(optarg, "long") ? 2 :
			       !strcmp(optarg, "abort") ? 0x7f : -2;
			if (test == -2)
				goto usage;
			break;
		case 'f': force = 1; break;
		case 's': shell = 1; break;
		case 'F': files = 1; break;
		default: goto usage;
		}
	argc -= optind; argv += optind;

	if (files) {
		if (argc < 3 || load(argv[0], id) || load(argv[1], smart) || load(argv[2], thr))
			goto usage;
		report(argv[0], id, smart, thr, argc > 3 ? argv[3] : NULL, shell);
		return 0;
	}
	if (argc != 1)
		goto usage;

	int fd = open(argv[0], O_RDONLY | O_NONBLOCK);
	if (fd < 0) {
		perror(argv[0]);
		return 1;
	}
	if (test >= 0) {        /* wakes the disk if it sleeps: asked for */
		if (ata_cmd(fd, 0xb0, 0xd0, 0, smart, r) < 0) {
			fprintf(stderr, "%s: SMART READ DATA failed (SMART disabled or not an ATA disk)\n", argv[0]);
			return 1;
		}
		if (test != 0x7f && !(smart[367] & 0x10)) {   /* off-line capability bit 4 */
			fprintf(stderr, "%s: this disk has no SMART self-test\n", argv[0]);
			return 1;
		}
		if (test != 0x7f && smart[363] >> 4 == 15) {
			fprintf(stderr, "%s: a self-test is already running\n", argv[0]);
			return 1;
		}
		if (ata_cmd(fd, 0xb0, 0xd4, test, NULL, r) < 0) {
			fprintf(stderr, "%s: SMART EXECUTE OFF-LINE IMMEDIATE failed\n", argv[0]);
			return 1;
		}
		close(fd);
		return 0;
	}
	/* CHECK POWER MODE: count 0x00/0x01 = standby; anything else spins */
	if (!force && ata_cmd(fd, 0xe5, 0, 0, NULL, r) == 0 && r[1] <= 0x01) {
		printf(shell ? "power=standby\n" : "STANDBY: disk asleep, not read (-f to wake it)\n");
		return 2;
	}
	int have_id = ata_cmd(fd, 0xec, 0, 0, id, r) >= 0;
	if (ata_cmd(fd, 0xb0, 0xd0, 0, smart, r) < 0) {
		fprintf(stderr, "%s: SMART READ DATA failed (SMART disabled or not an ATA disk)\n", argv[0]);
		return 1;
	}
	int have_thr = ata_cmd(fd, 0xb0, 0xd1, 1, thr, r) >= 0;
	const char *health = NULL;
	if (ata_cmd(fd, 0xb0, 0xda, 0, NULL, r) == 0) {
		if (r[3] == 0x4f && r[4] == 0xc2) health = "PASSED";
		else if (r[3] == 0xf4 && r[4] == 0x2c) health = "FAILED";
	}
	close(fd);
	report(argv[0], have_id ? id : NULL, smart, have_thr ? thr : NULL, health, shell);
	return 0;
usage:
	fprintf(stderr, "usage: smart-lite [-f] [-s] /dev/sdX\n"
		"       smart-lite -t short|long|abort /dev/sdX\n"
		"       smart-lite -F [-s] identify.bin smart.bin thresh.bin [PASSED|FAILED]\n");
	return 1;
}
