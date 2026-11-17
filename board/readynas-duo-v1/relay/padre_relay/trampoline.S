/*
 * trampoline.S - last step of padre_relay: copy the raw 6.18 image over the
 * running 2.6.17 kernel and jump to it, leaving the CPU as iboot leaves it
 * after "go 0x80004000".
 *
 * Copied by relay.c into a page that lies above the copy range, then called
 * there. Position independent (relative branches only), leaf (no save /
 * restore, so no window trap can happen while traps are off).
 *
 *   void relay_tramp(u32 *list, u32 npages, u32 dst, u32 unused, u32 entry)
 *     list[i] = kernel virtual address of the i-th 4 KiB page of the image
 *     entry == 0: test mode, only copy list -> dst with the caches on, return
 *     entry != 0: go mode (below), never returns
 *
 * Go mode, and where each choice comes from:
 *  - PSR: traps off (ET=0), PIL 15, supervisor, CWP kept (we are a leaf).
 *    The 6.18 head (continue_boot) rewrites the whole PSR itself, as the
 *    2.6.17 head (execute_in_high_mem) does: their only need is to run in
 *    supervisor mode, which "go" also gives.
 *  - D-cache written back and invalidated with the probe loop of the GPL
 *    2.6.17 arch/padre/mm/padre_cache.c (__flush_dcache_*: INVCLN | FORCE |
 *    0x80, one load per 16 bytes over the cacheable S3 alias 0x7400_0000..
 *    0x7400_0ff0). Needed because both heads (2.6.17 init_cache, 6.18
 *    gokernel) switch the caches off and clear the tags WITHOUT write-back.
 *  - I-cache and D-cache then off, as the heads do first (ICMU/DCMU CTRL = 0,
 *    dummy read of the S3 SRAM). The copy runs uncached, so nothing of the
 *    new image can be lost or stale when the 6.18 head clears the tags.
 *  - MMU: kept in fixed-map mode (MMU_CONTROL read back, NF cleared, FL |
 *    DE | IE set: TLB flushed, I and D translation on; the other bits, e.g.
 *    0x10000340 read under 2.6.17, are kept as they are). The address "go 0x80004000" jumps to is the
 *    fixed DDR window, and the very first thing both heads do is to write
 *    exactly this value, so this is the state they are designed to run in.
 *    Page table walk switched off (PGT = 0): the 2.6.17 page directory is
 *    about to be overwritten; 6.18 writes PGT itself in srmmu_paging_init().
 *    ASSUMPTION: iboot does not use the table walker either (it has no
 *    page tables; nothing in either head reads PGT).
 *  - WIM = 0 (no invalid window: no overflow trap before the 6.18 head
 *    sets WIM), TBR = entry (the 6.18 trap table; unused while ET=0).
 *  - Markers on the serial console (UART0 0x6000_0060, ttyS1 9600 baud):
 *    'R' traps off, 'C' caches off, 'J' copy done, jumping. The 6.18 head
 *    then prints 'L' (LP firmware loaded) or 'l', 'P', 'K'.
 */

#define UART0	0x60000060

/* poll "transmitter empty" (bit 2 of the status register, +4), bounded */
#define PUTC(c)				\
	set	UART0, %g2;		\
	set	100000, %g3;		\
8:	ld	[%g2 + 4], %g4;		\
	andcc	%g4, 4, %g0;		\
	bne	9f;			\
	 subcc	%g3, 1, %g3;		\
	bne	8b;			\
	 nop;				\
9:	mov	c, %g4;			\
	st	%g4, [%g2]

	.text
	.align	8
	.globl	relay_tramp_start
	.globl	relay_tramp_end
relay_tramp_start:
	cmp	%o4, 0
	be	2f			! test mode: copy only
	 nop

	/* traps off, PIL 15 */
	rd	%psr, %g1
	or	%g1, 0xf00, %g1
	andn	%g1, 0x20, %g1
	wr	%g1, 0, %psr
	nop; nop; nop
	PUTC('R')

	/* D-cache: write back and invalidate everything (2.6.17 padre_cache.c) */
	set	0x30000, %g1		! DCMU_CTRL (ASI 0x15), ICMU_CTRL (ASI 0x14)
	lda	[%g1] 0x15, %g5
	or	%g5, 0xf0, %g3		! (PROBE_INVCLN << 4) | FORCE | 0x80
	sta	%g3, [%g1] 0x15
	set	0x74000000, %g2		! PADRE_S3_RAMTOP_CACHEABLE
	set	0x74000ff0, %g3
