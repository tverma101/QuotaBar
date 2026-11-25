//! Antigravity widget ids and metric labels (Swift `AntigravityMetric`). Both sides of the
//! exact-string label binding come from one place: label drift is a silent "No data" failure.

pub const GEMINI_ID: &str = "antigravity.geminiPro";
pub const GEMINI_WEEKLY_ID: &str = "antigravity.geminiWeekly";
pub const ARGON_WEEKLY_ID: &str = "antigravity.argonWeekly";
pub const CLAUDE_ID: &str = "antigravity.claude";
pub const CLAUDE_WEEKLY_ID: &str = "antigravity.claudeWeekly";

pub const SESSION_LABEL: &str = "Session";
pub const WEEKLY_LABEL: &str = "Weekly";
pub const ARGON_WEEKLY_LABEL: &str = "Argon Weekly";
pub const CLAUDE_LABEL: &str = "Claude";
pub const CLAUDE_WEEKLY_LABEL: &str = "Claude Weekly";

/// Swift `MetricPeriod.sessionMs`.
pub const SESSION_MS: i64 = 5 * 60 * 60 * 1000;
pub use crate::parse::WEEK_MS;
