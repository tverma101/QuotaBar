import type { PluginMeta } from "@/lib/plugin-types"
import { metricIdPrefix, parseMetricId } from "@/lib/metric-id"
import { WidgetRow } from "@/components/modern/widget-row"
import type { WidgetData } from "@/lib/widget-data"
import { placeholderWidgetData } from "@/lib/widget-data"
import { descriptorLabel } from "@/lib/metric-registry"
import { cn } from "@/lib/utils"

export type ProviderWidgetGroup = {
  pluginId: string
  name: string
  instanceLabel?: string
  iconUrl?: string
  brandColor?: string
  metrics: WidgetData[]
}

type WidgetGroupedListProps = {
  groups: ProviderWidgetGroup[]
  compact?: boolean
  className?: string
  onRefreshPlugin?: (pluginId: string) => void
  onFocusProvider?: (pluginId: string) => void
}

export function WidgetGroupedList({ groups, compact, className, onRefreshPlugin, onFocusProvider }: WidgetGroupedListProps) {
  if (groups.length === 0) {
    return (
      <div className="text-center text-muted-foreground py-8 text-sm">
        No metrics on dashboard — open Customize to add some.
      </div>
    )
  }

  return (
    <div className={cn("space-y-2 motion-stagger", className)}>
      {groups.map((group, index) => (
        <ProviderCard
          key={group.pluginId}
          group={group}
          compact={compact}
          onRefreshPlugin={onRefreshPlugin}
          onFocusProvider={onFocusProvider}
          index={index}
        />
      ))}
    </div>
  )
}

function ProviderCard({
  group,
  compact,
  onRefreshPlugin,
  onFocusProvider,
  index = 0,
}: {
  group: ProviderWidgetGroup
  compact?: boolean
  onRefreshPlugin?: (pluginId: string) => void
  onFocusProvider?: (pluginId: string) => void
  index?: number
}) {
  const bounded = group.metrics.filter((m) => m.bounded && m.kind === "progress")
  const charts = group.metrics.filter((m) => m.kind === "barChart")
  const unbounded = group.metrics.filter((m) => !m.bounded && m.kind !== "barChart")

  return (
    <section
      className="rounded-xl border bg-card/85 overflow-hidden motion-card shadow-xs"
      style={{
        ["--i" as string]: index,
        ...(group.brandColor ? { borderColor: `${group.brandColor}33` } : {}),
      }}
    >
      <header
        className={cn(
          "flex items-center gap-2 px-3 border-b border-border/50 bg-muted/20",
          compact ? "py-1.5" : "py-2",
          onFocusProvider ? "cursor-pointer hover:bg-muted/40 transition-colors" : "",
        )}
        onClick={onFocusProvider ? () => onFocusProvider(group.pluginId) : undefined}
      >
        {group.iconUrl ? (
          <img src={group.iconUrl} alt="" className="h-4 w-4 shrink-0 rounded-xs" />
        ) : (
          <span
            className="h-4 w-4 rounded-xs shrink-0 bg-muted"
            style={group.brandColor ? { backgroundColor: group.brandColor } : undefined}
          />
        )}
        <div className="flex items-center gap-1.5 flex-1 min-w-0">
          <h3 className={cn("font-semibold truncate motion-title", compact ? "text-sm" : "text-base")}>
            {group.name}
          </h3>
          {group.instanceLabel ? (
            <span className="text-[11px] font-medium px-2 py-0.5 rounded-full bg-muted text-muted-foreground border border-border/60 shrink-0 truncate max-w-[180px]">
              {group.instanceLabel}
            </span>
          ) : null}
        </div>
      </header>
      <div className={cn("px-3", compact ? "py-1" : "py-2")}>
        {bounded.map((m) => (
          <WidgetRow key={m.metricId} data={m} compact={compact} onRefreshPlugin={onRefreshPlugin} />
        ))}
        {charts.map((m) => (
          <WidgetRow key={m.metricId} data={m} compact={compact} onRefreshPlugin={onRefreshPlugin} />
        ))}
        {unbounded.length > 0 ? (
          <div
            className={cn(
              bounded.length > 0 || charts.length > 0
                ? "mt-1.5 pt-1.5 border-t border-border/50"
                : "",
              "space-y-0",
            )}
          >
            {unbounded.map((m) => (
              <WidgetRow
                key={m.metricId}
                data={m}
                compact={compact}
                onRefreshPlugin={onRefreshPlugin}
              />
            ))}
          </div>
        ) : null}
      </div>
    </section>
  )
}

export function buildProviderWidgetGroups(args: {
  placedMetricIds: string[]
  providerOrder: string[]
  metricOrderByProvider: Record<string, string[]>
  widgetDataById: Map<string, WidgetData>
  getMeta: (pluginId: string) => PluginMeta | undefined
}): ProviderWidgetGroup[] {
  const {
    placedMetricIds,
    providerOrder,
    metricOrderByProvider,
    widgetDataById,
    getMeta,
  } = args

  const placedSet = new Set(placedMetricIds)
  const providersWithMetrics = new Set<string>()
  for (const id of placedMetricIds) {
    const pluginId = parseMetricId(id)?.pluginId
    if (pluginId) providersWithMetrics.add(pluginId)
  }

  const order =
    providerOrder.length > 0
      ? providerOrder.filter((p) => providersWithMetrics.has(p))
      : Array.from(providersWithMetrics)

  for (const p of providersWithMetrics) {
    if (!order.includes(p)) order.push(p)
  }

  return order
    .map((pluginId): ProviderWidgetGroup | null => {
      const meta = getMeta(pluginId)
      if (!meta) return null
      const orderIds =
        metricOrderByProvider[pluginId] ??
        placedMetricIds.filter((id) => id.startsWith(metricIdPrefix(pluginId)))
      const metrics: WidgetData[] = []
      for (const id of orderIds) {
        if (!placedSet.has(id)) continue
        const data =
          widgetDataById.get(id) ??
          placeholderWidgetData({
            metricId: id,
            label: descriptorLabel(id),
            displayName: meta.name,
          })
        metrics.push(data)
      }
      if (metrics.length === 0) return null
      let name = meta.name
      if (meta.instanceLabel && name.endsWith(` (${meta.instanceLabel})`)) {
        name = name.slice(0, -(meta.instanceLabel.length + 3))
      }
      return {
        pluginId,
        name,
        instanceLabel: meta.instanceLabel,
        iconUrl: meta.iconUrl,
        brandColor: meta.brandColor,
        metrics,
      }
    })
    .filter((g): g is ProviderWidgetGroup => g !== null)
}
