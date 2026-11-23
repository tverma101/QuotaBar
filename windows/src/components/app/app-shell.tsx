import { useShallow } from "zustand/react/shallow"
import { invoke, isTauri } from "@tauri-apps/api/core"
import { Menu, MenuItem, PredefinedMenuItem } from "@tauri-apps/api/menu"
import { ChevronDown, ChevronLeft, X } from "lucide-react"
import { AppContent, type AppContentActionProps } from "@/components/app/app-content"
import { OnboardingWizard } from "@/components/onboarding-wizard"
import type { UILayout } from "@/lib/settings"
import { LiquidGlassFilter } from "@/components/liquid-glass-filter"
import { PanelFooter } from "@/components/panel-footer"
import { SideNav, type NavPlugin, type PluginContextAction } from "@/components/side-nav"
import type { DisplayPluginState } from "@/hooks/app/use-app-plugin-views"
import type { SettingsPluginState } from "@/hooks/app/use-settings-plugin-list"
import { useAppVersion } from "@/hooks/app/use-app-version"
import { usePanel } from "@/hooks/app/use-panel"
import { usePlatform } from "@/hooks/app/use-platform"
import { useAppPreferencesStore } from "@/stores/app-preferences-store"
import { useAppUiStore } from "@/stores/app-ui-store"
import { useMotionPointer } from "@/hooks/app/use-motion-pointer"
import { MotionField } from "@/components/motion-field"

type AppShellProps = {
  onRefreshAll: () => void
  navPlugins: NavPlugin[]
  displayPlugins: DisplayPluginState[]
  settingsPlugins: SettingsPluginState[]
  autoUpdateNextAt: number | null
  selectedPlugin: DisplayPluginState | null
  onPluginContextAction: (pluginId: string, action: PluginContextAction) => void
  isPluginRefreshAvailable: (pluginId: string) => boolean
  onNavReorder: (orderedIds: string[]) => void
  appContentProps: AppContentActionProps

  showOnboardingWizard: boolean
  onOnboardingComplete: (layout: UILayout) => void
  onOnboardingSkip: () => void
}

