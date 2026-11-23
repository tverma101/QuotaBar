import { useEffect } from "react"
import { invoke, isTauri } from "@tauri-apps/api/core"

/** Focus the main window when the user clicks a system notification. */
export function useNotificationFocus() {
  useEffect(() => {
    if (!isTauri()) return

    let disposed = false
    let unregister: (() => void) | undefined

    void (async () => {
      try {
        const { onAction } = await import("@tauri-apps/plugin-notification")
        const listener = await onAction(() => {
          if (disposed) return
          void invoke("show_panel").catch(console.error)
        })
        if (disposed) {
          void listener.unregister()
          return
        }
        unregister = () => {
          void listener.unregister()
        }
      } catch (error) {
        console.warn("Notification click handler unavailable:", error)
      }
    })()

    return () => {
      disposed = true
      unregister?.()
    }
  }, [])
}
