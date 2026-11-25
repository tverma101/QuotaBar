import type { ReactNode } from "react"
import { Flame } from "lucide-react"
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip"
import { RateLimitResetsValue } from "@/components/rate-limit-resets-popover"
import { UsageSparkline } from "@/components/usage-sparkline"
import type { WidgetData } from "@/lib/widget-data"
import type { DisplayMode } from "@/lib/settings"
import { displayMetricLabel } from "@/lib/metric-display"
import {
  meterFillFraction,
  meterSeverity,
  meterState,
  meterWarningText,
  paceTickFraction,
  type MeterSeverity,
} from "@/lib/meter-state"
import { formatMoney } from "@/lib/locale-format"
import { cn } from "@/lib/utils"
import { MotionNumber } from "@/components/motion-number"

const EXPIRY_DOT: Record<string, string> = {
  normal: "bg-meter-normal",
  warning: "bg-meter-warning",
  critical: "bg-meter-critical",
}

const SEVERITY_FILL: Record<MeterSeverity, string> = {
  normal: "bg-meter-normal",
  warning: "bg-meter-warning",
  critical: "bg-meter-critical",
}

const SEVERITY_TEXT: Record<MeterSeverity, string> = {
  normal: "text-meter-normal",
  warning: "text-meter-warning",
  critical: "text-meter-critical",
}

const SPEND_LABELS = new Set(["today", "yesterday", "last 30 days"])

type WidgetRowProps = {
  data: WidgetData
  compact?: boolean
  className?: string
  onRefreshPlugin?: (pluginId: string) => void
  /** Used/Left framing of the meter fill (Settings → Show Usage As). */
  displayMode?: DisplayMode
  nowMs?: number
  /** A text row directly under another text row pulls up so spend rows read as one cluster. */
  condensedTop?: boolean
}

function TextValue({ data, compact, onRefreshPlugin }: WidgetRowProps) {
  const isResets = data.label === "Rate Limit Resets"
  const showBreakdown =
    Boolean(data.modelBreakdown?.length) &&
    SPEND_LABELS.has(data.label.trim().toLowerCase())

  let valueNode: ReactNode = (
    <span
      className={cn(
        "tabular-nums truncate text-foreground",
        data.loading && "text-muted-foreground animate-pulse",
      )}
    >
      {data.textValue}
    </span>
  )

  if (isResets) {
    valueNode = (
      <RateLimitResetsValue
        countLabel={data.textValue ?? "0 available"}
        expiries={data.resetCreditExpiries ?? []}
        pluginId={data.pluginId}
        compact={compact}
        onClaimed={() => {
          if (data.pluginId) onRefreshPlugin?.(data.pluginId)
        }}
      />
    )
  } else if (showBreakdown && data.modelBreakdown) {
    const breakdown = data.modelBreakdown
    const priced = breakdown.filter((row) => row.costUsd != null && row.costUsd > 0)
    valueNode = (
      <Tooltip>
        <TooltipTrigger
          render={(props) => (
            <span
              {...props}
              className={cn(
                "tabular-nums truncate cursor-default rounded-[6px] px-[7px] py-[4px] -mx-[7px] -my-[4px] transition-colors hover:bg-control",
                props.className,
              )}
            >
              {data.textValue}
            </span>
          )}
        />
        <TooltipContent side="left" className="max-w-xs p-2">
          <p className="text-[10px] font-medium text-muted-foreground mb-1.5">By model</p>
          <ul className="space-y-1">
            {breakdown.map((row) => (
              <li key={row.model} className="flex justify-between gap-3 text-xs">
                <span className="truncate" title={row.model}>
                  {row.model}
                </span>
                <span className="shrink-0 tabular-nums">
                  {row.percent}%
                  {row.costUsd != null && row.costUsd > 0
                    ? ` · ${formatMoney(row.costUsd, { sourceCurrency: "USD" })}`
                    : ""}
                </span>
              </li>
            ))}
          </ul>
          {priced.length < breakdown.length ? (
            <p className="text-[10px] text-muted-foreground mt-1.5">
              Totals exclude unpriced models.
            </p>
          ) : null}
        </TooltipContent>
      </Tooltip>
    )
  }

  if (!data.statusDot || isResets) return valueNode

  const dot = (
    <span
      className={cn("inline-block h-1.5 w-1.5 shrink-0 rounded-full", EXPIRY_DOT[data.statusDot])}
      aria-hidden
    />
  )

  if (data.expiryTooltip) {
    return (
      <Tooltip>
        <TooltipTrigger
          render={(props) => (
            <span {...props} className={cn("flex items-center gap-1", props.className)}>
              {dot}
              {valueNode}
            </span>
          )}
        />
        <TooltipContent side="left" className="max-w-xs whitespace-pre-line text-xs">
          {data.expiryTooltip}
        </TooltipContent>
      </Tooltip>
    )
  }

  return (
    <span className="flex items-center gap-1">
      {dot}
      {valueNode}
    </span>
  )
}

