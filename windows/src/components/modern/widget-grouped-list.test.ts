import { describe, expect, it } from "vitest"
import { buildProviderWidgetGroups } from "@/components/modern/widget-grouped-list"
import { metricId } from "@/lib/metric-id"
import { placeholderWidgetData } from "@/lib/widget-data"
import type { PluginMeta, PluginOutput } from "@/lib/plugin-types"

describe("buildProviderWidgetGroups", () => {
  const cursorMeta: PluginMeta = {
    id: "cursor:work",
    baseProviderId: "cursor",
    instanceLabel: "Work",
    name: "Cursor (Work)",
    iconUrl: "",
    lines: [],
    primaryCandidates: [],
  }

  it("groups metrics for provider account instances", () => {
    const credits = metricId("cursor:work", "Credits")
    const groups = buildProviderWidgetGroups({
      placedMetricIds: [credits],
      providerOrder: ["cursor", "cursor:work"],
      metricOrderByProvider: {},
      widgetDataById: new Map(),
      getMeta: (id) => (id === "cursor:work" ? cursorMeta : undefined),
    })

    expect(groups).toHaveLength(1)
    expect(groups[0]?.pluginId).toBe("cursor:work")
    expect(groups[0]?.name).toBe("Cursor")
    expect(groups[0]?.instanceLabel).toBe("Work")
    expect(groups[0]?.metrics).toHaveLength(1)
  })

  it("keeps saved row order in each bucket and hides missing rows after a successful probe", () => {
    const id = cursorMeta.id
    const session = metricId(id, "Session")
    const credits = metricId(id, "Credits")
    const missing = metricId(id, "Requests")
    const output: PluginOutput = {
      providerId: id,
      displayName: cursorMeta.name,
      iconUrl: cursorMeta.iconUrl,
      lines: [
        { type: "text", label: "Session", value: "Available" },
        { type: "text", label: "Credits", value: "150" },
      ],
    }
    const widgetDataById = new Map([session, credits].map((metricIdValue) => [
      metricIdValue,
      placeholderWidgetData({ metricId: metricIdValue, label: metricIdValue, displayName: "Cursor" }),
    ]))
    const [group] = buildProviderWidgetGroups({
      placedMetricIds: [session, missing, credits],
      providerOrder: [id],
      metricOrderByProvider: { [id]: [credits, missing, session] },
      widgetDataById,
      getMeta: () => cursorMeta,
      getState: () => ({ data: output, loading: false, error: null }),
      isOnDemand: (metric) => metric !== session,
    })

    expect(group.metrics.map((row) => row.metricId)).toEqual([session])
    expect(group.onDemandMetrics.map((row) => row.metricId)).toEqual([credits])
  })

  it("shows all rows when every row is On Demand", () => {
    const id = cursorMeta.id
    const credits = metricId(id, "Credits")
    const requests = metricId(id, "Requests")
    const [group] = buildProviderWidgetGroups({
      placedMetricIds: [credits, requests],
      providerOrder: [id],
      metricOrderByProvider: { [id]: [requests, credits] },
      widgetDataById: new Map(),
      getMeta: () => cursorMeta,
      isOnDemand: () => true,
    })

    expect(group.metrics.map((row) => row.metricId)).toEqual([requests, credits])
    expect(group.onDemandMetrics).toEqual([])
  })
})
