import { useCallback, useEffect, useRef, useState } from "react"
import { invoke } from "@tauri-apps/api/core"
import { isTauri } from "@tauri-apps/api/core"
import type { UsageDailyRow } from "@/lib/usage-daily"
import {
  computeRollingRollup,
  type WeeklyRollupResult,
} from "@/lib/weekly-rollup"

export function useWeeklyRollup(persistEnabled: boolean, visibleOnly = false) {
  const [dailyRows, setDailyRows] = useState<UsageDailyRow[]>([])
  const [rollup, setRollup] = useState<WeeklyRollupResult | null>(null)
  const [rollup30, setRollup30] = useState<WeeklyRollupResult | null>(null)
  const debounceRef = useRef<number | null>(null)

  const reload = useCallback(async () => {
    if (visibleOnly && document.hidden) return
    if (!isTauri() || !persistEnabled) {
      setDailyRows([])
      setRollup(null)
      setRollup30(null)
      return
    }
    try {
      const rows = await invoke<UsageDailyRow[]>("list_usage_daily", { limit: 120 })
      setDailyRows(rows)
      setRollup(computeRollingRollup(rows, 7))
      setRollup30(computeRollingRollup(rows, 30))
    } catch (e) {
      console.error("list_usage_daily:", e)
      setDailyRows([])
      setRollup(null)
      setRollup30(null)
    }
  }, [persistEnabled, visibleOnly])

  const cancelReload = useCallback(() => {
    if (debounceRef.current === null) return
    window.clearTimeout(debounceRef.current)
    debounceRef.current = null
  }, [])

  const scheduleReload = useCallback(() => {
    cancelReload()
    debounceRef.current = window.setTimeout(() => {
      debounceRef.current = null
      void reload()
    }, 32_000)
  }, [cancelReload, reload])

  useEffect(() => {
    void reload()
    return cancelReload
  }, [cancelReload, reload])

  return { dailyRows, rollup, rollup30, reload, scheduleReload, cancelReload }
}