1:	ld	[%g2], %g0
	cmp	%g2, %g3
	bleu	1b
	 add	%g2, 16, %g2
	sta	%g5, [%g1] 0x15
	nop; nop; nop

	/* caches off (2.6.17 head.S init_cache, 6.18 head_32.S gokernel) */
	sta	%g0, [%g1] 0x14
	nop; nop; nop
	sta	%g0, [%g1] 0x15
	nop; nop; nop
	set	0x70000000, %g2		! PADRE_S3_RAMTOP: dummy read
	ld	[%g2], %g0
	PUTC('C')

	/* copy npages pages from list[] to dst (uses %o0-%o3, %o5, %g1 only:
	 * in test mode %g2-%g7 belong to the running kernel) */
2:	cmp	%o1, 0
	be	6f
	 nop
	ld	[%o0], %o3
	add	%o0, 4, %o0
	set	4092, %o5
5:	ld	[%o3 + %o5], %g1
	st	%g1, [%o2 + %o5]
	subcc	%o5, 4, %o5
	bge	5b
	 nop
	sethi	%hi(0x1000), %g1
	add	%o2, %g1, %o2
	b	2b
	 sub	%o1, 1, %o1

6:	cmp	%o4, 0
	bne	7f
	 nop
	retl				! test mode ends here
	 nop

	/* MMU: table walk off, TLB flushed, fixed map (I and D) kept */
7:	set	0x24, %g1		! PADRE_MMU_PGT (ASI 0x10)
	sta	%g0, [%g1] 0x10
	set	0x04, %g1		! PADRE_MMU_CONTROL: read 0x10000343 under
	lda	[%g1] 0x10, %g2		! 2.6.17; keep the bits we do not know,
	andn	%g2, 0x04, %g2		! clear NF, set FL; DE|IE (0x3) stay set
	or	%g2, 0x23, %g2
	sta	%g2, [%g1] 0x10
	nop; nop; nop
	wr	%g0, 0, %wim
	wr	%o4, 0, %tbr
	nop; nop; nop
	PUTC('J')
	jmp	%o4
	 nop
relay_tramp_end:

/*
 * void relay_sync_caches(void) - module text, NOT copied: makes the
 * trampoline page (written through the D-cache) safe to execute.
 * The 2.6.17 cache functions cannot be used: flush_icache_range() and its
 * _workaround/_cachefix variants (chosen by padre_cachefix, from
 * product_features) are __ic3call code, absent from kallsyms.
 * Call with interrupts off. Only %o0-%o3 used (leaf).
 *  1. D-cache: write back + invalidate all, same probe loop as above.
 *  2. I-cache: invalidate all tags in test mode, as 2.6.17 head.S
 *     init_icache and __clean_icache_range_workaround do, then restore the
 *     control register (IC3 locked area: its contents are not in the tags).
 */
	.globl	relay_sync_caches
relay_sync_caches:
	set	0x30000, %o0
	lda	[%o0] 0x15, %o1
	or	%o1, 0xf0, %o2
	sta	%o2, [%o0] 0x15
	set	0x74000000, %o2
	set	0x74000ff0, %o3
1:	ld	[%o2], %g0
	cmp	%o2, %o3
	bleu	1b
	 add	%o2, 16, %o2
	sta	%o1, [%o0] 0x15
	nop; nop; nop

	lda	[%o0] 0x14, %o1		! ICMU_CTRL to restore
	sta	%g0, [%o0] 0x14
	nop; nop; nop
	set	2, %o2			! PADRE_ICMU_CTRL_TM
	sta	%o2, [%o0] 0x14
	set	0x10000, %o2		! PADRE_ICMU_ITAG
	set	0x13ffc, %o3
2:	sta	%g0, [%o2] 0x14
	cmp	%o2, %o3
	blu	2b
	 add	%o2, 4, %o2
	sta	%g0, [%o0] 0x14
	nop; nop; nop
	sta	%o1, [%o0] 0x14
	nop; nop; nop
	retl
	 nop
