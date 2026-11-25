//! OpenCode provider runtime (`Providers/OpenCode`).
//!
//! Credential discovery, the Go account API, OpenCode's SQLite history, the local Go windows, and
//! the Claude/Codex/Hermes/Muse gateway folds all live here. The Swift type owns only widget
//! descriptors and the engine call.

pub mod auth;
pub mod client;
pub mod mapper;
pub mod scanner;

#[cfg(test)]
mod tests;

use self::auth::{AuthError, GoKey};
use self::client::{AccountUsage, ClientError, GoClient};
use self::mapper::account_meter_lines;
use self::scanner::{FoldSources, OpenCodeScan, ScanError};
use super::{cancelled_snapshot, ProviderRuntime};
use crate::accounting::{
    append_token_usage, append_usage_trend, TokenUsageOptions, UsageHistoryWindow,
};
use crate::context::RefreshContext;
use crate::host;
use crate::model::{
    ErrorCategory, MetricLine, ProviderInfo, ProviderSnapshot, ProviderUsageHistory,
};
use crate::pricing::{self, ModelPricing};
use crate::qlog;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;

pub const ID: &str = "opencode";
const SOURCE_NOTE: &str = "From your OpenCode logs";

#[derive(Clone, Default)]
struct Config {
    data_directory: Option<PathBuf>,
    active_key_id: Option<String>,
    gateway_claude: bool,
    gateway_codex: bool,
    gateway_hermes: bool,
    gateway_muse: bool,
    claude_roots: Option<Vec<PathBuf>>,
    codex_homes: Option<Vec<PathBuf>>,
    hermes_state_db: Option<PathBuf>,
    muse_roots: Option<Vec<PathBuf>>,
    router_ledger_paths: Option<Vec<PathBuf>>,
    enabled_codex_identity_keys: Option<std::collections::BTreeSet<String>>,
    codex_home_identity_keys: std::collections::HashMap<String, String>,
    codex_account_identity_keys: std::collections::HashMap<String, String>,
    router_account_identity_keys: std::collections::HashMap<String, String>,
    claude_account_configs: Vec<crate::providers::claude::ClaudeProviderConfig>,
}

impl Config {
    fn from_value(value: Option<&Value>) -> Self {
        let Some(Value::Object(object)) = value else {
            return Config {
                gateway_claude: true,
                gateway_codex: true,
                gateway_hermes: true,
                gateway_muse: true,
                ..Config::default()
            };
        };
        let string = |key: &str| {
            object
                .get(key)
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
        };
        let paths = |key: &str| {
            object.get(key).and_then(Value::as_array).map(|values| {
                values
                    .iter()
                    .filter_map(Value::as_str)
                    .map(PathBuf::from)
                    .collect::<Vec<_>>()
            })
        };
        let bool_value =
            |key: &str, default: bool| object.get(key).and_then(Value::as_bool).unwrap_or(default);
        let string_map = |key: &str, lowercase_keys: bool| {
            object
                .get(key)
                .and_then(Value::as_object)
                .map(|values| {
                    values
                        .iter()
                        .filter_map(|(key, value)| {
                            value.as_str().map(|value| {
                                (
                                    if lowercase_keys {
                                        key.trim().to_lowercase()
                                    } else {
                                        key.trim().to_string()
                                    },
                                    value.trim().to_lowercase(),
                                )
                            })
                        })
                        .filter(|(key, value)| !key.is_empty() && !value.is_empty())
                        .collect::<std::collections::HashMap<_, _>>()
                })
                .unwrap_or_default()
        };
        Config {
            data_directory: string("dataDirectory").map(PathBuf::from),
            active_key_id: string("activeKeyID"),
            gateway_claude: bool_value("gatewayClaude", true),
            gateway_codex: bool_value("gatewayCodex", true),
            gateway_hermes: bool_value("gatewayHermes", true),
            gateway_muse: bool_value("gatewayMuse", true),
            claude_roots: paths("claudeRoots"),
            codex_homes: paths("codexHomes"),
            hermes_state_db: string("hermesStateDB").map(PathBuf::from),
            muse_roots: paths("museRoots"),
            router_ledger_paths: paths("routerLedgerPaths"),
            enabled_codex_identity_keys: object.get("enabledCodexIdentityKeys").map(|value| {
                value
                    .as_array()
                    .map(|values| {
                        values
                            .iter()
                            .filter_map(Value::as_str)
                            .map(|value| value.trim().to_lowercase())
                            .filter(|value| !value.is_empty())
                            .collect::<std::collections::BTreeSet<_>>()
                    })
                    .unwrap_or_default()
            }),
            codex_home_identity_keys: string_map("codexHomeIdentityKeys", false),
            codex_account_identity_keys: string_map("codexAccountIdentityKeys", true),
            router_account_identity_keys: string_map("routerAccountIdentityKeys", true),
            claude_account_configs: object
                .get("claudeAccountConfigs")
                .and_then(Value::as_array)
                .map(|values| {
                    values
                        .iter()
                        .map(|value| {
                            crate::providers::claude::ClaudeProviderConfig::from_value(Some(value))
                        })
                        .collect()
                })
                .unwrap_or_default(),
        }
    }
}

