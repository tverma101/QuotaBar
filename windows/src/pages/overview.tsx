import { useEffect } from "react"
import { ProviderCard } from "@/components/provider-card"
import { useSpendSpikeAlert } from "@/hooks/use-spend-spike-alert"
import { useWeeklyRollup } from "@/hooks/use-weekly-rollup"
import { usePersistUsageHistory } from "@/hooks/use-persist-usage-history"
import { useAppUiStore } from "@/stores/app-ui-store"
import { usePlatform } from "@/hooks/app/use-platform"
import type { PluginDisplayState } from "@/lib/plugin-types"
import type { DisplayMode, ResetTimerDisplayMode, TimeFormatMode } from "@/lib/settings"

interface OverviewPageProps {
  plugins: PluginDisplayState[]
  onProbeComplete?: () => void
  onRetryPlugin?: (pluginId: string) => void
  displayMode: DisplayMode
  resetTimerDisplayMode: ResetTimerDisplayMode
  timeFormatMode?: TimeFormatMode
  onResetTimerDisplayModeToggle?: () => void
  showAccountIdentity?: boolean
}

export function OverviewPage({
  plugins,
  onProbeComplete,
  onRetryPlugin,
  displayMode,
  resetTimerDisplayMode,
  timeFormatMode = "auto",
  onResetTimerDisplayModeToggle,
  showAccountIdentity,
}: OverviewPageProps) {
  const persistEnabled = usePersistUsageHistory()
  const { rollup, scheduleReload } = useWeeklyRollup(persistEnabled)
  const { checkSpendSpike } = useSpendSpikeAlert()
  const setActiveView = useAppUiStore((state) => state.setActiveView)
  const platform = usePlatform()
  const compactPopover = platform === "windows"

  const probeStamp = plugins.map((p) => p.lastUpdatedAt ?? 0).join(",")
  useEffect(() => {
    onProbeComplete?.()
    scheduleReload()
  }, [probeStamp, onProbeComplete, scheduleReload])

  useEffect(() => {
    checkSpendSpike(rollup)
  }, [rollup, checkSpendSpike])

  if (plugins.length === 0) {
    return (
      <div className="text-center text-muted-foreground py-8">
        No providers enabled
      </div>
    )
  }

  return (
    <div className="motion-stagger space-y-3">
      {plugins.map((plugin, index) => (
        <div
          key={plugin.meta.id}
          className="motion-card"
          style={{ ["--i" as string]: index }}
        >
        <ProviderCard
          name={plugin.meta.name}
          plan={plugin.data?.plan}
          links={compactPopover ? plugin.meta.links : undefined}
          popover={compactPopover}
          iconUrl={compactPopover ? plugin.meta.iconUrl : undefined}
          onTitleClick={compactPopover ? () => setActiveView(plugin.meta.id) : undefined}
          showSeparator={index < plugins.length - 1}
          loading={plugin.loading}
          error={plugin.error}
          warning={plugin.data?.warning}
          lines={plugin.data?.lines ?? []}
          skeletonLines={plugin.meta.lines}
          lastManualRefreshAt={plugin.lastManualRefreshAt}
          lastUpdatedAt={plugin.lastUpdatedAt}
          onRetry={onRetryPlugin ? () => onRetryPlugin(plugin.meta.id) : undefined}
          pluginId={plugin.meta.id}
          scopeFilter="overview"
          displayMode={displayMode}
          resetTimerDisplayMode={resetTimerDisplayMode}
          onResetTimerDisplayModeToggle={onResetTimerDisplayModeToggle}
          timeFormatMode={timeFormatMode}
          showAccountIdentity={showAccountIdentity}
        />
        </div>
      ))}
    </div>
  )
}
