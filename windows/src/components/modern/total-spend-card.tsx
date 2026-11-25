import { useMemo, useState } from "react"
import { useShallow } from "zustand/react/shallow"
import { Check, ChevronDown, Info } from "lucide-react"
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip"
import type { PluginOutput } from "@/lib/plugin-types"
import { saveShowTotalSpend, saveTotalSpendMetric } from "@/lib/settings"
import {
  TOTAL_SPEND_METRIC_EMPTY,
  TOTAL_SPEND_METRIC_TITLE,
  TOTAL_SPEND_METRICS,
  TOTAL_SPEND_PERIOD_SHORT,
  TOTAL_SPEND_PERIODS,
  aggregateTotalSpend,
  formatTotalSpendCenter,
  formatTotalSpendLegend,
  metricFromStored,
  metricToStored,
  projectTotalSpend,
  spendCapableProviders,
  totalSpendColor,
  type TotalSpendMetric,
  type TotalSpendPeriod,
  type TotalSpendProjectedSlice,
  type TotalSpendProvider,
} from "@/lib/total-spend"
import { cn } from "@/lib/utils"
import { useAppPreferencesStore } from "@/stores/app-preferences-store"

const RING_SIZE = 104
const MIN_SLICE_SHARE = 0.025

/** Near-black / near-white brand colors (Cursor) follow the label color, like macOS. */
function adaptiveSliceColor(providerId: string, brandColor?: string): string {
  const color = totalSpendColor(providerId, brandColor)
  const hex = /^#([0-9a-f]{6})$/i.exec(color.trim())?.[1]
  if (!hex) return color
  const [r, g, b] = [0, 2, 4].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
  const luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
  return luminance < 0.12 || luminance > 0.92 ? "var(--foreground)" : color
}

type TotalSpendCardProps = {
  providers: TotalSpendProvider[]
  outputs: Map<string, PluginOutput | null | undefined> | Record<string, PluginOutput | null | undefined>
  compact?: boolean
  className?: string
}

