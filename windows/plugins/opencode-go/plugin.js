(function () {
  const PROVIDER_ID = "opencode-go";
  const DEFAULT_ROOT = "~/.local/share/opencode";
  const USAGE_URL = "https://opencode.ai/zen/go/v1/usage";
  const LEGACY_CREDENTIALS_IMPORT_MIGRATION_ID = "20260805200742_import_legacy_credentials";
  const FIVE_HOURS_MS = 5 * 60 * 60 * 1000;
  const WEEK_MS = 7 * 24 * 60 * 60 * 1000;
  const MONTH_MS = 30 * 24 * 60 * 60 * 1000;
  const PLACEHOLDER_RESET_TOLERANCE_MS = 2000;
  const LIMITS = {
    session: 12,
    weekly: 30,
    monthly: 60,
  };

  function readNumber(value) {
    const n = Number(value);
    return Number.isFinite(n) ? n : null;
  }

  function readNowMs() {
    return Date.now();
  }

  function clampPercent(used, limit) {
    if (!Number.isFinite(used) || !Number.isFinite(limit) || limit <= 0)
      return 0;
    const percent = (used / limit) * 100;
    if (!Number.isFinite(percent)) return 0;
    return Math.round(Math.max(0, Math.min(100, percent)) * 10) / 10;
  }

  function toIso(ms) {
    if (!Number.isFinite(ms)) return null;
    return new Date(ms).toISOString();
  }

  function startOfUtcWeek(nowMs) {
    const date = new Date(nowMs);
    const offset = (date.getUTCDay() + 6) % 7;
    date.setUTCDate(date.getUTCDate() - offset);
    date.setUTCHours(0, 0, 0, 0);
    return date.getTime();
  }

  function startOfUtcMonth(nowMs) {
    const date = new Date(nowMs);
    return Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), 1, 0, 0, 0, 0);
  }

  function startOfNextUtcMonth(nowMs) {
    const date = new Date(nowMs);
    return Date.UTC(
      date.getUTCFullYear(),
      date.getUTCMonth() + 1,
      1,
      0,
      0,
      0,
      0,
    );
  }

  function shiftMonth(year, month, delta) {
    const total = year * 12 + month + delta;
    return [Math.floor(total / 12), ((total % 12) + 12) % 12];
  }

  function anchorMonth(year, month, anchorDate) {
    const maxDay = new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
    return Date.UTC(
      year,
      month,
      Math.min(anchorDate.getUTCDate(), maxDay),
      anchorDate.getUTCHours(),
      anchorDate.getUTCMinutes(),
      anchorDate.getUTCSeconds(),
      anchorDate.getUTCMilliseconds(),
    );
  }

  function anchoredMonthBounds(nowMs, anchorMs) {
    if (!Number.isFinite(anchorMs)) {
      const startMs = startOfUtcMonth(nowMs);
      return { startMs, endMs: startOfNextUtcMonth(nowMs) };
    }

    const nowDate = new Date(nowMs);
    const anchorDate = new Date(anchorMs);
    let year = nowDate.getUTCFullYear();
    let month = nowDate.getUTCMonth();
    let startMs = anchorMonth(year, month, anchorDate);

    if (startMs > nowMs) {
      const previous = shiftMonth(year, month, -1);
      year = previous[0];
      month = previous[1];
      startMs = anchorMonth(year, month, anchorDate);
    }

    const next = shiftMonth(year, month, 1);
    return {
      startMs,
      endMs: anchorMonth(next[0], next[1], anchorDate),
    };
  }

  function sumRange(rows, startMs, endMs) {
    let total = 0;
    for (let i = 0; i < rows.length; i += 1) {
      const row = rows[i];
      if (row.createdMs < startMs || row.createdMs >= endMs) continue;
      total += row.cost;
    }
    return Math.round(total * 10000) / 10000;
  }

  function nextRollingReset(rows, nowMs) {
    const startMs = nowMs - FIVE_HOURS_MS;
    let oldest = null;
    for (let i = 0; i < rows.length; i += 1) {
      const row = rows[i];
      if (row.createdMs < startMs || row.createdMs >= nowMs) continue;
      if (oldest === null || row.createdMs < oldest) oldest = row.createdMs;
    }
    return toIso((oldest === null ? nowMs : oldest) + FIVE_HOURS_MS);
  }

  function dataRoot(ctx) {
    const explicit = (ctx.host.env.get("OPENCODE_DATA_DIR") || "").trim();
    const xdg = (ctx.host.env.get("XDG_DATA_HOME") || "").trim();
    return (explicit || (xdg ? xdg.replace(/[\\/]+$/, "") + "/opencode" : DEFAULT_ROOT)).replace(/[\\/]+$/, "");
  }

  function databasePaths(ctx, root) {
    if (!ctx.host.fs.exists(root)) return [];
    return ctx.host.fs.listDir(root).filter(name => /^opencode[^\\/]*\.db$/.test(name))
      .sort().map(name => root + "/" + name);
  }

  function queryRows(ctx, sql, dbPath) {
    try {
      const raw = ctx.host.sqlite.query(dbPath, sql);
      const rows = Array.isArray(raw) ? raw : ctx.util.tryParseJson(raw);
      if (!Array.isArray(rows)) {
        ctx.host.log.warn("sqlite query returned non-array result");
        return { ok: false, rows: [] };
      }
      return { ok: true, rows };
    } catch (e) {
      ctx.host.log.warn("sqlite query failed: " + String(e));
      return { ok: false, rows: [] };
    }
  }

  function loadAuthKey(ctx, root, paths) {
    const providerKey = ctx.util.providerApiKey && ctx.util.providerApiKey()
    if (providerKey) {
      ctx.host.log.info("api key loaded from provider account")
      return providerKey
    }
    const dbResult = loadGoKeyFromDatabases(ctx, paths);
    if (dbResult.key) return dbResult.key;
    if (dbResult.imported) return null;

    const authPath = root + "/auth.json";
    if (ctx.host.fs.exists(authPath)) {
      try {
        const text = ctx.host.fs.readText(authPath);
        const parsed = ctx.util.tryParseJson(text);
        if (!parsed || typeof parsed !== "object") {
          ctx.host.log.warn("opencode auth file is not valid json");
        } else {
          const entry = parsed[PROVIDER_ID];
          const key = entry && typeof entry.key === "string" ? entry.key.trim() : "";
          if (key) return key;
        }
      } catch (e) {
        ctx.host.log.warn("opencode auth read failed: " + String(e));
      }
    }
    return null;
  }

  function loadGoKeyFromDatabases(ctx, paths) {
    const migrationSql =
      "SELECT 1 AS present FROM migration WHERE id = '" +
      LEGACY_CREDENTIALS_IMPORT_MIGRATION_ID +
      "' LIMIT 1";
    const sql =
      "SELECT json_extract(value,'$.key') AS key FROM credential WHERE integration_id = 'opencode-go' AND (active IS NULL OR active = 1) ORDER BY active DESC, time_updated DESC, id DESC LIMIT 1";
    let anyImported = false;
    for (let i = 0; i < paths.length; i += 1) {
      if (!ctx.host.fs.exists(paths[i])) continue;
      const migrationResult = queryRows(ctx, migrationSql, paths[i]);
      const imported = migrationResult.ok && migrationResult.rows.length > 0;
      if (imported) anyImported = true;
      const result = queryRows(ctx, sql, paths[i]);
      const row = result.ok && result.rows[0];
      const key = row && (row.key || row["json_extract(value,'$.key')"]);
      if (typeof key === "string" && key.trim()) {
        return { imported, key: key.trim() };
      }
    }
    return { imported: anyImported, key: null };
  }

  function loadHistory(ctx, paths) {
    const rows = [];
    const seen = new Set();
    const usage = "json_object('cost', data -> '$.cost', 'tokens', data -> '$.tokens') AS usage";
    const nestedProvider = "json_extract(data,'$.model.providerID')";
    const legacyProvider = "json_extract(data,'$.providerID')";
    for (const path of paths) {
      const schema = queryRows(ctx, "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('message','session_message')", path);
      if (!schema.ok) return { ok: false, rows: [] };
      const tables = new Set(schema.rows.map(row => row.name));
      const queries = [];
      if (tables.has("session_message")) {
        queries.push(`
          SELECT id, time_created AS createdMs, ${usage},
            COALESCE(${nestedProvider},${legacyProvider}) AS providerId FROM session_message
          WHERE type='assistant' AND json_valid(data)
            AND providerId IN ('opencode-go','opencode')`);
      }
      if (tables.has("message")) {
        queries.push(`
          SELECT id, COALESCE(json_extract(data,'$.time.created'),time_created) AS createdMs, ${usage},
            COALESCE(${legacyProvider},${nestedProvider}) AS providerId FROM message
          WHERE json_valid(data) AND json_extract(data,'$.role')='assistant'
            AND providerId IN ('opencode-go','opencode')`);
      }
      for (const sql of queries) {
        const result = queryRows(ctx, sql, path);
        if (!result.ok) return { ok: false, rows: [] };
        for (const row of result.rows) {
          if (row.id && seen.has(row.id)) continue;
          const parsed = ctx.util.tryParseJson(row.usage);
          const createdMs = row.createdMs;
          if (!parsed || !Number.isFinite(createdMs) || createdMs <= 0) continue;
          const cost = Number.isFinite(parsed.cost) && parsed.cost >= 0 ? parsed.cost : null;
          const usage = parsed.tokens;
          const buckets = usage && [usage.input, usage.output, usage.reasoning ?? 0, usage.cache?.read ?? 0, usage.cache?.write ?? 0];
          const tokens = Number.isSafeInteger(usage?.total) && usage.total > 0 ? usage.total :
            buckets?.every(n => Number.isSafeInteger(n) && n >= 0) ? buckets.reduce((sum, n) => sum + n, 0) : 0;
          if (cost === null && !tokens) continue;
          if (row.id) seen.add(row.id);
          rows.push({ createdMs, cost, tokens, go: row.providerId === "opencode-go" });
        }
      }
    }
    return { ok: true, rows };
  }

  function buildProgressLines(ctx, rows, nowMs) {
    const sessionStartMs = nowMs - FIVE_HOURS_MS;
    const weeklyStartMs = startOfUtcWeek(nowMs);
    const weeklyEndMs = weeklyStartMs + WEEK_MS;
    let earliestMs = null;
    for (let i = 0; i < rows.length; i += 1) {
      const createdMs = rows[i].createdMs;
      if (!Number.isFinite(createdMs)) continue;
      if (earliestMs === null || createdMs < earliestMs) earliestMs = createdMs;
    }
    const monthBounds = anchoredMonthBounds(nowMs, earliestMs);
    const monthlyStartMs = monthBounds.startMs;
    const monthlyEndMs = monthBounds.endMs;

    const sessionCost = sumRange(rows, sessionStartMs, nowMs);
    const weeklyCost = sumRange(rows, weeklyStartMs, weeklyEndMs);
    const monthlyCost = sumRange(rows, monthlyStartMs, monthlyEndMs);

    return [
      ctx.line.progress({
        label: "Session",
        used: clampPercent(sessionCost, LIMITS.session),
        limit: 100,
        format: { kind: "percent" },
        resetsAt: nextRollingReset(rows, nowMs),
        periodDurationMs: FIVE_HOURS_MS,
      }),
      ctx.line.progress({
        label: "Weekly",
        used: clampPercent(weeklyCost, LIMITS.weekly),
        limit: 100,
        format: { kind: "percent" },
        resetsAt: toIso(weeklyEndMs),
        periodDurationMs: WEEK_MS,
      }),
      ctx.line.progress({
        label: "Monthly",
        used: clampPercent(monthlyCost, LIMITS.monthly),
        limit: 100,
        format: { kind: "percent" },
        resetsAt: toIso(monthlyEndMs),
        periodDurationMs: monthlyEndMs - monthlyStartMs,
      }),
    ];
  }

  function buildSoftEmptyLines(ctx) {
    return [
      ctx.line.badge({
        label: "Status",
        text: "No usage data",
        color: "#a3a3a3",
      }),
    ];
  }

  function appendHistory(ctx, lines, rows, nowMs) {
    const daily = new Map();
    const dayKey = ms => {
      const date = new Date(ms);
      return [date.getFullYear(), date.getMonth() + 1, date.getDate()]
        .map(part => String(part).padStart(2, "0")).join("-");
    };
    for (const row of rows) {
      if (row.createdMs > nowMs + 300000) continue;
      const day = dayKey(row.createdMs);
      const record = daily.get(day) || { date: day, totalTokens: 0, totalCost: 0, unpriced: false };
      record.totalTokens += row.tokens;
      record.totalCost += row.cost ?? 0;
      record.unpriced ||= row.cost === null && row.tokens > 0;
      daily.set(day, record);
    }
    const days = [...daily.values()].sort((a, b) => a.date.localeCompare(b.date));
    if (!days.length) return;
    ctx.host.usageDaily.ingest({ displayName: "OpenCode Go", daily: days.map(({ date, totalTokens, totalCost, unpriced }) =>
      ({ date, totalTokens, totalCost: unpriced ? null : totalCost })) });
    const today = new Date(nowMs);
    const yesterday = new Date(nowMs);
    yesterday.setDate(today.getDate() - 1);
    const cutoff = new Date(nowMs);
    cutoff.setDate(today.getDate() - 29);
    const recent = days.filter(day => day.date >= dayKey(cutoff));
    for (const [label, entries] of [
      ["Today", [daily.get(dayKey(nowMs))]],
      ["Yesterday", [daily.get(dayKey(yesterday.getTime()))]],
      ["Last 30 Days", recent],
    ]) {
      const available = entries.filter(Boolean);
      if (!available.length) continue;
      const tokens = available.reduce((total, row) => total + row.totalTokens, 0);
      const cost = available.reduce((total, row) => total + row.totalCost, 0);
      const value = tokens.toLocaleString() + " tokens";
      lines.push(ctx.line.text({ label,
        value: available.some(row => row.unpriced) ? value : "$" + cost.toFixed(2) + " · " + value }));
    }
    if (recent.length) lines.push(ctx.line.barChart({
      label: "Usage Trend", note: "From your OpenCode logs",
      points: recent.map(day => ({ label: Number(day.date.slice(5, 7)) + "/" + Number(day.date.slice(8)),
        value: day.totalTokens, valueLabel: day.totalTokens.toLocaleString() + " tokens" })),
    }));
  }

  function clampReportedPercent(value) {
    const n = readNumber(value);
    if (n === null) return null;
    return Math.round(Math.max(0, Math.min(100, n)) * 10) / 10;
  }

  function readHeaderValue(headers, name) {
    if (!headers || typeof headers !== "object") return null;
    const target = name.toLowerCase();
    for (const key of Object.keys(headers)) {
      if (key.toLowerCase() === target && typeof headers[key] === "string") {
        return headers[key];
      }
    }
    return null;
  }

  function parseReferenceTimeMs(resp, fallbackMs) {
    const dateHeader = readHeaderValue(resp && resp.headers, "date");
    if (dateHeader) {
      const parsed = Date.parse(dateHeader.trim());
      if (Number.isFinite(parsed)) return parsed;
    }
    return fallbackMs;
  }

  function fetchGoMeters(ctx, apiKey) {
    const capturedAtMs = readNowMs();
    let resp;
    try {
      resp = ctx.host.http.request({
        method: "GET",
        url: USAGE_URL,
        headers: {
          Authorization: "Bearer " + apiKey,
          Accept: "application/json",
        },
        timeoutMs: 15000,
      });
    } catch (e) {
      ctx.host.log.error("Go usage API unreachable: " + String(e));
      throw "OpenCode Go usage API unreachable. Check your connection.";
    }

    const status = readNumber(resp && resp.status);
    const bodyText = resp && typeof resp.bodyText === "string" ? resp.bodyText : "";
    const parsed = ctx.util.tryParseJson(bodyText);
    const errorType =
      parsed && parsed.error && typeof parsed.error.type === "string"
        ? parsed.error.type.trim()
        : "";

    if (status === 401) {
      throw "OpenCode Go key was rejected. Log into OpenCode Go again.";
    }
    if (status === 403 && errorType === "EntitlementError") {
      throw "No OpenCode Go subscription on this key.";
    }
    if (status === null || status < 200 || status >= 300) {
      throw "OpenCode Go usage API failed (HTTP " + String(status) + ").";
    }
    if (!parsed || typeof parsed !== "object" || !parsed.usage || typeof parsed.usage !== "object") {
      throw "OpenCode Go usage API returned an invalid response.";
    }

    const referenceTimeMs = parseReferenceTimeMs(resp, capturedAtMs);
    const windows = [
      { key: "rolling", label: "Session", periodMs: FIVE_HOURS_MS, dropsPlaceholderReset: true },
      { key: "weekly", label: "Weekly", periodMs: WEEK_MS, dropsPlaceholderReset: false },
      { key: "monthly", label: "Monthly", periodMs: MONTH_MS, dropsPlaceholderReset: false },
    ];
    const lines = [];
    for (let i = 0; i < windows.length; i += 1) {
      const spec = windows[i];
      const raw = parsed.usage[spec.key];
      if (!raw || typeof raw !== "object" || (raw.status && raw.status !== "ok" && raw.status !== "rate-limited")) return null;
      const percent = clampReportedPercent(raw.percent);
      if (raw.percent == null || percent === null) return null;
      const rawResetsAt =
        typeof raw.resetsAt === "string" && raw.resetsAt.trim() ? raw.resetsAt.trim() : null;
      const reportedResetMs = rawResetsAt ? Date.parse(rawResetsAt) : NaN;
      let resetsAt = Number.isFinite(reportedResetMs) ? new Date(reportedResetMs).toISOString() : null;
      if (spec.dropsPlaceholderReset && percent === 0) {
        const distanceFromFullPeriodMs = Math.abs(
          reportedResetMs - referenceTimeMs - spec.periodMs,
        );
        if (distanceFromFullPeriodMs <= PLACEHOLDER_RESET_TOLERANCE_MS) {
          resetsAt = null;
        }
      }
      const progressOpts = {
        label: spec.label,
        used: percent,
        limit: 100,
        format: { kind: "percent" },
        resetsAt,
        periodDurationMs: spec.periodMs,
      };
      if (spec.dropsPlaceholderReset) {
        progressOpts.sessionStartSignal = "missingResetDate";
      }
      lines.push(ctx.line.progress(progressOpts));
    }
    return lines;
  }

  function probe(ctx) {
    const root = dataRoot(ctx);
    const ownsLocalHistory = !ctx.account?.instanceId || ctx.account.instanceId === PROVIDER_ID;
    const paths = ownsLocalHistory ? databasePaths(ctx, root) : [];
    const authKey = ownsLocalHistory ? loadAuthKey(ctx, root, paths) : ctx.util.providerApiKey?.();
    let official = null;
    let accountError = null;
    if (authKey) {
      try {
        official = fetchGoMeters(ctx, authKey);
      } catch (error) {
        accountError = error;
      }
    }
    const history = ownsLocalHistory ? loadHistory(ctx, paths) : { ok: true, rows: [] };
    if (history.ok && ownsLocalHistory && ctx.host.opencodeGateway) {
      const projected = ctx.util.tryParseJson(ctx.host.opencodeGateway.scan());
      if (!Array.isArray(projected)) {
        history.ok = false;
        history.rows = [];
      } else {
        for (const row of projected) history.rows.push(row);
      }
    }
    if (!authKey && history.ok && !history.rows.length) {
      throw "OpenCode Go not detected. Log in with OpenCode Go or use it locally first.";
    }
    if (accountError && !history.rows.length) throw accountError;
    const now = readNowMs();
    const go = official ? [] : history.rows.filter(row => row.go && row.cost !== null && row.createdMs <= now);
    const lines = official || (go.length ? buildProgressLines(ctx, go, now) : []);
    if (history.ok) appendHistory(ctx, lines, history.rows, now);
    else lines.push(ctx.line.badge({ label: "History", text: "Couldn't Read Local OpenCode Usage", color: "#d69b43" }));
    if (accountError) {
      lines.push(ctx.line.badge({ label: "Status", text: String(accountError), color: "#d69b43" }));
    }
    const plan = authKey || go.length || history.rows.some(row => row.go) ? "Go" : history.rows.length ? "Zen" : null;
    return { plan, lines: lines.length ? lines : buildSoftEmptyLines(ctx) };
  }

  globalThis.__openusage_plugin = { id: PROVIDER_ID, probe };
})();
