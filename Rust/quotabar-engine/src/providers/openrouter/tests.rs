use super::super::api_key::ApiKeySpec;
use super::auth::spec_with_paths;
use super::*;
use crate::context::{RefreshContext, Scope};
use crate::host::diagnostic_gate;
use crate::http::{mock::FnClient as MockClient, HttpError, Response};
use crate::model::{MetricKind, MetricLine};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

fn json_ok(value: Value) -> Result<Response, HttpError> {
    Ok(Response {
        status: 200,
        headers: Vec::new(),
        body: serde_json::to_vec(&value).unwrap(),
    })
}

#[test]
fn credits_and_key_mappers_cover_all_cases() {
    let data = json!({ "total_credits": 277.47, "total_usage": 178.20 })
        .as_object()
        .unwrap()
        .clone();
    let lines = mapper::credits_lines(&data);
    assert_eq!(lines.len(), 2);
    if let MetricLine::Progress { used, limit, .. } = &lines[0] {
        assert!((*used - 178.20).abs() < 1e-3);
        assert!((*limit - 277.47).abs() < 1e-3);
    } else {
        panic!("expected progress");
    }
    if let MetricLine::Values { values, .. } = &lines[1] {
        assert!((values[0].number - 99.27).abs() < 1e-3);
    }

    assert!(mapper::credits_lines(json!({"foo": "bar"}).as_object().unwrap()).is_empty());
    assert!(mapper::credits_lines(json!({"total_usage": 2.5}).as_object().unwrap()).is_empty());

    let zero = mapper::credits_lines(
        json!({"total_credits": 0, "total_usage": 0})
            .as_object()
            .unwrap(),
    );
    assert_eq!(zero.len(), 1);
    assert_eq!(zero[0].label(), "Balance");

    let (plan, key_lines) = mapper::key_metrics(
        json!({
            "is_free_tier": false,
            "usage_daily": 0,
            "usage_weekly": 1.25,
            "usage_monthly": 4.5,
            "usage": 12,
            "limit": 5,
            "limit_remaining": 3
        })
        .as_object()
        .unwrap(),
    );
    assert_eq!(plan.as_deref(), Some("Pay as you go"));
    assert_eq!(key_lines.len(), 4);
    if let MetricLine::Progress {
        label, used, limit, ..
    } = &key_lines[3]
    {
        assert_eq!(label, "Key Limit");
        assert_eq!(*used, 2.0);
        assert_eq!(*limit, 5.0);
    }

    diagnostic_gate::clear(mapper::MISSING_LIMIT_REMAINING_KEY);
    let (_, omitted) = mapper::key_metrics(
        json!({"is_free_tier": false, "usage": 2, "limit": 5})
            .as_object()
            .unwrap(),
    );
    assert!(!omitted.iter().any(|l| l.is_progress()));
}

