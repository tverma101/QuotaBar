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
  var HISTORY_URL = "https://www.codebuff.com/api/v1/cloud/history/"
  var HISTORY_COOLDOWN = 5 * 60 * 1000
  var MAX_HISTORY_RECEIPTS = 10000
  var MAX_HISTORY_BYTES = 2 * 1024 * 1024

  function isAbsolutePath(p) {
    return /^([a-zA-Z]:[\\/]|\\\\|\/)/.test(p)
  }

  function homeDir(ctx) {
    var home = ctx.host.fs.homeDir || ctx.host.env.get("HOME") || ctx.host.env.get("USERPROFILE")
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

  function sessionExpiry(value) {
    var raw = nonempty(value)
    if (!raw || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})$/.test(raw)) {
      throw ERR_INVALID_RESPONSE
    }
    var timestamp = Date.parse(raw)
    if (!Number.isFinite(timestamp)) throw ERR_INVALID_RESPONSE
    return timestamp
  }

  function activeSessions(root) {
    var sessions = Object.create(null)
    if (root.status === "active") {
      var id = nonempty(root.instanceId) || "single"
      sessions[id] = sessionExpiry(root.expiresAt)
    }
    if (root.desktopPurchases !== undefined && root.desktopPurchases !== null &&
        !Array.isArray(root.desktopPurchases)) {
      throw ERR_INVALID_RESPONSE
    }
    if (Array.isArray(root.desktopPurchases)) {
      for (var i = 0; i < root.desktopPurchases.length; i++) {
        var purchase = root.desktopPurchases[i]
        if (!purchase || typeof purchase !== "object" || Array.isArray(purchase)) throw ERR_INVALID_RESPONSE
        var holder = nonempty(purchase.holderInstanceId)
        if (!holder) continue
        sessions[holder] = sessionExpiry(purchase.expiresAt)
      }
    }
    return Object.keys(sessions)
      .map(function (key) { return sessions[key] })
      .sort(function (a, b) { return a - b })
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
        .map(function (expiry) { return new Date(expiry).toISOString() })
        .join("\n")
    }
    lines.push(ctx.line.text(sessionsLine))

    var tier = nonempty(subscription && subscription.tierId)
    var accessTier = nonempty(root.accessTier)
    return { plan: tier || capitalize(accessTier) || null, lines: lines, warning: warning }
  }

  function historyTokenCount(usage) {
    if (!usage) return null
    var input = usage.inputTokens
    var output = usage.outputTokens
    var total = input + output
    if (!Number.isSafeInteger(input) || input < 0 || !Number.isSafeInteger(output) || output < 0 ||
        !Number.isSafeInteger(total) || (usage.totalTokens != null && usage.totalTokens !== total) ||
        (usage.cachedInputTokens != null && (!Number.isSafeInteger(usage.cachedInputTokens) ||
          usage.cachedInputTokens < 0 || usage.cachedInputTokens > input)) ||
        (usage.reasoningOutputTokens != null && (!Number.isSafeInteger(usage.reasoningOutputTokens) ||
          usage.reasoningOutputTokens < 0 || usage.reasoningOutputTokens > output))) return null
    return total
  }

  function refreshHostedHistory(ctx, token, state, cutoff) {
    var budget = 20
    function pages(path, cursor, visit) {
      var seen = new Set()
      if (cursor) seen.add(cursor)
      while (true) {
        if (--budget < 0) throw "Freebuff history refresh reached its request budget."
        var url = HISTORY_URL + path + "?limit=" + (path.endsWith("/events") ? "500" : "100")
        if (cursor) url += "&cursor=" + encodeURIComponent(cursor)
        var resp = ctx.util.request({
          method: "GET", url: url, timeoutMs: 1000,
          headers: { Authorization: "Bearer " + token, Accept: "application/json", "x-freebuff-device-chats": "1" },
        })
        if (resp.status < 200 || resp.status >= 300) throw "Freebuff hosted history is unavailable."
        var page = ctx.util.tryParseJson(resp.bodyText)
        if (!page || !Array.isArray(page.items) || (page.nextCursor !== null && !nonempty(page.nextCursor)) ||
            (page.nextCursor && seen.has(page.nextCursor))) throw "Freebuff hosted history returned an invalid page."
        visit(page)
        cursor = page.nextCursor
        if (cursor === null) break
        seen.add(cursor)
      }
    }
    function active(run) { return run && (run.status === "queued" || run.status === "running") }
    function readRun(run, chatId) {
      if (!run || !nonempty(run.id)) throw ERR_INVALID_RESPONSE
      var id = "cloud:" + run.id
      if ((run.agent && run.agent !== "codebuff") || (typeof run.model === "string" && run.model.startsWith("byok:"))) {
        delete state.runs[id]
        return
      }
      var stamp = Date.parse(run.finishedAt || run.createdAt)
      if (!Number.isFinite(stamp)) throw ERR_INVALID_RESPONSE
      if (!active(run) && stamp < cutoff) return
      var receipt = state.runs[id]
      if (receipt && receipt.stamp === stamp && receipt.status === run.status && !active(run) &&
          !receipt.partial && !receipt.pending && receipt.tokens !== null) return
      if (!receipt) {
        if (Object.keys(state.runs).length >= MAX_HISTORY_RECEIPTS) throw ERR_INVALID_RESPONSE
        receipt = state.runs[id] = { chatId: chatId, tokens: null, partial: true, cursor: null }
      }
      receipt.stamp = stamp
      receipt.status = run.status
      receipt.pending = true
      pages("runs/" + encodeURIComponent(run.id) + "/events", receipt.cursor, function (page) {
        var tokens = receipt.tokens
        var partial = receipt.incomplete === true
        for (var i = 0; i < page.items.length; i++) {
          var event = page.items[i]
          if (!event || event.kind !== "metrics") continue
          if (!event.payload || typeof event.payload !== "object") throw ERR_INVALID_RESPONSE
          if (event.payload.usage != null) {
            tokens = historyTokenCount(event.payload.usage)
            if (tokens === null) throw ERR_INVALID_RESPONSE
          }
          if (typeof event.payload.usageIncomplete === "boolean") partial = event.payload.usageIncomplete
        }
        receipt.tokens = tokens
        receipt.incomplete = partial
        receipt.partial = tokens === null || partial
        receipt.cursor = nonempty(page.endCursor) || page.nextCursor || receipt.cursor
      })
      receipt.pending = false
    }
    var pendingChats = new Set()
    for (var id of Object.keys(state.runs)) {
      var prior = state.runs[id]
      if (!active(prior) && prior.stamp < cutoff) delete state.runs[id]
      else if (active(prior) || prior.partial || prior.pending) pendingChats.add(prior.chatId)
    }
    var observed = new Set()
    pages("chats", null, function (page) {
      for (var chat of page.items) {
        if (!chat || !nonempty(chat.id) || !nonempty(chat.updatedAt)) throw ERR_INVALID_RESPONSE
        var id = "chat:" + chat.id
        if (!observed.has(id) && observed.size >= MAX_HISTORY_RECEIPTS) throw ERR_INVALID_RESPONSE
        observed.add(id)
        if (state.chats[id] === chat.updatedAt && !active(chat.latestRun) && !pendingChats.has(chat.id)) continue
        pages("chats/" + encodeURIComponent(chat.id) + "/runs", null, function (runs) {
          for (var run of runs.items) readRun(run, chat.id)
        })
        state.chats[id] = chat.updatedAt
        if (Object.keys(state.chats).length > MAX_HISTORY_RECEIPTS) throw ERR_INVALID_RESPONSE
      }
    })
    for (var id of Object.keys(state.chats)) if (!observed.has(id)) delete state.chats[id]
  }

  function readDesktopHistory(ctx, cutoff) {
    var home = homeDir(ctx)
    var appData = ctx.host.env.get("APPDATA")
    var roots = [home && home + "/.config/freebuff-desktop/projects"]
    if (isAbsolutePath(appData || "")) roots.push(appData.replace(/[\\/]+$/, "") + "/freebuff-desktop/projects")
    var receipts = []
    var query = function (db, sql) { return JSON.parse(ctx.host.sqlite.query(db, sql)) }
    for (var root of roots) {
      if (!root || !ctx.host.fs.exists(root)) continue
      for (var project of ctx.host.fs.listDir(root)) {
        if (!project || /[\\/]/.test(project) || project === ".." || project === ".") continue
        var db = root + "/" + project + "/desktop-v2.db"
        if (!ctx.host.fs.exists(db)) continue
        var managers = query(db, "SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'auto_run_decision_receipts'")
        var sql = "WITH receipts AS (" +
          "SELECT CASE WHEN substr(m.request_id, 1, 6) = 'cloud:' THEN m.request_id ELSE m.thread_id || ':' || m.seq END AS id," +
          "m.ts AS stamp, m.metrics_json AS metrics FROM messages m JOIN threads t ON t.id = m.thread_id" +
          " WHERE t.harness_id = 'codebuff' AND m.role = 'assistant'"
        if (managers.length) {
          sql += " UNION ALL SELECT 'mission-manager:' || r.thread_id || ':' || r.id," +
            "COALESCE(json_extract(r.manager_json, '$.startedAt'), r.created_at)," +
            "json_object('usage', json_extract(r.manager_json, '$.usage')," +
            "'usageIncomplete', json_extract(r.manager_json, '$.usageIncomplete'))" +
            " FROM auto_run_decision_receipts r JOIN threads t ON t.id = r.thread_id" +
            " WHERE t.harness_id = 'codebuff'" +
            " AND json_extract(r.manager_json, '$.harnessId') = 'codebuff'" +
            " AND json_type(r.manager_json, '$.usage') = 'object'"
        }
        var rows = query(db, sql + "), bounded AS (" +
          "SELECT id, stamp, CASE WHEN length(metrics) <= 65536 AND json_valid(metrics) THEN metrics END AS usage" +
          " FROM receipts WHERE length(id) BETWEEN 1 AND 256 AND CAST(stamp AS REAL) >= " + cutoff +
          " ORDER BY CAST(stamp AS REAL) DESC LIMIT " + (MAX_HISTORY_RECEIPTS + 1) + ")" +
          " SELECT id, stamp, json_extract(usage, '$.usage.inputTokens') AS inputTokens," +
          " json_extract(usage, '$.usage.outputTokens') AS outputTokens," +
          " json_extract(usage, '$.usage.totalTokens') AS totalTokens," +
          " json_extract(usage, '$.usage.cachedInputTokens') AS cachedInputTokens," +
          " json_extract(usage, '$.usage.reasoningOutputTokens') AS reasoningOutputTokens," +
          " json_extract(usage, '$.usageIncomplete') AS usageIncomplete FROM bounded")
        if (receipts.length + rows.length > MAX_HISTORY_RECEIPTS) throw "Freebuff Desktop history exceeded its receipt budget."
        for (var row of rows) {
          var stamp = Number(row.stamp)
          if (!nonempty(row.id) || !Number.isFinite(stamp)) continue
          var tokens = historyTokenCount(row)
          receipts.push({ id: row.id, stamp: stamp, tokens: tokens, partial: tokens === null || row.usageIncomplete === 1 })
        }
      }
    }
    return receipts
  }

  function appendHistory(ctx, result, token) {
    var fs = ctx.host.fs
    var path = ctx.app.pluginDataDir + "/history-v1.json"
    var account = ctx.host.crypto.sha256Hex(token)
    var now = Date.parse(ctx.nowIso)
    var today = new Date(now)
    today.setHours(0, 0, 0, 0)
    var yesterday = new Date(today)
    yesterday.setDate(today.getDate() - 1)
    var window = new Date(today)
    window.setDate(today.getDate() - 29)
    var state = { account: account, runs: {}, chats: {}, desktop: [] }
    if (fs.exists(path)) {
      try {
        var raw = fs.readText(path)
        var cached = raw && raw.length <= MAX_HISTORY_BYTES && ctx.util.tryParseJson(raw)
        if (cached && cached.account === account && cached.runs && cached.chats && Array.isArray(cached.desktop)) state = cached
      } catch (e) { ctx.host.log.warn("Freebuff history cache could not be loaded.") }
    }
    if (ctx.app.refreshHistory && (!state.attempt || now < state.attempt || now - state.attempt >= HISTORY_COOLDOWN)) {
      state.attempt = now
      try {
        refreshHostedHistory(ctx, token, state, Number(window) - DAY_MS)
        state.hostedError = false
      } catch (e) {
        ctx.host.log.warn("Freebuff hosted history refresh did not complete.")
        state.hostedError = true
      }
      try {
        state.desktop = readDesktopHistory(ctx, Number(window) - DAY_MS)
        state.desktopError = false
      } catch (e) {
        ctx.host.log.warn("Freebuff Desktop history refresh did not complete.")
        state.desktopError = true
      }
      try {
        var encoded = JSON.stringify(state)
        if (encoded.length > MAX_HISTORY_BYTES) throw "Freebuff history cache exceeded its budget."
        fs.writeText(path, encoded)
      } catch (e) { ctx.host.log.warn("Freebuff history cache could not be saved.") }
    }
    var totals = [null, null, null]
    var incomplete = !!(state.hostedError || state.desktopError)
    var seen = new Set()
    function count(id, receipt) {
      if (seen.has(id) || receipt.stamp < Number(window) || receipt.stamp > now) return
      if (receipt.partial || receipt.pending) incomplete = true
      if (!Number.isSafeInteger(receipt.tokens) || receipt.tokens < 0) return
      seen.add(id)
      totals[2] = (totals[2] || 0) + receipt.tokens
      if (receipt.stamp >= Number(today)) totals[0] = (totals[0] || 0) + receipt.tokens
      else if (receipt.stamp >= Number(yesterday)) totals[1] = (totals[1] || 0) + receipt.tokens
    }
    for (var id of Object.keys(state.runs)) count(id, state.runs[id])
    for (var row of state.desktop) count(row.id, row)
    var labels = ["Today", "Yesterday", "Last 30 Days"]
    for (var i = 0; i < labels.length; i++) {
      if (totals[i] !== null) result.lines.push(ctx.line.text({ label: labels[i], value: totals[i] + " tokens" }))
    }
    if (incomplete) {
      var warning = "Freebuff usage history is incomplete; measured totals may be lower than actual usage."
      result.warning = result.warning ? result.warning + " " + warning : warning
    }
  }

  function probe(ctx) {
    var auth = loadAuth(ctx)
    var root = fetchSession(ctx, auth.token)
    var mapped = mapSession(ctx, root)
    var result = { plan: mapped.plan, lines: mapped.lines }
    if (mapped.warning) result.warning = mapped.warning
    appendHistory(ctx, result, auth.token)
    return result
  }

  globalThis.__openusage_plugin = { id: "freebuff", probe }
})()
