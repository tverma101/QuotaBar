import { useCallback, useEffect, useRef, useState } from "react"
import { invoke, isTauri } from "@tauri-apps/api/core"
import type { HistoryInsightsSummary } from "@/lib/usage-history-insights"

export function useHistoryInsights(persistEnabled: boolean, visibleOnly = false) {
  const [summary, setSummary] = useState<HistoryInsightsSummary | null>(null)
  const debounceRef = useRef<number | null>(null)

  const reload = useCallback(async () => {
    if (visibleOnly && document.hidden) return
    if (!isTauri() || !persistEnabled) {
      setSummary(null)
      return
    }
    try {
      const data = await invoke<HistoryInsightsSummary>("get_usage_insights", { limit: 3 })
      setSummary(data)
    } catch (e) {
      console.error("get_usage_insights:", e)
      setSummary(null)
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

  return { summary, reload, scheduleReload, cancelReload }
}
