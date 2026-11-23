import { describe, expect, it } from "vitest"
import { buildHistoryReport } from "@/lib/history-report"
import type { UsageDailyRow } from "@/lib/usage-daily"

function row(
  instanceId: string, dayKey: string, totalTokens: number, costUsd: number | null,
): UsageDailyRow {
  return { instanceId, dayKey, totalTokens, costUsd, displayName: "Same Name", inputTokens: null,
    outputTokens: null, source: "local_logs", ingestedAtMs: 0 }
}

describe("buildHistoryReport", () => {
  it("keeps account identity, period boundaries and unpriced tokens separate", () => {
    const report = buildHistoryReport([
      row("work", "2026-10-01", 30, 0),
      row("work", "2026-10-02", 20, null),
      row("home", "2026-10-25", 40, 1),
      row("work", "2026-10-31", 50, 2),
      row("work", "2026-11-01", 100, 10),
      row("disabled", "2026-10-31", 100, 10),
    ], ["home", "work"], new Date(2026, 9, 31, 15))

    expect(report.since).toBe("2026-10-01")
    expect(report.lifetime).toEqual({ tokens: 140, cost: 3, partial: true })
    expect(report.today).toEqual({ tokens: 50, cost: 2, partial: false })
    expect(report.last7).toEqual({ tokens: 90, cost: 3, partial: false })
    expect(report.last30).toEqual({ tokens: 110, cost: 3, partial: true })
    expect(report.days).toHaveLength(30)
    expect(report.days[0]).toMatchObject({ key: "2026-10-02", cost: null })
    expect(report.days[1]).toMatchObject({ key: "2026-10-03", tokens: 0 })
    expect(report.accounts.map(({ id, tokens }) => [id, tokens])).toEqual([["home", 40], ["work", 70]])
  })

  it("sums known public-rate estimates across the same lifetime scope as cost", () => {
    const report = buildHistoryReport([
      { ...row("work", "2026-01-01", 30, 2), apiEstimateUsd: 1 },
      row("work", "2026-10-31", 20, null),
      { ...row("work", "2026-10-31", 20, 4), apiEstimateUsd: 3 },
      { ...row("disabled", "2026-10-31", 20, 4), apiEstimateUsd: 5 },
      { ...row("work", "2026-11-01", 20, 4), apiEstimateUsd: 6 },
    ], ["work"], new Date(2026, 9, 31))
    expect(report.lifetime.cost).toBe(6)
    expect(report.apiEstimate).toBe(4)
    expect(buildHistoryReport([], ["work"], new Date(2026, 9, 31)).apiEstimate).toBeNull()
  })
})
