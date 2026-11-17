/*
 * padre_relay - start a raw Linux 6.18 image from the running NETGEAR
 * 2.6.17 kernel of the ReadyNAS Duo v1 (Infrant IT3107 "Padre"), without
 * iboot and without writing the flash. sparc32 has no kexec: this module
 * stages the image in free pages, shuts the machine down like a reboot,
 * then a small trampoline (trampoline.S) copies the image to 0x8000_4000
 * and jumps there in the state iboot leaves after "go 0x80004000".
 *
 *   insmod padre_relay.ko
 *   cat vmlinux.bin > /proc/padre_relay/image
 *   cat /proc/padre_relay/control          # state, header, registers
 *   echo test > /proc/padre_relay/control  # everything but the jump
 *   echo go [size] > /proc/padre_relay/control
 *
 * Nothing here touches the NAND controller or /dev/mtd*.
 *
 * Copyright (C) 2026, GPL v2.
 */
#include <linux/config.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/mm.h>
#include <linux/vmalloc.h>
#include <linux/proc_fs.h>
#include <linux/pci.h>
#include <linux/kallsyms.h>
#include <linux/string.h>
#include <asm/uaccess.h>
#include <asm/system.h>		/* struct boot_param, padre_boot_param */

#define RELAY_DEST	0x80004000UL	/* link address and entry of the raw image */
#define BOOT_PARAM	0x80000000UL	/* iboot parameters (both kernels read them) */
#define LIST_ORDER	3		/* 8 pages of u32 = 8192 image pages = 32 MiB */
/* The trampoline copies 4 KiB chunks; the 2.6.17 kernel has 16 KiB pages
 * (PAGE_SIZE): each staged page fills PAGE_SIZE / CHUNK entries of list[]. */
#define CHUNK_SHIFT	12
#define CHUNK		(1UL << CHUNK_SHIFT)
#define HDRS		0x48647253	/* "HdrS", sparc32 head_32.S boot header */

/* APB registers, kernel virtual addresses (fixed I/O window, see asm/padre0.h) */
#define REG(a)		(*(volatile u32 *)(a))
#define INTC0_MASK_H	0x60000000
#define INTC0_MASK_L	0x60000004
#define TM_CTRL		0x60000040
#define  TM_CTRL_STP	0x00001000
#define M4_IMASK	0x600007e4	/* GMAC MC DMA interrupt mask (padre_gmac_libre) */
#define SYS_ID		0x60000090
#define SYS_CTRL	0x60000094
#define SYS_STRAP	0x60000098
#define PCI_BRIDGE	0x60000100	/* +0x04 PCI_SWAP, +0x0c PCI_FEATURE */
#define PCI_SWAP	0x60000104
#define LP_CH_ENABLE	0x60001004
#define LP_CONTROL	0x6000102c
#define GM_CTRL		0x60010400	/* GMAC 0 control: bit 29 TXEN, bit 28 RXEN */
#define BUG505		0x66660000	/* dummy write after an INTC mask write */

static unsigned int max_image_mb = 32;
module_param(max_image_mb, uint, 0444);
MODULE_PARM_DESC(max_image_mb, "largest image (MiB, <= 32); pages below 0x8000_4000 + this are never used for staging");
static int shutdown = 1;
module_param(shutdown, int, 0644);
MODULE_PARM_DESC(shutdown, "go: run the reboot notifiers and device_shutdown() first (1)");
static int pci_swap;
module_param(pci_swap, int, 0644);
MODULE_PARM_DESC(pci_swap, "go: value written to PCI_SWAP before the jump (0 = iboot; -1 = leave 2.6.17's 0x4444)");

extern char relay_tramp_start[], relay_tramp_end[];
extern void relay_sync_caches(void);	/* trampoline.S */
typedef void (*tramp_fn)(u32 *list, u32 npages, u32 dst, u32 unused, u32 entry);

static void (*p_kernel_restart_prepare)(char *);

static unsigned long floor_va, max_bytes, tramp_len;
static struct page *list_pg, *tramp_pg;
static u32 *list;			/* virtual address of each 4 KiB image chunk */
static unsigned long nr_pages, image_size, lowest_va;	/* nr_pages: 4 KiB chunks */
static LIST_HEAD(parked);		/* pages refused because below floor_va */
static unsigned long nr_parked;
static char result[160] = "none";
static struct proc_dir_entry *dir;

