//! Read decrypted Chromium-family cookies from the local profile Cookies SQLite DB.
//!
//! Linux/macOS: OSCrypt `v10`/`v11` AES-128-CBC. Windows DPAPI/`v20` is not supported.
#![cfg_attr(windows, allow(dead_code, unused_imports))]

use aes::cipher::{block_padding::Pkcs7, BlockDecryptMut, KeyIvInit};
use pbkdf2::pbkdf2_hmac;
use rusqlite::{params_from_iter, Connection, OpenFlags};
use serde::Deserialize;
use sha1::Sha1;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const SALT: &[u8] = b"saltysalt";
const IV: [u8; 16] = [b' '; 16];
const KEY_LEN: usize = 16;
const LINUX_ITERATIONS: u32 = 1;
const MACOS_ITERATIONS: u32 = 1003;
const LINUX_V10_PASSWORD: &[u8] = b"peanuts";

type Aes128CbcDec = cbc::Decryptor<aes::Aes128>;

#[derive(Debug, Deserialize)]
pub struct ChromiumCookiesReadOpts {
    #[serde(default)]
    pub hosts: Vec<String>,
    #[serde(default)]
    pub names: Vec<String>,
}

#[derive(Clone, Copy)]
struct DerivedKey {
    bytes: [u8; KEY_LEN],
}

pub fn read_chromium_cookies(
    opts: &ChromiumCookiesReadOpts,
) -> Result<HashMap<String, String>, String> {
    if opts.names.is_empty() {
        return Err("chromiumCookies.read requires names".to_string());
    }
    if opts.hosts.is_empty() {
        return Err("chromiumCookies.read requires hosts".to_string());
    }

    #[cfg(windows)]
    {
        return Err(
            "Chrome cookie decryption on Windows is not supported yet (DPAPI / v20 app-bound)"
                .to_string(),
        );
    }

    #[cfg(not(windows))]
    {
        let keys = collect_os_crypt_keys()?;
        let dbs = cookie_db_candidates();
        if dbs.is_empty() {
            return Ok(HashMap::new());
        }

        let mut profiles = Vec::new();
        let mut v20_seen = false;
        let mut v12_seen = false;
        for db in &dbs {
            match read_cookies_from_db(db, &opts.hosts, &opts.names, &keys) {
                Ok(partial) => {
                    if partial.is_empty() {
                        continue;
                    }
                    let complete = opts.names.iter().all(|n| partial.contains_key(n));
                    profiles.push(partial);
                    if complete {
                        break;
                    }
                }
                Err(err) if err.contains("v20") => v20_seen = true,
                Err(err) if err.contains("v12") => v12_seen = true,
                Err(_) => {}
            }
        }

        let found = pick_single_profile_cookies(profiles, &opts.names);
        if found.is_empty() && v20_seen {
            return Err("Chrome cookie encryption v20 (app-bound) is not supported".to_string());
        }
        if found.is_empty() && v12_seen {
            return Err(
                "Chrome cookie encryption v12 (Secret Portal) is not supported".to_string(),
            );
        }
        Ok(found)
    }
}

fn collect_os_crypt_keys() -> Result<Vec<DerivedKey>, String> {
    let mut keys = Vec::new();
    let mut seen = std::collections::HashSet::new();

    for password in safe_storage_passwords() {
        let iterations = os_crypt_iterations();
        let key = derive_key(password.as_bytes(), iterations);
        if seen.insert(key.bytes) {
            keys.push(key);
        }
    }

    let peanuts = derive_key(LINUX_V10_PASSWORD, LINUX_ITERATIONS);
    if seen.insert(peanuts.bytes) {
        keys.push(peanuts);
    }
    let empty = derive_key(b"", LINUX_ITERATIONS);
    if seen.insert(empty.bytes) {
        keys.push(empty);
    }

    if keys.is_empty() {
        return Err("no Chromium OSCrypt keys available".to_string());
    }
    Ok(keys)
}

fn os_crypt_iterations() -> u32 {
    if cfg!(target_os = "macos") {
        MACOS_ITERATIONS
    } else {
        LINUX_ITERATIONS
    }
}

fn derive_key(password: &[u8], iterations: u32) -> DerivedKey {
    let mut bytes = [0u8; KEY_LEN];
    pbkdf2_hmac::<Sha1>(password, SALT, iterations, &mut bytes);
    DerivedKey { bytes }
}

