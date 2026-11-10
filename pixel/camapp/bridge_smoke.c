/* Android-only local socket smoke test. Never stores or prints camera pixels. */
#include <arpa/inet.h>
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
static int listen_on(unsigned short port) {
    int fd=socket(AF_INET,SOCK_STREAM,0), one=1;
    struct sockaddr_in a={.sin_family=AF_INET,.sin_port=htons(port),.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    if (fd<0) return -1;
    setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one));
    if (bind(fd,(struct sockaddr *)&a,sizeof(a)) || listen(fd,1)) { close(fd); return -1; }
    return fd;
}
static uint32_t le32(const unsigned char *p) { return p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24; }
int main(void) {
    signal(SIGPIPE,SIG_IGN);
    int cam=listen_on(7777),snd=listen_on(7778), got_cam=0,got_snd=0;
    if (cam<0 || snd<0) { puts("ports-unavailable"); return 1; }
    puts("listeners-ready"); fflush(stdout);
    struct pollfd p[2]={{.fd=cam,.events=POLLIN},{.fd=snd,.events=POLLIN}};
    for (int i=0;i<200 && (!got_cam || !got_snd);i++) {
        int r=poll(p,2,100); if (r<0 && errno==EINTR) continue; if (r<0) return 2;
        for (int j=0;j<2;j++) if (p[j].fd>=0 && (p[j].revents&POLLIN)) {
            int c=accept(p[j].fd,NULL,NULL); if (c<0) continue;
            struct timeval tv={.tv_sec=4}; setsockopt(c,SOL_SOCKET,SO_RCVTIMEO,&tv,sizeof(tv));
            if (j==0) {
                unsigned char h[20]; size_t n=0;
                while (n<sizeof(h)) { ssize_t k=read(c,h+n,sizeof(h)-n); if(k<=0) break; n+=(size_t)k; }
                got_cam=n==sizeof(h) && le32(h)==0x31414d43 && le32(h+8)==640 && le32(h+12)==480 && le32(h+16)==460800;
            } else { unsigned char silence[8192]={0}; got_snd=write(c,silence,sizeof(silence))==(ssize_t)sizeof(silence); }
            close(c); close(p[j].fd); p[j].fd=-1;
        }
    }
    printf("camera-frame-header=%s silent-audio-sent=%s\n",got_cam?"ok":"missing",got_snd?"ok":"missing");
    return got_cam && got_snd ? 0 : 3;
}
