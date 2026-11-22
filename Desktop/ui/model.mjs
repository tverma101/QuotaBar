// QuotaBar desktop preview — pure model layer.
// No DOM, no Tauri: prefs, formatting, error classification and the refresh
// state machine live here so `node --test` can drive them hermetically.

export const PROVIDERS = [
    { id: 'claude', label: 'Claude' },
    { id: 'codex', label: 'Codex' },
    { id: 'openrouter', label: 'OpenRouter' },
    { id: 'zai', label: 'Z.ai' },
];
export const PROVIDER_IDS = PROVIDERS.map((provider) => provider.id);

export const LIVE_PREFS_KEY = 'quotabar.live.enabled.v1';
export const DEMO_PREFS_KEY = 'quotabar.demo.enabled.v1';
const LIVE_DEFAULT = ['claude', 'codex'];
const DEMO_DEFAULT = PROVIDER_IDS;

export const REFRESH_INTERVAL_MS = 60_000;

export function prefsKey(demo) {
    return demo ? DEMO_PREFS_KEY : LIVE_PREFS_KEY;
}

export function defaultEnabled(demo) {
    return new Set(demo ? DEMO_DEFAULT : LIVE_DEFAULT);
}

// Strict schema: a stored value must be a JSON array of known provider ids,
// or the default set wins. Corrupted prefs can never widen the enabled set.
export function loadEnabled(storage, demo) {
    let parsed;
    try {
        const raw = storage.getItem(prefsKey(demo));
        if (raw === null || raw === undefined) return defaultEnabled(demo);
        parsed = JSON.parse(raw);
    } catch {
        return defaultEnabled(demo);
    }
    if (!Array.isArray(parsed)) return defaultEnabled(demo);
    const known = new Set(PROVIDER_IDS);
    const enabled = new Set();
    for (const item of parsed) {
        if (typeof item !== 'string' || !known.has(item)) return defaultEnabled(demo);
        enabled.add(item);
    }
    return enabled;
}

export function saveEnabled(storage, demo, enabled) {
    const ordered = PROVIDER_IDS.filter((id) => enabled.has(id));
    try {
        storage.setItem(prefsKey(demo), JSON.stringify(ordered));
    } catch {
        // Persist is best-effort: the in-session enable set still applies.
        console.warn('QuotaBar: provider preferences could not be saved.');
    }
}

// ---------------------------------------------------------------------------
// Errors: the Rust side sends a JSON envelope {"kind","message"}; anything
// else is shown as-is but classified 'unknown'.
// ---------------------------------------------------------------------------

export function classifyError(raw) {
    if (typeof raw === 'string') {
        try {
            const parsed = JSON.parse(raw);
            if (
                parsed && typeof parsed === 'object' &&
                typeof parsed.kind === 'string' &&
                typeof parsed.message === 'string'
            ) {
                return { kind: parsed.kind, message: parsed.message };
            }
        } catch {
            // Plain text error — show it directly.
        }
        return { kind: 'unknown', message: raw };
    }
    return { kind: 'unknown', message: 'Something went wrong. Try again.' };
}