struct GoAccountMeters {
    meters: Vec<MetricLine>,
    display_error: Option<ClientError>,
    clears_prior_quota_state: bool,
    cancelled: bool,
}

pub struct OpenCodeProvider {
    info: ProviderInfo,
    http: Arc<dyn crate::http::HttpClient>,
    pricing_override: Option<Arc<ModelPricing>>,
    home: PathBuf,
    app_data: PathBuf,
}

impl OpenCodeProvider {
    pub fn live() -> Self {
        OpenCodeProvider {
            info: ProviderInfo {
                id: ID.into(),
                display_name: "OpenCode".into(),
            },
            http: crate::http::shared(),
            pricing_override: None,
            home: crate::paths::home(),
            app_data: crate::paths::app_data(),
        }
    }

    #[cfg(test)]
    pub fn with_parts(
        home: PathBuf,
        app_data: PathBuf,
        http: Arc<dyn crate::http::HttpClient>,
    ) -> Self {
        OpenCodeProvider {
            info: ProviderInfo {
                id: ID.into(),
                display_name: "OpenCode".into(),
            },
            http,
            pricing_override: None,
            home,
            app_data,
        }
    }

    #[cfg(test)]
    pub fn with_pricing_override(mut self, pricing: Arc<ModelPricing>) -> Self {
        self.pricing_override = Some(pricing);
        self
    }

    fn pricing(&self, ctx: &RefreshContext) -> Arc<ModelPricing> {
        self.pricing_override.clone().unwrap_or_else(|| {
            pricing::shared()
                .current(ctx.skip_model_catalog_refresh || ctx.scope.suppresses_live_quota())
        })
    }

    fn data_directory(&self, config: &Config) -> PathBuf {
        config
            .data_directory
            .clone()
            .unwrap_or_else(|| auth::data_directory(&self.home, &host::env_var))
    }

    fn keys(&self, config: &Config) -> Result<Vec<GoKey>, AuthError> {
        let data_directory = self.data_directory(config);
        let file = auth::load_auth_file_keys(&data_directory);
        let saved = auth::load_saved_keys(&self.app_data);
        if file.is_err() && saved.is_err() {
            return Err(AuthError::CredentialsUnreadable(
                "OpenCode credentials are unreadable".into(),
            ));
        }
        let mut keys = Vec::new();
        match file {
            Ok(file) => keys.extend(file),
            Err(error) => qlog!(
                Warn,
                host::plugin_tag(ID),
                "auth.json unreadable: {}",
                error.detail()
            ),
        }
        match saved {
            Ok(saved) => keys.extend(auth::saved_to_go_keys(&saved)),
            Err(_) => qlog!(
                Warn,
                host::plugin_tag(ID),
                "app-saved OpenCode Go keys unreadable"
            ),
        }
        Ok(keys)
    }