fn safe_storage_passwords() -> Vec<String> {
    let out = Vec::new();
    #[cfg(target_os = "linux")]
    {
        for application in [
            "chrome",
            "chromium",
            "brave",
            "microsoft-edge",
            "chrome-beta",
            "chrome-unstable",
        ] {
            if let Ok(secret) = linux_libsecret_password(application) {
                if !secret.is_empty() {
                    out.push(secret);
                }
            }
        }
    }
    #[cfg(target_os = "macos")]
    {
        for service in [
            "Chrome Safe Storage",
            "Chromium Safe Storage",
            "Brave Safe Storage",
            "Microsoft Edge Safe Storage",
        ] {
            if let Ok(secret) = macos_safe_storage_password(service) {
                if !secret.is_empty() {
                    out.push(secret);
                }
            }
        }
    }
    out
}

#[cfg(target_os = "linux")]
fn linux_libsecret_password(application: &str) -> Result<String, String> {
    let secret_tool = ["secret-tool", "/usr/bin/secret-tool"]
        .into_iter()
        .find(|path| Path::new(path).is_file())
        .ok_or_else(|| "secret-tool not installed".to_string())?;

    let mut cmd = std::process::Command::new(secret_tool);
    cmd.arg("lookup").arg("application").arg(application);
    if let Ok(addr) = std::env::var("DBUS_SESSION_BUS_ADDRESS") {
        if !addr.trim().is_empty() {
            cmd.env("DBUS_SESSION_BUS_ADDRESS", addr);
        }
    } else {
        let uid = unsafe { libc::getuid() };
        let bus_path = format!("/run/user/{uid}/bus");
        if Path::new(&bus_path).exists() {
            cmd.env("DBUS_SESSION_BUS_ADDRESS", format!("unix:path={bus_path}"));
        }
    }

    let output = cmd
        .output()
        .map_err(|e| format!("secret-tool failed: {e}"))?;
    if !output.status.success() {
        return Err("secret-tool lookup returned no entry".to_string());
    }
    let password = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if password.is_empty() {
        return Err("secret-tool lookup returned empty secret".to_string());
    }
    Ok(password)
}

#[cfg(target_os = "macos")]
fn macos_safe_storage_password(service: &str) -> Result<String, String> {
    let output = std::process::Command::new("security")
        .args(["find-generic-password", "-s", service, "-w"])
        .output()
        .map_err(|e| format!("security failed: {e}"))?;
    if !output.status.success() {
        return Err("Chrome Safe Storage keychain item not found".to_string());
    }
    let password = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if password.is_empty() {
        return Err("Chrome Safe Storage keychain item empty".to_string());
    }
    Ok(password)
}

/// One Chromium profile at a time. Never stitch cookie names across DBs.
#[cfg(any(test, not(windows)))]
fn pick_single_profile_cookies(
    profiles: impl IntoIterator<Item = HashMap<String, String>>,
    names: &[String],
) -> HashMap<String, String> {
    let mut best = HashMap::new();
    for partial in profiles {
        if names.iter().all(|n| partial.contains_key(n)) {
            return partial;
        }
        if partial.len() > best.len() {
            best = partial;
        }
    }
    best
}

/// Prefer live `Network/Cookies` (Chrome M88+). Skip the unmaintained profile-root leftover.
fn cookie_db_for_profile(profile_dir: &Path) -> Option<PathBuf> {
    let network = profile_dir.join("Network").join("Cookies");
    if network.is_file() {
        return Some(network);
    }
    let leftover = profile_dir.join("Cookies");
    leftover.is_file().then_some(leftover)
}

fn cookie_db_candidates() -> Vec<PathBuf> {
    let mut roots = Vec::new();
    if let Some(home) = dirs::home_dir() {
        roots.extend([
            home.join(".config/google-chrome"),
            home.join(".config/google-chrome-beta"),
            home.join(".config/google-chrome-unstable"),
            home.join(".config/chromium"),
            home.join(".config/BraveSoftware/Brave-Browser"),
            home.join(".config/microsoft-edge"),
            home.join("snap/chromium/common/chromium"),
            home.join("snap/brave/common/.config/BraveSoftware/Brave-Browser"),
            home.join("Library/Application Support/Google/Chrome"),
            home.join("Library/Application Support/Google/Chrome Beta"),
            home.join("Library/Application Support/Chromium"),
            home.join("Library/Application Support/BraveSoftware/Brave-Browser"),
            home.join("Library/Application Support/Microsoft Edge"),
        ]);
    }
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        let local = PathBuf::from(local);
        roots.extend([
            local.join("Google/Chrome/User Data"),
            local.join("Google/Chrome Beta/User Data"),
            local.join("Chromium/User Data"),
            local.join("BraveSoftware/Brave-Browser/User Data"),
            local.join("Microsoft/Edge/User Data"),
        ]);
    }

    let mut dbs = Vec::new();
    for root in roots {
        if !root.is_dir() {
            continue;
        }
        let Ok(entries) = fs::read_dir(&root) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
            if name != "Default" && !name.starts_with("Profile ") {
                continue;
            }
            if let Some(db) = cookie_db_for_profile(&path) {
                dbs.push(db);
            }
        }
    }
    dbs
}

