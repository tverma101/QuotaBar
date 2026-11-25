import { useCallback, useMemo, useRef, useState } from "react"
import { invoke, isTauri } from "@tauri-apps/api/core"
import { useShallow } from "zustand/react/shallow"
import { LiquidGlassFilter } from "@/components/liquid-glass-filter"
import { CustomizeProviderDetail, CustomizeProviderList, type CustomizeMetric } from "@/components/modern/customize-view"
import { NavBar } from "@/components/modern/mac-ui"
import { ModernFooter } from "@/components/modern/modern-footer"
import { TotalSpendCard } from "@/components/modern/total-spend-card"
import { UsageHistoryView } from "@/components/modern/usage-history-view"
import { WelcomeHint } from "@/components/modern/welcome-hint"
import { WidgetGroupedList } from "@/components/modern/widget-grouped-list"
import { AppContent, type AppContentActionProps } from "@/components/app/app-content"
import type { DisplayPluginState } from "@/hooks/app/use-app-plugin-views"
import type { SettingsPluginState } from "@/hooks/app/use-settings-plugin-list"
import { useAppVersion } from "@/hooks/app/use-app-version"
import { useModernDashboard } from "@/hooks/app/use-modern-dashboard"
import { useModernPanel } from "@/hooks/app/use-modern-panel"
import { useNowTicker } from "@/hooks/use-now-ticker"
import { metricId } from "@/lib/metric-id"
import { isMetricOnDemand } from "@/lib/metric-display"
import { getProviderInstanceMeta, type UILayout } from "@/lib/settings"
import { cn } from "@/lib/utils"
import { useAppPreferencesStore } from "@/stores/app-preferences-store"
import { useAppUiStore } from "@/stores/app-ui-store"
import { useModernLayoutStore } from "@/stores/modern-layout-store"

type ModernScreen =
  | { id: "dashboard" }
  | { id: "customize" }
  | { id: "provider"; pluginId: string }
  | { id: "settings" }
  | { id: "history" }

const DASHBOARD: ModernScreen = { id: "dashboard" }

type ModernShellProps = {
  onRefreshAll: () => void
  displayPlugins: DisplayPluginState[]
  settingsPlugins: SettingsPluginState[]
  autoUpdateNextAt: number | null
  appContentProps: AppContentActionProps
  showOnboardingWizard: boolean
  onOnboardingComplete: (layout: UILayout, openSettings?: boolean) => void
}

