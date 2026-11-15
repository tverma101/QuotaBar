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

// ---------------------------------------------------------------------------
// Codex rollout-line parser (port of CodexLogUsageScanner.FileParser)
// ---------------------------------------------------------------------------

/// One emitted Codex event. `model` is the resolved display model (never nil); string offsets
/// index into the blob returned by qb_codex_take_events_strings; UINT32_MAX marks absent
/// optional strings.
typedef struct {
    double timestamp;
    int64_t input_tokens;
    int64_t cached_tokens;
    int64_t output_tokens;
    int64_t reasoning_tokens;
    int64_t total_tokens;
    uint32_t model_offset;
    uint32_t model_length;
    uint32_t pricing_model_offset;
    uint32_t pricing_model_length;
    uint32_t service_tier_offset;
    uint32_t service_tier_length;
    uint8_t has_complete_cost_breakdown;
    uint8_t is_fast;
    uint8_t reserved[6];
} QbCodexEvent;

#define QB_CODEX_FEED_OK 0
/// The line carries a timestamp this library cannot emulate (Foundation could): abandon this
/// parser and re-parse the whole file with the Swift implementation.
#define QB_CODEX_FEED_FALLBACK 1

void *qb_codex_parser_create(uint8_t has_emit_since, double emit_since_seconds);
uint32_t qb_codex_parser_feed_line(void *parser, const uint8_t *line, size_t line_len);
/// Nonzero when Swift's `hasMalformedUsage` semantics apply to at least one line.
uint32_t qb_codex_parser_malformed(const void *parser);
/// Move out the events emitted so far. Call once at the end of a file.
void *qb_codex_parser_take_events(void *parser);
uint32_t qb_codex_take_events_count(const void *result);
const QbCodexEvent *qb_codex_take_events_entries(const void *result);
const uint8_t *qb_codex_take_events_strings(const void *result, uint32_t *length);
void qb_codex_take_events_destroy(void *result);

/// Checkpoint export (one-way read; the parser keeps its state). All `*_offset`/`*_length` pairs
/// reference the blob returned by qb_codex_checkpoint_strings.
void *qb_codex_parser_checkpoint(const void *parser);
uint8_t qb_codex_checkpoint_has_previous_totals(const void *result);
int64_t qb_codex_checkpoint_previous_input(const void *result);
int64_t qb_codex_checkpoint_previous_cached(const void *result);
int64_t qb_codex_checkpoint_previous_output(const void *result);
int64_t qb_codex_checkpoint_previous_reasoning(const void *result);
int64_t qb_codex_checkpoint_previous_total(const void *result);
uint8_t qb_codex_checkpoint_previous_has_reported_total(const void *result);
uint8_t qb_codex_checkpoint_previous_is_valid(const void *result);
uint8_t qb_codex_checkpoint_previous_has_complete_cost_breakdown(const void *result);
uint8_t qb_codex_checkpoint_saw_session_meta(const void *result);
uint8_t qb_codex_checkpoint_current_tier_is_fast(const void *result);
uint8_t qb_codex_checkpoint_current_service_tier_is_valid(const void *result);
/// 0 none, 1 until_started_at, 2 until_self_timed.
uint8_t qb_codex_checkpoint_replay_gate_kind(const void *result);
double qb_codex_checkpoint_replay_gate_started_at(const void *result);
uint32_t qb_codex_checkpoint_current_model_offset(const void *result);
uint32_t qb_codex_checkpoint_current_model_length(const void *result);
uint32_t qb_codex_checkpoint_service_tier_offset(const void *result);
uint32_t qb_codex_checkpoint_service_tier_length(const void *result);
const uint8_t *qb_codex_checkpoint_strings(const void *result, uint32_t *length);
void qb_codex_checkpoint_destroy(void *result);

void qb_codex_parser_destroy(void *parser);

#ifdef __cplusplus
}
#endif

#endif /* QUOTABAR_CORE_H */
