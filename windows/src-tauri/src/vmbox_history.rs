use quotabar_core::usage_daily::UsageDailyRow;
use quotabar_core::provider_accounts::verified_history_identities;
use quotabar_core::usage_snapshot::PluginSelection;
use quotabar_core::vmbox_usage::{ReceiptCache, overlay_daily_rows};
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::{Mutex, OnceLock};

pub fn merge(
    rows: Vec<UsageDailyRow>,
    mut providers: BTreeMap<String, String>,
    app_data: &Path,
    instance_id: Option<&str>,
    limit: u32,
) -> Vec<UsageDailyRow> {
    static RECEIPTS: OnceLock<Option<Mutex<ReceiptCache>>> = OnceLock::new();
    let Some(receipts) = RECEIPTS.get_or_init(|| {
        dirs::home_dir().map(|home| {
            Mutex::new(ReceiptCache::new(home.join(".local/share/vmbox/usage")))
        })
    }) else {
        return rows;
    };
    let Ok(mut receipts) = receipts.lock() else {
        log::warn!("Could not read the VM Box receipt cache");
        return rows;
    };
    let now = chrono::Utc::now();
    let mut verified = BTreeMap::new();
    if receipts.has_account_receipts(now) {
        verified = verified_history_identities(app_data).unwrap_or_else(|error| {
            log::warn!("Could not read verified VM Box account identities: {error}");
            BTreeMap::new()
        });
        if let Ok(selection) = PluginSelection::read(app_data) {
            for (id, instance) in selection.provider_instances {
                if verified.contains_key(&id) && matches!(instance.base_provider_id.as_str(), "claude" | "codex") {
                    let Some(display_name) = providers.get(&instance.base_provider_id) else {
                        continue;
                    };
                    providers.insert(id, format!("{display_name} ({})", instance.label));
                }
            }
        }
    }
    let imported = receipts.read_rows(&providers, &verified, instance_id, now);
    overlay_daily_rows(rows, imported, limit)
}
