use crate::codex_accounts::CodexHome;
use crate::provider_accounts_crypto::{
    self, EncryptedProviderAccountsFile, STORE_FORMAT_V1,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{LazyLock, Mutex};

const STORE_FILE: &str = "provider_accounts.json";
static STORE_MUTATION: Mutex<()> = Mutex::new(());

#[derive(Default)]
struct HistoryIdentity {
    generation: u64,
    key: Option<String>,
}

type HistoryIdentities = BTreeMap<PathBuf, BTreeMap<String, HistoryIdentity>>;
static HISTORY_IDENTITIES: LazyLock<Mutex<HistoryIdentities>> = LazyLock::new(Mutex::default);
static HISTORY_IDENTITY_GENERATION: AtomicU64 = AtomicU64::new(1);

/// Read this process's latest verified Claude and Codex identities for an application data directory.
/// Keys are Windows provider instance IDs; values use the macOS VM Box receipt identity format.
/// Missing, failed, in-flight, or replaced logins have no entry. No names or credentials are exported.
pub fn verified_history_identities(app_data_dir: &Path) -> io::Result<BTreeMap<String, String>> {
    let identities = HISTORY_IDENTITIES
        .lock()
        .map_err(|_| io::Error::other("verified history identities unavailable"))?;
    Ok(identities
        .get(app_data_dir)
        .into_iter()
        .flatten()
        .filter_map(|(instance, identity)| {
            identity.key.as_ref().map(|key| (instance.clone(), key.clone()))
        })
        .collect())
}

pub(crate) fn begin_history_identity_probe(app_data_dir: &Path, instance_id: &str) -> Option<u64> {
    let mut identities = HISTORY_IDENTITIES.lock().ok()?;
    let generation = HISTORY_IDENTITY_GENERATION.fetch_add(1, Ordering::Relaxed);
    identities.entry(app_data_dir.to_path_buf()).or_default().insert(
        instance_id.to_string(),
        HistoryIdentity { generation, key: None },
    );
    Some(generation)
}

pub(crate) fn finish_history_identity_probe(
    app_data_dir: &Path,
    instance_id: &str,
    generation: u64,
    family: &str,
    key: &str,
) {
    let key = key.trim();
    let valid_part = |part: &str| {
        !part.is_empty()
            && part.len() <= 128
            && part.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_".contains(&b))
    };
    let valid = match family {
        "claude" => match key.split_once('|') {
            Some((account, org)) => valid_part(account) && valid_part(org),
            None => valid_part(key),
        },
        "codex" => valid_part(key),
        _ => false,
    };
    if !valid {
        return;
    }
    if let Ok(mut identities) = HISTORY_IDENTITIES.lock()
        && let Some(identity) = identities.get_mut(app_data_dir)
            .and_then(|entries| entries.get_mut(instance_id))
        && identity.generation == generation
    {
        identity.key = Some(key.to_ascii_lowercase());
    }
}

fn forget_history_identity(app_data_dir: &Path, instance_id: &str) {
    if let Ok(mut identities) = HISTORY_IDENTITIES.lock()
        && let Some(entries) = identities.get_mut(app_data_dir)
    {
        entries.remove(instance_id);
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderCredential {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub access_token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refresh_token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<i64>,
}

impl ProviderCredential {
    pub fn is_empty(&self) -> bool {
        self.access_token.as_deref().unwrap_or("").trim().is_empty()
            && self.refresh_token.as_deref().unwrap_or("").trim().is_empty()
            && self.session_key.as_deref().unwrap_or("").trim().is_empty()
            && self.expires_at.is_none()
    }

    pub fn merge_update(&mut self, update: ProviderCredential) {
        if let Some(value) = update.access_token {
            self.access_token = normalize_secret(value);
        }
        if let Some(value) = update.refresh_token {
            self.refresh_token = normalize_secret(value);
        }
        if let Some(value) = update.session_key {
            self.session_key = normalize_secret(value);
        }
        if update.expires_at.is_some() {
            self.expires_at = update.expires_at;
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderAccount {
    pub instance_id: String,
    pub base_provider_id: String,
    pub label: String,
    #[serde(default)]
    pub credential: ProviderCredential,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codex_home: Option<CodexHome>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderAccountsStore {
    #[serde(default)]
    pub accounts: BTreeMap<String, ProviderAccount>,
}

#[derive(Debug, Clone)]
pub struct ProviderAccountContext {
    pub instance_id: String,
    pub base_provider_id: String,
    pub label: String,
    pub credential: Option<ProviderCredential>,
    pub codex_home: Option<CodexHome>,
    pub store_path: Option<PathBuf>,
}

pub fn store_path(app_data_dir: &Path) -> PathBuf {
    app_data_dir.join(STORE_FILE)
}

pub fn load_store(app_data_dir: &Path) -> io::Result<ProviderAccountsStore> {
    load_store_path(&store_path(app_data_dir))
}

pub fn load_store_path(path: &Path) -> io::Result<ProviderAccountsStore> {
    let _lock = lock_store(path)?;
    load_store_locked(path)
}

fn lock_store(path: &Path) -> io::Result<File> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid provider accounts path"))?;
    fs::create_dir_all(parent)?;
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(path.with_extension("lock"))?;
    lock.lock()?;
    Ok(lock)
}

fn load_store_locked(path: &Path) -> io::Result<ProviderAccountsStore> {
    let text = match fs::read_to_string(path) {
        Ok(text) => text,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(ProviderAccountsStore::default()),
        Err(err) => return Err(err),
    };

    let app_data_dir = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid provider accounts path"))?;
    let (store, migrated_from_legacy) = decode_store_text(&text, app_data_dir)?;
    if migrated_from_legacy {
        save_store_locked(path, &store)?;
    }
    Ok(store)
}

fn decode_store_text(text: &str, app_data_dir: &Path) -> io::Result<(ProviderAccountsStore, bool)> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Ok((ProviderAccountsStore::default(), false));
    }

    if let Ok(wrapper) = serde_json::from_str::<EncryptedProviderAccountsFile>(trimmed) {
        if wrapper.format == STORE_FORMAT_V1 {
            let plaintext = provider_accounts_crypto::decrypt_store_envelope(&wrapper.envelope, app_data_dir)?;
            let store = serde_json::from_str(&plaintext).map_err(|err| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("invalid decrypted provider accounts store: {err}"),
                )
            })?;
            return Ok((store, false));
        }
    }

    if provider_accounts_crypto::is_legacy_plaintext_store(trimmed) {
        let store = serde_json::from_str(trimmed).map_err(|err| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("invalid legacy provider accounts store: {err}"),
            )
        })?;
        return Ok((store, true));
    }

    Err(io::Error::new(
        io::ErrorKind::InvalidData,
        "invalid provider accounts store",
    ))
}

