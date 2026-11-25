use super::auth::{
    yaml_value, CopilotAuthError, CopilotAuthStore, CREDENTIALS_UNREADABLE_MSG,
    GH_KEYCHAIN_SERVICE, INVALID_CREDENTIALS_MSG, NOT_LOGGED_IN_MSG, TOKEN_INVALID_MSG,
};
use super::org::{org_logins, OrgBillingState, OrgStateStore};
use super::*;
use crate::context::{RefreshContext, Scope};
use crate::host::{
    self, Host, SecureDeleteOutcome, SecureDeleteRequest, SecureReadOutcome, SecureReadRequest,
    SecureWriteOutcome, SecureWriteRequest,
};
use crate::http::{mock::FnClient as MockClient, HttpError, Request, Response};
use crate::model::{MetricKind, MetricLine};
use serde_json::json;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

struct TestKeychainHost {
    response: Arc<dyn Fn(&SecureReadRequest) -> SecureReadOutcome + Send + Sync>,
    reads: Mutex<usize>,
}

impl TestKeychainHost {
    fn new(f: impl Fn(&SecureReadRequest) -> SecureReadOutcome + Send + Sync + 'static) -> Self {
        TestKeychainHost {
            response: Arc::new(f),
            reads: Mutex::new(0),
        }
    }
    fn read_count(&self) -> usize {
        *self.reads.lock().unwrap()
    }
}

impl Host for TestKeychainHost {
    fn env_var(&self, _name: &str) -> Option<String> {
        None
    }
    fn log_level(&self) -> host::LogLevel {
        host::LogLevel::Error
    }
    fn log(&self, _level: host::LogLevel, _tag: &str, _message: &str) {}
    fn secure_read(&self, request: &SecureReadRequest) -> SecureReadOutcome {
        *self.reads.lock().unwrap() += 1;
        (self.response)(request)
    }
    fn secure_write(&self, _request: &SecureWriteRequest) -> SecureWriteOutcome {
        SecureWriteOutcome::Written
    }
    fn secure_delete(&self, _request: &SecureDeleteRequest) -> SecureDeleteOutcome {
        SecureDeleteOutcome::Deleted
    }
    fn secure_exists(&self, _service: &str) -> Option<bool> {
        None
    }
}

#[derive(Default)]
struct MemoryOrgStore {
    state: Mutex<OrgBillingState>,
}

impl OrgStateStore for MemoryOrgStore {
    fn load(&self) -> OrgBillingState {
        self.state.lock().unwrap().clone()
    }
    fn save(&self, state: &OrgBillingState) {
        *self.state.lock().unwrap() = state.clone();
    }
}

fn paid_body() -> Vec<u8> {
    serde_json::to_vec(&json!({
        "copilot_plan": "pro",
        "quota_reset_date": "2026-08-01T00:00:00Z",
        "quota_snapshots": {
            "premium_interactions": { "entitlement": 300, "remaining": 123, "percent_remaining": 41.0, "unlimited": false, "overage_permitted": false },
            "chat": { "entitlement": -1, "remaining": -1, "unlimited": true },
            "completions": { "entitlement": -1, "remaining": -1, "unlimited": true }
        }
    }))
    .unwrap()
}

fn org_managed_body(credits_used: Option<f64>) -> Vec<u8> {
    let mut prem = json!({ "entitlement": 0, "remaining": 0, "overage_permitted": true });
    if let Some(used) = credits_used {
        prem["credits_used"] = json!(used);
    }
    serde_json::to_vec(&json!({
        "copilot_plan": "business",
        "token_based_billing": true,
        "quota_snapshots": { "premium_interactions": prem }
    }))
    .unwrap()
}

fn org_summary_body() -> Vec<u8> {
    serde_json::to_vec(&json!({
        "organization": "acme",
        "usageItems": [
            { "product": "copilot", "unitType": "ai-credits", "grossQuantity": 298.698546, "netAmount": 0.0 },
            { "product": "actions", "unitType": "minutes", "grossQuantity": 500.0, "netAmount": 12.0 }
        ]
    }))
    .unwrap()
}

fn ok_resp(body: Vec<u8>) -> Result<Response, HttpError> {
    Ok(Response {
        status: 200,
        headers: Vec::new(),
        body,
    })
}

