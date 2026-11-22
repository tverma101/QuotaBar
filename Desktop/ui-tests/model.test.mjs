import test from 'node:test';
import assert from 'node:assert/strict';
import * as model from '../ui/model.mjs';

function fakeStorage(initial = {}) {
    const map = new Map(Object.entries(initial));
    return {
        getItem: (key) => (map.has(key) ? map.get(key) : null),
        setItem: (key, value) => map.set(key, String(value)),
        map,
    };
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

test('formatValue renders each unit and keeps a real zero', () => {
    assert.equal(model.formatValue({ unit: 'percent', value: 0, limit: 100 }), '0%');
    assert.equal(model.formatValue({ unit: 'percent', value: 37.5, limit: 100 }), '37.5%');
    assert.equal(model.formatValue({ unit: 'usd', value: 3.42 }), '$3.42');
    assert.equal(model.formatValue({ unit: 'usd', value: 30, limit: 100 }), '$30.00 of $100.00');
    assert.equal(model.formatValue({ unit: 'count', value: 34, limit: 100 }), '34 of 100');
    assert.equal(model.formatValue({ unit: 'count', value: 7 }), '7');
    // Missing/non-finite values are 'Unavailable' — never a fake zero.
    assert.equal(model.formatValue({ unit: 'percent' }), 'Unavailable');
    assert.equal(model.formatValue({ unit: 'percent', value: NaN }), 'Unavailable');
    assert.equal(model.formatValue({ unit: 'percent', value: 0 }), '0%');
});

test('formatReset produces compact countdowns and handles edges', () => {
    const now = 1_000_000_000_000;
    assert.equal(model.formatReset(undefined, now), null);
    assert.equal(model.formatReset(now - 1, now), 'Reset due');
    assert.equal(model.formatReset(now + 30_000, now), 'Reset in <1m');
    assert.equal(model.formatReset(now + 42 * 60_000, now), 'Reset in 42m');
    assert.equal(model.formatReset(now + (2 * 60 + 14) * 60_000, now), 'Reset in 2h 14m');
    assert.equal(model.formatReset(now + (3 * 24 + 5) * 3_600_000, now), 'Reset in 3d 5h');
});

// ---------------------------------------------------------------------------
// Preferences
// ---------------------------------------------------------------------------

test('loadEnabled falls back to defaults on every malformed shape', () => {
    const live = model.LIVE_PREFS_KEY;
    for (const raw of ['not json', '"claude"', '42', '["claude","bogus"]', '{"a":1}']) {
        assert.deepEqual(
            [...model.loadEnabled(fakeStorage({ [live]: raw }), false)].sort(),
            ['claude', 'codex'],
            `malformed ${raw} must fall back`,
        );
    }
    // No stored value → defaults per mode.
    assert.deepEqual([...model.loadEnabled(fakeStorage(), false)].sort(), ['claude', 'codex']);
    assert.deepEqual([...model.loadEnabled(fakeStorage(), true)].sort(),
        ['claude', 'codex', 'openrouter', 'zai']);
});

test('a valid stored subset round-trips', () => {
    const storage = fakeStorage();
    model.saveEnabled(storage, false, new Set(['zai', 'claude']));
    const enabled = model.loadEnabled(storage, false);
    assert.deepEqual([...enabled].sort(), ['claude', 'zai']);
});

// ---------------------------------------------------------------------------
// Error classification
// ---------------------------------------------------------------------------

test('classifyError parses the IPC envelope and tolerates plain text', () => {
    assert.deepEqual(
        model.classifyError('{"kind":"auth","message":"sign in again"}'),
        { kind: 'auth', message: 'sign in again' },
    );
    assert.deepEqual(model.classifyError('boom'), { kind: 'unknown', message: 'boom' });
    assert.equal(model.clearsLastGood('auth'), true);
    assert.equal(model.clearsLastGood('setup'), true);
    assert.equal(model.clearsLastGood('network'), false);
});

// ---------------------------------------------------------------------------
// Refresh state machine
// ---------------------------------------------------------------------------

function makeDashboard(invoke, storage = fakeStorage()) {
    const clock = { t: 1_000_000 };
    return {
        dashboard: model.createDashboard({
            invoke,
            storage,
            now: () => clock.t,
            onChange: () => {},
        }),
        clock,
    };
}

const SNAPSHOT = { metrics: [{ id: 'claude.session', label: 'Session', value: 10, limit: 100, unit: 'percent', onDemand: false }], updatedAtMs: 1, warning: null };

test('init enables defaults and refreshes only those providers', async () => {
    const calls = [];
    const { dashboard } = makeDashboard(async (cmd, args) => {
        if (cmd === 'is_demo') return false;
        calls.push(args.provider);
        return SNAPSHOT;
    });
    await dashboard.init();
    // Let queued refresh promises settle.
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.deepEqual(calls.sort(), ['claude', 'codex']);
    assert.equal(dashboard.state.entries.get('claude').status, 'ready');
    assert.equal(dashboard.state.entries.get('openrouter').status, 'disabled');
});

test('transient error keeps last good, auth error clears it', async () => {
    let mode = 'ok';
    const { dashboard } = makeDashboard(async (cmd) => {
        if (cmd === 'is_demo') return false;
        if (mode === 'network') throw '{"kind":"network","message":"offline"}';
        if (mode === 'auth') throw '{"kind":"auth","message":"expired"}';
        return SNAPSHOT;
    });
    await dashboard.init();
    await new Promise((resolve) => setTimeout(resolve, 0));
    const entry = dashboard.state.entries.get('claude');
    assert.equal(entry.status, 'ready');

    mode = 'network';
    await dashboard.refresh('claude');
    assert.equal(entry.status, 'error');
    assert.equal(entry.error.kind, 'network');
    assert.ok(entry.snapshot, 'stale snapshot stays for transient errors');

    mode = 'auth';
    await dashboard.refresh('claude');
    assert.equal(entry.status, 'error');
    assert.equal(entry.snapshot, null, 'auth failure drops last-good');
});

test('disable discards an in-flight result; re-enable fetches fresh', async () => {
    let resolvePending;
    let calls = 0;
    const { dashboard } = makeDashboard(async (cmd) => {
        if (cmd === 'is_demo') return false;
        calls += 1;
        if (calls === 1) return SNAPSHOT;          // init's refresh
        return new Promise((resolve) => { resolvePending = resolve; });
    });
    await dashboard.init();
    await new Promise((resolve) => setTimeout(resolve, 0));

    const entry = dashboard.state.entries.get('claude');
    const inflight = dashboard.refresh('claude'); // hangs until resolvePending
    assert.equal(entry.refreshing, true);

    dashboard.setEnabled('claude', false);
    assert.equal(entry.status, 'disabled');
    assert.equal(entry.snapshot, null);
    resolvePending(SNAPSHOT);
    await inflight;
    assert.equal(entry.status, 'disabled', 'stale async result must be ignored');
    assert.equal(entry.snapshot, null);

    const before = calls;
    dashboard.setEnabled('claude', true);
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.ok(calls > before, 're-enable triggers a fresh fetch');
});

test('no overlapping refresh per provider', async () => {
    let calls = 0;
    const gate = new Promise(() => {});
    const { dashboard } = makeDashboard(async (cmd) => {
        if (cmd === 'is_demo') return true;
        calls += 1;
        return gate;
    });
    await dashboard.init();
    await dashboard.refresh('claude');
    const afterFirst = calls;
    await dashboard.refresh('claude');
    assert.equal(calls, afterFirst, 'second refresh while one is in flight is skipped');
});

test('isDue is false right after refresh and true when idle past interval', async () => {
    const { dashboard, clock } = makeDashboard(async (cmd) =>
        cmd === 'is_demo' ? false : SNAPSHOT);
    await dashboard.init();
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.equal(dashboard.isDue(), false);
    clock.t += model.REFRESH_INTERVAL_MS + 1;
    assert.equal(dashboard.isDue(), true);
});
