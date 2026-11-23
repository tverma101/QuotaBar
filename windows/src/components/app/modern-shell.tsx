import { lazy, Suspense, useEffect, useMemo, useRef, useState } from "react"
import { invoke, isTauri } from "@tauri-apps/api/core"
import { ChevronLeft } from "lucide-react"
import { ResetCustomizationButton } from "@/components/modern/reset-customization-button"
import { useShallow } from "zustand/react/shallow"
import { LiquidGlassFilter } from "@/components/liquid-glass-filter"
import { OnboardingWizard } from "@/components/onboarding-wizard"
import { PanelFooter } from "@/components/panel-footer"
import { CustomizeView } from "@/components/modern/customize-view"
import { PanelOptions } from "@/components/modern/panel-options"
import { TotalSpendCard } from "@/components/modern/total-spend-card"
import {
  WidgetGroupedList,
  buildProviderWidgetGroups,
} from "@/components/modern/widget-grouped-list"
import { UsageInsightsBanner } from "@/components/usage-insights-banner"
import { AppContent, type AppContentActionProps } from "@/components/app/app-content"
import type { DisplayPluginState } from "@/hooks/app/use-app-plugin-views"
import type { SettingsPluginState } from "@/hooks/app/use-settings-plugin-list"
import { useAppVersion } from "@/hooks/app/use-app-version"
import { usePanel } from "@/hooks/app/use-panel"
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
import { getProviderInstanceMeta, savePluginSettings } from "@/lib/settings"
import { resolveWidgetData } from "@/lib/widget-data"
import { buildUsageInsights } from "@/lib/usage-insights"
import { cn } from "@/lib/utils"
import { useAppPluginStore } from "@/stores/app-plugin-store"
import { useAppPreferencesStore } from "@/stores/app-preferences-store"
import { useAppUiStore } from "@/stores/app-ui-store"
import { flushModernLayout, useModernLayoutStore } from "@/stores/modern-layout-store"
import type { UILayout } from "@/lib/settings"
import { useMotionPointer } from "@/hooks/app/use-motion-pointer"

const screenTitles = {
  customize: "Customize",
  history: "Usage History",
  settings: "Settings",
}

const HistoryView = lazy(() => import("@/pages/history").then(({ HistoryView }) => ({
  default: HistoryView,
})))

function quitApp() {
  if (isTauri()) void flushModernLayout().then(() => invoke("quit_app")).catch(console.error)
}

