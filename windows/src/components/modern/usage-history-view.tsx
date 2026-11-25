import { useMemo } from "react"
import { History } from "lucide-react"
import { GroupCard } from "@/components/modern/mac-ui"
import { formatMoney } from "@/lib/locale-format"
import type { UsageDailyRow } from "@/lib/usage-daily"
import { formatCompactTokens, summarizeUsageHistory, type UsagePeriodTotal } from "@/lib/usage-history-summary"
import { cn } from "@/lib/utils"

const money = (usd: number) => formatMoney(usd, { sourceCurrency: "USD" })
const MONTH_DAY = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" })
const MONTH_YEAR = new Intl.DateTimeFormat(undefined, { month: "short", year: "numeric" })

function parseDayKey(key: string): Date {
  const [y, m, d] = key.split("-").map(Number)
  return new Date(y, m - 1, d)
}

function Est({ className }: { className?: string }) {
  return <span className={cn("font-semibold text-muted-foreground", className)}>Est.</span>
}

function PeriodColumn({ title, total }: { title: string; total: UsagePeriodTotal }) {
  return (
    <div className="min-w-0 flex-1">
      <p className="truncate text-[12px] font-semibold">
        {title} <Est className="text-[11px]" />
      </p>
      <p className="truncate text-[15px] font-bold tabular-nums">{money(total.cost)}</p>
      <p className="truncate text-[11px] text-muted-foreground tabular-nums">{formatCompactTokens(total.tokens)} tokens</p>
    </div>
  )
}

function DailyTokensChart({ daily }: { daily: { dayKey: string; tokens: number }[] }) {
  const max = Math.max(1, ...daily.map((d) => d.tokens))
  const first = daily[0]
  const last = daily[daily.length - 1]
  return (
    <GroupCard className="px-[14px] py-[12px]">
      <div className="flex items-baseline justify-between gap-2">
        <p className="text-[13px] font-semibold">Daily Tokens</p>
        {first && last ? (
          <p className="text-[11px] text-muted-foreground">
            {MONTH_DAY.format(parseDayKey(first.dayKey))} – {MONTH_DAY.format(parseDayKey(last.dayKey))}
          </p>
        ) : null}
      </div>
      <div className="mt-2 flex h-[38px] items-end gap-[2px]" role="img" aria-label="Daily tokens for the last 30 days">
        {daily.map((day) => (
          <span
            key={day.dayKey}
            className={cn("flex-1", day.tokens > 0 ? "rounded-full bg-meter-normal" : "h-[2px] rounded-full bg-track")}
            style={day.tokens > 0 ? { height: `${Math.max(12, (day.tokens / max) * 100)}%` } : undefined}
          />
        ))}
      </div>
    </GroupCard>
  )
}

export function UsageHistoryView({
  rows,
  persistEnabled,
  nowMs,
  onOpenSettings,
}: {
  rows: UsageDailyRow[]
  persistEnabled: boolean
  nowMs: number
  onOpenSettings: () => void
}) {
  const summary = useMemo(() => summarizeUsageHistory(rows, new Date(nowMs)), [rows, nowMs])

  if (!persistEnabled || summary.lifetime.sinceDayKey == null) {
    return (
      <GroupCard className="flex flex-col items-center px-6 py-8 text-center">
        <History className="size-6 text-muted-foreground" strokeWidth={1.75} aria-hidden />
        <p className="mt-2 text-[14px] font-semibold">{persistEnabled ? "No Usage History Yet" : "Usage History Is Off"}</p>
        <p className="mt-1 text-[12px] leading-[1.35] text-muted-foreground">
          {persistEnabled
            ? "Spend and token totals appear here once providers report daily usage."
            : "Turn on usage history in Settings to keep daily spend and token totals on this PC."}
        </p>
        {!persistEnabled ? (
          <button
            type="button"
            onClick={onOpenSettings}
            className="mt-3 rounded-[7px] bg-control px-3 py-1 text-[12px] font-medium transition-colors hover:bg-control-hover"
          >
            Open Settings
          </button>
        ) : null}
      </GroupCard>
    )
  }

  return (
    <div className="flex flex-col gap-[14px]">
      <GroupCard className="flex items-end justify-between gap-3 px-[14px] py-[12px]">
        <div className="min-w-0">
          <p className="text-[14px] font-semibold">
            Lifetime <Est className="ml-1 text-[12px]" />
          </p>
          <p className="text-[24px] font-bold leading-tight tabular-nums">{money(summary.lifetime.cost)}</p>
        </div>
        <div className="shrink-0 text-right">
          <p className="text-[11px] text-muted-foreground">Since {MONTH_YEAR.format(parseDayKey(summary.lifetime.sinceDayKey))}</p>
          <p className="mt-1 text-[13px] text-foreground/80 tabular-nums">{formatCompactTokens(summary.lifetime.tokens)} tokens</p>
        </div>
      </GroupCard>

      <GroupCard className="flex gap-3 px-[14px] py-[12px]">
        <PeriodColumn title="Today" total={summary.today} />
        <PeriodColumn title="7 Days" total={summary.days7} />
        <PeriodColumn title="30 Days" total={summary.days30} />
      </GroupCard>

      <DailyTokensChart daily={summary.daily} />

      {summary.providers.map((provider) => (
        <GroupCard key={provider.instanceId} className="px-[14px] py-[12px]">
          <div className="flex items-baseline gap-2">
            <p className="min-w-0 flex-1 truncate text-[14px] font-semibold">{provider.displayName}</p>
            <p className="shrink-0 text-[12px] text-muted-foreground tabular-nums">{formatCompactTokens(provider.tokens)} tokens</p>
            <p className="shrink-0 text-[13px] font-bold tabular-nums">
              <Est className="mr-1 text-[11px]" />
              {money(provider.cost)}
            </p>
          </div>
          <div className="mt-2 flex items-start justify-between gap-2">
            <p className="text-[12px] font-semibold">Today</p>
            <div className="text-right tabular-nums">
              <p className="text-[13px]">{money(provider.today.cost)}</p>
              <p className="text-[11px] text-muted-foreground">{formatCompactTokens(provider.today.tokens)} tokens</p>
            </div>
          </div>
        </GroupCard>
      ))}

      <p className="px-2 text-[11px] text-muted-foreground">Estimated from local logs, not provider billing.</p>
    </div>
  )
}