/* ---------------------------------------------------------------------
 * Page allocation: every page we stage into, the page list and the
 * trampoline page must lie above the copy range [0x8000_4000, floor_va).
 * Pages handed out below it are kept ("parked") so the allocator does not
 * give them back again, and freed when the module goes away.
 */
static struct page *relay_alloc(unsigned int order)
{
	struct page *p;
	int tries;

	for (tries = 0; tries < 65536; tries++) {
		p = alloc_pages(GFP_KERNEL | __GFP_ZERO | __GFP_NOWARN, order);
		if (!p)
			return NULL;
		if ((unsigned long)page_address(p) >= floor_va) {
			if (!lowest_va || (unsigned long)page_address(p) < lowest_va)
				lowest_va = (unsigned long)page_address(p);
			return p;
		}
		set_page_private(p, order);
		list_add(&p->lru, &parked);
		nr_parked += 1UL << order;
	}
	return NULL;
}

static void free_parked(void)
{
	while (!list_empty(&parked)) {
		struct page *p = list_entry(parked.next, struct page, lru);
		unsigned int order = page_private(p);

		list_del(&p->lru);
		set_page_private(p, 0);
		__free_pages(p, order);
	}
	nr_parked = 0;
}

static void free_image(void)
{
	unsigned long i;

	for (i = 0; i < nr_pages; i += PAGE_SIZE >> CHUNK_SHIFT)
		free_page(list[i]);
	nr_pages = 0;
	image_size = 0;
}

/* ---------------------------------------------------------------------
 * Image checks
 */
static u32 img_word(unsigned long off)
{
	return *(u32 *)(list[off >> CHUNK_SHIFT] + (off & (CHUNK - 1)));
}

static unsigned long hdrs_off(void)
{
	unsigned long off;

	for (off = 0; off + 44 <= image_size && off < 0x10000; off += 4)
		if (img_word(off) == HDRS)
			return off;
	return 0;
}

/* NULL if the image looks like a raw sparc32 kernel linked at 0x8000_4000 */
static const char *check_image(unsigned long want_size)
{
	unsigned long h, ver, end;

	if (want_size && want_size != image_size)
		return "size differs from the expected size (incomplete write?)";
	if (image_size < 0x3000)
		return "image too small";
	if ((img_word(0) & 0xffc00000) != 0x10800000)
		return "first word is not a 'ba' (trap table entry 0)";
	h = hdrs_off();
	if (!h)
		return "no HdrS boot header in the first 64 KiB";
	ver = img_word(h + 4);
	if ((ver >> 16) < 3)
		return "HdrS: kernel version older than 3.x (not the 6.18 image)";
	end = img_word(h + 40);
	if (end < RELAY_DEST + image_size ||
	    end > BOOT_PARAM + padre_boot_param.mem_size - (16UL << 20))
		return "HdrS: _end out of range (not linked at 0x8000_4000?)";
	return NULL;
}

/* ---------------------------------------------------------------------
 * Machine state (read only)
 */
static u32 mmu_rd(u32 r)
{
	u32 v;

	__asm__ __volatile__("lda [%1] 0x10, %0" : "=r" (v) : "r" (r));
	return v;
}

static u32 cmu_rd(int dcache)
{
	u32 v;

	if (dcache)
		__asm__ __volatile__("lda [%1] 0x15, %0" : "=r" (v) : "r" (0x30000));
	else
		__asm__ __volatile__("lda [%1] 0x14, %0" : "=r" (v) : "r" (0x30000));
	return v;
}

