#ifndef CUBS_ABOUT_IDENTITY_H
#define CUBS_ABOUT_IDENTITY_H
#include <string.h>

/* Only presentation queries in Settings. Never change ProductType, UDID,
 * radio identifiers, or the user-assigned device name. */
static const char *cubs_about_identity(const char *key)
{
    if (!key) return 0;
    if (!strcmp(key,"MarketingName") || !strcmp(key,"marketing-name") ||
        !strcmp(key,"aS/S7hCcobxbRgwdTuv4bw") || !strcmp(key,"Z/dqyWS6OZTRy10UcmUAhw")) return "Pixel 11";
    if (!strcmp(key,"ModelNumber") || !strcmp(key,"D0cJ8r7U5zve6uA6QbOiLA")) return "ported by mattv4";
    if (!strcmp(key,"SerialNumber") || !strcmp(key,"VasUgeSzVyHdB27g2XpN0g")) return "hesm4tt/ios-cubs";
    return 0;
}
#endif
