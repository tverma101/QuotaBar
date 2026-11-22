// QuotaBar desktop preview — DOM wiring over the pure model in model.mjs.
// Everything rendered is built with createElement/textContent: no HTML
// injection of provider data is possible.

import * as model from './model.mjs';

const els = {
    demoBadge: document.getElementById('demo-badge'),
    bridgeWarning: document.getElementById('bridge-warning'),
    dashboard: document.getElementById('dashboard'),
    customize: document.getElementById('customize'),
    customizeList: document.getElementById('customize-list'),
    statusLine: document.getElementById('status-line'),
    refreshAll: document.getElementById('refresh-all'),
    navDashboard: document.getElementById('nav-dashboard'),
    navCustomize: document.getElementById('nav-customize'),
};

const customizeRows = new Map(); // provider id -> {checkbox, note}
const cards = new Map(); // provider id -> refs

const bridge = globalThis.__TAURI__;
if (!bridge?.core?.invoke) {
    els.bridgeWarning.hidden = false;
    els.refreshAll.disabled = true;
    els.navCustomize.disabled = true;
} else {
    const dashboard = model.createDashboard({
        invoke: bridge.core.invoke.bind(bridge.core),
        storage: globalThis.localStorage,
        onChange: render,
    });
    wireViews(dashboard);
    void dashboard.init().catch(() => {
        els.bridgeWarning.hidden = false;
        els.refreshAll.disabled = true;
        els.navCustomize.disabled = true;
    });

    // Refresh cadence: every 60s while visible; on return only when due.
    setInterval(() => {
        if (document.visibilityState === 'visible' && dashboard.isDue()) dashboard.refreshAll();
    }, model.REFRESH_INTERVAL_MS);
    document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'visible' && dashboard.isDue()) dashboard.refreshAll();
    });

    // Tray "Refresh" — runs even while the window is hidden. A listen failure
    // is non-fatal: the window controls keep working.
    if (bridge.event?.listen) {
        bridge.event
            .listen('quotabar:refresh', () => dashboard.refreshAll())
            .catch(() => console.warn('QuotaBar: tray refresh events are unavailable in this build.'));
    }

    // Countdowns tick without spamming aria-live or rebuilding the cards.
    setInterval(updateCountdowns, 30_000);
}

// ---------------------------------------------------------------------------
// View switching + controls
// ---------------------------------------------------------------------------

function wireViews(dashboard) {
    const showDashboard = () => {
        els.dashboard.hidden = false;
        els.customize.hidden = true;
        els.navDashboard.setAttribute('aria-pressed', 'true');
        els.navCustomize.setAttribute('aria-pressed', 'false');
    };
    const showCustomize = () => {
        els.dashboard.hidden = true;
        els.customize.hidden = false;
        els.navDashboard.setAttribute('aria-pressed', 'false');
        els.navCustomize.setAttribute('aria-pressed', 'true');
    };
    els.navDashboard.addEventListener('click', showDashboard);
    els.navCustomize.addEventListener('click', showCustomize);
    els.refreshAll.addEventListener('click', () => dashboard.refreshAll());

    for (const provider of model.PROVIDERS) {
        const li = document.createElement('li');
        const checkbox = document.createElement('input');
        checkbox.type = 'checkbox';
        checkbox.id = `enable-${provider.id}`;
        checkbox.checked = dashboard.state.enabled.has(provider.id);
        checkbox.addEventListener('change', () => dashboard.setEnabled(provider.id, checkbox.checked));
        const name = document.createElement('label');
        name.className = 'customize-name';
        name.htmlFor = checkbox.id;
        name.textContent = provider.label;
        const note = document.createElement('span');
        note.className = 'customize-note';
        li.append(checkbox, name, note);
        els.customizeList.append(li);
        customizeRows.set(provider.id, { checkbox, note });
    }
}

// ---------------------------------------------------------------------------
// Rendering — per-provider cards mutate in place so focus and the expanded
// state of the On Demand group survive refresh-driven updates.
// ---------------------------------------------------------------------------