export function TotalSpendCard({ providers, outputs, compact, className }: TotalSpendCardProps) {
  const { showTotalSpend, totalSpendMetric, setShowTotalSpend, setTotalSpendMetric } =
    useAppPreferencesStore(
      useShallow((s) => ({
        showTotalSpend: s.showTotalSpend,
        totalSpendMetric: s.totalSpendMetric,
        setShowTotalSpend: s.setShowTotalSpend,
        setTotalSpendMetric: s.setTotalSpendMetric,
      })),
    )

  const [period, setPeriod] = useState<TotalSpendPeriod>("Today")
  const [metricMenuOpen, setMetricMenuOpen] = useState(false)

  const metric = metricFromStored(totalSpendMetric)
  const capable = useMemo(
    () => spendCapableProviders(providers, outputs),
    [providers, outputs],
  )

  const total = useMemo(
    () => aggregateTotalSpend({ period, providers: capable, outputs }),
    [period, capable, outputs],
  )
  const projection = useMemo(() => projectTotalSpend(total, metric), [total, metric])

  if (!showTotalSpend || capable.length === 0) return null

  const setMetric = (next: TotalSpendMetric) => {
    const stored = metricToStored(next)
    setTotalSpendMetric(stored)
    void saveTotalSpendMetric(stored).catch((e) => console.error("saveTotalSpendMetric:", e))
    setMetricMenuOpen(false)
  }

  // Keep showTotalSpend setter available for settings; silence unused if only read here.
  void setShowTotalSpend

  const info = `Only includes ${capable.map((p) => p.displayName).join(", ")}.`

  return (
    <section className={cn("motion-card", compact ? "space-y-[2px]" : "space-y-[4px]", className)}>
      <header className="flex items-center gap-1.5 px-[8px]">
        <div className="relative">
          <button
            type="button"
            className={cn(
              "flex items-center gap-1 rounded-[6px] font-semibold tracking-[-0.01em] outline-none focus-visible:ring-2 focus-visible:ring-ring",
              compact ? "text-[15px]" : "text-[17px]",
            )}
            aria-label="Total Spend Metric"
            aria-expanded={metricMenuOpen}
            onClick={() => setMetricMenuOpen((o) => !o)}
          >
            {TOTAL_SPEND_METRIC_TITLE[metric]}
            <ChevronDown className="size-3.5 text-muted-foreground" strokeWidth={2.5} aria-hidden />
          </button>
          {metricMenuOpen ? (
            <div className="absolute left-0 top-full z-20 mt-1 min-w-[10rem] rounded-[10px] border border-hairline bg-popover p-[5px] shadow-[0_10px_30px_rgba(0,0,0,0.3)]">
              {TOTAL_SPEND_METRICS.map((option) => (
                <button
                  key={option}
                  type="button"
                  className="flex h-[28px] w-full items-center gap-2 rounded-[6px] px-2 text-left text-[13px] transition-colors hover:bg-switch-on hover:text-white"
                  onClick={() => setMetric(option)}
                >
                  <Check className={cn("size-3.5", option !== metric && "invisible")} aria-hidden />
                  {TOTAL_SPEND_METRIC_TITLE[option]}
                </button>
              ))}
            </div>
          ) : null}
        </div>
        <Tooltip>
          <TooltipTrigger
            render={(props) => (
              <span
                {...props}
                className="flex cursor-default text-muted-foreground"
                aria-label="Total Spend info"
              >
                <Info className="size-4" strokeWidth={1.75} />
              </span>
            )}
          />
          <TooltipContent side="top" className="max-w-[220px] text-xs">
            {info}
          </TooltipContent>
        </Tooltip>
      </header>

      <div className={cn("rounded-[12px] bg-surface px-[14px]", compact ? "py-[10px]" : "py-[12px]")}>
        <div className={cn("flex rounded-full bg-segment p-[3px]", compact ? "mb-2" : "mb-3")}>
          {TOTAL_SPEND_PERIODS.map((candidate) => {
            const selected = candidate === period
            return (
              <button
                key={candidate}
                type="button"
                aria-pressed={selected}
                className={cn(
                  "flex-1 rounded-full px-2 text-[13px] transition-colors",
                  compact ? "py-[3px]" : "py-[5px]",
                  selected
                    ? "bg-segment-selected font-semibold text-foreground shadow-[0_1px_3px_rgba(0,0,0,0.18)]"
                    : "font-medium text-muted-foreground hover:text-foreground",
                )}
                onClick={() => setPeriod(candidate)}
              >
                {TOTAL_SPEND_PERIOD_SHORT[candidate]}
              </button>
            )
          })}
        </div>

        {projection.slices.length === 0 ? (
          <p className="py-6 text-center text-[13px] text-muted-foreground">
            {TOTAL_SPEND_METRIC_EMPTY[metric]}
          </p>
        ) : (
          <TotalSpendRing projectionSlices={projection.slices} metric={metric} center={projection.centerValue} estimated={projection.isEstimated} />
        )}
      </div>
    </section>
  )
}

