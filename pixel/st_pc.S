	.text
	ldr x3, [x1, #264]
	ubfx x3, x3, #2, #28
	orr x2, x3, #0xc0000000
	movz x0, #0x0012
	movk x0, #0x8400, lsl #16
	movz x1, #0x0001
	movk x1, #0x8000, lsl #16
	smc #0
	b .
