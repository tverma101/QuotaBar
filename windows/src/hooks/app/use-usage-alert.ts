import { useCallback, useEffect, useRef } from "react"
import { convertFileSrc } from "@tauri-apps/api/core"
import type { PluginOutput } from "@/lib/plugin-types"
import { calculatePaceStatus, stableResetKeyMs } from "@/lib/pace-status"
import { sendNotificationAsync } from "@/lib/notification"
import { resolvePrimaryProgressLine } from "@/lib/primary-progress-line"
import {
  createUsageAlertBatcher,
  type GroupedUsageAlert,
  type UsageAlertEvent,
} from "@/lib/usage-alert-group"
import { useAppPluginStore } from "@/stores/app-plugin-store"
import { useAppPreferencesStore } from "@/stores/app-preferences-store"

export function useUsageAlert() {
  const {
    usageAlertEnabled,
    usageAlertThreshold,
    customUsageAlertThreshold,
    usageAlertSound,
    usagePaceAlertEnabled,
    preferMenubarWeeklyLimit,
  } = useAppPreferencesStore()

  const { pluginsMeta, pluginSettings } = useAppPluginStore()

  const lowRemainingNotifiedRef = useRef<Record<string, boolean>>({})
  const paceNotifiedRef = useRef<Record<string, boolean>>({})

  const deliver = useCallback(
    (alert: GroupedUsageAlert) => {
      const iconFilePath =
        alert.providerIds.length === 1
          ? pluginsMeta.find((plugin) => plugin.id === alert.providerIds[0])?.iconFilePath
          : undefined

      void sendNotificationAsync({
        title: alert.title,
        subtitle: alert.subtitle,
        body: alert.body,
        sound: usageAlertSound,
        ...(iconFilePath
          ? { iconPath: iconFilePath, attachments: [{ id: "icon", url: convertFileSrc(iconFilePath) }] }
          : {}),
      }).catch((error) => {
        console.error("Failed to send usage alert notification:", error)
      })
    },
    [pluginsMeta, usageAlertSound],
  )

  const deliverRef = useRef(deliver)
  deliverRef.current = deliver
  const batcherRef = useRef<ReturnType<typeof createUsageAlertBatcher> | null>(null)
  if (batcherRef.current == null) {
    batcherRef.current = createUsageAlertBatcher((alert) => deliverRef.current(alert))
  }
  useEffect(() => () => batcherRef.current?.flush(), [])

  const sendAlert = useCallback((event: UsageAlertEvent) => {
    batcherRef.current?.add(event)
  }, [])

  const checkUsageAlert = useCallback(
    (output: PluginOutput) => {
      if (!usageAlertEnabled) return
      if (!pluginSettings) return

      const instanceId = output.providerId
      const meta = pluginsMeta.find((p) => p.id === instanceId)
      if (!meta) return

      const primary = resolvePrimaryProgressLine({
        meta,
        data: output,
        pluginSettings,
        instanceId,
        preferWeeklyLimit: preferMenubarWeeklyLimit,
      })

      if (!primary) return
      if (!Number.isFinite(primary.used) || !Number.isFinite(primary.limit)) return
      if (primary.limit <= 0) return

      const displayName = output.displayName
      const lineLabel = primary.label

      if (primary.format?.kind === "percent") {
        const usedPercent = (primary.used / primary.limit) * 100
        const remaining = 100 - usedPercent
        const effectiveThreshold =
          usageAlertThreshold === "custom" ? customUsageAlertThreshold : usageAlertThreshold

        if (effectiveThreshold != null) {
          if (remaining > effectiveThreshold) {
            lowRemainingNotifiedRef.current[instanceId] = false
          } else if (!lowRemainingNotifiedRef.current[instanceId]) {
            lowRemainingNotifiedRef.current[instanceId] = true
            sendAlert({
              key: `${instanceId}:${lineLabel}:lowRemaining`,
              kind: "lowRemaining",
              providerId: instanceId,
              providerName: displayName,
              metricLabel: lineLabel,
              body: `Under ${effectiveThreshold}% usage remaining for this window.`,
            })
          }
        }

        if (usagePaceAlertEnabled) {
          const resetsAtMs = primary.resetsAt ? Date.parse(primary.resetsAt) : NaN
          const periodDurationMs = primary.periodDurationMs
          const paceKey = `${instanceId}:${stableResetKeyMs(resetsAtMs)}:pace`

          if (
            Number.isFinite(resetsAtMs) &&
            periodDurationMs != null &&
            periodDurationMs > 0
          ) {
            const nowMs = Date.now()
            const pace = calculatePaceStatus(
              primary.used,
              primary.limit,
              resetsAtMs,
              periodDurationMs,
              nowMs,
            )
            if (pace?.status !== "behind") {
              paceNotifiedRef.current[paceKey] = false
            } else if (!paceNotifiedRef.current[paceKey]) {
              paceNotifiedRef.current[paceKey] = true
              sendAlert({
                key: paceKey,
                kind: "pace",
                providerId: instanceId,
                providerName: displayName,
                metricLabel: lineLabel,
                body: "Projected to finish before the limit resets.",
              })
            }
          }
        }
      }
    },
    [
      customUsageAlertThreshold,
      pluginSettings,
      pluginsMeta,
      preferMenubarWeeklyLimit,
      sendAlert,
      usageAlertEnabled,
      usageAlertThreshold,
      usagePaceAlertEnabled,
    ],
  )

  return { checkUsageAlert }
}
