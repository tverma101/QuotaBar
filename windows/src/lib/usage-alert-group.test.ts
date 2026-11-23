import { afterEach, describe, expect, it, vi } from "vitest"
import { createUsageAlertBatcher, groupUsageAlerts, type UsageAlertEvent } from "@/lib/usage-alert-group"

const event = (overrides: Partial<UsageAlertEvent> = {}): UsageAlertEvent => ({
  key: "claude:session:low",
  kind: "lowRemaining",
  providerId: "claude",
  providerName: "Claude",
  metricLabel: "Session",
  body: "Under 10% usage remaining for this window.",
  ...overrides,
})

describe("groupUsageAlerts", () => {
  it("uses the verdict as title and provider metric as subtitle", () => {
    expect(groupUsageAlerts([event()])).toEqual({
      title: "Almost Out",
      subtitle: "Claude Session",
      body: "Under 10% usage remaining for this window.",
      providerIds: ["claude"],
    })
  })

  it("returns null for no events and drops duplicate keys", () => {
    expect(groupUsageAlerts([])).toBeNull()
    expect(groupUsageAlerts([event(), event()])?.subtitle).toBe("Claude Session")
  })

  it("groups same-verdict alerts under the shared title", () => {
    const grouped = groupUsageAlerts([
      event(),
      event({ key: "codex:weekly:low", providerId: "codex", providerName: "Codex", metricLabel: "Weekly" }),
    ])
    expect(grouped?.title).toBe("Almost Out")
    expect(grouped?.subtitle).toBe("Claude Session, Codex Weekly")
    expect(grouped?.body.split("\n")).toHaveLength(2)
    expect(grouped?.providerIds).toEqual(["claude", "codex"])
  })

  it("counts mixed verdicts", () => {
    const grouped = groupUsageAlerts([
      event(),
      event({ key: "claude:session:pace", kind: "pace", body: "Projected to finish before the limit resets." }),
    ])
    expect(grouped?.title).toBe("2 Usage Alerts")
    expect(grouped?.body).toBe("Almost Out: Claude Session\nWill Run Out: Claude Session")
  })
})

describe("createUsageAlertBatcher", () => {
  afterEach(() => vi.useRealTimers())

  it("delivers one grouped alert per window", () => {
    vi.useFakeTimers()
    const deliver = vi.fn()
    const batcher = createUsageAlertBatcher(deliver, 1000)
    batcher.add(event())
    batcher.add(event({ key: "codex:weekly:low", providerName: "Codex", providerId: "codex" }))
    expect(deliver).not.toHaveBeenCalled()
    vi.advanceTimersByTime(1000)
    expect(deliver).toHaveBeenCalledTimes(1)
    batcher.add(event())
    batcher.cancel()
    vi.advanceTimersByTime(1000)
    expect(deliver).toHaveBeenCalledTimes(1)
  })
})
