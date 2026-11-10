/*
 * usbmuxdev: the DEVICE side of Apple's usbmux, on Android's USB gadget (FunctionFS), so that a Mac's usbmuxd (Finder, Xcode, libimobiledevice)
 * sees the phone as an iPhone and can reach services of the iOS running beside Android (lockdownd on 62078 first of all) through TCP connections
 * that are forwarded to 10.77.0.2 (iOS's address on the ring network, see netsrv.sh).
 *
 * The wire protocol is what the host side (libimobiledevice's usbmuxd, src/device.c) speaks:
 *   - a bulk IN and a bulk OUT endpoint on an interface of class 0xff, subclass 0xfe, protocol 2
 *   - packets of "mux header + payload": the header is 8 bytes (protocol, length) until the SETUP packet, 16 bytes (protocol, length, magic
 *     0xfeedface, tx_seq, rx_seq) after it; all fields big endian. Protocols: 0 version, 1 control, 2 setup, 6 TCP.
 *   - the host starts with a VERSION packet (major 2); the device answers with its own VERSION packet; the host then sends SETUP (payload 0x07)
 *     and from then on both sides use 16-byte headers (SETUP resets the sequence numbers).
 *   - TCP: the payload starts with a 20-byte tcp header. The host opens a connection with SYN (seq 0); the device must answer with exactly
 *     SYN|ACK; data and acknowledgements are flags ACK exactly; RST closes. th_win is the window in units of 256 bytes.
 *
 * usage:  usbmuxdev DIR [IOS_IP]    (DIR: the FunctionFS mount, /dev/usb-ffs/usbmux; IOS_IP default 10.77.0.2)
 * Written to ep0: the descriptors and strings, then it waits for ENABLE, opens ep1 (IN) and ep2 (OUT) and serves. Log on stderr.
 * Built with the NDK: $T/bin/aarch64-linux-android31-clang -O2 -Wall -pthread -o usbmuxdev usbmuxdev.c
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <endian.h>
#include <errno.h>
#include <stdarg.h>
#include <fcntl.h>
#include <linux/usb/ch9.h>
#include <linux/usb/functionfs.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#define MUX_VERSION 0
#define MUX_CONTROL 1
#define MUX_SETUP   2
#define MUX_TCP     6
#define TH_FIN 0x01
#define TH_SYN 0x02
#define TH_RST 0x04
#define TH_ACK 0x10
#define MAX_CONN 64
#define MAX_PAYLOAD 16384
#define WIN_SHIFT 8

struct mux_header2 {
	uint32_t protocol, length, magic;
	uint16_t tx_seq, rx_seq;
} __attribute__((packed));

struct tcp_hdr {
	uint16_t sport, dport;
	uint32_t seq, ack;
	uint8_t off;
	uint8_t flags;
	uint16_t win, sum, urp;
} __attribute__((packed));

struct conn {
	int used;
	uint16_t host_port, dev_port;   /* the host's source port, the device port asked for */
	int fd;                         /* the connection to iOS */
	uint32_t our_seq, our_ack;      /* our sequence (bytes sent + 1), what we have of the host's (bytes + 1) */
	uint32_t host_acked;            /* the host's th_ack */
	uint32_t host_win;              /* bytes the host takes unacknowledged */
};

static int ep_in = -1, ep_out = -1;
static pthread_mutex_t wlock = PTHREAD_MUTEX_INITIALIZER, clock_ = PTHREAD_MUTEX_INITIALIZER;
static int setup_done;
static uint16_t tx_seq, rx_seq = 0xffff;
static struct conn conns[MAX_CONN];
static const char *ios_ip = "10.77.0.2";

static void
say(const char *fmt, ...)
{
	va_list ap;
	struct timeval tv;

	gettimeofday(&tv, NULL);
	fprintf(stderr, "usbmuxdev %ld.%03ld: ", (long)tv.tv_sec % 100000, (long)tv.tv_usec / 1000);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
}

