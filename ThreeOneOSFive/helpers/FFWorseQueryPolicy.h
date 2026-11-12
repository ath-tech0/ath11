#ifndef FF_WORSE_QUERY_POLICY_H
#define FF_WORSE_QUERY_POLICY_H

#include <stdbool.h>
#include <string.h>

// Upstream worse_query plus Erosion's published build list, checked 2026-11-12.
// 27.3 is deliberately restricted to beta 1; a version number alone is insufficient.
static inline bool FFWorseQueryVersionSupported(long major, long minor, long patch,
                                                const char *build) {
    if (minor < 0 || patch < 0) return false;
    if (major == 26) return minor < 7 || (minor == 7 && patch <= 2);
    if (major != 27) return false;
    if (minor < 2) return true;
    if (minor == 2) return patch <= 1;
    return minor == 3 && patch == 0 && build && strcmp(build, "24C5037i") == 0;
}

#endif