fn copy_db_for_read(src: &Path) -> Result<PathBuf, String> {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let tmp = std::env::temp_dir().join(format!(
        "quotabar-chrome-cookies-{}-{}.db",
        std::process::id(),
        nanos
    ));
    fs::copy(src, &tmp).map_err(|e| format!("copy Cookies db failed: {e}"))?;
    if let Some(file_name) = src.file_name().and_then(|s| s.to_str()) {
        let wal_src = src.with_file_name(format!("{file_name}-wal"));
        if wal_src.is_file() {
            let wal_dst = tmp.with_file_name(format!(
                "{}-wal",
                tmp.file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or("Cookies")
            ));
            let _ = fs::copy(&wal_src, wal_dst);
        }
    }
    Ok(tmp)
}

fn cleanup_db_copy(path: &Path) {
    let _ = fs::remove_file(path);
    if let Some(file_name) = path.file_name().and_then(|s| s.to_str()) {
        let _ = fs::remove_file(path.with_file_name(format!("{file_name}-wal")));
        let _ = fs::remove_file(path.with_file_name(format!("{file_name}-shm")));
    }
}

fn read_cookies_from_db(
    db_path: &Path,
    hosts: &[String],
    names: &[String],
    keys: &[DerivedKey],
) -> Result<HashMap<String, String>, String> {
    let tmp = copy_db_for_read(db_path)?;
    let result = read_cookies_from_copied_db(&tmp, hosts, names, keys);
    cleanup_db_copy(&tmp);
    result
}

fn read_cookies_from_copied_db(
    db_path: &Path,
    hosts: &[String],
    names: &[String],
    keys: &[DerivedKey],
) -> Result<HashMap<String, String>, String> {
    let conn = Connection::open_with_flags(db_path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|e| format!("sqlite open failed: {e}"))?;

    let name_placeholders = vec!["?"; names.len()].join(",");
    let host_placeholders = vec!["?"; hosts.len()].join(",");
    let sql = format!(
        "SELECT name, host_key, value, encrypted_value FROM cookies \
         WHERE name IN ({name_placeholders}) AND host_key IN ({host_placeholders})"
    );
    let mut params: Vec<&str> = Vec::with_capacity(names.len() + hosts.len());
    for n in names {
        params.push(n.as_str());
    }
    for h in hosts {
        params.push(h.as_str());
    }

    let mut stmt = conn
        .prepare(&sql)
        .map_err(|e| format!("sqlite prepare failed: {e}"))?;
    let mut rows = stmt
        .query(params_from_iter(params))
        .map_err(|e| format!("sqlite query failed: {e}"))?;

    let mut found = HashMap::new();
    let mut v20 = false;
    let mut v12 = false;
    while let Some(row) = rows.next().map_err(|e| format!("sqlite row failed: {e}"))? {
        let name: String = row.get(0).map_err(|e| e.to_string())?;
        if found.contains_key(&name) {
            continue;
        }
        let host_key: String = row.get(1).unwrap_or_default();
        let value: String = row.get(2).unwrap_or_default();
        let encrypted: Vec<u8> = row.get(3).unwrap_or_default();

        if !value.is_empty() && encrypted.is_empty() {
            found.insert(name, value);
            continue;
        }
        if encrypted.is_empty() {
            continue;
        }
        match decrypt_cookie_value(&encrypted, keys, &host_key) {
            Ok(plain) if !plain.is_empty() => {
                found.insert(name, plain);
            }
            Err(err) if err.contains("v20") => v20 = true,
            Err(err) if err.contains("v12") => v12 = true,
            _ => {}
        }
    }

    if found.is_empty() && v20 {
        return Err("Chrome cookie encryption v20 (app-bound) is not supported".to_string());
    }
    if found.is_empty() && v12 {
        return Err("Chrome cookie encryption v12 (Secret Portal) is not supported".to_string());
    }
    Ok(found)
}