export function AppShell({
  onRefreshAll,
  navPlugins,
  displayPlugins,
  settingsPlugins,
  autoUpdateNextAt,
  selectedPlugin,
  onPluginContextAction,
  isPluginRefreshAvailable,
  onNavReorder,
  appContentProps,
  showOnboardingWizard,
  onOnboardingComplete,
  onOnboardingSkip,
}: AppShellProps) {
  const { themeMode, reduceAnimations } = useAppPreferencesStore(
    useShallow((state) => ({ themeMode: state.themeMode, reduceAnimations: state.reduceAnimations }))
  )

  const {
    activeView,
    setActiveView,
    showAbout,
    setShowAbout,
  } = useAppUiStore(
    useShallow((state) => ({
      activeView: state.activeView,
      setActiveView: state.setActiveView,
      showAbout: state.showAbout,
      setShowAbout: state.setShowAbout,
    }))
  )

  const {
    containerRef,
    scrollRef,
    canScrollDown,
    maxPanelHeightPx,
  } = usePanel({
    activeView,
    setActiveView,
    showAbout,
    setShowAbout,
    displayPlugins,
  })

  const appVersion = useAppVersion()
  const platform = usePlatform()
  // macOS and Windows run the same frameless tray popover (borderless window,
  // click-away dismiss); Linux keeps the native-title-bar layout.
  const popoverChrome = isTauri() && (platform === "macos" || platform === "windows")
  // Windows-only: single-column popover (no nav rail), back bar on sub-views,
  // Options menu in the footer — mirroring the macOS QuotaBar panel.
  const compactPopover = isTauri() && platform === "windows"
  const macPopoverChrome = platform === "macos"
  const panelMotionRef = useMotionPointer(!reduceAnimations)

  // macOS parity: the popover footer exposes a single Options menu instead of
  // a nav rail (Customize/Settings/About/Quit, mirroring the macOS popover).
  const openOptionsMenu = () => {
    ;(async () => {
      const settingsItem = await MenuItem.new({
        id: "opt-settings",
        text: "Settings",
        action: () => setActiveView("settings"),
      })
      const aboutItem = await MenuItem.new({
        id: "opt-about",
        text: "About QuotaBar",
        action: () => setShowAbout(true),
      })
      const quitItem = await MenuItem.new({
        id: "opt-quit",
        text: "Quit QuotaBar",
        action: () => {
          invoke("quit_app").catch(console.error)
        },
      })
      const separator = await PredefinedMenuItem.new({ item: "Separator" })
      const separator2 = await PredefinedMenuItem.new({ item: "Separator" })
      const menu = await Menu.new({
        items: [settingsItem, separator, aboutItem, separator2, quitItem],
      })
      try {
        await menu.popup()
      } finally {
        await Promise.allSettled([
          menu.close(),
          settingsItem.close(),
          aboutItem.close(),
          quitItem.close(),
          separator.close(),
          separator2.close(),
        ])
      }
    })().catch(console.error)
  }

  const onHome = activeView === "home"
  const topBarTitle =
    activeView === "settings"
      ? "Settings"
      : (selectedPlugin?.meta.name ?? "")

  return (
    <div ref={containerRef} className="app-popover-shell w-full bg-transparent" tabIndex={-1}>
      {/* SVG filter definitions for the liquid-distort effect; rendered off-screen */}
      <LiquidGlassFilter active={themeMode === "glass"} />
      {macPopoverChrome ? <div className="tray-arrow" aria-hidden="true" /> : null}
      {/* Windows popover anchors above/beside the taskbar, so no top arrow. */}
      <div
        ref={panelMotionRef}
        className="app-panel-surface relative w-full overflow-hidden rounded-[18px] select-none flex flex-col"
        data-ui-layout="classic"
        style={
          macPopoverChrome && maxPanelHeightPx
            ? { maxHeight: `${maxPanelHeightPx}px` }
            : undefined
        }
      >
        <MotionField />
        <div className="flex flex-1 min-h-0 flex-row">
          {compactPopover ? null : (
            <SideNav
              activeView={activeView}
              onViewChange={setActiveView}
              plugins={navPlugins}
              onPluginContextAction={onPluginContextAction}
              isPluginRefreshAvailable={isPluginRefreshAvailable}
              onReorder={onNavReorder}
            />
          )}
          <div className="app-main-pane relative flex-1 flex flex-col px-3 pt-2 pb-1.5 min-w-0">
            {popoverChrome ? (
              <button
                type="button"
                className="absolute right-2 top-1 z-30 flex h-8 w-8 items-center justify-center rounded-md text-muted-foreground hover:bg-muted hover:text-foreground"
                aria-label="Hide window"
                onClick={() => {
                  void invoke("hide_panel")
                }}
              >
                <X className="h-4 w-4" strokeWidth={2.5} />
              </button>
            ) : null}
            {compactPopover && !onHome ? (
              <div className="relative mb-1 flex h-7 shrink-0 items-center">
                <button
                  type="button"
                  className="flex h-6 w-6 items-center justify-center rounded-full text-muted-foreground hover:bg-muted hover:text-foreground"
                  aria-label="Back"
                  onClick={() => setActiveView("home")}
                >
                  <ChevronLeft className="h-4 w-4" strokeWidth={2.5} />
                </button>
                <span className="pointer-events-none absolute inset-x-8 truncate text-center text-[13px] font-semibold">
                  {topBarTitle}
                </span>
              </div>
            ) : null}
            <div className="relative flex min-h-0 flex-1 flex-col">
              {showOnboardingWizard ? (
                <OnboardingWizard onComplete={onOnboardingComplete} onSkip={onOnboardingSkip} />
              ) : null}
              <div
                ref={scrollRef}
                className="min-h-0 flex-1 overflow-y-auto scrollbar-none"
              >
                <div className="min-h-full min-w-0">
                  <AppContent
                    {...appContentProps}
                    displayPlugins={displayPlugins}
                    settingsPlugins={settingsPlugins}
                    compactSettings={compactPopover}
                    selectedPlugin={selectedPlugin}
                  />
                </div>
              </div>
              <div
                className={`app-scroll-fade pointer-events-none absolute inset-x-0 bottom-0 h-14 transition-opacity duration-200 ${canScrollDown ? "opacity-100" : "opacity-0"}`}
              />
            </div>
            <PanelFooter
              version={appVersion}
              autoUpdateNextAt={autoUpdateNextAt}
              onRefreshAll={onRefreshAll}
              showAbout={showAbout}
              onShowAbout={() => setShowAbout(true)}
              onCloseAbout={() => setShowAbout(false)}
              trailing={
                compactPopover && onHome ? (
                  <button
                    type="button"
                    onClick={(e) => {
                      e.currentTarget.blur()
                      openOptionsMenu()
                    }}
                    className="flex h-6 items-center gap-1 rounded-full border border-border/60 bg-card/60 px-2.5 text-[11px] font-semibold text-foreground hover:bg-accent transition-colors"
                  >
                    Options
                    <ChevronDown className="h-3 w-3" strokeWidth={2.5} />
                  </button>
                ) : undefined
              }
            />
          </div>
        </div>
      </div>
    </div>
  )
}