/* one packet to the host */
static void
send_packet(uint32_t protocol, const void *head, size_t headlen, const void *payload, size_t paylen)
{
	uint8_t buf[64 + MAX_PAYLOAD + 64];
	size_t hdr = setup_done ? sizeof(struct mux_header2) : 8, total = hdr + headlen + paylen, off;
	uint32_t v;

	if (total > sizeof buf) {
		return;
	}
	v = htonl(protocol);
	memcpy(buf, &v, 4);
	v = htonl((uint32_t)total);
	memcpy(buf + 4, &v, 4);
	pthread_mutex_lock(&wlock);
	if (setup_done) {
		struct mux_header2 *h = (struct mux_header2 *)buf;

		h->magic = htonl(0xfeedface);
		h->tx_seq = htons(tx_seq++);
		h->rx_seq = htons(rx_seq);
	}
	off = hdr;
	if (head != NULL) {
		memcpy(buf + off, head, headlen);
		off += headlen;
	}
	if (payload != NULL) {
		memcpy(buf + off, payload, paylen);
	}
	if (write(ep_in, buf, total) != (ssize_t)total) {
		say("write to the host: %s", strerror(errno));
	}
	pthread_mutex_unlock(&wlock);
}

static void
send_tcp(const struct conn *c, uint8_t flags, const void *payload, size_t len, uint32_t seq, uint32_t ack)
{
	struct tcp_hdr t;

	memset(&t, 0, sizeof t);
	t.sport = htons(c->dev_port);
	t.dport = htons(c->host_port);
	t.seq = htonl(seq);
	t.ack = htonl(ack);
	t.off = 5 << 4;
	t.flags = flags;
	t.win = htons(131072 >> WIN_SHIFT);
	send_packet(MUX_TCP, &t, sizeof t, payload, len);
}

static void
close_conn(struct conn *c, const char *why)
{
	pthread_mutex_lock(&clock_);
	if (c->used) {
		say("connection %u -> %u closed: %s", c->host_port, c->dev_port, why);
		if (c->fd >= 0) {
			shutdown(c->fd, SHUT_RDWR);
			close(c->fd);
		}
		c->fd = -1;
		c->used = 0;
	}
	pthread_mutex_unlock(&clock_);
}

/* iOS -> host */
static void *
pump(void *arg)
{
	struct conn *c = arg;
	uint8_t buf[MAX_PAYLOAD];
	int fd = c->fd;

	for (;;) {
		ssize_t n = read(fd, buf, sizeof buf);

		if (n <= 0) {
			break;
		}
		/* the host's window: do not run more than it takes ahead of its acknowledgements */
		for (int w = 0; w < 5000 && c->used && c->our_seq - c->host_acked + (uint32_t)n > c->host_win; w++) {
			usleep(2000);
		}
		if (!c->used) {
			break;
		}
		send_tcp(c, TH_ACK, buf, (size_t)n, c->our_seq, c->our_ack);
		c->our_seq += (uint32_t)n;
	}
	if (c->used && c->fd == fd) {
		const char *msg = "closed\n";

		send_tcp(c, TH_RST, msg, strlen(msg), c->our_seq, c->our_ack);
		close_conn(c, "iOS closed it");
	}
	return NULL;
}


/*
 * A stand-in for lockdownd for when iOS is not running (the phone is in Android mode): enough for the Mac to list the device by name. Lockdown messages
 * are a 4-byte big-endian length and an XML plist; unpaired devices answer QueryType and GetValue of the plain identification keys.
 */
