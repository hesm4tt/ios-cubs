#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc,char **argv) {
    if (argc!=2 || (strcmp(argv[1],"on") && strcmp(argv[1],"off"))) return 1;
    const char *marker=getenv("CUBS_POWER_MOCK_MARKER");
    if (marker) { FILE *f=fopen(marker,"w"); if (!f) return 1; fputs(argv[1],f); fclose(f); }
    puts("state-observed"); return 0;
}
