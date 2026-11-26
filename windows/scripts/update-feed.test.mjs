import { describe, expect, it } from "vitest"
import { buildFeed, compareVersions, installerName, shouldReplace } from "./update-feed.mjs"

const signature = "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHRhdXJpIHNlY3JldCBrZXkK"

describe("update feed", () => {
  it("orders releases and betas like semver", () => {
    expect(compareVersions("0.7.2-beta.2", "0.7.2-beta.10")).toBe(-1)
    expect(compareVersions("0.7.2-beta.9", "0.7.2")).toBe(-1)
    expect(compareVersions("0.7.2", "0.7.10")).toBe(-1)
    expect(compareVersions("0.8.0", "0.7.99")).toBe(1)
    expect(compareVersions("0.7.2", "0.7.2")).toBe(0)
  })

  it("points the Windows platform at the release installer", () => {
    const feed = buildFeed({ tag: "v0.7.3-beta.1", repo: "owner/QuotaBar", signature: `${signature}\n`, pubDate: "2026-11-26T00:00:00Z" })
    expect(feed).toEqual({
      version: "0.7.3-beta.1",
      notes: "QuotaBar 0.7.3-beta.1. Release notes: https://github.com/owner/QuotaBar/releases/tag/v0.7.3-beta.1",
      pub_date: "2026-11-26T00:00:00Z",
      platforms: {
        "windows-x86_64": {
          signature,
          url: `https://github.com/owner/QuotaBar/releases/download/v0.7.3-beta.1/${installerName("0.7.3-beta.1")}`,
        },
      },
    })
  })

  it("refuses unsigned or malformed releases", () => {
    const base = { tag: "v0.7.3", repo: "owner/QuotaBar", signature, pubDate: "x" }
    expect(() => buildFeed({ ...base, signature: "" })).toThrow(/signature/)
    expect(() => buildFeed({ ...base, tag: "0.7.3" })).toThrow(/tag/)
    expect(() => buildFeed({ ...base, tag: "v0.7.3-rc.1" })).toThrow(/tag/)
    expect(() => buildFeed({ ...base, repo: "owner/QuotaBar/../x" })).toThrow(/Repository/)
  })

  it("only moves forward", () => {
    const next = buildFeed({ tag: "v0.7.3", repo: "owner/QuotaBar", signature, pubDate: "x" })
    expect(shouldReplace(null, next)).toBe(true)
    expect(shouldReplace({ version: "0.7.3-beta.4" }, next)).toBe(true)
    expect(shouldReplace({ version: "0.7.3" }, next)).toBe(false)
    expect(shouldReplace({ version: "0.8.0" }, next)).toBe(false)
  })
})
