import { useMemo } from "react"
import { History, Sparkles } from "lucide-react"
import type { DisplayPluginState } from "@/hooks/app/use-app-plugin-views"
import { useHistoryReportDays } from "@/hooks/use-history-report-days"
import { useNowTicker } from "@/hooks/use-now-ticker"
import { buildHistoryReport, type HistoryTotal } from "@/lib/history-report"
import { formatMoney, getEffectiveIntlLocale } from "@/lib/locale-format"

const card = "rounded-xl bg-muted/60 text-card-foreground"

function historyMoney(value: number): string {
  return formatMoney(value, { compact: true })
}

function cost(total: HistoryTotal): string {
  if (total.cost == null) return "—"
  return historyMoney(total.cost) + (total.partial ? "+" : "")
}

function tokens(count: number): string {
  return new Intl.NumberFormat(getEffectiveIntlLocale(), {
    notation: "compact",
    maximumFractionDigits: 1,
  }).format(count) + " tokens"
}

function dayLabel(day: string): string {
  return new Intl.DateTimeFormat(getEffectiveIntlLocale(), {
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  }).format(new Date(day))
}

export function HistoryView({
  plugins, persistEnabled,
}: {
  plugins: DisplayPluginState[]
  persistEnabled: boolean
}) {
  const ids = useMemo(() => plugins.map(({ meta }) => meta.id), [plugins])
  const stamp = plugins.map(({ lastUpdatedAt }) => lastUpdatedAt ?? 0).join(",")
  const { rows, failed, loading } = useHistoryReportDays(JSON.stringify(ids), stamp, persistEnabled)
  const now = new Date(useNowTicker({ enabled: persistEnabled && rows.length > 0, intervalMs: 60_000 }))
  const localDay = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
  const report = useMemo(() => buildHistoryReport(rows, ids, new Date(localDay)), [rows, ids, localDay])
  const pluginsById = useMemo(() => new Map(plugins.map((plugin) => [plugin.meta.id, plugin])), [plugins])
  const peak = Math.max(...report.days.map((day) => day.tokens))
  const estimate = report.apiEstimate == null ? null : historyMoney(report.apiEstimate)
  const lifetimeCost = report.lifetime.cost == null ? null : historyMoney(report.lifetime.cost)

  if (!report.since) {
    return (
      <div className={card + " grid justify-items-center gap-1.5 px-3 py-6 text-center text-xs"}>
        <History aria-hidden="true" className="size-5 text-muted-foreground" />
        <p className="font-semibold" role="status">{loading ? "Loading Usage History…" : failed
          ? "Usage History Could Not Be Loaded" : "No Local Usage In The Last 30 Days"}</p>
        {!loading && !failed && (
          <p className="text-muted-foreground">{persistEnabled
            ? "Usage appears after your tools log activity while QuotaBar is running."
            : "Enable local usage history in Settings to record activity."}</p>
        )}
      </div>
    )
  }

  return (
    <div className="space-y-3.5 pb-2 text-xs">
      <section className={card + " space-y-1 p-3.5"}>
        <div className="flex items-baseline justify-between gap-2">
          <h2 className="text-sm font-semibold">Lifetime</h2>
          <span className="text-muted-foreground">Since {dayLabel(report.since)}</span>
        </div>
        <div className="flex items-baseline justify-between gap-2 tabular-nums">
          <strong className="text-xl">{cost(report.lifetime)}</strong>
          <span className="text-muted-foreground">{tokens(report.lifetime.tokens)}</span>
        </div>
      </section>
      {estimate !== null && estimate !== lifetimeCost && (
        <section className={card + " flex items-center gap-2 px-3 py-2.5"}>
          <Sparkles aria-hidden="true" className="size-3.5 text-muted-foreground" />
          <h2 className="flex-1 font-medium">At Public API Rates (Est.)</h2>
          <strong className="text-sm tabular-nums">{estimate}</strong>
        </section>
      )}
      <section aria-label="Period totals" className={card + " grid grid-cols-3"}>
        {([["Today", report.today], ["7 Days", report.last7], ["30 Days", report.last30]] as const).map(([label, total]) => (
          <div key={label} className="space-y-0.5 p-3 tabular-nums">
            <h2 className="font-medium text-muted-foreground">{label}</h2>
            <p className="text-sm font-semibold">{cost(total)}</p>
            <p className="text-muted-foreground">{tokens(total.tokens)}</p>
          </div>
        ))}
      </section>
      <section className={card + " space-y-1.5 p-3"}>
        <div className="flex justify-between gap-2">
          <h2 className="font-semibold">Daily Tokens</h2>
          <span className="text-muted-foreground">{dayLabel(report.days[0].key)} – {dayLabel(report.days[29].key)}</span>
        </div>
        <ul className="flex h-9 items-end gap-0.5" aria-label="30-day token trend">
          {report.days.map((day) => (
            <li key={day.key} className={"flex-1 rounded-full " + (day.tokens > 0 ? "bg-[#008bff]" : "bg-foreground/10")}
              style={{ height: day.tokens > 0 ? Math.max(3, 36 * day.tokens / peak) : 2 }}>
              <span className="sr-only">{dayLabel(day.key)}: {tokens(day.tokens)}</span>
            </li>
          ))}
        </ul>
      </section>
      {report.accounts.map((account) => {
        const plugin = pluginsById.get(account.id)
        const line = plugin?.data?.lines.find((item) => item.type === "text" && item.label === "Last 30 Days")
        const models = line?.type === "text" ? line.modelBreakdown : undefined
        return (
          <section key={account.id} className={card + " space-y-1.5 p-3 [content-visibility:auto] [contain-intrinsic-size:auto_64px]"}>
            <div className="flex items-baseline gap-2 tabular-nums">
              <h2 className="flex-1 truncate text-sm font-semibold">{plugin?.meta.name}</h2>
              <span className="text-muted-foreground">{tokens(account.tokens)}</span>
              <strong>{cost(account)}</strong>
            </div>
            {account.partial && <p className="text-muted-foreground">Some usage could not be priced completely.</p>}
            {!!models?.length && (
              <ul aria-label="Latest 30-day model breakdown" className="space-y-2 pt-1">
                {models.map((model) => (
                  <li key={model.model} className="grid grid-cols-[1fr_auto] gap-x-2 tabular-nums">
                    <span className="truncate font-semibold">{model.model}</span>
                    <span>{model.costUsd == null ? "—" : formatMoney(model.costUsd)}</span>
                    <span className="col-start-2 text-muted-foreground">{tokens(model.tokens)}</span>
                  </li>
                ))}
              </ul>
            )}
          </section>
        )
      })}
    </div>
  )
}
