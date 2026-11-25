import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

it("shows local ZCode history and an active grant without requesting a remote quota", async () => {
  const ctx = makeCtx()
  ctx.nowIso = new Date(2026, 1, 2, 12).toISOString()
  ctx.host.zcode = { scan: () => JSON.stringify({
    daily: [{ date: "2026-02-02", totalTokens: 30, totalCost: null }],
    entitlement: { quota: { level: "Start", limits: [
      { planId: "wk-current", period: "one_time", unit: 500, usage: 80, remaining: 420,
        nextResetTime: Date.parse(ctx.nowIso) + 60_000 },
      { planId: "wk-expired", period: "one_time", unit: 600, usage: 90, remaining: 510,
        nextResetTime: Date.parse(ctx.nowIso) - 60_000 },
    ] } },
  }) }
  const { plan, lines } = (await loadPlugin()).probe(ctx)
  expect(plan).toBe("Start Plan")
  expect(lines.find(line => line.label === "Weekend Build")).toMatchObject({ used: 80, limit: 500 })
  expect(lines.find(line => line.label === "Today")).toMatchObject({ value: "30 tokens" })
  expect(ctx.host.http.request).not.toHaveBeenCalled()
})

const mockEnvWithKey = (ctx, key, varName = "ZAI_API_KEY") => {
  ctx.host.env.get.mockImplementation((name) => (name === varName ? key : null))
}

const QUOTA_RESPONSE = {
  code: 200,
  data: {
    limits: [
      {
        type: "TOKENS_LIMIT",
        usage: 800000000,
        currentValue: 1900000,
        percentage: 10,
        nextResetTime: 1738368000000,
        unit: 3,
        number: 5,
      },
      {
        type: "TIME_LIMIT",
        usage: 4000,
        currentValue: 1095,
        percentage: 27,
        remaining: 2905,
        usageDetails: [
          { modelCode: "search-prime", usage: 951 },
          { modelCode: "web-reader", usage: 211 },
          { modelCode: "zread", usage: 0 },
        ],
        unit: 5,
        number: 1,
      },
    ],
  },
}

const QUOTA_RESPONSE_WITH_WEEKLY = {
  code: 200,
  data: {
    limits: [
      {
        type: "TOKENS_LIMIT",
        usage: 800000000,
        currentValue: 1900000,
        percentage: 10,
        nextResetTime: 1738368000000,
        unit: 3,
        number: 5,
      },
      {
        type: "TOKENS_LIMIT",
        usage: 1600000000,
        currentValue: 4800000,
        percentage: 10,
        nextResetTime: 1738972800000,
        unit: 6,
        number: 7,
      },
      {
        type: "TIME_LIMIT",
        usage: 4000,
        currentValue: 1095,
        percentage: 27,
        remaining: 2905,
        usageDetails: [
          { modelCode: "search-prime", usage: 951 },
          { modelCode: "web-reader", usage: 211 },
          { modelCode: "zread", usage: 0 },
        ],
        unit: 5,
        number: 1,
      },
    ],
  },
}

const QUOTA_RESPONSE_NO_TIME_LIMIT = {
  code: 200,
  data: {
    limits: [
      {
        type: "TOKENS_LIMIT",
        usage: 800000000,
        currentValue: 1900000,
        percentage: 10,
        nextResetTime: 1738368000000,
        unit: 3,
        number: 5,
      },
    ],
  },
}

const QUOTA_RESPONSE_CREDIT_LIMIT = {
  code: 200,
  data: {
    level: "lite",
    limits: [
      {
        type: "CREDIT_LIMIT",
        unit: 3,
        number: 5,
        usage: 2000,
        currentValue: 8,
        remaining: 1991,
        percentage: 1,
        nextResetTime: 1790069319040,
      },
      {
        type: "CREDIT_LIMIT",
        unit: 6,
        number: 1,
        usage: 10000,
        currentValue: 7031,
        remaining: 2968,
        percentage: 70,
        nextResetTime: 1790234556979,
      },
    ],
  },
}

const SUBSCRIPTION_RESPONSE = {
  data: [{ productName: "GLM Coding Max", nextRenewTime: "2026-03-12" }],
}

const mockHttp = (ctx) => {
  ctx.host.http.request.mockImplementation((opts) => {
    if (opts.url.includes("subscription")) {
      return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
    }
    return { status: 200, bodyText: JSON.stringify(QUOTA_RESPONSE) }
  })
}