#[test]
fn editor_config_picks_github_dot_com_and_yaml_parses_user() {
    let dir = tempfile::tempdir().unwrap();
    let apps = dir.path().join("apps.json");
    let hosts = dir.path().join("hosts.json");
    let gh = dir.path().join("hosts.yml");

    // Enterprise-only editor config returns None without failing.
    std::fs::write(
        &apps,
        r#"{ "ghe.corp.example:Iv1.x": { "oauth_token": "gho_ent" } }"#,
    )
    .unwrap();
    let store = CopilotAuthStore {
        editor_apps_path: apps.clone(),
        editor_hosts_path: hosts.clone(),
        gh_hosts_path: gh.clone(),
    };
    let host_none = Arc::new(TestKeychainHost::new(|_| SecureReadOutcome::NotFound));
    host::with_test_host(host_none, || {
        assert_eq!(store.load_token(None).unwrap(), None);
    });

    // Multi-host picks github.com.
    std::fs::write(&apps, r#"{ "ghe.corp.example:Iv1.x": { "oauth_token": "gho_ent" }, "github.com:Iv1.y": { "oauth_token": "gho_dotcom" } }"#).unwrap();
    assert_eq!(
        store.load_token(None).unwrap().as_deref(),
        Some("gho_dotcom")
    );

    // Malformed editor file falls back if gh hosts.yml has token, else returns InvalidCredentials.
    std::fs::write(&apps, r#"{ "github.com": { "oauth_token": 7 } }"#).unwrap();
    assert_eq!(
        store.load_token(None),
        Err(CopilotAuthError::InvalidCredentials)
    );

    std::fs::write(&gh, "ghe.corp.example:\n    oauth_token: gho_ent\ngithub.com:\n    users:\n        octocat:\n    user: octocat\n    oauth_token: gho_cli\n").unwrap();
    assert_eq!(
        yaml_value(&std::fs::read_to_string(&gh).unwrap(), "user", "github.com").as_deref(),
        Some("octocat")
    );
    assert_eq!(store.load_token(None).unwrap().as_deref(), Some("gho_cli"));
}

#[test]
fn keychain_permission_refusal_and_service_only_guards() {
    let dir = tempfile::tempdir().unwrap();
    let store = CopilotAuthStore {
        editor_apps_path: dir.path().join("apps.json"),
        editor_hosts_path: dir.path().join("hosts.json"),
        gh_hosts_path: dir.path().join("hosts.yml"),
    };
    let h = Arc::new(TestKeychainHost::new(|req| {
        assert_eq!(req.service, GH_KEYCHAIN_SERVICE);
        SecureReadOutcome::InteractionRequired
    }));
    host::with_test_host(h.clone(), || {
        let p = CopilotProvider::new(
            store.clone(),
            Arc::new(MockClient::new(|_| unreachable!())),
            Arc::new(MemoryOrgStore::default()),
        );
        assert!(p.has_local_credentials());
        let snap = p.refresh(&RefreshContext::new(Scope::Full));
        assert_eq!(snap.error_category, Some(ErrorCategory::CredentialAccess));
    });
    // Single refusal must not re-try secondary keychain items.
    assert_eq!(h.read_count(), 2); // 1 for has_local_credentials + 1 for refresh

    // Present unreadable gh hosts.yml must NOT do a service-only keychain lookup.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::write(&store.gh_hosts_path, "github.com:\n  user: octo\n").unwrap();
        std::fs::set_permissions(&store.gh_hosts_path, std::fs::Permissions::from_mode(0o000))
            .unwrap();
        let h2 = Arc::new(TestKeychainHost::new(|_| {
            panic!("must not query service-only keychain when hosts.yml is unreadable")
        }));
        host::with_test_host(h2, || {
            let err = store.load_token(None).unwrap_err();
            assert_eq!(err, CopilotAuthError::CredentialsUnreadable);
            assert_eq!(err.message(), CREDENTIALS_UNREADABLE_MSG);
            assert_eq!(
                CopilotAuthError::InvalidCredentials.message(),
                INVALID_CREDENTIALS_MSG
            );
        });
        std::fs::set_permissions(&store.gh_hosts_path, std::fs::Permissions::from_mode(0o644))
            .unwrap();
    }
}

#[test]
fn maps_paid_and_org_managed_seats_and_paginates_org_discovery() {
    let dir = tempfile::tempdir().unwrap();
    let apps = dir.path().join("apps.json");
    std::fs::write(
        &apps,
        r#"{ "github.com": { "oauth_token": "gho_editor" } }"#,
    )
    .unwrap();
    let store = CopilotAuthStore {
        editor_apps_path: apps,
        editor_hosts_path: dir.path().join("h.json"),
        gh_hosts_path: dir.path().join("gh.yml"),
    };

    // 401 -> authExpired, 403 -> http4xx
    let p401 = CopilotProvider::new(
        store.clone(),
        Arc::new(MockClient::new(|_| {
            Ok(Response {
                status: 401,
                headers: Vec::new(),
                body: Vec::new(),
            })
        })),
        Arc::new(MemoryOrgStore::default()),
    );
    let s401 = p401.refresh(&RefreshContext::new(Scope::Full));
    assert_eq!(s401.error_category, Some(ErrorCategory::AuthExpired));
    assert!(
        matches!(s401.lines.first(), Some(MetricLine::Badge { text, .. }) if text == TOKEN_INVALID_MSG)
    );

    // Paid plan
    let p_paid = CopilotProvider::new(
        store.clone(),
        Arc::new(MockClient::new(|req: &Request| {
            assert_eq!(
                req.headers
                    .iter()
                    .find(|(k, _)| k == "Authorization")
                    .map(|(_, v)| v.as_str()),
                Some("token gho_editor")
            );
            ok_resp(paid_body())
        })),
        Arc::new(MemoryOrgStore::default()),
    );
    let s_paid = p_paid.refresh(&RefreshContext::new(Scope::Full));
    assert_eq!(s_paid.plan.as_deref(), Some("Pro"));
    assert_eq!(s_paid.lines.len(), 1);

    // Org discovery with pagination + personal credits preserved
    let requests = Arc::new(Mutex::new(Vec::<String>::new()));
    let reqs_c = requests.clone();
    let org_store = Arc::new(MemoryOrgStore::default());
    let client = Arc::new(MockClient::new(move |req: &Request| {
        reqs_c.lock().unwrap().push(req.url.clone());
        if req.url == client::USAGE_URL {
            ok_resp(org_managed_body(Some(2111.0)))
        } else if req.url == client::USER_ORGS_URL {
            Ok(Response {
                status: 200,
                headers: vec![(
                    "Link".into(),
                    r#"<https://api.github.com/user/orgs?per_page=100&page=2>; rel="next""#.into(),
                )],
                body: serde_json::to_vec(&json!([{"login": "member-0"}])).unwrap(),
            })
        } else if req.url.contains("page=2") {
            ok_resp(serde_json::to_vec(&json!([{"login": "acme"}])).unwrap())
        } else if req.url.contains("/orgs/member-0/") {
            Ok(Response {
                status: 404,
                headers: Vec::new(),
                body: Vec::new(),
            })
        } else {
            ok_resp(org_summary_body())
        }
    }));
    let p_org = CopilotProvider::new(store.clone(), client.clone(), org_store.clone());
    let mut ctx = RefreshContext::new(Scope::Full);
    ctx.now = 1_800_000_000.0;
    let s_org = p_org.refresh(&ctx);
    assert_eq!(s_org.plan.as_deref(), Some("Business"));
    assert!(s_org.lines.iter().any(|l| l.label() == "Credits"));
    assert!(s_org.lines.iter().any(|l| l.label() == "Org Credits"));
    assert!(s_org.lines.iter().any(|l| l.label() == "Org Spend"));
    assert_eq!(org_store.load().billing_org.as_deref(), Some("acme"));

    // Cached org skips /user/orgs
    requests.lock().unwrap().clear();
    let _ = p_org.refresh(&ctx);
    assert!(!requests
        .lock()
        .unwrap()
        .iter()
        .any(|u| u.contains("/user/orgs")));

    // Rate-limit header sets cooldown
    let rl_store = Arc::new(MemoryOrgStore::default());
    let rl_client = Arc::new(MockClient::new(|req| {
        if req.url == client::USAGE_URL {
            ok_resp(org_managed_body(None))
        } else {
            Ok(Response {
                status: 429,
                headers: vec![("Retry-After".into(), "120".into())],
                body: Vec::new(),
            })
        }
    }));
    let p_rl = CopilotProvider::new(store, rl_client, rl_store.clone());
    let _ = p_rl.refresh(&ctx);
    assert!(rl_store.load().rate_limit_retry_after.unwrap() >= ctx.now + 119.0);
    let _ = (
        NOT_LOGGED_IN_MSG,
        HashMap::<String, String>::new(),
        MetricKind::Count,
        org_logins(b"[]"),
    );
}
