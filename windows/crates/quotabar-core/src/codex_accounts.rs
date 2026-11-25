use base64::Engine;
use base64::engine::general_purpose::{URL_SAFE, URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexHome {
    pub path: PathBuf,
    pub account_id: String,
}

fn normalize_account_id(value: &Value) -> Option<String> {
    let id = value.as_str()?.trim();
    (!id.is_empty() && id.len() <= 128
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_".contains(&b)))
        .then(|| id.to_ascii_lowercase())
}

fn token_account_id(token: &Value) -> Option<String> {
    let payload = token.as_str()?.split('.').nth(1)?;
    let bytes = URL_SAFE_NO_PAD.decode(payload).or_else(|_| URL_SAFE.decode(payload)).ok()?;
    let value: Value = serde_json::from_slice(&bytes).ok()?;
    normalize_account_id(value["https://api.openai.com/auth"].get("chatgpt_account_id")
        .filter(|value| !value.is_null()).unwrap_or(&value["chatgpt_account_id"]))
}

fn account_id_from_auth(text: &str) -> Option<String> {
    let auth: Value = serde_json::from_str(text.trim_start_matches('\u{feff}')).ok()?;
    let tokens = &auth["tokens"];
    if tokens["access_token"].as_str()?.trim().is_empty() {
        return None;
    }
    let declared = normalize_account_id(&tokens["account_id"]);
    let identity_token = token_account_id(&tokens["id_token"]);
    let access_token = token_account_id(&tokens["access_token"]);
    let identity = declared.as_ref().or(identity_token.as_ref())?;
    [declared.as_ref(), identity_token.as_ref(), access_token.as_ref()]
        .into_iter().flatten().all(|id| id == identity).then(|| identity.clone())
}

impl CodexHome {
    pub fn inspect(path: &Path) -> io::Result<Self> {
        let path = fs::canonicalize(path)?;
        let auth = fs::read_to_string(path.join("auth.json"))?;
        let account_id = account_id_from_auth(&auth).ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidData, "Codex home has no identifiable ChatGPT login")
        })?;
        Ok(Self { path, account_id })
    }

    pub fn plugin_path(&self) -> String {
        let path = self.path.to_string_lossy();
        #[cfg(windows)]
        {
            if let Some(unc) = path.strip_prefix(r"\\?\UNC\") {
                return format!(r"\\{unc}");
            }
            if let Some(disk) = path.strip_prefix(r"\\?\")
                && disk.as_bytes().get(1) == Some(&b':')
            {
                return disk.to_string();
            }
        }
        path.into_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_only_a_signed_in_and_consistent_home() {
        let dir = tempfile::tempdir().unwrap();
        let token = format!("header.{}.signature", URL_SAFE_NO_PAD.encode(
            br#"{"https://api.openai.com/auth":{"chatgpt_account_id":"Account-A"}}"#
        ));
        let file = dir.path().join("auth.json");
        for (declared, access, expected) in [
            (" Account-A ", "synthetic", Some("account-a")),
            ("", "synthetic", Some("account-a")),
            ("account-b", "synthetic", None),
            ("account-a", "", None),
        ] {
            fs::write(&file, serde_json::json!({"tokens": {
                "account_id": declared, "access_token": access, "id_token": token
            }}).to_string()).unwrap();
            let account = CodexHome::inspect(dir.path()).ok().map(|home| home.account_id);
            assert_eq!(account.as_deref(), expected);
        }
    }
}
