use crate::plugin_engine::host_api;
use crate::plugin_engine::manifest::LoadedPlugin;
use crate::provider_accounts::{self, ProviderAccountContext};
use rquickjs::{Array, Context, Ctx, Error, Object, Promise, Runtime, Value};
use serde::{Deserialize, Serialize};
use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;
use std::time::{Duration, Instant};

const PROBE_TIMEOUT_SECS: u64 = 30;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ProgressFormat {
    Percent,
    Dollars,
    Count { suffix: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BarChartPoint {
    label: String,
    value: f64,
    #[serde(rename = "valueLabel")]
    value_label: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelSpendBreakdown {
    pub model: String,
    pub tokens: u64,
    pub cost_usd: Option<f64>,
    pub percent: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum MetricLine {
    Text {
        label: String,
        value: String,
        color: Option<String>,
        subtitle: Option<String>,
        model_breakdown: Option<Vec<ModelSpendBreakdown>>,
        status_dot: Option<String>,
        expiry_tooltip: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reset_credit_expiries: Option<Vec<String>>,
    },
    Progress {
        label: String,
        used: f64,
        limit: f64,
        format: ProgressFormat,
        #[serde(rename = "resetsAt")]
        resets_at: Option<String>,
        #[serde(rename = "periodDurationMs")]
        period_duration_ms: Option<u64>,
        color: Option<String>,
        /// Claude Session: `missingResetDate` — a reset time means the window started (0% is still in-flight).
        #[serde(default, rename = "sessionStartSignal", skip_serializing_if = "Option::is_none")]
        session_start_signal: Option<String>,
    },
    Badge {
        label: String,
        text: String,
        color: Option<String>,
        subtitle: Option<String>,
    },
    #[serde(rename = "barChart")]
    BarChart {
        label: String,
        points: Vec<BarChartPoint>,
        note: Option<String>,
        color: Option<String>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginOutput {
    pub provider_id: String,
    pub display_name: String,
    pub plan: Option<String>,
    #[serde(default)]
    pub warning: Option<String>,
    pub lines: Vec<MetricLine>,
    pub icon_url: String,
}

pub fn run_probe(plugin: &LoadedPlugin, app_data_dir: &PathBuf, app_version: &str) -> PluginOutput {
    run_probe_with_account(plugin, app_data_dir, app_version, None)
}

pub fn run_probe_with_account(
    plugin: &LoadedPlugin,
    app_data_dir: &PathBuf,
    app_version: &str,
    account: Option<ProviderAccountContext>,
) -> PluginOutput {
    run_probe_with_history(plugin, app_data_dir, app_version, account, false)
}

pub fn run_probe_with_history(
    plugin: &LoadedPlugin,
    app_data_dir: &PathBuf,
    app_version: &str,
    account: Option<ProviderAccountContext>,
    refresh_history: bool,
) -> PluginOutput {
    run_probe_with_account_timeout(
        plugin,
        app_data_dir,
        app_version,
        account,
        Duration::from_secs(PROBE_TIMEOUT_SECS),
        refresh_history,
        None,
        None,
    )
}

pub fn run_probe_in_batch(
    plugin: &LoadedPlugin,
    app_data_dir: &PathBuf,
    app_version: &str,
    account: Option<ProviderAccountContext>,
    opencode_go_batch: Option<Arc<host_api::OpenCodeGoProbeBatch>>,
) -> PluginOutput {
    run_probe_with_account_timeout(
        plugin,
        app_data_dir,
        app_version,
        account,
        Duration::from_secs(PROBE_TIMEOUT_SECS),
        false,
        None,
        opencode_go_batch,
    )
}

pub fn run_probe_with_deferred_usage(
    plugin: &LoadedPlugin,
    app_data_dir: &PathBuf,
    app_version: &str,
    account: ProviderAccountContext,
) -> (PluginOutput, Vec<String>) {
    run_probe_with_deferred_usage_and_history(plugin, app_data_dir, app_version, account, false)
}

pub fn run_probe_with_deferred_usage_and_history(
    plugin: &LoadedPlugin,
    app_data_dir: &PathBuf,
    app_version: &str,
    account: ProviderAccountContext,
    refresh_history: bool,
) -> (PluginOutput, Vec<String>) {
    run_probe_with_deferred_usage_history_and_batch(
        plugin,
        app_data_dir,
        app_version,
        account,
        refresh_history,
        None,
    )
}

pub fn run_probe_with_deferred_usage_history_and_batch(
    plugin: &LoadedPlugin,
    app_data_dir: &PathBuf,
    app_version: &str,
    account: ProviderAccountContext,
    refresh_history: bool,
    opencode_go_batch: Option<Arc<host_api::OpenCodeGoProbeBatch>>,
) -> (PluginOutput, Vec<String>) {
    let usage = Rc::new(RefCell::new(Vec::new()));
    let output = run_probe_with_account_timeout(
        plugin,
        app_data_dir,
        app_version,
        Some(account),
        Duration::from_secs(PROBE_TIMEOUT_SECS),
        refresh_history,
        Some(Rc::clone(&usage)),
        opencode_go_batch,
    );
    let payloads = usage.take();
    (output, payloads)
}

fn run_probe_with_account_timeout(
    plugin: &LoadedPlugin,
    app_data_dir: &PathBuf,
    app_version: &str,
    account: Option<ProviderAccountContext>,
    timeout: Duration,
    refresh_history: bool,
    deferred_usage: Option<host_api::DeferredUsage>,
    opencode_go_batch: Option<Arc<host_api::OpenCodeGoProbeBatch>>,
) -> PluginOutput {
    let plugin_id = account
        .as_ref()
        .map(|account| account.instance_id.clone())
        .unwrap_or_else(|| plugin.manifest.id.clone());
    let identity_generation = if matches!(plugin.manifest.id.as_str(), "claude" | "codex") {
        provider_accounts::begin_history_identity_probe(app_data_dir, &plugin_id).filter(|_| {
            let Some(account) = &account else { return true };
            let Some(path) = &account.store_path else { return true };
            provider_accounts::load_store_path(path).is_ok_and(|store| {
                let stored = store.accounts.get(&plugin_id);
                let current = stored
                    .map(|entry| &entry.credential)
                    .filter(|credential| !credential.is_empty());
                current == account.credential.as_ref()
                    && stored.and_then(|entry| entry.codex_home.as_ref()) == account.codex_home.as_ref()
            })
        })
    } else {
        None
    };
    let fallback = error_output(plugin, "runtime error".to_string());
    let timeout_message = format!("probe timed out after {}s", timeout.as_secs());
    let deadline_at = Instant::now()
        .checked_add(timeout)
        .unwrap_or_else(Instant::now);
    let deadline = host_api::ProbeDeadline::at(deadline_at);

    let rt = match Runtime::new() {
        Ok(rt) => rt,
        Err(_) => return fallback,
    };
    rt.set_interrupt_handler(Some(Box::new(move || Instant::now() >= deadline_at)));

    let ctx = match Context::full(&rt) {
        Ok(ctx) => ctx,
        Err(_) => return fallback,
    };

    let base_plugin_id = account
        .as_ref()
        .map(|account| account.base_provider_id.clone())
        .unwrap_or_else(|| plugin.manifest.id.clone());
    let display_name = account
        .as_ref()
        .filter(|account| !account.label.trim().is_empty())
        .map(|account| format!("{} ({})", plugin.manifest.name, account.label.trim()))
        .unwrap_or_else(|| plugin.manifest.name.clone());
    let entry_script = plugin.entry_script.clone();
    let icon_url = plugin.icon_data_url.clone();
    let app_data = app_data_dir.clone();

    ctx.with(|ctx| {
        if host_api::inject_host_api_with_deadline(
            &ctx,
            &base_plugin_id,
            &plugin_id,
            account.as_ref(),
            &app_data,
            app_version,
            host_api::ProbeNetwork { deadline, opencode_go_batch, deferred_usage },
        )
        .is_err()
        {
            if deadline.has_elapsed() {
                return error_output(plugin, timeout_message.clone());
            }
            return error_output(plugin, "host api injection failed".to_string());
        }
        if refresh_history
            && base_plugin_id == "freebuff"
            && ctx.eval::<(), _>("__openusage_ctx.app.refreshHistory = true; void 0").is_err()
        {
            return error_output(plugin, "history option initialization failed".to_string());
        }
        if host_api::patch_http_wrapper(&ctx).is_err() {
            if deadline.has_elapsed() {
                return error_output(plugin, timeout_message.clone());
            }
            return error_output(plugin, "http wrapper patch failed".to_string());
        }
        if host_api::patch_ls_wrapper(&ctx).is_err() {
            if deadline.has_elapsed() {
                return error_output(plugin, timeout_message.clone());
            }
            return error_output(plugin, "ls wrapper patch failed".to_string());
        }
        if host_api::patch_usage_daily_wrapper(&ctx).is_err() {
            if deadline.has_elapsed() {
                return error_output(plugin, timeout_message.clone());
            }
            return error_output(plugin, "usageDaily wrapper patch failed".to_string());
        }
        if host_api::patch_cursor_logs_wrapper(&ctx).is_err() {
            if deadline.has_elapsed() {
                return error_output(plugin, timeout_message.clone());
            }
            return error_output(plugin, "cursorLogs wrapper patch failed".to_string());
        }
        if host_api::patch_claude_logs_wrapper(&ctx).is_err() {
            if deadline.has_elapsed() {
                return error_output(plugin, timeout_message.clone());
            }
            return error_output(plugin, "claudeLogs wrapper patch failed".to_string());
        }
        if host_api::patch_codex_logs_wrapper(&ctx).is_err() {
            if deadline.has_elapsed() {
                return error_output(plugin, timeout_message.clone());
            }
            return error_output(plugin, "codexLogs wrapper patch failed".to_string());
        }
        if host_api::patch_antigravity_logs_wrapper(&ctx).is_err() {
            if deadline.has_elapsed() {
                return error_output(plugin, timeout_message.clone());
            }
            return error_output(plugin, "antigravityLogs wrapper patch failed".to_string());
        }
        if host_api::patch_grok_logs_wrapper(&ctx).is_err() {
            if deadline.has_elapsed() {
                return error_output(plugin, timeout_message.clone());
            }
            return error_output(plugin, "grokLogs wrapper patch failed".to_string());
        }
        if host_api::patch_cursor_usage_export_wrapper(&ctx).is_err() {
            if deadline.has_elapsed() {
                return error_output(plugin, timeout_message.clone());
            }
            return error_output(plugin, "cursorUsageExport wrapper patch failed".to_string());
        }
        if host_api::patch_fireworks_wrapper(&ctx).is_err() {
            if deadline.has_elapsed() {
                return error_output(plugin, timeout_message.clone());
            }
            return error_output(plugin, "fireworks wrapper patch failed".to_string());
        }
        if host_api::patch_chromium_cookies_wrapper(&ctx).is_err() {
            if deadline.has_elapsed() {
                return error_output(plugin, timeout_message.clone());
            }
            return error_output(plugin, "chromiumCookies wrapper patch failed".to_string());
        }
        if host_api::inject_utils(&ctx).is_err() {
            if deadline.has_elapsed() {
                return error_output(plugin, timeout_message.clone());
            }
            return error_output(plugin, "utils injection failed".to_string());
        }

        if ctx.eval::<(), _>(entry_script.as_bytes()).is_err() {
            if deadline.has_elapsed() {
                return error_output(plugin, timeout_message.clone());
            }
            return error_output(plugin, "script eval failed".to_string());
        }

        let globals = ctx.globals();
        let plugin_obj: Object = match globals.get("__openusage_plugin") {
            Ok(obj) => obj,
            Err(_) => return error_output(plugin, "missing __openusage_plugin".to_string()),
        };

        let probe_fn: rquickjs::Function = match plugin_obj.get("probe") {
            Ok(f) => f,
            Err(_) => return error_output(plugin, "missing probe()".to_string()),
        };

        let probe_ctx: Value = globals
            .get("__openusage_ctx")
            .unwrap_or_else(|_| Value::new_undefined(ctx.clone()));

        let result_value: Value = match probe_fn.call((probe_ctx,)) {
            Ok(r) => r,
            Err(_) => {
                if deadline.has_elapsed() {
                    return error_output(plugin, timeout_message.clone());
                }
                return error_output(plugin, extract_error_string(&ctx));
            }
        };
        if deadline.has_elapsed() {
            return error_output(plugin, timeout_message.clone());
        }
        let result: Object = if result_value.is_promise() {
            let promise: Promise = match result_value.into_promise() {
                Some(promise) => promise,
                None => {
                    return error_output(plugin, "probe() returned invalid promise".to_string());
                }
            };
            match promise.finish::<Object>() {
                Ok(obj) => obj,
                Err(Error::WouldBlock) => {
                    return error_output(plugin, "probe() returned unresolved promise".to_string());
                }
                Err(_) => return error_output(plugin, extract_error_string(&ctx)),
            }
        } else {
            match result_value.into_object() {
                Some(obj) => obj,
                None => return error_output(plugin, "probe() returned non-object".to_string()),
            }
        };

        let plan: Option<String> = result
            .get::<_, String>("plan")
            .ok()
            .filter(|s| !s.is_empty());

        let warning: Option<String> = result
            .get::<_, String>("warning")
            .ok()
            .filter(|s| !s.is_empty());

        let lines = match parse_lines(&result) {
            Ok(lines) if !lines.is_empty() => {
                if let Some(generation) = identity_generation
                    && let Ok(key) = result.get::<_, String>("verifiedHistoryIdentity")
                {
                    provider_accounts::finish_history_identity_probe(
                        &app_data, &plugin_id, generation, &plugin.manifest.id, &key,
                    );
                }
                lines
            }
            Ok(_) => vec![error_line("no lines returned".to_string())],
            Err(msg) => vec![error_line(msg)],
        };

        PluginOutput {
            provider_id: plugin_id,
            display_name,
            plan,
            warning,
            lines,
            icon_url,
        }
    })
}

/// Call a named export on `__openusage_plugin` (e.g. `claimResetCredit`) with JSON args.
/// Returns the string result of the function, or an error message.
pub fn run_plugin_action(
    plugin: &LoadedPlugin,
    app_data_dir: &PathBuf,
    app_version: &str,
    action: &str,
    args_json: &str,
    account: Option<ProviderAccountContext>,
) -> Result<String, String> {
    run_guarded_plugin_action(plugin, app_data_dir, app_version, action, args_json, account, || true)
}

pub fn run_guarded_plugin_action(
    plugin: &LoadedPlugin,
    app_data_dir: &PathBuf,
    app_version: &str,
    action: &str,
    args_json: &str,
    account: Option<ProviderAccountContext>,
    can_redeem: impl Fn() -> bool + 'static,
) -> Result<String, String> {
    let timeout = Duration::from_secs(PROBE_TIMEOUT_SECS);
    let deadline_at = Instant::now()
        .checked_add(timeout)
        .unwrap_or_else(Instant::now);
    let deadline = host_api::ProbeDeadline::at(deadline_at);

    let rt = Runtime::new().map_err(|_| "runtime init failed".to_string())?;
    rt.set_interrupt_handler(Some(Box::new(move || Instant::now() >= deadline_at)));
    let ctx = Context::full(&rt).map_err(|_| "context init failed".to_string())?;

    let plugin_id = account
        .as_ref()
        .map(|account| account.instance_id.clone())
        .unwrap_or_else(|| plugin.manifest.id.clone());
    let base_plugin_id = account
        .as_ref()
        .map(|account| account.base_provider_id.clone())
        .unwrap_or_else(|| plugin.manifest.id.clone());
    let entry_script = plugin.entry_script.clone();
    let app_data = app_data_dir.clone();
    let action_name = action.to_string();
    let args_json = args_json.to_string();

    ctx.with(|ctx| {
        host_api::inject_host_api_with_deadline(
            &ctx,
            &base_plugin_id,
            &plugin_id,
            account.as_ref(),
            &app_data,
            app_version,
            host_api::ProbeNetwork { deadline, opencode_go_batch: None, deferred_usage: None },
        )
        .map_err(|_| "host api injection failed".to_string())?;
        host_api::patch_http_wrapper(&ctx).map_err(|_| "http wrapper failed".to_string())?;
        host_api::patch_chromium_cookies_wrapper(&ctx)
            .map_err(|_| "chromiumCookies wrapper failed".to_string())?;
        host_api::inject_utils(&ctx).map_err(|_| "utils injection failed".to_string())?;
        ctx.eval::<(), _>(entry_script.as_bytes())
            .map_err(|_| "script eval failed".to_string())?;

        let globals = ctx.globals();
        let plugin_obj: Object = globals
            .get("__openusage_plugin")
            .map_err(|_| "missing __openusage_plugin".to_string())?;
        let action_fn: rquickjs::Function = plugin_obj
            .get(action_name.as_str())
            .map_err(|_| format!("missing action {action_name}"))?;

        let probe_ctx: Value = globals
            .get("__openusage_ctx")
            .unwrap_or_else(|_| Value::new_undefined(ctx.clone()));

        // Inject args as a global JSON literal, then read it back as a Value.
        let inject = format!("globalThis.__openusage_action_args = ({args_json});");
        ctx.eval::<(), _>(inject.as_bytes())
            .map_err(|_| "invalid action args json".to_string())?;
        let args_value: Value = globals
            .get("__openusage_action_args")
            .map_err(|_| "missing action args".to_string())?;
        let consent = rquickjs::Function::new(ctx.clone(), can_redeem)
            .map_err(|_| "action consent guard failed".to_string())?;

        let result_value: Value = action_fn
            .call((probe_ctx, args_value, consent))
            .map_err(|_| extract_error_string(&ctx))?;

        let as_outcome = |value: Value| -> Result<String, String> {
            if let Some(s) = value.as_string() {
                return s
                    .to_string()
                    .map_err(|_| "action string decode failed".to_string());
            }
            Err("action returned non-string".to_string())
        };

        if result_value.is_promise() {
            let promise: Promise = result_value
                .into_promise()
                .ok_or_else(|| "action returned invalid promise".to_string())?;
            let finished: Value = promise.finish().map_err(|e| match e {
                Error::WouldBlock => "action returned unresolved promise".to_string(),
                _ => extract_error_string(&ctx),
            })?;
            as_outcome(finished)
        } else {
            as_outcome(result_value)
        }
    })
}

fn parse_model_breakdown(line: &Object) -> Option<Vec<ModelSpendBreakdown>> {
    let arr: Array = line.get("modelBreakdown").ok()?;
    let mut out = Vec::new();
    let len = arr.len();
    for idx in 0..len {
        let row: Object = arr.get(idx).ok()?;
        let model = row.get::<_, String>("model").unwrap_or_default();
        let tokens = row
            .get::<_, f64>("tokens")
            .ok()
            .filter(|v| v.is_finite())
            .map(|v| v.max(0.0) as u64)
            .unwrap_or(0);
        let percent = row
            .get::<_, f64>("percent")
            .ok()
            .filter(|v| v.is_finite())
            .unwrap_or(0.0);
        let cost_usd = row.get::<_, f64>("costUsd").ok().filter(|v| v.is_finite());
        if model.trim().is_empty() {
            continue;
        }
        out.push(ModelSpendBreakdown {
            model,
            tokens,
            cost_usd,
            percent,
        });
    }
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

fn parse_reset_credit_expiries(line: &Object) -> Option<Vec<String>> {
    let arr: Array = line.get("resetCreditExpiries").ok()?;
    let mut out = Vec::new();
    let len = arr.len();
    for idx in 0..len {
        let Ok(value) = arr.get::<Value>(idx) else {
            continue;
        };
        if let Some(s) = value.as_string() {
            if let Ok(text) = s.to_string() {
                let trimmed = text.trim();
                if !trimmed.is_empty() {
                    out.push(trimmed.to_string());
                }
            }
        }
    }
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

fn parse_lines(result: &Object) -> Result<Vec<MetricLine>, String> {
    let lines: Array = result
        .get("lines")
        .map_err(|_| "missing lines".to_string())?;

    let mut out = Vec::new();
    let len = lines.len();
    for idx in 0..len {
        let line: Object = lines
            .get(idx)
            .map_err(|_| format!("invalid line at index {}", idx))?;

        let line_type: String = line.get("type").unwrap_or_default();
        let label = line.get::<_, String>("label").unwrap_or_default();
        let color = line.get::<_, String>("color").ok();
        let subtitle = line.get::<_, String>("subtitle").ok();

        match line_type.as_str() {
            "text" => {
                let value = line.get::<_, String>("value").unwrap_or_default();
                let model_breakdown = parse_model_breakdown(&line);
                let status_dot = line.get::<_, String>("statusDot").ok();
                let expiry_tooltip = line.get::<_, String>("expiryTooltip").ok();
                let reset_credit_expiries = parse_reset_credit_expiries(&line);
                out.push(MetricLine::Text {
                    label,
                    value,
                    color,
                    subtitle,
                    model_breakdown,
                    status_dot,
                    expiry_tooltip,
                    reset_credit_expiries,
                });
            }
            "progress" => {
                let used_value: Value = match line.get("used") {
                    Ok(v) => v,
                    Err(_) => {
                        out.push(error_line(format!(
                            "progress line at index {} missing used",
                            idx
                        )));
                        continue;
                    }
                };
                let used = match used_value.as_number() {
                    Some(n) => n,
                    None => {
                        out.push(error_line(format!(
                            "progress line at index {} invalid used (expected number)",
                            idx
                        )));
                        continue;
                    }
                };

                let limit_value: Value = match line.get("limit") {
                    Ok(v) => v,
                    Err(_) => {
                        out.push(error_line(format!(
                            "progress line at index {} missing limit",
                            idx
                        )));
                        continue;
                    }
                };
                let limit = match limit_value.as_number() {
                    Some(n) => n,
                    None => {
                        out.push(error_line(format!(
                            "progress line at index {} invalid limit (expected number)",
                            idx
                        )));
                        continue;
                    }
                };

                if !used.is_finite() || used < 0.0 {
                    out.push(error_line(format!(
                        "progress line at index {} invalid used: {}",
                        idx, used
                    )));
                    continue;
                }
                if !limit.is_finite() || limit <= 0.0 {
                    out.push(error_line(format!(
                        "progress line at index {} invalid limit: {}",
                        idx, limit
                    )));
                    continue;
                }

                let format_obj: Object = match line.get("format") {
                    Ok(obj) => obj,
                    Err(_) => {
                        out.push(error_line(format!(
                            "progress line at index {} missing format",
                            idx
                        )));
                        continue;
                    }
                };
                let kind_value: Value = match format_obj.get("kind") {
                    Ok(v) => v,
                    Err(_) => {
                        out.push(error_line(format!(
                            "progress line at index {} missing format.kind",
                            idx
                        )));
                        continue;
                    }
                };
                let kind = match kind_value.as_string() {
                    Some(s) => s.to_string().unwrap_or_default(),
                    None => {
                        out.push(error_line(format!(
                            "progress line at index {} invalid format.kind (expected string)",
                            idx
                        )));
                        continue;
                    }
                };
                let format = match kind.as_str() {
                    "percent" => {
                        if limit != 100.0 {
                            out.push(error_line(format!(
                                "progress line at index {}: percent format requires limit=100 (got {})",
                                idx, limit
                            )));
                            continue;
                        }
                        ProgressFormat::Percent
                    }
                    "dollars" => ProgressFormat::Dollars,
                    "count" => {
                        let suffix_value: Value = match format_obj.get("suffix") {
                            Ok(v) => v,
                            Err(_) => {
                                out.push(error_line(format!(
                                    "progress line at index {}: count format missing suffix",
                                    idx
                                )));
                                continue;
                            }
                        };
                        let suffix = match suffix_value.as_string() {
                            Some(s) => s.to_string().unwrap_or_default(),
                            None => {
                                out.push(error_line(format!(
                                    "progress line at index {}: count format suffix must be a string",
                                    idx
                                )));
                                continue;
                            }
                        };
                        let suffix = suffix.trim().to_string();
                        if suffix.is_empty() {
                            out.push(error_line(format!(
                                "progress line at index {}: count format suffix must be non-empty",
                                idx
                            )));
                            continue;
                        }
                        ProgressFormat::Count { suffix }
                    }
                    _ => {
                        out.push(error_line(format!(
                            "progress line at index {} invalid format.kind: {}",
                            idx, kind
                        )));
                        continue;
                    }
                };

                let resets_at = match line.get::<_, Value>("resetsAt") {
                    Ok(v) => {
                        if v.is_null() || v.is_undefined() {
                            None
                        } else if let Some(s) = v.as_string() {
                            let raw = s.to_string().unwrap_or_default();
                            let value = raw.trim().to_string();
                            if value.is_empty() {
                                None
                            } else {
                                let parsed = chrono::DateTime::parse_from_rfc3339(&value);
                                if parsed.is_ok() {
                                    Some(value)
                                } else {
                                    // ISO-like but missing timezone: assume UTC.
                                    let is_missing_tz =
                                        value.contains('T') && !value.ends_with('Z') && {
                                            let tail = value.splitn(2, 'T').nth(1).unwrap_or("");
                                            !tail.contains('+') && !tail.contains('-')
                                        };
                                    if is_missing_tz {
                                        let with_z = format!("{}Z", value);
                                        let parsed_with_z = chrono::DateTime::parse_from_rfc3339(&with_z);
                                        if parsed_with_z.is_ok() {
                                            Some(with_z)
                                        } else {
                                            log::warn!(
                                                "invalid resetsAt at index {} (value='{}'), omitting",
                                                idx,
                                                raw
                                            );
                                            None
                                        }
                                    } else {
                                        log::warn!(
                                            "invalid resetsAt at index {} (value='{}'), omitting",
                                            idx,
                                            raw
                                        );
                                        None
                                    }
                                }
                            }
                        } else {
                            log::warn!("invalid resetsAt at index {} (non-string), omitting", idx);
                            None
                        }
                    }
                    Err(_) => None,
                };

                // Parse optional periodDurationMs
                let period_duration_ms: Option<u64> = match line.get::<_, Value>("periodDurationMs")
                {
                    Ok(val) => {
                        if val.is_null() || val.is_undefined() {
                            None
                        } else if let Some(n) = val.as_number() {
                            let ms = n as u64;
                            if ms > 0 {
                                Some(ms)
                            } else {
                                log::warn!(
                                    "periodDurationMs at index {} must be positive, omitting",
                                    idx
                                );
                                None
                            }
                        } else {
                            log::warn!(
                                "invalid periodDurationMs at index {} (non-number), omitting",
                                idx
                            );
                            None
                        }
                    }
                    Err(_) => None,
                };

                let session_start_signal: Option<String> = match line.get::<_, Value>("sessionStartSignal")
                {
                    Ok(val) => val
                        .as_string()
                        .and_then(|s| s.to_string().ok())
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty()),
                    Err(_) => None,
                };

                out.push(MetricLine::Progress {
                    label,
                    used,
                    limit,
                    format,
                    resets_at,
                    period_duration_ms,
                    color,
                    session_start_signal,
                });
            }
            "badge" => {
                let text = line.get::<_, String>("text").unwrap_or_default();
                out.push(MetricLine::Badge {
                    label,
                    text,
                    color,
                    subtitle,
                });
            }
            "barChart" => {
                let (chart, errors) = parse_bar_chart_line(&line, idx, label, color);
                for message in errors {
                    out.push(error_line(message));
                }
                if let Some(chart) = chart {
                    out.push(chart);
                }
            }
            _ => {
                out.push(error_line(format!(
                    "unknown line type at index {}: {}",
                    idx, line_type
                )));
            }
        }
    }

    Ok(out)
}

// Upper bound on barChart points parsed from a plugin. The chart is daily
// history (plugins emit ~31), so a year of points is generous headroom while
// keeping the loop and allocations bounded — parse_lines runs natively after
// the JS returns, so the probe's interrupt-based timeout can't cap it here.
const MAX_BAR_CHART_POINTS: usize = 366;

// Parses a barChart line, keeping its point/value/note validation out of
// parse_lines. Returns the built line (when at least one point is valid) plus
// any per-point error messages the caller should surface as error lines.
fn parse_bar_chart_line<'js>(
    line: &Object<'js>,
    idx: usize,
    label: String,
    color: Option<String>,
) -> (Option<MetricLine>, Vec<String>) {
    let mut errors: Vec<String> = Vec::new();

    let points_array: Array = match line.get("points") {
        Ok(points) => points,
        Err(_) => {
            errors.push(format!("barChart line at index {} missing points", idx));
            return (None, errors);
        }
    };

    // Bound the loop to a plugin-independent maximum so a huge points array
    // can't exhaust CPU/memory in this native (non-interruptible) path.
    let total_points = points_array.len();
    let scan_count = total_points.min(MAX_BAR_CHART_POINTS);
    if total_points > MAX_BAR_CHART_POINTS {
        log::warn!(
            "barChart line at index {} has {} points; capping at {}",
            idx,
            total_points,
            MAX_BAR_CHART_POINTS
        );
    }

    let mut points = Vec::new();
    for point_idx in 0..scan_count {
        let point: Object = match points_array.get(point_idx) {
            Ok(point) => point,
            Err(_) => {
                errors.push(format!(
                    "barChart line at index {} has invalid point at index {}",
                    idx, point_idx
                ));
                continue;
            }
        };
        let point_label = point.get::<_, String>("label").unwrap_or_default();
        let point_label = point_label.trim().to_string();
        if point_label.is_empty() {
            errors.push(format!(
                "barChart line at index {} has empty point label at index {}",
                idx, point_idx
            ));
            continue;
        }

        let value: Value = match point.get("value") {
            Ok(v) => v,
            Err(_) => {
                errors.push(format!(
                    "barChart line at index {} point {} missing value",
                    idx, point_idx
                ));
                continue;
            }
        };
        let value = match value.as_number() {
            Some(n) if n.is_finite() && n >= 0.0 => n,
            _ => {
                errors.push(format!(
                    "barChart line at index {} point {} invalid value",
                    idx, point_idx
                ));
                continue;
            }
        };

        let value_label = match point.get::<_, Value>("valueLabel") {
            Ok(v) => {
                if v.is_null() || v.is_undefined() {
                    None
                } else if let Some(s) = v.as_string() {
                    let value = s.to_string().unwrap_or_default();
                    let trimmed = value.trim().to_string();
                    if trimmed.is_empty() {
                        None
                    } else {
                        Some(trimmed)
                    }
                } else {
                    log::warn!(
                        "invalid barChart valueLabel at line {} point {}, omitting",
                        idx,
                        point_idx
                    );
                    None
                }
            }
            Err(_) => None,
        };

        points.push(BarChartPoint {
            label: point_label,
            value,
            value_label,
        });
    }

    if points.is_empty() {
        errors.push(format!(
            "barChart line at index {} has no valid points",
            idx
        ));
        return (None, errors);
    }

    let note = match line.get::<_, Value>("note") {
        Ok(v) => {
            if v.is_null() || v.is_undefined() {
                None
            } else if let Some(s) = v.as_string() {
                let value = s.to_string().unwrap_or_default();
                let trimmed = value.trim().to_string();
                if trimmed.is_empty() {
                    None
                } else {
                    Some(trimmed)
                }
            } else {
                log::warn!("invalid note at index {} (non-string), omitting", idx);
                None
            }
        }
        Err(_) => None,
    };

    (
        Some(MetricLine::BarChart {
            label,
            points,
            note,
            color,
        }),
        errors,
    )
}

fn error_output(plugin: &LoadedPlugin, message: String) -> PluginOutput {
    PluginOutput {
        provider_id: plugin.manifest.id.clone(),
        display_name: plugin.manifest.name.clone(),
        plan: None,
        warning: None,
        lines: vec![error_line(message)],
        icon_url: plugin.icon_data_url.clone(),
    }
}

/// Error-shaped probe output for a specific provider instance (matches `run_probe_with_account` ids).
pub fn probe_fault_output(
    plugin: &LoadedPlugin,
    provider_id: &str,
    display_name: &str,
    message: String,
) -> PluginOutput {
    PluginOutput {
        provider_id: provider_id.to_string(),
        display_name: display_name.to_string(),
        plan: None,
        warning: None,
        lines: vec![error_line(message)],
        icon_url: plugin.icon_data_url.clone(),
    }
}

fn extract_error_string(ctx: &Ctx<'_>) -> String {
    let exc = ctx.catch();
    if exc.is_null() || exc.is_undefined() {
        return "The plugin failed, try again or contact plugin author.".to_string();
    }
    if let Some(str_val) = exc.as_string() {
        let message: String = str_val.to_string().unwrap_or_default();
        let trimmed = message.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }
    "The plugin failed, try again or contact plugin author.".to_string()
}

fn error_line(message: String) -> MetricLine {
    MetricLine::Badge {
        label: "Error".to_string(),
        text: message,
        color: Some("#ef4444".to_string()),
        subtitle: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plugin_engine::host_api;
    use crate::plugin_engine::manifest::{LoadedPlugin, PluginManifest};
    use crate::provider_accounts::{ProviderAccountContext, ProviderCredential};
    use serde_json::Value as JsonValue;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn test_plugin(entry_script: &str) -> LoadedPlugin {
        test_plugin_with_id("test", "Test", entry_script)
    }

    fn test_plugin_with_id(id: &str, name: &str, entry_script: &str) -> LoadedPlugin {
        LoadedPlugin {
            manifest: PluginManifest {
                schema_version: 1,
                id: id.to_string(),
                name: name.to_string(),
                version: "0.0.0".to_string(),
                entry: "plugin.js".to_string(),
                icon: "icon.svg".to_string(),
                brand_color: None,
                lines: vec![],
                links: vec![],
            },
            plugin_dir: PathBuf::from("."),
            entry_script: entry_script.to_string(),
            icon_data_url: "data:image/svg+xml;base64,".to_string(),
            icon_file_path: PathBuf::from("."),
        }
    }

    fn temp_app_dir(label: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        std::env::temp_dir().join(format!("openusage-test-{}-{}", label, nanos))
    }

    fn error_text(output: PluginOutput) -> String {
        match output.lines.first() {
            Some(MetricLine::Badge { text, .. }) => text.clone(),
            other => panic!("expected error badge, got {:?}", other),
        }
    }

    #[test]
    fn history_identities_are_keyed_by_instance_not_display_label() {
        let dir = temp_app_dir("history-identities");
        for (family, instance, key) in [
            ("claude", "claude:work", "Acct-1|Org-1"),
            ("codex", "codex:work", "Account-A"),
        ] {
            let plugin = test_plugin_with_id(
                family,
                family,
                &format!(r#"globalThis.__openusage_plugin = {{ probe: (ctx) => ({{
                    lines: [ctx.line.text({{ label: "Status", value: "Ready" }})],
                    verifiedHistoryIdentity: "{key}"
                }}) }};"#),
            );
            run_probe_with_account(&plugin, &dir, "test", Some(account(instance, family, "Work", "test")));
        }
        assert_eq!(
            provider_accounts::verified_history_identities(&dir).unwrap(),
            [
                ("claude:work".into(), "acct-1|org-1".into()),
                ("codex:work".into(), "account-a".into()),
            ].into()
        );
        let failed = test_plugin_with_id(
            "claude",
            "Claude",
            r#"globalThis.__openusage_plugin = { probe: () => { throw "Not logged in"; } };"#,
        );
        run_probe_with_account(&failed, &dir, "test", Some(account("claude:work", "claude", "Work", "test")));
        assert_eq!(
            provider_accounts::verified_history_identities(&dir).unwrap(),
            [("codex:work".into(), "account-a".into())].into()
        );
    }

    fn account(
        instance_id: &str,
        base_provider_id: &str,
        label: &str,
        token: &str,
    ) -> ProviderAccountContext {
        ProviderAccountContext {
            instance_id: instance_id.to_string(),
            base_provider_id: base_provider_id.to_string(),
            label: label.to_string(),
            credential: Some(ProviderCredential {
                access_token: Some(token.to_string()),
                refresh_token: None,
                session_key: None,
                expires_at: None,
            }),
            codex_home: None,
            store_path: None,
        }
    }

    #[test]
    fn groups_local_and_configured_opencode_credentials_within_a_batch() {
        let script = format!(
            "{}\nconst probe = globalThis.__openusage_plugin.probe;\n{}",
            include_str!("../../../../plugins/opencode-go/plugin.js"),
            r#"
            globalThis.__openusage_plugin.probe = function (ctx) {
                ctx.host.env.get = () => null;
                ctx.host.fs.exists = path => path.endsWith("/auth.json");
                ctx.host.fs.readText = () => '{"opencode-go":{"key":"same-test-key"}}';
                ctx.host.opencodeGateway = undefined;
                return probe(ctx);
            };
            "#,
        );
        let plugin = test_plugin_with_id("opencode-go", "OpenCode Go", &script);
        let temp = tempfile::tempdir().unwrap();
        let dir = temp.path().to_path_buf();
        let batch = Arc::new(host_api::OpenCodeGoProbeBatch::default());
        let response = |percent| serde_json::json!({
            "usage": {
                "rolling": { "percent": percent },
                "weekly": { "percent": 0 },
                "monthly": { "percent": 0 }
            }
        }).to_string();
        let first = response(12);
        let other = response(34);
        let fresh = response(56);
        host_api::install_http_mock(vec![(200, &first), (200, &other), (200, &fresh)]);
        let run = |context, batch| run_probe_in_batch(&plugin, &dir, "0.0.0", context, Some(batch));
        let local = run(None, Arc::clone(&batch));
        let alias = run(
            Some(account("opencode-go:work", "opencode-go", "Work", "same-test-key")),
            Arc::clone(&batch),
        );
        let second_alias = run(
            Some(account("opencode-go:copy", "opencode-go", "Copy", "same-test-key")),
            Arc::clone(&batch),
        );
        let distinct = run(
            Some(account("opencode-go:personal", "opencode-go", "Personal", "other-test-key")),
            batch,
        );
        let next = run(None, Arc::new(host_api::OpenCodeGoProbeBatch::default()));
        let used = |out: PluginOutput| match out.lines.first() {
            Some(MetricLine::Progress { used, .. }) => *used,
            other => panic!("expected OpenCode meter, got {other:?}"),
        };
        assert_eq!(alias.provider_id, "opencode-go:work");
        assert_eq!(
            [used(local), used(alias), used(second_alias), used(distinct), used(next)],
            [12.0, 12.0, 12.0, 34.0, 56.0]
        );
        assert_eq!(host_api::take_http_mock_requests().len(), 3);
    }

    #[test]
    fn run_probe_returns_thrown_string_from_sync_error() {
        let plugin = test_plugin(
            r#"
            globalThis.__openusage_plugin = {
                probe() {
                    throw "boom";
                }
            };
            "#,
        );
        let output = run_probe(&plugin, &temp_app_dir("sync"), "0.0.0");
        assert_eq!(error_text(output), "boom");
    }

    #[test]
    fn deferred_probe_collects_daily_rows_without_writing_history() {
        let plugin = test_plugin(
            r#"
            globalThis.__openusage_plugin = {
                probe(ctx) {
                    ctx.host.usageDaily.ingest({daily: [{date: "2030-01-01", totalTokens: 42}]});
                    return {lines: [{type: "text", label: "State", value: "OK"}]};
                }
            };
            "#,
        );
        let dir = tempfile::tempdir().unwrap();
        let app_data = dir.path().to_path_buf();
        std::fs::write(app_data.join("settings.json"), r#"{"persistUsageHistory":true}"#).unwrap();
        let account = ProviderAccountContext {
            instance_id: "test:work".into(),
            base_provider_id: "test".into(),
            label: "Work".into(),
            credential: None,
            codex_home: None,
            store_path: None,
        };
        let (output, payloads) = run_probe_with_deferred_usage(&plugin, &app_data, "0.0.0", account);
        assert_eq!(output.provider_id, "test:work");
        assert_eq!(payloads.len(), 1);
        let usage: JsonValue = serde_json::from_str(&payloads[0]).unwrap();
        assert_eq!(usage["daily"][0]["totalTokens"], 42);
        assert!(!crate::usage_history::usage_history_db_path(&app_data).exists());
    }

    #[test]
    fn run_probe_returns_thrown_string_from_async_error() {
        let plugin = test_plugin(
            r#"
            globalThis.__openusage_plugin = {
                probe: async function () {
                    throw "boom";
                }
            };
            "#,
        );
        let output = run_probe(&plugin, &temp_app_dir("async"), "0.0.0");
        assert_eq!(error_text(output), "boom");
    }

    #[test]
    fn progress_resets_at_serializes_as_resets_at_camelcase() {
        let line = MetricLine::Progress {
            label: "Session".to_string(),
            used: 1.0,
            limit: 100.0,
            format: ProgressFormat::Percent,
            resets_at: Some("2099-01-01T00:00:00.000Z".to_string()),
            period_duration_ms: None,
            color: None,
            session_start_signal: None,        };

        let json: JsonValue = serde_json::to_value(&line).expect("serialize");
        let obj = json.as_object().expect("object");
        assert!(obj.get("resetsAt").is_some(), "expected resetsAt key");
        assert!(
            obj.get("resets_at").is_none(),
            "did not expect resets_at key"
        );
    }

    #[test]
    fn bar_chart_line_round_trips_from_builder() {
        let plugin = test_plugin(
            r#"
            globalThis.__openusage_plugin = {
                probe(ctx) {
                    return {
                        lines: [
                            ctx.line.barChart({
                                label: "Usage Trend",
                                points: [{ label: "Today", value: 42, valueLabel: "42 tokens" }],
                                note: "Estimated from local logs"
                            })
                        ]
                    };
                }
            };
            "#,
        );

        let output = run_probe(&plugin, &temp_app_dir("bar-chart"), "0.0.0");
        let json: JsonValue = serde_json::to_value(&output.lines[0]).expect("serialize");
        assert_eq!(json["type"], "barChart");
        assert_eq!(json["label"], "Usage Trend");
        assert_eq!(json["points"][0]["valueLabel"], "42 tokens");
        assert_eq!(json["note"], "Estimated from local logs");
    }

    #[test]
    fn bar_chart_caps_excessive_points() {
        let plugin = test_plugin(
            r#"
            globalThis.__openusage_plugin = {
                probe(ctx) {
                    var points = [];
                    for (var i = 0; i < 5000; i++) {
                        points.push({ label: "d" + i, value: i });
                    }
                    return { lines: [ctx.line.barChart({ label: "Big", points: points })] };
                }
            };
            "#,
        );

        let output = run_probe(&plugin, &temp_app_dir("bar-chart-cap"), "0.0.0");
        let json: JsonValue = serde_json::to_value(&output.lines[0]).expect("serialize");
        assert_eq!(json["type"], "barChart");
        assert_eq!(
            json["points"].as_array().expect("points array").len(),
            MAX_BAR_CHART_POINTS
        );
    }

    #[test]
    fn run_probe_routes_account_credentials_to_http_headers() {
        let claude = test_plugin_with_id(
            "claude",
            "Claude",
            r#"
            globalThis.__openusage_plugin = {
                probe(ctx) {
                    const raw = ctx.host.credentials.get();
                    const credential = JSON.parse(raw);
                    ctx.host.http.request({
                        method: "GET",
                        url: "https://example.test/claude/" + ctx.host.account.instanceId,
                        headers: { Authorization: "Bearer " + credential.accessToken }
                    });
                    return { lines: [{ type: "text", label: "Account", value: ctx.host.account.label }] };
                }
            };
            "#,
        );
        let cursor = test_plugin_with_id(
            "cursor",
            "Cursor",
            r#"
            globalThis.__openusage_plugin = {
                probe(ctx) {
                    const raw = ctx.host.credentials.get();
                    const credential = JSON.parse(raw);
                    ctx.host.http.request({
                        method: "POST",
                        url: "https://example.test/cursor",
                        headers: {
                            Authorization: "Bearer " + credential.accessToken,
                            Cookie: "WorkosCursorSessionToken=test-session"
                        }
                    });
                    return { lines: [{ type: "text", label: "Account", value: ctx.account.label }] };
                }
            };
            "#,
        );
        host_api::install_http_mock(vec![(200, "{}"), (200, "{}"), (200, "{}")]);

        let dir = temp_app_dir("multi-account");
        let out_work = run_probe_with_account(
            &claude,
            &dir,
            "0.0.0",
            Some(account(
                "claude:work",
                "claude",
                "Work",
                "claude-work-token",
            )),
        );
        let out_personal = run_probe_with_account(
            &claude,
            &dir,
            "0.0.0",
            Some(account(
                "claude:personal",
                "claude",
                "Personal",
                "claude-personal-token",
            )),
        );
        let out_cursor = run_probe_with_account(
            &cursor,
            &dir,
            "0.0.0",
            Some(account(
                "cursor:default",
                "cursor",
                "Default",
                "cursor-token",
            )),
        );

        assert_eq!(out_work.provider_id, "claude:work");
        assert_eq!(out_personal.provider_id, "claude:personal");
        assert_eq!(out_cursor.provider_id, "cursor:default");

        let requests = host_api::take_http_mock_requests();
        assert_eq!(requests.len(), 3);
        assert_eq!(
            requests[0].headers.get("Authorization").map(String::as_str),
            Some("Bearer claude-work-token")
        );
        assert_eq!(
            requests[1].headers.get("Authorization").map(String::as_str),
            Some("Bearer claude-personal-token")
        );
        assert_eq!(
            requests[2].headers.get("Authorization").map(String::as_str),
            Some("Bearer cursor-token")
        );
        assert_eq!(
            requests[2].headers.get("Cookie").map(String::as_str),
            Some("WorkosCursorSessionToken=test-session")
        );
    }

    fn isolated_bundled_plugin(plugin: &LoadedPlugin) -> LoadedPlugin {
        let mut isolated = plugin.clone();
        isolated.entry_script = format!(
            "{}\n;globalThis.__openusage_plugin = (() => {{
                const plugin = globalThis.__openusage_plugin;
                const probe = plugin.probe;
                plugin.probe = function(ctx) {{
                    if (ctx.host.env) ctx.host.env.get = () => null;
                    if (ctx.host.fs) {{
                        ctx.host.fs.homeDir = \"C:/quotabar-isolated-home\";
                        ctx.host.fs.exists = () => false;
                        ctx.host.fs.firstExisting = () => null;
                        ctx.host.fs.firstExistingAppSupport = () => null;
                        ctx.host.fs.readText = () => null;
                        ctx.host.fs.writeText = () => false;
                        ctx.host.fs.listDir = () => [];
                    }}
                    const emptyDaily = () => ({{ status: \"no_data\", data: {{ daily: [] }} }});
                    for (const name of [\"claudeLogs\", \"codexLogs\", \"cursorLogs\", \"grokLogs\", \"antigravityLogs\"]) {{
                        if (ctx.host[name]) ctx.host[name].queryDaily = emptyDaily;
                    }}
                    if (ctx.host.cursorPaths) ctx.host.cursorPaths.resolveStateDb = () => null;
                    if (ctx.host.cursorUsageExport) {{
                        ctx.host.cursorUsageExport.queryDaily = () => null;
                        ctx.host.cursorUsageExport.queryMtd = () => null;
                    }}
                    if (ctx.host.sqlite) {{
                        ctx.host.sqlite.query = () => \"[]\";
                        ctx.host.sqlite.exec = () => undefined;
                    }}
                    if (ctx.host.keychain) {{
                        for (const key of Object.keys(ctx.host.keychain)) {{
                            if (key.startsWith(\"read\")) ctx.host.keychain[key] = () => null;
                            else ctx.host.keychain[key] = () => true;
                        }}
                    }}
                    if (ctx.host.chromiumCookies) ctx.host.chromiumCookies.read = () => [];
                    if (ctx.host.ls) ctx.host.ls.discover = () => null;
                    if (ctx.host.opencodeGateway) ctx.host.opencodeGateway.scan = () => null;
                    if (ctx.host.zcode) ctx.host.zcode.scan = () => null;
                    return probe(ctx);
                }};
                return plugin;
            }})();",
            plugin.entry_script
        );
        isolated
    }

    #[test]
    fn bundled_provider_scripts_execute_fail_closed_in_quickjs_without_machine_state() {
        let plugin_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../plugins");
        let plugins = crate::plugin_engine::manifest::load_plugins_from_dir(&plugin_dir);
        // Public builds (which tests are) skip the Google-only plugins.
        let skipped = if crate::google_terms::PRIVATE_GOOGLE_ACCESS { 0 } else { crate::google_terms::GOOGLE_ONLY_PLUGIN_IDS.len() };
        assert!(plugins.len() + skipped >= 30, "expected bundled provider inventory, got {}", plugins.len());
        host_api::install_http_mock(vec![(200, "{}"); 400]);
        let dir = temp_app_dir("bundled-provider-smoke");
        let mut failures = Vec::new();
        for plugin in plugins {
            let id = plugin.manifest.id.clone();
            let output = run_probe(&isolated_bundled_plugin(&plugin), &dir, "test");
            if output.provider_id != id {
                failures.push(format!("{id}: provider id became {}", output.provider_id));
            }
            if output.lines.is_empty() {
                failures.push(format!("{id}: no metric lines or error badge"));
            }
            if matches!(output.lines.first(), Some(MetricLine::Badge { text, .. }) if text == "runtime error") {
                failures.push(format!("{id}: generic runtime error"));
            }
        }
        assert!(failures.is_empty(), "{}", failures.join("\n"));
    }

    fn bundled_plugin(plugin_dir: &std::path::Path, id: &str) -> LoadedPlugin {
        crate::plugin_engine::manifest::load_plugins_from_dir(plugin_dir)
            .into_iter()
            .find(|plugin| plugin.manifest.id == id)
            .unwrap_or_else(|| panic!("bundled {id} plugin"))
    }

    #[test]
    fn real_remote_plugins_map_mocked_success_responses_in_quickjs() {
        let plugin_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../plugins");
        let dir = temp_app_dir("remote-provider-mocks");

        let openrouter = bundled_plugin(&plugin_dir, "openrouter");
        host_api::install_http_mock(vec![
            (200, r#"{"data":{"total_usage":4.5,"total_credits":10}}"#),
            (200, r#"{"data":{"is_free_tier":false,"usage_daily":1.25,"usage_weekly":3.5,"usage_monthly":8,"limit":20,"limit_remaining":15}}"#),
        ]);
        let output = run_probe_with_account(
            &isolated_bundled_plugin(&openrouter),
            &dir,
            "test",
            Some(account("openrouter:work", "openrouter", "Work", "sk-or-test")),
        );
        assert_eq!(output.plan.as_deref(), Some("Pay as you go"));
        for expected in ["Credits", "Balance", "Today", "Key Limit"] {
            assert!(output.lines.iter().any(|line| match line {
                MetricLine::Text { label, .. } | MetricLine::Progress { label, .. } | MetricLine::Badge { label, .. } => label == expected,
                _ => false,
            }), "missing OpenRouter line {expected}: {:?}", output.lines);
        }
        assert!(!output.lines.iter().any(|line| matches!(line, MetricLine::Badge { label, .. } if label == "Error")));
        let requests = host_api::take_http_mock_requests();
        assert_eq!(requests.len(), 2);
        assert!(requests.iter().all(|request| request.headers.get("Authorization").is_some_and(|value| value == "Bearer sk-or-test")));

        let crofai = bundled_plugin(&plugin_dir, "crofai");
        host_api::install_http_mock(vec![(200, r#"{"credits":10,"usable_requests":100,"requests_plan":500}"#)]);
        let output = run_probe_with_account(
            &isolated_bundled_plugin(&crofai),
            &dir,
            "test",
            Some(account("crofai:work", "crofai", "Work", "crof-test")),
        );
        assert!(!output.lines.is_empty());
        assert!(!output.lines.iter().any(|line| matches!(line, MetricLine::Badge { label, .. } if label == "Error")), "unexpected CrofAI error: {:?}", output.lines);
        let requests = host_api::take_http_mock_requests();
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].headers.get("Authorization").map(String::as_str), Some("Bearer crof-test"));
    }

    #[test]
    fn real_cursor_plugin_dev_mock_accounts_probe_successfully_without_network() {
        let plugin_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../plugins");
        let plugin = crate::plugin_engine::manifest::load_plugins_from_dir(&plugin_dir)
            .into_iter()
            .find(|plugin| plugin.manifest.id == "cursor")
            .expect("bundled Cursor plugin");
        let dir = temp_app_dir("cursor-dev-mock-accounts");
        for (instance, label) in [("cursor:work", "Work"), ("cursor:personal", "Personal")] {
            let output = run_probe_with_account(
                &isolated_bundled_plugin(&plugin),
                &dir,
                "test",
                Some(account(instance, "cursor", label, "quotabar-dev-mock-access-token")),
            );
            assert_eq!(output.provider_id, instance);
            assert_eq!(output.plan.as_deref(), Some("Dev mock"));
            assert!(output.lines.iter().any(|line| matches!(
                line,
                MetricLine::Text { label, value, .. } if label == "Data source" && value == "Mock (QuotaBar dev)"
            )));
            assert!(!output.lines.iter().any(|line| matches!(line, MetricLine::Badge { label, .. } if label == "Error")));
        }
    }

    #[test]
    fn concurrent_quickjs_probes_survive_repeated_parallel_stress() {
        let script = r#"
            globalThis.__openusage_plugin = {
                probe(ctx) {
                    let total = 0;
                    for (let i = 0; i < 2000; i += 1) total += i % 7;
                    ctx.host.usageDaily.ingest({ daily: [{ date: "2030-01-01", totalTokens: total }] });
                    return { lines: [{ type: "text", label: "State", value: "ok" }] };
                }
            };
        "#;
        let mut failures = Vec::new();
        std::thread::scope(|scope| {
            let mut handles = Vec::new();
            for worker in 0..8 {
                handles.push(scope.spawn(move || {
                    let plugin = test_plugin_with_id("stress", "Stress", script);
                    let dir = temp_app_dir(&format!("parallel-probe-{worker}"));
                    for iteration in 0..10 {
                        let (output, payloads) = run_probe_with_deferred_usage(
                            &plugin,
                            &dir,
                            "test",
                            account("stress:worker", "stress", "Worker", "token"),
                        );
                        if output.provider_id != "stress:worker" || payloads.len() != 1 {
                            return Err(format!("worker {worker} iteration {iteration} produced invalid output"));
                        }
                    }
                    Ok::<(), String>(())
                }));
            }
            for handle in handles {
                match handle.join() {
                    Ok(Ok(())) => {}
                    Ok(Err(error)) => failures.push(error),
                    Err(_) => failures.push("worker panicked".to_string()),
                }
            }
        });
        assert!(failures.is_empty(), "{}", failures.join("\n"));
    }

}
