import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "./test-helpers.js"

// Public builds follow Google's Antigravity and Gemini terms: no Google login reads, no Google or
// Antigravity endpoints, no local language-server probing, no Google browser cookies. The host blocks
// these too (crates/quotabar-core/src/google_terms.rs); these tests pin the plugins' friendly behavior.

const loadPlugin = async (id) => {
  await import(`./${id}/plugin.js`)
  return globalThis.__openusage_plugin
}

const publicCtx = () => {
  const ctx = makeCtx()
  ctx.app.googlePrivateAccess = false
  ctx.host.ls.discover.mockReturnValue({ pid: 1, csrf: "x", ports: [1], extensionPort: null })
  ctx.host.http.request.mockImplementation(() => {
    throw new Error("public builds must not make network requests")
  })
  return ctx
}

const todayKey = () => {
  const now = new Date()
  return [
    now.getFullYear(),
    String(now.getMonth() + 1).padStart(2, "0"),
    String(now.getDate()).padStart(2, "0"),
  ].join("-")
}

const withHistory = (ctx) => {
  ctx.host.antigravityLogs.queryDaily = vi.fn(() => ({
    status: "ok",
    data: { daily: [{ date: todayKey(), totalTokens: 1500, totalCost: 0.12, models: {} }] },
  }))
  return ctx
}

const expectNoGoogleAccess = (ctx) => {
  expect(ctx.host.http.request).not.toHaveBeenCalled()
  expect(ctx.host.ls.discover).not.toHaveBeenCalled()
  expect(ctx.host.keychain.readGenericPassword).not.toHaveBeenCalled()
  expect(ctx.host.sqlite.query).not.toHaveBeenCalled()
}

describe("public builds and Google's terms", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  for (const id of ["antigravity", "antigravity-cli"]) {
    it(`${id} shows local token history and no live limits`, async () => {
      const ctx = withHistory(publicCtx())
      const plugin = await loadPlugin(id)

      const result = plugin.probe(ctx)

      expect(result.lines.map((line) => line.label)).toEqual([
        "Today",
        "Yesterday",
        "Last 30 Days",
        "Usage Trend",
      ])
      expect(result.lines.find((line) => line.label === "Today").value).toContain("1.5K tokens")
      expectNoGoogleAccess(ctx)
    })

    it(`${id} explains the local-only source when there is no history`, async () => {
      const ctx = publicCtx()
      const plugin = await loadPlugin(id)

      expect(() => plugin.probe(ctx)).toThrow(/local conversation history/)
      expectNoGoogleAccess(ctx)
    })
  }

  it("antigravity refuses extra accounts instead of reading their Google login", async () => {
    const ctx = withHistory(publicCtx())
    ctx.account = { instanceId: "antigravity:work", baseProviderId: "antigravity" }
    ctx.util.readProviderCredential = vi.fn(() => ({ accessToken: "fixture" }))
    const plugin = await loadPlugin("antigravity")

    expect(() => plugin.probe(ctx)).toThrow(/Google's terms/)
    expect(ctx.util.readProviderCredential).not.toHaveBeenCalled()
    expectNoGoogleAccess(ctx)
  })

  for (const id of ["gemini-apps", "antigravity-ide"]) {
    it(`${id} is unavailable without touching Google`, async () => {
      const ctx = publicCtx()
      ctx.host.chromiumCookies = { read: vi.fn(() => ({})) }
      const plugin = await loadPlugin(id)

      expect(() => plugin.probe(ctx)).toThrow(/Google's terms/)
      expect(ctx.host.chromiumCookies.read).not.toHaveBeenCalled()
      expectNoGoogleAccess(ctx)
    })
  }
})