fn decrypt_cookie_value(
    encrypted: &[u8],
    keys: &[DerivedKey],
    host_key: &str,
) -> Result<String, String> {
    if encrypted.len() >= 3 {
        let prefix = &encrypted[..3];
        if prefix == b"v20" {
            return Err("Chrome cookie encryption v20 (app-bound) is not supported".to_string());
        }
        if prefix == b"v12" {
            return Err(
                "Chrome cookie encryption v12 (Secret Portal) is not supported".to_string(),
            );
        }
        if prefix == b"v10" || prefix == b"v11" {
            let ciphertext = &encrypted[3..];
            let mut last_err = "could not decrypt Chrome cookie".to_string();
            for key in keys {
                match aes128_cbc_decrypt(&key.bytes, ciphertext) {
                    Ok(plain) => {
                        if let Some(text) = plaintext_to_cookie(&plain, host_key) {
                            return Ok(text);
                        }
                        last_err = "decrypted cookie was not UTF-8".to_string();
                    }
                    Err(err) => last_err = err,
                }
            }
            return Err(last_err);
        }
    }
    if let Ok(text) = std::str::from_utf8(encrypted) {
        if !text.is_empty() {
            return Ok(text.to_string());
        }
    }
    Err("unrecognized cookie encryption prefix".to_string())
}

fn aes128_cbc_decrypt(key: &[u8; KEY_LEN], ciphertext: &[u8]) -> Result<Vec<u8>, String> {
    Aes128CbcDec::new(key.into(), &IV.into())
        .decrypt_padded_vec_mut::<Pkcs7>(ciphertext)
        .map_err(|_| "AES-128-CBC decrypt failed".to_string())
}

fn plaintext_to_cookie(plain: &[u8], host_key: &str) -> Option<String> {
    if plain.len() >= 32 {
        let hash = Sha256::digest(host_key.as_bytes());
        if plain[..32] == hash[..] {
            return String::from_utf8(plain[32..].to_vec()).ok();
        }
    }
    String::from_utf8(plain.to_vec()).ok()
}

