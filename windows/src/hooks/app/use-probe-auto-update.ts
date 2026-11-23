import { useCallback, useEffect, useState } from "react"
import {
  getEnabledPluginIds,
  type AutoUpdateIntervalMinutes,
  type PluginSettings,
} from "@/lib/settings"

type UseProbeAutoUpdateArgs = {
  pluginSettings: PluginSettings | null
  autoUpdateInterval: AutoUpdateIntervalMinutes
  setLoadingForPlugins: (ids: string[]) => void
  setErrorForPlugins: (ids: string[], error: string) => void
  isPluginLoading: (id: string) => boolean
  startBatch: (pluginIds?: string[]) => Promise<string[] | undefined>
}

function nextLocalMidnight(now: number) {
  const next = new Date(now)
  next.setHours(24, 0, 0, 0)
  return next.getTime()
}

export function useProbeAutoUpdate({
  pluginSettings,
  autoUpdateInterval,
  setLoadingForPlugins,
  setErrorForPlugins,
  isPluginLoading,
  startBatch,
}: UseProbeAutoUpdateArgs) {
  const [autoUpdateNextAt, setAutoUpdateNextAt] = useState<number | null>(null)
  const [autoUpdateResetToken, setAutoUpdateResetToken] = useState(0)

  useEffect(() => {
    if (!pluginSettings) {
      setAutoUpdateNextAt(null)
      return
    }

    const enabledIds = getEnabledPluginIds(pluginSettings)
    if (enabledIds.length === 0) {
      setAutoUpdateNextAt(null)
      return
    }

    const intervalMs = autoUpdateInterval * 60_000
    let nextQuota = Date.now() + intervalMs
    let midnight = nextLocalMidnight(Date.now())
    let timer: ReturnType<typeof setTimeout>
    setAutoUpdateNextAt(nextQuota)

    const schedule = () => {
      clearTimeout(timer)
      timer = setTimeout(checkDeadlines, Math.max(0, Math.min(nextQuota, midnight) - Date.now()))
    }

    function checkDeadlines() {
      const now = Date.now()
      const quotaDue = now >= nextQuota
      const midnightDue = now >= midnight
      midnight = nextLocalMidnight(now)
      if (quotaDue) {
        nextQuota = now + intervalMs
        setAutoUpdateNextAt(nextQuota)
      }
      schedule()
      if (!quotaDue && !midnightDue) return

      const idleIds = enabledIds.filter((id) => !isPluginLoading(id))
      if (idleIds.length === 0) return

      setLoadingForPlugins(idleIds)
      startBatch(idleIds).catch((error) => {
        console.error("Failed to start auto-update batch:", error)
        setErrorForPlugins(idleIds, "Failed to start probe")
      })
    }

    schedule()
    window.addEventListener("focus", checkDeadlines)
    document.addEventListener("visibilitychange", checkDeadlines)
    return () => {
      clearTimeout(timer)
      window.removeEventListener("focus", checkDeadlines)
      document.removeEventListener("visibilitychange", checkDeadlines)
    }
  }, [
    autoUpdateInterval,
    autoUpdateResetToken,
    pluginSettings,
    isPluginLoading,
    setLoadingForPlugins,
    setErrorForPlugins,
    startBatch,
  ])

  const resetAutoUpdateSchedule = useCallback(() => {
    if (!pluginSettings) return
    const enabledIds = getEnabledPluginIds(pluginSettings)
    /* v8 ignore start */
    if (enabledIds.length === 0) {
      setAutoUpdateNextAt(null)
      return
    }
    /* v8 ignore stop */

    setAutoUpdateNextAt(Date.now() + autoUpdateInterval * 60_000)
    setAutoUpdateResetToken((value) => value + 1)
  }, [autoUpdateInterval, pluginSettings])

  return {
    autoUpdateNextAt,
    setAutoUpdateNextAt,
    resetAutoUpdateSchedule,
  }
}
