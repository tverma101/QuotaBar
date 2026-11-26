import { beforeEach, describe, expect, it, vi } from "vitest"

vi.mock("@/lib/settings", () => ({
  loadModernLayout: vi.fn(),
  saveModernLayout: vi.fn().mockResolvedValue(undefined),
}))

import { saveModernLayout } from "@/lib/settings"
import { metricId } from "@/lib/metric-id"
import { EMPTY_MODERN_LAYOUT } from "@/lib/modern-layout"
import type { MetricDescriptor } from "@/lib/metric-registry"
import { useModernLayoutStore } from "@/stores/modern-layout-store"

const claudeSession = metricId("claude", "Session")
const claudeWeekly = metricId("claude", "Weekly")
const antigravityWeekly = metricId("antigravity", "Weekly")
const cursorCredits = metricId("cursor", "Credits")

function desc(pluginId: string, lineLabel: string): MetricDescriptor {
  return {
    id: metricId(pluginId, lineLabel),
    pluginId,
    lineLabel,
    manifest: { type: "progress", label: lineLabel, scope: "overview" },
    displayName: pluginId,
    bounded: true,
  }
}

const descriptors = [
  desc("claude", "Session"),
  desc("claude", "Weekly"),
  desc("antigravity", "Weekly"),
  desc("cursor", "Credits"),
]

describe("modern-layout-store tray readout", () => {
  beforeEach(() => {
    useModernLayoutStore.setState({
      ...EMPTY_MODERN_LAYOUT,
      hydrated: true,
      pinLimitNotice: null,
      initialized: true,
      pinnedMetricIds: [claudeSession, cursorCredits],
      trayFocusProviderId: "claude",
    })
  })

  it("applyTrayReadout focuses the plugin and pins its meter first", () => {
    useModernLayoutStore.getState().applyTrayReadout("antigravity", "Weekly")
    const state = useModernLayoutStore.getState()
    expect(state.trayFocusProviderId).toBe("antigravity")
    expect(state.pinnedMetricIds[0]).toBe(antigravityWeekly)
    expect(state.pinnedMetricIds).toContain(claudeSession)
    expect(state.pinnedMetricIds).toContain(cursorCredits)
  })

  it("applyTrayReadout leaves an already-pinned only meter in place", () => {
    useModernLayoutStore.getState().applyTrayReadout("cursor", "Credits")
    const state = useModernLayoutStore.getState()
    expect(state.trayFocusProviderId).toBe("cursor")
    expect(state.pinnedMetricIds).toEqual([claudeSession, cursorCredits])
  })

  it("applyTrayReadout reorders sibling pins within the provider group", () => {
    useModernLayoutStore.setState({
      pinnedMetricIds: [claudeSession, claudeWeekly, cursorCredits],
    })
    useModernLayoutStore.getState().applyTrayReadout("claude", "Weekly")
    const state = useModernLayoutStore.getState()
    expect(state.trayFocusProviderId).toBe("claude")
    expect(state.pinnedMetricIds).toEqual([claudeWeekly, claudeSession, cursorCredits])
  })

  it("syncPinsFromTrayLines does not overwrite pins or focus after init", () => {
    useModernLayoutStore.getState().applyTrayReadout("antigravity", "Weekly")
    useModernLayoutStore.getState().syncPinsFromTrayLines(
      {
        claude: ["Session", "Weekly"],
        antigravity: ["Weekly"],
      },
      descriptors,
    )
    const state = useModernLayoutStore.getState()
    expect(state.trayFocusProviderId).toBe("antigravity")
    expect(state.pinnedMetricIds[0]).toBe(antigravityWeekly)
    expect(state.pinnedMetricIds).toEqual([
      antigravityWeekly,
      claudeSession,
      cursorCredits,
    ])
    expect(state.pinnedMetricIds).not.toContain(claudeWeekly)
  })
})

describe("modern-layout-store descriptor sync", () => {
  beforeEach(() => {
    useModernLayoutStore.setState({
      ...EMPTY_MODERN_LAYOUT,
      hydrated: true,
      pinLimitNotice: null,
      initialized: true,
      pinnedMetricIds: [claudeSession],
      trayFocusProviderId: "claude",
    })
    vi.mocked(saveModernLayout).mockClear()
  })

  it("writes once when descriptors add metrics, then not again for the same descriptors", () => {
    const store = useModernLayoutStore.getState()
    store.syncDescriptors(descriptors)
    expect(saveModernLayout).toHaveBeenCalledTimes(1)
    const after = useModernLayoutStore.getState()
    expect(after.metricOrderByProvider.claude).toEqual([claudeSession, claudeWeekly])

    useModernLayoutStore.getState().syncDescriptors(descriptors)
    useModernLayoutStore.getState().syncDescriptors([...descriptors])
    expect(saveModernLayout).toHaveBeenCalledTimes(1)
    expect(useModernLayoutStore.getState().metricOrderByProvider).toBe(after.metricOrderByProvider)
  })

  it("still writes when a pinned metric disappears", () => {
    useModernLayoutStore.getState().syncDescriptors(descriptors)
    vi.mocked(saveModernLayout).mockClear()
    useModernLayoutStore.getState().syncDescriptors(descriptors.filter((d) => d.id !== claudeSession))
    expect(saveModernLayout).toHaveBeenCalledTimes(1)
    expect(useModernLayoutStore.getState().pinnedMetricIds).toEqual([])
  })
})
