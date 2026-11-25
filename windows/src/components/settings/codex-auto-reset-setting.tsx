import { useEffect, useState } from "react"
import { invoke } from "@tauri-apps/api/core"
import { Checkbox } from "@/components/ui/checkbox"

export function CodexAutoResetSetting() {
  const [enabled, setEnabled] = useState<boolean | null>(null)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    void invoke<boolean>("codex_auto_reset_enabled")
      .then((value) => setEnabled(value === true))
      .catch(() => setError("Could not load the Codex reset setting."))
  }, [])

  async function update(value: boolean) {
    setSaving(true)
    setError(null)
    try {
      await invoke("set_codex_auto_reset_enabled", { value })
      setEnabled(value)
    } catch {
      setError("Could not save the Codex reset setting.")
    } finally {
      setSaving(false)
    }
  }

  return (
    <section>
      <label className="flex items-center justify-between gap-2 font-semibold">
        Auto-Use Expiring Codex Resets
        <Checkbox checked={enabled === true} disabled={enabled === null || saving}
          onCheckedChange={(value) => void update(value === true)} />
      </label>
      <p className="text-sm text-muted-foreground">
        Use an available Codex reset within one minute of expiry on each verified Codex account.
        QuotaBar must be running and the computer awake.
      </p>
      {error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}
    </section>
  )
}
