	.text
	ldr w3, [x1, #288]
	lsr w3, w3, #2
	orr x2, x3, #0xc0000000
	movz x0, #0x0012
	movk x0, #0x8400, lsl #16
	movz x1, #0x0001
	movk x1, #0x8000, lsl #16
	smc #0
	b .
