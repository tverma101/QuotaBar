import type { WidgetData } from "@/lib/widget-data"
import type { DisplayMode } from "@/lib/settings"
import { isFreshUsageWindow, minimumElapsedMs } from "@/lib/pace-status"
import { formatCompactDuration } from "@/lib/pace-tooltip"

/**
 * Meter fill severity and pace copy for a dashboard row — a port of the macOS
 * `WidgetData.meterState(now:)` precedence so both apps color the same reading
 * the same way:
 *
 * 1. no data → gray track, no fill color
 * 2. spent (remainder rounds to zero at the headline's precision) → red, "Limit reached"
 * 3. live pace verdict (reset window) → blue ≥10% projected spare, yellow inside the
 *    last 10% ("~N% spare"), red when projected past the limit ("Limit in 3h")
 * 4. absolute level bands → yellow from 80% used, red from 90% used
 *
 * Bands key off the share used, never the displayed fraction, so the color does
 * not flip with the Used/Left toggle.
 */
export type MeterSeverity = "normal" | "warning" | "critical"

export type MeterState =
  | { kind: "noData" }
  | { kind: "spent" }
  | { kind: "runningOut"; eta: string | null }
  | { kind: "closeToLimit"; spare: string }
  | { kind: "healthy" }
  | { kind: "level"; severity: MeterSeverity }

const NEAR_EMPTY_SHARE = 0.05

function roundedRemainder(data: WidgetData, remaining: number, limit: number): number {
  if (data.format === "percent") return Math.round((remaining / limit) * 100)
  if (data.format === "dollars") return Math.round(remaining * 100) / 100
  return Math.round(remaining)
}

function levelState(used: number, limit: number): MeterState {
  const percentUsed = Math.round(Math.min(Math.max(used / limit, 0), 1) * 100)
  if (percentUsed >= 90) return { kind: "level", severity: "critical" }
  if (percentUsed >= 80) return { kind: "level", severity: "warning" }
  return { kind: "level", severity: "normal" }
}

type PaceWindow = { resetsAtMs: number; periodMs: number; elapsedMs: number }

function paceWindow(data: WidgetData, nowMs: number): PaceWindow | null {
  if (data.format !== "percent" || !data.resetsAt || !data.periodDurationMs) return null
  const resetsAtMs = Date.parse(data.resetsAt)
  const periodMs = data.periodDurationMs
  if (!Number.isFinite(resetsAtMs) || periodMs <= 0 || nowMs >= resetsAtMs) return null
  const elapsedMs = nowMs - (resetsAtMs - periodMs)
  if (elapsedMs < minimumElapsedMs(periodMs)) return null
  return { resetsAtMs, periodMs, elapsedMs }
}

export function meterState(data: WidgetData, nowMs: number = Date.now()): MeterState {
  if (!data.bounded || data.loading || data.used == null || data.limit == null) {
    return { kind: "noData" }
  }
  const { used, limit } = data
  if (!Number.isFinite(used) || !Number.isFinite(limit) || limit <= 0) {
    return { kind: "level", severity: "normal" }
  }
  if (roundedRemainder(data, limit - used, limit) <= 0) return { kind: "spent" }

  const window = paceWindow(data, nowMs)
  if (!window || isFreshUsageWindow(window.resetsAtMs, window.periodMs, nowMs)) {
    return levelState(used, limit)
  }
  if (used <= 0) return { kind: "healthy" }

  const projected = (used / window.elapsedMs) * window.periodMs
  const projectedShare = projected / limit
  if (projectedShare <= 0.9) return { kind: "healthy" }
  if (used / limit < NEAR_EMPTY_SHARE) return levelState(used, limit)
  if (projectedShare <= 1) {
    const spare = Math.round((1 - projectedShare) * 100)
    if (spare < 1) return { kind: "runningOut", eta: null }
    return { kind: "closeToLimit", spare: `~${spare}% spare` }
  }
  const rate = used / window.elapsedMs
  const runOutMs = (limit - used) / rate
  const remainingMs = window.resetsAtMs - nowMs
  const duration = runOutMs > 0 && runOutMs < remainingMs ? formatCompactDuration(runOutMs) : null
  return { kind: "runningOut", eta: duration ? `Limit in ${duration}` : null }
}

export function meterSeverity(state: MeterState): MeterSeverity | null {
  switch (state.kind) {
    case "noData":
      return null
    case "spent":
    case "runningOut":
      return "critical"
    case "closeToLimit":
      return "warning"
    case "healthy":
      return "normal"
    case "level":
      return state.severity
  }
}

/** Short copy for the label line's trailing slot (flame + text on macOS). */
export function meterWarningText(state: MeterState): string | null {
  if (state.kind === "spent") return "Limit reached"
  if (state.kind === "runningOut") return state.eta
  if (state.kind === "closeToLimit") return state.spare
  return null
}

/** Meter fill share, framed by the Used/Left display mode like the macOS bar. */
export function meterFillFraction(data: WidgetData, displayMode: DisplayMode): number {
  if (!data.bounded || data.used == null || data.limit == null || data.limit <= 0) return 0
  const usedShare = Math.min(Math.max(data.used / data.limit, 0), 1)
  return displayMode === "used" ? usedShare : 1 - usedShare
}

/**
 * Even-pace tick (0…1) on the bar: the elapsed share of the reset window, framed
 * like the fill. Only warning and critical pace states show it.
 */
export function paceTickFraction(
  data: WidgetData,
  state: MeterState,
  displayMode: DisplayMode,
  nowMs: number = Date.now(),
): number | null {
  if (state.kind !== "closeToLimit" && state.kind !== "runningOut") return null
  const window = paceWindow(data, nowMs)
  if (!window) return null
  const elapsedShare = Math.min(Math.max(window.elapsedMs / window.periodMs, 0), 1)
  return displayMode === "used" ? elapsedShare : 1 - elapsedShare
}
