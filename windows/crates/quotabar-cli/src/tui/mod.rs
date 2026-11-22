//! Ratatui dashboard — btop-style QuotaBar TUI.

mod app;
mod picker;
mod platform;
mod state;
pub mod theme;
pub mod view_model;

pub use app::run;
pub use platform::ignore_sigtstp;
