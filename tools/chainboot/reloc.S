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