export function ModernShell({
  onRefreshAll,
  displayPlugins,
  settingsPlugins,
  autoUpdateNextAt,
  appContentProps,
  showOnboardingWizard,
  onOnboardingComplete,
}: ModernShellProps) {
  const [stack, setStack] = useState<ModernScreen[]>(() =>
    useAppUiStore.getState().activeView === "settings" ? [{ id: "settings" }] : [],
  )
  const screen = stack[stack.length - 1] ?? DASHBOARD
  const appVersion = useAppVersion()
  const panelRef = useRef<HTMLDivElement>(null)
  const contentRef = useRef<HTMLDivElement>(null)

  const { themeMode, modernDensity, showTotalSpend } = useAppPreferencesStore(
    useShallow((s) => ({
      themeMode: s.themeMode,
      modernDensity: s.modernDensity,
      showTotalSpend: s.showTotalSpend,
    })),
  )
  const { showAbout, setShowAbout, setActiveView } = useAppUiStore(
    useShallow((s) => ({ showAbout: s.showAbout, setShowAbout: s.setShowAbout, setActiveView: s.setActiveView })),
  )
  const layoutActions = useModernLayoutStore(
    useShallow((s) => ({
      metricOrderByProvider: s.metricOrderByProvider,
      onDemandOverrides: s.onDemandOverrides,
      setTrayFocusProvider: s.setTrayFocusProvider,
      setProviderArrangement: s.setProviderArrangement,
      resetProviderLayout: s.resetProviderLayout,
    })),
  )

  const compact = modernDensity === "compact"
  const nowMs = useNowTicker()
  const dashboard = useModernDashboard(displayPlugins, nowMs)
  const { pluginSettings, pluginsMeta, descriptors, placedMetricIds } = dashboard

  const push = useCallback((next: ModernScreen) => setStack((s) => [...s, next]), [])
  const back = useCallback(() => {
    const next = stack.slice(0, -1)
    if (!next.some((x) => x.id === "settings")) setActiveView("home")
    setStack(next)
  }, [stack, setActiveView])
  const home = useCallback(() => {
    setActiveView("home")
    setStack([])
  }, [setActiveView])
  const openSettings = useCallback(() => {
    setActiveView("settings")
    setStack((s) => (s[s.length - 1]?.id === "settings" ? s : [...s, { id: "settings" }]))
  }, [setActiveView])

  useModernPanel({
    panelRef,
    contentRef,
    screenKey: screen.id === "provider" ? `provider:${screen.pluginId}` : screen.id,
    canGoBack: stack.length > 0,
    showAbout,
    onBack: back,
    onHome: home,
    onOpenSettings: openSettings,
    onShowAbout: setShowAbout,
  })

  const customizeProviders = useMemo(
    () =>
      settingsPlugins.map((p) => {
        const meta = getProviderInstanceMeta(p.id, pluginSettings, pluginsMeta)
        const live = descriptors.filter((d) => d.pluginId === p.id).length
        return { id: p.id, name: p.name, iconUrl: meta?.iconUrl, enabled: p.enabled, metricCount: live || meta?.lines.length || 0 }
      }),
    [settingsPlugins, pluginSettings, pluginsMeta, descriptors],
  )

  const providerMetrics = useCallback(
    (pluginId: string): CustomizeMetric[] => {
      const meta = getProviderInstanceMeta(pluginId, pluginSettings, pluginsMeta)
      const live = descriptors.filter((d) => d.pluginId === pluginId).map((d) => ({ id: d.id, lineLabel: d.lineLabel }))
      const items = live.length > 0 ? live : (meta?.lines ?? []).map((l) => ({ id: metricId(pluginId, l.label), lineLabel: l.label }))
      const rank = new Map((layoutActions.metricOrderByProvider[pluginId] ?? []).map((id, i) => [id, i]))
      items.sort((a, b) => (rank.get(a.id) ?? 999) - (rank.get(b.id) ?? 999))
      const enabled = !pluginSettings?.disabled.includes(pluginId)
      const raw = pluginSettings?.trayLines?.[pluginId]
      const placed = enabled
        ? new Set(placedMetricIds)
        : new Set(raw == null || raw.length === 0 ? items.map((i) => i.id) : raw.map((l) => metricId(pluginId, l)))
      const base = meta?.baseProviderId ?? pluginId
      return items.map((item) => ({
        ...item,
        placed: placed.has(item.id),
        onDemand: isMetricOnDemand(item.id, base, item.lineLabel, layoutActions.onDemandOverrides),
      }))
    },
    [descriptors, pluginSettings, pluginsMeta, placedMetricIds, layoutActions.metricOrderByProvider, layoutActions.onDemandOverrides],
  )

  const refreshing = displayPlugins.some((p) => p.loading)
  const enabledNames = displayPlugins.map((p) => p.meta.name)

  let title = ""
  let onReset: (() => void) | undefined
  let content: React.ReactNode = null
  switch (screen.id) {
    case "dashboard":
      content = (
        <div className={cn("flex flex-col motion-stagger", compact ? "gap-[8px]" : "gap-[14px]")}>
          {showOnboardingWizard ? (
            <WelcomeHint
              enabledNames={enabledNames}
              onOpenCustomize={() => {
                onOnboardingComplete("modern", false)
                push({ id: "customize" })
              }}
              onDismiss={() => onOnboardingComplete("modern", false)}
            />
          ) : null}
          {showTotalSpend ? (
            <TotalSpendCard providers={dashboard.spendProviders} outputs={dashboard.spendOutputs} compact={compact} />
          ) : null}
          <WidgetGroupedList
            groups={dashboard.groups}
            compact={compact}
            displayMode={dashboard.displayMode}
            nowMs={nowMs}
            onRefreshPlugin={appContentProps.onRetryPlugin}
            onFocusProvider={layoutActions.setTrayFocusProvider}
            onOpenCustomize={() => push({ id: "customize" })}
          />
        </div>
      )
      break
    case "customize":
      title = "Customize"
      content = (
        <CustomizeProviderList
          providers={customizeProviders}
          compact={compact}
          onToggleProvider={appContentProps.onToggle}
          onReorder={appContentProps.onReorder}
          onOpenProvider={(pluginId) => push({ id: "provider", pluginId })}
          onOpenSettings={openSettings}
        />
      )
      break
    case "provider": {
      const { pluginId } = screen
      const metrics = providerMetrics(pluginId)
      title = customizeProviders.find((p) => p.id === pluginId)?.name ?? "Provider"
      onReset = () => layoutActions.resetProviderLayout(pluginId)
      content = (
        <CustomizeProviderDetail
          metrics={metrics}
          compact={compact}
          onTogglePlaced={(id, placed) =>
            appContentProps.onDashboardMetricToggle(id, placed, metrics.map((m) => m.lineLabel))
          }
          onArrange={(order, onDemandIds) => {
            const onDemand = new Set(onDemandIds)
            layoutActions.setProviderArrangement(
              pluginId,
              order,
              Object.fromEntries(metrics.map((m) => [m.id, onDemand.has(m.id)])),
            )
          }}
        />
      )
      break
    }
    case "settings":
      title = "Settings"
      content = (
        <div className="mac-settings">
          <AppContent
            {...appContentProps}
            displayPlugins={displayPlugins}
            settingsPlugins={settingsPlugins}
            selectedPlugin={null}
            viewOverride="settings"
          />
        </div>
      )
      break
    case "history":
      title = "Usage History"
      content = (
        <UsageHistoryView nowMs={nowMs} onOpenSettings={openSettings} />
      )
      break
  }

  return (
    <div className="app-popover-shell w-full bg-transparent" data-density={modernDensity}>
      <LiquidGlassFilter active={themeMode === "glass"} />
      <div
        ref={panelRef}
        className="app-panel-surface relative flex w-full select-none flex-col overflow-hidden rounded-[13px]"
        data-ui-layout="modern"
        data-density={modernDensity}
      >
        {screen.id !== "dashboard" ? <NavBar title={title} onBack={back} onReset={onReset} /> : null}
        <div data-panel-scroll className="min-h-0 flex-1 overflow-y-auto scrollbar-none">
          <div
            ref={contentRef}
            key={screen.id === "provider" ? `provider:${screen.pluginId}` : screen.id}
            className={cn("motion-view px-[14px] pb-[14px]", compact ? "pt-[10px]" : "pt-[14px]")}
          >
            {content}
          </div>
        </div>
        <ModernFooter
          version={appVersion}
          autoUpdateNextAt={autoUpdateNextAt}
          refreshing={refreshing}
          onRefreshAll={onRefreshAll}
          showAbout={showAbout}
          onShowAbout={() => setShowAbout(true)}
          onCloseAbout={() => setShowAbout(false)}
          showOptions={screen.id === "dashboard"}
          onOpenCustomize={() => push({ id: "customize" })}
          onOpenHistory={() => push({ id: "history" })}
          onOpenSettings={openSettings}
          onQuit={() => {
            if (isTauri()) invoke("quit_app").catch(console.error)
          }}
        />
      </div>
    </div>
  )
}