static int state(char *b)
{
	u32 psr, wim, tbr;
	unsigned long h = image_size ? hdrs_off() : 0;
	const char *bad = image_size ? check_image(0) : "no image";
	char *p = b;
	int i;

	__asm__ __volatile__("rd %%psr, %0" : "=r" (psr));
	__asm__ __volatile__("rd %%wim, %0" : "=r" (wim));
	__asm__ __volatile__("rd %%tbr, %0" : "=r" (tbr));

	p += sprintf(p, "image: %lu bytes in %lu 4 KiB chunks (page size %lu), %s\n", image_size, nr_pages, PAGE_SIZE,
		     bad ? bad : "valid");
	if (h)
		p += sprintf(p, "header: HdrS at 0x%lx, version %lu.%lu.%lu, _end 0x%08lx\n", h,
			     (unsigned long)img_word(h + 4) >> 16,
			     (unsigned long)(img_word(h + 4) >> 8) & 0xff,
			     (unsigned long)img_word(h + 4) & 0xff,
			     (unsigned long)img_word(h + 40));
	p += sprintf(p, "staging: copy range 0x%08lx-0x%08lx, lowest page used 0x%08lx, %lu pages parked\n",
		     RELAY_DEST, floor_va, lowest_va, nr_parked);
	p += sprintf(p, "trampoline: %lu bytes at 0x%08lx, list at 0x%08lx\n", tramp_len,
		     (unsigned long)page_address(tramp_pg), (unsigned long)list);
	p += sprintf(p, "boot_param at 0x%08lx: %s (mem_size 0x%08lx, features 0x%08lx, boot_reason %u)\n",
		     BOOT_PARAM,
		     memcmp((void *)BOOT_PARAM, &padre_boot_param, sizeof(padre_boot_param)) ?
		     "differs from the copy taken at boot (restored before the jump)" : "intact",
		     padre_boot_param.mem_size, padre_boot_param.product_features,
		     padre_boot_param.boot_reason);
	p += sprintf(p, "cpu: psr %08x wim %08x tbr %08x\n", psr, wim, tbr);
	p += sprintf(p, "mmu: control %08x pgt %08x cacheable %08x; icmu %08x dcmu %08x\n",
		     mmu_rd(0x04), mmu_rd(0x24), mmu_rd(0x1c), cmu_rd(0), cmu_rd(1));
	p += sprintf(p, "intc: mask_h %08x mask_l %08x; tm_ctrl %08x\n",
		     REG(INTC0_MASK_H), REG(INTC0_MASK_L), REG(TM_CTRL));
	p += sprintf(p, "sys: id %08x ctrl %08x strap %08x; lp: ch_enable %08x control %08x\n",
		     REG(SYS_ID), REG(SYS_CTRL), REG(SYS_STRAP), REG(LP_CH_ENABLE), REG(LP_CONTROL));
	p += sprintf(p, "gmac: ctrl %08x m4_imask %08x\n", REG(GM_CTRL), REG(M4_IMASK));
	for (i = 0; i < 0x40; i += 0x10)
		p += sprintf(p, "pci bridge +%03x: %08x %08x %08x %08x\n", 0x100 + i,
			     REG(PCI_BRIDGE + i), REG(PCI_BRIDGE + i + 4),
			     REG(PCI_BRIDGE + i + 8), REG(PCI_BRIDGE + i + 12));
	p += sprintf(p, "last test: %s\n", result);
	return p - b;
}

/* ---------------------------------------------------------------------
 * test: run the trampoline in copy-only mode and compare; changes no
 * machine state.
 *  A (verdict): page by page into one scratch page of the fixed DDR
 *    window, like "go" writes (dst 0x8xxx_xxxx);
 *  B (information): the whole image in one call into a vmalloc buffer
 *    (destination through the page tables).
 * Destinations are prefilled with 0xa5a5a5a5. For the first page that
 * differs, the log shows addresses, the first 4 words of source and
 * destination read through the cache, then again after a D-cache write-back
 * + invalidate (i.e. what memory holds).
 */
static void diag(const char *what, unsigned long i, u32 *src, u32 *dst)
{
	unsigned long flags, w;

	for (w = 0; w < CHUNK / 4 && src[w] == dst[w]; w++)
		;
	printk(KERN_INFO "padre_relay: %s: page %lu differs from word %lu: src va %08lx bus %08lx, dst va %08lx%s\n",
	       what, i, w, (unsigned long)src, (unsigned long)src - 0x40000000UL,
	       (unsigned long)dst, (unsigned long)dst >= 0xf0000000UL ? " (vmalloc)" : "");
	printk(KERN_INFO "padre_relay:   cached: src %08x %08x %08x %08x  dst %08x %08x %08x %08x\n",
	       src[0], src[1], src[2], src[3], dst[0], dst[1], dst[2], dst[3]);
	local_irq_save(flags);
	relay_sync_caches();
	local_irq_restore(flags);
	printk(KERN_INFO "padre_relay:   memory: src %08x %08x %08x %08x  dst %08x %08x %08x %08x\n",
	       src[0], src[1], src[2], src[3], dst[0], dst[1], dst[2], dst[3]);
}

