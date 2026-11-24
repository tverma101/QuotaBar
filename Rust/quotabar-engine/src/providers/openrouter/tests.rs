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
    Ok(Response { status: 200, headers: Vec::new(), body: serde_json::to_vec(&value).unwrap() })
}

#[test]
fn credits_and_key_mappers_cover_all_cases() {
    let data = json!({ "total_credits": 277.47, "total_usage": 178.20 }).as_object().unwrap().clone();
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

    let zero = mapper::credits_lines(json!({"total_credits": 0, "total_usage": 0}).as_object().unwrap());
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
    if let MetricLine::Progress { label, used, limit, .. } = &key_lines[3] {
        assert_eq!(label, "Key Limit");
        assert_eq!(*used, 2.0);
        assert_eq!(*limit, 5.0);
    }

    diagnostic_gate::clear(mapper::MISSING_LIMIT_REMAINING_KEY);
    let (_, omitted) = mapper::key_metrics(json!({"is_free_tier": false, "usage": 2, "limit": 5}).as_object().unwrap());
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
            Ok(Response { status: 403, headers: Vec::new(), body: b"{}".to_vec() })
        } else {
            json_ok(json!({ "data": { "is_free_tier": false, "usage_daily": 0.5, "usage_weekly": 2.0 } }))
        }
    }));
    let p_partial = OpenRouterProvider::new(spec_with_paths(vec![cfg.clone()]), partial_client);
    let snap = p_partial.refresh(&RefreshContext::new(Scope::Full));
    assert_eq!(snap.error_category, None);
    assert!(snap.lines.iter().any(|l| l.label() == "Today"));
    assert!(!snap.lines.iter().any(|l| l.label() == "Balance"));

    let bad_client = Arc::new(MockClient::new(|_| Ok(Response { status: 401, headers: Vec::new(), body: b"{}".to_vec() })));
    let p_bad = OpenRouterProvider::new(spec_with_paths(vec![cfg.clone()]), bad_client);
    assert_eq!(p_bad.refresh(&RefreshContext::new(Scope::Full)).error_category, Some(ErrorCategory::AuthInvalid));

    let gated_empty = Arc::new(MockClient::new(|req| {
        if req.url == CREDITS_URL {
            Ok(Response { status: 403, headers: Vec::new(), body: b"{}".to_vec() })
        } else {
            json_ok(json!({ "data": {} }))
        }
    }));
    let p_gated = OpenRouterProvider::new(spec_with_paths(vec![cfg]), gated_empty);
    assert_ne!(p_gated.refresh(&RefreshContext::new(Scope::Full)).error_category, Some(ErrorCategory::AuthInvalid));
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
    assert_eq!(provider.refresh(&RefreshContext::new(Scope::Full)).error_category, Some(ErrorCategory::NotLoggedIn));
    let _ = HashMap::<String, String>::new();
    let _ = MetricKind::Dollars;
}