describe("zai plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("throws when no env vars set", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("No ZAI_API_KEY found. Set up environment variable first.")
  })

  it("uses ZAI_API_KEY when set", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    mockHttp(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((l) => l.label === "Session")).toBeTruthy()
  })

  it("falls back to GLM_API_KEY when ZAI_API_KEY is missing", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "glm-key", "GLM_API_KEY")
    mockHttp(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((l) => l.label === "Session")).toBeTruthy()
  })

  it("prefers ZAI_API_KEY over GLM_API_KEY", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => {
      if (name === "ZAI_API_KEY") return "zai-key"
      if (name === "GLM_API_KEY") return "glm-key"
      return null
    })
    mockHttp(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((l) => l.label === "Session")).toBeTruthy()
    const authHeader = ctx.host.http.request.mock.calls[0][0].headers.Authorization
    expect(authHeader).toBe("Bearer zai-key")
  })

  it("renders session usage as percent from quota response", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    mockHttp(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines.find((l) => l.label === "Session")
    expect(line).toBeTruthy()
    expect(line.type).toBe("progress")
    expect(line.used).toBe(10)
    expect(line.limit).toBe(100)
    expect(line.format).toEqual({ kind: "percent" })
    expect(line.periodDurationMs).toBe(5 * 60 * 60 * 1000)
  })

  it("extracts plan name from subscription response", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    mockHttp(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBe("GLM Coding Max")
  })

  it("handles subscription fetch failure gracefully", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 500, bodyText: "" }
      }
      return { status: 200, bodyText: JSON.stringify(QUOTA_RESPONSE) }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBeNull()
    expect(result.lines.find((l) => l.label === "Session")).toBeTruthy()
  })

  it("throws on 401 from quota endpoint", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
      }
      return { status: 401, bodyText: "" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("API key invalid")
  })

  it("throws on HTTP 500 from quota endpoint", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("HTTP 500")
  })

  it("throws on network exception", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
      }
      throw new Error("ECONNREFUSED")
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage request failed. Check your connection.")
  })

  it("throws on invalid JSON from quota endpoint", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
      }
      return { status: 200, bodyText: "not-json" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage response invalid")
  })

  it("shows badge when limits array is empty", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
      }
      return { status: 200, bodyText: JSON.stringify({ data: { limits: [] } }) }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines[0].text).toBe("No usage data")
  })

  it("passes resetsAt from nextResetTime (epoch ms to ISO)", async () => {
    const ctx = makeCtx()
    ctx.nowIso = "2025-01-01T00:00:00Z"
    mockEnvWithKey(ctx, "test-key")
    mockHttp(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines.find((l) => l.label === "Session")
    expect(line.resetsAt).toBe(new Date(1738368000000).toISOString())
  })

  it("renders Web Searches line with count format and monthly cadence", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    mockHttp(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines.find((l) => l.label === "Web Searches")
    expect(line).toBeTruthy()
    expect(line.type).toBe("progress")
    expect(line.used).toBe(1095)
    expect(line.limit).toBe(4000)
    expect(line.format).toEqual({ kind: "count", suffix: "searches" })
    expect(line.periodDurationMs).toBe(30 * 24 * 60 * 60 * 1000)
    expect(line.resetsAt).toBeUndefined()
  })

  it("skips Web Searches when TIME_LIMIT is absent", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
      }
      return { status: 200, bodyText: JSON.stringify(QUOTA_RESPONSE_NO_TIME_LIMIT) }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((l) => l.label === "Web Searches")).toBeUndefined()
    expect(result.lines.find((l) => l.label === "Session")).toBeTruthy()
  })

  it("Web Searches still has monthly cadence even when subscription fails", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 500, bodyText: "" }
      }
      return { status: 200, bodyText: JSON.stringify(QUOTA_RESPONSE) }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines.find((l) => l.label === "Web Searches")
    expect(line).toBeTruthy()
    expect(line.periodDurationMs).toBe(30 * 24 * 60 * 60 * 1000)
    expect(line.resetsAt).toBeUndefined()
  })

  it("handles missing nextResetTime gracefully", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    const quotaNoReset = {
      data: {
        limits: [
          { type: "TOKENS_LIMIT", percentage: 10 },
        ],
      },
    }
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
      }
      return { status: 200, bodyText: JSON.stringify(quotaNoReset) }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines.find((l) => l.label === "Session")
    expect(line).toBeTruthy()
    expect(line.resetsAt).toBeUndefined()
  })

  it("handles invalid subscription JSON without failing quota rendering", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: "not-json" }
      }
      return { status: 200, bodyText: JSON.stringify(QUOTA_RESPONSE) }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBeNull()
    expect(result.lines.find((l) => l.label === "Session")).toBeTruthy()
  })

  it("handles subscription payload with empty list", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify({ data: [] }) }
      }
      return { status: 200, bodyText: JSON.stringify(QUOTA_RESPONSE) }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBeNull()
    expect(result.lines.find((l) => l.label === "Session")).toBeTruthy()
  })

  it("supports quota payloads where limits are top-level and numeric strings are accepted", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
      }
      return {
        status: 200,
        bodyText: JSON.stringify([
          { type: "TOKENS_LIMIT", percentage: "10", nextResetTime: 1738368000000, unit: 3 },
          { type: "TIME_LIMIT", currentValue: "1095", usage: "4000" },
        ]),
      }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const session = result.lines.find((l) => l.label === "Session")
    const web = result.lines.find((l) => l.label === "Web Searches")
    expect(session.used).toBe(10)
    expect(web.used).toBe(1095)
    expect(web.limit).toBe(4000)
  })

  it("rejects malformed quota values instead of coercing to zero", async () => {
    const cases = [
      { data: { limits: [{ type: "TOKENS_LIMIT", unit: 3, number: 5 }] } },
      { data: { limits: [{ type: "TOKENS_LIMIT", unit: 3, number: 5, percentage: true }] } },
      { data: { limits: [{ type: "TIME_LIMIT", usage: 1000 }] } },
      { data: { limits: [{ type: "TIME_LIMIT", currentValue: 10 }] } },
      { data: { limits: [{ type: "TIME_LIMIT", currentValue: -1, usage: 1000 }] } },
    ]

    for (const body of cases) {
      const ctx = makeCtx()
      mockEnvWithKey(ctx, "test-key")
      ctx.host.http.request.mockImplementation((opts) => {
        if (opts.url.includes("subscription")) {
          return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
        }
        return { status: 200, bodyText: JSON.stringify(body) }
      })
      const plugin = await loadPlugin()
      expect(() => plugin.probe(ctx)).toThrow("Usage response invalid")
    }
  })

  it("rejects malformed quota envelopes but allows explicit empty limits", async () => {
    for (const body of [{ data: [] }, { data: {} }, { data: { limits: {} } }]) {
      const ctx = makeCtx()
      mockEnvWithKey(ctx, "test-key")
      ctx.host.http.request.mockImplementation((opts) => {
        if (opts.url.includes("subscription")) {
          return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
        }
        return { status: 200, bodyText: JSON.stringify(body) }
      })
      const plugin = await loadPlugin()
      expect(() => plugin.probe(ctx)).toThrow("Usage response invalid")
    }

    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
      }
      return { status: 200, bodyText: JSON.stringify({ data: { limits: [] } }) }
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines[0].text).toBe("No usage data")
  })

  it("shows no-usage badge when token limit entry is missing", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
      }
      return {
        status: 200,
        bodyText: JSON.stringify({
          data: { limits: [{ type: "FUTURE_LIMIT" }, { type: "TOKENS_LIMIT", unit: 99, number: 1, percentage: 70 }] },
        }),
      }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines).toHaveLength(1)
    expect(result.lines[0].text).toBe("No usage data")
  })

  it("renders Weekly line with percent format and 7-day reset", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
      }
      return { status: 200, bodyText: JSON.stringify(QUOTA_RESPONSE_WITH_WEEKLY) }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines.find((l) => l.label === "Weekly")
    expect(line).toBeTruthy()
    expect(line.type).toBe("progress")
    expect(line.used).toBe(10)
    expect(line.limit).toBe(100)
    expect(line.format).toEqual({ kind: "percent" })
    expect(line.periodDurationMs).toBe(7 * 7 * 24 * 60 * 60 * 1000)
  })

  it("Weekly line has correct percentage, resetsAt, and periodDurationMs values", async () => {
    const ctx = makeCtx()
    ctx.nowIso = "2025-01-01T00:00:00Z"
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
      }
      return { status: 200, bodyText: JSON.stringify(QUOTA_RESPONSE_WITH_WEEKLY) }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines.find((l) => l.label === "Weekly")
    expect(line).toBeTruthy()
    expect(line.resetsAt).toBe(new Date(1738972800000).toISOString())
    expect(line.periodDurationMs).toBe(7 * 7 * 24 * 60 * 60 * 1000)
  })

  it("correctly binds Session to unit 3 and Weekly to unit 6 when weekly appears first", async () => {
    const ctx = makeCtx()
    ctx.nowIso = "2025-01-01T00:00:00Z"
    mockEnvWithKey(ctx, "test-key")
    const quotaReversed = {
      code: 200,
      data: {
        limits: [
          {
            type: "TOKENS_LIMIT",
            usage: 1600000000,
            currentValue: 4800000,
            percentage: 75,
            nextResetTime: 1738972800000,
            unit: 6,
            number: 7,
          },
          {
            type: "TOKENS_LIMIT",
            usage: 800000000,
            currentValue: 1900000,
            percentage: 10,
            nextResetTime: 1738368000000,
            unit: 3,
            number: 5,
          },
          {
            type: "TIME_LIMIT",
            usage: 4000,
            currentValue: 1095,
            percentage: 27,
            remaining: 2905,
            unit: 5,
            number: 1,
          },
        ],
      },
    }
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
      }
      return { status: 200, bodyText: JSON.stringify(quotaReversed) }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const session = result.lines.find((l) => l.label === "Session")
    const weekly = result.lines.find((l) => l.label === "Weekly")
    expect(session).toBeTruthy()
    expect(session.used).toBe(10)
    expect(session.resetsAt).toBe(new Date(1738368000000).toISOString())
    expect(weekly).toBeTruthy()
    expect(weekly.used).toBe(75)
    expect(weekly.resetsAt).toBe(new Date(1738972800000).toISOString())
  })
  it("renders Session and Weekly from CREDIT_LIMIT entries when TOKENS_LIMIT is absent", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
      }
      return { status: 200, bodyText: JSON.stringify(QUOTA_RESPONSE_CREDIT_LIMIT) }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const session = result.lines.find((l) => l.label === "Session")
    const weekly = result.lines.find((l) => l.label === "Weekly")
    expect(session).toBeTruthy()
    expect(session.type).toBe("progress")
    expect(session.used).toBe(1)
    expect(session.limit).toBe(100)
    expect(session.format).toEqual({ kind: "percent" })
    expect(session.periodDurationMs).toBe(5 * 60 * 60 * 1000)
    expect(session.resetsAt).toBe(new Date(1790069319040).toISOString())
    expect(weekly).toBeTruthy()
    expect(weekly.used).toBe(70)
    expect(weekly.periodDurationMs).toBe(7 * 24 * 60 * 60 * 1000)
    expect(weekly.resetsAt).toBe(new Date(1790234556979).toISOString())
  })

  it("prefers TOKENS_LIMIT over CREDIT_LIMIT when both types are present", async () => {
    const ctx = makeCtx()
    ctx.nowIso = "2025-01-01T00:00:00Z"
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
      }
      return {
        status: 200,
        bodyText: JSON.stringify({
          code: 200,
          data: {
            limits: [
              QUOTA_RESPONSE_CREDIT_LIMIT.data.limits[0],
              QUOTA_RESPONSE_CREDIT_LIMIT.data.limits[1],
              {
                type: "TOKENS_LIMIT",
                usage: 800000000,
                currentValue: 1900000,
                percentage: 42,
                nextResetTime: 1738368000000,
                unit: 3,
                number: 5,
              },
            ],
          },
        }),
      }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const session = result.lines.find((l) => l.label === "Session")
    expect(session).toBeTruthy()
    expect(session.used).toBe(42)
    expect(session.resetsAt).toBe(new Date(1738368000000).toISOString())
  })

  it("uses the selected account key, then config, then environment", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "environment-key")
    ctx.host.fs.writeText("~/.config/openusage/zai.json", JSON.stringify({ api_key: "config-key" }))
    ctx.util.providerApiKey = vi.fn().mockReturnValueOnce("account-key")
    mockHttp(ctx)
    const plugin = await loadPlugin()
    plugin.probe(ctx)
    plugin.probe(ctx)
    expect(ctx.host.http.request.mock.calls.map(([req]) => req.headers.Authorization)).toEqual([
      "Bearer account-key", "Bearer account-key", "Bearer config-key", "Bearer config-key",
    ])
  })

  it("keeps a valid window beside malformed entries and drops stale resets and zero allowances", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({ limits: [
        { type: "CREDIT_LIMIT", unit: 3, number: 5 },
        { name: "CREDIT_LIMIT", unit: "4", number: "7", percentage: 20, nextResetTime: 1 },
        { type: "TIME_LIMIT", currentValue: 0, usage: 0 },
      ] }),
    })
    const plugin = await loadPlugin()
    const { lines } = plugin.probe(ctx)
    expect(lines).toHaveLength(1)
    expect(lines[0]).toMatchObject({ label: "Weekly", used: 20, periodDurationMs: 604800000 })
    expect(lines[0].resetsAt).toBeUndefined()
  })

  it("reports that a valid key has no Coding Plan without exposing a subscription label", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation(({ url }) => ({
      status: 200,
      bodyText: JSON.stringify(url.includes("subscription")
        ? SUBSCRIPTION_RESPONSE
        : { success: false, msg: "No Coding Plan" }),
    }))
    const plugin = await loadPlugin()
    expect(plugin.probe(ctx)).toMatchObject({
      plan: null,
      lines: [expect.objectContaining({ type: "badge", text: "No usage data" })],
      warning: expect.stringContaining("No active GLM Coding Plan"),
    })
    expect(ctx.host.http.request).toHaveBeenCalledTimes(1)
  })

})
