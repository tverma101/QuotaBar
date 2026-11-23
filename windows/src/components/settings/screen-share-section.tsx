import { useEffect, useState } from "react"
import { invoke, isTauri } from "@tauri-apps/api/core"
import { Checkbox } from "@/components/ui/checkbox"
import { loadHideFromScreenShare, saveHideFromScreenShare } from "@/lib/settings"

/** Windows only: keep QuotaBar's own windows out of screen capture (WDA_EXCLUDEFROMCAPTURE). */
export function ScreenShareSection() {
  const [platform, setPlatform] = useState<string | null>(null)
  const [enabled, setEnabled] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!isTauri()) return
    void invoke<string>("get_platform")
      .then(setPlatform)
      .catch(() => setPlatform(null))
    void loadHideFromScreenShare().then(setEnabled).catch(console.error)
  }, [])

  if (platform !== "windows") return null

  const onChange = async (value: boolean) => {
    setError(null)
    try {
      await invoke("set_hide_from_screen_share", { enabled: value })
      await saveHideFromScreenShare(value)
      setEnabled(value)
    } catch (cause) {
      console.error("Hide From Screen Share failed:", cause)
      setError("Could not change screen share protection. See the log for details.")
    }
  }

  return (
    <section>
      <h3 className="text-lg font-semibold mb-0">Hide From Screen Share</h3>
      <p className="text-sm text-muted-foreground mb-2">
        Keep the QuotaBar window out of screen shares, recordings and screenshots; it shows as a
        blank area there. The tray icon belongs to Windows and stays visible.
      </p>
      <label className="flex items-center gap-2 text-sm select-none text-foreground">
        <Checkbox
          key={`hide-from-screen-share-${enabled}`}
          checked={enabled}
          onCheckedChange={(checked) => void onChange(checked === true)}
        />
        Hide From Screen Share
      </label>
      {error ? <p className="text-sm text-destructive mt-1">{error}</p> : null}
    </section>
  )
}
