use super::{LoadedPlugin, MetricLine, PluginOutput, ProgressFormat, error_line, probe_fault_output};
use crate::provider_accounts::ProviderAccountContext;
use quotabar_engine::context::{RefreshContext, Scope};
use quotabar_engine::host::{self, Host, LogLevel, SecureReadOutcome, SecureReadRequest};
use quotabar_engine::model::{
    MetricKind, MetricLine as EngineLine, ProgressFormat as EngineProgressFormat, ProviderSnapshot,
};
use quotabar_engine::providers::devin::DevinProvider;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

pub(super) fn run(
    plugin: &LoadedPlugin,
    account: Option<&ProviderAccountContext>,
    timeout: Duration,
) -> PluginOutput {
    static PROVIDER: OnceLock<DevinProvider> = OnceLock::new();
    let provider = PROVIDER.get_or_init(|| {
        host::set_host(Arc::new(DesktopLogHost));
        DevinProvider::live()
    });
    run_with_provider(plugin, account, timeout, provider)
}

fn run_with_provider(
    plugin: &LoadedPlugin,
    account: Option<&ProviderAccountContext>,
    timeout: Duration,
    provider: &DevinProvider,
) -> PluginOutput {
    let provider_id = account.map_or(plugin.manifest.id.as_str(), |account| &account.instance_id);
    let display_name = account.map_or(plugin.manifest.name.as_str(), |account| &account.label);
    let api_key = account
        .and_then(|account| account.credential.as_ref())
        .and_then(|credential| credential.access_token.as_deref());
    let deadline = Instant::now() + timeout;
    let snapshot = provider.refresh_with_api_key(
        &RefreshContext::new(Scope::Full),
        api_key,
        Some(deadline),
    );
    if Instant::now() >= deadline {
        return probe_fault_output(
            plugin, provider_id, display_name, format!("probe timed out after {}s", timeout.as_secs()),
        );
    }
    into_output(plugin, provider_id, display_name, snapshot)
}

fn into_output(
    plugin: &LoadedPlugin,
    provider_id: &str,
    display_name: &str,
    snapshot: ProviderSnapshot,
) -> PluginOutput {
    let lines = snapshot.lines.into_iter().map(convert_line).collect::<Option<Vec<_>>>();
    if let Some(lines) = lines.filter(|lines| !lines.is_empty()) {
        return PluginOutput {
            provider_id: provider_id.to_owned(),
            display_name: display_name.to_owned(),
            plan: snapshot.plan,
            warning: snapshot.warning,
            lines,
            icon_url: plugin.icon_data_url.clone(),
        };
    }
    log::error!("native Devin refresh returned an unsupported metric");
    probe_fault_output(plugin, provider_id, display_name, "Devin quota data unavailable. Try again later.".into())
}

fn convert_line(line: EngineLine) -> Option<MetricLine> {
    match line {
        EngineLine::Progress { label, used, limit, format: EngineProgressFormat::Percent, resets_at, period_duration_ms, color_hex, .. } => {
            Some(MetricLine::Progress {
                label, used, limit,
                format: ProgressFormat::Percent,
                resets_at: resets_at.map(quotabar_engine::time::format_iso8601),
                period_duration_ms: period_duration_ms.and_then(|value| u64::try_from(value).ok()),
                color: color_hex,
                session_start_signal: None,
            })
        }
        EngineLine::Values { label, values, color_hex, .. }
            if values.len() == 1 && values[0].kind == MetricKind::Dollars =>
        {
            Some(MetricLine::Text {
                label,
                value: format!("${:.2}", values[0].number),
                color: color_hex,
                subtitle: None,
                model_breakdown: None,
                status_dot: None,
                expiry_tooltip: None,
                reset_credit_expiries: None,
            })
        }
        EngineLine::Badge { label, text, .. } if label == EngineLine::ERROR_BADGE_LABEL => {
            Some(error_line(text))
        }
        _ => None,
    }
}

struct DesktopLogHost;

impl Host for DesktopLogHost {
    fn log(&self, level: LogLevel, tag: &str, message: &str) {
        let level = match level {
            LogLevel::Error => log::Level::Error,
            LogLevel::Warn => log::Level::Warn,
            LogLevel::Info => log::Level::Info,
            LogLevel::Debug => log::Level::Debug,
        };
        log::log!(target: tag, level, "{message}");
    }

    fn log_level(&self) -> LogLevel {
        match log::max_level() {
            log::LevelFilter::Trace | log::LevelFilter::Debug => LogLevel::Debug,
            log::LevelFilter::Info => LogLevel::Info,
            log::LevelFilter::Warn => LogLevel::Warn,
            _ => LogLevel::Error,
        }
    }

    fn secure_read(&self, _: &SecureReadRequest) -> SecureReadOutcome {
        SecureReadOutcome::Failed { message: "The desktop credential store is unavailable to the engine.".into() }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use quotabar_engine::model::MetricValue;

    #[test]
    fn formats_the_balance_as_a_windows_text_tile() {
        let line = EngineLine::values("Extra usage balance", vec![MetricValue::new(964.22, MetricKind::Dollars)]);
        assert!(matches!(convert_line(line), Some(MetricLine::Text { value, .. }) if value == "$964.22"));
    }
}
