import { useEffect, useState } from "react"
import { invoke, isTauri } from "@tauri-apps/api/core"
import type { UsageDailyRow } from "@/lib/usage-daily"

const emptyRows: UsageDailyRow[] = []
const pageSize = 500

async function loadAccountDays(instanceId: string, active: () => boolean) {
  const rows: UsageDailyRow[] = []
  let beforeDay: string | undefined
  while (active()) {
    const page = await invoke<UsageDailyRow[]>("list_usage_daily", { instanceId, limit: pageSize, beforeDay })
    rows.push(...page)
    if (page.length < pageSize) break
    beforeDay = page[page.length - 1].dayKey
  }
  return rows
}

export function useHistoryReportDays(accountKey: string, probeStamp: string, enabled: boolean) {
  const [result, setResult] = useState<{
    accountKey: string
    rows: UsageDailyRow[]
    failed: boolean
  } | null>(null)

  useEffect(() => {
    if (!enabled || !isTauri()) return
    let generation = 0
    const accountIds: string[] = JSON.parse(accountKey)
    const loadVisible = () => {
      const request = ++generation
      if (document.hidden) return
      const active = () => request === generation && !document.hidden
      void Promise.all(accountIds.map((instanceId) => loadAccountDays(instanceId, active))).then((rows) => {
        if (active()) setResult({ accountKey, rows: rows.flat(), failed: false })
      }).catch((error) => {
        console.error("list_usage_daily:", error)
        if (active()) setResult({ accountKey, rows: emptyRows, failed: true })
      })
    }
    loadVisible()
    document.addEventListener("visibilitychange", loadVisible)
    return () => {
      generation++
      document.removeEventListener("visibilitychange", loadVisible)
    }
  }, [accountKey, enabled, probeStamp])

  const matches = enabled && result?.accountKey === accountKey
  return {
    rows: matches ? result.rows : emptyRows,
    failed: matches && result.failed,
    loading: enabled && isTauri() && !matches,
  }
}