type ModernShellProps = {
  onRefreshAll: () => void
  onResetCustomization: () => void
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
  onResetCustomization,
  displayPlugins,
  settingsPlugins,
  autoUpdateNextAt,
  appContentProps,
  showOnboardingWizard,
  onOnboardingComplete,
  onOnboardingSkip,
  preferWeeklyLimit,
}: ModernShellProps) {
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

  const { activeView, setActiveView, showAbout, setShowAbout } = useAppUiStore(
    useShallow((s) => ({
      activeView: s.activeView,
      setActiveView: s.setActiveView,
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
      onDemandMetricIds: s.onDemandMetricIds,
      hydrated: s.hydrated,
      setTrayFocusProvider: s.setTrayFocusProvider,
    })),
  )

  const compact = modernDensity === "compact"
  const screen = activeView === "settings" || activeView === "customize" || activeView === "history"
    ? activeView : "dashboard"
  const isDashboard = screen === "dashboard"
  const nowMs = useNowTicker({ enabled: isDashboard })
  const persistEnabled = usePersistUsageHistory(screen)
  const { dailyRows, rollup, rollup30, scheduleReload: scheduleRollupReload, cancelReload: cancelRollupReload } =
    useWeeklyRollup(isDashboard && persistEnabled, true)
  const { summary: historyInsights, scheduleReload: scheduleHistoryInsightsReload, cancelReload: cancelInsightsReload } =
    useHistoryInsights(isDashboard && persistEnabled, true)

  const probeStamp = displayPlugins.map((p) => p.lastUpdatedAt ?? 0).join(",")
  useEffect(() => {
    if (!isDashboard || !persistEnabled) return
    const cancel = () => {
      cancelRollupReload()
      cancelInsightsReload()
    }
    const scheduleVisibleReload = () => {
      if (document.hidden) {
        cancel()
        return
      }
      scheduleRollupReload()
      scheduleHistoryInsightsReload()
    }
    scheduleVisibleReload()
    document.addEventListener("visibilitychange", scheduleVisibleReload)
    return () => {
      document.removeEventListener("visibilitychange", scheduleVisibleReload)
      cancel()
    }
  }, [isDashboard, persistEnabled, probeStamp, scheduleRollupReload, scheduleHistoryInsightsReload, cancelRollupReload, cancelInsightsReload])

  const [providerId, setProviderId] = useState<string | null>(null)
  const undoStack = useRef<(() => void)[]>([])
  const migratingPlacement = useRef(false)
  const actions = useRef(appContentProps)
  actions.current = appContentProps
  const { containerRef, scrollRef, maxPanelHeightPx } = usePanel({
    activeView, setActiveView, showAbout, setShowAbout, displayPlugins,
    narrowWindowsPanel: !isDashboard,
  })

  useEffect(() => {
    scrollRef.current?.scrollTo?.(0, 0)
    containerRef.current?.focus({ preventScroll: true })
  }, [containerRef, providerId, screen, scrollRef])

  useEffect(() => {
    if (screen !== "customize") setProviderId(null)
  }, [screen])

  const goBack = () => {
    if (screen === "customize" && providerId) setProviderId(null)
    else setActiveView("home")
  }

  const pluginStatesForDescriptors = useMemo(
    () =>
      Object.fromEntries(displayPlugins.map((p) => [p.meta.id, { data: p.data }])),
    [displayPlugins],
  )

  const descriptors = useMemo(
    () => buildMetricDescriptors(pluginsMeta, pluginSettings, pluginStatesForDescriptors, true),
    [pluginsMeta, pluginSettings, pluginStatesForDescriptors],
  )

  useEffect(() => {
    if (!pluginSettings || !layout.hydrated) return
    const state = useModernLayoutStore.getState()

    let settings = pluginSettings
    if (state.initialized && state.placedMetricIds.length > 0 && !migratingPlacement.current) {
      const migrated = migrateModernPlacedToTrayLines(pluginSettings, state.placedMetricIds)
      if (migrated !== pluginSettings) {
        settings = migrated
        migratingPlacement.current = true
        useAppPluginStore.getState().setPluginSettings(migrated)
        void savePluginSettings(migrated).then(() => state.clearLegacyPlacement())
          .catch((e) => console.error("migrateModernPlacedToTrayLines:", e))
          .finally(() => { migratingPlacement.current = false })
      } else {
        state.clearLegacyPlacement()
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
  }, [pluginSettings, descriptors, layout.hydrated])

  const placedMetricIds = useMemo(
    () => (pluginSettings ? placedIdsFromPluginSettings(pluginSettings, descriptors) : []),
    [pluginSettings, descriptors],
  )

  const providerOrder = useMemo(
    () => (pluginSettings ? providerOrderFromPluginSettings(pluginSettings, descriptors) : []),
    [pluginSettings, descriptors],
  )

  const editingProvider = screen === "customize" ? settingsPlugins.find((p) => p.id === providerId) : null

  const widgetDataById = useMemo(() => {
    const map = new Map<string, import("@/lib/widget-data").WidgetData>()
    if (!pluginSettings || !isDashboard) return map
    for (const d of descriptors) {
      const state = pluginStatesForDescriptors[d.pluginId]
      if (!state) continue
      const line = findMetricLine(state.data?.lines, d.lineLabel)
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
  }, [descriptors, pluginStatesForDescriptors, displayMode, resetTimerDisplayMode, nowMs, pluginSettings, displayCurrency, exchangeRatesRevision, isDashboard])

  const groups = useMemo(
    () => isDashboard
      ? buildProviderWidgetGroups({
        placedMetricIds,
        providerOrder,
        metricOrderByProvider: layout.metricOrderByProvider,
        widgetDataById,
        getMeta: (id) => getProviderInstanceMeta(id, pluginSettings, pluginsMeta) ?? undefined,
      }) : [],
    [
      placedMetricIds,
      providerOrder,
      layout.metricOrderByProvider,
      widgetDataById,
      pluginSettings,
      pluginsMeta,
      isDashboard,
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
    () => isDashboard
      ? buildUsageInsights({
        plugins: displayPlugins,
        pluginSettings,
        preferWeeklyLimit,
        nowMs,
      }) : null,
    [displayPlugins, pluginSettings, preferWeeklyLimit, nowMs, isDashboard],
  )
  const panelMotionRef = useMotionPointer(!reduceAnimations)

  return (
    <div
      ref={containerRef}
      tabIndex={-1}
      className="app-popover-shell w-full bg-transparent"
      data-density={modernDensity}
      onKeyDown={(event) => {
        if (event.defaultPrevented || event.repeat || showAbout || event.altKey || event.shiftKey) return
        const target = event.target
        if (target instanceof HTMLElement &&
            (target.isContentEditable || target.closest("input, textarea, select, [role='textbox'], [role='menu'], [role='dialog']"))) return
        const command = event.ctrlKey || event.metaKey
        if (command && event.key === ",") setActiveView(screen === "settings" ? "home" : "settings")
        else if (command && event.key.toLowerCase() === "r" && screen === "dashboard") onRefreshAll()
        else if (command && event.key.toLowerCase() === "q") quitApp()
        else if (command && event.key.toLowerCase() === "z" && screen === "customize" && undoStack.current.length) undoStack.current.pop()?.()
        else if (!command && event.key === "Escape" && screen !== "dashboard") goBack()
        else if (!command && event.key === "Enter" && screen === "dashboard" &&
          !(target instanceof HTMLElement && target.closest("button, a, [role='button']"))) setActiveView("customize")
        else return
        event.preventDefault()
      }}
    >
      <LiquidGlassFilter active={themeMode === "glass"} />
      <div
        ref={panelMotionRef}
        className={cn("app-panel-surface relative w-full overflow-hidden rounded-[18px] select-none flex flex-col",
          isDashboard ? "min-h-[320px]" : "min-h-[250px]")}
        data-ui-layout="modern"
        style={maxPanelHeightPx ? { maxHeight: `min(100dvh, ${maxPanelHeightPx}px)` } : { maxHeight: "100dvh" }}
      >
        {screen !== "dashboard" && (
          <header className="relative mx-3 mt-2 flex h-7 shrink-0 items-center">
            <button type="button" aria-label="Back" onClick={goBack}
              className="grid size-6 place-items-center rounded-full text-muted-foreground hover:bg-muted hover:text-foreground">
              <ChevronLeft className="size-4" aria-hidden="true" />
            </button>
            <h1 className="pointer-events-none absolute inset-x-8 truncate text-center text-[13px] font-semibold">
              {editingProvider?.name ?? screenTitles[screen]}
            </h1>
            {screen === "customize" && !editingProvider && (
              <ResetCustomizationButton onReset={() => {
                undoStack.current = []
                onResetCustomization()
              }} />
            )}
          </header>
        )}

        <div className="relative flex min-h-0 flex-1 flex-col px-3 pt-2 pb-1.5">
          {showOnboardingWizard ? (
            <OnboardingWizard
              onComplete={onOnboardingComplete}
              onSkip={onOnboardingSkip}
            />
          ) : null}

          <div
            ref={scrollRef}
            className={cn(
              "min-h-0 flex-1 overflow-y-auto scrollbar-none",
              compact ? "text-sm" : "text-base",
            )}
          >
            {screen === "dashboard" && insights ? (
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
                  onDemandMetricIds={layout.onDemandMetricIds}
                />
              </div>
            ) : null}

            {screen === "history" && (
              <div key="history" className="motion-view">
                <Suspense fallback={<p role="status" className="p-3 text-xs">Loading Usage History…</p>}>
                  <HistoryView plugins={displayPlugins} persistEnabled={persistEnabled} />
                </Suspense>
              </div>
            )}

            {screen === "customize" ? (
              <div key="customize" className="motion-view">
              <CustomizeView
                providers={settingsPlugins}
                providerId={editingProvider?.id ?? null}
                onOpenProvider={setProviderId}
                onSettings={() => setActiveView("settings")}
                onToggleProvider={(id) => actions.current.onToggle(id)}
                recordUndo={(undo) => { undoStack.current.push(undo) }}
                descriptors={descriptors}
                placedMetricIds={placedMetricIds}
                onTogglePlaced={(metricId, enabled) => {
                  const labels = descriptors
                    .filter((d) => d.pluginId === parseMetricId(metricId)?.pluginId)
                    .map((d) => d.lineLabel)
                  actions.current.onDashboardMetricToggle(metricId, enabled, labels)
                }}
                onSetProviderMetricsEnabled={(id, enabled) => {
                  const labels = descriptors.filter((d) => d.pluginId === id).map((d) => d.lineLabel)
                  actions.current.onProviderDashboardMetrics(id, labels, enabled)
                }}
                onProviderReorder={(order) => actions.current.onReorder(order)}
              />
              {editingProvider && editingProvider.baseProviderId !== "mock" && (
                <AppContent
                  {...appContentProps}
                  displayPlugins={displayPlugins}
                  settingsPlugins={settingsPlugins}
                  selectedPlugin={null}
                  viewOverride="settings"
                  accountProviderId={editingProvider.id}
                />
              )}
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
              <button type="button" onClick={() => setActiveView("customize")}
                className="mb-2 flex w-full flex-col rounded-xl border bg-card p-3 text-left text-xs">
                <strong>Customize</strong>
                <span className="text-muted-foreground">Choose What’s Visible and Where</span>
              </button>
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
            trailing={screen === "dashboard" ? (
              <PanelOptions
                onCustomize={() => setActiveView("customize")}
                onHistory={() => setActiveView("history")}
                onSettings={() => setActiveView("settings")}
                onAbout={() => setShowAbout(true)}
                onQuit={quitApp}
              />
            ) : undefined}
          />
        </div>
      </div>
    </div>
  )
}
