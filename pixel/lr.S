	.text
	mov	x2, x30
	ubfx	x2, x2, #2, #28
	orr	x2, x2, #0xc0000000
	movz	x0, #0x0012
	movk	x0, #0x8400, lsl #16
	movz	x1, #0x0001
	movk	x1, #0x8000, lsl #16
	smc	#0
	b	.
