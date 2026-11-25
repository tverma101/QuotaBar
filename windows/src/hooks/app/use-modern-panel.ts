import { useEffect, useRef, type RefObject } from "react"
import { invoke, isTauri } from "@tauri-apps/api/core"
import { listen } from "@tauri-apps/api/event"

type UseModernPanelArgs = {
  panelRef: RefObject<HTMLDivElement | null>
  contentRef: RefObject<HTMLDivElement | null>
  /** Changes whenever the visible screen changes (resets scroll, re-measures). */
  screenKey: string
  canGoBack: boolean
  showAbout: boolean
  onBack: () => void
  onHome: () => void
  onOpenSettings: () => void
  onShowAbout: (show: boolean) => void
}

function isEditableTarget(target: EventTarget | null): boolean {
  return (
    target instanceof HTMLElement &&
    (target.isContentEditable || Boolean(target.closest("input, textarea, select, [contenteditable='true']")))
  )
}

/**
 * Panel behavior for the Modern layout, mirroring the macOS panel: Esc steps back
 * (then hides), Ctrl+, opens Settings, Ctrl+Q quits, closing returns to the
 * dashboard, and on Windows the window height follows the content.
 */
export function useModernPanel({
  panelRef,
  contentRef,
  screenKey,
  canGoBack,
  showAbout,
  onBack,
  onHome,
  onOpenSettings,
  onShowAbout,
}: UseModernPanelArgs) {
  const handlers = useRef({ onBack, onHome, onOpenSettings, onShowAbout })
  handlers.current = { onBack, onHome, onOpenSettings, onShowAbout }

  useEffect(() => {
    if (!isTauri()) return
    invoke("init_panel").catch(console.error)
  }, [])

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || showAbout) return
      if (event.key === "Escape") {
        event.preventDefault()
        if (canGoBack) handlers.current.onBack()
        else if (isTauri()) invoke("hide_panel").catch(console.error)
        return
      }
      if (!event.ctrlKey || event.altKey || event.metaKey || isEditableTarget(event.target)) return
      if (event.key === ",") {
        event.preventDefault()
        handlers.current.onOpenSettings()
      } else if (event.key.toLowerCase() === "q" && isTauri()) {
        event.preventDefault()
        invoke("quit_app").catch(console.error)
      }
    }
    document.addEventListener("keydown", onKeyDown)
    return () => document.removeEventListener("keydown", onKeyDown)
  }, [canGoBack, showAbout])

  useEffect(() => {
    if (!isTauri()) return
    let cancelled = false
    const unlisteners: (() => void)[] = []
    const add = (promise: Promise<() => void>) =>
      promise
        .then((unlisten) => (cancelled ? unlisten() : unlisteners.push(unlisten)))
        .catch(console.error)

    add(
      listen<string>("tray:navigate", (event) => {
        if (event.payload === "settings") handlers.current.onOpenSettings()
        else handlers.current.onHome()
      }),
    )
    add(listen("tray:show-about", () => handlers.current.onShowAbout(true)))
    add(
      listen("panel:did-hide", () => {
        handlers.current.onShowAbout(false)
        handlers.current.onHome()
      }),
    )
    return () => {
      cancelled = true
      for (const unlisten of unlisteners) unlisten()
    }
  }, [])

  useEffect(() => {
    contentRef.current?.parentElement?.scrollTo({ top: 0 })
  }, [screenKey, contentRef])

  useEffect(() => {
    if (!isTauri()) return
    const panel = panelRef.current
    const content = contentRef.current
    if (!panel || !content) return
    let platform: string | null = null
    let frame = 0
    let cancelled = false

    const resize = async () => {
      platform ??= await invoke<string>("get_platform").catch((error) => {
        console.error("Get panel platform:", error)
        return ""
      })
      if (cancelled || platform !== "windows") return
      const scroll = content.parentElement
      const chrome = panel.offsetHeight - (scroll ? scroll.offsetHeight : 0)
      await invoke<number | null>("resize_panel", { height: chrome + content.offsetHeight + 2 }).catch(console.error)
    }
    const schedule = () => {
      cancelAnimationFrame(frame)
      frame = requestAnimationFrame(() => void resize())
    }

    schedule()
    const observer = new ResizeObserver(schedule)
    observer.observe(content)
    return () => {
      cancelled = true
      cancelAnimationFrame(frame)
      observer.disconnect()
    }
  }, [panelRef, contentRef, screenKey])
}
