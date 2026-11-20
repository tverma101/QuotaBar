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

/// Per-chunk cancellation hook passed to the whole-file parsers. Return nonzero to abort the
/// scan; NULL means never cancel. Typically `Task.isCancelled` on the calling side.
typedef uint8_t (*qb_cancel_callback)(void *ctx);

/// Whole-file status codes shared by the `qb_*_parse_file` family.
#define QB_FILE_OK 0u       /* entries valid */
#define QB_FILE_FALLBACK 1u /* legal Swift input this library declines — re-parse in Swift */
#define QB_FILE_FAILED 2u   /* unreadable/cancelled/oversized/malformed — caller returns nil */

/// One parsed Grok `updates.jsonl` usage entry. `timestamp` is seconds since the Unix epoch.
/// Offsets index into the UTF-8 blob returned by `qb_grok_*_result_strings`; UINT32_MAX = nil.
typedef struct {
    double timestamp;
    double carried_cost;      /* valid only when has_carried_cost != 0 */
    uint64_t input_tokens;
    uint64_t cache_write_5m;
    uint64_t cache_read;
    uint64_t output_tokens;
    uint32_t event_id_offset;
    uint32_t event_id_length;
    uint32_t model_offset;    /* never nil in this format */
    uint32_t model_length;
    uint8_t has_carried_cost;
    uint8_t reserved[7];
} QbGrokEntry;

/// Parse one Grok usage line. NULL = fall back to the Swift reference implementation.
void *qb_grok_parse_line(const uint8_t *line, size_t line_len);
uint32_t qb_grok_line_result_malformed(const void *result);
uint32_t qb_grok_line_result_irrelevant(const void *result);
uint32_t qb_grok_line_result_entry_count(const void *result);
const QbGrokEntry *qb_grok_line_result_entries(const void *result);
const uint8_t *qb_grok_line_result_strings(const void *result, uint32_t *length);
void qb_grok_line_result_destroy(void *result);

/// Parse one Grok `updates.jsonl` file end to end: the Rust side streams, splits, and parses
/// every line without materializing Foundation objects. `end_offset` of UINT64_MAX reads to
/// EOF. NULL result is treated like QB_FILE_FALLBACK.
void *qb_grok_parse_file(const uint8_t *path, size_t path_len,
                         uint64_t start_offset, uint64_t end_offset,
                         qb_cancel_callback cancel, void *cancel_ctx);
uint32_t qb_grok_file_result_status(const void *result);
uint32_t qb_grok_file_result_entry_count(const void *result);
const QbGrokEntry *qb_grok_file_result_entries(const void *result);
const uint8_t *qb_grok_file_result_strings(const void *result, uint32_t *length);
uint64_t qb_grok_file_result_bytes_read(const void *result);
uint64_t qb_grok_file_result_oversized_lines(const void *result);
void qb_grok_file_result_destroy(void *result);

/// One parsed Muse `session.jsonl` usage entry (`goal_usage_attribution` with `reported:true`,
/// `unit:"tokens"`). `timestamp` is seconds since the Unix epoch (`recorded_at` is microseconds
/// in the log). `input_tokens` is the uncached portion; `cache_read` is the prefix-hit portion.
/// Offsets index into the UTF-8 blob returned by `qb_muse_*_result_strings`.
typedef struct {
    double timestamp;
    uint64_t input_tokens;
    uint64_t cache_read;
    uint64_t output_tokens;
    uint32_t model_offset;    /* never nil in this format */
    uint32_t model_length;
} QbMuseEntry;

/// Parse one Muse usage line. NULL = fall back to the Swift reference implementation.
void *qb_muse_parse_line(const uint8_t *line, size_t line_len);
uint32_t qb_muse_line_result_malformed(const void *result);
uint32_t qb_muse_line_result_irrelevant(const void *result);
uint32_t qb_muse_line_result_entry_count(const void *result);
const QbMuseEntry *qb_muse_line_result_entries(const void *result);
const uint8_t *qb_muse_line_result_strings(const void *result, uint32_t *length);
void qb_muse_line_result_destroy(void *result);

