import { SlidersHorizontal, X } from "lucide-react"
import { GroupCard } from "@/components/modern/mac-ui"

function joinNames(names: string[]): string {
  if (names.length <= 1) return names[0] ?? ""
  if (names.length === 2) return `${names[0]} and ${names[1]}`
  return `${names.slice(0, -1).join(", ")}, and ${names[names.length - 1]}`
}

/** First-run hint card at the top of the Modern dashboard (macOS "Welcome to QuotaBar"). */
export function WelcomeHint({
  enabledNames,
  onOpenCustomize,
  onDismiss,
}: {
  enabledNames: string[]
  onOpenCustomize: () => void
  onDismiss: () => void
}) {
  const names = joinNames(enabledNames)
  return (
    <GroupCard className="relative flex gap-3 px-[14px] py-[12px]">
      <SlidersHorizontal className="mt-px size-[18px] shrink-0 text-foreground/80" strokeWidth={1.75} aria-hidden />
      <div className="min-w-0 flex-1 pr-4">
        <p className="text-[13px] font-semibold">Welcome to QuotaBar</p>
        <p className="mt-0.5 text-[12px] leading-[1.35] text-foreground/75">
          {names ? `${names} ${enabledNames.length === 1 ? "is" : "are"} on. ` : ""}
          Customize shows every supported provider; you choose what to turn on.
        </p>
        <button
          type="button"
          onClick={onOpenCustomize}
          className="mt-2 rounded-[7px] bg-control px-[10px] py-[3px] text-[12px] font-medium transition-colors hover:bg-control-hover"
        >
          Open Customize
        </button>
      </div>
      <button
        type="button"
        aria-label="Dismiss"
        onClick={onDismiss}
        className="absolute right-[10px] top-[10px] flex size-6 items-center justify-center rounded-full text-muted-foreground transition-colors hover:bg-control hover:text-foreground"
      >
        <X className="size-4" aria-hidden />
      </button>
    </GroupCard>
  )
}
