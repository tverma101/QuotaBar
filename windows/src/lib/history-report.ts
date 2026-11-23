import type { UsageDailyRow } from "@/lib/usage-daily"
import { rollingWindowDays } from "@/lib/weekly-rollup"

export type HistoryTotal = {
  tokens: number
  cost: number | null
  partial: boolean
}

function total(rows: UsageDailyRow[]): HistoryTotal {
  let tokens = 0
  let cost: number | null = null
  let partial = false
  for (const row of rows) {
    const rowTokens = row.totalTokens ?? ((row.inputTokens ?? 0) + (row.outputTokens ?? 0))
    tokens += rowTokens
    if (row.costUsd != null) cost = (cost ?? 0) + row.costUsd
    else if (rowTokens > 0) partial = true
  }
  return { tokens, cost, partial }
}

export function buildHistoryReport(
  rows: UsageDailyRow[],
  accountIds: string[],
  now: Date,
) {
  const end = rollingWindowDays(1, now).current.endDay
  const dayKeys = Array.from({ length: 30 }, (_, index) =>
    rollingWindowDays(30 - index, now).current.startDay,
  )
  const accounts = new Set(accountIds)
  const eligible = rows.filter((row) =>
    accounts.has(row.instanceId) && row.dayKey <= end &&
    (row.totalTokens != null || row.inputTokens != null || row.outputTokens != null ||
      row.costUsd != null || row.apiEstimateUsd != null),
  )
  const recent = eligible.filter((row) => row.dayKey >= dayKeys[0])
  const byDay = new Map<string, UsageDailyRow[]>()
  const byAccount = new Map<string, UsageDailyRow[]>()
  let apiEstimate: number | null = null
  for (const row of eligible) {
    if (row.apiEstimateUsd != null) apiEstimate = (apiEstimate ?? 0) + row.apiEstimateUsd
  }
  for (const row of recent) {
    const dayRows = byDay.get(row.dayKey) ?? []
    dayRows.push(row)
    byDay.set(row.dayKey, dayRows)
    const accountRows = byAccount.get(row.instanceId) ?? []
    accountRows.push(row)
    byAccount.set(row.instanceId, accountRows)
  }

  return {
    since: eligible.reduce<string | null>(
      (earliest, row) => earliest === null || row.dayKey < earliest ? row.dayKey : earliest,
      null,
    ),
    lifetime: total(eligible),
    apiEstimate,
    today: total(byDay.get(end) ?? []),
    last7: total(recent.filter((row) => row.dayKey >= dayKeys[23])),
    last30: total(recent),
    days: dayKeys.map((key) => ({ key, ...total(byDay.get(key) ?? []) })),
    accounts: accountIds.flatMap((id) => {
      const accountRows = byAccount.get(id)
      return accountRows ? [{ id, ...total(accountRows) }] : []
    }),
  }
}