/// Parse one Muse `session.jsonl` file end to end: the Rust side streams, splits, and parses
/// every line without materializing Foundation objects. `end_offset` of UINT64_MAX reads to
/// EOF. NULL result is treated like QB_FILE_FALLBACK.
void *qb_muse_parse_file(const uint8_t *path, size_t path_len,
                         uint64_t start_offset, uint64_t end_offset,
                         qb_cancel_callback cancel, void *cancel_ctx);
uint32_t qb_muse_file_result_status(const void *result);
uint32_t qb_muse_file_result_entry_count(const void *result);
const QbMuseEntry *qb_muse_file_result_entries(const void *result);
const uint8_t *qb_muse_file_result_strings(const void *result, uint32_t *length);
uint64_t qb_muse_file_result_bytes_read(const void *result);
uint64_t qb_muse_file_result_oversized_lines(const void *result);
void qb_muse_file_result_destroy(void *result);

/// One parsed Pi session usage entry (a `type == "message"` assistant row). `timestamp` is
/// seconds since the Unix epoch. Offsets index into the UTF-8 blob returned by
/// `qb_pi_*_result_strings`; UINT32_MAX = nil. `card_id`/`model` are never nil.
typedef struct {
    double timestamp;
    double carried_cost;      /* valid only when has_carried_cost != 0 */
    uint64_t input_tokens;
    uint64_t cache_write_5m;
    uint64_t cache_write_1h;
    uint64_t cache_read;
    uint64_t output_tokens;
    uint64_t reported_total_tokens;  /* pi's own usage.totalTokens, carried verbatim */
    uint32_t id_offset;
    uint32_t id_length;
    uint32_t card_id_offset;  /* never nil in this format */
    uint32_t card_id_length;
    uint32_t model_offset;    /* never nil; may be empty */
    uint32_t model_length;
    uint8_t has_carried_cost;
    uint8_t reserved[7];
} QbPiEntry;

/// Parse one Pi usage line. NULL = fall back to the Swift reference implementation.
void *qb_pi_parse_line(const uint8_t *line, size_t line_len);
uint32_t qb_pi_line_result_malformed(const void *result);
uint32_t qb_pi_line_result_irrelevant(const void *result);
uint32_t qb_pi_line_result_entry_count(const void *result);
const QbPiEntry *qb_pi_line_result_entries(const void *result);
const uint8_t *qb_pi_line_result_strings(const void *result, uint32_t *length);
void qb_pi_line_result_destroy(void *result);

/// Parse one Pi session `.jsonl` file end to end: the Rust side streams, splits, and parses
/// every line without materializing Foundation objects. `end_offset` of UINT64_MAX reads to
/// EOF. NULL result is treated like QB_FILE_FALLBACK.
void *qb_pi_parse_file(const uint8_t *path, size_t path_len,
                       uint64_t start_offset, uint64_t end_offset,
                       qb_cancel_callback cancel, void *cancel_ctx);
uint32_t qb_pi_file_result_status(const void *result);
uint32_t qb_pi_file_result_entry_count(const void *result);
const QbPiEntry *qb_pi_file_result_entries(const void *result);
const uint8_t *qb_pi_file_result_strings(const void *result, uint32_t *length);
uint64_t qb_pi_file_result_bytes_read(const void *result);
uint64_t qb_pi_file_result_oversized_lines(const void *result);
void qb_pi_file_result_destroy(void *result);

// ---------------------------------------------------------------------------
// CodexRouter event-line parser (port of CodexRouterEventLineParser)
// ---------------------------------------------------------------------------