#[cfg(test)]
fn encrypt_v10_peanuts(plaintext: &[u8]) -> Vec<u8> {
    use aes::cipher::BlockEncryptMut;
    type Aes128CbcEnc = cbc::Encryptor<aes::Aes128>;
    let key = derive_key(LINUX_V10_PASSWORD, LINUX_ITERATIONS);
    let ciphertext =
        Aes128CbcEnc::new(&key.bytes.into(), &IV.into()).encrypt_padded_vec_mut::<Pkcs7>(plaintext);
    let mut out = b"v10".to_vec();
    out.extend_from_slice(&ciphertext);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::params;

    #[test]
    fn decrypts_v10_peanuts_plaintext() {
        let encrypted = encrypt_v10_peanuts(b"g.a000sessioncookievalue");
        let key = derive_key(LINUX_V10_PASSWORD, LINUX_ITERATIONS);
        let plain = decrypt_cookie_value(&encrypted, &[key], ".google.com").expect("decrypt");
        assert_eq!(plain, "g.a000sessioncookievalue");
    }

    #[test]
    fn decrypts_v10_peanuts_with_host_hash_prefix() {
        let host = ".google.com";
        let mut payload = Sha256::digest(host.as_bytes()).to_vec();
        payload.extend_from_slice(b"__Secure-1PSID-value");
        let encrypted = encrypt_v10_peanuts(&payload);
        let key = derive_key(LINUX_V10_PASSWORD, LINUX_ITERATIONS);
        let plain = decrypt_cookie_value(&encrypted, &[key], host).expect("decrypt");
        assert_eq!(plain, "__Secure-1PSID-value");
    }

    #[test]
    fn v20_prefix_is_loud_error() {
        let key = derive_key(LINUX_V10_PASSWORD, LINUX_ITERATIONS);
        let err = decrypt_cookie_value(b"v20not-real", &[key], ".google.com").unwrap_err();
        assert!(err.contains("v20"), "{err}");
    }

    #[test]
    fn v12_prefix_is_loud_error() {
        let key = derive_key(LINUX_V10_PASSWORD, LINUX_ITERATIONS);
        let err = decrypt_cookie_value(b"v12not-real", &[key], ".google.com").unwrap_err();
        assert!(err.contains("v12"), "{err}");
    }

    #[test]
    fn reads_encrypted_cookie_from_sqlite_copy() {
        let dir = std::env::temp_dir().join(format!(
            "quotabar-chrome-cookie-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("temp dir");
        let db_path = dir.join("Cookies");
        let conn = Connection::open(&db_path).expect("create db");
        conn.execute(
            "CREATE TABLE cookies (
                name TEXT,
                host_key TEXT,
                value TEXT,
                encrypted_value BLOB
            )",
            [],
        )
        .expect("schema");
        let encrypted = encrypt_v10_peanuts(b"session-from-sqlite");
        conn.execute(
            "INSERT INTO cookies (name, host_key, value, encrypted_value) VALUES (?1, ?2, ?3, ?4)",
            params!["__Secure-1PSID", ".google.com", "", encrypted],
        )
        .expect("insert");
        drop(conn);

        let key = derive_key(LINUX_V10_PASSWORD, LINUX_ITERATIONS);
        let map = read_cookies_from_db(
            &db_path,
            &[".google.com".to_string()],
            &["__Secure-1PSID".to_string()],
            &[key],
        )
        .expect("read");
        assert_eq!(
            map.get("__Secure-1PSID").map(String::as_str),
            Some("session-from-sqlite")
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn pick_single_profile_does_not_stitch_cookie_names() {
        let names = vec!["__Secure-1PSID".into(), "SAPISID".into()];
        let mut first = HashMap::new();
        first.insert("__Secure-1PSID".into(), "profile-a-psid".into());
        let mut second = HashMap::new();
        second.insert("SAPISID".into(), "profile-b-sapisid".into());
        let picked = pick_single_profile_cookies([first, second], &names);
        assert_eq!(
            picked.get("__Secure-1PSID").map(String::as_str),
            Some("profile-a-psid")
        );
        assert!(picked.get("SAPISID").is_none());
    }

    #[test]
    fn pick_single_profile_prefers_complete_later_db() {
        let names = vec!["__Secure-1PSID".into(), "SAPISID".into()];
        let mut first = HashMap::new();
        first.insert("__Secure-1PSID".into(), "stale-psid".into());
        let mut second = HashMap::new();
        second.insert("__Secure-1PSID".into(), "fresh-psid".into());
        second.insert("SAPISID".into(), "fresh-sapisid".into());
        let picked = pick_single_profile_cookies([first, second], &names);
        assert_eq!(
            picked.get("__Secure-1PSID").map(String::as_str),
            Some("fresh-psid")
        );
        assert_eq!(
            picked.get("SAPISID").map(String::as_str),
            Some("fresh-sapisid")
        );
    }

    #[test]
    fn pick_single_profile_keeps_first_complete() {
        let names = vec!["__Secure-1PSID".into(), "SAPISID".into()];
        let mut first = HashMap::new();
        first.insert("__Secure-1PSID".into(), "a-psid".into());
        first.insert("SAPISID".into(), "a-sapisid".into());
        let mut second = HashMap::new();
        second.insert("__Secure-1PSID".into(), "b-psid".into());
        second.insert("SAPISID".into(), "b-sapisid".into());
        let picked = pick_single_profile_cookies([first, second], &names);
        assert_eq!(
            picked.get("__Secure-1PSID").map(String::as_str),
            Some("a-psid")
        );
        assert_eq!(picked.get("SAPISID").map(String::as_str), Some("a-sapisid"));
    }

    #[test]
    fn cookie_db_for_profile_prefers_live_network_over_leftover() {
        let dir = std::env::temp_dir().join(format!(
            "quotabar-chrome-cookie-network-vs-leftover-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("Network")).expect("temp dir");
        fs::write(dir.join("Network").join("Cookies"), b"live").expect("live db");
        fs::write(dir.join("Cookies"), b"stale").expect("leftover db");
        let picked = cookie_db_for_profile(&dir).expect("db");
        assert_eq!(picked, dir.join("Network").join("Cookies"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn cookie_db_for_profile_uses_leftover_when_network_missing() {
        let dir = std::env::temp_dir().join(format!(
            "quotabar-chrome-cookie-leftover-only-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("temp dir");
        fs::write(dir.join("Cookies"), b"legacy").expect("leftover db");
        let picked = cookie_db_for_profile(&dir).expect("db");
        assert_eq!(picked, dir.join("Cookies"));
        let _ = fs::remove_dir_all(&dir);
    }
}
