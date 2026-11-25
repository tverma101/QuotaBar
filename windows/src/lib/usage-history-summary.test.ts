import { describe, expect, it } from "vitest"
import type { UsageDailyRow } from "@/lib/usage-daily"
import { summarizeUsageHistory } from "@/lib/usage-history-summary"

function row(dayKey: string, tokens: number, cost: number | null, instanceId = "claude"): UsageDailyRow {
  return {
    dayKey,
    instanceId,
    displayName: instanceId,
    totalTokens: tokens,
    costUsd: cost,
    inputTokens: null,
    outputTokens: null,
    source: "fixture",
    ingestedAtMs: 0,
  }
}

describe("summarizeUsageHistory", () => {
  const now = new Date(2026, 10, 25, 13)

  it("uses inclusive local calendar dates and keeps accounts separate", () => {
    const summary = summarizeUsageHistory([
      row("2026-11-25", 400, 4),
      row("2026-11-25", 50, null, "claude:work"),
      row("2026-11-24", 200, 2),
      row("2026-11-19", 100, 1),
      row("2026-11-18", 50, 0.5),
      row("2026-10-27", 30, 0.3),
      row("2026-10-26", 20, 0.2),
      row("2026-11-26", 999, 999),
      row("unknown", 999, 999),
    ], now)

    expect(summary.today).toEqual({ cost: 4, tokens: 450 })
    expect(summary.days7).toEqual({ cost: 7, tokens: 750 })
    expect(summary.days30).toEqual({ cost: 7.8, tokens: 830 })
    expect(summary.lifetime).toEqual({ cost: 8, tokens: 850, sinceDayKey: "2026-10-26" })
    expect(summary.daily).toHaveLength(30)
    expect(summary.daily[0]).toEqual({ dayKey: "2026-10-27", tokens: 30 })
    expect(summary.daily.at(-3)).toEqual({ dayKey: "2026-11-23", tokens: 0 })
    expect(summary.daily.at(-1)).toEqual({ dayKey: "2026-11-25", tokens: 450 })
    expect(summary.providers.map(({ instanceId, today }) => [instanceId, today.tokens])).toEqual([
      ["claude", 400],
      ["claude:work", 50],
    ])
  })

  it("has no lifetime start date without retained rows", () => {
    const summary = summarizeUsageHistory([], now)
    expect(summary.lifetime).toEqual({ cost: 0, tokens: 0, sinceDayKey: null })
    expect(summary.providers).toEqual([])
  })
})
