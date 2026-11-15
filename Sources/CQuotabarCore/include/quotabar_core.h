#ifndef QUOTABAR_CORE_H
#define QUOTABAR_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// ABI version of the quotabar-core library. Bump when this layout changes.
uint32_t qb_core_version(void);

/// One parsed Claude usage line. `timestamp` is seconds since the Unix epoch; token buckets
/// mirror `TokenBreakdown` in Swift. Offsets index into the UTF-8 blob returned by
/// `qb_claude_result_strings`; UINT32_MAX means the field is nil.
typedef struct {
    double timestamp;
    double cost_usd;
    uint64_t input_tokens;
    uint64_t cache_write_5m;
    uint64_t cache_write_1h;
    uint64_t cache_read;
    uint64_t output_tokens;
    uint32_t message_id_offset;
    uint32_t message_id_length;
    uint32_t request_id_offset;
    uint32_t request_id_length;
    uint32_t model_offset;
    uint32_t model_length;
    uint8_t is_sidechain;
    uint8_t has_speed;
    uint8_t is_fast;
    uint8_t has_cost_usd;
    uint8_t reserved[4];
} QbClaudeUsageEntry;

#define QB_NIL_STRING_OFFSET UINT32_MAX

/// Parse one Claude usage line. Returns a heap-allocated opaque result, or NULL when the line
/// is legal input this library does not support (e.g. a timestamp shape only Foundation can
/// parse, or more entries than fit the fixed per-line array). NULL is not an error: the caller
/// is expected to fall back to its own implementation.
void *qb_claude_parse_usage_line(const uint8_t *line, size_t line_len);

/// Always 0 (parsed) for a non-NULL result; NULL results signal fallback.
uint32_t qb_claude_result_status(const void *result);
/// Nonzero when Swift's `malformedTokenCounts` semantics apply to this line.
uint32_t qb_claude_result_malformed(const void *result);
uint32_t qb_claude_result_entry_count(const void *result);
/// Pointer to the entry array, valid until qb_claude_result_destroy.
const QbClaudeUsageEntry *qb_claude_result_entries(const void *result);
/// Pointer to the UTF-8 string blob plus its byte length, valid until qb_claude_result_destroy.
const uint8_t *qb_claude_result_strings(const void *result, uint32_t *length);
/// Free a result returned by qb_claude_parse_usage_line. Safe to call with NULL.
void qb_claude_result_destroy(void *result);

#ifdef __cplusplus
}
#endif

#endif /* QUOTABAR_CORE_H */
