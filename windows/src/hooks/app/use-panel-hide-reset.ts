import { useEffect } from "react"
import { isTauri } from "@tauri-apps/api/core"
import { listen } from "@tauri-apps/api/event"
import { useAppUiStore } from "@/stores/app-ui-store"

/** Closing the panel returns it to Home at the top, like the macOS panel (both layouts). */
export function usePanelHideReset() {
  const setActiveView = useAppUiStore((s) => s.setActiveView)

  useEffect(() => {
    if (!isTauri()) return
    let cancelled = false
    let unlisten: (() => void) | undefined
    void listen("panel:did-hide", () => {
      setActiveView("home")
      for (const el of Array.from(document.querySelectorAll<HTMLElement>("[data-panel-scroll]"))) {
        el.scrollTo({ top: 0 })
      }
    })
      .then((u) => {
        if (cancelled) u()
        else unlisten = u
      })
      .catch(console.error)
    return () => {
      cancelled = true
      unlisten?.()
    }
  }, [setActiveView])
}