    fn fetch_go_accounts(
        &self,
        keys: &[GoKey],
        config: &Config,
        ctx: &RefreshContext,
    ) -> GoAccountMeters {
        let client = GoClient::with_http(self.http.clone());
        let mut seen = BTreeSet::new();
        let unique: Vec<&GoKey> = keys
            .iter()
            .filter(|key| seen.insert(credential_id(&key.key)))
            .collect();
        let mut usages: Vec<(String, String, AccountUsage)> = Vec::new();
        let mut errors: Vec<(String, String, String, ClientError)> = Vec::new();
        let mut cancelled = false;
        if !ctx.scope.suppresses_live_quota() {
            for key in unique {
                if ctx.is_cancelled() {
                    cancelled = true;
                    break;
                }
                match client.fetch_usage(&key.key, &ctx.cancel) {
                    Ok(usage) => usages.push((key.name.clone(), credential_id(&key.key), usage)),
                    Err(ClientError::Cancelled) => {
                        cancelled = true;
                        break;
                    }
                    Err(error) => {
                        let id = credential_id(&key.key);
                        qlog!(
                            Warn,
                            host::plugin_tag(ID),
                            "account usage API unavailable ({}): {}",
                            key.name,
                            error.message()
                        );
                        errors.push((key.name.clone(), key.id.clone(), id, error));
                    }
                }
            }
        }
        let configured = distinct_names(keys);
        let display_name = |credential: &str| {
            configured
                .iter()
                .find(|(id, _)| id == credential)
                .map(|(_, name)| name.clone())
                .unwrap_or_else(|| "Account".into())
        };
        let mut distinct: Vec<(String, String, AccountUsage)> = Vec::new();
        let mut index_by_id: std::collections::BTreeMap<String, usize> =
            std::collections::BTreeMap::new();
        for (name, credential, usage) in usages {
            if let Some(index) = distinct.iter().position(|(id, _, _)| *id == credential) {
                index_by_id.insert(name, index);
            } else {
                index_by_id.insert(name, distinct.len());
                let label = display_name(&credential);
                distinct.push((credential, label, usage));
            }
        }
        for key in keys {
            if let Some(index) = distinct
                .iter()
                .position(|(id, _, _)| *id == credential_id(&key.key))
            {
                index_by_id.insert(key.id.clone(), index);
            }
        }
        let selected = config.active_key_id.clone();
        let selected_known = selected
            .as_ref()
            .is_some_and(|id| keys.iter().any(|key| &key.id == id));
        let selected_index = selected
            .as_ref()
            .and_then(|id| index_by_id.get(id).copied());
        let meters = if configured.len() == 1
            && distinct.len() == 1
            && (!selected_known || selected_index.is_some())
        {
            account_meter_lines(&distinct[0].2, None)
        } else if selected_known {
            match selected_index.and_then(|index| distinct.get(index)) {
                Some((_, name, usage)) => account_meter_lines(usage, Some(name)),
                None => Vec::new(),
            }
        } else {
            distinct
                .iter()
                .flat_map(|(_, name, usage)| account_meter_lines(usage, Some(name)))
                .collect()
        };
        let relevant_errors: Vec<&(String, String, String, ClientError)> =
            match (&selected, selected_known) {
                (Some(id), true) => errors
                    .iter()
                    .filter(|(_, key_id, _, _)| key_id == id)
                    .collect(),
                _ => errors.iter().collect(),
            };
        let display_error = relevant_errors.first().map(|entry| entry.3.clone());
        let has_usage = !meters.is_empty();
        GoAccountMeters {
            meters,
            display_error,
            clears_prior_quota_state: !ctx.scope.suppresses_live_quota()
                && (!has_usage || !relevant_errors.is_empty()),
            cancelled,
        }
    }

