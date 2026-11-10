	.text
	sub	sp, sp, #48
	stp	x29, x30, [sp, #16]
	add	x0, sp, #32
	mov	w1, #16
	bl	.
	ldr	w3, [sp, #32]
	ubfx	w4, w3, #0, #7
	lsl	w4, w4, #21
	ubfx	w5, w3, #8, #7
	orr	w4, w4, w5, lsl #14
	ubfx	w5, w3, #16, #7
	orr	w4, w4, w5, lsl #7
	ubfx	w5, w3, #24, #7
	orr	w4, w4, w5
	orr	x2, x4, #0xc0000000
	movz	x0, #0x0012
	movk	x0, #0x8400, lsl #16
	movz	x1, #0x0001
	movk	x1, #0x8000, lsl #16
	smc	#0
	b	.