static const struct { const char *key, *value; } lockdown_values[] = {
	{ "DeviceName", "Pixel 11 (iOS port)" }, { "ProductType", "iPhone14,2" }, { "ProductVersion", "16.5" }, { "BuildVersion", "20F66" },
	{ "DeviceClass", "iPhone" }, { "HardwareModel", "D63AP" }, { "ModelNumber", "MLKH3" }, { "CPUArchitecture", "arm64" },
	{ "UniqueDeviceID", "00008140-001A2B3C4D5E6F70" }, { "SerialNumber", "PIXEL11IOS01" }, { "ActivationState", "Activated" },
	{ "FirmwareVersion", "iBoot-8422.141.2" }, { "ProductName", "iPhone OS" }, { "RegionInfo", "LL/A" }, { "TimeZone", "UTC" },
	{ "TrustedHostAttached", "" }, { NULL, NULL },
};

static int
xml_string(const char *buf, const char *key, char *out, size_t outlen)
{
	char pat[96];
	const char *p, *q;

	snprintf(pat, sizeof pat, "<key>%s</key>", key);
	p = strstr(buf, pat);
	if (p == NULL) {
		return 0;
	}
	p = strstr(p, "<string>");
	if (p == NULL) {
		return 0;
	}
	p += 8;
	q = strstr(p, "</string>");
	if (q == NULL || (size_t)(q - p) >= outlen) {
		return 0;
	}
	memcpy(out, p, (size_t)(q - p));
	out[q - p] = 0;
	return 1;
}

static void
lockdown_reply(int fd, const char *body)
{
	char buf[8192];
	uint32_t n = (uint32_t)snprintf(buf + 4, sizeof buf - 4,
	    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
	    "<plist version=\"1.0\">\n<dict>\n%s</dict>\n</plist>\n", body);
	uint32_t be = htonl(n);

	memcpy(buf, &be, 4);
	(void)!write(fd, buf, 4 + n);
}

