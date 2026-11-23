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

  function probe(ctx) {
    const apiKey = loadApiKey(ctx)
    if (!apiKey) {
      throw "No ZAI_API_KEY found. Set up environment variable first."
    }

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

  globalThis.__openusage_plugin = { id: "zai", probe }
})()