pub fn save_store(app_data_dir: &Path, store: &ProviderAccountsStore) -> io::Result<()> {
    save_store_path(&store_path(app_data_dir), store)
}

pub fn save_store_path(path: &Path, store: &ProviderAccountsStore) -> io::Result<()> {
    let _lock = lock_store(path)?;
    save_store_locked(path, store)
}

fn save_store_locked(path: &Path, store: &ProviderAccountsStore) -> io::Result<()> {
    let app_data_dir = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid provider accounts path"))?;
    let plaintext = serde_json::to_string(store).map_err(io::Error::other)?;
    let encrypted = provider_accounts_crypto::encrypt_store_plaintext(&plaintext, app_data_dir)?;
    let text = serde_json::to_string_pretty(&encrypted).map_err(io::Error::other)?;
    let tmp = path.with_extension("json.tmp");
    let mut options = OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let result = (|| {
        let mut file = options.open(&tmp)?;
        restrict_private_file_permissions(&tmp)?;
        file.write_all(text.as_bytes())?;
        file.sync_all()?;
        drop(file);
        fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

#[cfg(unix)]
fn restrict_private_file_permissions(path: &Path) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
}

#[cfg(not(unix))]
fn restrict_private_file_permissions(_path: &Path) -> io::Result<()> {
    Ok(())
}

pub fn get_account(app_data_dir: &Path, instance_id: &str) -> io::Result<Option<ProviderAccount>> {
    Ok(load_store(app_data_dir)?.accounts.get(instance_id).cloned())
}

pub fn upsert_account(app_data_dir: &Path, mut account: ProviderAccount) -> io::Result<()> {
    account.instance_id = account.instance_id.trim().to_string();
    account.base_provider_id = account.base_provider_id.trim().to_string();
    account.label = account.label.trim().to_string();
    account.credential.access_token = account.credential.access_token.and_then(normalize_secret);
    account.credential.refresh_token = account.credential.refresh_token.and_then(normalize_secret);
    account.credential.session_key = account.credential.session_key.and_then(normalize_secret);

    let _mutation = STORE_MUTATION
        .lock()
        .map_err(|_| io::Error::other("provider account store unavailable"))?;
    let path = store_path(app_data_dir);
    let instance_id = account.instance_id.clone();
    let _lock = lock_store(&path)?;
    let mut store = load_store_locked(&path)?;
    store.accounts.insert(account.instance_id.clone(), account);
    save_store_locked(&path, &store)?;
    forget_history_identity(app_data_dir, &instance_id);
    Ok(())
}

pub fn delete_account(app_data_dir: &Path, instance_id: &str) -> io::Result<()> {
    let _mutation = STORE_MUTATION
        .lock()
        .map_err(|_| io::Error::other("provider account store unavailable"))?;
    let path = store_path(app_data_dir);
    let _lock = lock_store(&path)?;
    let mut store = load_store_locked(&path)?;
    store.accounts.remove(instance_id);
    save_store_locked(&path, &store)?;
    forget_history_identity(app_data_dir, instance_id);
    Ok(())
}

pub fn update_credential_at_path(
    store_path: &Path,
    instance_id: &str,
    update: ProviderCredential,
) -> io::Result<Option<ProviderCredential>> {
    let _mutation = STORE_MUTATION
        .lock()
        .map_err(|_| io::Error::other("provider account store unavailable"))?;
    let _lock = lock_store(store_path)?;
    let mut store = load_store_locked(store_path)?;
    let Some(account) = store.accounts.get_mut(instance_id) else {
        return Ok(None);
    };
    account.credential.merge_update(update);
    let credential = account.credential.clone();
    save_store_locked(store_path, &store)?;
    Ok(Some(credential))
}

fn normalize_secret(value: String) -> Option<String> {
    let trimmed = value.trim().to_string();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_dir(name: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("quotabar-provider-accounts-{name}-{nonce}"));
        fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    #[serial]

    fn concurrent_home_registration_preserves_other_accounts() {
        provider_accounts_crypto::set_test_master_key(Some([7_u8; 32]));
        let dir = temp_dir("concurrent-registrations");
        let barrier = std::sync::Barrier::new(4);
        std::thread::scope(|scope| {
            for n in 0..4 {
                let dir = &dir;
                let barrier = &barrier;
                scope.spawn(move || {
                    barrier.wait();
                    upsert_account(
                        dir,
                        ProviderAccount {
                            instance_id: format!("codex:{n}"),
                            base_provider_id: "codex".into(),
                            label: format!("Account {n}"),
                            codex_home: Some(CodexHome {
                                path: dir.join(format!("home-{n}")),
                                account_id: format!("account-{n}"),
                            }),

                            credential: ProviderCredential::default(),
                        },
                    )
                    .unwrap();
                });
            }
        });

        let store = load_store(&dir).unwrap();
        assert_eq!(store.accounts.len(), 4);
        for n in 0..4 {
            let account = &store.accounts[&format!("codex:{n}")];
            assert!(account.credential.is_empty());
            assert_eq!(
                account.codex_home.as_ref().unwrap().account_id,
                format!("account-{n}")
            );
        }
        provider_accounts_crypto::set_test_master_key(None);
        fs::remove_dir_all(dir).unwrap();

    }

    #[test]
    #[serial]
    fn upsert_load_and_update_credentials() {
        provider_accounts_crypto::set_test_master_key(Some([7_u8; 32]));
        let dir = temp_dir("roundtrip");
        upsert_account(
            &dir,
            ProviderAccount {
                instance_id: "claude:work".into(),
                base_provider_id: "claude".into(),
                label: "Work".into(),
                codex_home: None,
                credential: ProviderCredential {
                    access_token: Some("old".into()),
                    refresh_token: None,
                    session_key: None,
                    expires_at: None,
                },
            },
        )
        .unwrap();

        let path = store_path(&dir);
        let updated = update_credential_at_path(
            &path,
            "claude:work",
            ProviderCredential {
                access_token: Some("new".into()),
                refresh_token: Some("refresh".into()),
                session_key: None,
                expires_at: Some(123),
            },
        )
        .unwrap()
        .unwrap();

        assert_eq!(updated.access_token.as_deref(), Some("new"));
        assert_eq!(updated.refresh_token.as_deref(), Some("refresh"));
        assert_eq!(updated.expires_at, Some(123));
        assert_eq!(
            get_account(&dir, "claude:work")
                .unwrap()
                .unwrap()
                .credential
                .access_token
                .as_deref(),
            Some("new")
        );
        let on_disk = fs::read_to_string(store_path(&dir)).expect("encrypted store");
        assert!(!on_disk.contains("\"old\""));
        assert!(!on_disk.contains("\"new\""));
        let _ = fs::remove_dir_all(dir);
        provider_accounts_crypto::set_test_master_key(None);
    }

    #[test]
    #[serial]
    fn migrates_legacy_plaintext_store_to_encrypted_file() {
        provider_accounts_crypto::set_test_master_key(Some([9_u8; 32]));
        let dir = temp_dir("migrate");
        let path = store_path(&dir);
        let legacy = ProviderAccountsStore {
            accounts: BTreeMap::from([(
                "cursor:work".to_string(),
                ProviderAccount {
                    instance_id: "cursor:work".into(),
                    base_provider_id: "cursor".into(),
                    label: "Work".into(),
                    codex_home: None,
                    credential: ProviderCredential {
                        access_token: Some("secret-token".into()),
                        refresh_token: None,
                        session_key: None,
                        expires_at: None,
                    },
                },
            )]),
        };
        fs::write(
            &path,
            serde_json::to_string_pretty(&legacy).expect("legacy json"),
        )
        .expect("write legacy");

        let loaded = load_store_path(&path).expect("load migrates");
        assert_eq!(
            loaded
                .accounts
                .get("cursor:work")
                .and_then(|account| account.credential.access_token.as_deref()),
            Some("secret-token")
        );

        let on_disk = fs::read_to_string(&path).expect("encrypted file");
        assert!(!on_disk.contains("secret-token"));
        assert!(on_disk.contains(STORE_FORMAT_V1));

        provider_accounts_crypto::set_test_master_key(None);
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    #[cfg(unix)]
    #[serial]
    fn save_store_path_sets_private_file_permissions() {
        provider_accounts_crypto::set_test_master_key(Some([3_u8; 32]));
        use std::os::unix::fs::PermissionsExt;

        let dir = temp_dir("perms");
        let path = store_path(&dir);
        save_store_path(
            &path,
            &ProviderAccountsStore {
                accounts: BTreeMap::new(),
            },
        )
        .unwrap();
        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        provider_accounts_crypto::set_test_master_key(None);
        let _ = fs::remove_dir_all(dir);
    }
}