    fn scan(
        &self,
        config: &Config,
        ctx: &RefreshContext,
        pricing: Arc<ModelPricing>,
    ) -> Result<Option<OpenCodeScan>, ScanError> {
        let data_directory = self.data_directory(config);
        let databases =
            auth::database_files(&data_directory).map_err(|_| ScanError::DatabaseUnreadable)?;
        let sources = FoldSources {
            claude_roots: config
                .claude_roots
                .clone()
                .unwrap_or_else(default_claude_roots),
            codex_homes: config
                .codex_homes
                .clone()
                .unwrap_or_else(default_codex_homes),
            hermes_state_db: config.hermes_state_db.clone().or_else(|| {
                Some(crate::providers::hermes::scanner::default_state_db_path())
                    .filter(|path| path.exists())
            }),
            muse_roots: config
                .muse_roots
                .clone()
                .unwrap_or_else(|| vec![crate::providers::muse::sessions_directory(&self.home)]),
            router_ledger_paths: config.router_ledger_paths.clone().unwrap_or_default(),
            enabled_codex_identity_keys: config.enabled_codex_identity_keys.clone(),
            codex_home_identity_keys: config.codex_home_identity_keys.clone(),
            codex_account_identity_keys: config.codex_account_identity_keys.clone(),
            router_account_identity_keys: config.router_account_identity_keys.clone(),
            claude_account_configs: config.claude_account_configs.clone(),
        };
        let sources = FoldSources {
            claude_roots: if config.gateway_claude {
                sources.claude_roots
            } else {
                Vec::new()
            },
            codex_homes: if config.gateway_codex {
                sources.codex_homes
            } else {
                Vec::new()
            },
            hermes_state_db: if config.gateway_hermes {
                sources.hermes_state_db
            } else {
                None
            },
            muse_roots: if config.gateway_muse {
                sources.muse_roots
            } else {
                Vec::new()
            },
            router_ledger_paths: if config.gateway_codex {
                sources.router_ledger_paths
            } else {
                Vec::new()
            },
            enabled_codex_identity_keys: if config.gateway_codex {
                sources.enabled_codex_identity_keys
            } else {
                None
            },
            codex_home_identity_keys: if config.gateway_codex {
                sources.codex_home_identity_keys
            } else {
                Default::default()
            },
            codex_account_identity_keys: if config.gateway_codex {
                sources.codex_account_identity_keys
            } else {
                Default::default()
            },
            router_account_identity_keys: if config.gateway_codex {
                sources.router_account_identity_keys
            } else {
                Default::default()
            },
            claude_account_configs: if config.gateway_claude {
                sources.claude_account_configs
            } else {
                Vec::new()
            },
        };
        let days = UsageHistoryWindow::lifetime_days(ctx.now, crate::accounting::DayZone::Local);
        scanner::scan(
            &databases,
            days,
            ctx.now,
            pricing.clone(),
            &sources,
            &ctx.cancel,
        )
    }
}

impl ProviderRuntime for OpenCodeProvider {
    fn info(&self) -> &ProviderInfo {
        &self.info
    }

    fn has_local_credentials(&self) -> bool {
        self.has_local_credentials_with_config(None)
    }

    fn has_local_credentials_with_config(&self, config: Option<&Value>) -> bool {
        let config = Config::from_value(config);
        if config.data_directory.is_some() {
            let data = self.data_directory(&config);
            if auth::load_auth_file_keys(&data)
                .map(|keys| !keys.is_empty())
                .unwrap_or(true)
            {
                return true;
            }
            if auth::load_saved_keys(&self.app_data)
                .map(|keys| !keys.is_empty())
                .unwrap_or(true)
            {
                return true;
            }
            return auth::database_files(&data)
                .map(|files| files.iter().any(|path| database_has_hosted_usage(path)))
                .unwrap_or(true);
        }
        auth::has_local_credentials(&self.home, &host::env_var)
    }

    fn unload_caches(&self) {
        scanner::clear_database_cache();
    }

    fn refresh(&self, ctx: &RefreshContext) -> ProviderSnapshot {
        if ctx.is_cancelled() {
            return cancelled_snapshot(&self.info, ctx);
        }
        let config = Config::from_value(ctx.config.as_ref());
        let keys = match self.keys(&config) {
            Ok(keys) => keys,
            Err(error) => {
                return ProviderSnapshot::error(
                    &self.info,
                    error.message(),
                    ErrorCategory::CredentialAccess,
                    ctx.now,
                )
            }
        };
        let accounts = if ctx.scope.skips_local_accounting() || ctx.scope.suppresses_live_quota() {
            GoAccountMeters {
                meters: Vec::new(),
                display_error: None,
                clears_prior_quota_state: false,
                cancelled: false,
            }
        } else {
            self.fetch_go_accounts(&keys, &config, ctx)
        };
        if accounts.cancelled || ctx.is_cancelled() {
            return cancelled_snapshot(&self.info, ctx);
        }
        if ctx.scope.skips_local_accounting() {
            return self.meter_snapshot(accounts, ctx);
        }
        let pricing = self.pricing(ctx);
        let scan = match self.scan(&config, ctx, pricing.clone()) {
            Ok(scan) => scan,
            Err(ScanError::Cancelled) => return cancelled_snapshot(&self.info, ctx),
            Err(ScanError::DatabaseUnreadable) => {
                return ProviderSnapshot::error(
                    &self.info,
                    "Couldn't read OpenCode's local database. Quit OpenCode and refresh, or check the data directory's permissions.",
                    ErrorCategory::CredentialAccess,
                    ctx.now,
                )
            }
            Err(ScanError::Incomplete(source)) => {
                return ProviderSnapshot::error(
                    &self.info,
                    "Couldn't read all of OpenCode's local usage history. Check its files and refresh again.",
                    ErrorCategory::Other,
                    ctx.now,
                )
                .with_scan_source(source)
            }
        };
        self.history_snapshot(accounts, scan, keys.is_empty(), &pricing, ctx)
    }
}