function cardRefs(provider) {
    let refs = cards.get(provider.id);
    if (refs) return refs;

    const root = document.createElement('article');
    root.className = 'card';
    root.dataset.provider = provider.id;

    const head = document.createElement('header');
    head.className = 'card-head';
    const chip = document.createElement('span');
    chip.className = 'chip';
    chip.setAttribute('aria-hidden', 'true');
    chip.textContent = provider.label.slice(0, 1);
    const title = document.createElement('h2');
    title.textContent = provider.label;
    const dot = document.createElement('span');
    dot.className = 'state-dot';
    dot.setAttribute('aria-hidden', 'true');
    head.append(chip, title, dot);

    const warning = document.createElement('div');
    warning.className = 'card-warning';
    warning.hidden = true;

    const metrics = document.createElement('ul');
    metrics.className = 'metrics';

    const details = document.createElement('details');
    details.className = 'ondemand';
    const summary = document.createElement('summary');
    summary.textContent = 'On Demand';
    const odMetrics = document.createElement('ul');
    odMetrics.className = 'metrics-od';
    details.append(summary, odMetrics);

    const empty = document.createElement('p');
    empty.className = 'card-empty';
    empty.hidden = true;
    empty.textContent = 'No Usage Reported';

    const status = document.createElement('p');
    status.className = 'card-status';
    status.hidden = true;

    root.append(head, warning, metrics, details, empty, status);
    els.dashboard.append(root);

    refs = { root, warning, metrics, details, odMetrics, empty, status, resetEls: [] };
    cards.set(provider.id, refs);
    return refs;
}

function render(state) {
    els.demoBadge.hidden = !state.demo;

    let refreshing = 0;
    let freshest = 0;
    for (const provider of model.PROVIDERS) {
        const entry = state.entries.get(provider.id);
        updateCard(provider, entry, state);
        if (entry.refreshing) refreshing += 1;
        // Freshness is the newest snapshot's own timestamp — a failed attempt
        // must not masquerade as a fresh update.
        freshest = Math.max(freshest, entry.snapshot?.updatedAtMs ?? 0);
        const row = customizeRows.get(provider.id);
        if (row) {
            row.checkbox.checked = state.enabled.has(provider.id);
            row.note.textContent = entryNote(entry, state);
        }
    }

    els.refreshAll.disabled = refreshing > 0;
    els.statusLine.textContent = refreshing > 0
        ? 'Refreshing…'
        : freshest > 0 ? `Updated ${model.formatAge(freshest, Date.now())}` : '';
}

function entryNote(entry, state) {
    if (!state.enabled.has(entry.id)) return 'Off';
    if (entry.refreshing) return 'Refreshing…';
    if (entry.status === 'error') return 'Error';
    if (entry.status === 'ready') return state.demo ? 'Demo' : 'Live';
    return '';
}

function updateCard(provider, entry, state) {
    const refs = cardRefs(provider);
    const enabled = state.enabled.has(provider.id);

    refs.root.classList.toggle('is-off', !enabled);
    refs.root.classList.toggle('is-ready', entry.status === 'ready');
    refs.root.classList.toggle('is-error', entry.status === 'error');
    refs.root.classList.toggle('is-loading', entry.refreshing);

    if (!enabled) {
        setStatus(refs, 'Off — enable in Customize.', '');
        refs.metrics.replaceChildren();
        refs.odMetrics.replaceChildren();
        refs.details.hidden = true;
        refs.empty.hidden = true;
        refs.warning.hidden = true;
        return;
    }

    // Status line precedence: a refresh in flight with nothing to show yet
    // reads "Loading…", not a leftover error from the previous attempt.
    if (entry.refreshing && !entry.snapshot) {
        setStatus(refs, 'Loading…', '');
    } else if (entry.error && !entry.snapshot) {
        setStatus(refs, entry.error.message, 'is-error');
    } else if (!entry.error) {
        setStatus(refs, '', '');
    }
    // error + snapshot is handled inside renderMetrics (stale note).

    refs.warning.hidden = !entry.snapshot?.warning;
    if (entry.snapshot?.warning) refs.warning.textContent = entry.snapshot.warning;

    if (entry.snapshot) {
        renderMetrics(refs, entry, Boolean(entry.error));
    } else {
        refs.metrics.replaceChildren();
        refs.odMetrics.replaceChildren();
        refs.details.hidden = true;
        refs.empty.hidden = entry.refreshing || Boolean(entry.error);
    }
}