function TotalSpendRing({
  projectionSlices,
  metric,
  center,
  estimated,
}: {
  projectionSlices: TotalSpendProjectedSlice[]
  metric: TotalSpendMetric
  center: number
  estimated: boolean
}) {
  const totalDisplay = projectionSlices.reduce((s, row) => s + row.displayAmount, 0)
  const floored = projectionSlices.map((row) =>
    Math.max(row.displayAmount / Math.max(totalDisplay, 1e-9), MIN_SLICE_SHARE),
  )
  const sum = floored.reduce((a, b) => a + b, 0)
  let cursor = -0.25 // start at 12 o'clock
  const arcs = projectionSlices.map((slice, i) => {
    const width = floored[i]! / sum
    const start = cursor
    const end = cursor + width
    cursor = end
    return {
      id: slice.provider.id,
      color: adaptiveSliceColor(slice.provider.id, slice.provider.brandColor),
      start,
      end,
      slice,
    }
  })

  const centerLabel = formatTotalSpendCenter(center, metric)
  const centerTip =
    estimated && metric !== "tokens"
      ? `${formatTotalSpendLegend(center, metric)} · Estimated from local logs`
      : formatTotalSpendLegend(center, metric)

  return (
    <div className="flex items-center gap-4">
      <Tooltip>
        <TooltipTrigger
          render={(props) => (
            <div {...props} className="relative shrink-0" style={{ width: RING_SIZE, height: RING_SIZE }}>
              <svg width={RING_SIZE} height={RING_SIZE} viewBox={`0 0 ${RING_SIZE} ${RING_SIZE}`} aria-hidden>
                {arcs.map((arc) => (
                  <path
                    key={arc.id}
                    d={donutSectorPath(RING_SIZE / 2, RING_SIZE / 2, RING_SIZE / 2 - 2, RING_SIZE * 0.28, arc.start, arc.end)}
                    style={{ fill: arc.color }}
                  />
                ))}
              </svg>
              <div className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center px-2 text-center">
                <span className="text-[15px] font-bold tabular-nums leading-tight">
                  {centerLabel.primary}
                </span>
                <span className="text-[10px] font-medium text-muted-foreground">{centerLabel.unit}</span>
              </div>
            </div>
          )}
        />
        <TooltipContent side="top" className="text-xs">
          {centerTip}
        </TooltipContent>
      </Tooltip>

      <ul className="min-w-0 flex-1 space-y-[6px]">
        {projectionSlices.map((slice) => (
          <li key={slice.provider.id} className="flex items-center gap-2 text-[13px]">
            <span
              className="h-2 w-2 shrink-0 rounded-full"
              style={{ backgroundColor: adaptiveSliceColor(slice.provider.id, slice.provider.brandColor) }}
            />
            <span className="min-w-0 flex-1 truncate">{slice.provider.displayName}</span>
            <span className="shrink-0 font-medium tabular-nums text-foreground/85">
              {formatTotalSpendLegend(slice.displayAmount, metric)}
            </span>
          </li>
        ))}
      </ul>
    </div>
  )
}

/** Donut sector from fraction start→end (0..1, -0.25 = 12 o'clock). */
function donutSectorPath(
  cx: number,
  cy: number,
  outerR: number,
  innerR: number,
  startFrac: number,
  endFrac: number,
): string {
  const gap = 0.004
  const start = (startFrac + gap) * Math.PI * 2
  const end = (endFrac - gap) * Math.PI * 2
  if (end <= start) return ""
  const large = end - start > Math.PI ? 1 : 0
  const ox1 = cx + outerR * Math.cos(start)
  const oy1 = cy + outerR * Math.sin(start)
  const ox2 = cx + outerR * Math.cos(end)
  const oy2 = cy + outerR * Math.sin(end)
  const ix1 = cx + innerR * Math.cos(end)
  const iy1 = cy + innerR * Math.sin(end)
  const ix2 = cx + innerR * Math.cos(start)
  const iy2 = cy + innerR * Math.sin(start)
  return [
    `M ${ox1} ${oy1}`,
    `A ${outerR} ${outerR} 0 ${large} 1 ${ox2} ${oy2}`,
    `L ${ix1} ${iy1}`,
    `A ${innerR} ${innerR} 0 ${large} 0 ${ix2} ${iy2}`,
    "Z",
  ].join(" ")
}

/** Settings / Customize toggle helper — persists showTotalSpend. */
export function useTotalSpendVisibilityToggle() {
  const showTotalSpend = useAppPreferencesStore((s) => s.showTotalSpend)
  const setShowTotalSpend = useAppPreferencesStore((s) => s.setShowTotalSpend)
  return {
    showTotalSpend,
    setShowTotalSpend: (checked: boolean) => {
      setShowTotalSpend(checked)
      void saveShowTotalSpend(checked).catch((e) => console.error("saveShowTotalSpend:", e))
    },
  }
}