/// One parsed CodexRouter `Event` — mirrors `CodexRouterUsageScanner.Event`. `timestamp`
/// is seconds since the Unix epoch (`Date.distantPast`, -62135769600, when the `at` field
/// is missing or unparseable, matching the Swift malformed-event payload). String offsets
/// index into the UTF-8 blob returned by `qb_codex_router_*_result_strings`; UINT32_MAX
/// marks an absent optional string (`service_tier`, `account_id`, `account_fingerprint` —
/// `model`/`provider` are never nil: "Unattributed"/"unknown"). `total_tokens` is valid
/// only when `has_total_tokens != 0`. The four optional-Bool flags are tri-state:
/// 0 = nil, 1 = false, 2 = true.
typedef struct {
    double timestamp;
    int64_t status;
    int64_t input_tokens;
    int64_t cached_input_tokens;
    int64_t output_tokens;
    int64_t reasoning_tokens;
    int64_t total_tokens;
    uint32_t model_offset;
    uint32_t model_length;
    uint32_t provider_offset;
    uint32_t provider_length;
    uint32_t service_tier_offset;
    uint32_t service_tier_length;
    uint32_t account_id_offset;
    uint32_t account_id_length;
    uint32_t account_fingerprint_offset;
    uint32_t account_fingerprint_length;
    uint8_t has_valid_status_field;
    uint8_t has_valid_timestamp_field;
    uint8_t has_valid_model_field;
    uint8_t has_unique_status_field;
    uint8_t has_unique_provider_field;
    uint8_t has_unique_model_field;
    uint8_t has_unique_account_identity_fields;
    uint8_t has_valid_numeric_count_fields;
    uint8_t has_unique_recognized_fields;
    uint8_t has_total_tokens;
    uint8_t has_input_tokens_field;
    uint8_t has_output_tokens_field;
    uint8_t has_valid_cached_input_tokens_field;
    uint8_t has_valid_total_tokens_field;
    uint8_t has_valid_estimated_input_tokens_field;
    uint8_t has_valid_account_identity_fields;
    uint8_t has_estimated_input_tokens;      /* tri-state: 0 nil, 1 false, 2 true */
    uint8_t has_valid_provider_field;        /* tri-state */
    uint8_t has_valid_service_tier_field;    /* tri-state */
    uint8_t token_count_saturated;           /* tri-state */
    uint8_t reserved[4];
} QbCodexRouterEvent;

/* qb_codex_router_line_result_verdict values — mirror `LineResult`. */
#define QB_ROUTER_LINE_EVENT 0u
#define QB_ROUTER_LINE_MALFORMED_EVENT 1u
#define QB_ROUTER_LINE_IRRELEVANT 2u
#define QB_ROUTER_LINE_MALFORMED 3u

/// Parse one CodexRouter ledger line with the byte-level structural walker. NULL = the
/// line is legal Swift input this library declines (a non-canonical `at` timestamp
/// string) — the caller re-runs its own parser, never a different answer.
void *qb_codex_router_parse_line(const uint8_t *line, size_t line_len);
/// One of QB_ROUTER_LINE_*. The IRRELEVANT verdict may still carry one entry — the
/// produced event for a non-2xx short circuit, which Swift's `parse` returns.
uint32_t qb_codex_router_line_result_verdict(const void *result);
uint32_t qb_codex_router_line_result_entry_count(const void *result);
const QbCodexRouterEvent *qb_codex_router_line_result_entries(const void *result);
const uint8_t *qb_codex_router_line_result_strings(const void *result, uint32_t *length);
void qb_codex_router_line_result_destroy(void *result);

/// Parse one CodexRouter ledger file end to end: the Rust side streams, splits, and
/// parses every line — including a trailing `}`-terminated object without a newline —
/// without materializing Foundation objects. `end_offset` of UINT64_MAX reads to EOF.
/// NULL result is treated like QB_FILE_FALLBACK. A FALLBACK or FAILED result carries no
/// entries: engines never mix within one file.
void *qb_codex_router_parse_file(const uint8_t *path, size_t path_len,
                                 uint64_t start_offset, uint64_t end_offset,
                                 qb_cancel_callback cancel, void *cancel_ctx);