// Auth/setup failures mean the old snapshot belongs to a different or dead
// credential — it must go, not linger as a plausible-looking stale read.
export function clearsLastGood(kind) {
    return kind === 'setup' || kind === 'auth';
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

const usd = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' });

function trimNumber(value) {
    if (!Number.isFinite(value)) return '0';
    return Number.isInteger(value) ? String(value) : String(Math.round(value * 10) / 10);
}

export function formatValue(metric) {
    if (!Number.isFinite(metric?.value)) return 'Unavailable';
    const value = metric.value;
    switch (metric?.unit) {
        case 'percent':
            return `${trimNumber(value)}%`;
        case 'usd':
            return metric.limit ? `${usd.format(value)} of ${usd.format(metric.limit)}` : usd.format(value);
        case 'count':
            return metric.limit ? `${trimNumber(value)} of ${trimNumber(metric.limit)}` : trimNumber(value);
        default:
            return trimNumber(value);
    }
}

export function formatReset(resetAtMs, nowMs) {
    if (!Number.isFinite(resetAtMs) || !Number.isFinite(nowMs)) return null;
    const deltaMs = resetAtMs - nowMs;
    if (deltaMs <= 0) return 'Reset due';
    const minutes = Math.floor(deltaMs / 60_000);
    if (minutes < 1) return 'Reset in <1m';
    if (minutes < 60) return `Reset in ${minutes}m`;
    const hours = Math.floor(minutes / 60);
    const remMinutes = minutes % 60;
    if (hours < 24) return remMinutes ? `Reset in ${hours}h ${remMinutes}m` : `Reset in ${hours}h`;
    const days = Math.floor(hours / 24);
    const remHours = hours % 24;
    return remHours ? `Reset in ${days}d ${remHours}h` : `Reset in ${days}d`;
}

export function formatAge(updatedAtMs, nowMs) {
    if (!Number.isFinite(updatedAtMs) || !Number.isFinite(nowMs)) return '';
    const minutes = Math.floor(Math.max(0, nowMs - updatedAtMs) / 60_000);
    if (minutes < 1) return 'just now';
    if (minutes < 60) return `${minutes}m ago`;
    const hours = Math.floor(minutes / 60);
    if (hours < 24) return `${hours}h ${minutes % 60}m ago`;
    return `${Math.floor(hours / 24)}d ago`;
}

// ---------------------------------------------------------------------------
// Dashboard state machine. Per provider: an epoch-guarded single-flight
// refresh, a last-good snapshot kept only for transient errors, and no
// persisted snapshots at all.
// ---------------------------------------------------------------------------

export function createDashboard({ invoke, storage, now = () => Date.now(), onChange = () => {} }) {
    const entries = new Map(
        PROVIDER_IDS.map((id) => [
            id,
            {
                id,
                status: 'disabled', // disabled | idle | loading | ready | error
                snapshot: null,
                error: null, // {kind, message}
                epoch: 0,
                refreshing: false,
                lastRefresh: 0,
                expanded: false,
            },
        ]),
    );
    const state = { demo: false, enabled: new Set(), entries, ready: false };

    const emit = () => onChange(state);

    async function refresh(id) {
        const entry = entries.get(id);
        if (!entry || !state.enabled.has(id) || entry.refreshing) return;
        entry.epoch += 1;
        const epoch = entry.epoch;
        entry.refreshing = true;
        if (entry.status === 'idle' || (entry.status === 'error' && !entry.snapshot)) {
            entry.status = 'loading';
        }
        emit();

        let result;
        try {
            result = { snapshot: await invoke('refresh', { provider: id }) };
        } catch (raw) {
            result = { error: raw };
        }

        // Entry identity check: a disable/re-enable bumps the epoch and wipes
        // the entry, so an old in-flight result can never land on the new one.
        const live = entries.get(id);
        if (live.epoch !== epoch || !state.enabled.has(id)) return;
        live.refreshing = false;
        live.lastRefresh = now();

        if ('error' in result) {
            const error = classifyError(result.error);
            if (clearsLastGood(error.kind)) live.snapshot = null;
            live.error = error;
            live.status = 'error';
        } else {
            live.snapshot = result.snapshot;
            live.error = null;
            live.status = 'ready';
        }
        emit();
    }

    function refreshAll() {
        for (const id of PROVIDER_IDS) {
            if (state.enabled.has(id)) void refresh(id);
        }
    }

    // A provider is due when its last successful-or-failed attempt is older
    // than the interval (or it has never refreshed). Used by the 60s visible
    // timer and by return-to-visible catch-up.
    function isDue(intervalMs = REFRESH_INTERVAL_MS) {
        const at = now();
        for (const id of PROVIDER_IDS) {
            const entry = entries.get(id);
            if (state.enabled.has(id) && at - entry.lastRefresh >= intervalMs) return true;
        }
        return false;
    }

    function setEnabled(id, on) {
        const entry = entries.get(id);
        if (!entry) return;
        if (on) {
            if (state.enabled.has(id)) return;
            state.enabled.add(id);
            saveEnabled(storage, state.demo, state.enabled);
            entry.status = 'loading';
            emit();
            void refresh(id); // fresh fetch — never reuses anything
        } else {
            if (!state.enabled.delete(id)) return;
            saveEnabled(storage, state.demo, state.enabled);
            entry.epoch += 1; // invalidate any in-flight result
            entry.refreshing = false;
            entry.snapshot = null; // discard: a different account must not resurface
            entry.error = null;
            entry.status = 'disabled';
            emit();
        }
    }

    async function init() {
        state.demo = Boolean(await invoke('is_demo', {}));
        state.enabled = loadEnabled(storage, state.demo);
        for (const id of PROVIDER_IDS) {
            entries.get(id).status = state.enabled.has(id) ? 'loading' : 'disabled';
        }
        state.ready = true;
        emit();
        refreshAll();
    }

    return { state, init, refresh, refreshAll, setEnabled, isDue };
}
