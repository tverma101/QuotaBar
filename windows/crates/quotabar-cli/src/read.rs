use anyhow::{Context, Result};
use chrono::Utc;
use quotabar_core::limits_export::{limits_from_snapshots, probe_error_message, LimitsError};
use quotabar_core::provider_accounts::{self, ProviderAccountContext};
use quotabar_core::usage_snapshot::{read_cache, CachedPluginSnapshot, PluginSelection};
use quotabar_core::plugin_engine;
use std::collections::BTreeMap;

pub fn run(provider: Option<&str>, force: bool, diagnose: bool) -> Result<i32> {
    let paths = super::resolve_install_paths()?;
    let mut snapshots = read_cache(&paths.app_data).context("Could not read the app usage cache")?;
    let selection = PluginSelection::read(&paths.app_data).context("Could not read app settings")?;
    let mut plugins = plugin_engine::discover_plugin_dirs(&paths.app_data, paths.resource_dir.as_deref());
    if plugins.is_empty() {
        super::embedded_plugins::materialize_into_app_data(&paths.app_data)?;
        plugins = plugin_engine::discover_plugin_dirs(&paths.app_data, paths.resource_dir.as_deref());
    }
    if plugins.is_empty() {
        anyhow::bail!("No providers found. {}", quotabar_core::paths::plugins_empty_diagnostic(
            &paths.resource_resolution
        ));
    }

    let known = plugins.keys().cloned().collect::<Vec<_>>();
    let provider = provider.map(str::to_ascii_lowercase);
    let ids = selection.matching_ids(&known, provider.as_deref());
    if let (Some(provider), true) = (provider, ids.is_empty()) {
        eprintln!("quotabar-cli: Unknown provider: {provider}");
        return Ok(2);
    }

    let interrupt = super::register_batch_interrupt_flag()?;
    let mut errors = Vec::new();
    let mut accounts = None;
    let mut loaded_plugins = BTreeMap::new();
    let mut refresh_timed_out = false;
    for id in &ids {
        super::exit_if_batch_interrupted(&interrupt);
        if !force && snapshots.get(id).is_some_and(|s| !s.is_stale(Utc::now())) {
            continue;
        }
        if refresh_timed_out {
            errors.push(LimitsError {
                provider_id: id.clone(),
                message: "Refresh skipped because the previous probe timed out.".into(),
            });
            continue;
        }
        let base_id = selection.base_id(id);
        if !loaded_plugins.contains_key(base_id) {
            let plugin = plugin_engine::manifest::load_single_plugin(&plugins[base_id]);
            match plugin {
                Ok(plugin) if plugin.manifest.id == base_id => {
                    loaded_plugins.insert(base_id, plugin);
                }
                _ => {
                    errors.push(LimitsError {
                        provider_id: id.clone(),
                        message: "Could not load the provider plugin.".into(),
                    });
                    continue;
                }
            }
        }
        let plugin = &loaded_plugins[base_id];
        let store = accounts.get_or_insert_with(|| provider_accounts::load_store(&paths.app_data));
        let Ok(store) = store else {
            errors.push(LimitsError {
                provider_id: id.clone(),
                message: "Could not read configured provider accounts.".into(),
            });
            continue;
        };
        let saved_account = store.accounts.get(id).filter(|entry| entry.base_provider_id == base_id);
        let credential = saved_account.filter(|entry| !entry.credential.is_empty())
            .map(|entry| entry.credential.clone());
        if id != base_id && credential.is_none() {
            errors.push(LimitsError {
                provider_id: id.clone(),
                message: "This account has no independently configured credentials.".into(),
            });
            continue;
        }
        let label = selection.provider_instances.get(id).map(|instance| instance.label.as_str())
            .or_else(|| saved_account.map(|account| account.label.as_str()));
        let account = ProviderAccountContext {
            instance_id: id.clone(),
            base_provider_id: base_id.to_string(),
            label: label.unwrap_or_default().to_string(),
            credential,
            store_path: Some(provider_accounts::store_path(&paths.app_data)),
        };
        let attempt = super::batch_probe::run_account_probe_with_timeout(
            plugin, &paths.app_data, env!("CARGO_PKG_VERSION"), Some(&interrupt), Some(account),
        );
        refresh_timed_out = attempt.timed_out;
        let output = attempt.output;
        if let Some(message) = probe_error_message(&output) {
            errors.push(LimitsError { provider_id: id.clone(), message: message.to_string() });
        } else if output.provider_id == *id {
            snapshots.insert(id.clone(), CachedPluginSnapshot::from_output(output, Utc::now()));
        } else {
            errors.push(LimitsError {
                provider_id: id.clone(),
                message: "The probe returned a different provider identity.".into(),
            });
        }
    }

    let now = Utc::now();
    let selected = ids.iter().filter_map(|id| snapshots.get(id));
    let mut failed = !errors.is_empty();
    for error in &errors {
        eprintln!("quotabar-cli: {}: {}", error.provider_id, error.message);
    }
    if diagnose {
        let mut findings = Vec::new();
        for error in &errors {
            findings.push(serde_json::json!({
                "providerId": error.provider_id,
                "severity": "error",
                "message": error.message,
            }));
        }
        for snapshot in selected.clone() {
            for message in snapshot.warning.as_deref().into_iter().chain(
                snapshot.is_stale(now).then_some("Live quota data is stale."),
            ) {
                findings.push(serde_json::json!({
                    "providerId": snapshot.provider_id,
                    "severity": "warning",
                    "message": message,
                }));
            }
        }
        failed = !findings.is_empty();
        let diagnostics: BTreeMap<_, _> = selected.map(|snapshot| (
            &snapshot.provider_id,
            serde_json::json!({
                "snapshot": snapshot,
                "expiresAt": snapshot.expires_at().map(|date| date.to_rfc3339()),
                "stale": snapshot.is_stale(now),
                "quotaAgeSeconds": snapshot.fetched_at()
                    .map(|date| now.signed_duration_since(date).num_seconds().max(0)),
            }),
        )).collect();
        println!("{}", serde_json::to_string_pretty(&serde_json::json!({
            "schema": "quotabar.windows.diagnostics.v1",
            "generatedAt": now.to_rfc3339(),
            "providers": diagnostics,
            "findings": findings,
            "errors": errors,
        }))?);
    } else {
        let limits = limits_from_snapshots(selected, errors, now);
        println!("{}", serde_json::to_string_pretty(&limits)?);
    }
    Ok(if failed { 4 } else { 0 })
}
