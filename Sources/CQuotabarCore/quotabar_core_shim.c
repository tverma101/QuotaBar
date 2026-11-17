// Marker translation unit: makes CQuotabarCore a clang target so SwiftPM compiles and links it.
// All real work lives in Rust/quotabar-core; see docs/rust-core.md.
#include "quotabar_core.h"
#include <string.h>

uint32_t quotabar_core_link_probe(void) {
    return qb_core_version();
}

intptr_t qb_find_byte(const uint8_t *haystack, size_t length, uint8_t byte, size_t start) {
    if (haystack == NULL || start >= length) {
        return -1;
    }
    const void *found = memchr(haystack + start, (int)byte, length - start);
    return found != NULL
        ? (intptr_t)((const uint8_t *)found - haystack)
        : -1;
}
