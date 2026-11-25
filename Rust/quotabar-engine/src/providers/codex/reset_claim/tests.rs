use super::*;
use crate::context::Scope;
use crate::http::mock::MockClient;

fn config(home: &std::path::Path, expected: Option<&str>) -> ClaimConfig {
    std::fs::write(
        home.join("auth.json"),
        r#"{"tokens":{"access_token":"token-123","account_id":"acct-456"}}"#,
    )
    .unwrap();
    ClaimConfig {
        provider_id: "codex".into(),
        expected_identity_key: expected.map(str::to_lowercase),
        candidate_auth_homes: vec![home.to_string_lossy().into_owned()],
        additional_auth_homes: Vec::new(),
        allows_keychain_fallback: false,
    }
}

fn write_auth(home: &std::path::Path, token: &str, account: &str) {
    std::fs::create_dir_all(home).unwrap();
    std::fs::write(
        home.join("auth.json"),
        format!(r#"{{"tokens":{{"access_token":"{token}","account_id":"{account}"}}}}"#),
    )
    .unwrap();
}

fn request(expiry: f64, redeem: &str) -> ClaimRequest {
    ClaimRequest {
        expiry,
        redeem_request_id: redeem.into(),
        credit_id: None,
        owner_identity: None,
        is_retry: false,
        automatic: false,
    }
}

fn list_body(id: &str, expiry: f64) -> String {
    format!(r#"{{"credits":[{{"id":"{id}","status":"available","expires_at":{expiry}}}]}}"#)
}

fn context(now: f64) -> RefreshContext {
    let mut ctx = RefreshContext::new(Scope::Full);
    ctx.now = now;
    ctx.is_manual = true;
    ctx
}

#[test]
fn matches_the_credit_by_expiry_and_ignores_unavailable_ones() {
    let body = serde_json::json!({
        "credits": [
            {"id": "other", "status": "available", "expires_at": 1_800_000_999.0},
            {"id": "used", "status": "redeemed", "expires_at": 1_800_000_000.0},
            {"id": "target", "status": "available", "expires_at": "2027-01-15T08:00:00Z"}
        ]
    });
    let object = body.as_object().unwrap();
    assert_eq!(credit_id_in(object, 1_800_000_000.0), Some("target".into()));
    assert_eq!(credit_id_in(object, 1_800_000_000.5), Some("target".into()));
    assert_eq!(credit_id_in(object, 1_800_000_500.0), None);
}

#[test]
fn consume_codes_map_to_the_popover_outcome() {
    for (code, expected) in [
        ("reset", ResetClaimOutcome::Success),
        ("already_redeemed", ResetClaimOutcome::Success),
        ("nothing_to_reset", ResetClaimOutcome::NothingToReset),
        ("no_credit", ResetClaimOutcome::NoCredit),
        ("new", ResetClaimOutcome::Failed),
    ] {
        let response = Response {
            status: 200,
            headers: Vec::new(),
            body: serde_json::to_vec(&serde_json::json!({"code": code})).unwrap(),
        };
        assert_eq!(outcome_from_consume(&response), expected);
    }
    assert_eq!(
        outcome_from_consume(&Response {
            status: 500,
            headers: Vec::new(),
            body: Vec::new()
        }),
        ResetClaimOutcome::Failed
    );
}

#[test]
fn claim_matches_lists_and_consumes_the_selected_credit() {
    let dir = tempfile::tempdir().unwrap();
    let config = config(dir.path(), None);
    let http = MockClient::new(vec![
        MockClient::json(200, &list_body("target", 1_800_000_000.0)),
        MockClient::json(200, r#"{"code":"reset"}"#),
    ]);
    let result = claim_with_http(
        &config,
        &request(1_800_000_000.0, "claim-success"),
        &context(1_799_999_900.0),
        http.clone(),
    );
    assert_eq!(result.outcome, ResetClaimOutcome::Success);
    let requests = http.requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].method, "GET");
    assert_eq!(requests[0].url, super::super::client::RESET_CREDITS_URL);
    assert_eq!(
        requests[0]
            .headers
            .iter()
            .find(|(name, _)| name == "Authorization")
            .unwrap()
            .1,
        "Bearer token-123"
    );
    assert_eq!(requests[1].method, "POST");
    let body: Value = serde_json::from_slice(requests[1].body.as_deref().unwrap()).unwrap();
    assert_eq!(body["credit_id"], "target");
    assert_eq!(body["redeem_request_id"], "claim-success");
}

#[test]
fn a_replay_reuses_the_matched_credit_without_relisting() {
    let dir = tempfile::tempdir().unwrap();
    let config = config(dir.path(), None);
    let first = claim_with_http(
        &config,
        &request(1_800_000_000.0, "replay-key"),
        &context(1_799_999_900.0),
        MockClient::new(vec![
            MockClient::json(200, &list_body("target", 1_800_000_000.0)),
            MockClient::json(200, r#"{"code":"reset"}"#),
        ]),
    );
    assert_eq!(first.outcome, ResetClaimOutcome::Success);

    let http = MockClient::new(vec![MockClient::json(
        200,
        r#"{"code":"already_redeemed"}"#,
    )]);
    let second = claim_with_http(
        &config,
        &request(1_800_000_000.0, "replay-key"),
        &context(1_799_999_900.0),
        http.clone(),
    );
    assert_eq!(second.outcome, ResetClaimOutcome::Success);
    let requests = http.requests.lock().unwrap();
    assert_eq!(
        requests.len(),
        1,
        "the replay skips the GET and posts the original id"
    );
    let body: Value = serde_json::from_slice(requests[0].body.as_deref().unwrap()).unwrap();
    assert_eq!(body["credit_id"], "target");
}

#[test]
fn claim_falls_back_to_a_live_file_candidate_after_a_rejection() {
    let first = tempfile::tempdir().unwrap();
    let second = tempfile::tempdir().unwrap();
    write_auth(first.path(), "stale-token", "acct-old");
    write_auth(second.path(), "live-token", "acct-456");
    let config = ClaimConfig {
        provider_id: "codex-fallback".into(),
        expected_identity_key: None,
        candidate_auth_homes: vec![
            first.path().to_string_lossy().into_owned(),
            second.path().to_string_lossy().into_owned(),
        ],
        additional_auth_homes: Vec::new(),
        allows_keychain_fallback: false,
    };
    let http = MockClient::new(vec![
        MockClient::json(401, ""),
        MockClient::json(200, &list_body("target", 1_800_000_000.0)),
        MockClient::json(200, r#"{"code":"reset"}"#),
    ]);
    let result = claim_with_http(
        &config,
        &request(1_800_000_000.0, "fallback-key"),
        &context(1_799_999_900.0),
        http.clone(),
    );
    assert_eq!(result.outcome, ResetClaimOutcome::Success);
    let requests = http.requests.lock().unwrap();
    let consume = requests.last().unwrap();
    assert_eq!(
        consume
            .headers
            .iter()
            .find(|(name, _)| name == "Authorization")
            .unwrap()
            .1,
        "Bearer live-token"
    );
}

#[test]
fn consume_falls_back_only_within_the_originating_account() {
    let first = tempfile::tempdir().unwrap();
    let second = tempfile::tempdir().unwrap();
    write_auth(first.path(), "stale-token", "acct-A");
    write_auth(second.path(), "fresh-token", "acct-A");
    let config = ClaimConfig {
        provider_id: "codex-account-fallback".into(),
        expected_identity_key: None,
        candidate_auth_homes: vec![
            first.path().to_string_lossy().into_owned(),
            second.path().to_string_lossy().into_owned(),
        ],
        additional_auth_homes: Vec::new(),
        allows_keychain_fallback: false,
    };
    let http = MockClient::new(vec![
        MockClient::json(200, &list_body("target", 1_800_000_000.0)),
        MockClient::json(401, ""),
        MockClient::json(200, r#"{"code":"reset"}"#),
    ]);
    let result = claim_with_http(
        &config,
        &request(1_800_000_000.0, "account-fallback"),
        &context(1_799_999_900.0),
        http.clone(),
    );
    assert_eq!(result.outcome, ResetClaimOutcome::Success);
    let requests = http.requests.lock().unwrap();
    let posts: Vec<_> = requests
        .iter()
        .filter(|request| request.method == "POST")
        .collect();
    assert_eq!(posts.len(), 2);
    assert!(posts.iter().all(|request| {
        request.headers.iter().any(|(name, value)| {
            name == "ChatGPT-Account-Id" && value.eq_ignore_ascii_case("acct-A")
        })
    }));
}

#[test]
fn a_rejected_consume_never_switches_accounts() {
    let first = tempfile::tempdir().unwrap();
    let second = tempfile::tempdir().unwrap();
    write_auth(first.path(), "shared-token", "acct-A");
    write_auth(second.path(), "shared-token", "acct-B");
    let config = ClaimConfig {
        provider_id: "codex-no-switch".into(),
        expected_identity_key: None,
        candidate_auth_homes: vec![
            first.path().to_string_lossy().into_owned(),
            second.path().to_string_lossy().into_owned(),
        ],
        additional_auth_homes: Vec::new(),
        allows_keychain_fallback: false,
    };
    let http = MockClient::new(vec![
        MockClient::json(200, &list_body("target", 1_800_000_000.0)),
        MockClient::json(403, ""),
    ]);
    let result = claim_with_http(
        &config,
        &request(1_800_000_000.0, "no-switch"),
        &context(1_799_999_900.0),
        http.clone(),
    );
    assert_eq!(result.outcome, ResetClaimOutcome::Failed);
    let requests = http.requests.lock().unwrap();
    let posts: Vec<_> = requests
        .iter()
        .filter(|request| request.method == "POST")
        .collect();
    assert_eq!(
        posts.len(),
        1,
        "one rejected consume must not fall through to another account"
    );
}

#[test]
fn a_first_automatic_attempt_still_preflights_the_live_list() {
    let dir = tempfile::tempdir().unwrap();
    let config = config(dir.path(), Some("acct-456"));
    let mut automatic = request(1_800_000_000.0, "automatic-preflight");
    automatic.credit_id = Some("target".into());
    automatic.automatic = true;
    let http = MockClient::new(vec![
        MockClient::json(200, &list_body("target", 1_800_000_000.0)),
        MockClient::json(200, r#"{"code":"reset"}"#),
    ]);
    let result = claim_with_http(&config, &automatic, &context(1_799_999_950.0), http.clone());
    assert_eq!(result.outcome, ResetClaimOutcome::Success);
    let requests = http.requests.lock().unwrap();
    assert_eq!(
        requests.len(),
        2,
        "the first attempt validates the credit before posting"
    );
    assert_eq!(requests[0].method, "GET");
    assert_eq!(requests[1].method, "POST");
}

#[test]
fn a_vanished_automatic_credit_never_posts() {
    let dir = tempfile::tempdir().unwrap();
    let config = config(dir.path(), Some("acct-456"));
    let mut automatic = request(1_800_000_000.0, "automatic-vanished");
    automatic.credit_id = Some("target".into());
    automatic.automatic = true;
    let http = MockClient::new(vec![MockClient::json(
        200,
        &list_body("other", 1_800_000_000.0),
    )]);
    let result = claim_with_http(&config, &automatic, &context(1_799_999_950.0), http.clone());
    assert_eq!(result.outcome, ResetClaimOutcome::NoCredit);
    assert_eq!(
        http.requests.lock().unwrap().len(),
        1,
        "no POST without a live preflight match"
    );
}

#[test]
fn an_automatic_retry_replays_the_verified_account_without_preflight() {
    let dir = tempfile::tempdir().unwrap();
    let config = config(dir.path(), Some("acct-456"));
    let mut automatic = request(1_800_000_000.0, "automatic-retry");
    automatic.credit_id = Some("target".into());
    automatic.owner_identity = Some("acct-456".into());
    automatic.automatic = true;
    automatic.is_retry = true;
    let http = MockClient::new(vec![MockClient::json(
        200,
        r#"{"code":"already_redeemed"}"#,
    )]);
    let result = claim_with_http(&config, &automatic, &context(1_799_999_950.0), http.clone());
    assert_eq!(result.outcome, ResetClaimOutcome::Success);
    let requests = http.requests.lock().unwrap();
    assert_eq!(
        requests.len(),
        1,
        "a persisted retry posts straight to the idempotency ledger"
    );
    assert_eq!(requests[0].method, "POST");
}

#[test]
fn pre_cancelled_claim_does_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let config = config(dir.path(), None);
    let ctx = context(1_799_999_900.0);
    ctx.cancel.cancel();
    let result = claim_with_http(
        &config,
        &request(1_800_000_000.0, "pre-cancelled"),
        &ctx,
        MockClient::new(Vec::new()),
    );
    assert_eq!(result.outcome, ResetClaimOutcome::Cancelled);
}

#[test]
fn automatic_claim_rejects_past_and_early_credits_before_any_io() {
    let dir = tempfile::tempdir().unwrap();
    let config = config(dir.path(), None);
    let mut automatic = request(1_800_000_000.0, "automatic-window");
    automatic.credit_id = Some("target".into());
    automatic.is_retry = true;
    automatic.automatic = true;
    let past = claim_with_http(
        &config,
        &automatic,
        &context(1_800_000_001.0),
        MockClient::new(Vec::new()),
    );
    assert_eq!(past.outcome, ResetClaimOutcome::NoCredit);
    let early = claim_with_http(
        &config,
        &automatic,
        &context(1_799_999_000.0),
        MockClient::new(Vec::new()),
    );
    assert_eq!(early.outcome, ResetClaimOutcome::Cancelled);
}

#[test]
fn automatic_retry_rechecks_expiry_before_trying_another_credential() {
    let first = tempfile::tempdir().unwrap();
    let second = tempfile::tempdir().unwrap();
    write_auth(first.path(), "stale-token", "acct-a");
    write_auth(second.path(), "fresh-token", "acct-a");
    let config = ClaimConfig {
        provider_id: "codex-auto-expiry".into(),
        expected_identity_key: Some("acct-a".into()),
        candidate_auth_homes: vec![
            first.path().to_string_lossy().into_owned(),
            second.path().to_string_lossy().into_owned(),
        ],
        additional_auth_homes: Vec::new(),
        allows_keychain_fallback: false,
    };
    let expiry = 1_800_000_000.0;
    let mut automatic = request(expiry, "late-auth-rejection");
    automatic.credit_id = Some("target".into());
    automatic.owner_identity = Some("acct-a".into());
    automatic.is_retry = true;
    automatic.automatic = true;
    let http = MockClient::new(vec![MockClient::json(401, "")]);
    let times = std::cell::RefCell::new([expiry - 30.0, expiry - 1.0, expiry].into_iter());
    let result = claim_with_clock(
        &config,
        &automatic,
        &context(expiry - 30.0),
        http.clone(),
        &|| times.borrow_mut().next().unwrap(),
    );

    assert_eq!(result.outcome, ResetClaimOutcome::NoCredit);
    let requests = http.requests.lock().unwrap();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, "POST");
}

#[test]
fn available_credits_filters_unavailable_and_unsupported_rows() {
    let dir = tempfile::tempdir().unwrap();
    let config = config(dir.path(), None);
    let body = r#"{"credits":[
        {"id":"usable","status":"available","expires_at":1800000000.0},
        {"id":"used","status":"redeemed","expires_at":1800000000.0},
        {"id":"wrong-type","status":"available","reset_type":"other","expires_at":1800000000.0},
        {"id":"no-expiry","status":"available","expires_at":null}
    ]}"#;
    let http = MockClient::new(vec![MockClient::json(200, body)]);
    let result = available_credits_with_http(&config, &context(1_799_999_900.0), http).unwrap();
    assert_eq!(
        result.credits,
        vec![ResetCredit {
            id: "usable".into(),
            expires_at: 1_800_000_000.0
        }]
    );
    assert!(!result.auth_rejected);
}
