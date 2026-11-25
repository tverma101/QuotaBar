import { describe, expect, it } from "vitest"
import { displayMetricLabel, isDefaultOnDemand, isMetricOnDemand } from "@/lib/metric-display"

describe("displayMetricLabel", () => {
  it("title-cases plain labels and keeps small words lowercase", () => {
    expect(displayMetricLabel("Total usage")).toBe("Total Usage")
    expect(displayMetricLabel("Usage trend")).toBe("Usage Trend")
    expect(displayMetricLabel("Weekly — Claude and GPT Models")).toBe("Weekly — Claude and GPT Models")
  })

  it("uses the macOS names for renamed rows", () => {
    expect(displayMetricLabel("Extra usage spent")).toBe("Extra Usage")
    expect(displayMetricLabel("On-demand")).toBe("On-Demand")
  })

  it("leaves model ids and mixed-case words alone", () => {
    expect(displayMetricLabel("gpt-5.5 tokens")).toBe("gpt-5.5 Tokens")
    expect(displayMetricLabel("Last 30 Days")).toBe("Last 30 Days")
  })
})

describe("On Demand defaults", () => {
  it("puts spend rows behind the caret except for Freebuff", () => {
    expect(isDefaultOnDemand("claude", "Today")).toBe(true)
    expect(isDefaultOnDemand("codex", "Last 30 Days")).toBe(true)
    expect(isDefaultOnDemand("freebuff", "Today")).toBe(false)
  })

  it("follows the macOS per-provider list", () => {
    expect(isDefaultOnDemand("claude", "Sonnet")).toBe(true)
    expect(isDefaultOnDemand("claude", "Session")).toBe(false)
    expect(isDefaultOnDemand("cursor", "On-demand")).toBe(true)
  })

  it("lets a saved override win over the default", () => {
    expect(isMetricOnDemand("claude::Sonnet", "claude", "Sonnet", { "claude::Sonnet": false })).toBe(false)
    expect(isMetricOnDemand("claude::Session", "claude", "Session", { "claude::Session": true })).toBe(true)
    expect(isMetricOnDemand("claude:work::Sonnet", "claude", "Sonnet", {})).toBe(true)
  })
})
