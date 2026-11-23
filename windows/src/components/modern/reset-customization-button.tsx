import { AlertDialog } from "@base-ui/react/alert-dialog"
import { RotateCcw } from "lucide-react"

export function ResetCustomizationButton({ onReset }: { onReset: () => void }) {
  return (
    <AlertDialog.Root>
      <AlertDialog.Trigger className="ml-auto grid size-6 place-items-center rounded-full text-muted-foreground hover:bg-muted hover:text-foreground"
        aria-label="Reset All Customization">
        <RotateCcw className="size-4" aria-hidden="true" />
      </AlertDialog.Trigger>
      <AlertDialog.Portal>
        <AlertDialog.Backdrop className="fixed inset-0 z-50 bg-black/40" />
        <AlertDialog.Popup className="fixed left-1/2 top-1/2 z-50 w-[calc(100%-2rem)] max-w-xs -translate-x-1/2 -translate-y-1/2 space-y-3 rounded-xl border bg-popover p-4 text-popover-foreground shadow-lg">
          <AlertDialog.Title className="text-sm font-semibold">Reset All Customization?</AlertDialog.Title>
          <AlertDialog.Description className="text-xs text-muted-foreground">
            Turns on Claude, Codex, Cursor, Freebuff, and registered Codex accounts, turns other providers off, and resets every provider's metrics and order. Are you sure?
          </AlertDialog.Description>
          <div className="flex justify-end gap-2 text-xs">
            <AlertDialog.Close className="rounded-md border px-3 py-1.5">Cancel</AlertDialog.Close>
            <AlertDialog.Close className="rounded-md bg-destructive px-3 py-1.5 text-white" onClick={onReset}>Reset All</AlertDialog.Close>
          </div>
        </AlertDialog.Popup>
      </AlertDialog.Portal>
    </AlertDialog.Root>
  )
}
