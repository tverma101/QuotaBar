// Marker translation unit: makes CQuotabarCore a clang target so SwiftPM compiles and links it.
// All real work lives in Rust/quotabar-core; see docs/rust-core.md.
#include "quotabar_core.h"

uint32_t quotabar_core_link_probe(void) {
    return qb_core_version();
}
