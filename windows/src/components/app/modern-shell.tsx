import { useEffect, useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { useShallow } from "zustand/react/shallow"
import { LiquidGlassFilter } from "@/components/liquid-glass-filter"
import { OnboardingWizard } from "@/components/onboarding-wizard"
import { PanelFooter } from "@/components/panel-footer"
import { CustomizeView } from "@/components/modern/customize-view"
import { TotalSpendCard } from "@/components/modern/total-spend-card"
import {
  WidgetGroupedList,
  buildProviderWidgetGroups,
} from "@/components/modern/widget-grouped-list"
import { UsageInsightsBanner } from "@/components/usage-insights-banner"
import { AppContent, type AppContentActionProps } from "@/components/app/app-content"
import { Button } from "@/components/ui/button"
import type { DisplayPluginState } from "@/hooks/app/use-app-plugin-views"
import type { SettingsPluginState } from "@/hooks/app/use-settings-plugin-list"
import { useAppVersion } from "@/hooks/app/use-app-version"
import { useWeeklyRollup } from "@/hooks/use-weekly-rollup"
import { useHistoryInsights } from "@/hooks/use-history-insights"
import { usePersistUsageHistory } from "@/hooks/use-persist-usage-history"
import { useNowTicker } from "@/hooks/use-now-ticker"
import { buildMetricDescriptors, findMetricLine } from "@/lib/metric-registry"
import { parseMetricId } from "@/lib/metric-id"
import {
  pinnedIdsFromTrayLines,
  placedIdsFromPluginSettings,
  providerOrderFromPluginSettings,
  migrateModernPlacedToTrayLines,
} from "@/lib/modern-layout"
import { savePluginSettings } from "@/lib/settings"
import { resolveWidgetData } from "@/lib/widget-data"
import { buildUsageInsights } from "@/lib/usage-insights"
import { getProviderInstanceMeta } from "@/lib/settings"
import { cn } from "@/lib/utils"
import { useAppPluginStore } from "@/stores/app-plugin-store"
import { useAppPreferencesStore } from "@/stores/app-preferences-store"
import { useAppUiStore } from "@/stores/app-ui-store"
import { useModernLayoutStore } from "@/stores/modern-layout-store"
import type { UILayout } from "@/lib/settings"
import { useMotionPointer } from "@/hooks/app/use-motion-pointer"

type ModernScreen = "dashboard" | "customize" | "settings"

type ModernShellProps = {
  onRefreshAll: () => void
  displayPlugins: DisplayPluginState[]
  settingsPlugins: SettingsPluginState[]
  autoUpdateNextAt: number | null
  appContentProps: AppContentActionProps
  showOnboardingWizard: boolean
  onOnboardingComplete: (layout: UILayout) => void
  onOnboardingSkip: () => void
  preferWeeklyLimit: boolean
}

export function ModernShell({
  onRefreshAll,
  displayPlugins,
  settingsPlugins,
  autoUpdateNextAt,
  appContentProps,
  showOnboardingWizard,
  onOnboardingComplete,
  onOnboardingSkip,
  preferWeeklyLimit,
}: ModernShellProps) {
  const { t } = useTranslation()
  const [screen, setScreen] = useState<ModernScreen>("dashboard")
  const appVersion = useAppVersion()

  const { themeMode, displayMode, resetTimerDisplayMode, modernDensity, displayCurrency, exchangeRatesRevision, showTotalSpend, reduceAnimations } =
    useAppPreferencesStore(
    useShallow((s) => ({
      themeMode: s.themeMode,
      displayMode: s.displayMode,
      resetTimerDisplayMode: s.resetTimerDisplayMode,
      modernDensity: s.modernDensity,
      displayCurrency: s.displayCurrency,
      exchangeRatesRevision: s.exchangeRatesRevision,
      showTotalSpend: s.showTotalSpend,
      reduceAnimations: s.reduceAnimations,
    })),
  )

  const { showAbout, setShowAbout } = useAppUiStore(
    useShallow((s) => ({
      showAbout: s.showAbout,
      setShowAbout: s.setShowAbout,
    })),
  )

  const { pluginsMeta, pluginSettings } = useAppPluginStore(
    useShallow((s) => ({
      pluginsMeta: s.pluginsMeta,
      pluginSettings: s.pluginSettings,
    })),
  )

  const layout = useModernLayoutStore(
    useShallow((s) => ({
      metricOrderByProvider: s.metricOrderByProvider,
      pinnedMetricIds: s.pinnedMetricIds,
      hydrated: s.hydrated,
      ensureInitialized: s.ensureInitialized,
      setMetricOrder: s.setMetricOrder,
      setTrayFocusProvider: s.setTrayFocusProvider,
      syncDescriptors: s.syncDescriptors,
      syncPinsFromTrayLines: s.syncPinsFromTrayLines,
    })),
  )

  const compact = modernDensity === "compact"
  const nowMs = useNowTicker()
  const persistEnabled = usePersistUsageHistory()
  const { dailyRows, rollup, rollup30, scheduleReload: scheduleRollupReload } = useWeeklyRollup(persistEnabled)
  const { summary: historyInsights, scheduleReload: scheduleHistoryInsightsReload } =
    useHistoryInsights(persistEnabled)

  const probeStamp = displayPlugins.map((p) => p.lastUpdatedAt ?? 0).join(",")
  useEffect(() => {
    scheduleRollupReload()
    scheduleHistoryInsightsReload()
  }, [probeStamp, scheduleRollupReload, scheduleHistoryInsightsReload])

  const setActiveView = useAppUiStore((s) => s.setActiveView)

  useEffect(() => {
    if (!pluginSettings || !layout.hydrated) return
    const pluginStates = Object.fromEntries(
      displayPlugins.map((p) => [p.meta.id, { data: p.data }]),
    )
    const descriptors = buildMetricDescriptors(pluginsMeta, pluginSettings, pluginStates)
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
      state.ensureInitialized(
        descriptors,
        settings,
        pinnedIdsFromTrayLines(settings.trayLines),
      )
      return
    }
    state.syncDescriptors(descriptors)
    state.syncPinsFromTrayLines(settings.trayLines, descriptors)
  }, [pluginSettings, pluginsMeta, layout.hydrated, displayPlugins])

  const pluginStatesForDescriptors = useMemo(
    () =>
      Object.fromEntries(displayPlugins.map((p) => [p.meta.id, { data: p.data }])),
    [displayPlugins],
  )

  const descriptors = useMemo(
    () => buildMetricDescriptors(pluginsMeta, pluginSettings, pluginStatesForDescriptors),
    [pluginsMeta, pluginSettings, pluginStatesForDescriptors],
  )

  const placedMetricIds = useMemo(
    () => (pluginSettings ? placedIdsFromPluginSettings(pluginSettings, descriptors) : []),
    [pluginSettings, descriptors],
  )

  const providerOrder = useMemo(
    () => (pluginSettings ? providerOrderFromPluginSettings(pluginSettings, descriptors) : []),
    [pluginSettings, descriptors],
  )

  const widgetDataById = useMemo(() => {
    const map = new Map<string, import("@/lib/widget-data").WidgetData>()
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
  }, [descriptors, displayPlugins, displayMode, resetTimerDisplayMode, nowMs, pluginSettings, displayCurrency, exchangeRatesRevision])

  const groups = useMemo(
    () =>
      buildProviderWidgetGroups({
        placedMetricIds,
        providerOrder,
        metricOrderByProvider: layout.metricOrderByProvider,
        widgetDataById,
        getMeta: (id) => getProviderInstanceMeta(id, pluginSettings, pluginsMeta) ?? undefined,
      }),
    [
      placedMetricIds,
      providerOrder,
      layout.metricOrderByProvider,
      widgetDataById,
      pluginSettings,
      pluginsMeta,
    ],
  )

  const spendProviders = useMemo(
    () =>
      displayPlugins.map((p) => ({
        id: p.meta.id,
        displayName: p.meta.name,
        brandColor: p.meta.brandColor,
      })),
    [displayPlugins],
  )

  const spendOutputs = useMemo(() => {
    const map = new Map<string, import("@/lib/plugin-types").PluginOutput | null>()
    for (const p of displayPlugins) {
      map.set(p.meta.id, p.data)
    }
    return map
  }, [displayPlugins])

  const insights = useMemo(
    () =>
      buildUsageInsights({
        plugins: displayPlugins,
        pluginSettings,
        preferWeeklyLimit,
        nowMs,
      }),
    [displayPlugins, pluginSettings, preferWeeklyLimit, nowMs],
  )
  const panelMotionRef = useMotionPointer(!reduceAnimations)

  return (
    <div
      className="app-popover-shell w-full bg-transparent"
      data-density={modernDensity}
    >
      <LiquidGlassFilter active={themeMode === "glass"} />
      <div
        ref={panelMotionRef}
        className="app-panel-surface relative w-full overflow-hidden rounded-[18px] select-none flex flex-col min-h-[320px]"
        data-ui-layout="modern"
      >
        <nav
          className="flex gap-1 px-3 pt-2 pb-1 border-b border-border/50"
          aria-label="Modern navigation"
        >
          {(
            [
              ["dashboard", t("modern.dashboard")],
              ["customize", t("modern.customize")],
              ["settings", t("modern.settings")],
            ] as const
          ).map(([id, label]) => (
            <Button
              key={id}
              type="button"
              size="sm"
              variant={screen === id ? "default" : "ghost"}
              className={cn("relative flex-1 motion-tab")}
              data-active={screen === id}
              onClick={() => {
                if (id === "settings") setActiveView("settings")
                else setActiveView("home")
                setScreen(id)
              }}
            >
              {label}
            </Button>
          ))}
        </nav>

        <div className="relative flex min-h-0 flex-1 flex-col px-3 pt-2 pb-1.5">
          {showOnboardingWizard ? (
            <OnboardingWizard
              onComplete={onOnboardingComplete}
              onSkip={onOnboardingSkip}
            />
          ) : null}

          <div
            className={cn(
              "min-h-0 flex-1 overflow-y-auto scrollbar-none",
              compact ? "text-sm" : "text-base",
            )}
          >
            {screen === "dashboard" ? (
              <div key="dashboard" className="motion-view space-y-2 pb-2 motion-stagger">
                <UsageInsightsBanner
                  insights={insights}
                  historyTightest={historyInsights?.tightest}
                  rollup={rollup}
                  rollup30={rollup30}
                  dailyRows={dailyRows}
                  persistEnabled={persistEnabled}
                  nowMs={nowMs}
                  onSelectProvider={setActiveView}
                />
                {showTotalSpend ? (
                  <TotalSpendCard
                    providers={spendProviders}
                    outputs={spendOutputs}
                    compact={compact}
                  />
                ) : null}
                <WidgetGroupedList
                  groups={groups}
                  compact={compact}
                  onRefreshPlugin={(pluginId) => {
                    appContentProps.onRetryPlugin(pluginId)
                  }}
                  onFocusProvider={layout.setTrayFocusProvider}
                />
              </div>
            ) : null}

            {screen === "customize" ? (
              <div key="customize" className="motion-view">
              <CustomizeView
                descriptors={descriptors}
                providerOrder={providerOrder}
                metricOrderByProvider={layout.metricOrderByProvider}
                placedMetricIds={placedMetricIds}
                onTogglePlaced={(metricId, enabled) => {
                  const labels = descriptors
                    .filter((d) => d.pluginId === parseMetricId(metricId)?.pluginId)
                    .map((d) => d.lineLabel)
                  appContentProps.onDashboardMetricToggle(metricId, enabled, labels)
                }}
                onSetProviderMetricsEnabled={(pluginId, metricIds, enabled) => {
                  const labels = metricIds
                    .map((id) => parseMetricId(id)?.lineLabel)
                    .filter((l): l is string => Boolean(l))
                  appContentProps.onProviderDashboardMetrics(pluginId, labels, enabled)
                }}
                onProviderReorder={appContentProps.onReorder}
                onMetricReorder={layout.setMetricOrder}
                compact={compact}
              />
              </div>
            ) : null}

            {screen === "settings" ? (
              <div key="settings" className="motion-view">
              <AppContent
                {...appContentProps}
                displayPlugins={displayPlugins}
                settingsPlugins={settingsPlugins}
                selectedPlugin={null}
                viewOverride="settings"
              />
              </div>
            ) : null}
          </div>

          <PanelFooter
            version={appVersion}
            autoUpdateNextAt={autoUpdateNextAt}
            onRefreshAll={onRefreshAll}
            showAbout={showAbout}
            onShowAbout={() => setShowAbout(true)}
            onCloseAbout={() => setShowAbout(false)}
          />
        </div>
      </div>
    </div>
  )
}
