use crate::AppState;
use quotabar_core::{plugin_engine::runtime::run_guarded_plugin_action, provider_accounts};
use provider_accounts::ProviderAccountContext;
use serde::{Deserialize, Serialize};
use std::cell::Cell;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::Path;
use std::rc::Rc;
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};
use tauri::Manager;
use tauri_plugin_store::StoreExt;
use uuid::Uuid;

const ENABLED: &str = "codexAutoRedeemExpiringResets";
const LEAD_MS: i64 = 60_000;
const RETRY_MS: i64 = 15_000;
const PATROL_MS: i64 = 300_000;
const MAX_ATTEMPTS: u8 = 3;
type Ledger = BTreeMap<String, BTreeMap<String, Attempt>>;
static WAKE: (Mutex<u64>, Condvar) = (Mutex::new(0), Condvar::new());

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Credit {
    id: String,
    expiry_ms: i64,
}

#[derive(Clone, Deserialize, Serialize)]
struct Attempt {
    credit: Credit,
    request_id: Uuid,
    count: u8,
    last_ms: i64,
    terminal: bool,
    sent: bool,
}

#[derive(Default)]
struct Schedule {
    next: Option<Instant>,
    failures: u32,
}

fn enabled(app: &tauri::AppHandle) -> bool {
    app.store("settings.json").ok().is_some_and(|store| {
        store.get(ENABLED).and_then(|value| value.as_bool()) == Some(true)
    })
}

#[tauri::command]
pub(crate) fn codex_auto_reset_enabled(app: tauri::AppHandle) -> bool {
    enabled(&app)
}

#[tauri::command]
pub(crate) fn set_codex_auto_reset_enabled(app: tauri::AppHandle, value: bool) -> Result<(), String> {
    let store = app.store("settings.json").map_err(|err| err.to_string())?;
    let mut generation = WAKE.0.lock().map_err(|err| err.to_string())?;
    let previous = store.get(ENABLED);
    store.set(ENABLED, value);
    if let Err(error) = store.save() {
        if let Some(previous) = previous {
            store.set(ENABLED, previous);
        } else {
            store.delete(ENABLED);
        }
        return Err(error.to_string());
    }
    *generation = generation.wrapping_add(1);
    WAKE.1.notify_one();
    Ok(())
}

pub(crate) fn start(app: tauri::AppHandle) {
    if let Err(error) = std::thread::Builder::new().name("codex-auto-reset".into()).spawn(move || {
        let mut schedules = BTreeMap::new();
        let mut last_generation = None;
        loop {
            let generation = *WAKE.0.lock().expect("Codex reset wake");
            if last_generation != Some(generation) {
                schedules.clear();
                last_generation = Some(generation);
            }
            let delay = if enabled(&app) {
                Some(run_accounts(&app, generation, &mut schedules))
            } else {
                None
            };
            let guard = WAKE.0.lock().expect("Codex reset wake");
            if let Some(delay) = delay {
                drop(WAKE.1.wait_timeout_while(guard, delay, |current| *current == generation));
            } else {
                drop(WAKE.1.wait_while(guard, |current| *current == generation));
            }
        }
    }) {
        log::error!("Could not start Codex auto-reset worker: {error}");
    }
}

fn eligible_credit(
    live: Vec<Credit>,
    attempts: &BTreeMap<String, Attempt>,
    now: i64,
) -> Option<(Credit, i64)> {
    let live_ids: BTreeSet<_> = live.iter().map(|credit| credit.id.clone()).collect();
    live.into_iter()
        .chain(attempts.values().filter(|attempt| attempt.sent && !live_ids.contains(&attempt.credit.id))
            .map(|attempt| attempt.credit.clone()))
        .filter_map(|credit| {
            let previous = attempts.get(&credit.id);
            if previous.is_some_and(|attempt| attempt.terminal || attempt.count >= MAX_ATTEMPTS) {
                return None;
            }
            let ready = credit.expiry_ms.saturating_sub(LEAD_MS).max(
                previous.map_or(i64::MIN, |attempt| attempt.last_ms.saturating_add(RETRY_MS))
            );
            (credit.expiry_ms > now && ready < credit.expiry_ms).then_some((credit, ready))
        })
        .min_by(|(a, first), (b, second)| first.cmp(second).then_with(|| a.id.cmp(&b.id)))
}

fn save(path: &Path, ledger: &Ledger) -> std::io::Result<()> {
    let staged = path.with_extension("tmp");
    let data = serde_json::to_vec(ledger)?;
    let mut file = fs::File::create(&staged)?;
    std::io::Write::write_all(&mut file, &data)?;
    file.sync_all()?;
    drop(file);
    fs::rename(staged, path)
}

fn load(path: &Path) -> std::io::Result<Ledger> {
    match fs::read(path) {
        Ok(bytes) => Ok(serde_json::from_slice(&bytes)?),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Ledger::new()),
        Err(error) => Err(error),
    }
}

fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

fn can_redeem(app: &tauri::AppHandle, generation: u64) -> bool {
    WAKE.0.lock().is_ok_and(|current| *current == generation && enabled(app))
}

fn run_accounts(app: &tauri::AppHandle, generation: u64, schedules: &mut BTreeMap<String, Schedule>) -> Duration {
    let patrol = Duration::from_millis(PATROL_MS as u64);
    let state = app.state::<Mutex<AppState>>();
    let (dir, version, plugin) = {
        let Ok(state) = state.lock() else { return patrol };
        let Some(plugin) = state.plugins.iter().find(|plugin| plugin.manifest.id == "codex") else {
            return patrol;
        };
        (state.app_data_dir.clone(), state.app_version.clone(), plugin.clone())
    };
    let Ok(accounts) = provider_accounts::load_store(&dir) else { return patrol };
    let Ok(verified) = provider_accounts::verified_history_identities(&dir) else { return patrol };
    let path = dir.join("codex-auto-reset-attempts.json");
    let mut ledger = match load(&path) {
        Ok(ledger) => ledger,
        Err(error) => {
            log::error!("Codex auto reset cannot read its attempt ledger: {error}");
            return patrol;
        }
    };
    let cutoff = now_ms().saturating_sub(86_400_000);
    ledger.retain(|_, attempts| {
        attempts.retain(|_, attempt| attempt.credit.expiry_ms >= cutoff);
        !attempts.is_empty()
    });
    let mut scheduled = BTreeSet::new();
    for (instance_id, owner) in verified {
        if !can_redeem(app, generation) { break }
        let stored = accounts.accounts.get(&instance_id);
        if instance_id != "codex" && !stored.is_some_and(|account| account.base_provider_id == "codex") {
            continue;
        }
        if !scheduled.insert(owner.clone()) { continue }
        let schedule = schedules.entry(owner.clone()).or_default();
        if schedule.next.is_some_and(|next| next > Instant::now()) { continue }
        let account = ProviderAccountContext {
            instance_id: instance_id.clone(),
            base_provider_id: "codex".into(),
            label: stored.map(|entry| entry.label.clone()).unwrap_or_default(),
            credential: stored.map(|entry| entry.credential.clone()).filter(|item| !item.is_empty()),
            codex_home: stored.and_then(|entry| entry.codex_home.clone()),
            store_path: Some(provider_accounts::store_path(&dir)),
        };
        let action = |name: &str, args: serde_json::Value, prepare: Box<dyn Fn() -> bool>| {
            if !can_redeem(app, generation) { return Ok("cancelled".to_string()) }
            let app = app.clone();
            let dir = dir.clone();
            let stored = stored.cloned();
            let instance_id = instance_id.clone();
            run_guarded_plugin_action(&plugin, &dir.clone(), &version, name, &args.to_string(), Some(account.clone()), move || {
                let current = || can_redeem(&app, generation) &&
                    provider_accounts::get_account(&dir, &instance_id)
                        .is_ok_and(|current| current == stored);
                current() && prepare() && current()
            })
        };
        let result = action("listAutomaticResets", serde_json::json!({"accountId": owner}), Box::new(|| true))
            .ok().and_then(|result| serde_json::from_str::<Vec<Credit>>(&result).ok());
        let delay = if let Some(credits) = result {
            schedule.failures = 0;
            attempt_due(&path, &mut ledger, &owner, credits, action)
        } else {
            if schedule.failures == 0 { log::warn!("Codex auto reset credit lookup failed"); }
            schedule.failures = schedule.failures.saturating_add(1);
            (RETRY_MS << (schedule.failures - 1).min(5)).min(PATROL_MS)
        };
        schedule.next = Some(Instant::now() + Duration::from_millis(delay.clamp(1_000, PATROL_MS) as u64));
    }
    schedules.retain(|account, _| scheduled.contains(account));
    schedules.values().filter_map(|schedule| schedule.next).min()
        .map_or(patrol, |instant| instant.saturating_duration_since(Instant::now()).max(Duration::from_secs(1)))
}

fn attempt_due(
    path: &Path,
    ledger: &mut Ledger,
    owner: &str,
    credits: Vec<Credit>,
    action: impl Fn(&str, serde_json::Value, Box<dyn Fn() -> bool>) -> Result<String, String>,
) -> i64 {
    attempt_due_at(path, ledger, owner, credits, action, now_ms())
}

