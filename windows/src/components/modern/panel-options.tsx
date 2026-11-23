import { Menu } from "@base-ui/react/menu"
import { ChevronDown, History, Info, Power, Settings, SlidersHorizontal } from "lucide-react"

const itemClass = "flex items-center gap-2 rounded px-2 py-1.5 outline-none data-highlighted:bg-accent"

export function PanelOptions({ onCustomize, onHistory, onSettings, onAbout, onQuit }: {
  onCustomize: () => void
  onHistory: () => void
  onSettings: () => void
  onAbout: () => void
  onQuit: () => void
}) {
  return (
    <Menu.Root>
      <Menu.Trigger className="flex h-6 items-center gap-1 rounded-full border border-border/60 bg-card/60 px-2.5 text-[11px] font-semibold hover:bg-accent">
        Options <ChevronDown className="size-3" aria-hidden="true" />
      </Menu.Trigger>
      <Menu.Portal>
        <Menu.Positioner side="top" align="end" sideOffset={5} className="z-50">
          <Menu.Popup className="min-w-48 rounded-lg border border-border bg-popover p-1 text-xs text-popover-foreground shadow-lg">
            <Menu.Item className={itemClass} onClick={onCustomize}><SlidersHorizontal className="size-3.5" />Customize</Menu.Item>
            <Menu.Item className={itemClass} onClick={onHistory}><History className="size-3.5" />Usage History</Menu.Item>
            <Menu.Item className={itemClass} onClick={onSettings}><Settings className="size-3.5" />Settings</Menu.Item>
            <Menu.Separator className="my-1 border-t border-border" />
            <Menu.Item className={itemClass} onClick={onAbout}><Info className="size-3.5" />About QuotaBar</Menu.Item>
            <Menu.Item className={itemClass} onClick={onQuit}><Power className="size-3.5" />Quit QuotaBar</Menu.Item>
          </Menu.Popup>
        </Menu.Positioner>
      </Menu.Portal>
    </Menu.Root>
  )
}