uint32_t qb_codex_router_file_result_status(const void *result);
uint32_t qb_codex_router_file_result_entry_count(const void *result);
const QbCodexRouterEvent *qb_codex_router_file_result_entries(const void *result);
const uint8_t *qb_codex_router_file_result_strings(const void *result, uint32_t *length);
uint64_t qb_codex_router_file_result_bytes_read(const void *result);
uint64_t qb_codex_router_file_result_oversized_lines(const void *result);
/// The trailing newline-less fragment retained for the append-resume checkpoint —
/// `JSONLFileReader.ReadResult.finalPartial`. NULL + length 0 when a `}`-terminated tail
/// was consumed or no fragment exists.
const uint8_t *qb_codex_router_file_result_partial_line(const void *result,
                                                        uint32_t *length);
uint8_t qb_codex_router_file_result_is_discarding_oversized_line(const void *result);
void qb_codex_router_file_result_destroy(void *result);

// ---------------------------------------------------------------------------
// Antigravity protobuf blob decoder (port of AntigravityProtoDecoder)
// ---------------------------------------------------------------------------

/// One decoded Antigravity generation event. `timestamp_seconds` is seconds since the Unix
/// epoch; `input_tokens` is billable input (system-prompt + input counts). `model_*` offsets
/// index into the UTF-8 blob returned by qb_antigravity_generation_strings — always valid:
/// the decoder substitutes the "Unknown Antigravity Model" placeholder before emitting.
typedef struct {
    int64_t timestamp_seconds;
    uint64_t input_tokens;
    uint64_t output_tokens;
    uint64_t cache_read_tokens;
    uint32_t model_offset;
    uint32_t model_length;
    uint8_t reserved[8];
} QbAntigravityGenerationEvent;

/// uuid/bot identifiers extracted from a generation or steps.metadata row — the key the step
/// timestamp index uses. UINT32_MAX offsets = nil. `timestamp_seconds`/`has_timestamp` are
/// populated only by qb_antigravity_step_metadata_identity.
typedef struct {
    int64_t timestamp_seconds;
    uint32_t uuid_offset;
    uint32_t uuid_length;
    uint32_t bot_id_offset;
    uint32_t bot_id_length;
    uint8_t has_timestamp;
    uint8_t reserved[7];
} QbAntigravityStepIdentity;

/* qb_antigravity_generation_status values — mirror GenerationEventDecodeResult. */
#define QB_ANTIGRAVITY_EVENT 0u
#define QB_ANTIGRAVITY_IGNORED 1u
#define QB_ANTIGRAVITY_UNDATED_USAGE 2u
#define QB_ANTIGRAVITY_INVALID_TOKEN_COUNT 3u
#define QB_ANTIGRAVITY_MALFORMED_USAGE 4u
/* Generation hex is undecodable — the row takes the caller's oversized/unreadable path. */
#define QB_ANTIGRAVITY_UNREADABLE_HEX 5u
/* NULL result / accessor fallback — never stored in a result. */
#define QB_ANTIGRAVITY_FALLBACK 6u

#define QB_ANTIGRAVITY_IDENTITY_PRESENT 0u
#define QB_ANTIGRAVITY_IDENTITY_ABSENT 1u

/// Decode one generation row: `generation_hex` is the `hex(gen_metadata.data)` text,
/// `step_hex` the same-index `hex(steps.metadata)` text (NULL when absent), and
/// `matched_step_timestamp` the step-index-correlated timestamp when
/// `has_matched_step_timestamp` is nonzero. NULL result = fall back to the Swift decoder
/// (non-ASCII hex input or identifier strings whose canonical equivalence is undecidable);
/// QB_ANTIGRAVITY_UNREADABLE_HEX = hex provably fails the way bytes(fromHex:) returns nil.
void *qb_antigravity_decode_generation(const uint8_t *generation_hex, size_t generation_hex_len,
                                       const uint8_t *step_hex, size_t step_hex_len,
                                       int64_t matched_step_timestamp,
                                       uint8_t has_matched_step_timestamp);
/// Raw-bytes variant for the bounded accounting projection of oversized blobs.
void *qb_antigravity_decode_generation_blob(const uint8_t *generation, size_t generation_len,
                                            const uint8_t *step_hex, size_t step_hex_len,
                                            int64_t matched_step_timestamp,
                                            uint8_t has_matched_step_timestamp);
