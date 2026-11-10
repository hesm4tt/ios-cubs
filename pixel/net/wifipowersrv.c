/* Experimental, default-disabled Wi-Fi power receiver; no credentials.
 * PWR1: response seq/status at 0x80, claim at 0xc0, request seq/value at
 * 0x100, decision at 0x180 (seq=commit, seq|1=cancel).
 * Status: 1 desired state observed, 2 rejected/cancelled, 3 outcome unknown.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#define OFF 0x2300000
#define MAGIC 0x31525750u

static int observed_line(int fd) {
    const char expected[]="state-observed\n";
    char buf[64]={0}; size_t n=0;
    struct timespec start, now;
    if (clock_gettime(CLOCK_MONOTONIC,&start)) return 0;
    while (n<sizeof(buf)-1) {
        if (clock_gettime(CLOCK_MONOTONIC,&now)) return 0;
        int64_t ms=(now.tv_sec-start.tv_sec)*1000LL+(now.tv_nsec-start.tv_nsec)/1000000LL;
        if (ms>=15000) return 0;
        struct pollfd p={.fd=fd,.events=POLLIN};
        int ready=poll(&p,1,(int)(15000-ms));
        if (ready<0 && errno==EINTR) continue;
        if (ready<=0) return 0;
        ssize_t k=read(fd,buf+n,sizeof(buf)-1-n);
        if (k<0 && errno==EINTR) continue;
        if (k<=0) return 0;
        n+=(size_t)k;
        if (memchr(buf,'\n',n)) return n==sizeof(expected)-1 && !memcmp(buf,expected,n);
    }
    return 0;
}
static int invoke(unsigned desired) {
    int output[2]; if (pipe(output)) return 0;
    pid_t child=fork();
    if (child<0) { close(output[0]); close(output[1]); return 0; }
    if (!child) {
        dup2(output[1],STDOUT_FILENO);
        int nullfd=open("/dev/null",O_WRONLY); if (nullfd>=0) dup2(nullfd,STDERR_FILENO);
        close(output[0]); close(output[1]);
#ifdef CUBS_POWER_TEST
        const char *helper=getenv("CUBS_POWER_TEST_HELPER");
        if (helper) { execl(helper,helper,desired?"on":"off",(char *)NULL); _exit(127); }
#endif
        struct stat parent,dir,dex;
        if (lstat("/data/adb",&parent) || !S_ISDIR(parent.st_mode) || parent.st_uid || (parent.st_mode&022) ||
            lstat("/data/adb/cubs-wifi",&dir) || !S_ISDIR(dir.st_mode) || dir.st_uid || (dir.st_mode&077) ||
            lstat("/data/adb/cubs-wifi/cubs-wifi-power-helper.dex",&dex) || !S_ISREG(dex.st_mode) || dex.st_uid || (dex.st_mode&077)) _exit(126);
        setenv("CLASSPATH","/data/adb/cubs-wifi/cubs-wifi-power-helper.dex",1);
        execl("/system/bin/app_process","app_process","/system/bin","com.cubs.cam.PrivilegedWifiPower",desired?"on":"off",(char *)NULL);
        _exit(127);
    }
    close(output[1]); int ok=observed_line(output[0]); close(output[0]);
    kill(child,SIGKILL); while (waitpid(child,NULL,0)<0 && errno==EINTR) { }
    return ok;
}
int main(void) {
    const char *path=getenv("CUBS_POWER_RING");
    int fd=open(path?path:"/dev/cubs_ram",O_RDWR|O_NOFOLLOW);
    struct stat st;
    if (fd<0 || fstat(fd,&st) || st.st_uid || (st.st_mode&022)) return 1;
    uint32_t zero=0, magic=MAGIC, last=0;
    const unsigned offsets[]={0x80,0x84,0xc0,0x100,0x104,0x180};
    for (unsigned i=0;i<sizeof(offsets)/sizeof(offsets[0]);i++)
        if (pwrite(fd,&zero,4,OFF+offsets[i])!=4) return 1;
    if (pwrite(fd,&magic,4,OFF)!=4) return 1;
    for (;;) {
        uint32_t seq=0,desired=0,check=0,status=2;
        if (pread(fd,&seq,4,OFF+0x100)!=4) return 1;
        if (!seq || (seq&1) || seq==last) { usleep(100000); continue; }
        if (pread(fd,&desired,4,OFF+0x104)!=4 || pread(fd,&check,4,OFF+0x100)!=4) return 1;
        if (check!=seq || (check&1)) continue;
        if (desired<=1) {
            if (pwrite(fd,&seq,4,OFF+0xc0)!=4) return 1;
            uint32_t decision=0;
            for (unsigned i=0;i<200;i++) {
                if (pread(fd,&decision,4,OFF+0x180)!=4) return 1;
                if (decision==seq || decision==(seq|1u)) break;
                usleep(100000);
            }
            if (decision==seq) status=invoke(desired)?1:3;
        }
        if (pwrite(fd,&status,4,OFF+0x84)!=4 || pwrite(fd,&seq,4,OFF+0x80)!=4) return 1;
        last=seq;
    }
}
