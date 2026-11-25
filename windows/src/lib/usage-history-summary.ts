import type { UsageDailyRow } from "@/lib/usage-daily"

/** Totals behind the Modern "Usage History" screen, built from the local daily usage rows. */
export type UsagePeriodTotal = { cost: number; tokens: number }

export type UsageHistorySummary = {
  lifetime: UsagePeriodTotal & { sinceDayKey: string | null }
  today: UsagePeriodTotal
  days7: UsagePeriodTotal
  days30: UsagePeriodTotal
  /** Last 30 days, oldest first, with empty days filled in. */
  daily: { dayKey: string; tokens: number }[]
  providers: (UsagePeriodTotal & { instanceId: string; displayName: string; today: UsagePeriodTotal })[]
}

function dayKey(date: Date): string {
  const y = date.getFullYear()
  const m = String(date.getMonth() + 1).padStart(2, "0")
  const d = String(date.getDate()).padStart(2, "0")
  return `${y}-${m}-${d}`
}

function daysBack(now: Date, days: number): string {
  return dayKey(new Date(now.getFullYear(), now.getMonth(), now.getDate() - days))
}

function add(total: UsagePeriodTotal, row: UsageDailyRow) {
  total.cost += row.costUsd ?? 0
  total.tokens += row.totalTokens ?? 0
}

const empty = (): UsagePeriodTotal => ({ cost: 0, tokens: 0 })

export function summarizeUsageHistory(rows: UsageDailyRow[], now: Date = new Date()): UsageHistorySummary {
  const todayKey = dayKey(now)
  const start7 = daysBack(now, 6)
  const start30 = daysBack(now, 29)
  const lifetime = { ...empty(), sinceDayKey: null as string | null }
  const today = empty()
  const days7 = empty()
  const days30 = empty()
  const tokensByDay = new Map<string, number>()
  const providers = new Map<string, UsageHistorySummary["providers"][number]>()

  for (const row of rows) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(row.dayKey) || row.dayKey > todayKey) continue
    add(lifetime, row)
    if (!lifetime.sinceDayKey || row.dayKey < lifetime.sinceDayKey) lifetime.sinceDayKey = row.dayKey
    if (row.dayKey === todayKey) add(today, row)
    if (row.dayKey >= start7) add(days7, row)
    if (row.dayKey >= start30) {
      add(days30, row)
      tokensByDay.set(row.dayKey, (tokensByDay.get(row.dayKey) ?? 0) + (row.totalTokens ?? 0))
    }
    let provider = providers.get(row.instanceId)
    if (!provider) {
      provider = { instanceId: row.instanceId, displayName: row.displayName, ...empty(), today: empty() }
      providers.set(row.instanceId, provider)
    }
    add(provider, row)
    if (row.dayKey === todayKey) add(provider.today, row)
  }

  const daily = Array.from({ length: 30 }, (_, i) => {
    const key = daysBack(now, 29 - i)
    return { dayKey: key, tokens: tokensByDay.get(key) ?? 0 }
  })

  return {
    lifetime,
    today,
    days7,
    days30,
    daily,
    providers: Array.from(providers.values()).sort(
      (a, b) => b.cost - a.cost || b.tokens - a.tokens || a.displayName.localeCompare(b.displayName),
    ),
  }
}

/** "35M", "23.3M", "940K" — the macOS compact token style. */
export function formatCompactTokens(tokens: number): string {
  const trim = (value: number) => value.toFixed(1).replace(/\.0$/, "")
  if (tokens >= 1_000_000_000) return `${trim(tokens / 1_000_000_000)}B`
  if (tokens >= 1_000_000) return `${trim(tokens / 1_000_000)}M`
  if (tokens >= 1_000) return `${trim(tokens / 1_000)}K`
  return String(Math.round(tokens))
}