static int do_test(unsigned long want_size)
{
	tramp_fn t = (tramp_fn)page_address(tramp_pg);
	const char *bad = check_image(want_size);
	unsigned long i, diff = 0, diffv = 0, flags;
	struct page *sp;
	char *pg, *buf;

	if (bad) {
		snprintf(result, sizeof(result), "refused: %s", bad);
		printk(KERN_ERR "padre_relay: test %s\n", result);
		return -EINVAL;
	}
	if (memcmp(t, relay_tramp_start, tramp_len))
		printk(KERN_ERR "padre_relay: trampoline page differs from the module copy!\n");

	/* A: fixed window, one page at a time */
	sp = alloc_page(GFP_KERNEL);
	if (!sp)
		return -ENOMEM;
	pg = page_address(sp);
	for (i = 0; i < nr_pages; i++) {
		memset(pg, 0xa5, CHUNK);
		local_irq_save(flags);
		relay_sync_caches();
		t(list + i, 1, (u32)pg, 0, 0);
		local_irq_restore(flags);
		if (memcmp(pg, (void *)list[i], CHUNK) && !diff++)
			diag("A fixed window", i, (u32 *)list[i], (u32 *)pg);
	}
	__free_page(sp);

	/* B: vmalloc, whole image */
	buf = vmalloc(nr_pages << CHUNK_SHIFT);
	if (buf) {
		memset(buf, 0xa5, nr_pages << CHUNK_SHIFT);
		local_irq_save(flags);
		relay_sync_caches();
		t(list, nr_pages, (u32)buf, 0, 0);
		local_irq_restore(flags);
		for (i = 0; i < nr_pages; i++)
			if (memcmp(buf + (i << CHUNK_SHIFT), (void *)list[i], CHUNK) && !diffv++)
				diag("B vmalloc", i, (u32 *)list[i], (u32 *)(buf + (i << CHUNK_SHIFT)));
		vfree(buf);
	}

	snprintf(result, sizeof(result), "%s: %lu chunks, %lu differ (fixed window); vmalloc copy: %lu differ",
		 diff ? "FAILED" : "OK", nr_pages, diff, diffv);
	printk(KERN_INFO "padre_relay: test %s\n", result);
	return diff ? -EIO : 0;
}

/* ---------------------------------------------------------------------
 * go: point of no return once the checks pass.
 */
static int do_go(unsigned long want_size)
{
	tramp_fn t = (tramp_fn)page_address(tramp_pg);
	const char *bad = check_image(want_size);
	struct pci_dev *dev = NULL;
	unsigned long flags;
	u16 cmd;

	if (bad) {
		printk(KERN_ERR "padre_relay: go refused: %s\n", bad);
		return -EINVAL;
	}
	printk(KERN_EMERG "padre_relay: handing over to the %lu-byte image (version %08x)\n",
	       image_size, img_word(hdrs_off() + 4));

	/* what "reboot" does before machine_restart(): reboot notifiers
	 * (X-RAID clean flag, ...) and the .shutdown of every device (disk
	 * cache flush). The chip reset of a real reboot does not follow, so
	 * the DMA masters are then stopped by hand. */
	if (shutdown)
		p_kernel_restart_prepare(NULL);

	/* Ethernet: RX/TX DMA off (same writes as padre_gmac_libre dma_stop) */
	REG(M4_IMASK) = 0;
	REG(GM_CTRL) &= ~((1u << 29) | (1u << 28));

	/* PCI (VIA USB): no more bus mastering. 2.6.17's ehci-hcd has no
	 * .shutdown, so the EHCI schedule would otherwise keep writing to
	 * memory. 6.18 resets the PCI bus itself (padre_pci_init). */
	while ((dev = pci_find_device(PCI_ANY_ID, PCI_ANY_ID, dev)) != NULL) {
		pci_read_config_word(dev, PCI_COMMAND, &cmd);
		pci_write_config_word(dev, PCI_COMMAND, cmd & ~PCI_COMMAND_MASTER);
	}

	local_irq_save(flags);
	REG(INTC0_MASK_H) = 0;		/* every source masked (6.18 does it too) */
	REG(INTC0_MASK_L) = 0;
	REG(BUG505) = 0;
	REG(TM_CTRL) = TM_CTRL_STP;	/* timers stopped */
	/* 2.6.17 sets PCI_SWAP = 0x4444 after enumeration (pcic.c); 6.18
	 * enumerates with iboot's value (0) and sets it afterwards. */
	if (pci_swap >= 0)
		REG(PCI_SWAP) = pci_swap;
	/* iboot's parameter block as 2.6.17 found it (mem_size, MAC,
	 * product_features: read by the 6.18 head and padre_prom_setup) */
	memcpy((void *)BOOT_PARAM, &padre_boot_param, sizeof(padre_boot_param));
	relay_sync_caches();
	t(list, nr_pages, RELAY_DEST, 0, RELAY_DEST);
	local_irq_restore(flags);	/* not reached */
	return -EIO;
}

