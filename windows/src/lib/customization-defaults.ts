import { metricId } from "@/lib/metric-id"
import type { MetricDescriptor } from "@/lib/metric-registry"
import { getBaseProviderId, type PluginSettings } from "@/lib/settings"

type Defaults = { hidden?: string[]; onDemand?: string[]; pins?: string[] }
const spend = ["Today", "Yesterday", "Last 30 Days"]
const defaults: Record<string, Defaults> = {
  antigravity: {
    onDemand: ["Session — Claude and GPT Models", "Weekly — Claude and GPT Models", ...spend],
    pins: ["Session", "Weekly"],
  },
  claude: {
    hidden: ["Sonnet", "Claude Design", "Rate Limit Resets"],
    onDemand: ["Sonnet", ...spend],
    pins: ["Session", "Weekly"],
  },
  codex: {
    hidden: ["Reviews"],
    onDemand: ["Spark", "Spark Weekly", "Credits", "Rate Limit Resets", ...spend],
    pins: ["Session", "Weekly"],
  },
  cursor: {
    hidden: ["Credits", "Requests"],
    onDemand: ["Credits", "Requests", "Grok Bot usage", "On-demand", ...spend],
    pins: ["Cursor Models", "Other Models"],
  },
  copilot: { onDemand: ["Chat", "Completions"], pins: ["Credits"] },
  devin: { onDemand: ["Extra usage balance"] },
  freebuff: { pins: ["Daily Hours"] },
  grok: { onDemand: ["Pay as you go", ...spend] },
  hermes: { onDemand: ["Usage Trend"] },
  opencode: { onDemand: spend },
  openrouter: { onDemand: ["Today", "This Week", "This Month", "Key Limit"], pins: ["Credits"] },
  zai: { onDemand: ["Web Searches", ...spend], pins: ["Session", "Weekly"] },
}

export function defaultMetricCustomization(settings: PluginSettings, descriptors: MetricDescriptor[]) {
  const knownByProvider = new Map<string, Set<string>>()
  for (const { pluginId, lineLabel } of descriptors) {
    let labels = knownByProvider.get(pluginId)
    if (!labels) knownByProvider.set(pluginId, labels = new Set())
    labels.add(lineLabel)
  }

  const trayLines: Record<string, string[]> = {}
  const onDemandMetricIds: string[] = []
  const pinnedMetricIds: string[] = []
  for (const id of settings.order) {
    const rule = defaults[getBaseProviderId(id, settings)]
    const known = knownByProvider.get(id)
    if (!rule || !known) continue
    if (rule.hidden?.some((label) => known.has(label))) {
      const visible = [...known].filter((label) => !rule.hidden!.includes(label))
      trayLines[id] = visible.length ? visible : ["__NONE__"]
    }
    for (const label of rule.onDemand ?? []) {
      if (known.has(label)) onDemandMetricIds.push(metricId(id, label))
    }
    for (const label of rule.pins ?? []) {
      if (known.has(label)) pinnedMetricIds.push(metricId(id, label))
    }
  }
  return { trayLines, onDemandMetricIds, pinnedMetricIds }
}
