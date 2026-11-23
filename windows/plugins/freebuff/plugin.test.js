import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const SESSION_URL = "https://www.codebuff.com/api/v1/freebuff/session"
const CRED_PATH = "/home/user/.config/manicode/credentials.json"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

function setEnv(ctx, envValues) {
  ctx.host.env.get.mockImplementation((name) =>
    Object.prototype.hasOwnProperty.call(envValues, name) ? envValues[name] : null
  )
}

function sessionPayload(overrides) {
  const base = {
    status: "active",
    instanceId: "inst-1",
    expiresAt: "2026-02-03T00:00:00.000Z",
    accessTier: "free",
    subscription: {
      tierId: "pro",
      usage: {
        dayUsed: 3,
        dayLimit: 10,
        dayResetAt: "2026-02-02T17:00:00.000Z",
        fiveDayUsed: 12,
        fiveDayLimit: 40,
        monthUsed: 30,
        monthLimit: 200,
        periodEndsAt: "2026-03-01T00:00:00.000Z",
      },
    },
  }
  return overrides ? Object.assign(base, overrides) : base
}

function mockRequest(ctx, handler) {
  ctx.host.http.request.mockImplementation(handler)
}

function okJson(body) {
  return { status: 200, bodyText: JSON.stringify(body) }
}

