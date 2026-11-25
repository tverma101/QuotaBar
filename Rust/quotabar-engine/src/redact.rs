//! Log redaction. One implementation for macOS and Windows: the union of the macOS `LogRedaction`
//! rules and the Windows plugin host's (`windows/crates/quotabar-core/src/plugin_engine/host_api.rs`),
//! with every pattern compiled once instead of per call.
//!
//! Every engine log line passes through [`redact_log_message`] (see `host::log`). Code that logs a URL
//! or a response body must pre-redact it with [`redact_url`] / [`body_preview`], which also cover the
//! query-parameter and JSON-key surfaces the message pass deliberately skips.

use regex_lite::{Captures, Regex};
use std::sync::OnceLock;

/// Mask a sensitive value as `first4...last4`, or `[REDACTED]` when too short to mask safely.
pub fn redact_value(value: &str) -> String {
    let count = value.chars().count();
    if count <= 12 {
        return "[REDACTED]".to_string();
    }
    let first: String = value.chars().take(4).collect();
    let last: String = value.chars().skip(count - 4).collect();
    format!("{first}...{last}")
}

const URL_SENSITIVE_PARAMS: &[&str] = &[
    "key", "api_key", "apikey", "token", "access_token", "secret", "password", "auth", "authorization",
    "bearer", "credential", "user", "user_id", "userid", "account_id", "accountid", "profilearn",
    "profile_arn", "email", "login", "cookie", "sid", "sapisid",
];

const JSON_SENSITIVE_KEYS: &[&str] = &[
    "name", "password", "token", "access_token", "refresh_token", "secret", "api_key", "apiKey",
    "authorization", "bearer", "credential", "session_token", "sessionToken", "auth_token", "authToken",
    "id_token", "idToken", "accessToken", "refreshToken", "user_id", "userId", "account_id", "accountId",
    "team_id", "teamId", "org_id", "orgId", "account_display_name", "accountDisplayName", "payment_id",
    "paymentId", "profile_arn", "profileArn", "email", "login", "username", "rpc_token", "simpleToken",
    "analytics_tracking_id", "uuid",
];

