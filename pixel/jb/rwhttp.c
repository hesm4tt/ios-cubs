/*
 * rwhttp: a minimal HTTP/1.0 client for iOS jobs (the Procursus bootstrap has no curl/wget).
 *   rwhttp get URL [OUTFILE]    body to OUTFILE (default stdout); exit 0 only for status 200
 *   rwhttp put URL INFILE       sends INFILE as the body (Content-Length), exit 0 only for status 200
 * Plain http:// only (the Android persistsrv on 10.77.0.1:8099). Build:
 *   xnu-clang -arch arm64 -isysroot $THEOS/sdks/iPhoneOS16.5.sdk -O1 -o rwhttp rwhttp.c
 */
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

static int
dial(const char *host, int port)
{
	struct addrinfo hints = { .ai_family = AF_INET, .ai_socktype = SOCK_STREAM }, *res;
	char ps[16];
	int fd;
	struct timeval tv = { 60, 0 };

	snprintf(ps, sizeof ps, "%d", port);
	if (getaddrinfo(host, ps, &hints, &res) != 0) {
		return -1;
	}
	fd = socket(res->ai_family, res->ai_socktype, 0);
	if (fd < 0) {
		freeaddrinfo(res);
		return -1;
	}
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
	if (connect(fd, res->ai_addr, res->ai_addrlen) < 0) {
		close(fd);
		freeaddrinfo(res);
		return -1;
	}
	freeaddrinfo(res);
	return fd;
}

int
main(int argc, char **argv)
{
	char host[128] = "", path[512] = "/", req[1024], buf[65536];
	int port = 80, fd, status = 0, put, out = 1, in = -1;
	size_t have = 0;
	char *eoh = NULL;
	const char *u;

	if (argc < 3 || (strcmp(argv[1], "get") != 0 && strcmp(argv[1], "put") != 0)) {
		fprintf(stderr, "usage: rwhttp get URL [OUTFILE] | rwhttp put URL INFILE\n");
		return 2;
	}
	put = strcmp(argv[1], "put") == 0;
	if (strncmp(argv[2], "http://", 7) != 0) {
		return 2;
	}
	u = argv[2] + 7;
	{
		size_t n = strcspn(u, ":/");

		if (n == 0 || n >= sizeof host) {
			return 2;
		}
		memcpy(host, u, n);
		host[n] = 0;
		u += n;
		if (*u == ':') {
			port = atoi(u + 1);
			u += strcspn(u, "/");
		}
		if (*u == '/') {
			snprintf(path, sizeof path, "%s", u);
		}
	}
	if (put) {
		struct stat st;

		if (argc < 4 || (in = open(argv[3], O_RDONLY)) < 0 || fstat(in, &st) < 0) {
			perror("rwhttp: input");
			return 2;
		}
		snprintf(req, sizeof req, "PUT %s HTTP/1.0\r\nHost: %s\r\nContent-Length: %lld\r\nConnection: close\r\n\r\n", path, host,
		    (long long)st.st_size);
	} else {
		snprintf(req, sizeof req, "GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n", path, host);
		if (argc > 3 && (out = open(argv[3], O_WRONLY | O_CREAT | O_TRUNC, 0644)) < 0) {
			perror("rwhttp: output");
			return 2;
		}
	}
	if ((fd = dial(host, port)) < 0) {
		fprintf(stderr, "rwhttp: cannot connect to %s:%d\n", host, port);
		return 1;
	}
	if (write(fd, req, strlen(req)) < 0) {
		return 1;
	}
	if (put) {
		ssize_t r;

		while ((r = read(in, buf, sizeof buf)) > 0) {
			ssize_t w = 0;

			while (w < r) {
				ssize_t k = write(fd, buf + w, (size_t)(r - w));

				if (k <= 0) {
					return 1;
				}
				w += k;
			}
		}
	}
	for (;;) {
		ssize_t r;

		buf[have] = 0;
		if ((eoh = strstr(buf, "\r\n\r\n")) != NULL || have >= sizeof buf - 1) {
			break;
		}
		r = read(fd, buf + have, sizeof buf - 1 - have);
		if (r <= 0) {
			return 1;
		}
		have += (size_t)r;
	}
	if (eoh == NULL || sscanf(buf, "HTTP/%*s %d", &status) != 1) {
		return 1;
	}
	if (!put && status == 200) {
		size_t head = (size_t)(eoh - buf) + 4;
		ssize_t r;

		if (have > head && write(out, buf + head, have - head) < 0) {
			return 1;
		}
		while ((r = read(fd, buf, sizeof buf)) > 0) {
			if (write(out, buf, (size_t)r) < 0) {
				return 1;
			}
		}
	}
	close(fd);
	return status == 200 ? 0 : 1;
}