describe("freebuff plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("throws when no credentials exist", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { HOME: "/home/user" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("No Freebuff login was found")
  })

  it("rejects a relative FREEBUFF_CONFIG_DIR", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { FREEBUFF_CONFIG_DIR: "manicode" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("absolute path")
  })

  it("uses CODEBUFF_API_KEY when no credentials file exists", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { HOME: "/home/user", CODEBUFF_API_KEY: "tok-env" })
    mockRequest(ctx, (req) => {
      expect(req.url).toBe(SESSION_URL)
      expect(req.headers.Authorization).toBe("Bearer tok-env")
      expect(req.headers["x-freebuff-multi-session"]).toBe("1")
      return okJson(sessionPayload())
    })
    const plugin = await loadPlugin()
    const out = plugin.probe(ctx)
    expect(out.plan).toBe("pro")
    const daily = out.lines.find((l) => l.label === "Daily")
    expect(daily.used).toBe(3)
    expect(daily.limit).toBe(10)
  })

  it("reads the default profile authToken from credentials.json", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { HOME: "/home/user" })
    ctx.host.fs.writeText(CRED_PATH, JSON.stringify({ default: { authToken: "tok-file" } }))
    mockRequest(ctx, (req) => {
      expect(req.headers.Authorization).toBe("Bearer tok-file")
      return okJson(sessionPayload())
    })
    const plugin = await loadPlugin()
    const out = plugin.probe(ctx)
    expect(out.lines.find((l) => l.label === "5-Day").used).toBe(12)
    expect(out.lines.find((l) => l.label === "Monthly").limit).toBe(200)
    expect(out.lines.find((l) => l.label === "Active Sessions").value).toBe("1")
  })

  it("honors FREEBUFF_CONFIG_DIR", async () => {
    const ctx = makeCtx()
    const dir = "/opt/fb"
    setEnv(ctx, { FREEBUFF_CONFIG_DIR: dir })
    ctx.host.fs.writeText(dir + "/credentials.json", JSON.stringify({ default: { authToken: "tok-cfg" } }))
    mockRequest(ctx, (req) => {
      expect(req.headers.Authorization).toBe("Bearer tok-cfg")
      return okJson(sessionPayload())
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).not.toThrow()
  })

  it("falls back to keychain when tokenStore is keychain", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { HOME: "/home/user" })
    ctx.host.fs.writeText(CRED_PATH, JSON.stringify({ default: { tokenStore: "keychain" } }))
    ctx.host.keychain.readGenericPassword.mockReturnValue("tok-kc")
    mockRequest(ctx, (req) => {
      expect(req.headers.Authorization).toBe("Bearer tok-kc")
      return okJson(sessionPayload())
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).not.toThrow()
    expect(ctx.host.keychain.readGenericPassword).toHaveBeenCalledWith("freebuff-cli", CRED_PATH)
  })

  it("throws missingDefaultProfile guidance without a default profile", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { HOME: "/home/user" })
    ctx.host.fs.writeText(CRED_PATH, JSON.stringify({ other: { authToken: "x" } }))
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("no `default` profile")
  })

  it("treats 404 as status none", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { CODEBUFF_API_KEY: "tok" })
    mockRequest(ctx, () => ({ status: 404, bodyText: "" }))
    const plugin = await loadPlugin()
    const out = plugin.probe(ctx)
    expect(out.lines.find((l) => l.label === "Active Sessions").value).toBe("0")
  })

  it("maps auth failures to a re-login message", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { CODEBUFF_API_KEY: "tok" })
    mockRequest(ctx, () => ({ status: 401, bodyText: "" }))
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("expired")
  })

  it("maps freebucks daily hours and wallet balance", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { CODEBUFF_API_KEY: "tok" })
    mockRequest(ctx, () => okJson({
      status: "active",
      instanceId: "a",
      expiresAt: "2026-02-03T00:00:00.000Z",
      accessTier: "free",
      freebucks: {
        daily: { spent: 10, limit: 25, resetAt: "2026-02-02T17:00:00.000Z" },
        wallet: { balance: 60 },
        monthly: { spentUsd: 4.2, limitUsd: 10, resetAt: "2026-03-01T00:00:00.000Z" },
      },
    }))
    const plugin = await loadPlugin()
    const out = plugin.probe(ctx)
    const hours = out.lines.find((l) => l.label === "Daily Hours")
    expect(hours.used).toBe(2)
    expect(hours.limit).toBe(5)
    expect(out.lines.find((l) => l.label === "Hours Balance").value).toBe("12 h")
    const spend = out.lines.find((l) => l.label === "Monthly Spend")
    expect(spend.used).toBe(4.2)
    expect(spend.limit).toBe(10)
  })

  it("computes wallet from legacy balance minus daily remainder", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { CODEBUFF_API_KEY: "tok" })
    mockRequest(ctx, () => okJson({
      status: "none",
      accessTier: "free",
      freebucks: {
        daily: { spent: 5, limit: 25, remaining: 20 },
        balance: 100,
      },
    }))
    const plugin = await loadPlugin()
    const out = plugin.probe(ctx)
    expect(out.lines.find((l) => l.label === "Hours Balance").value).toBe("16 h")
  })

  it("warns instead of failing when freebucks is null", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { CODEBUFF_API_KEY: "tok" })
    mockRequest(ctx, () => okJson(sessionPayload({ freebucks: null })))
    const plugin = await loadPlugin()
    const out = plugin.probe(ctx)
    expect(out.warning).toContain("hours balances")
  })

  it("collects desktop purchase holders into Active Sessions", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { CODEBUFF_API_KEY: "tok" })
    mockRequest(ctx, () => okJson(sessionPayload({
      status: "none",
      desktopPurchases: [
        { holderInstanceId: "h1", expiresAt: "2026-02-05T00:00:00.000Z" },
        { holderInstanceId: "h2", expiresAt: "2026-02-04T00:00:00.000Z" },
      ],
    })))
    const plugin = await loadPlugin()
    const out = plugin.probe(ctx)
    const line = out.lines.find((l) => l.label === "Active Sessions")
    expect(line.value).toBe("2")
    expect(line.expiryTooltip).toContain("2026-02-04")
  })

  it("picks the most-used rate-limit pool", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { CODEBUFF_API_KEY: "tok" })
    mockRequest(ctx, () => okJson({
      status: "none",
      accessTier: "pro",
      rateLimitsByModel: {
        "model-a": { pool: "p1", poolLabel: "Pool One", limit: 10, recentCount: 1 },
        "model-b": { pool: "p2", poolLabel: "Pool Two", limit: 10, recentCount: 8, resetAt: "2026-02-03T00:00:00.000Z", period: "pacific_day" },
        "model-c": { pool: "p2", poolLabel: "Pool Two", limit: 10, recentCount: 2 },
      },
    }))
    const plugin = await loadPlugin()
    const out = plugin.probe(ctx)
    const pool = out.lines.find((l) => l.label === "Session Pool")
    expect(pool.used).toBe(8)
    expect(pool.limit).toBe(10)
    expect(out.plan).toBe("Pro")
  })
})