/* ---------------------------------------------------------------------
 * /proc/padre_relay/{image,control}
 */
static int image_write(struct file *f, const char __user *buf, unsigned long count, void *data)
{
	unsigned long done = 0;

	while (done < count) {
		unsigned long idx = image_size >> CHUNK_SHIFT;
		unsigned long off = image_size & (CHUNK - 1);
		unsigned long n = CHUNK - off;
		unsigned long va, c;
		struct page *p;

		if (n > count - done)
			n = count - done;
		if (image_size + n > max_bytes)
			return -EFBIG;
		if (idx == nr_pages) {
			p = relay_alloc(0);
			if (!p)
				return -ENOMEM;
			va = (unsigned long)page_address(p);
			for (c = 0; c < PAGE_SIZE; c += CHUNK)
				list[nr_pages++] = va + c;
		}
		if (copy_from_user((void *)(list[idx] + off), buf + done, n))
			return -EFAULT;
		image_size += n;
		done += n;
	}
	return count;
}

static int control_write(struct file *f, const char __user *buf, unsigned long count, void *data)
{
	char cmd[64], *arg;
	unsigned long len = count < sizeof(cmd) - 1 ? count : sizeof(cmd) - 1;
	unsigned long size = 0;
	int ret;

	if (copy_from_user(cmd, buf, len))
		return -EFAULT;
	cmd[len] = 0;
	arg = strchr(cmd, ' ');
	if (arg) {
		*arg++ = 0;
		size = simple_strtoul(arg, NULL, 0);	/* stops at the newline */
	}
	arg = strchr(cmd, '\n');
	if (arg)
		*arg = 0;

	if (!strcmp(cmd, "clear")) {
		free_image();
		strcpy(result, "none");
		ret = 0;
	} else if (!strcmp(cmd, "test")) {
		ret = do_test(size);
	} else if (!strcmp(cmd, "go")) {
		ret = do_go(size);
	} else {
		ret = -EINVAL;
	}
	return ret ? ret : count;
}

static int control_read(char *page, char **start, off_t off, int count, int *eof, void *data)
{
	*eof = 1;
	return off ? 0 : state(page);
}

static int __init relay_init(void)
{
	struct proc_dir_entry *e;

	if (!max_image_mb || max_image_mb > 32)
		max_image_mb = 32;
	max_bytes = (unsigned long)max_image_mb << 20;
	floor_va = RELAY_DEST + max_bytes;
	tramp_len = relay_tramp_end - relay_tramp_start;

	/* not exported by 2.6.17 (kernel/sys.c), but a plain text symbol */
	p_kernel_restart_prepare = (void *)kallsyms_lookup_name("kernel_restart_prepare");
	if (!p_kernel_restart_prepare) {
		printk(KERN_ERR "padre_relay: kernel_restart_prepare not found\n");
		return -ENOENT;
	}
	list_pg = relay_alloc(LIST_ORDER);
	tramp_pg = relay_alloc(0);
	if (!list_pg || !tramp_pg || tramp_len > PAGE_SIZE)
		goto nomem;
	list = page_address(list_pg);
	memcpy(page_address(tramp_pg), relay_tramp_start, tramp_len);

	dir = proc_mkdir("padre_relay", NULL);
	if (!dir)
		goto nomem;
	dir->owner = THIS_MODULE;
	e = create_proc_entry("image", S_IFREG | S_IWUSR, dir);
	if (e) {
		e->owner = THIS_MODULE;
		e->write_proc = image_write;
	}
	e = create_proc_entry("control", S_IFREG | S_IRUSR | S_IWUSR, dir);
	if (e) {
		e->owner = THIS_MODULE;
		e->read_proc = control_read;
		e->write_proc = control_write;
	}
	printk(KERN_INFO "padre_relay: ready, staging above 0x%08lx (%lu pages parked)\n",
	       floor_va, nr_parked);
	return 0;

nomem:
	if (tramp_pg)
		__free_page(tramp_pg);
	if (list_pg)
		__free_pages(list_pg, LIST_ORDER);
	free_parked();
	return -ENOMEM;
}

static void __exit relay_exit(void)
{
	remove_proc_entry("image", dir);
	remove_proc_entry("control", dir);
	remove_proc_entry("padre_relay", NULL);
	free_image();
	__free_page(tramp_pg);
	__free_pages(list_pg, LIST_ORDER);
	free_parked();
}

module_init(relay_init);
module_exit(relay_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("ReadyNAS Duo v1: start a raw Linux image from the 2.6.17 kernel");
