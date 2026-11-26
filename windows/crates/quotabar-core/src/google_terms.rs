//! Build-time policy for Google-owned services.
//!
//! Google's Antigravity Additional Terms (§6) and the Antigravity and Gemini CLI FAQs treat
//! third-party software that accesses those services — reusing their OAuth login, calling their
//! internal endpoints, wrapping `agy`, scraping gemini.google.com with browser cookies, or presenting
//! itself as the Antigravity client — as a breach that can suspend the user's Google account.
//!
//! Public QuotaBar builds therefore read only the Antigravity token history already on local disk.
//! The plugin host enforces that here, below the plugins, so a plugin bug cannot reach Google.
//! A private owner build opts back in by compiling with `QUOTABAR_GOOGLE_PRIVATE_ACCESS=1`.

/// Whether this binary may read Google credentials or query Antigravity's live quota sources.
pub const PRIVATE_GOOGLE_ACCESS: bool = is_one(option_env!("QUOTABAR_GOOGLE_PRIVATE_ACCESS"));

const fn is_one(value: Option<&str>) -> bool {
    match value {
        Some(value) => matches!(value.as_bytes(), [b'1']),
        None => false,
    }
}

/// Error text a plugin sees when the host refuses a Google-restricted operation.
pub const BLOCKED_MESSAGE: &str =
    "Blocked in public QuotaBar builds to follow Google's Antigravity and Gemini terms";

/// Plugins whose live-limit sources go through Antigravity's login or local language server.
pub fn is_antigravity_plugin(plugin_id: &str) -> bool {
    plugin_id == "antigravity" || plugin_id.starts_with("antigravity-")
}

/// Plugins that have no function without Google-restricted access, so public builds do not ship them.
pub const GOOGLE_ONLY_PLUGIN_IDS: &[&str] = &["antigravity-ide", "gemini-apps"];

/// Hosts that serve Google's internal Antigravity/Gemini backends, Google OAuth token exchange, or the
/// Gemini web app. Public builds never send requests to them.
pub fn is_restricted_google_url(url: &str) -> bool {
    let Some(host) = url_host(url) else { return false };
    host == "oauth2.googleapis.com"
        || host == "gemini.google.com"
        || host == "cloudcode-pa.googleapis.com"
        || host.ends_with("-cloudcode-pa.googleapis.com")
        || host.ends_with(".cloudcode-pa.googleapis.com")
}

/// Cookie hosts that would carry a Google account session.
pub fn is_google_cookie_host(host: &str) -> bool {
    let host = host.trim_start_matches('.').to_ascii_lowercase();
    host == "google.com" || host.ends_with(".google.com")
}

/// Public builds block the operation; owner builds allow it.
pub fn blocks(restricted: bool) -> bool {
    restricted && !PRIVATE_GOOGLE_ACCESS
}

fn url_host(url: &str) -> Option<String> {
    let rest = url.split_once("://").map(|(_, rest)| rest)?;
    let authority = rest.split(['/', '?', '#']).next()?;
    let host_port = authority.rsplit_once('@').map(|(_, host)| host).unwrap_or(authority);
    let host = if host_port.starts_with('[') {
        host_port.split(']').next().map(|h| h.trim_start_matches('['))?
    } else {
        host_port.split(':').next()?
    };
    Some(host.trim_end_matches('.').to_ascii_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn public_build_is_the_default() {
        // Tests are compiled without QUOTABAR_GOOGLE_PRIVATE_ACCESS, like every public build.
        assert!(!PRIVATE_GOOGLE_ACCESS);
        assert!(blocks(true));
        assert!(!blocks(false));
    }

    #[test]
    fn restricted_urls_cover_cloud_code_oauth_and_gemini_web() {
        for url in [
            "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota",
            "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
            "https://oauth2.googleapis.com/token",
            "https://GEMINI.google.com/_/BardChatUi/data/batchexecute",
            "https://user@cloudcode-pa.googleapis.com:443/x",
        ] {
            assert!(is_restricted_google_url(url), "{url}");
        }
        for url in [
            "https://generativelanguage.googleapis.com/v1beta/models",
            "https://api.github.com/repos/x/y",
            "http://127.0.0.1:4242/x",
            "https://notgemini.google.com.example.com/",
            "not a url",
        ] {
            assert!(!is_restricted_google_url(url), "{url}");
        }
    }

    #[test]
    fn google_cookie_hosts_and_plugins() {
        assert!(is_google_cookie_host(".google.com"));
        assert!(is_google_cookie_host("gemini.google.com"));
        assert!(!is_google_cookie_host("cursor.com"));
        assert!(!is_google_cookie_host("notgoogle.com"));
        assert!(is_antigravity_plugin("antigravity"));
        assert!(is_antigravity_plugin("antigravity-cli"));
        assert!(!is_antigravity_plugin("claude"));
    }
}