static void *
lockdown_stub(void *arg)
{
	int fd = (int)(intptr_t)arg;
	char msg[16384], req[64], key[64], out[8192];

	for (;;) {
		uint32_t be, n, got = 0;

		if (read(fd, &be, 4) != 4) {
			break;
		}
		n = ntohl(be);
		if (n == 0 || n >= sizeof msg) {
			break;
		}
		while (got < n) {
			ssize_t r = read(fd, msg + got, n - got);

			if (r <= 0) {
				goto done;
			}
			got += (uint32_t)r;
		}
		msg[n] = 0;
		req[0] = key[0] = 0;
		xml_string(msg, "Request", req, sizeof req);
		xml_string(msg, "Key", key, sizeof key);
		say("lockdown stub: %s %s", req, key);
		if (strcmp(req, "QueryType") == 0) {
			lockdown_reply(fd, "<key>Request</key><string>QueryType</string>\n<key>Type</key><string>com.apple.mobile.lockdown</string>\n");
		} else if (strcmp(req, "GetValue") == 0) {
			const char *v = NULL;
			int i;

			for (i = 0; lockdown_values[i].key != NULL; i++) {
				if (key[0] != 0 && strcmp(key, lockdown_values[i].key) == 0) {
					v = lockdown_values[i].value;
				}
			}
			if (key[0] != 0 && v != NULL) {
				snprintf(out, sizeof out, "<key>Key</key><string>%s</string>\n<key>Request</key><string>GetValue</string>\n<key>Value</key><string>%s</string>\n", key, v);
			} else if (key[0] == 0) {
				size_t o = 0;

				o += (size_t)snprintf(out + o, sizeof out - o, "<key>Request</key><string>GetValue</string>\n<key>Value</key><dict>\n");
				for (i = 0; lockdown_values[i].key != NULL; i++) {
					o += (size_t)snprintf(out + o, sizeof out - o, "<key>%s</key><string>%s</string>\n", lockdown_values[i].key, lockdown_values[i].value);
				}
				snprintf(out + o, sizeof out - o, "</dict>\n");
			} else {
				snprintf(out, sizeof out, "<key>Error</key><string>MissingValue</string>\n<key>Key</key><string>%s</string>\n<key>Request</key><string>GetValue</string>\n", key);
			}
			lockdown_reply(fd, out);
		} else if (strcmp(req, "Pair") == 0 || strcmp(req, "ValidatePair") == 0 || strcmp(req, "StartSession") == 0 ||
			   strcmp(req, "StopSession") == 0 || strcmp(req, "SetValue") == 0 || strcmp(req, "RemoveValue") == 0) {
			/* pairing without a real lockdownd: the host's id is remembered; sessions run without SSL (EnableSessionSSL false) */
			char host[128] = "", known[128];
			int ok = 1;

			xml_string(msg, "HostID", host, sizeof host);
			if (strcmp(req, "Pair") == 0 && host[0] != 0) {
				FILE *f = fopen("/data/local/ios/lockdown_hosts.txt", "a");

				if (f != NULL) {
					fprintf(f, "%s\n", host);
					fclose(f);
				}
				say("lockdown stub: paired with host %s", host);
				snprintf(out, sizeof out, "<key>EscrowBag</key><data>AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=</data>\n<key>Request</key><string>Pair</string>\n");
			} else if (strcmp(req, "ValidatePair") == 0 || strcmp(req, "StartSession") == 0) {
				FILE *f = fopen("/data/local/ios/lockdown_hosts.txt", "r");

				ok = 0;
				while (f != NULL && fgets(known, sizeof known, f) != NULL) {
					known[strcspn(known, "\n")] = 0;
					ok |= known[0] != 0 && strcmp(known, host) == 0;
				}
				if (f != NULL) {
					fclose(f);
				}
				if (!ok) {
					snprintf(out, sizeof out, "<key>Error</key><string>InvalidHostID</string>\n<key>Request</key><string>%s</string>\n", req);
				} else if (strcmp(req, "StartSession") == 0) {
					snprintf(out, sizeof out, "<key>EnableSessionSSL</key><false/>\n<key>Request</key><string>StartSession</string>\n"
						 "<key>SessionID</key><string>C0B5C0B5-0000-4000-8000-000000000001</string>\n");
				} else {
					snprintf(out, sizeof out, "<key>Request</key><string>ValidatePair</string>\n");
				}
			} else {
				snprintf(out, sizeof out, "<key>Request</key><string>%s</string>\n", req);
			}
			lockdown_reply(fd, out);
		} else if (strcmp(req, "StartService") == 0) {
			char svc[96] = "";

			xml_string(msg, "Service", svc, sizeof svc);
			snprintf(out, sizeof out, "<key>Error</key><string>InvalidService</string>\n<key>Request</key><string>StartService</string>\n<key>Service</key><string>%s</string>\n", svc);
			lockdown_reply(fd, out);
		} else {
			snprintf(out, sizeof out, "<key>Error</key><string>InvalidRequest</string>\n<key>Request</key><string>%s</string>\n", req);
			lockdown_reply(fd, out);
		}
	}
done:
	close(fd);
	return NULL;
}

static struct conn *
find_conn(uint16_t host_port, uint16_t dev_port)
{
	for (int i = 0; i < MAX_CONN; i++) {
		if (conns[i].used && conns[i].host_port == host_port && conns[i].dev_port == dev_port) {
			return &conns[i];
		}
	}
	return NULL;
}

