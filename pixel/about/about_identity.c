/* Experimental: inject into Preferences only, not global system services. */
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <stdio.h>
#include "about_identity.h"

extern CFTypeRef MGCopyAnswer(CFStringRef key);
extern CFTypeRef MGCopyAnswerWithError(CFStringRef key, CFDictionaryRef options, int *error);

__attribute__((constructor)) static void about_loaded(void)
{
    fprintf(stderr,"cubs-about: Settings presentation library loaded\n");
}

static CFTypeRef replacement(CFStringRef key)
{
    char name[128];
    if (!key || !CFStringGetCString(key,name,sizeof(name),kCFStringEncodingUTF8)) return NULL;
    const char *value=cubs_about_identity(name);
    if (!value) return NULL;
    /* The key name is from a small allowlist; never print the original value. */
    fprintf(stderr,"cubs-about: matched presentation key\n");
    return CFStringCreateWithCString(kCFAllocatorDefault,value,kCFStringEncodingUTF8);
}
static CFTypeRef my_MGCopyAnswer(CFStringRef key)
{
    CFTypeRef value=replacement(key);
    return value ? value : MGCopyAnswer(key);
}
static CFTypeRef my_MGCopyAnswerWithError(CFStringRef key, CFDictionaryRef options, int *error)
{
    CFTypeRef value=replacement(key);
    if (!value) return MGCopyAnswerWithError(key,options,error);
    if (error) *error=0;
    return value;
}
#define INTERPOSE(new, old) { (const void *)(uintptr_t)(new), (const void *)(uintptr_t)(old) }
__attribute__((used)) static const struct { const void *replacement, *replacee; } interposers[]
    __attribute__((section("__DATA,__interpose"))) = {
    INTERPOSE(my_MGCopyAnswer,MGCopyAnswer),
    INTERPOSE(my_MGCopyAnswerWithError,MGCopyAnswerWithError),
};
