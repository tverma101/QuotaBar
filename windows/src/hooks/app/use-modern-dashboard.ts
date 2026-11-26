import { useEffect, useMemo } from "react"
import { useShallow } from "zustand/react/shallow"
import type { DisplayPluginState } from "@/hooks/app/use-app-plugin-views"
import { buildProviderWidgetGroups } from "@/components/modern/widget-grouped-list"
import { buildMetricDescriptors, findMetricLine } from "@/lib/metric-registry"
import {
  migrateModernPlacedToTrayLines,
  pinnedIdsFromTrayLines,
  placedIdsFromPluginSettings,
  providerOrderFromPluginSettings,
} from "@/lib/modern-layout"
import { isMetricOnDemand } from "@/lib/metric-display"
import type { PluginOutput } from "@/lib/plugin-types"
import { getProviderInstanceMeta, savePluginSettings } from "@/lib/settings"
import { resolveWidgetData, type WidgetData } from "@/lib/widget-data"
import { useAppPluginStore } from "@/stores/app-plugin-store"
import { useAppPreferencesStore } from "@/stores/app-preferences-store"
import { useModernLayoutStore } from "@/stores/modern-layout-store"

/**
 * Everything the Modern dashboard and Customize derive from plugin settings,
 * probe results and the Modern layout store: metric descriptors, placement,
 * provider order and the grouped provider sections.
 */
export function useModernDashboard(displayPlugins: DisplayPluginState[], nowMs: number) {
  const { displayMode, resetTimerDisplayMode, displayCurrency, exchangeRatesRevision } = useAppPreferencesStore(
    useShallow((s) => ({
      displayMode: s.displayMode,
      resetTimerDisplayMode: s.resetTimerDisplayMode,
      displayCurrency: s.displayCurrency,
      exchangeRatesRevision: s.exchangeRatesRevision,
    })),
  )
  const { pluginsMeta, pluginSettings } = useAppPluginStore(
    useShallow((s) => ({ pluginsMeta: s.pluginsMeta, pluginSettings: s.pluginSettings })),
  )
  const layout = useModernLayoutStore(
    useShallow((s) => ({
      metricOrderByProvider: s.metricOrderByProvider,
      onDemandOverrides: s.onDemandOverrides,
      hydrated: s.hydrated,
    })),
  )

  const descriptors = useMemo(() => {
    const pluginStates = Object.fromEntries(displayPlugins.map((p) => [p.meta.id, { data: p.data }]))
    return buildMetricDescriptors(pluginsMeta, pluginSettings, pluginStates)
  }, [pluginsMeta, pluginSettings, displayPlugins])

  useEffect(() => {
    if (!pluginSettings || !layout.hydrated) return
    const state = useModernLayoutStore.getState()

    let settings = pluginSettings
    if (state.initialized && state.placedMetricIds.length > 0) {
      const migrated = migrateModernPlacedToTrayLines(pluginSettings, state.placedMetricIds)
      if (migrated !== pluginSettings) {
        settings = migrated
        useAppPluginStore.getState().setPluginSettings(migrated)
        void savePluginSettings(migrated).catch((e) => console.error("migrateModernPlacedToTrayLines:", e))
      }
    }

    if (!state.initialized) {
      state.ensureInitialized(descriptors, settings, pinnedIdsFromTrayLines(settings.trayLines))
      return
    }
    state.syncDescriptors(descriptors)
    state.syncPinsFromTrayLines(settings.trayLines, descriptors)
  }, [pluginSettings, layout.hydrated, descriptors])

  const placedMetricIds = useMemo(
    () => (pluginSettings ? placedIdsFromPluginSettings(pluginSettings, descriptors) : []),
    [pluginSettings, descriptors],
  )

  const providerOrder = useMemo(
    () => (pluginSettings ? providerOrderFromPluginSettings(pluginSettings, descriptors) : []),
    [pluginSettings, descriptors],
  )

  const widgetDataById = useMemo(() => {
    const map = new Map<string, WidgetData>()
    if (!pluginSettings) return map
    for (const d of descriptors) {
      const state = displayPlugins.find((p) => p.meta.id === d.pluginId)
      const line = findMetricLine(state?.data?.lines, d.lineLabel)
      const data = resolveWidgetData({
        metricId: d.id,
        displayName: d.displayName,
        line,
        displayMode,
        resetTimerDisplayMode,
        nowMs,
      })
      if (data) {
        data.pluginId = d.pluginId
        map.set(d.id, data)
      }
    }
    return map
    // displayCurrency / exchangeRatesRevision change the formatted money values.
  }, [descriptors, displayPlugins, displayMode, resetTimerDisplayMode, nowMs, pluginSettings, displayCurrency, exchangeRatesRevision])

  const groups = useMemo(() => {
    const bounded = new Map(descriptors.map((d) => [d.id, d.bounded]))
    const lineLabel = new Map(descriptors.map((d) => [d.id, d.lineLabel]))
    return buildProviderWidgetGroups({
      placedMetricIds,
      providerOrder,
      metricOrderByProvider: layout.metricOrderByProvider,
      widgetDataById,
      getMeta: (id) => getProviderInstanceMeta(id, pluginSettings, pluginsMeta) ?? undefined,
      getState: (id) => displayPlugins.find((p) => p.meta.id === id),
      isBounded: (id) => bounded.get(id) ?? false,
      isOnDemand: (id, baseProviderId, label) =>
        isMetricOnDemand(id, baseProviderId, lineLabel.get(id) ?? label, layout.onDemandOverrides),
    })
  }, [
    descriptors,
    placedMetricIds,
    providerOrder,
    layout.metricOrderByProvider,
    layout.onDemandOverrides,
    widgetDataById,
    pluginSettings,
    pluginsMeta,
    displayPlugins,
  ])

  const spendProviders = useMemo(
    () => displayPlugins.map((p) => ({ id: p.meta.id, displayName: p.meta.name, brandColor: p.meta.brandColor })),
    [displayPlugins],
  )

  const spendOutputs = useMemo(() => {
    const map = new Map<string, PluginOutput | null>()
    for (const p of displayPlugins) map.set(p.meta.id, p.data)
    return map
  }, [displayPlugins])

  return {
    descriptors,
    placedMetricIds,
    providerOrder,
    groups,
    spendProviders,
    spendOutputs,
    displayMode,
    pluginSettings,
    pluginsMeta,
  }
}
