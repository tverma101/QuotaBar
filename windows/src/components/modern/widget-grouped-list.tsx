import { useState } from "react"
import { ChevronDown, Loader2, RotateCw, TriangleAlert } from "lucide-react"
import type { PluginMeta, PluginOutput } from "@/lib/plugin-types"
import type { DisplayMode } from "@/lib/settings"
import { metricIdPrefix, parseMetricId } from "@/lib/metric-id"
import { WidgetRow } from "@/components/modern/widget-row"
import { GroupCard, ProviderGlyph } from "@/components/modern/mac-ui"
import type { WidgetData } from "@/lib/widget-data"
import { placeholderWidgetData } from "@/lib/widget-data"
import { descriptorLabel } from "@/lib/metric-registry"
import { cn } from "@/lib/utils"

export type ProviderGroupStatus = "ready" | "loading" | "error"

export type ProviderWidgetGroup = {
  pluginId: string
  name: string
  instanceLabel?: string
  iconUrl?: string
  brandColor?: string
  plan?: string
  status: ProviderGroupStatus
  error?: string | null
  /** Rows above the fold. */
  metrics: WidgetData[]
  /** Rows behind the provider's caret. */
  onDemandMetrics: WidgetData[]
}

type ProviderRuntimeState = {
  data: PluginOutput | null
  loading: boolean
  error: string | null
}

type WidgetGroupedListProps = {
  groups: ProviderWidgetGroup[]
  compact?: boolean
  className?: string
  displayMode?: DisplayMode
  nowMs?: number
  onRefreshPlugin?: (pluginId: string) => void
  onFocusProvider?: (pluginId: string) => void
  onOpenCustomize?: () => void
}

export function WidgetGroupedList({
  groups,
  compact,
  className,
  displayMode,
  nowMs,
  onRefreshPlugin,
  onFocusProvider,
  onOpenCustomize,
}: WidgetGroupedListProps) {
  if (groups.length === 0) {
    return (
      <GroupCard className="px-4 py-6 text-center">
        <p className="text-[13px] font-semibold">No Metrics on the Dashboard</p>
        <p className="mt-1 text-[12px] text-muted-foreground">Turn on a provider or a metric in Customize.</p>
        {onOpenCustomize ? (
          <button
            type="button"
            onClick={onOpenCustomize}
            className="mt-3 rounded-[7px] bg-control px-3 py-1 text-[12px] font-medium transition-colors hover:bg-control-hover"
          >
            Open Customize
          </button>
        ) : null}
      </GroupCard>
    )
  }

  return (
    <div className={cn("flex flex-col motion-stagger", compact ? "gap-[8px]" : "gap-[14px]", className)}>
      {groups.map((group, index) => (
        <ProviderSection
          key={group.pluginId}
          group={group}
          compact={compact}
          displayMode={displayMode}
          nowMs={nowMs}
          onRefreshPlugin={onRefreshPlugin}
          onFocusProvider={onFocusProvider}
          index={index}
        />
      ))}
    </div>
  )
}

function MetricRows({
  metrics,
  compact,
  displayMode,
  nowMs,
  onRefreshPlugin,
  previousIsText = false,
}: {
  metrics: WidgetData[]
  compact?: boolean
  displayMode?: DisplayMode
  nowMs?: number
  onRefreshPlugin?: (pluginId: string) => void
  previousIsText?: boolean
}) {
  return metrics.map((m, i) => {
    const prev = i === 0 ? null : metrics[i - 1]
    const prevText = i === 0 ? previousIsText : !prev!.bounded && prev!.kind !== "barChart"
    const isText = !m.bounded && m.kind !== "barChart"
    return (
      <WidgetRow
        key={m.metricId}
        data={m}
        compact={compact}
        displayMode={displayMode}
        nowMs={nowMs}
        condensedTop={isText && prevText}
        onRefreshPlugin={onRefreshPlugin}
      />
    )
  })
}

