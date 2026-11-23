import { AlertCircle } from "lucide-react"
import { Alert, AlertDescription } from "@/components/ui/alert"

type PluginErrorProps = {
  message: string
  /** Slim single-line row for the popover card layout. */
  compact?: boolean
}

function formatMessage(message: string) {
  const parts = message.split(/`([^`]+)`/)
  return parts.map((part, index) =>
    index % 2 === 1 ? (
      <code
        key={`code-${index}`}
        className="rounded bg-muted px-1 font-mono text-[0.75rem] leading-tight"
      >
        {part}
      </code>
    ) : (
      part
    )
  )
}

export function PluginError({ message, compact }: PluginErrorProps) {
  if (compact) {
    return (
      <div className="flex items-start gap-1.5 py-1 text-xs text-destructive">
        <AlertCircle className="mt-px h-3.5 w-3.5 shrink-0" />
        <span className="select-text cursor-text leading-snug">{formatMessage(message)}</span>
      </div>
    )
  }
  return (
    <Alert
      variant="destructive"
      className="flex items-center gap-2 [&>svg]:static [&>svg]:translate-y-0 [&>svg~*]:pl-0 [&>svg+div]:translate-y-0"
    >
      <AlertCircle className="h-4 w-4" />
      <AlertDescription className="select-text cursor-text">{formatMessage(message)}</AlertDescription>
    </Alert>
  )
}
