import { useEffect, useMemo, useRef, useState, type ReactNode } from "react"
import { ChevronDown, History, Info, Loader2, Power, Settings, SlidersHorizontal } from "lucide-react"
import { AboutDialog } from "@/components/about-dialog"
import { useNowTicker } from "@/hooks/use-now-ticker"
import { cn } from "@/lib/utils"

type ModernFooterProps = {
  version: string
  autoUpdateNextAt: number | null
  refreshing: boolean
  onRefreshAll: () => void
  showAbout: boolean
  onShowAbout: () => void
  onCloseAbout: () => void
  /** The Options menu only lives on the dashboard, like the macOS panel. */
  showOptions: boolean
  onOpenCustomize: () => void
  onOpenHistory: () => void
  onOpenSettings: () => void
  onQuit: () => void
}

export function nextUpdateLabel(autoUpdateNextAt: number | null, now: number): string {
  if (!autoUpdateNextAt) return "Auto Update Paused"
  const totalSeconds = Math.ceil(Math.max(0, autoUpdateNextAt - now) / 1000)
  if (totalSeconds >= 60) return `Next update in ${Math.ceil(totalSeconds / 60)}m`
  return `Next update in ${totalSeconds}s`
}

export function ModernFooter({
  version,
  autoUpdateNextAt,
  refreshing,
  onRefreshAll,
  showAbout,
  onShowAbout,
  onCloseAbout,
  showOptions,
  onOpenCustomize,
  onOpenHistory,
  onOpenSettings,
  onQuit,
}: ModernFooterProps) {
  const now = useNowTicker({ enabled: Boolean(autoUpdateNextAt), resetKey: autoUpdateNextAt })
  const countdown = useMemo(() => nextUpdateLabel(autoUpdateNextAt, now), [autoUpdateNextAt, now])

  return (
    <>
      <footer className="flex h-[52px] shrink-0 items-center justify-between gap-3 border-t border-hairline bg-chrome pl-[14px] pr-[12px]">
        <div className="flex min-w-0 flex-col items-start text-[12px] leading-[1.3] text-foreground/80">
          <button
            type="button"
            onClick={onShowAbout}
            className="truncate rounded-[4px] outline-none transition-colors hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring"
          >
            QuotaBar {version}
          </button>
          <button
            type="button"
            disabled={refreshing}
            onClick={(event) => {
              event.currentTarget.blur()
              onRefreshAll()
            }}
            className="flex items-center gap-1 truncate rounded-[4px] tabular-nums outline-none transition-colors hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring disabled:cursor-default"
            aria-label={refreshing ? "Updating" : `${countdown}. Refresh now`}
          >
            {refreshing ? (
              <>
                Updating…
                <Loader2 className="size-3 animate-spin text-muted-foreground" aria-hidden />
              </>
            ) : (
              countdown
            )}
          </button>
        </div>
        {showOptions ? (
          <OptionsMenu
            onOpenCustomize={onOpenCustomize}
            onOpenHistory={onOpenHistory}
            onOpenSettings={onOpenSettings}
            onShowAbout={onShowAbout}
            onQuit={onQuit}
          />
        ) : null}
      </footer>
      {showAbout ? <AboutDialog version={version} onClose={onCloseAbout} /> : null}
    </>
  )
}

function OptionsMenu({
  onOpenCustomize,
  onOpenHistory,
  onOpenSettings,
  onShowAbout,
  onQuit,
}: {
  onOpenCustomize: () => void
  onOpenHistory: () => void
  onOpenSettings: () => void
  onShowAbout: () => void
  onQuit: () => void
}) {
  const [open, setOpen] = useState(false)
  const rootRef = useRef<HTMLDivElement>(null)
  const menuRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    const onPointer = (event: PointerEvent) => {
      if (!rootRef.current?.contains(event.target as Node)) setOpen(false)
    }
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return
      event.preventDefault()
      event.stopPropagation()
      setOpen(false)
    }
    document.addEventListener("pointerdown", onPointer)
    document.addEventListener("keydown", onKey, true)
    menuRef.current?.querySelector<HTMLButtonElement>("[role=menuitem]")?.focus()
    return () => {
      document.removeEventListener("pointerdown", onPointer)
      document.removeEventListener("keydown", onKey, true)
    }
  }, [open])

  const choose = (action: () => void) => () => {
    setOpen(false)
    action()
  }

  return (
    <div ref={rootRef} className="relative">
      <button
        type="button"
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen((v) => !v)}
        className={cn(
          "flex h-[34px] items-center gap-1.5 rounded-full px-[14px] text-[14px] font-semibold outline-none transition-colors focus-visible:ring-2 focus-visible:ring-ring",
          open ? "bg-control-hover" : "bg-control hover:bg-control-hover",
        )}
      >
        Options
        <ChevronDown className="size-4" strokeWidth={2.25} aria-hidden />
      </button>
      {open ? (
        <div
          ref={menuRef}
          role="menu"
          aria-label="Options"
          onKeyDown={(event) => {
            if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return
            event.preventDefault()
            const items = Array.from(menuRef.current?.querySelectorAll<HTMLButtonElement>("[role=menuitem]") ?? [])
            const at = items.indexOf(document.activeElement as HTMLButtonElement)
            const next = event.key === "ArrowDown" ? (at + 1) % items.length : (at - 1 + items.length) % items.length
            items[next]?.focus()
          }}
          className="absolute bottom-[calc(100%+8px)] right-0 z-50 w-[220px] origin-bottom-right animate-in fade-in-0 zoom-in-95 rounded-[12px] border border-hairline bg-popover p-[5px] shadow-[0_10px_30px_rgba(0,0,0,0.35)] duration-100"
        >
          <MenuItem icon={<SlidersHorizontal />} label="Customize" onSelect={choose(onOpenCustomize)} />
          <MenuItem icon={<History />} label="Usage History" onSelect={choose(onOpenHistory)} />
          <MenuItem icon={<Settings />} label="Settings" shortcut="Ctrl+," onSelect={choose(onOpenSettings)} />
          <div className="mx-[10px] my-[5px] h-px bg-hairline" role="separator" />
          <MenuItem icon={<Info />} label="About QuotaBar" onSelect={choose(onShowAbout)} />
          <MenuItem icon={<Power />} label="Quit QuotaBar" shortcut="Ctrl+Q" onSelect={choose(onQuit)} />
        </div>
      ) : null}
    </div>
  )
}

function MenuItem({
  icon,
  label,
  shortcut,
  onSelect,
}: {
  icon: ReactNode
  label: string
  shortcut?: string
  onSelect: () => void
}) {
  return (
    <button
      type="button"
      role="menuitem"
      onClick={onSelect}
      className="flex h-[30px] w-full items-center gap-[9px] rounded-[7px] px-[9px] text-left text-[13px] outline-none transition-colors hover:bg-switch-on hover:text-white focus-visible:bg-switch-on focus-visible:text-white [&_svg]:size-[15px] [&_svg]:shrink-0"
    >
      {icon}
      <span className="flex-1 truncate">{label}</span>
      {shortcut ? <span className="text-[12px] opacity-50">{shortcut}</span> : null}
    </button>
  )
}