uint32_t qb_antigravity_generation_status(const void *result);
uint8_t qb_antigravity_generation_has_timestamp(const void *result);
int64_t qb_antigravity_generation_timestamp(const void *result);
const QbAntigravityGenerationEvent *qb_antigravity_generation_event(const void *result);
const uint8_t *qb_antigravity_generation_strings(const void *result, uint32_t *length);
void qb_antigravity_generation_destroy(void *result);

/// Extract a generation's step identity (uuid + bot identifier) — the step timestamp index
/// key. NULL = fall back to the Swift extraction.
void *qb_antigravity_generation_step_identity(const uint8_t *generation_hex, size_t generation_hex_len);
void *qb_antigravity_generation_step_identity_blob(const uint8_t *generation, size_t generation_len);
/// Extract a steps.metadata row's identity plus wall-clock timestamp — the pair
/// stepIdentityAndTimestamp(from:) produces for the step index's insert.
void *qb_antigravity_step_metadata_identity(const uint8_t *metadata_hex, size_t metadata_hex_len);
uint32_t qb_antigravity_identity_status(const void *result);
const QbAntigravityStepIdentity *qb_antigravity_identity(const void *result);
const uint8_t *qb_antigravity_identity_strings(const void *result, uint32_t *length);
void qb_antigravity_identity_destroy(void *result);

// ---------------------------------------------------------------------------
// Whole-file parsers
// ---------------------------------------------------------------------------

/// Parse one Claude session `.jsonl` file end to end: the Rust side streams, splits, and parses
/// every line without materializing Foundation objects. `end_offset` of UINT64_MAX reads to EOF.
/// NULL result is treated like QB_FILE_FALLBACK. The file-level `malformed` flag is the OR of
/// every line's malformedTokenCounts signal — the same condition under which the Swift
/// parseFile(at:) returns nil (QB_FILE_FAILED).
void *qb_claude_parse_file(const uint8_t *path, size_t path_len,
                           uint64_t start_offset, uint64_t end_offset,
                           qb_cancel_callback cancel, void *cancel_ctx);
uint32_t qb_claude_file_result_status(const void *result);
uint32_t qb_claude_file_result_malformed(const void *result);
uint32_t qb_claude_file_result_entry_count(const void *result);
const QbClaudeUsageEntry *qb_claude_file_result_entries(const void *result);
const uint8_t *qb_claude_file_result_strings(const void *result, uint32_t *length);
uint64_t qb_claude_file_result_bytes_read(const void *result);
uint64_t qb_claude_file_result_oversized_lines(const void *result);
void qb_claude_file_result_destroy(void *result);

/// Parse one Codex rollout `.jsonl` file end to end: streams, splits, and feeds every line to the
/// stateful parser, then packages the emitted events plus the tail-cache checkpoint projection
/// into one result. `end_offset` of UINT64_MAX reads to EOF. NULL result is treated like
/// QB_FILE_FALLBACK. `partial_line` carries the undelivered trailing fragment
/// (ReadResult.finalPartial) so the caller can rebuild its append-resume checkpoint.
void *qb_codex_parse_file(const uint8_t *path, size_t path_len,
                          uint8_t has_emit_since, double emit_since_seconds,
                          uint64_t start_offset, uint64_t end_offset,
                          qb_cancel_callback cancel, void *cancel_ctx);
