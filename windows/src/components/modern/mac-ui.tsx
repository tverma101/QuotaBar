import type { CSSProperties, ReactNode } from "react"
import { ChevronLeft, RotateCcw } from "lucide-react"
import { cn } from "@/lib/utils"

/**
 * Small building blocks for the Modern layout, matching the macOS panel:
 * a 44 px navigation bar with a round back button, inset grouped cards,
 * pill switches and monochrome provider glyphs.
 */

export function NavBar({
  title,
  onBack,
  onReset,
  resetLabel = "Reset to Default",
}: {
  title: string
  onBack: () => void
  onReset?: () => void
  resetLabel?: string
}) {
  return (
    <header className="relative flex h-11 shrink-0 items-center justify-center border-b border-hairline bg-chrome px-3">
      <RoundButton className="absolute left-3" label="Back" onClick={onBack}>
        <ChevronLeft className="size-[18px]" strokeWidth={2.25} />
      </RoundButton>
      <h2 className="max-w-[200px] truncate text-[15px] font-bold tracking-[-0.01em]">{title}</h2>
      {onReset ? (
        <RoundButton className="absolute right-3" label={resetLabel} onClick={onReset}>
          <RotateCcw className="size-[15px]" strokeWidth={2.25} />
        </RoundButton>
      ) : null}
    </header>
  )
}

export function RoundButton({
  label,
  onClick,
  className,
  children,
}: {
  label: string
  onClick: () => void
  className?: string
  children: ReactNode
}) {
  return (
    <button
      type="button"
      aria-label={label}
      onClick={onClick}
      className={cn(
        "flex size-7 items-center justify-center rounded-full bg-control text-foreground/90 outline-none transition-colors hover:bg-control-hover focus-visible:ring-2 focus-visible:ring-ring",
        className,
      )}
    >
      {children}
    </button>
  )
}

export function MacSwitch({
  checked,
  onCheckedChange,
  label,
  disabled,
  compact,
  className,
}: {
  checked: boolean
  onCheckedChange: (checked: boolean) => void
  label: string
  disabled?: boolean
  compact?: boolean
  className?: string
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      disabled={disabled}
      onClick={(event) => {
        event.stopPropagation()
        onCheckedChange(!checked)
      }}
      className={cn(
        "relative shrink-0 rounded-full outline-none transition-colors duration-150 focus-visible:ring-2 focus-visible:ring-ring disabled:opacity-40",
        compact ? "h-[19px] w-[36px]" : "h-[22px] w-[42px]",
        checked ? "bg-switch-on" : "bg-switch-off",
        className,
      )}
    >
      <span
        aria-hidden
        className={cn(
          "absolute top-1/2 -translate-y-1/2 rounded-full shadow-[0_1px_2px_rgba(0,0,0,0.25)] transition-[left,background-color] duration-150",
          compact ? "h-[13px] w-[20px]" : "h-[16px] w-[24px]",
          checked
            ? cn("bg-[var(--switch-knob-on)]", compact ? "left-[13px]" : "left-[15px]")
            : "left-[3px] bg-[var(--switch-knob)]",
        )}
      />
    </button>
  )
}

export function GroupCard({
  children,
  className,
  style,
}: {
  children: ReactNode
  className?: string
  style?: CSSProperties
}) {
  return (
    <div className={cn("rounded-[12px] bg-surface", className)} style={style}>
      {children}
    </div>
  )
}

export function SectionHeader({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <h3 className={cn("px-2 pb-1.5 text-[12px] font-semibold text-muted-foreground", className)}>
      {children}
    </h3>
  )
}

/** Provider icon drawn as a single-color glyph (macOS template image) via a CSS mask. */
export function ProviderGlyph({
  iconUrl,
  size = 16,
  className,
}: {
  iconUrl?: string
  size?: number
  className?: string
}) {
  if (!iconUrl) {
    return <span aria-hidden className={cn("shrink-0 rounded-[3px] bg-current opacity-60", className)} style={{ width: size, height: size }} />
  }
  const mask = `url("${iconUrl}") center / contain no-repeat`
  return (
    <span
      aria-hidden
      className={cn("shrink-0 bg-current", className)}
      style={{ width: size, height: size, mask, WebkitMask: mask }}
    />
  )
}

/** macOS "line.3.horizontal" drag handle. */
export function GripLines({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 16 16" aria-hidden className={cn("size-4 text-grip", className)}>
      <path d="M2.5 4.5h11M2.5 8h11M2.5 11.5h11" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
    </svg>
  )
}