static void
handle_tcp(const uint8_t *p, size_t len)
{
	const struct tcp_hdr *t = (const struct tcp_hdr *)p;
	uint16_t hport, dport;
	uint32_t seq, ack;
	size_t hl;
	struct conn *c;

	if (len < sizeof *t) {
		return;
	}
	hport = ntohs(t->sport);
	dport = ntohs(t->dport);
	seq = ntohl(t->seq);
	ack = ntohl(t->ack);
	hl = (size_t)(t->off >> 4) * 4;
	if (hl < sizeof *t || hl > len) {
		return;
	}
	c = find_conn(hport, dport);
	if (t->flags & TH_RST) {
		if (c != NULL) {
			close_conn(c, "reset by the host");
		}
		return;
	}
	if (t->flags & TH_SYN) {
		struct sockaddr_in a;
		struct timeval tv = { 3, 0 };
		int fd, i;
		pthread_t th;

		if (c != NULL) {
			close_conn(c, "again");
		}
		fd = socket(AF_INET, SOCK_STREAM, 0);
		memset(&a, 0, sizeof a);
		a.sin_family = AF_INET;
		a.sin_port = htons(dport);
		inet_pton(AF_INET, ios_ip, &a.sin_addr);
		setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
		int refused = connect(fd, (struct sockaddr *)&a, sizeof a) != 0;

		if (refused && dport == 62078) {
			/* iOS is not there: the stand-in for lockdownd answers on the other end of a socket pair */
			int sv[2];
			pthread_t lt;

			say("connection %u -> 62078: iOS %s: %s: the lockdown stand-in answers", hport, ios_ip, strerror(errno));
			close(fd);
			if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) {
				return;
			}
			fd = sv[0];
			pthread_create(&lt, NULL, lockdown_stub, (void *)(intptr_t)sv[1]);
			pthread_detach(lt);
		} else if (refused) {
			struct conn tmp = { .host_port = hport, .dev_port = dport };
			const char *msg = "refused\n";

			say("connection %u -> %u: iOS %s:%u: %s", hport, dport, ios_ip, dport, strerror(errno));
			close(fd);
			send_tcp(&tmp, TH_RST, msg, strlen(msg), 0, seq + 1);
			return;
		}
		setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &(int){ 1 }, sizeof(int));
		pthread_mutex_lock(&clock_);
		for (i = 0; i < MAX_CONN && conns[i].used; i++) {
		}
		if (i == MAX_CONN) {
			pthread_mutex_unlock(&clock_);
			close(fd);
			return;
		}
		c = &conns[i];
		memset(c, 0, sizeof *c);
		c->used = 1;
		c->host_port = hport;
		c->dev_port = dport;
		c->fd = fd;
		c->our_seq = 1;
		c->our_ack = seq + 1;
		c->host_acked = 1;
		c->host_win = (uint32_t)ntohs(t->win) << WIN_SHIFT;
		pthread_mutex_unlock(&clock_);
		say("connection %u -> %u open (iOS %s)", hport, dport, ios_ip);
		send_tcp(c, TH_SYN | TH_ACK, NULL, 0, 0, seq + 1);
		pthread_create(&th, NULL, pump, c);
		pthread_detach(th);
		return;
	}
	if (c == NULL) {
		struct conn tmp = { .host_port = hport, .dev_port = dport };

		send_tcp(&tmp, TH_RST, NULL, 0, 0, seq);
		return;
	}
	c->host_acked = ack;
	c->host_win = (uint32_t)ntohs(t->win) << WIN_SHIFT;
	if (len > hl) {
		size_t n = len - hl;
		const uint8_t *d = p + hl;

		while (n > 0) {
			ssize_t w = write(c->fd, d, n);

			if (w <= 0) {
				close_conn(c, "write to iOS failed");
				return;
			}
			d += w;
			n -= (size_t)w;
		}
		c->our_ack += (uint32_t)(len - hl);
		send_tcp(c, TH_ACK, NULL, 0, c->our_seq, c->our_ack);
	}
}

static void
handle_packet(const uint8_t *pkt, size_t len)
{
	uint32_t protocol, length;
	size_t hdr;

	if (len < 8) {
		return;
	}
	memcpy(&protocol, pkt, 4);
	memcpy(&length, pkt + 4, 4);
	protocol = ntohl(protocol);
	length = ntohl(length);
	if (length != len) {
		say("packet of %zu bytes says %u", len, length);
	}
	hdr = (!setup_done && protocol == MUX_VERSION) ? 8 : sizeof(struct mux_header2);
	if (len < hdr) {
		return;
	}
	if (hdr == sizeof(struct mux_header2)) {
		const struct mux_header2 *h = (const struct mux_header2 *)pkt;

		rx_seq = ntohs(h->tx_seq);
	}
	switch (protocol) {
	case MUX_VERSION: {
		uint32_t v[3] = { htonl(2), htonl(0), 0 };

		say("version request: major %u, answering 2.0", len >= 12 + hdr ? ntohl(*(const uint32_t *)(pkt + hdr)) : 0);
		setup_done = 0;
		send_packet(MUX_VERSION, v, sizeof v, NULL, 0);
		break;
	}
	case MUX_SETUP:
		say("setup (v2 headers from now on)");
		setup_done = 1;
		tx_seq = 0;
		rx_seq = 0xffff;
		break;
	case MUX_TCP:
		handle_tcp(pkt + hdr, len - hdr);
		break;
	default:
		say("packet protocol %u (%zu bytes) ignored", protocol, len);
	}
}

/* the descriptors of the usbmux interface: class 0xff, subclass 0xfe, protocol 2; bulk IN (ep1) and OUT (ep2) */
#define EP(addr, mps) { .bLength = USB_DT_ENDPOINT_SIZE, .bDescriptorType = USB_DT_ENDPOINT, .bEndpointAddress = (addr), \
	.bmAttributes = USB_ENDPOINT_XFER_BULK, .wMaxPacketSize = htole16(mps) }
#define INTF { .bLength = sizeof(struct usb_interface_descriptor), .bDescriptorType = USB_DT_INTERFACE, .bNumEndpoints = 2, \
	.bInterfaceClass = 0xff, .bInterfaceSubClass = 0xfe, .bInterfaceProtocol = 2, .iInterface = 1 }
#define COMP { .bLength = sizeof(struct usb_ss_ep_comp_descriptor), .bDescriptorType = USB_DT_SS_ENDPOINT_COMP, .bMaxBurst = 4 }

struct func_desc {
	struct usb_interface_descriptor intf;
	struct usb_endpoint_descriptor_no_audio in, out;
} __attribute__((packed));
struct ss_func_desc {
	struct usb_interface_descriptor intf;
	struct usb_endpoint_descriptor_no_audio in;
	struct usb_ss_ep_comp_descriptor in_comp;
	struct usb_endpoint_descriptor_no_audio out;
	struct usb_ss_ep_comp_descriptor out_comp;
} __attribute__((packed));
struct descs {
	struct usb_functionfs_descs_head_v2 header;
	__le32 fs_count, hs_count, ss_count;
	struct func_desc fs, hs;
	struct ss_func_desc ss;
} __attribute__((packed));

static const struct descs descriptors = {
	.header = { .magic = htole32(FUNCTIONFS_DESCRIPTORS_MAGIC_V2), .length = htole32(sizeof(struct descs)),
		    .flags = htole32(FUNCTIONFS_HAS_FS_DESC | FUNCTIONFS_HAS_HS_DESC | FUNCTIONFS_HAS_SS_DESC) },
	.fs_count = htole32(3), .hs_count = htole32(3), .ss_count = htole32(5),
	.fs = { INTF, EP(1 | USB_DIR_IN, 64), EP(2 | USB_DIR_OUT, 64) },
	.hs = { INTF, EP(1 | USB_DIR_IN, 512), EP(2 | USB_DIR_OUT, 512) },
	.ss = { INTF, EP(1 | USB_DIR_IN, 1024), COMP, EP(2 | USB_DIR_OUT, 1024), COMP },
};

static const struct {
	struct usb_functionfs_strings_head header;
	struct {
		__le16 code;
		const char str1[7];
	} __attribute__((packed)) lang0;
} __attribute__((packed)) strings = {
	.header = { .magic = htole32(FUNCTIONFS_STRINGS_MAGIC), .length = htole32(sizeof strings), .str_count = htole32(1), .lang_count = htole32(1) },
	.lang0 = { htole16(0x0409), "usbmux" },
};

static void *serve(void *arg);