#[test]
fn cancellation_stops_after_credits_and_partial_endpoints_succeed() {
    let dir = tempfile::tempdir().unwrap();
    let cfg = dir.path().join("openrouter.json");
    std::fs::write(&cfg, r#"{"apiKey":"sk-or-test"}"#).unwrap();

    let urls = Arc::new(Mutex::new(Vec::<String>::new()));
    let urls_c = urls.clone();
    let cancel_client = Arc::new(MockClient::new(move |req| {
        urls_c.lock().unwrap().push(req.url.clone());
        Err(HttpError::Cancelled)
    }));
    let p_cancel = OpenRouterProvider::new(spec_with_paths(vec![cfg.clone()]), cancel_client);
    let snap = p_cancel.refresh(&RefreshContext::new(Scope::Full));
    assert_eq!(snap.error_category, Some(ErrorCategory::Cancelled));
    assert_eq!(urls.lock().unwrap().as_slice(), [CREDITS_URL]);

    let partial_client = Arc::new(MockClient::new(|req| {
        if req.url == CREDITS_URL {
            Ok(Response {
                status: 403,
                headers: Vec::new(),
                body: b"{}".to_vec(),
            })
        } else {
            json_ok(
                json!({ "data": { "is_free_tier": false, "usage_daily": 0.5, "usage_weekly": 2.0 } }),
            )
        }
    }));
    let p_partial = OpenRouterProvider::new(spec_with_paths(vec![cfg.clone()]), partial_client);
    let snap = p_partial.refresh(&RefreshContext::new(Scope::Full));
    assert_eq!(snap.error_category, None);
    assert!(snap.lines.iter().any(|l| l.label() == "Today"));
    assert!(!snap.lines.iter().any(|l| l.label() == "Balance"));

    let bad_client = Arc::new(MockClient::new(|_| {
        Ok(Response {
            status: 401,
            headers: Vec::new(),
            body: b"{}".to_vec(),
        })
    }));
    let p_bad = OpenRouterProvider::new(spec_with_paths(vec![cfg.clone()]), bad_client);
    assert_eq!(
        p_bad
            .refresh(&RefreshContext::new(Scope::Full))
            .error_category,
        Some(ErrorCategory::AuthInvalid)
    );

    let gated_empty = Arc::new(MockClient::new(|req| {
        if req.url == CREDITS_URL {
            Ok(Response {
                status: 403,
                headers: Vec::new(),
                body: b"{}".to_vec(),
            })
        } else {
            json_ok(json!({ "data": {} }))
        }
    }));
    let p_gated = OpenRouterProvider::new(spec_with_paths(vec![cfg]), gated_empty);
    assert_ne!(
        p_gated
            .refresh(&RefreshContext::new(Scope::Full))
            .error_category,
        Some(ErrorCategory::AuthInvalid)
    );
}

#[test]
fn missing_key_never_hits_network() {
    let dir = tempfile::tempdir().unwrap();
    let cfg = dir.path().join("missing.json");
    let client = Arc::new(MockClient::new(|_| panic!("must not hit network")));
    let provider = OpenRouterProvider::new(
        ApiKeySpec {
            provider_id: "openrouter",
            config_paths: vec![cfg],
            env_names: &[],
            missing_key_error: auth::MISSING_KEY_ERROR,
            save_failed_error: auth::SAVE_FAILED_ERROR,
            delete_failed_error: auth::DELETE_FAILED_ERROR,
        },
        client,
    );
    assert!(!provider.has_local_credentials());
    assert_eq!(
        provider
            .refresh(&RefreshContext::new(Scope::Full))
            .error_category,
        Some(ErrorCategory::NotLoggedIn)
    );
    let _ = HashMap::<String, String>::new();
    let _ = MetricKind::Dollars;
}

// ---- Auth store (Swift `OpenRouterAuthStoreTests`) ----

use super::super::api_key::{key_from_config_text, ApiKeyStatus};
use crate::host::{self, Host, LogLevel, SecureReadOutcome, SecureReadRequest};

struct EnvHost(HashMap<String, String>);

impl Host for EnvHost {
    fn log(&self, _: LogLevel, _: &str, _: &str) {}
    fn log_level(&self) -> LogLevel {
        LogLevel::Error
    }
    fn secure_read(&self, _: &SecureReadRequest) -> SecureReadOutcome {
        SecureReadOutcome::NotFound
    }
    fn env_var(&self, name: &str) -> Option<String> {
        self.0.get(name).filter(|v| !v.is_empty()).cloned()
    }
}

fn with_env<R>(vars: &[(&str, &str)], f: impl FnOnce() -> R) -> R {
    let map = vars
        .iter()
        .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
        .collect();
    host::with_test_host(Arc::new(EnvHost(map)), f)
}

fn paths(dir: &tempfile::TempDir) -> Vec<std::path::PathBuf> {
    vec![
        dir.path().join("quotabar.json"),
        dir.path().join("openusage.json"),
        dir.path().join("key.json"),
    ]
}

#[test]
fn live_spec_lists_the_swift_config_paths_and_environment_names() {
    assert_eq!(
        auth::CONFIG_PATHS,
        [
            "~/.config/quotabar/openrouter.json",
            "~/.config/openusage/openrouter.json",
            "~/.config/openrouter/key.json"
        ]
    );
    assert_eq!(auth::ENV_NAMES, ["OPENROUTER_API_KEY", "OPENROUTER_KEY"]);
}

#[test]
fn loads_config_formats_before_environment_and_skips_blank_values() {
    let cases: [(&str, Option<(usize, &str)>, Option<&str>, &str); 5] = [
        (
            "saved override",
            Some((0, r#"{"apiKey":"sk-or-file"}"#)),
            Some("sk-or-env"),
            "sk-or-file",
        ),
        ("environment fallback", None, Some("sk-or-env"), "sk-or-env"),
        (
            "legacy JSON key",
            Some((0, r#"{"api_key":"sk-or-json"}"#)),
            None,
            "sk-or-json",
        ),
        (
            "trimmed plain text",
            Some((1, "  sk-or-plain\n")),
            None,
            "sk-or-plain",
        ),
        (
            "blank config",
            Some((0, "   ")),
            Some("sk-or-env"),
            "sk-or-env",
        ),
    ];
    for (name, file, env, expected) in cases {
        let dir = tempfile::tempdir().unwrap();
        let paths = paths(&dir);
        if let Some((index, text)) = file {
            std::fs::write(&paths[index], text).unwrap();
        }
        let vars: Vec<(&str, &str)> = env.map(|v| ("OPENROUTER_API_KEY", v)).into_iter().collect();
        let loaded = with_env(&vars, || spec_with_paths(paths).load_key());
        assert_eq!(loaded.as_deref(), Some(expected), "{name}");
    }
    let dir = tempfile::tempdir().unwrap();
    assert_eq!(
        with_env(&[], || spec_with_paths(paths(&dir)).load_key()),
        None
    );
    // The second environment name is honored too.
    assert_eq!(
        with_env(&[("OPENROUTER_KEY", "sk-or-alt")], || spec_with_paths(
            paths(&dir)
        )
        .load_key())
        .as_deref(),
        Some("sk-or-alt")
    );
    assert_eq!(
        key_from_config_text(r#"{"key":"sk-or-k"}"#).as_deref(),
        Some("sk-or-k")
    );
}

#[test]
fn save_writes_trimmed_json_rejects_empty_and_overrides_environment() {
    let dir = tempfile::tempdir().unwrap();
    let paths = paths(&dir);
    let spec = spec_with_paths(paths.clone());
    with_env(&[], || {
        assert_eq!(spec.save_key("   ").unwrap_err(), auth::MISSING_KEY_ERROR);
        assert!(!paths[0].exists());
        spec.save_key("  sk-or-new  ").unwrap();
        assert_eq!(
            std::fs::read_to_string(&paths[0]).unwrap(),
            r#"{"apiKey":"sk-or-new"}"#
        );
        assert_eq!(spec.load_key().as_deref(), Some("sk-or-new"));
    });
    with_env(&[("OPENROUTER_API_KEY", "sk-or-env")], || {
        spec.save_key("sk-or-saved").unwrap();
        assert_eq!(spec.load_key().as_deref(), Some("sk-or-saved"));
        assert_eq!(spec.key_status(), ApiKeyStatus::OverrideActive);
    });
}

#[test]
fn key_status_reports_every_state() {
    let env = [("OPENROUTER_API_KEY", "sk-or-env")];
    let file_text = r#"{"apiKey":"sk-or-file"}"#;
    let status = |file: Option<&str>, env: &[(&str, &str)]| {
        let dir = tempfile::tempdir().unwrap();
        let paths = paths(&dir);
        if let Some(text) = file {
            std::fs::write(&paths[0], text).unwrap();
        }
        with_env(env, || spec_with_paths(paths).key_status())
    };
    assert_eq!(status(None, &[]), ApiKeyStatus::NotSet);
    assert_eq!(status(None, &env), ApiKeyStatus::FromEnvironment);
    assert_eq!(status(Some(file_text), &[]), ApiKeyStatus::Saved);
    assert_eq!(status(Some(file_text), &env), ApiKeyStatus::OverrideActive);
    assert_eq!(
        status(Some(file_text), &[("OPENROUTER_API_KEY", "sk-or-file")]),
        ApiKeyStatus::OverrideActive
    );
}

#[test]
fn unreadable_saved_key_is_detected_repairable_and_falls_back_to_environment() {
    // A directory at the config path exists but cannot be read as a file.
    let dir = tempfile::tempdir().unwrap();
    let paths = paths(&dir);
    std::fs::create_dir(&paths[0]).unwrap();
    let spec = spec_with_paths(paths.clone());
    with_env(&[], || {
        assert_eq!(spec.key_status(), ApiKeyStatus::SavedUnreadable);
        assert!(spec.has_key_or_unreadable_config());
        assert_eq!(
            auth::load_for_refresh(&spec),
            Err((
                auth::CREDENTIALS_UNREADABLE_ERROR,
                ErrorCategory::CredentialAccess
            ))
        );
        let provider = OpenRouterProvider::new(
            spec_with_paths(paths.clone()),
            Arc::new(MockClient::new(|_| {
                panic!("must not hit network without a readable key")
            })),
        );
        assert!(provider.has_local_credentials());
        assert_eq!(
            provider
                .refresh(&RefreshContext::new(Scope::Full))
                .error_category,
            Some(ErrorCategory::CredentialAccess)
        );
    });
    with_env(&[("OPENROUTER_API_KEY", "sk-or-env")], || {
        assert_eq!(spec.key_status(), ApiKeyStatus::EnvironmentFallback);
        assert_eq!(auth::load_for_refresh(&spec), Ok("sk-or-env".to_string()));
    });
}

#[test]
fn delete_clears_every_config_path_and_keeps_the_environment_fallback() {
    let cases: [(&[usize], bool); 4] =
        [(&[0], true), (&[0], false), (&[0, 1], false), (&[1], false)];
    for (indices, has_env) in cases {
        let dir = tempfile::tempdir().unwrap();
        let paths = paths(&dir);
        for &i in indices {
            std::fs::write(
                &paths[i],
                if i == 0 {
                    r#"{"apiKey":"sk-or-primary"}"#
                } else {
                    "sk-or-alt"
                },
            )
            .unwrap();
        }
        let spec = spec_with_paths(paths.clone());
        let env: Vec<(&str, &str)> = if has_env {
            vec![("OPENROUTER_API_KEY", "sk-or-env")]
        } else {
            vec![]
        };
        with_env(&env, || {
            spec.delete_key().unwrap();
            assert!(paths.iter().all(|p| !p.exists()));
            assert_eq!(spec.load_key().as_deref(), has_env.then_some("sk-or-env"));
            assert_eq!(
                spec.key_status(),
                if has_env {
                    ApiKeyStatus::FromEnvironment
                } else {
                    ApiKeyStatus::NotSet
                }
            );
        });
    }
    // Removing a key that is not there is the desired end state, not an error.
    let dir = tempfile::tempdir().unwrap();
    with_env(&[], || {
        let spec = spec_with_paths(paths(&dir));
        spec.delete_key().unwrap();
        assert_eq!(spec.key_status(), ApiKeyStatus::NotSet);
    });
}

// ---- Mapper (Swift `OpenRouterUsageMapperTests`) ----

fn object(value: Value) -> serde_json::Map<String, Value> {
    value.as_object().unwrap().clone()
}

#[test]
fn key_limit_uses_the_current_window_not_lifetime_usage() {
    let (_, lines) = mapper::key_metrics(&object(
        json!({ "usage": 12, "limit": 5, "limit_remaining": 3 }),
    ));
    match &lines[..] {
        [MetricLine::Progress {
            label, used, limit, ..
        }] => {
            assert_eq!((label.as_str(), *used, *limit), ("Key Limit", 2.0, 5.0));
        }
        other => panic!("unexpected lines {other:?}"),
    }
}

#[test]
fn key_metrics_omit_the_cap_when_unset_and_name_the_free_tier() {
    let (plan, lines) =
        mapper::key_metrics(&object(json!({ "is_free_tier": true, "limit": null })));
    assert_eq!(plan.as_deref(), Some("Free tier"));
    assert!(lines.is_empty());
}

#[test]
fn period_spend_rows_are_measured_zeros_in_swift_order() {
    let (_, lines) = mapper::key_metrics(&object(
        json!({ "usage_daily": 0, "usage_weekly": 1.25, "usage_monthly": 4.5 }),
    ));
    let rows: Vec<(String, f64)> = lines
        .iter()
        .map(|l| match l {
            MetricLine::Values { label, values, .. } => (label.clone(), values[0].number),
            other => panic!("unexpected {other:?}"),
        })
        .collect();
    assert_eq!(
        rows,
        [
            ("Today".to_string(), 0.0),
            ("This Week".to_string(), 1.25),
            ("This Month".to_string(), 4.5)
        ]
    );
}

#[test]
fn key_limit_without_a_numeric_remaining_amount_is_hidden_and_logged() {
    crate::test_support::install_capture_host();
    for payload in [
        json!({ "is_free_tier": false, "usage": 2, "limit": 5 }),
        json!({ "limit": 5, "limit_remaining": "many" }),
    ] {
        diagnostic_gate::clear(mapper::MISSING_LIMIT_REMAINING_KEY);
        let (_, lines) = mapper::key_metrics(&object(payload));
        assert!(
            !lines.iter().any(|l| l.label() == "Key Limit"),
            "a missing remaining amount is not a measured zero"
        );
        assert!(crate::test_support::captured_logs()
            .iter()
            .any(|l| l.contains("[plugin:openrouter]")
                && l.contains("key limit reported without a remaining amount")));
    }
}

#[test]
fn bearer_header_timeout_and_endpoints_match_swift() {
    let dir = tempfile::tempdir().unwrap();
    let cfg = dir.path().join("openrouter.json");
    std::fs::write(&cfg, r#"{"apiKey":"sk-or-test"}"#).unwrap();
    let client = Arc::new(MockClient::new(|req| {
        if req.url == CREDITS_URL {
            json_ok(json!({ "data": { "total_credits": 100, "total_usage": 40 } }))
        } else {
            json_ok(json!({ "data": { "is_free_tier": false, "usage_daily": 0.5 } }))
        }
    }));
    let provider = OpenRouterProvider::new(spec_with_paths(vec![cfg]), client.clone());
    let snap = provider.refresh(&RefreshContext::new(Scope::Full));
    assert_eq!(snap.plan.as_deref(), Some("Pay as you go"));
    assert_eq!(snap.error_category, None);
    for label in ["Credits", "Balance", "Today"] {
        assert!(snap.lines.iter().any(|l| l.label() == label), "{label}");
    }
    let requests = client.requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].url, "https://openrouter.ai/api/v1/credits");
    assert_eq!(requests[1].url, "https://openrouter.ai/api/v1/key");
    for req in requests.iter() {
        assert_eq!(req.method, "GET");
        assert_eq!(req.timeout, Duration::from_secs(15));
        assert!(req
            .headers
            .contains(&("Authorization".to_string(), "Bearer sk-or-test".to_string())));
        assert!(req
            .headers
            .contains(&("Accept".to_string(), "application/json".to_string())));
    }
}

#[test]
fn key_endpoint_transport_failure_keeps_the_credits_rows() {
    let dir = tempfile::tempdir().unwrap();
    let cfg = dir.path().join("openrouter.json");
    std::fs::write(&cfg, r#"{"apiKey":"sk-or-test"}"#).unwrap();
    let client = Arc::new(MockClient::new(|req| {
        if req.url == CREDITS_URL {
            json_ok(json!({ "data": { "total_credits": 100, "total_usage": 40 } }))
        } else {
            Err(HttpError::Transport("boom".into()))
        }
    }));
    let snap = OpenRouterProvider::new(spec_with_paths(vec![cfg]), client)
        .refresh(&RefreshContext::new(Scope::Full));
    assert!(!snap.is_error());
    assert!(snap.lines.iter().any(|l| l.label() == "Balance"));
}

#[test]
fn failure_messages_and_categories_match_swift() {
    let dir = tempfile::tempdir().unwrap();
    let cfg = dir.path().join("openrouter.json");
    std::fs::write(&cfg, r#"{"apiKey":"sk-or-test"}"#).unwrap();
    let message = |snap: &crate::model::ProviderSnapshot| match &snap.lines[0] {
        MetricLine::Badge { text, .. } => text.clone(),
        other => panic!("unexpected {other:?}"),
    };
    let run = |client: MockClient| {
        OpenRouterProvider::new(spec_with_paths(vec![cfg.clone()]), Arc::new(client))
            .refresh(&RefreshContext::new(Scope::Full))
    };
    let snap = run(MockClient::new(|_| Err(HttpError::Transport("x".into()))));
    assert_eq!(
        message(&snap),
        "Couldn't reach OpenRouter. Check your connection."
    );
    assert_eq!(snap.error_category, Some(ErrorCategory::Network));
    let snap = run(MockClient::new(|_| {
        Ok(Response {
            status: 503,
            headers: Vec::new(),
            body: Vec::new(),
        })
    }));
    assert_eq!(message(&snap), "OpenRouter request failed (HTTP 503).");
    assert_eq!(snap.error_category, Some(ErrorCategory::Http5xx));
    let snap = run(MockClient::new(|_| {
        Ok(Response {
            status: 200,
            headers: Vec::new(),
            body: b"[]".to_vec(),
        })
    }));
    assert_eq!(
        message(&snap),
        "OpenRouter usage data unavailable. Try again later."
    );
    assert_eq!(snap.error_category, Some(ErrorCategory::Decoding));
    let snap = run(MockClient::new(|_| {
        Ok(Response {
            status: 401,
            headers: Vec::new(),
            body: b"{}".to_vec(),
        })
    }));
    assert_eq!(
        message(&snap),
        "OpenRouter API key invalid. Check your key at openrouter.ai/keys."
    );
}
