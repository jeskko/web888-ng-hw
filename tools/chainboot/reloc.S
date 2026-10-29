/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Runs from a copy in a page of its own, at its physical address, with
 * the MMU and caches off (soft_restart): copies each page of the list
 * {dst, src}... to its place ({1, next}: the list goes on at next; {0}:
 * its end), then enters the kernel as a boot loader would: r0 = 0,
 * r1 = ~0 (machine: from the DT), r2 = the DTB.
 */
	.text
	.arm
	.align	5
	.globl	cb_reloc_start
	.globl	cb_reloc_end
cb_reloc_start:
	@ First quiet the old kernel's DMA masters: a controller it left
	@ running (the GEM's receive ring, with traffic on the LAN) writes into
	@ the new kernel's memory (seen on the unit: a corrupt squashfs root,
	@ and the GEM never sent). Pulse the SLCR resets of the DMAC, both USB,
	@ GEM and SDIO controllers; the new kernel finds them as after a boot.
	movw	r0, #0x0000
	movt	r0, #0xf800		@ SLCR
	movw	r1, #0xdf0d
	str	r1, [r0, #0x008]	@ SLCR_UNLOCK
	mov	r1, #0x01
	str	r1, [r0, #0x20c]	@ DMAC_RST_CTRL
	mov	r1, #0x03
	str	r1, [r0, #0x210]	@ USB_RST_CTRL (CPU_1x)
	mov	r1, #0xf3
	str	r1, [r0, #0x214]	@ GEM_RST_CTRL (CPU_1x, RX, ref)
	mov	r1, #0x33
	str	r1, [r0, #0x218]	@ SDIO_RST_CTRL (CPU_1x, ref)
	dsb
	mov	r2, #0x10000		@ hold the resets a while
4:	subs	r2, r2, #1
	bne	4b
	mov	r1, #0
	str	r1, [r0, #0x20c]
	str	r1, [r0, #0x210]
	str	r1, [r0, #0x214]
	str	r1, [r0, #0x218]
	dsb
	adr	r12, cb_reloc_data
	ldr	r4, [r12]		@ the list
1:	ldr	r5, [r4], #4		@ dst; 0 ends the list
	cmp	r5, #0
	beq	3f
	ldr	r6, [r4], #4		@ src
	cmp	r5, #1			@ the next list page
	moveq	r4, r6
	beq	1b
	mov	r7, #4096
2:	ldmia	r6!, {r0-r3, r8-r11}
	stmia	r5!, {r0-r3, r8-r11}
	subs	r7, r7, #32
	bne	2b
	b	1b
3:	mov	r0, #0
	mcr	p15, 0, r0, c7, c5, 0	@ invalidate the I-cache
	mcr	p15, 0, r0, c7, c5, 6	@ and the branch predictor
	dsb
	isb
	ldr	r3, [r12, #4]		@ entry
	ldr	r2, [r12, #8]		@ the DTB
	mov	r0, #0
	mvn	r1, #0
	bx	r3
	.align	2
	.globl	cb_reloc_data
cb_reloc_data:
	.word	0, 0, 0			@ list, entry, DTB (physical)
cb_reloc_end:
