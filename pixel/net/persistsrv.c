/*
 * persistsrv: Android's end of iOS persistence (the iOS root is a RAM image: nothing survives a reboot by itself).
 * A tiny HTTP server on the iOS-facing address (default 10.77.0.1:8099) that keeps one tar file:
 *   GET  /persist.tar  -> the saved archive (404 when there is none yet)
 *   PUT  /persist.tar  -> replaces it (body = the archive; Content-Length or chunked is not needed: read until close)
 *   POST /persist.tar  -> same as PUT (curl -T - and --data-binary both work)
 * iOS side (Procursus has curl and tar): restore  curl -sf http://10.77.0.1:8099/persist.tar | tar -x -C /
 *                                       save     tar -c -C / var/jb/... | curl -sf -T - http://10.77.0.1:8099/persist.tar
 *   GET  /inbox.list   -> one file name per line: the .deb files in /data/local/ios/inbox (push packages there with adb)
 *   GET  /inbox/NAME   -> that file
 * The file lives in /data/local/ios (PERSIST_FILE overrides); a new upload is written to a temp file and renamed over the old one
 * only when it arrived completely (Content-Length checked when given), so a cut connection never destroys the last good archive.
 * Built with the NDK: $T/bin/aarch64-linux-android31-clang -O2 -Wall -o persistsrv persistsrv.c
 */
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#define FILE_DEFAULT "/data/local/ios/persist.tar"

static const char *path;

static void
send_all(int fd, const void *p, size_t n)
{
	const char *c = p;

	while (n > 0) {
		ssize_t w = write(fd, c, n);

		if (w <= 0) {
			return;
		}
		c += w;
		n -= (size_t)w;
	}
}

static void
reply(int fd, const char *status, long len)
{
	char h[160];
	int n = snprintf(h, sizeof h, "HTTP/1.0 %s\r\nContent-Type: application/x-tar\r\nContent-Length: %ld\r\nConnection: close\r\n\r\n", status, len);

	send_all(fd, h, (size_t)n);
}

static void
serve(int c)
{
	char buf[65536];
	size_t have = 0;
	char *eoh = NULL;

	while (have < sizeof buf - 1 && !(eoh = memmem(buf, have, "\r\n\r\n", 4))) {
		ssize_t r = read(c, buf + have, sizeof buf - 1 - have);

		if (r <= 0) {
			return;
		}
		have += (size_t)r;
	}
	if (eoh == NULL) {
		return;
	}
	buf[have] = 0;
	size_t head = (size_t)(eoh - buf) + 4;

	if (strncmp(buf, "GET /brightness/", 16) == 0) {
		/* iOS tells its brightness in thousandths (0..1000); the panel's backlight is Android's, so the level is written to it here.
		 * The curve is squared (the eye is logarithmic); never fully off, as nothing could then be seen to turn it up again. */
		const char *dir = getenv("BL_DIR") ? getenv("BL_DIR") : "/sys/class/backlight/panel0-backlight";
		char node[300];
		int pm = atoi(buf + 16), max = 3870;
		FILE *m;

		snprintf(node, sizeof node, "%s/max_brightness", dir);
		if ((m = fopen(node, "r")) != NULL) {
			if (fscanf(m, "%d", &max) != 1) {
				max = 3870;
			}
			fclose(m);
		}
		pm = pm < 0 ? 0 : pm > 1000 ? 1000 : pm;
		long val = (long)((double)max * ((double)pm / 1000.0) * ((double)pm / 1000.0));
		val = val < 2 ? 2 : val;
		snprintf(node, sizeof node, "%s/brightness", dir);
		FILE *w = fopen(node, "w");

		if (w != NULL) {
			fprintf(w, "%ld\n", val);
			fclose(w);
			fprintf(stderr, "persistsrv: brightness %d/1000 -> %ld of %d\n", pm, val, max);
			reply(c, "200 OK", 0);
		} else {
			reply(c, "500 Internal Server Error", 0);
		}
		return;
	}
	if (strncmp(buf, "GET /persist.tar", 16) == 0) {
		int f = open(path, O_RDONLY);
		struct stat st;

		if (f < 0 || fstat(f, &st) < 0) {
			reply(c, "404 Not Found", 0);
			if (f >= 0) {
				close(f);
			}
			return;
		}
		reply(c, "200 OK", (long)st.st_size);
		ssize_t r;

		while ((r = read(f, buf, sizeof buf)) > 0) {
			send_all(c, buf, (size_t)r);
		}
		close(f);
		return;
	}
	if (strncmp(buf, "GET /inbox", 10) == 0) {
		const char *dir = getenv("PERSIST_INBOX") ? getenv("PERSIST_INBOX") : "/data/local/ios/inbox";
		char name[200] = "", full[400];

		if (strncmp(buf, "GET /inbox.list", 15) == 0) {
			DIR *d = opendir(dir);
			char out[8192];
			size_t n = 0;
			struct dirent *e;

			while (d != NULL && (e = readdir(d)) != NULL && n + 300 < sizeof out) {
				size_t l = strlen(e->d_name);

				if (e->d_name[0] != '.' && l > 4 && strcmp(e->d_name + l - 4, ".deb") == 0) {
					n += (size_t)snprintf(out + n, sizeof out - n, "%s\n", e->d_name);
				}
			}
			if (d != NULL) {
				closedir(d);
			}
			reply(c, "200 OK", (long)n);
			send_all(c, out, n);
			return;
		}
		if (sscanf(buf, "GET /inbox/%199[A-Za-z0-9._+-] ", name) == 1 && strstr(name, "..") == NULL) {
			snprintf(full, sizeof full, "%s/%s", dir, name);
			int f = open(full, O_RDONLY);
			struct stat st;

			if (f < 0 || fstat(f, &st) < 0) {
				reply(c, "404 Not Found", 0);
				if (f >= 0) {
					close(f);
				}
				return;
			}
			reply(c, "200 OK", (long)st.st_size);
			ssize_t r;

			while ((r = read(f, buf, sizeof buf)) > 0) {
				send_all(c, buf, (size_t)r);
			}
			close(f);
			return;
		}
		reply(c, "404 Not Found", 0);
		return;
	}
	if (strncmp(buf, "PUT ", 4) == 0 || strncmp(buf, "POST ", 5) == 0) {
		long want = -1;
		const char *cl = strcasestr(buf, "\r\nContent-Length:");

		if (cl != NULL && cl < buf + head) {
			want = atol(cl + 17);
		}
		char tmp[256];

		snprintf(tmp, sizeof tmp, "%s.tmp", path);
		int f = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);

		if (f < 0) {
			reply(c, "500 Internal Server Error", 0);
			return;
		}
		long got = 0;

		if (have > head) {
			(void)!write(f, buf + head, have - head);
			got = (long)(have - head);
		}
		while (want < 0 || got < want) {
			ssize_t r = read(c, buf, sizeof buf);

			if (r <= 0) {
				break;
			}
			(void)!write(f, buf, (size_t)r);
			got += r;
		}
		close(f);
		if (want >= 0 && got != want) {
			unlink(tmp);
			reply(c, "400 Bad Request", 0);
			return;
		}
		{
			char prev[256];

			snprintf(prev, sizeof prev, "%s.prev", path);
			rename(path, prev);
		}
		rename(tmp, path);
		reply(c, "200 OK", 0);
		printf("persistsrv: stored %ld bytes\n", got);
		fflush(stdout);
		return;
	}
	reply(c, "405 Method Not Allowed", 0);
}

int
main(void)
{
	const char *addr = getenv("PERSIST_ADDR") ? getenv("PERSIST_ADDR") : "10.77.0.1";
	int port = getenv("PERSIST_PORT") ? atoi(getenv("PERSIST_PORT")) : 8099, one = 1;
	struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons((uint16_t)port) };
	int ls = socket(AF_INET, SOCK_STREAM, 0);

	path = getenv("PERSIST_FILE") ? getenv("PERSIST_FILE") : FILE_DEFAULT;
	inet_pton(AF_INET, addr, &a.sin_addr);
	setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
	/* the address exists only once netsrv has made the iOS-facing interface: wait for it */
	while (bind(ls, (struct sockaddr *)&a, sizeof a) < 0) {
		sleep(2);
	}
	if (listen(ls, 4) < 0) {
		perror("persistsrv: listen");
		return 1;
	}
	printf("persistsrv: %s:%d -> %s\n", addr, port, path);
	fflush(stdout);
	for (;;) {
		int c = accept(ls, NULL, NULL);

		if (c < 0) {
			continue;
		}
		serve(c);
		close(c);
	}
}
