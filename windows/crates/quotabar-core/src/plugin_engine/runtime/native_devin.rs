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
    let display_name = account
        .filter(|account| !account.label.trim().is_empty())
        .map(|account| format!("{} ({})", plugin.manifest.name, account.label.trim()))
        .unwrap_or_else(|| plugin.manifest.name.clone());
    let api_key = account
        .and_then(|account| account.credential.as_ref())
        .and_then(|credential| credential.access_token.as_deref())
        .map(str::trim)
        .filter(|key| !key.is_empty());
    let api_key = if provider_id == plugin.manifest.id {
        api_key
    } else {
        // An unconfigured secondary card must not display the default account's quota.
        Some(api_key.unwrap_or_default())
    };
    let deadline = Instant::now() + timeout;
    let snapshot = provider.refresh_with_api_key(
        &RefreshContext::new(Scope::PanelMeters),
        api_key,
        Some(deadline),
    );
    if Instant::now() >= deadline {
        return probe_fault_output(
            plugin, provider_id, &display_name, format!("probe timed out after {}s", timeout.as_secs()),
        );
    }
    into_output(plugin, provider_id, &display_name, snapshot)
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
    use crate::plugin_engine::manifest::load_plugins_from_dir;
    use crate::provider_accounts::ProviderCredential;
    use quotabar_engine::context::{now_timestamp, CancelToken};
    use quotabar_engine::http::{HttpClient, HttpError, Request, Response};
    use quotabar_engine::model::MetricValue;
    use quotabar_engine::providers::devin::{
        transcripts::DevinTranscriptUsageScanner, DevinAuthStore, NOT_LOGGED_IN,
    };
    use std::path::Path;
    use std::sync::Mutex;

    const USER_STATUS_FIXTURE: &str = r#"{"userStatus":{"planStatus":{"planInfo":{"planName":"Max","billingStrategy":"BILLING_STRATEGY_QUOTA"},"weeklyQuotaRemainingPercent":40,"overageBalanceMicros":"964220000"}}}"#;

    struct FakeHttp {
        requests: Mutex<Vec<Request>>,
    }

    impl HttpClient for FakeHttp {
        fn send(&self, request: &Request, _cancel: &CancelToken) -> Result<Response, HttpError> {
            self.requests.lock().unwrap().push(request.clone());
            Ok(Response { status: 200, headers: Vec::new(), body: USER_STATUS_FIXTURE.as_bytes().to_vec() })
        }
    }

    fn bundled_devin_plugin() -> LoadedPlugin {
        let plugins_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../plugins");
        load_plugins_from_dir(&plugins_dir)
            .into_iter()
            .find(|plugin| plugin.manifest.id == "devin")
            .expect("bundled devin plugin")
    }

    /// A provider whose only credentials are explicit overrides. The transcript scanner is real so a
    /// Full-scope regression would append local metric lines the converter cannot represent.
    fn fixture_provider(http: Arc<dyn HttpClient>, dir: &Path) -> DevinProvider {
        let transcripts = dir.join("transcripts");
        std::fs::create_dir_all(&transcripts).unwrap();
        let ts = quotabar_engine::time::format_iso8601(now_timestamp());
        let transcript = serde_json::json!({
            "schema_version": "ATIF-v1.7",
            "agent": { "model_name": "SWE-2 Max" },
            "steps": [
                { "source": "user", "timestamp": ts },
                { "source": "agent", "timestamp": ts, "model_name": "swe-2-max",
                  "metrics": { "prompt_tokens": 15836, "completion_tokens": 1813, "cached_tokens": 11776 } }
            ]
        });
        std::fs::write(transcripts.join("exported.json"), serde_json::to_vec(&transcript).unwrap()).unwrap();
        DevinProvider::new(DevinAuthStore::new(vec![], vec![]), http).with_local_scanner(
            DevinTranscriptUsageScanner::new(transcripts, None, Some(dir.join("cache"))),
        )
    }

    #[test]
    fn formats_the_balance_as_a_windows_text_tile() {
        let line = EngineLine::values("Extra usage balance", vec![MetricValue::new(964.22, MetricKind::Dollars)]);
        assert!(matches!(convert_line(line), Some(MetricLine::Text { value, .. }) if value == "$964.22"));
    }

    #[test]
    fn matches_the_script_probe_contract_for_instance_accounts() {
        let plugin = bundled_devin_plugin();
        assert!(plugin.manifest.uses_native_devin());
        assert!(plugin.entry_script.is_empty());

        let http = Arc::new(FakeHttp { requests: Mutex::new(Vec::new()) });
        let dir = tempfile::tempdir().unwrap();
        let provider = fixture_provider(http.clone(), dir.path());
        let account = ProviderAccountContext {
            instance_id: "devin:work".into(),
            base_provider_id: "devin".into(),
            label: " Work ".into(),
            credential: Some(ProviderCredential {
                access_token: Some("fake-key".into()),
                ..ProviderCredential::default()
            }),
            store_path: None,
        };

        let output = run_with_provider(&plugin, Some(&account), Duration::from_secs(30), &provider);
        assert_eq!(output.provider_id, "devin:work");
        assert_eq!(output.display_name, "Devin (Work)");
        assert_eq!(output.plan.as_deref(), Some("Max"));
        let weekly = output.lines.iter().find_map(|line| match line {
            MetricLine::Progress { label, used, limit, .. } if label == "Weekly quota" => Some((*used, *limit)),
            _ => None,
        });
        assert_eq!(weekly, Some((60.0, 100.0)));
        let balance = output.lines.iter().find_map(|line| match line {
            MetricLine::Text { label, value, .. } if label == "Extra usage balance" => Some(value.as_str()),
            _ => None,
        });
        assert_eq!(balance, Some("$964.22"));
        {
            let requests = http.requests.lock().unwrap();
            assert_eq!(requests.len(), 1);
            let sent: serde_json::Value = serde_json::from_slice(requests[0].body.as_ref().unwrap()).unwrap();
            assert_eq!(sent["metadata"]["apiKey"], "fake-key");
        }

        // A secondary instance without a credential must not read the machine's Devin login.
        let blank = ProviderAccountContext {
            instance_id: "devin:blank".into(),
            base_provider_id: "devin".into(),
            label: String::new(),
            credential: None,
            store_path: None,
        };
        let output = run_with_provider(&plugin, Some(&blank), Duration::from_secs(30), &provider);
        assert_eq!(output.provider_id, "devin:blank");
        assert_eq!(output.display_name, "Devin");
        assert!(matches!(
            output.lines.as_slice(),
            [MetricLine::Badge { text, .. }] if text == NOT_LOGGED_IN
        ));
        assert_eq!(http.requests.lock().unwrap().len(), 1);
    }
}
