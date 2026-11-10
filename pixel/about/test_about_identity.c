#include <assert.h>
#include <stdio.h>
#include "about_identity.h"
int main(void) {
    assert(!strcmp(cubs_about_identity("MarketingName"),"Pixel 11"));
    assert(!strcmp(cubs_about_identity("Z/dqyWS6OZTRy10UcmUAhw"),"Pixel 11"));
    assert(!strcmp(cubs_about_identity("D0cJ8r7U5zve6uA6QbOiLA"),"ported by mattv4"));
    assert(!strcmp(cubs_about_identity("VasUgeSzVyHdB27g2XpN0g"),"hesm4tt/ios-cubs"));
    assert(!cubs_about_identity("DeviceName") && !cubs_about_identity("ProductType") && !cubs_about_identity(NULL));
    puts("About presentation mapping passed");
    return 0;
}