function ProviderSection({
  group,
  compact,
  displayMode,
  nowMs,
  onRefreshPlugin,
  onFocusProvider,
  index = 0,
}: {
  group: ProviderWidgetGroup
  compact?: boolean
  displayMode?: DisplayMode
  nowMs?: number
  onRefreshPlugin?: (pluginId: string) => void
  onFocusProvider?: (pluginId: string) => void
  index?: number
}) {
  const [expanded, setExpanded] = useState(false)
  const last = group.metrics[group.metrics.length - 1]
  const lastIsText = Boolean(last && !last.bounded && last.kind !== "barChart")

  return (
    <section
      className="motion-card"
      style={{ ["--i" as string]: index }}
      aria-label={group.name}
      data-provider={group.pluginId}
    >
      <header
        className={cn("flex min-w-0 items-center gap-[6px] px-[10px]", compact ? "pb-[2px]" : "pb-[4px]")}
        onClick={onFocusProvider ? () => onFocusProvider(group.pluginId) : undefined}
      >
        <ProviderGlyph iconUrl={group.iconUrl} size={compact ? 14 : 16} className="text-foreground/85" />
        <h3 className={cn("shrink-0 font-semibold tracking-[-0.01em]", compact ? "text-[13px]" : "text-[14px]")}>
          {group.name}
        </h3>
        {group.plan ? (
          <span className={cn("min-w-0 truncate text-muted-foreground", compact ? "text-[10px]" : "text-[11px]")}>
            {group.plan}
          </span>
        ) : null}
        {group.instanceLabel ? (
          <span className="min-w-0 max-w-[120px] truncate rounded-full bg-control px-2 py-px text-[10px] font-medium text-muted-foreground">
            {group.instanceLabel}
          </span>
        ) : null}
        {group.status === "loading" ? (
          <Loader2 className="size-3 shrink-0 animate-spin text-muted-foreground" aria-label="Updating" />
        ) : null}
        {group.status === "error" ? (
          <>
            <TriangleAlert className="size-3.5 shrink-0 fill-meter-warning text-surface" aria-label="Error" />
            {onRefreshPlugin ? (
              <button
                type="button"
                onClick={(event) => {
                  event.stopPropagation()
                  onRefreshPlugin(group.pluginId)
                }}
                className="flex shrink-0 items-center gap-1 rounded-[6px] px-1 text-[11px] font-medium text-muted-foreground transition-colors hover:text-foreground"
              >
                <RotateCw className="size-3" aria-hidden />
                Refresh
              </button>
            ) : null}
          </>
        ) : null}
      </header>
      <GroupCard className={compact ? "py-[3px]" : "py-[5px]"}>
        {group.status === "error" && group.error ? (
          <p className={cn("px-[14px] text-muted-foreground", compact ? "py-[4px] text-[11px]" : "py-[6px] text-[12px]")} role="alert">
            {group.error}
          </p>
        ) : null}
        <MetricRows
          metrics={group.metrics}
          compact={compact}
          displayMode={displayMode}
          nowMs={nowMs}
          onRefreshPlugin={onRefreshPlugin}
        />
        {expanded ? (
          <MetricRows
            metrics={group.onDemandMetrics}
            compact={compact}
            displayMode={displayMode}
            nowMs={nowMs}
            onRefreshPlugin={onRefreshPlugin}
            previousIsText={lastIsText}
          />
        ) : null}
        {group.onDemandMetrics.length > 0 ? (
          <button
            type="button"
            aria-expanded={expanded}
            aria-label={expanded ? `Show fewer ${group.name} metrics` : `Show more ${group.name} metrics`}
            onClick={() => setExpanded((v) => !v)}
            className={cn(
              "flex w-full items-center justify-center text-muted-foreground outline-none transition-colors hover:text-foreground focus-visible:text-foreground",
              compact ? "h-[18px]" : "h-[22px]",
            )}
          >
            <ChevronDown className={cn("size-4 transition-transform duration-200", expanded && "rotate-180")} strokeWidth={2} />
          </button>
        ) : null}
      </GroupCard>
    </section>
  )
}

function badgeError(output: PluginOutput | null): string | null {
  const badge = output?.lines.find((line) => line.type === "badge" && line.label === "Error")
  return badge && badge.type === "badge" ? (badge.text ?? null) : null
}

export function buildProviderWidgetGroups(args: {
  placedMetricIds: string[]
  providerOrder: string[]
  metricOrderByProvider: Record<string, string[]>
  widgetDataById: Map<string, WidgetData>
  getMeta: (pluginId: string) => PluginMeta | undefined
  /** Probe state per provider; without it every placed metric shows (placeholder when missing). */
  getState?: (pluginId: string) => ProviderRuntimeState | undefined
  isOnDemand?: (metricId: string, baseProviderId: string, lineLabel: string) => boolean
  isBounded?: (metricId: string) => boolean
}): ProviderWidgetGroup[] {
  const {
    placedMetricIds,
    providerOrder,
    metricOrderByProvider,
    widgetDataById,
    getMeta,
    getState,
    isOnDemand,
    isBounded,
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
      const state = getState?.(pluginId)
      const error = state?.error ?? badgeError(state?.data ?? null)
      const hasData = Boolean(state?.data?.lines.length) && !error
      const status: ProviderGroupStatus = error ? "error" : state?.loading ? "loading" : "ready"
      const baseProviderId = meta.baseProviderId ?? meta.id
      const orderIds =
        metricOrderByProvider[pluginId] ??
        placedMetricIds.filter((id) => id.startsWith(metricIdPrefix(pluginId)))
      const metrics: WidgetData[] = []
      const onDemandMetrics: WidgetData[] = []
      for (const id of orderIds) {
        if (!placedSet.has(id)) continue
        const label = descriptorLabel(id)
        let data = widgetDataById.get(id)
        // Once a provider has answered, optional rows it did not report stay hidden (macOS).
        if (!data && hasData) continue
        data ??= placeholderWidgetData({
          metricId: id,
          label,
          displayName: meta.name,
          bounded: isBounded?.(id),
        })
        if (isOnDemand?.(id, baseProviderId, label)) onDemandMetrics.push(data)
        else metrics.push(data)
      }
      if (metrics.length === 0 && onDemandMetrics.length === 0) return null
      // A provider always keeps at least one row above the fold.
      if (metrics.length === 0) metrics.push(...onDemandMetrics.splice(0))
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
        plan: state?.data?.plan,
        status,
        error,
        metrics,
        onDemandMetrics,
      }
    })
    .filter((g): g is ProviderWidgetGroup => g !== null)
}
