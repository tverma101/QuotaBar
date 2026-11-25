import {
  DndContext,
  KeyboardSensor,
  PointerSensor,
  closestCenter,
  type DragEndEvent,
  useSensor,
  useSensors,
} from "@dnd-kit/core"
import {
  SortableContext,
  arrayMove,
  sortableKeyboardCoordinates,
  useSortable,
  verticalListSortingStrategy,
} from "@dnd-kit/sortable"
import { CSS } from "@dnd-kit/utilities"
import { ChevronRight, Settings } from "lucide-react"
import { GripLines, GroupCard, MacSwitch, ProviderGlyph, SectionHeader } from "@/components/modern/mac-ui"
import { displayMetricLabel } from "@/lib/metric-display"
import { cn } from "@/lib/utils"

export type CustomizeProvider = {
  id: string
  name: string
  iconUrl?: string
  enabled: boolean
  metricCount: number
}

export type CustomizeMetric = {
  id: string
  lineLabel: string
  placed: boolean
  onDemand: boolean
}

function useListSensors() {
  return useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 4 } }),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }),
  )
}

function rowPadding(compact?: boolean) {
  return compact ? "py-[6px]" : "py-[9px]"
}

function SortableProviderRow({
  provider,
  compact,
  onToggle,
  onOpen,
}: {
  provider: CustomizeProvider
  compact?: boolean
  onToggle: () => void
  onOpen: () => void
}) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({ id: provider.id })
  return (
    <li
      ref={setNodeRef}
      style={{ transform: CSS.Transform.toString(transform), transition }}
      className={cn(
        "relative flex items-center gap-[10px] px-[12px] transition-colors hover:bg-surface-hover",
        compact ? "py-[4px]" : "py-[6px]",
        isDragging && "z-10 rounded-[10px] bg-surface-hover shadow-lg",
      )}
    >
      <button
        type="button"
        className="-m-1 shrink-0 cursor-grab touch-none p-1 active:cursor-grabbing"
        aria-label={`Reorder ${provider.name}`}
        {...attributes}
        {...listeners}
      >
        <GripLines />
      </button>
      <button
        type="button"
        onClick={onOpen}
        className={cn(
          "flex min-w-0 flex-1 items-center gap-[10px] text-left outline-none",
          !provider.enabled && "opacity-45",
        )}
        aria-label={`${provider.name} metrics`}
      >
        <ProviderGlyph iconUrl={provider.iconUrl} size={compact ? 15 : 17} className="text-foreground" />
        <span className="min-w-0 flex-1">
          <span className={cn("block truncate font-semibold", compact ? "text-[13px]" : "text-[14px]")}>{provider.name}</span>
          <span className={cn("block text-muted-foreground", compact ? "text-[11px]" : "text-[12px]")}>
            {provider.metricCount} {provider.metricCount === 1 ? "metric" : "metrics"}
          </span>
        </span>
      </button>
      <MacSwitch
        checked={provider.enabled}
        onCheckedChange={onToggle}
        label={`Show ${provider.name}`}
        compact={compact}
        className={cn(!provider.enabled && "opacity-60")}
      />
      <button type="button" onClick={onOpen} className={cn("-mr-1 shrink-0 p-1 text-muted-foreground/70", !provider.enabled && "opacity-60")} aria-hidden tabIndex={-1}>
        <ChevronRight className="size-4" strokeWidth={2.25} />
      </button>
    </li>
  )
}

export function CustomizeProviderList({
  providers,
  compact,
  onToggleProvider,
  onReorder,
  onOpenProvider,
  onOpenSettings,
}: {
  providers: CustomizeProvider[]
  compact?: boolean
  onToggleProvider: (id: string) => void
  onReorder: (order: string[]) => void
  onOpenProvider: (id: string) => void
  onOpenSettings: () => void
}) {
  const sensors = useListSensors()
  const ids = providers.map((p) => p.id)
  const onDragEnd = (event: DragEndEvent) => {
    const { active, over } = event
    if (!over || active.id === over.id) return
    const from = ids.indexOf(String(active.id))
    const to = ids.indexOf(String(over.id))
    if (from >= 0 && to >= 0) onReorder(arrayMove(ids, from, to))
  }

  return (
    <div className={cn("flex flex-col", compact ? "gap-[8px]" : "gap-[14px]")}>
      <GroupCard className="overflow-hidden py-[4px]">
        <DndContext sensors={sensors} collisionDetection={closestCenter} onDragEnd={onDragEnd}>
          <SortableContext items={ids} strategy={verticalListSortingStrategy}>
            <ul aria-label="Providers">
              {providers.map((provider) => (
                <SortableProviderRow
                  key={provider.id}
                  provider={provider}
                  compact={compact}
                  onToggle={() => onToggleProvider(provider.id)}
                  onOpen={() => onOpenProvider(provider.id)}
                />
              ))}
            </ul>
          </SortableContext>
        </DndContext>
      </GroupCard>
      <GroupCard>
        <button
          type="button"
          onClick={onOpenSettings}
          className={cn("flex w-full items-center gap-[12px] rounded-[12px] px-[14px] text-left transition-colors hover:bg-surface-hover", rowPadding(compact))}
        >
          <Settings className="size-[18px] shrink-0 text-foreground/80" strokeWidth={1.75} aria-hidden />
          <span className="min-w-0 flex-1">
            <span className={cn("block font-semibold", compact ? "text-[13px]" : "text-[14px]")}>Settings</span>
            <span className={cn("block truncate text-muted-foreground", compact ? "text-[11px]" : "text-[12px]")}>
              Notifications, appearance and more
            </span>
          </span>
          <ChevronRight className="size-4 shrink-0 text-muted-foreground/70" strokeWidth={2.25} aria-hidden />
        </button>
      </GroupCard>
    </div>
  )
}