uint32_t qb_codex_file_result_status(const void *result);
uint32_t qb_codex_file_result_has_malformed_usage(const void *result);
uint32_t qb_codex_file_result_event_count(const void *result);
const QbCodexEvent *qb_codex_file_result_events(const void *result);
const uint8_t *qb_codex_file_result_strings(const void *result, uint32_t *length);
uint8_t qb_codex_file_result_has_previous_totals(const void *result);
int64_t qb_codex_file_result_previous_input(const void *result);
int64_t qb_codex_file_result_previous_cached(const void *result);
int64_t qb_codex_file_result_previous_output(const void *result);
int64_t qb_codex_file_result_previous_reasoning(const void *result);
int64_t qb_codex_file_result_previous_total(const void *result);
uint8_t qb_codex_file_result_previous_has_reported_total(const void *result);
uint8_t qb_codex_file_result_previous_is_valid(const void *result);
uint8_t qb_codex_file_result_previous_has_complete_cost_breakdown(const void *result);
uint8_t qb_codex_file_result_saw_session_meta(const void *result);
uint8_t qb_codex_file_result_current_tier_is_fast(const void *result);
uint8_t qb_codex_file_result_current_service_tier_is_valid(const void *result);
uint8_t qb_codex_file_result_replay_gate_kind(const void *result);
double qb_codex_file_result_replay_gate_started_at(const void *result);
uint32_t qb_codex_file_result_current_model_offset(const void *result);
uint32_t qb_codex_file_result_current_model_length(const void *result);
uint32_t qb_codex_file_result_service_tier_offset(const void *result);
uint32_t qb_codex_file_result_service_tier_length(const void *result);
uint64_t qb_codex_file_result_bytes_read(const void *result);
uint64_t qb_codex_file_result_oversized_lines(const void *result);
const uint8_t *qb_codex_file_result_partial_line(const void *result, uint32_t *length);
uint8_t qb_codex_file_result_is_discarding_oversized_line(const void *result);
void qb_codex_file_result_destroy(void *result);

/// Rust pricing catalog parser — parses the compact pricing catalog JSON.
/// Field order must match `Rust/quotabar-core/src/pricing.rs` exactly.
typedef struct {
    uint32_t key_offset, key_length;    /* offsets into the strings blob */
    double input_per_million;
    double output_per_million;
    double cache_write_per_million;
    double cache_read_per_million;
    double cache_write_1h_per_million;  /* NaN when absent */
    double input_above_200k_per_million;     /* NaN when absent */
    double output_above_200k_per_million;    /* NaN when absent */
    double cache_write_above_200k_per_million; /* NaN when absent */
    double cache_read_above_200k_per_million;  /* NaN when absent */
    uint8_t cache_read_is_explicit;
    double fast_multiplier;
    uint8_t tier_count;
    uint32_t tier_offset;               /* index into the tier array */
} QbCompactEntry;

typedef struct {
    uint64_t threshold_prompt_tokens;
    uint8_t includes_threshold;          /* 1 = threshold is inclusive (>=); 0 = strictly above */
    double input_per_million;            /* NaN when untouched */
    double output_per_million;
    double cache_write_per_million;
    double cache_read_per_million;
    double cache_write_1h_per_million;
} QbCompactTier;

void *qb_pricing_compact_catalog_parse(const uint8_t *data, size_t length);
uint32_t qb_pricing_compact_catalog_entry_count(const void *result);
const QbCompactEntry *qb_pricing_compact_catalog_entries(const void *result);
uint32_t qb_pricing_compact_catalog_tier_count(const void *result);
const QbCompactTier *qb_pricing_compact_catalog_tiers(const void *result);
uint32_t qb_pricing_compact_catalog_retrieved_at_offset(const void *result);
uint32_t qb_pricing_compact_catalog_retrieved_at_length(const void *result);
uint32_t qb_pricing_compact_catalog_retired_count(const void *result);
uint32_t qb_pricing_compact_catalog_retired_offset(const void *result);
const uint8_t *qb_pricing_compact_catalog_strings(const void *result, uint32_t *length);
uint8_t qb_pricing_compact_catalog_retired_present(const void *result);
void qb_pricing_compact_catalog_destroy(void *result);


#ifdef __cplusplus
}
#endif