function Meter({
  fraction,
  severity,
  tick,
  compact,
}: {
  fraction: number
  severity: MeterSeverity | null
  tick: number | null
  compact?: boolean
}) {
  return (
    <div
      className={cn("relative w-full overflow-hidden rounded-full bg-track", compact ? "h-[4px]" : "h-[5px]")}
      data-severity={severity ?? "none"}
    >
      {severity ? (
        <div
          className={cn("h-full rounded-full transition-[width] duration-300 ease-out", SEVERITY_FILL[severity])}
          style={{ width: `${Math.round(fraction * 1000) / 10}%` }}
        />
      ) : null}
      {tick != null ? (
        <span
          aria-hidden
          className="absolute inset-y-0 w-[2px] -translate-x-1/2 bg-surface"
          style={{ left: `${Math.round(tick * 1000) / 10}%` }}
        />
      ) : null}
    </div>
  )
}

export function WidgetRow({
  data,
  compact,
  className,
  onRefreshPlugin,
  displayMode = "left",
  nowMs = Date.now(),
  condensedTop,
}: WidgetRowProps) {
  const label = displayMetricLabel(data.label)
  const labelClass = cn("min-w-0 truncate font-semibold", compact ? "text-[12px]" : "text-[13px]")
  const supportClass = compact ? "text-[11px]" : "text-[12px]"

  if (data.kind === "barChart" && data.barChartPoints?.length) {
    return (
      <div className={cn("px-[14px]", compact ? "py-[4px]" : "py-[6px]", className)}>
        <UsageSparkline
          label={label}
          points={data.barChartPoints}
          note={data.barChartNote}
          variant="mac"
          compact={compact}
        />
      </div>
    )
  }

  if (data.bounded) {
    const state = meterState(data, nowMs)
    const severity = meterSeverity(state)
    const warning = meterWarningText(state)
    const tick = paceTickFraction(data, state, displayMode, nowMs)
    const hasReading = state.kind !== "noData"
    const trailing = hasReading
      ? (data.textSecondary ?? (data.format && data.format !== "percent" && data.limitText ? `${data.limitText} limit` : null))
      : "No data"
    const flame = state.kind === "spent" || state.kind === "runningOut"
    return (
      <div className={cn("px-[14px]", compact ? "py-[5px]" : "py-[10px]", className)} data-metric-row="bounded">
        <div className={cn("flex flex-col", compact ? "gap-[3px]" : "gap-[4px]")}>
          <div className="flex items-center gap-2">
            <span className={cn(labelClass, "flex-1")}>{label}</span>
            {warning || flame ? (
              <span className={cn("flex shrink-0 items-center gap-1 text-muted-foreground", supportClass)}>
                {flame && severity ? <Flame className={cn("size-3 fill-current", SEVERITY_TEXT[severity])} aria-hidden /> : null}
                {warning}
              </span>
            ) : null}
          </div>
          <Meter fraction={meterFillFraction(data, displayMode)} severity={severity} tick={tick} compact={compact} />
          <div className={cn("flex items-baseline justify-between gap-3 tabular-nums", supportClass)}>
            <span className="shrink-0 text-foreground">
              {hasReading && data.textValue ? <MotionNumber value={data.textValue} className="motion-number" /> : "—"}
            </span>
            {trailing ? <span className="min-w-0 truncate text-muted-foreground">{trailing}</span> : null}
          </div>
        </div>
      </div>
    )
  }

  const noData = data.loading || data.kind === "barChart"
  return (
    <div
      className={cn(
        "flex items-center justify-between gap-3 px-[14px]",
        condensedTop
          ? compact ? "pt-[1px] pb-[4px]" : "pt-[2px] pb-[6px]"
          : compact ? "py-[4px]" : "py-[6px]",
        className,
      )}
      data-metric-row="text"
    >
      <span className={labelClass}>{label}</span>
      <div className={cn("flex min-w-0 flex-col items-end gap-0.5", supportClass)}>
        {noData ? (
          <span className="font-semibold">No data</span>
        ) : (
          <TextValue data={data} compact={compact} onRefreshPlugin={onRefreshPlugin} />
        )}
        {!noData && data.textSecondary ? (
          <span className="truncate text-[11px] text-muted-foreground">{data.textSecondary}</span>
        ) : null}
      </div>
    </div>
  )
}
