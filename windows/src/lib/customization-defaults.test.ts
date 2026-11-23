import { describe, expect, it } from "vitest"
import { defaultMetricCustomization } from "@/lib/customization-defaults"
import { metricId } from "@/lib/metric-id"
import { buildMetricDescriptors } from "@/lib/metric-registry"
import type { PluginMeta } from "@/lib/plugin-types"
import { resetPluginCustomization } from "@/lib/settings"

describe("Reset All Customization", () => {
  it("restores known default metrics and accounts without altering account metadata", () => {
    const plugins = [
      ["claude", ["Session", "Weekly", "Sonnet", "Today"]],
      ["codex", ["Session", "Weekly", "Spark", "Reviews"]],
      ["cursor", ["Credits", "Total usage", "Cursor Models", "Requests"]],
      ["freebuff", ["Daily", "Daily Hours"]],
      ["grok", ["Pay as you go"]],
    ].map(([id, labels]) => ({
      id, name: id,
      lines: (labels as string[]).map((label) => ({ label, type: "progress", scope: "overview" })),
    })) as PluginMeta[]
    const settings = {
      order: ["grok", "codex-work", "cursor", "claude-work"],
      disabled: ["codex", "claude", "codex-work"],
      trayLines: { grok: ["__NONE__"], "codex-work": ["Reviews"] },
      providerLabels: { claude: "My Claude" },
      providerInstances: {
        "codex-work": { baseProviderId: "codex", label: "Work" },
        "claude-work": { baseProviderId: "claude", label: "Team" },
      },
    }
    const reset = resetPluginCustomization(settings, plugins)
    const layout = defaultMetricCustomization(reset, buildMetricDescriptors(plugins, reset, undefined, true))
    expect(reset.order).toEqual(["claude", "codex", "cursor", "freebuff", "grok", "claude-work", "codex-work"])
    expect(reset.disabled).toEqual(["grok", "claude-work"])
    expect(reset.providerLabels).toEqual(settings.providerLabels)
    expect(reset.providerInstances).toEqual(settings.providerInstances)
    expect(layout.trayLines["codex-work"]).toEqual(["Session", "Weekly", "Spark"])
    expect(layout.trayLines.claude).toEqual(["Session", "Weekly", "Today"])
    expect(layout.onDemandMetricIds).toContain(metricId("claude", "Sonnet"))
    expect(layout.onDemandMetricIds).not.toContain(metricId("freebuff", "Daily Hours"))
    expect(layout.pinnedMetricIds).toContain(metricId("freebuff", "Daily Hours"))
    expect(settings.trayLines.grok).toEqual(["__NONE__"])
  })
})