#ifdef __cplusplus
static_assert(sizeof(QbCompactTier) == 56, "QbCompactTier layout drifted");
static_assert(sizeof(QbCompactEntry) == 104, "QbCompactEntry layout drifted");
static_assert(sizeof(QbClaudeUsageEntry) == 88, "QbClaudeUsageEntry layout drifted");
static_assert(sizeof(QbCodexEvent) == 80, "QbCodexEvent layout drifted");
static_assert(sizeof(QbGrokEntry) == 72, "QbGrokEntry layout drifted");
static_assert(sizeof(QbMuseEntry) == 40, "QbMuseEntry layout drifted");
static_assert(sizeof(QbPiEntry) == 96, "QbPiEntry layout drifted");
static_assert(sizeof(QbCodexRouterEvent) == 120, "QbCodexRouterEvent layout drifted");
static_assert(sizeof(QbAntigravityGenerationEvent) == 48, "QbAntigravityGenerationEvent layout drifted");
static_assert(sizeof(QbAntigravityStepIdentity) == 32, "QbAntigravityStepIdentity layout drifted");
static_assert(alignof(QbCompactTier) == 8, "QbCompactTier alignment drifted");
static_assert(alignof(QbCompactEntry) == 8, "QbCompactEntry alignment drifted");
static_assert(alignof(QbClaudeUsageEntry) == 8, "QbClaudeUsageEntry alignment drifted");
static_assert(alignof(QbCodexEvent) == 8, "QbCodexEvent alignment drifted");
static_assert(alignof(QbGrokEntry) == 8, "QbGrokEntry alignment drifted");
static_assert(alignof(QbMuseEntry) == 8, "QbMuseEntry alignment drifted");
static_assert(alignof(QbPiEntry) == 8, "QbPiEntry alignment drifted");
static_assert(alignof(QbCodexRouterEvent) == 8, "QbCodexRouterEvent alignment drifted");
static_assert(alignof(QbAntigravityGenerationEvent) == 8, "QbAntigravityGenerationEvent alignment drifted");
static_assert(alignof(QbAntigravityStepIdentity) == 8, "QbAntigravityStepIdentity alignment drifted");
#else
_Static_assert(sizeof(QbCompactTier) == 56, "QbCompactTier layout drifted");
_Static_assert(sizeof(QbCompactEntry) == 104, "QbCompactEntry layout drifted");
_Static_assert(sizeof(QbClaudeUsageEntry) == 88, "QbClaudeUsageEntry layout drifted");
_Static_assert(sizeof(QbCodexEvent) == 80, "QbCodexEvent layout drifted");
_Static_assert(sizeof(QbGrokEntry) == 72, "QbGrokEntry layout drifted");
_Static_assert(sizeof(QbMuseEntry) == 40, "QbMuseEntry layout drifted");
_Static_assert(sizeof(QbPiEntry) == 96, "QbPiEntry layout drifted");
_Static_assert(sizeof(QbCodexRouterEvent) == 120, "QbCodexRouterEvent layout drifted");
_Static_assert(sizeof(QbAntigravityGenerationEvent) == 48, "QbAntigravityGenerationEvent layout drifted");
_Static_assert(sizeof(QbAntigravityStepIdentity) == 32, "QbAntigravityStepIdentity layout drifted");
_Static_assert(_Alignof(QbCompactTier) == 8, "QbCompactTier alignment drifted");
_Static_assert(_Alignof(QbCompactEntry) == 8, "QbCompactEntry alignment drifted");
_Static_assert(_Alignof(QbClaudeUsageEntry) == 8, "QbClaudeUsageEntry alignment drifted");
_Static_assert(_Alignof(QbCodexEvent) == 8, "QbCodexEvent alignment drifted");
_Static_assert(_Alignof(QbGrokEntry) == 8, "QbGrokEntry alignment drifted");
_Static_assert(_Alignof(QbMuseEntry) == 8, "QbMuseEntry alignment drifted");
_Static_assert(_Alignof(QbPiEntry) == 8, "QbPiEntry alignment drifted");
_Static_assert(_Alignof(QbCodexRouterEvent) == 8, "QbCodexRouterEvent alignment drifted");
_Static_assert(_Alignof(QbAntigravityGenerationEvent) == 8, "QbAntigravityGenerationEvent alignment drifted");
_Static_assert(_Alignof(QbAntigravityStepIdentity) == 8, "QbAntigravityStepIdentity alignment drifted");
#endif

#endif /* QUOTABAR_CORE_H */