impl OpenCodeProvider {
    fn meter_snapshot(&self, accounts: GoAccountMeters, ctx: &RefreshContext) -> ProviderSnapshot {
        if !accounts.meters.is_empty() {
            let mut lines = accounts.meters.clone();
            MetricLine::append_no_data_if_needed(&mut lines);
            let mut snapshot = ProviderSnapshot::new(&self.info, Some("Go".into()), lines, ctx.now);
            snapshot.warning = accounts
                .display_error
                .as_ref()
                .map(|error| error.message().to_string());
            snapshot.clears_prior_menu_bar_quota_state = Some(accounts.clears_prior_quota_state);
            return snapshot;
        }
        let error = accounts
            .display_error
            .clone()
            .map(|error| (error.message().to_string(), error_category(&error)));
        match error {
            Some((message, category)) => {
                let mut snapshot = ProviderSnapshot::error(&self.info, &message, category, ctx.now);
                snapshot.clears_prior_menu_bar_quota_state =
                    Some(accounts.clears_prior_quota_state);
                snapshot
            }
            None => ProviderSnapshot::error(
                &self.info,
                "OpenCode not detected. Log in with OpenCode Go or use OpenCode locally first.",
                ErrorCategory::NotLoggedIn,
                ctx.now,
            ),
        }
    }

    fn history_snapshot(
        &self,
        accounts: GoAccountMeters,
        scan: Option<OpenCodeScan>,
        no_keys: bool,
        _pricing: &ModelPricing,
        ctx: &RefreshContext,
    ) -> ProviderSnapshot {
        let account_meters = accounts.meters;
        let account_has_usage = !account_meters.is_empty();
        let account_error = accounts.display_error;
        let Some(scan) = scan else {
            if account_has_usage {
                let mut lines = account_meters;
                MetricLine::append_no_data_if_needed(&mut lines);
                let mut snapshot =
                    ProviderSnapshot::new(&self.info, Some("Go".into()), lines, ctx.now);
                snapshot.warning = account_error
                    .as_ref()
                    .map(|error| error.message().to_string());
                snapshot.clears_prior_menu_bar_quota_state =
                    Some(accounts.clears_prior_quota_state);
                return snapshot;
            }
            if let Some(error) = account_error {
                let mut snapshot = ProviderSnapshot::error(
                    &self.info,
                    error.message(),
                    error_category(&error),
                    ctx.now,
                );
                snapshot.clears_prior_menu_bar_quota_state =
                    Some(accounts.clears_prior_quota_state);
                return snapshot;
            }
            return ProviderSnapshot::error(
                &self.info,
                if no_keys {
                    "OpenCode not detected. Log in with OpenCode Go or use OpenCode locally first."
                } else {
                    "OpenCode returned Go usage data QuotaBar couldn't read. Try refreshing."
                },
                if no_keys {
                    ErrorCategory::NotLoggedIn
                } else {
                    ErrorCategory::Decoding
                },
                ctx.now,
            );
        };
        let mut lines = account_meters;
        let options = TokenUsageOptions {
            estimated: scan.includes_estimated_cost,
            unknown_models_by_day: scan.log_scan.unknown_models_by_day.clone(),
            model_usage: scan.log_scan.model_usage.clone(),
            model_source_note: Some(SOURCE_NOTE.into()),
            partial_days: scan.partial_days.clone(),
            api_estimate_by_day: scan.log_scan.api_estimate_by_day.clone(),
            estimated_cost_days: scan.log_scan.estimated_cost_days.clone(),
        };
        append_token_usage(&scan.log_scan.series, &mut lines, ctx.now, &options);
        append_usage_trend(
            &scan.log_scan.series,
            &mut lines,
            ctx.now,
            SOURCE_NOTE,
            &scan.partial_days,
            None,
        );
        MetricLine::append_no_data_if_needed(&mut lines);
        let plan = account_has_usage.then(|| "Go".to_string());
        let mut snapshot = ProviderSnapshot::new(&self.info, plan, lines, ctx.now);
        snapshot.usage_history = Some(ProviderUsageHistory {
            series: scan.log_scan.series.clone(),
            model_usage: scan.log_scan.model_usage.clone(),
            unknown_models_by_day: scan.log_scan.unknown_models_by_day.clone(),
            api_estimate_by_day: scan.log_scan.api_estimate_by_day.clone(),
            api_estimate_incomplete_days: scan.log_scan.api_estimate_incomplete_days.clone(),
            partial_days: Some(scan.partial_days.clone()),
            estimated_cost_days: scan.log_scan.estimated_cost_days.clone(),
        });
        snapshot.history_refreshed_at = Some(ctx.now);
        snapshot.warning = account_error
            .as_ref()
            .map(|error| error.message().to_string())
            .or_else(|| no_keys.then(|| "OpenCode not detected. Log in with OpenCode Go or use OpenCode locally first.".to_string()));
        snapshot.clears_prior_menu_bar_quota_state = Some(accounts.clears_prior_quota_state);
        snapshot
    }
}

