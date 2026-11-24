//! Claude (Swift `Providers/Claude`). Local session-log accounting lives in `logs`; the live-quota
//! runtime (auth stores, usage client, mapper) is ported separately.
//!
//! - `log_parse`: one JSONL line to [`ClaudeEntry`]s, and the [`crate::scan::LineParser`] the shared
//!   incremental scanner drives.
//! - `dedup`, `aggregate`: replay deduplication and per-day pricing.
//! - `roots`, `owned`, `ownership`: where logs live (terminal, Cowork) and which sessions an
//!   account-scoped card owns.
//! - `logs`: the orchestrating [`ClaudeLogScanner`], with the in-memory `fold_cache`.
//! - `gateway`: OpenCode gateway model ids, which the native card skips.

mod aggregate;
mod dedup;
mod entry;
mod fold_cache;
pub mod gateway;
mod log_parse;
mod logs;
mod owned;
mod ownership;
mod roots;
pub mod util;

pub use aggregate::aggregate;
pub use dedup::{dedup, should_replace, ClaudeEntryDeduplication};
pub use entry::ClaudeEntry;
pub use gateway::{is_hosted_gateway_model, is_opencode_go_gateway_model, CLAUDE_GATEWAY_PREFIXES};
pub use log_parse::{is_valid_semver, parse_line, ClaudeLineParser, LineParse};
pub use logs::{ClaudeIncrementalScanner, ClaudeLogConfig, ClaudeLogScanner, ClaudeScanResult, EnvLookup, OwnershipFn};
pub use ownership::{read_ownership_prefix, OwnershipLookup, OwnershipPrefix};
pub use roots::{parse_source_identity, usage_files_if_complete};
pub use util::since_date;

#[cfg(test)]
mod tests;