int
main(int argc, char **argv)
{
	char path[256];
	int ep0;
	struct usb_functionfs_event ev;

	if (argc < 2) {
		fprintf(stderr, "usage: usbmuxdev FFSDIR [IOS_IP]\n");
		return 2;
	}
	if (argc > 2) {
		ios_ip = argv[2];
	}
	signal(SIGPIPE, SIG_IGN);
	snprintf(path, sizeof path, "%s/ep0", argv[1]);
	ep0 = open(path, O_RDWR);
	if (ep0 < 0) {
		say("%s: %s", path, strerror(errno));
		return 1;
	}
	if (write(ep0, &descriptors, sizeof descriptors) != (ssize_t)sizeof descriptors || write(ep0, &strings, sizeof strings) != (ssize_t)sizeof strings) {
		say("descriptors: %s", strerror(errno));
		return 1;
	}
	say("descriptors written; waiting for the host (bind the gadget now)");
	for (;;) {
		if (read(ep0, &ev, sizeof ev) != (ssize_t)sizeof ev) {
			say("ep0: %s", strerror(errno));
			return 1;
		}
		switch (ev.type) {
		case FUNCTIONFS_BIND:
			say("bound");
			break;
		case FUNCTIONFS_ENABLE: {
			char p1[256], p2[256];

			say("enabled by the host: opening the bulk endpoints");
			snprintf(p1, sizeof p1, "%s/ep1", argv[1]);
			snprintf(p2, sizeof p2, "%s/ep2", argv[1]);
			ep_in = open(p1, O_WRONLY);
			ep_out = open(p2, O_RDONLY);
			if (ep_in < 0 || ep_out < 0) {
				say("endpoints: %s", strerror(errno));
				return 1;
			}
			setup_done = 0;
			/* the serving: a thread reads the OUT endpoint */
			{
				pthread_t th;

				pthread_create(&th, NULL, serve, NULL);
				pthread_detach(th);
			}
			break;
		}
		case FUNCTIONFS_DISABLE:
			say("disabled");
			for (int i = 0; i < MAX_CONN; i++) {
				if (conns[i].used) {
					close_conn(&conns[i], "usb disabled");
				}
			}
			if (ep_in >= 0) {
				close(ep_in);
			}
			if (ep_out >= 0) {
				close(ep_out);
			}
			ep_in = ep_out = -1;
			break;
		case FUNCTIONFS_SETUP:
			/* a control request for the interface: stalled (usbmux has none) */
			say("control request %02x/%02x", ev.u.setup.bRequestType, ev.u.setup.bRequest);
			if (ev.u.setup.bRequestType & USB_DIR_IN) {
				(void)!read(ep0, NULL, 0);
			} else {
				(void)!write(ep0, NULL, 0);
			}
			break;
		case FUNCTIONFS_SUSPEND:
		case FUNCTIONFS_RESUME:
		case FUNCTIONFS_UNBIND:
			say("event %d", ev.type);
			break;
		}
	}
}

static void *
serve(void *arg)
{
	static uint8_t buf[1 << 17];
	static uint8_t acc[1 << 18];
	size_t have = 0;
	int fd = ep_out;

	(void)arg;
	for (;;) {
		ssize_t n = read(fd, buf, sizeof buf);

		if (n < 0) {
			say("read from the host: %s", strerror(errno));
			break;
		}
		if (n == 0) {
			continue;
		}
		if (have + (size_t)n > sizeof acc) {
			have = 0;
		}
		memcpy(acc + have, buf, (size_t)n);
		have += (size_t)n;
		/* the packets of the stream: each says its length */
		while (have >= 8) {
			uint32_t length;

			memcpy(&length, acc + 4, 4);
			length = ntohl(length);
			if (length < 8 || length > sizeof acc) {
				say("bad packet length %u: dropped %zu bytes", length, have);
				have = 0;
				break;
			}
			if (have < length) {
				break;
			}
			handle_packet(acc, length);
			memmove(acc, acc + length, have - length);
			have -= length;
		}
	}
	return NULL;
}