trait ScanSourceDetail {
    fn with_scan_source(self, source: String) -> Self;
}

impl ScanSourceDetail for ProviderSnapshot {
    fn with_scan_source(mut self, source: String) -> Self {
        self.history_warning = Some(format!(
            "{source} could not be read completely; preserving last-good combined usage."
        ));
        self
    }
}

fn error_category(error: &ClientError) -> ErrorCategory {
    match error {
        ClientError::Unauthorized | ClientError::NoEntitlement => ErrorCategory::CredentialAccess,
        ClientError::InvalidResponse => ErrorCategory::Decoding,
        ClientError::RequestFailed(_) => ErrorCategory::Network,
        ClientError::Unavailable(_) => ErrorCategory::Network,
        ClientError::Cancelled => ErrorCategory::Cancelled,
    }
}

fn credential_id(key: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(key.as_bytes());
    hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn distinct_names(keys: &[GoKey]) -> Vec<(String, String)> {
    let mut seen = BTreeSet::new();
    let mut output = Vec::new();
    for key in keys {
        let id = credential_id(&key.key);
        if !seen.insert(id.clone()) {
            continue;
        }
        let name = key.name.trim();
        output.push((
            id,
            if name.is_empty() {
                format!("Account {}", output.len() + 1)
            } else {
                name.to_string()
            },
        ));
    }
    output
}

fn default_claude_roots() -> Vec<PathBuf> {
    let home = crate::paths::home();
    let mut roots = Vec::new();
    if let Some(configured) = host::env_var("CLAUDE_CONFIG_DIR") {
        for part in configured
            .split(',')
            .map(str::trim)
            .filter(|part| !part.is_empty())
        {
            let mut path = crate::paths::expand_home(part);
            if path.file_name().is_some_and(|name| name == "projects") {
                path.pop();
            }
            if path.join("projects").is_dir() {
                roots.push(path);
            }
        }
    } else {
        let xdg = host::env_var("XDG_CONFIG_HOME")
            .map(|value| crate::paths::expand_home(value.trim()))
            .unwrap_or_else(|| home.join(".config"));
        let candidates = [xdg.join("claude"), home.join(".claude")];
        for path in candidates {
            if path.join("projects").is_dir() {
                roots.push(path);
            }
        }
    }
    roots
}

fn default_codex_homes() -> Vec<PathBuf> {
    let home = crate::paths::home();
    let mut homes = Vec::new();
    if let Some(configured) = host::env_var("CODEX_HOME") {
        for part in configured
            .split(',')
            .map(str::trim)
            .filter(|part| !part.is_empty())
        {
            homes.push(crate::paths::expand_home(part));
        }
    }
    if homes.is_empty() {
        homes.push(home.join(".codex"));
    }
    homes
}

fn database_has_hosted_usage(path: &Path) -> bool {
    let sql = "SELECT 1 FROM session_message WHERE type = 'assistant' LIMIT 1;";
    sqlite_any(path, sql)
        || sqlite_any(
            path,
            "SELECT 1 FROM message WHERE json_extract(data,'$.role') = 'assistant' LIMIT 1;",
        )
}

fn sqlite_any(path: &Path, sql: &str) -> bool {
    crate::sqlite::query_value_tolerating_missing_table(path, sql)
        .ok()
        .flatten()
        .is_some()
}
