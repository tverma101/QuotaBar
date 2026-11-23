// Freebuff provider — ported from QuotaBar's Swift FreebuffProvider/FreebuffUsageMapper.
// Reads the Freebuff (Codebuff) CLI's local credentials and polls the read-only
// session endpoint. The POST session route admits a session and is never used.
(function () {
  var SESSION_URL = "https://www.codebuff.com/api/v1/freebuff/session"
  var CREDENTIALS_FILE = "credentials.json"
  var KEYCHAIN_SERVICE = "freebuff-cli"
  var DAY_MS = 24 * 60 * 60 * 1000
  var WEEK_MS = 7 * DAY_MS
  var FIVE_DAY_MS = 5 * DAY_MS
  var FREEBUCKS_PER_HOUR = 5
  var ERR_INVALID_RESPONSE = "Freebuff returned unreadable usage data. Try again later."
  var LOGIN_HINT = "Run freebuff login (or ~/.config/manicode/freebuff login), then refresh."

  function isAbsolutePath(p) {
    return /^([a-zA-Z]:[\\/]|\\\\|\/)/.test(p)
  }

  function homeDir(ctx) {
    var home = ctx.host.env.get("HOME") || ctx.host.env.get("USERPROFILE")
    return typeof home === "string" && home.trim() ? home.trim() : null
  }

  function credentialsPath(ctx) {
    var configured = ctx.host.env.get("FREEBUFF_CONFIG_DIR")
    if (typeof configured === "string" && configured.trim()) {
      var dir = configured.trim()
      if (!isAbsolutePath(dir)) {
        throw "Freebuff's FREEBUFF_CONFIG_DIR must be an absolute path."
      }
      return dir.replace(/[\\/]+$/, "") + "/" + CREDENTIALS_FILE
    }
    var envName = ctx.host.env.get("NEXT_PUBLIC_CB_ENVIRONMENT") || "prod"
    var suffix = envName === "prod" ? "" : "-" + envName
    var home = homeDir(ctx)
    if (!home) return null
    return home + "/.config/manicode" + suffix + "/" + CREDENTIALS_FILE
  }

  function environmentToken(ctx) {
    var token = ctx.host.env.get("CODEBUFF_API_KEY")
    return typeof token === "string" && token.trim() ? token.trim() : null
  }

  function loadAuth(ctx) {
    var envToken = environmentToken(ctx)
    var path = credentialsPath(ctx)
    if (!path) {
      if (envToken) return { token: envToken, source: "env" }
      throw "No Freebuff login was found. " + LOGIN_HINT
    }

    var text = null
    try {
      if (ctx.host.fs.exists(path)) text = ctx.host.fs.readText(path)
    } catch (e) {
      ctx.host.log.warn("credentials read failed: " + String(e))
    }

    if (text && text.trim()) {
      var object = ctx.util.tryParseJson(text)
      if (!object || typeof object !== "object") {
        if (envToken) return { token: envToken, source: "env" }
        throw "Freebuff's credentials file is invalid. Sign in again with the Freebuff CLI."
      }
      var profile = object["default"]
      if (!profile || typeof profile !== "object") {
        if (envToken) return { token: envToken, source: "env" }
        throw "Freebuff credentials have no `default` profile. Sign in again, or point FREEBUFF_CONFIG_DIR at the right config directory."
      }
      var fileToken = typeof profile.authToken === "string" && profile.authToken.trim()
        ? profile.authToken.trim() : null
      if (fileToken) return { token: fileToken, source: "file" }

      if (profile.tokenStore === "keychain" && ctx.host.keychain &&
          typeof ctx.host.keychain.readGenericPassword === "function") {
        try {
          var stored = ctx.host.keychain.readGenericPassword(KEYCHAIN_SERVICE, path)
          if (typeof stored === "string" && stored.trim()) {
            return { token: stored.trim(), source: "keychain" }
          }
        } catch (e) {
          ctx.host.log.warn("keychain read failed: " + String(e))
        }
      }
    }

    if (envToken) return { token: envToken, source: "env" }
    throw "No Freebuff login was found. " + LOGIN_HINT
  }

  function fetchSession(ctx, token) {
    var headers = {
      Authorization: "Bearer " + token,
      Accept: "application/json",
      "x-freebuff-multi-session": "1",
    }
    try {
      var tz = Intl.DateTimeFormat().resolvedOptions().timeZone
      if (tz) headers["x-fb-timezone"] = tz
    } catch (e) { /* QuickJS without Intl: server falls back to default tz */ }

    var resp
    try {
      resp = ctx.util.request({ method: "GET", url: SESSION_URL, headers: headers, timeoutMs: 15000 })
    } catch (e) {
      ctx.host.log.error("session request exception: " + String(e))
      throw "Couldn't reach Freebuff. Check your connection and try again."
    }

    if (ctx.util.isAuthStatus(resp.status)) {
      throw "The Freebuff login has expired. Sign in again with the Freebuff CLI."
    }
    if (resp.status === 404) return { status: "none" }
    if (resp.status < 200 || resp.status >= 300) {
      throw "Freebuff usage request failed (HTTP " + String(resp.status) + ")."
    }
    var data = ctx.util.tryParseJson(resp.bodyText)
    if (!data || typeof data !== "object") throw ERR_INVALID_RESPONSE
    return data
  }

  function num(value) {
    if (typeof value === "boolean") return null
    if (typeof value === "number") return Number.isFinite(value) ? value : null
    if (typeof value === "string") {
      var t = value.trim()
      if (!t) return null
      var n = Number(t)
      return Number.isFinite(n) ? n : null
    }
    return null
  }

  function nonnegative(value) {
    var n = num(value)
    return n !== null && n >= 0 ? n : null
  }

  function nonempty(value) {
    return typeof value === "string" && value.trim() ? value.trim() : null
  }

  function dateIso(value) {
    return nonempty(value) || undefined
  }

  function periodDuration(value) {
    switch (value) {
      case "pacific_day": return DAY_MS
      case "pacific_week": return WEEK_MS
      case "pacific_month": return 30 * DAY_MS
      default: return undefined
    }
  }

  function appendProgress(ctx, lines, label, rawUsed, rawLimit, format, rawReset, periodMs, detail) {
    var used = num(rawUsed)
    var limit = num(rawLimit)
    if (used === null || used < 0 || limit === null || limit < 0) return
    var opts = { label: label, used: used, limit: limit, format: format }
    var reset = dateIso(rawReset)
    if (reset) opts.resetsAt = reset
    if (periodMs) opts.periodDurationMs = periodMs
    if (detail) opts.detail = detail
    lines.push(ctx.line.progress(opts))
  }

  function mostUsedRateLimit(models) {
    var pools = {}
    for (var model in models) {
      var value = models[model]
      if (!value || typeof value !== "object") continue
      var limit = num(value.limit)
      var recentCount = num(value.recentCount)
      if (limit === null || limit <= 0 || recentCount === null || recentCount < 0) continue
      var key = nonempty(value.pool) || ("model:" + model)
      var candidate = {
        key: key,
        poolLabel: nonempty(value.poolLabel),
        limit: limit,
        recentCount: recentCount,
        resetAt: dateIso(value.resetAt),
        periodMs: periodDuration(value.period),
      }
      var existing = pools[key]
      if (!existing || candidate.recentCount / candidate.limit > existing.recentCount / existing.limit) {
        pools[key] = candidate
      }
    }
    var best = null
    for (var k in pools) {
      var c = pools[k]
      if (!best || c.recentCount / c.limit > best.recentCount / best.limit ||
          (c.recentCount / c.limit === best.recentCount / best.limit && c.key < best.key)) {
        best = c
      }
    }
    return best
  }

  function appendMonthlySpend(ctx, lines, usage, freebucks) {
    var monthly = freebucks && typeof freebucks.monthly === "object" ? freebucks.monthly : null
    var spent = num(monthly ? monthly.spentUsd : null)
    if (spent === null && usage) spent = num(usage.monthSpendUsd)
    var limit = num(monthly ? monthly.limitUsd : null)
    if (limit === null && usage) limit = num(usage.monthSpendLimitUsd)
    if (spent === null || spent < 0) return
    var reset = dateIso(monthly ? monthly.resetAt : null) || (usage ? dateIso(usage.periodEndsAt) : undefined)
    if (limit !== null && limit > 0) {
      var opts = { label: "Monthly Spend", used: spent, limit: limit, format: { kind: "dollars" } }
      if (reset) opts.resetsAt = reset
      lines.push(ctx.line.progress(opts))
    } else {
      lines.push(ctx.line.text({
        label: "Monthly Spend",
        value: "$" + (Math.round(spent * 100) / 100).toFixed(2),
      }))
    }
  }

  function activeSessions(root) {
    var sessions = {}
    if (root.status === "active") {
      var expiry = nonempty(root.expiresAt)
      if (!expiry) throw ERR_INVALID_RESPONSE
      var id = nonempty(root.instanceId) || "single"
      sessions[id] = { expiresAt: expiry }
    }
    if (root.desktopPurchases !== undefined && root.desktopPurchases !== null &&
        !Array.isArray(root.desktopPurchases)) {
      throw ERR_INVALID_RESPONSE
    }
    if (Array.isArray(root.desktopPurchases)) {
      for (var i = 0; i < root.desktopPurchases.length; i++) {
        var purchase = root.desktopPurchases[i]
        if (!purchase || typeof purchase !== "object") continue
        var holder = nonempty(purchase.holderInstanceId)
        if (!holder) continue
        var pExpiry = nonempty(purchase.expiresAt)
        if (!pExpiry) throw ERR_INVALID_RESPONSE
        sessions[holder] = { expiresAt: pExpiry }
      }
    }
    var list = []
    for (var key in sessions) list.push(sessions[key])
    list.sort(function (a, b) { return a.expiresAt < b.expiresAt ? -1 : a.expiresAt > b.expiresAt ? 1 : 0 })
    return list
  }

  function capitalize(value) {
    if (!value) return null
    return value.charAt(0).toUpperCase() + value.slice(1)
  }

  function mapSession(ctx, root) {
    var status = nonempty(root.status)
    if (!status) throw ERR_INVALID_RESPONSE

    var subscription = root.subscription && typeof root.subscription === "object" ? root.subscription : null
    var usage = subscription && typeof subscription.usage === "object" ? subscription.usage : null
    var freeWindows = root.freeWindows && typeof root.freeWindows === "object" ? root.freeWindows : null
    var hasFreebucks = Object.prototype.hasOwnProperty.call(root, "freebucks")
    var freebucks = hasFreebucks && root.freebucks && typeof root.freebucks === "object" ? root.freebucks : null
    var lines = []
    var warning = null

    if (hasFreebucks && root.freebucks !== null && root.freebucks !== undefined && !freebucks) {
      throw ERR_INVALID_RESPONSE
    }
    if (root.freebucks === null && hasFreebucks) {
      warning = "Freebuff couldn't refresh its hours balances. Refresh again to get current hours."
    }

    if (hasFreebucks) {
      // Current hours meter: legacy session windows no longer describe the budget.
    } else if (usage) {
      appendProgress(ctx, lines, "Daily", usage.dayUsed, usage.dayLimit,
        { kind: "count", suffix: "sessions" }, usage.dayResetAt, DAY_MS)
      appendProgress(ctx, lines, "5-Day", usage.fiveDayUsed, usage.fiveDayLimit,
        { kind: "count", suffix: "sessions" }, null, FIVE_DAY_MS)
      appendProgress(ctx, lines, "Monthly", usage.monthUsed, usage.monthLimit,
        { kind: "count", suffix: "sessions" }, usage.periodEndsAt, undefined)
      appendProgress(ctx, lines, "Premium Sessions", usage.dayPremiumUsed, usage.dayPremiumLimit,
        { kind: "count", suffix: "sessions" }, usage.dayResetAt, DAY_MS, "Luna / DeepSeek V4 Pro")
      appendProgress(ctx, lines, "Free Premium Sessions", usage.freeDayUsed, usage.freeDayLimit,
        { kind: "count", suffix: "sessions" }, usage.dayResetAt, DAY_MS)
    } else if (freeWindows) {
      appendProgress(ctx, lines, "Daily", freeWindows.dayUsed, freeWindows.dayLimit,
        { kind: "count", suffix: "sessions" }, freeWindows.dayResetAt, DAY_MS)
      appendProgress(ctx, lines, "Weekly", freeWindows.weekUsed, freeWindows.weekLimit,
        { kind: "count", suffix: "sessions" }, null, WEEK_MS)
      appendProgress(ctx, lines, "Monthly", freeWindows.monthUsed, freeWindows.monthLimit,
        { kind: "count", suffix: "sessions" }, freeWindows.monthResetAt, undefined)
    } else {
      var models = root.rateLimitsByModel && typeof root.rateLimitsByModel === "object"
        ? root.rateLimitsByModel : {}
      var pool = mostUsedRateLimit(models)
      if (pool) {
        appendProgress(ctx, lines, "Session Pool", pool.recentCount, pool.limit,
          { kind: "count", suffix: "sessions" }, pool.resetAt, pool.periodMs,
          pool.poolLabel ? "Most used pool: " + pool.poolLabel : undefined)
      }
    }

    if (freebucks) {
      var daily = typeof freebucks.daily === "object" && freebucks.daily ? freebucks.daily : null
      if (daily) {
        var spent = nonnegative(daily.spent)
        var dayLimit = nonnegative(daily.limit)
        if (spent === null || dayLimit === null) throw ERR_INVALID_RESPONSE
        if (daily.resetAt != null && !nonempty(daily.resetAt)) throw ERR_INVALID_RESPONSE
        appendProgress(ctx, lines, "Daily Hours", spent / FREEBUCKS_PER_HOUR, dayLimit / FREEBUCKS_PER_HOUR,
          { kind: "count", suffix: "hours" }, daily.resetAt, DAY_MS)
      } else {
        throw ERR_INVALID_RESPONSE
      }

      var wallet = null
      if (freebucks.wallet !== undefined && freebucks.wallet !== null) {
        var walletObj = typeof freebucks.wallet === "object" ? freebucks.wallet : null
        var balance = walletObj ? nonnegative(walletObj.balance) : null
        if (balance === null) throw ERR_INVALID_RESPONSE
        wallet = balance
      } else {
        var total = nonnegative(freebucks.balance)
        var dailySpent = daily ? nonnegative(daily.spent) : null
        var dailyLimit = daily ? nonnegative(daily.limit) : null
        if (total === null || !daily || dailySpent === null || dailyLimit === null) {
          throw ERR_INVALID_RESPONSE
        }
        var remaining = nonnegative(daily.remaining)
        if (remaining === null) remaining = Math.max(0, dailyLimit - dailySpent)
        if (total + 1e-9 < remaining) throw ERR_INVALID_RESPONSE
        wallet = Math.max(0, total - remaining)
      }
      lines.push(ctx.line.text({
        label: "Hours Balance",
        value: String(Math.floor(wallet / FREEBUCKS_PER_HOUR + 1e-9)) + " h",
      }))
    }

    appendMonthlySpend(ctx, lines, usage, freebucks)

    if (lines.length === 0) {
      lines.push(ctx.line.badge({ label: "Status", text: "No usage data", color: "#a3a3a3" }))
    }

    var sessions = activeSessions(root)
    var sessionsLine = { label: "Active Sessions", value: String(sessions.length) }
    if (sessions.length > 0) {
      sessionsLine.statusDot = "green"
      sessionsLine.expiryTooltip = sessions
        .map(function (s) { return s.expiresAt })
        .join("\n")
    }
    lines.push(ctx.line.text(sessionsLine))

    var tier = nonempty(subscription && subscription.tierId)
    var accessTier = nonempty(root.accessTier)
    return { plan: tier || capitalize(accessTier) || null, lines: lines, warning: warning }
  }

  function probe(ctx) {
    var auth = loadAuth(ctx)
    var root = fetchSession(ctx, auth.token)
    var mapped = mapSession(ctx, root)
    var result = { plan: mapped.plan, lines: mapped.lines }
    if (mapped.warning) result.warning = mapped.warning
    return result
  }

  globalThis.__openusage_plugin = { id: "freebuff", probe }
})()