fn attempt_due_at(
    path: &Path,
    ledger: &mut Ledger,
    owner: &str,
    credits: Vec<Credit>,
    action: impl Fn(&str, serde_json::Value, Box<dyn Fn() -> bool>) -> Result<String, String>,
    now: i64,
) -> i64 {
    let attempts = ledger.entry(owner.into()).or_default();
    let Some((credit, ready)) = eligible_credit(credits, attempts, now) else { return PATROL_MS };
    if ready > now { return ready.saturating_sub(now) }
    let previous = attempts.get(&credit.id).cloned();
    let mut attempt = previous.clone().unwrap_or_else(|| Attempt {
        credit: credit.clone(),
        request_id: Uuid::new_v4(),
        count: 0,
        last_ms: 0,
        terminal: false,
        sent: false,
    });
    attempt.credit = credit.clone();
    attempt.count += 1;
    attempt.last_ms = now;
    attempts.insert(credit.id.clone(), attempt.clone());
    if let Err(error) = save(path, ledger) {
        log::error!("Codex auto reset could not persist request state: {error}");
        return RETRY_MS;
    }
    let sent = Rc::new(Cell::new(false));
    let mut prepared = ledger.clone();
    prepared.get_mut(owner).unwrap().get_mut(&credit.id).unwrap().sent = true;
    let prepare = {
        let sent = Rc::clone(&sent);
        let path = path.to_owned();
        move || match save(&path, &prepared) {
            Ok(()) => {
                sent.set(true);
                true
            }
            Err(error) => {
                log::error!("Codex auto reset could not persist permission to redeem: {error}");
                false
            }
        }
    };
    let outcome = action("claimAutomaticReset", serde_json::json!({
        "accountId": owner, "id": credit.id, "expiryMs": credit.expiry_ms,
        "requestId": attempt.request_id, "retry": attempt.sent,
    }), Box::new(prepare));
    attempt.sent |= sent.get();
    let attempts = ledger.entry(owner.into()).or_default();
    let delay = match outcome.as_deref() {
        Ok("cancelled") => {
            if let Some(previous) = previous {
                attempts.insert(credit.id, previous);
            } else {
                attempts.remove(&credit.id);
            }
            RETRY_MS
        }
        Ok("success" | "no_credit" | "nothing_to_reset") => {
            attempt.terminal = true;
            attempts.insert(credit.id, attempt);
            1_000
        }
        _ => {
            attempts.insert(credit.id, attempt);
            log::warn!("Codex automatic reset was not confirmed");
            RETRY_MS
        }
    };
    if let Err(error) = save(path, ledger) {
        log::error!("Codex auto reset could not persist claim outcome: {error}");
    }
    delay
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ledger_replays_the_same_request_after_reload_at_most_three_times() {
        let tmp = std::env::temp_dir().join(format!("quotabar-auto-reset-{}", Uuid::new_v4()));
        fs::create_dir_all(&tmp).unwrap();
        let path = tmp.join("attempts.json");
        let mut ledger = load(&path).unwrap();
        let credit = Credit { id: "exact".into(), expiry_ms: 100_000 };
        let request = std::cell::RefCell::new(None);
        for count in 0..3 {
            let now = 40_000 + count * RETRY_MS;
            let live = if count == 0 { vec![credit.clone()] } else { vec![] };
            assert_eq!(attempt_due_at(&path, &mut ledger, "owner", live, |name, args, prepare| {
                assert_eq!(name, "claimAutomaticReset");
                assert_eq!(args["accountId"], "owner");
                assert_eq!(args["id"], "exact");
                assert_eq!(args["retry"], count > 0);
                assert!(prepare());
                let stored = load(&path).unwrap();
                let entry = &stored["owner"]["exact"];
                assert!(entry.sent);
                assert_eq!(args["requestId"], entry.request_id.to_string());
                assert_eq!(*request.borrow_mut().get_or_insert(entry.request_id), entry.request_id);
                Err("response lost".into())
            }, now), RETRY_MS);
            ledger = load(&path).unwrap();
        }
        assert_eq!(attempt_due_at(&path, &mut ledger, "owner", vec![credit], |_, _, _| panic!("fourth attempt"), 85_000), PATROL_MS);
        fs::remove_dir_all(tmp).unwrap();
    }

    #[test]
    fn schedules_inside_the_window_and_does_not_starve_other_credits() {
        let a = Credit { id: "a".into(), expiry_ms: 70_000 };
        let b = Credit { id: "b".into(), expiry_ms: 70_000 };
        let credits = vec![a.clone(), b];
        let mut attempts = BTreeMap::new();
        assert_eq!(eligible_credit(credits.clone(), &attempts, 5_000).unwrap().1, 10_000);
        attempts.insert("a".into(), Attempt {
            credit: a, request_id: Uuid::new_v4(), count: 1, last_ms: 10_000, terminal: false, sent: true,
        });
        assert_eq!(eligible_credit(credits.clone(), &attempts, 11_000).unwrap().0.id, "b");
        assert_eq!(eligible_credit(vec![], &attempts, 11_000).unwrap().1, 25_000);
        assert!(eligible_credit(credits, &attempts, 70_000).is_none());
    }
}
