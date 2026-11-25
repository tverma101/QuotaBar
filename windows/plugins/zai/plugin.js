(function () {
  const BASE_URL = "https://api.z.ai"
  const SUBSCRIPTION_URL = BASE_URL + "/api/biz/subscription/list"
  const QUOTA_URL = BASE_URL + "/api/monitor/usage/quota/limit"
  const PERIOD_MS = 5 * 60 * 60 * 1000
  const DAY_MS = 24 * 60 * 60 * 1000
  const WEEK_MS = 7 * 24 * 60 * 60 * 1000
  const MONTH_MS = 30 * 24 * 60 * 60 * 1000
  const ERR_INVALID_RESPONSE = "Usage response invalid. Try again later."
  const CONFIG_PATHS = ["~/.config/openusage/zai.json", "~/.config/zai/key.json"]

  function readString(value) {
    return typeof value === "string" ? value.trim() : ""
  }

  function loadApiKey(ctx) {
    const providerKey = ctx.util.providerApiKey && ctx.util.providerApiKey()
    if (providerKey) {
      ctx.host.log.info("api key loaded from provider account")
      return providerKey
    }
    for (const path of CONFIG_PATHS) {
      try {
        if (!ctx.host.fs.exists(path)) continue
        const text = readString(ctx.host.fs.readText(path))
        if (!text) continue
        if (!text.startsWith("{")) return text
        const config = ctx.util.tryParseJson(text)
        if (config) {
          const key = readString(config.apiKey) || readString(config.api_key) || readString(config.key)
          if (key) return key
        }
      } catch {
        ctx.host.log.warn("config read failed for " + path)
      }
    }
    const zai = ctx.host.env.get("ZAI_API_KEY")
    if (typeof zai === "string" && zai.trim()) return zai.trim()

    const glm = ctx.host.env.get("GLM_API_KEY")
    if (typeof glm === "string" && glm.trim()) return glm.trim()

    return null
  }

  function fetchSubscription(ctx, apiKey) {
    try {
      const resp = ctx.util.request({
        method: "GET",
        url: SUBSCRIPTION_URL,
        headers: {
          Authorization: "Bearer " + apiKey,
          Accept: "application/json",
        },
        timeoutMs: 10000,
      })
      if (resp.status < 200 || resp.status >= 300) {
        ctx.host.log.warn("subscription request failed: HTTP " + resp.status)
        return null
      }
      const data = ctx.util.tryParseJson(resp.bodyText)
      if (!data) return null
      const list = data.data
      if (!Array.isArray(list) || list.length === 0) return null
      return {
        productName: list[0].productName || null,
        nextRenewTime: list[0].nextRenewTime || null,
      }
    } catch (e) {
      ctx.host.log.warn("subscription request exception: " + String(e))
      return null
    }
  }

  function fetchQuota(ctx, apiKey) {
    let resp
    try {
      resp = ctx.util.request({
        method: "GET",
        url: QUOTA_URL,
        headers: {
          Authorization: "Bearer " + apiKey,
          Accept: "application/json",
        },
        timeoutMs: 10000,
      })
    } catch (e) {
      ctx.host.log.error("usage request exception: " + String(e))
      throw "Usage request failed. Check your connection."
    }

    if (ctx.util.isAuthStatus(resp.status)) {
      throw "API key invalid. Check your Z.ai API key."
    }

    if (resp.status < 200 || resp.status >= 300) {
      throw "Usage request failed (HTTP " + String(resp.status) + "). Try again later."
    }

    const data = ctx.util.tryParseJson(resp.bodyText)
    if (!data) {
      throw ERR_INVALID_RESPONSE
    }

    return data
  }

  /// Accept JSON numbers and numeric strings; reject booleans and non-finite values (#951).
  function parseNumber(value) {
    if (typeof value === "boolean") return null
    if (typeof value === "number") {
      return Number.isFinite(value) ? value : null
    }
    if (typeof value === "string") {
      const trimmed = value.trim()
      if (!trimmed) return null
      const n = Number(trimmed)
      return Number.isFinite(n) ? n : null
    }
    return null
  }

  function clampPercent(value) {
    if (!Number.isFinite(value)) return 0
    return Math.min(100, Math.max(0, value))
  }

  function resetIso(ctx, value) {
    const resetMs = parseNumber(value)
    const now = ctx.util.parseDateMs(ctx.nowIso) ?? Date.now()
    if (resetMs === null || resetMs <= now || resetMs - now > 2 * 365 * DAY_MS) return undefined
    return ctx.util.toIso(resetMs)
  }

  function windowDuration(entry) {
    const unit = parseNumber(entry.unit)
    const count = entry.number === undefined ? 1 : parseNumber(entry.number)
    const unitMs = { 3: DAY_MS / 24, 4: DAY_MS, 5: MONTH_MS, 6: WEEK_MS }[unit]
    if (entry.unit === undefined && entry.number === undefined) return PERIOD_MS
    if (unit === null || count === null || count <= 0) throw ERR_INVALID_RESPONSE
    if (unitMs === undefined) return null
    const duration = Math.trunc(unitMs * count)
    if (!Number.isSafeInteger(duration) || duration < 1) throw ERR_INVALID_RESPONSE
    return duration
  }

  function mapTokenProgress(ctx, entry, label, periodMs) {
    const rawPercentage = parseNumber(entry.percentage)
    if (rawPercentage === null) throw ERR_INVALID_RESPONSE
    const used = clampPercent(rawPercentage)
    const resetsAt = resetIso(ctx, entry.nextResetTime)

    const progressOpts = {
      label: label,
      used: used,
      limit: 100,
      format: { kind: "percent" },
      periodDurationMs: periodMs,
    }
    if (resetsAt) progressOpts.resetsAt = resetsAt
    return ctx.line.progress(progressOpts)
  }

  function mapWebSearches(ctx, entry) {
    const used = parseNumber(entry.currentValue)
    const limit = parseNumber(entry.usage)
    if (used === null || limit === null || used < 0 || limit < 0) {
      throw ERR_INVALID_RESPONSE
    }
    if (limit === 0) return null
    const resetsAt = resetIso(ctx, entry.nextResetTime)

    return ctx.line.progress({
      label: "Web Searches",
      used: used,
      limit: limit,
      format: { kind: "count", suffix: "searches" },
      periodDurationMs: MONTH_MS,
      ...(resetsAt ? { resetsAt } : {}),
    })
  }

  function extractLimits(quota) {
    if (!quota || typeof quota !== "object") return null
    // Legacy: some payloads used a bare limits array at the root.
    if (Array.isArray(quota)) return quota
    if (quota.data !== undefined) {
      if (Array.isArray(quota.data)) return null // must be object envelope
      if (!quota.data || typeof quota.data !== "object") return null
      if (quota.data.limits === undefined) return null
      if (!Array.isArray(quota.data.limits)) return null
      return quota.data.limits
    }
    if (quota.limits === undefined) return null
    if (!Array.isArray(quota.limits)) return null
    return quota.limits
  }

  function probeQuota(ctx, apiKey) {

    const quota = fetchQuota(ctx, apiKey)
    const lines = []
    if (quota.success === false && /coding plan/i.test(quota.msg)) {
      lines.push(ctx.line.badge({ label: "Status", text: "No usage data", color: "#a3a3a3" }))
      return { plan: null, lines, warning: "No active GLM Coding Plan. Subscribe at z.ai/subscribe to see usage." }

    }

    const limits = extractLimits(quota)
    if (limits === null) {
      throw ERR_INVALID_RESPONSE
    }
    if (limits.some(entry => !entry || typeof entry !== "object" || Array.isArray(entry))) {
      throw ERR_INVALID_RESPONSE
    }
    let damaged = false
    const mapped = {}
    for (const type of ["TOKENS_LIMIT", "CREDIT_LIMIT", "TIME_LIMIT"]) {
      for (const entry of limits) {
        if (entry.type !== type && entry.name !== type) continue
        try {
          if (type === "TIME_LIMIT") {
            mapped["Web Searches"] ??= mapWebSearches(ctx, entry)
          } else {
            const duration = windowDuration(entry)
            if (duration === null) continue
            const label = duration < DAY_MS ? "Session" : "Weekly"
            mapped[label] ??= mapTokenProgress(ctx, entry, label, duration)
          }
        } catch {
          damaged = true
          ctx.host.log.warn("skipped unreadable " + type + " quota entry")
        }
      }
    }
    for (const label of ["Session", "Weekly", "Web Searches"]) {
      if (mapped[label]) lines.push(mapped[label])
    }
    if (lines.length === 0) {
      if (damaged) throw ERR_INVALID_RESPONSE
      lines.push(ctx.line.badge({ label: "Status", text: "No usage data", color: "#a3a3a3" }))
    }

    const sub = fetchSubscription(ctx, apiKey)
    const plan = sub && sub.productName ? ctx.fmt.planLabel(sub.productName) : null
    return { plan, lines }
  }

  function buildAllowance(snapshot, now) {
    const promos = new Map()
    const expiry = new Map()
    for (const detail of snapshot?.subscription?.details || []) {
      const id = detail.productId
      if (typeof id !== "string") continue
      const expires = Date.parse(detail.expireTime)
      expiry.set(id, expires)
      const name = String(detail.productName || "")
      if (detail.billingCycle !== "one_time" && !/build|wk/.test(id) && !/build/i.test(name)) continue
      const effective = (detail.entitlements || []).map(item => Date.parse(item.effectiveTime)).find(Number.isFinite) ??
        Date.parse(detail.beginTime)
      const label = /global build/i.test(name) ? "Global Build" :
        /weekend build/i.test(name) ? "Weekend Build" : name.replace(/^zcode /i, "") || "Weekend Build"
      promos.set(id, { label, expires, effective })
    }
    const candidates = []
    const plausibleReset = ms => Number.isFinite(ms) && ms > now && ms - now <= 2 * 365 * 86400000
    for (const window of snapshot?.quota?.limits || []) {
      const id = String(window.planId || "")
      const once = window.period === "one_time"
      if (!once && !/build|wk/.test(id) && !promos.has(id)) continue
      const promo = promos.get(id)
      promos.delete(id)
      if (!Number.isFinite(window.unit) || window.unit <= 0) continue
      const expires = expiry.get(id)
      const expiryFromReset = once && Number.isFinite(window.nextResetTime) && window.nextResetTime > 0 ?
        window.nextResetTime : NaN
      candidates.push({
        label: promo?.label || "Weekend Build",
        expires: Number.isFinite(expires) ? expires : expiryFromReset,
        effective: promo?.effective,
        used: Number.isFinite(window.usage) ? Math.max(0, window.usage) : 0,
        limit: window.unit,
        remaining: Number.isFinite(window.remaining) ? Math.max(0, window.remaining) : 0,
        reset: !once && plausibleReset(window.nextResetTime) ? window.nextResetTime : null,
      })
    }
    for (const promo of promos.values()) {
      candidates.push({ ...promo, used: 0, limit: 500000000, remaining: 500000000, reset: null })
    }
    const valid = candidates.filter(row => !Number.isFinite(row.expires) || row.expires > now)
    const active = row => !(row.effective > now)
    return valid.find(row => active(row) && row.remaining > 0) || valid.find(active) ||
      valid.find(row => row.effective > now)
  }

  function localDay(date) {
    return [date.getFullYear(), date.getMonth() + 1, date.getDate()]
      .map(n => String(n).padStart(2, "0")).join("-")
  }

  function appendLocalHistory(ctx, lines, daily, now) {
    const today = new Date(now)
    const yesterday = new Date(now)
    const cutoff = new Date(now)
    yesterday.setDate(today.getDate() - 1)
    cutoff.setDate(today.getDate() - 29)
    const days = daily.filter(row => row.date <= localDay(today))
    if (!days.length) return
    ctx.host.usageDaily.ingest({ displayName: "Z.ai", daily: days })
    const recent = days.filter(row => row.date >= localDay(cutoff))
    const tokensLabel = tokens => tokens.toLocaleString() + " tokens"
    for (const [label, rows] of [
      ["Today", recent.filter(row => row.date === localDay(today))],
      ["Yesterday", recent.filter(row => row.date === localDay(yesterday))],
      ["Last 30 Days", recent],
    ]) {
      if (!rows.length) continue
      const tokens = rows.reduce((sum, row) => sum + row.totalTokens, 0)
      const cost = rows.every(row => row.totalCost != null) ?
        "~$" + rows.reduce((sum, row) => sum + row.totalCost, 0).toFixed(2) + " · " : ""
      lines.push(ctx.line.text({ label, value: cost + tokensLabel(tokens) }))
    }
    if (recent.length) lines.push(ctx.line.barChart({
      label: "Usage Trend",
      note: "From your ZCode usage history",
      points: recent.map(row => ({
        label: Number(row.date.slice(5, 7)) + "/" + Number(row.date.slice(8)),
        value: row.totalTokens,
        valueLabel: tokensLabel(row.totalTokens),
      })),
    }))
  }

  function probe(ctx) {
    const apiKey = loadApiKey(ctx)
    const ownsLocalHistory = !ctx.account?.instanceId || ctx.account.instanceId === PROVIDER_ID
    const local = ownsLocalHistory && ctx.host.zcode ? ctx.util.tryParseJson(ctx.host.zcode.scan()) : null
    const daily = local?.daily || []
    const now = new Date(ctx.nowIso || Date.now()).getTime()
    const allowance = buildAllowance(local?.entitlement, now)
    let result
    try {
      if (!apiKey) throw "No ZAI_API_KEY found. Set up environment variable first."
      result = probeQuota(ctx, apiKey)
    } catch (error) {
      if (!daily.length && !allowance) throw error
      result = { plan: null, lines: [] }
      if (apiKey) {
        ctx.host.log.warn("Quota refresh failed: " + String(error))
        result.lines.push(ctx.line.badge({ label: "Status", text: String(error), color: "#d69b43" }))
      }
    }
    const level = local?.entitlement?.quota?.level
    result.plan ||= local?.plan || (level ? level + " Plan" : null)
    if (allowance) {
      const next = allowance.effective > now ? allowance.effective : allowance.reset
      result.lines.push(ctx.line.progress({
        label: allowance.label, used: allowance.used, limit: allowance.limit,
        format: { kind: "count", suffix: "tokens" },
        resetsAt: next ? new Date(next).toISOString() : null,
      }))
    }
    appendLocalHistory(ctx, result.lines, daily, now)
    if (local?.damagedRows > 0) {
      result.lines.push(ctx.line.badge({ label: "History", text: "Skipped Invalid ZCode Usage Rows", color: "#d69b43" }))
    }
    return result
  }

  globalThis.__openusage_plugin = { id: "zai", probe }
})()