function setStatus(refs, text, extraClass) {
    refs.status.hidden = text === '';
    refs.status.textContent = text;
    refs.status.className = `card-status ${extraClass}`.trim();
}

function renderMetrics(refs, entry, stale) {
    const visible = entry.snapshot.metrics.filter((m) => !m.onDemand);
    const onDemand = entry.snapshot.metrics.filter((m) => m.onDemand);
    refs.resetEls = [];

    refs.metrics.replaceChildren(...visible.map((metric) => metricRow(refs, metric)));
    refs.odMetrics.replaceChildren(...onDemand.map((metric) => metricRow(refs, metric)));

    refs.details.hidden = onDemand.length === 0;
    refs.details.open = entry.expanded;
    if (!refs.details.dataset.wired) {
        refs.details.dataset.wired = '1';
        refs.details.addEventListener('toggle', () => {
            entry.expanded = refs.details.open;
        });
    }

    const noneShown = visible.length === 0 && onDemand.length === 0;
    refs.empty.hidden = !noneShown;
    if (noneShown) refs.empty.textContent = 'No Usage Reported';

    if (stale) {
        setStatus(
            refs,
            `${entry.error.message} Showing last update from ${new Date(entry.snapshot.updatedAtMs).toLocaleTimeString()}.`,
            'is-stale',
        );
    }
}

function metricRow(refs, metric) {
    const li = document.createElement('li');
    li.className = 'metric';

    const head = document.createElement('div');
    head.className = 'metric-head';
    const label = document.createElement('span');
    label.className = 'metric-label';
    label.textContent = metric.label;
    const value = document.createElement('span');
    value.className = 'metric-value';
    value.textContent = model.formatValue(metric);
    head.append(label, value);
    li.append(head);

    if (Number.isFinite(metric.limit)) {
        const bar = document.createElement('div');
        bar.className = 'bar';
        bar.setAttribute('role', 'meter');
        bar.setAttribute('aria-valuemin', '0');
        bar.setAttribute('aria-valuemax', String(metric.limit));
        // Clamp the numeric position inside the range; the true reported value
        // (including overage) stays in the accessible text.
        bar.setAttribute(
            'aria-valuenow',
            String(Math.min(metric.limit, Math.max(0, metric.value))),
        );
        bar.setAttribute('aria-valuetext', value.textContent);
        bar.setAttribute('aria-label', metric.label);
        const fill = document.createElement('div');
        fill.className = 'bar-fill';
        const ratio = metric.limit > 0 ? Math.min(1, Math.max(0, metric.value / metric.limit)) : 0;
        fill.style.width = `${Math.round(ratio * 100)}%`;
        bar.append(fill);
        li.append(bar);
    }

    const reset = document.createElement('div');
    reset.className = 'metric-reset';
    reset.dataset.resetAt = Number.isFinite(metric.resetAtMs) ? String(metric.resetAtMs) : '';
    reset.textContent = model.formatReset(metric.resetAtMs, Date.now()) ?? '';
    reset.hidden = reset.textContent === '';
    refs.resetEls.push(reset);
    li.append(reset);

    return li;
}

// Re-stamp countdown text only — quiet for screen readers and focus.
function updateCountdowns() {
    const now = Date.now();
    for (const el of document.querySelectorAll('.metric-reset')) {
        if (!el.dataset.resetAt) continue; // '' would coerce to epoch 0
        const at = Number(el.dataset.resetAt);
        if (!Number.isFinite(at)) continue;
        el.textContent = model.formatReset(at, now) ?? '';
        el.hidden = el.textContent === '';
    }
}
