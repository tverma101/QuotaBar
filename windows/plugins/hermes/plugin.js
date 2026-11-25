(function () {
  const counters = ["input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "reasoning_tokens"]
  const sourceNote = "From your Hermes state database"

  function query(ctx, path, sql) {
    return JSON.parse(ctx.host.sqlite.query(path, sql))
  }

  function aggregateSQL(cutoff, maxTime, detailed, models) {
    const source = detailed ? "session_model_usage u JOIN sessions s ON u.session_id = s.id" : "sessions s"
    const usage = detailed ? "u" : "s"
    const columns = counters.map(name => usage + "." + name)
    const tokens = columns.map(col => "COALESCE(" + col + ",0)").join("+")
    const cost = usage + ".estimated_cost_usd"
    const invalid = [...columns, "s.api_call_count"].map(col =>
      "(" + col + " IS NOT NULL AND (typeof(" + col + ") NOT IN ('integer','real') OR " +
        col + " < 0 OR " + col + " > 1e15 OR " + col + " != CAST(" + col + " AS INTEGER)))")
    invalid.push("(" + cost + " IS NOT NULL AND (typeof(" + cost + ") NOT IN ('integer','real') OR " +
      cost + " < 0 OR " + cost + " > 1e12))")
    invalid.push("((" + tokens + "+COALESCE(s.api_call_count,0)+COALESCE(" + cost + ",0)) > 0 AND " +
      "(typeof(s.started_at) NOT IN ('integer','real') OR s.started_at > " + maxTime + "))")
    return `
      SELECT date(CAST(s.started_at AS INTEGER),'unixepoch','localtime') AS day,
             ${models ? usage + ".model AS model," : ""}
             SUM(CAST((${tokens}) AS REAL)) AS tokens,
             SUM(COALESCE(${cost},0)) AS cost,
             MAX(CASE WHEN (${tokens}) > 0 AND COALESCE(${cost},0) <= 0 THEN 1 ELSE 0 END) AS unpriced,
             MAX(s.ended_at IS NULL) AS partial,
             MAX(${invalid.join(" OR ")}) AS invalid
      FROM ${source}
      WHERE s.started_at >= ${cutoff}
        AND COALESCE(LOWER(s.billing_provider),'') NOT LIKE 'opencode%'
        AND COALESCE(LOWER(s.billing_base_url),'') NOT LIKE '%opencode%'
      GROUP BY day${models ? ", 2" : ""}
      ORDER BY day
    `
  }

  function dayKey(date) {
    return [date.getFullYear(), date.getMonth() + 1, date.getDate()]
      .map(n => String(n).padStart(2, "0")).join("-")
  }

  function merge(rows) {
    return rows.reduce((a, row) => ({
      tokens: a.tokens + row.tokens,
      cost: a.cost + row.cost,
      unpriced: a.unpriced || row.unpriced,
      partial: a.partial || row.partial,
    }), { tokens: 0, cost: 0, unpriced: false, partial: false })
  }

  function tokenLabel(tokens) {
    for (const [unit, scale] of [["B", 1e9], ["M", 1e6], ["K", 1e3]]) {
      if (tokens >= scale) return Number((tokens / scale).toFixed(1)) + unit + " tokens"
    }
    return tokens + " tokens"
  }

  function value(row) {
    const tokens = (row.partial ? "~" : "") + tokenLabel(row.tokens)
    return row.cost > 0 && !row.unpriced ? "~$" + row.cost.toFixed(2) + " · " + tokens : tokens
  }

  function breakdown(rows, totalTokens) {
    const groups = new Map()
    for (const row of rows) {
      const name = (typeof row.model === "string" && row.model.trim()) || "Unattributed"
      if (!groups.has(name)) groups.set(name, [])
      groups.get(name).push(row)
    }
    const ranked = [...groups].map(([model, group]) => ({ model, ...merge(group) }))
      .filter(row => row.tokens > 0 || row.cost > 0)
      .sort((a, b) => b.tokens - a.tokens || a.model.localeCompare(b.model))
    const top = ranked.slice(0, 5)
    if (ranked.length > 5) top.push({ model: "Other", ...merge(ranked.slice(5)) })
    return top.map(row => ({
      model: row.model,
      tokens: row.tokens,
      percent: totalTokens > 0 ? row.tokens / totalTokens * 100 : 0,
      costUsd: row.cost > 0 && !row.unpriced ? row.cost : undefined,
    }))
  }

  function probe(ctx) {
    const home = (ctx.host.env.get("HERMES_HOME") || "").trim() || "~/.hermes"
    const path = home.replace(/[\\/]+$/, "") + "/state.db"
    if (!ctx.host.fs.exists(path)) throw "Hermes not detected. Run Hermes Agent locally first."
    const now = new Date(ctx.nowIso || Date.now())
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate())
    const week = new Date(today)
    week.setDate(today.getDate() - (today.getDay() + 6) % 7)
    const month = new Date(today.getFullYear(), today.getMonth(), 1)
    const oldestPeriod = new Date(Math.min(week.getTime(), month.getTime()))
    const cutoff = new Date(today)
    cutoff.setFullYear(today.getFullYear() - 10)
    const maximum = now.getTime() / 1000 + 300
    let daily, models
    try {
      const detailed = query(ctx, path, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'session_model_usage'").length > 0
      daily = query(ctx, path, aggregateSQL(cutoff.getTime() / 1000, maximum, false, false))
      models = query(ctx, path, aggregateSQL(oldestPeriod.getTime() / 1000, maximum, detailed, true))
      if ([...daily, ...models].some(row => row.invalid || !row.day ||
          !Number.isSafeInteger(row.tokens) || row.tokens > 1e15 || !Number.isFinite(row.cost) || row.cost > 1e12)) {
        throw new Error("invalid accounting row")
      }
    } catch (error) {
      ctx.host.log.warn("Hermes history read failed: " + String(error))
      throw "Hermes usage history could not be read."
    }
    const lines = []
    for (const [label, start] of [["Today", today], ["This Week", week], ["This Month", month]]) {
      const key = dayKey(start)
      const total = merge(daily.filter(row => row.day >= key))
      if (total.tokens > 0 || total.cost > 0) {
        lines.push(ctx.line.text({ label, value: value(total),
          modelBreakdown: breakdown(models.filter(row => row.day >= key), total.tokens) }))
      }
    }
    daily = daily.filter(row => row.tokens > 0 || row.cost > 0)
    if (daily.length) {
      ctx.host.usageDaily.ingest({ displayName: "Hermes", daily: daily.map(row => ({
        date: row.day, totalTokens: row.tokens, totalCost: row.unpriced ? null : row.cost || null,
      })) })
      const earliestTrendDay = new Date(today)
      earliestTrendDay.setDate(today.getDate() - 30)
      const points = daily.filter(row => row.day >= dayKey(earliestTrendDay)).map(row => ({
        label: Number(row.day.slice(5, 7)) + "/" + Number(row.day.slice(8)),
        value: row.tokens,
        valueLabel: value(row),
      }))
      if (points.length) lines.push(ctx.line.barChart({ label: "Usage Trend", points, note: sourceNote }))
    }
    if (!lines.length) lines.push(ctx.line.badge({ label: "Status", text: "No Data" }))
    return { lines }
  }

  globalThis.__openusage_plugin = { id: "hermes", probe }
})()
