import { renderHook } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { USAGE_ALERT_GROUP_DELAY_MS } from "@/lib/usage-alert-group"
import type { PluginOutput } from "@/lib/plugin-types"
import { useAppPluginStore } from "@/stores/app-plugin-store"
import { useAppPreferencesStore } from "@/stores/app-preferences-store"

const { sendNotificationAsync } = vi.hoisted(() => ({
  sendNotificationAsync: vi.fn(() => Promise.resolve()),
}))

vi.mock("@/lib/notification", () => ({
  sendNotificationAsync,
}))

vi.mock("@tauri-apps/api/core", () => ({
  convertFileSrc: (path: string) => path,
}))

import { useUsageAlert } from "@/hooks/app/use-usage-alert"

const WEEK_MS = 7 * 24 * 60 * 60 * 1000

function makeOutput(overrides: Partial<PluginOutput> = {}): PluginOutput {
  const resetsAt = new Date(Date.now() + 3 * 24 * 60 * 60 * 1000).toISOString()
  return {
    providerId: "cursor",
    displayName: "Cursor",
    lines: [
      {
        type: "progress",
        label: "Total usage",
        used: 80,
        limit: 100,
        format: { kind: "percent" },
        resetsAt,
        periodDurationMs: WEEK_MS,
      },
    ],
    iconUrl: "icon",
    ...overrides,
  }
}

describe("useUsageAlert", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  beforeEach(() => {
    vi.useFakeTimers()
    sendNotificationAsync.mockClear()
    useAppPreferencesStore.getState().resetState()
    useAppPluginStore.getState().resetState()

    useAppPreferencesStore.getState().setUsageAlertEnabled(true)
    useAppPreferencesStore.getState().setUsageAlertThreshold(20)
    useAppPreferencesStore.getState().setUsagePaceAlertEnabled(true)

    useAppPluginStore.getState().setPluginsMeta([
      {
        id: "cursor",
        name: "Cursor",
        iconUrl: "icon",
        iconFilePath: "/icon.png",
        brandColor: "#000",
        lines: [{ type: "progress", label: "Total usage", scope: "overview" }],
        primaryCandidates: ["Total usage"],
      },
    ])
    useAppPluginStore.getState().setPluginSettings({
      order: ["cursor"],
      disabled: [],
    })
  })

  it("groups the low-remaining and pace alerts of one refresh into one notification", () => {
    const { result } = renderHook(() => useUsageAlert())
    result.current.checkUsageAlert(makeOutput())
    vi.advanceTimersByTime(USAGE_ALERT_GROUP_DELAY_MS)

    expect(sendNotificationAsync).toHaveBeenCalledTimes(1)
    expect(sendNotificationAsync).toHaveBeenCalledWith(
      expect.objectContaining({
        title: "2 Usage Alerts",
        subtitle: "Cursor Total usage",
        body: "Almost Out: Cursor Total usage\nWill Run Out: Cursor Total usage",
        iconPath: "/icon.png",
      }),
    )
  })

  it("does not repeat an alert until the metric recovers", () => {
    const { result } = renderHook(() => useUsageAlert())
    result.current.checkUsageAlert(makeOutput())
    result.current.checkUsageAlert(makeOutput())
    vi.advanceTimersByTime(USAGE_ALERT_GROUP_DELAY_MS)
    result.current.checkUsageAlert(makeOutput())
    vi.advanceTimersByTime(USAGE_ALERT_GROUP_DELAY_MS)

    expect(sendNotificationAsync).toHaveBeenCalledTimes(1)
  })

  it("skips pace alerts when usagePaceAlertEnabled is false", () => {
    useAppPreferencesStore.getState().setUsagePaceAlertEnabled(false)
    const { result } = renderHook(() => useUsageAlert())
    result.current.checkUsageAlert(makeOutput())
    vi.advanceTimersByTime(USAGE_ALERT_GROUP_DELAY_MS)

    expect(sendNotificationAsync).toHaveBeenCalledTimes(1)
    expect(sendNotificationAsync.mock.calls[0][0]).toEqual(
      expect.objectContaining({
        title: "Almost Out",
        subtitle: "Cursor Total usage",
        body: "Under 20% usage remaining for this window.",
      }),
    )
  })

  it("does nothing when alerts are disabled", () => {
    useAppPreferencesStore.getState().setUsageAlertEnabled(false)
    const { result } = renderHook(() => useUsageAlert())
    result.current.checkUsageAlert(makeOutput())
    vi.advanceTimersByTime(USAGE_ALERT_GROUP_DELAY_MS)

    expect(sendNotificationAsync).not.toHaveBeenCalled()
  })
})
