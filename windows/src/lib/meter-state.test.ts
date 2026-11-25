import { describe, expect, it } from "vitest"
import {
  meterFillFraction,
  meterSeverity,
  meterState,
  meterWarningText,
  paceTickFraction,
} from "@/lib/meter-state"
import type { WidgetData } from "@/lib/widget-data"

const NOW = Date.parse("2026-11-25T12:00:00Z")
const HOUR = 60 * 60 * 1000
const PERIOD = 5 * HOUR

function meter(used: number | null, overrides: Partial<WidgetData> = {}): WidgetData {
  return {
    metricId: "claude::Session",
    label: "Session",
    displayName: "Claude",
    kind: "meter",
    bounded: true,
    used,
    limit: 100,
    resetsAt: null,
    periodDurationMs: null,
    textValue: used == null ? null : `${100 - used}% left`,
    textSecondary: null,
    paceStatus: null,
    paceDetail: null,
    isLimitReached: false,
    format: "percent",
    ...overrides,
  }
}

/** A 5h window with `elapsedMs` already gone. */
function windowed(used: number, elapsedMs: number): WidgetData {
  return meter(used, {
    resetsAt: new Date(NOW + PERIOD - elapsedMs).toISOString(),
    periodDurationMs: PERIOD,
  })
}

describe("meterState", () => {
  it("has no data while loading or without a reading", () => {
    expect(meterState(meter(40, { loading: true }), NOW)).toEqual({ kind: "noData" })
    expect(meterState(meter(null), NOW)).toEqual({ kind: "noData" })
    expect(meterSeverity({ kind: "noData" })).toBeNull()
  })

  it("is spent when the remainder rounds to zero at the headline precision", () => {
    expect(meterState(meter(99.6), NOW)).toEqual({ kind: "spent" })
    expect(meterWarningText({ kind: "spent" })).toBe("Limit reached")
    expect(meterState(meter(99.4), NOW)).toEqual({ kind: "level", severity: "critical" })
  })

  it("uses level bands without a reset window", () => {
    expect(meterState(meter(50), NOW)).toEqual({ kind: "level", severity: "normal" })
    expect(meterState(meter(80), NOW)).toEqual({ kind: "level", severity: "warning" })
    expect(meterState(meter(90), NOW)).toEqual({ kind: "level", severity: "critical" })
  })

  it("judges pace inside a live reset window", () => {
    expect(meterState(windowed(30, PERIOD / 2), NOW)).toEqual({ kind: "healthy" })

    const close = meterState(windowed(47, PERIOD / 2), NOW)
    expect(close).toEqual({ kind: "closeToLimit", spare: "~6% spare" })
    expect(meterSeverity(close)).toBe("warning")

    const runningOut = meterState(windowed(60, PERIOD / 2), NOW)
    expect(runningOut.kind).toBe("runningOut")
    expect(meterWarningText(runningOut)).toMatch(/^Limit in /)
    expect(meterSeverity(runningOut)).toBe("critical")
  })

  it("falls back to level bands in a window that has barely started", () => {
    expect(meterState(windowed(85, 10_000), NOW)).toEqual({ kind: "level", severity: "warning" })
  })

  it("keeps a nearly empty meter on its level band even when the projection is high", () => {
    expect(meterState(windowed(4, 10 * 60 * 1000), NOW)).toEqual({ kind: "level", severity: "normal" })
  })

  it("does not pace dollar meters", () => {
    const dollars = meter(95, {
      format: "dollars",
      resetsAt: new Date(NOW + HOUR).toISOString(),
      periodDurationMs: PERIOD,
    })
    expect(meterState(dollars, NOW)).toEqual({ kind: "level", severity: "critical" })
  })
})

describe("meterFillFraction", () => {
  it("follows the Used/Left display mode", () => {
    expect(meterFillFraction(meter(25), "used")).toBeCloseTo(0.25)
    expect(meterFillFraction(meter(25), "left")).toBeCloseTo(0.75)
    expect(meterFillFraction(meter(null), "left")).toBe(0)
    expect(meterFillFraction(meter(140), "used")).toBe(1)
  })
})

describe("paceTickFraction", () => {
  it("marks the elapsed share only for warning and critical pace", () => {
    const data = windowed(47, 2 * HOUR + 30 * 60 * 1000)
    const state = meterState(data, NOW)
    expect(state.kind).toBe("closeToLimit")
    expect(paceTickFraction(data, state, "used", NOW)).toBeCloseTo(0.5)
    expect(paceTickFraction(data, state, "left", NOW)).toBeCloseTo(0.5)

    const early = windowed(50, 2 * HOUR)
    const earlyState = meterState(early, NOW)
    expect(earlyState.kind).toBe("runningOut")
    expect(paceTickFraction(early, earlyState, "used", NOW)).toBeCloseTo(0.4)
    expect(paceTickFraction(early, earlyState, "left", NOW)).toBeCloseTo(0.6)

    const healthy = windowed(10, PERIOD / 2)
    expect(paceTickFraction(healthy, meterState(healthy, NOW), "used", NOW)).toBeNull()
  })
})