const DIVIDER_ID = "__on-demand__"

function SortableMetricRow({
  metric,
  compact,
  roundTop,
  roundBottom,
  onTogglePlaced,
}: {
  metric: CustomizeMetric
  compact?: boolean
  roundTop: boolean
  roundBottom: boolean
  onTogglePlaced: (placed: boolean) => void
}) {
  const label = displayMetricLabel(metric.lineLabel)
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({ id: metric.id })
  return (
    <li
      ref={setNodeRef}
      style={{ transform: CSS.Transform.toString(transform), transition }}
      className={cn(
        "relative flex items-center gap-[10px] bg-surface px-[12px]",
        rowPadding(compact),
        roundTop && "rounded-t-[12px] pt-[12px]",
        roundBottom && "rounded-b-[12px] pb-[12px]",
        isDragging && "z-10 rounded-[10px] bg-surface-hover shadow-lg",
      )}
    >
      <button
        type="button"
        className="-m-1 shrink-0 cursor-grab touch-none p-1 active:cursor-grabbing"
        aria-label={`Reorder ${label}`}
        {...attributes}
        {...listeners}
      >
        <GripLines />
      </button>
      <span className={cn("min-w-0 flex-1 truncate", compact ? "text-[13px]" : "text-[14px]", !metric.placed && "text-muted-foreground")}>
        {label}
      </span>
      <MacSwitch checked={metric.placed} onCheckedChange={onTogglePlaced} label={`Show ${label}`} compact={compact} />
    </li>
  )
}

function SectionDivider({ compact }: { compact?: boolean }) {
  const { setNodeRef } = useSortable({ id: DIVIDER_ID, disabled: true })
  return (
    <li ref={setNodeRef} aria-hidden className={compact ? "pt-[8px]" : "pt-[14px]"}>
      <SectionHeader>On Demand</SectionHeader>
    </li>
  )
}

/**
 * One provider's metrics, split like macOS into Always Visible and On Demand.
 * A single sortable list with a fixed divider: dragging a row across the
 * "On Demand" header moves it between the sections.
 */
export function CustomizeProviderDetail({
  metrics,
  compact,
  onTogglePlaced,
  onArrange,
}: {
  metrics: CustomizeMetric[]
  compact?: boolean
  onTogglePlaced: (metricId: string, placed: boolean) => void
  onArrange: (order: string[], onDemandIds: string[]) => void
}) {
  const sensors = useListSensors()
  const always = metrics.filter((m) => !m.onDemand)
  const onDemand = metrics.filter((m) => m.onDemand)
  const ids = [...always.map((m) => m.id), DIVIDER_ID, ...onDemand.map((m) => m.id)]

  const onDragEnd = (event: DragEndEvent) => {
    const { active, over } = event
    if (!over || active.id === over.id) return
    const from = ids.indexOf(String(active.id))
    const to = ids.indexOf(String(over.id))
    if (from < 0 || to < 0) return
    const next = arrayMove(ids, from, to)
    const divider = next.indexOf(DIVIDER_ID)
    onArrange(
      next.filter((id) => id !== DIVIDER_ID),
      next.slice(divider + 1),
    )
  }

  if (metrics.length === 0) {
    return <p className="py-8 text-center text-[13px] text-muted-foreground">This provider has no metrics yet.</p>
  }

  return (
    <div>
      <SectionHeader>Always Visible</SectionHeader>
      <DndContext sensors={sensors} collisionDetection={closestCenter} onDragEnd={onDragEnd}>
        <SortableContext items={ids} strategy={verticalListSortingStrategy}>
          <ul aria-label="Metrics">
            {always.length === 0 ? (
              <li className="rounded-[12px] bg-surface px-[14px] py-[10px] text-[12px] text-muted-foreground">
                Drag a metric here to keep it above the fold.
              </li>
            ) : null}
            {always.map((metric, i) => (
              <SortableMetricRow
                key={metric.id}
                metric={metric}
                compact={compact}
                roundTop={i === 0}
                roundBottom={i === always.length - 1}
                onTogglePlaced={(placed) => onTogglePlaced(metric.id, placed)}
              />
            ))}
            <SectionDivider compact={compact} />
            {onDemand.length === 0 ? (
              <li className="rounded-[12px] bg-surface px-[14px] py-[10px] text-[12px] text-muted-foreground">
                Drag a metric here to show it only when the provider is expanded.
              </li>
            ) : null}
            {onDemand.map((metric, i) => (
              <SortableMetricRow
                key={metric.id}
                metric={metric}
                compact={compact}
                roundTop={i === 0}
                roundBottom={i === onDemand.length - 1}
                onTogglePlaced={(placed) => onTogglePlaced(metric.id, placed)}
              />
            ))}
          </ul>
        </SortableContext>
      </DndContext>
      <p className="px-2 pt-2 text-[11px] leading-[1.35] text-muted-foreground">
        On Demand metrics sit behind the provider’s arrow on the dashboard. Drag a metric between the sections to move
        it.
      </p>
    </div>
  )
}