struct Patterns {
    account_path: Regex,
    cookie_pair: Regex,
    jwt_body: Regex,
    jwt_message: Regex,
    api_key_quoted: Regex,
    api_key_bare: Regex,
    devin_session: Regex,
    email: Regex,
    account_eq: Regex,
    path: Regex,
    json_keys: Vec<(&'static str, Regex)>,
}

fn patterns() -> &'static Patterns {
    static PATTERNS: OnceLock<Patterns> = OnceLock::new();
    PATTERNS.get_or_init(|| {
        let re = |p: &str| Regex::new(p).expect("static redaction pattern");
        Patterns {
            account_path: re(r"(?P<prefix>/accounts/)(?P<value>[^/?#]+)"),
            cookie_pair: re(
                r"(?i)(__Secure-1PSIDTS|__Secure-1PAPISID|__Secure-3PSID|__Secure-1PSID|SAPISID|APISID|HSID|SSID|SIDCC|NID|SID)=([^\s;]+)",
            ),
            jwt_body: re(r"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*(?:\.[A-Za-z0-9_-]+){1,3}"),
            jwt_message: re(r"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"),
            api_key_quoted: re(r#"["']?(sk-|pk-|api_|key_|secret_)[A-Za-z0-9_-]{12,}["']?"#),
            api_key_bare: re(r"(sk-|pk-|api_|key_|secret_)[A-Za-z0-9_-]{12,}"),
            devin_session: re(r#"devin-session-token\$[^\s"',}\]]+"#),
            email: re(r"[A-Za-z0-9._%+-]+@(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}"),
            account_eq: re(r"(account=)([^,\s]+)"),
            path: re(r#"(/(?:Users|home|opt|private|var|tmp|Applications)/[^\s"')]+|[A-Za-z]:\\Users\\[^\s"')]+)"#),
            json_keys: JSON_SENSITIVE_KEYS
                .iter()
                .map(|key| (*key, re(&format!(r#""{}":\s*"([^"]+)""#, regex_lite::escape(key)))))
                .collect(),
        }
    })
}

fn mask_whole(re: &Regex, input: &str) -> String {
    re.replace_all(input, |c: &Captures| redact_value(&c[0])).into_owned()
}

/// Redact sensitive query parameters and `/accounts/<id>` path segments in a URL.
pub fn redact_url(url: &str) -> String {
    let p = patterns();
    let url = p
        .account_path
        .replace_all(url, |c: &Captures| format!("{}{}", &c["prefix"], redact_value(&c["value"])))
        .into_owned();
    let Some(query_start) = url.find('?') else { return url };
    let (base, query) = url.split_at(query_start + 1);
    let params: Vec<String> = query
        .split('&')
        .map(|param| match param.split_once('=') {
            Some((name, value)) => {
                let lower = name.to_lowercase();
                if !value.is_empty() && URL_SENSITIVE_PARAMS.iter().any(|s| lower.contains(s)) {
                    format!("{name}={}", redact_value(value))
                } else {
                    param.to_string()
                }
            }
            None => param.to_string(),
        })
        .collect();
    format!("{base}{}", params.join("&"))
}

/// Redact secrets, identities and filesystem paths in a response body. Redact before truncating so a
/// secret straddling the cut is still caught intact.
pub fn redact_body(body: &str) -> String {
    let p = patterns();
    let mut result = p
        .cookie_pair
        .replace_all(body, |c: &Captures| format!("{}={}", &c[1], redact_value(&c[2])))
        .into_owned();
    result = mask_whole(&p.jwt_body, &result);
    result = p
        .api_key_quoted
        .replace_all(&result, |c: &Captures| redact_value(c[0].trim_matches(|ch| ch == '"' || ch == '\'')))
        .into_owned();
    result = mask_whole(&p.devin_session, &result);
    for (key, re) in &p.json_keys {
        result = re
            .replace_all(&result, |c: &Captures| format!("\"{key}\": \"{}\"", redact_value(&c[1])))
            .into_owned();
    }
    result = mask_whole(&p.email, &result);
    p.path.replace_all(&result, "[PATH]").into_owned()
}

/// Redacted, UTF-8-safe preview of at most `limit` bytes with the original byte count appended.
pub fn body_preview(body: &str, limit: usize) -> String {
    let redacted = redact_body(body);
    if redacted.len() <= limit {
        return redacted;
    }
    let cut: String = redacted.char_indices().take_while(|(i, _)| *i < limit).map(|(_, c)| c).collect();
    format!("{cut}... ({} bytes total)", body.len())
}

/// Lightweight last line of defense applied to every engine log line.
pub fn redact_log_message(message: &str) -> String {
    let p = patterns();
    let mut result = p
        .cookie_pair
        .replace_all(message, |c: &Captures| format!("{}={}", &c[1], redact_value(&c[2])))
        .into_owned();
    result = mask_whole(&p.email, &result);
    result = mask_whole(&p.jwt_message, &result);
    result = mask_whole(&p.api_key_bare, &result);
    result = mask_whole(&p.devin_session, &result);
    result = p
        .account_eq
        .replace_all(&result, |c: &Captures| format!("{}{}", &c[1], redact_value(&c[2])))
        .into_owned();
    p.path.replace_all(&result, "[PATH]").into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn masks_values() {
        assert_eq!(redact_value("short"), "[REDACTED]");
        assert_eq!(redact_value("abcdefghijklmnop"), "abcd...mnop");
    }

    #[test]
    fn redacts_url_query_and_account_paths() {
        assert_eq!(
            redact_url("https://x.test/v1/accounts/acct_1234567890abc/usage?api_key=sk-abcdefghijklmnop&day=1"),
            "https://x.test/v1/accounts/acct...0abc/usage?api_key=sk-a...mnop&day=1"
        );
    }

    #[test]
    fn redacts_body_keys_and_paths_before_truncating() {
        let body = r#"{"apiKey": "sk-ws-01-abcdefghijklmnopqrstuvwxyz", "path": "/Users/someone/x"}"#;
        let out = body_preview(body, 500);
        assert!(!out.contains("abcdefghijklmnopqrstuvwxyz"), "{out}");
        assert!(out.contains("[PATH]"), "{out}");
    }

    #[test]
    fn redacts_messages() {
        let out = redact_log_message("token eyJabc.def.ghi for a@b.co at /Users/me/file account=12345");
        assert!(!out.contains("eyJabc.def.ghi"));
        assert!(!out.contains("/Users/me"));
        assert!(out.contains("account=[REDACTED]"));
    }
}
