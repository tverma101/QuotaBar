import { useState } from "react"
import { invoke } from "@tauri-apps/api/core"
import { Button } from "@/components/ui/button"

type RegisteredCodexAccount = { instanceId: string; label: string }

export function CodexEnrollment({
  label,
  onRegistered,
}: {
  label: string
  onRegistered: (account: RegisteredCodexAccount) => void
}) {
  const [operation, setOperation] = useState<"sign-in" | "existing" | null>(null)
  const [error, setError] = useState<string | null>(null)

  async function enroll(mode: "sign-in" | "existing") {
    setOperation(mode)
    setError(null)
    try {
      let result: RegisteredCodexAccount
      if (mode === "sign-in") {
        result = await invoke("sign_in_to_codex", { label })
      } else {
        const { open } = await import("@tauri-apps/plugin-dialog")
        const path = await open({ directory: true, multiple: false, title: "Choose Codex Home" })
        if (!path) return
        result = await invoke("register_codex_home", { label, path })
      }
      onRegistered(result)
    } catch (failure) {
      setError(typeof failure === "string" ? failure : "Could not connect the Codex account.")
    } finally {
      setOperation(null)
    }
  }

  return (
    <div className="mb-3 space-y-2">
      <p className="text-xs text-muted-foreground">
        Sign in through Codex in your browser, or connect an existing Codex home. No credentials need to be copied.
      </p>
      {operation === "sign-in" ? (
        <div className="flex items-center justify-between gap-2">
          <p role="status" className="text-xs">Finish signing in through Codex in your browser.</p>
          <Button type="button" size="sm" variant="outline" onClick={() => {
            void invoke("cancel_codex_sign_in").catch(() => setError("Could not cancel Codex sign-in."))
          }}>Cancel</Button>
        </div>
      ) : (
        <Button type="button" size="sm" variant="outline" className="w-full" disabled={!!operation}
          onClick={() => void enroll("sign-in")}>Sign In to Codex…</Button>
      )}
      <Button type="button" size="sm" variant="outline" className="w-full" disabled={!!operation}
        onClick={() => void enroll("existing")}>Use Existing Codex Home…</Button>
      {error ? <p role="alert" className="text-xs text-destructive">{error}</p> : null}
    </div>
  )
}
