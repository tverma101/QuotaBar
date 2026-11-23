import {
  DndContext, KeyboardSensor, PointerSensor, closestCenter,
  useDroppable, useSensor, useSensors, type DragEndEvent,
} from "@dnd-kit/core"
import {
  SortableContext, arrayMove, sortableKeyboardCoordinates, useSortable, verticalListSortingStrategy,
} from "@dnd-kit/sortable"
import { CSS } from "@dnd-kit/utilities"
import { Switch } from "@base-ui/react/switch"
import { ChevronRight, GripHorizontal, Settings, Star } from "lucide-react"
import type { ReactNode } from "react"
import { useShallow } from "zustand/react/shallow"
import type { SettingsPluginState } from "@/hooks/app/use-settings-plugin-list"
import type { MetricDescriptor } from "@/lib/metric-registry"
import { cn } from "@/lib/utils"
import { useModernLayoutStore } from "@/stores/modern-layout-store"

const card = "rounded-xl bg-muted/70"

function CustomizeSwitch(props: Switch.Root.Props) {
  return (
    <Switch.Root {...props} className="relative h-5 w-11 shrink-0 rounded-full bg-foreground/10 outline-none focus-visible:ring-2 focus-visible:ring-ring data-checked:bg-[#007aff] data-disabled:opacity-50">
      <Switch.Thumb className="absolute left-0.5 top-0.5 h-4 w-6 rounded-full bg-white shadow-sm transition-transform data-checked:translate-x-4 motion-reduce:transition-none" />
    </Switch.Root>
  )
}

type CustomizeViewProps = {
  providers: SettingsPluginState[]
  descriptors: MetricDescriptor[]
  placedMetricIds: string[]
  providerId: string | null
  onOpenProvider: (id: string) => void
  onSettings: () => void
  onToggleProvider: (id: string) => void
  onTogglePlaced: (metricId: string, enabled: boolean) => void
  onSetProviderMetricsEnabled: (id: string, enabled: boolean) => void
  onProviderReorder: (order: string[]) => void
  recordUndo: (undo: () => void) => void
}

const alwaysDrop = "bucket:always"
const demandDrop = "bucket:on-demand"

export function moveCustomizeMetric(
  always: string[], demand: string[], active: string, over: string,
): { order: string[]; onDemand: string[] } | null {
  if (active === over) return null
  const source = always.includes(active) ? always : demand.includes(active) ? demand : null
  const target = over === alwaysDrop || always.includes(over) ? always
    : over === demandDrop || demand.includes(over) ? demand : null
  if (!source || !target) return null
  if (target === source && target.includes(over)) {
    const next = arrayMove(target, target.indexOf(active), target.indexOf(over))
    return source === always ? { order: [...next, ...demand], onDemand: demand }
      : { order: [...always, ...next], onDemand: next }
  }
  const nextAlways = always.filter((id) => id !== active)
  const nextDemand = demand.filter((id) => id !== active)
  const bucket = target === always ? nextAlways : nextDemand
  const index = bucket.indexOf(over)
  bucket.splice(index < 0 ? bucket.length : index, 0, active)
  return { order: [...nextAlways, ...nextDemand], onDemand: nextDemand }
}

function SortableRow({ id, label, disabled, children }: {
  id: string; label: string; disabled?: boolean; children: ReactNode
}) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({
    id, disabled: Boolean(disabled),
  })
  return (
    <li ref={setNodeRef} style={{ transform: CSS.Transform.toString(transform), transition }}
      className={cn("relative flex min-h-8 items-center gap-2 px-3 py-1.5 text-xs", isDragging && "z-10 bg-card shadow-sm")}>
      <button type="button" disabled={disabled} aria-label={`Reorder ${label}`}
        className="touch-none text-muted-foreground hover:text-foreground disabled:opacity-40"
        {...attributes} {...listeners}>
        <GripHorizontal aria-hidden="true" className="size-4" />
      </button>
      {children}
    </li>
  )
}

function MetricBucket({ title, id, ids, children }: {
  title: string; id: string; ids: string[]; children: ReactNode
}) {
  const { setNodeRef, isOver } = useDroppable({ id, disabled: ids.length !== 0 })
  return (
    <section className="space-y-1">
      <h2 className="px-2 text-xs font-semibold text-muted-foreground">{title}</h2>
      <SortableContext items={ids} strategy={verticalListSortingStrategy}>
        {ids.length > 0 ? <ul className={card}>{children}</ul> : (
          <div ref={setNodeRef} className={cn(card, "p-2", isOver && "ring-1 ring-primary")}>
            <p className="grid h-[30px] place-items-center rounded-lg border border-dashed text-xs text-muted-foreground">Drag metrics here</p>
          </div>
        )}
      </SortableContext>
    </section>
  )
}

export function CustomizeView({
  providers, descriptors, placedMetricIds, providerId, onOpenProvider, onSettings,
  onToggleProvider, onTogglePlaced, onSetProviderMetricsEnabled, onProviderReorder, recordUndo,
}: CustomizeViewProps) {
  const layout = useModernLayoutStore(useShallow((s) => ({
    metricOrder: s.metricOrderByProvider,
    onDemand: s.onDemandMetricIds,
    pinned: s.pinnedMetricIds,
    pinNotice: s.pinLimitNotice,
    togglePin: s.togglePin,
    setPlacement: s.setMetricPlacement,
  })))
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 4 } }),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }),
  )
  const provider = providers.find(({ id }) => id === providerId)
  const enabledIds = providers.filter(({ enabled }) => enabled).map(({ id }) => id)

  if (!provider) {
    const counts = new Map<string, number>()
    for (const { pluginId } of descriptors) counts.set(pluginId, (counts.get(pluginId) ?? 0) + 1)
    const handleProviderDragEnd = ({ active, over }: DragEndEvent) => {
      if (!over || active.id === over.id) return
      const oldIndex = enabledIds.indexOf(String(active.id))
      const newIndex = enabledIds.indexOf(String(over.id))
      if (oldIndex < 0 || newIndex < 0) return
      const reordered = arrayMove(enabledIds, oldIndex, newIndex)
      const previous = providers.map(({ id }) => id)
      recordUndo(() => onProviderReorder(previous))
      let next = 0
      onProviderReorder(providers.map(({ id, enabled }) => enabled ? reordered[next++] : id))
    }
    return (
      <div className="space-y-2 pb-2">
        <DndContext sensors={sensors} collisionDetection={closestCenter} onDragEnd={handleProviderDragEnd}>
          <SortableContext items={enabledIds} strategy={verticalListSortingStrategy}>
            <ul className={card}>
              {providers.map(({ id, name, enabled }) => (
                <SortableRow key={id} id={id} label={name} disabled={!enabled}>
                  <button type="button" onClick={() => onOpenProvider(id)} className={cn("flex min-h-9 flex-1 flex-col justify-center text-left leading-tight after:absolute after:inset-y-0 after:right-0 after:w-6", !enabled && "opacity-60")}>
                    <span className="truncate text-sm font-semibold">{name}</span>
                    <span className="text-[11px] text-muted-foreground">{counts.get(id) ?? 0} metrics</span>
                    <ChevronRight aria-hidden="true" className="absolute right-2 top-1/2 size-3.5 -translate-y-1/2 text-muted-foreground" />
                  </button>
                  <div className="mr-4 flex">
                    <CustomizeSwitch checked={enabled} aria-label={`Enable ${name}`} onCheckedChange={() => {
                      recordUndo(() => onToggleProvider(id))
                      onToggleProvider(id)
                    }} />
                  </div>
                </SortableRow>
              ))}
            </ul>
          </SortableContext>
        </DndContext>
        <button type="button" onClick={onSettings} className={cn(card, "flex w-full items-center gap-2 p-3 text-left text-xs")}>
          <Settings aria-hidden="true" className="size-4" />
          <span><strong>Settings</strong><br /><span className="text-muted-foreground">Notifications, Appearance and More</span></span>
        </button>
      </div>
    )
  }

  const byId = new Map(descriptors.filter((d) => d.pluginId === provider.id).map((d) => [d.id, d]))
  const existingOrder = (layout.metricOrder[provider.id] ?? []).filter((id) => byId.has(id))
  const order = [...existingOrder, ...[...byId.keys()].filter((id) => !existingOrder.includes(id))]
  const demand = order.filter((id) => layout.onDemand.includes(id))
  const always = order.filter((id) => !layout.onDemand.includes(id))
  const move = (active: string, over: string) => {
    const next = moveCustomizeMetric(always, demand, active, over)
    if (!next) return
    recordUndo(() => layout.setPlacement(provider.id, order, demand))
    layout.setPlacement(provider.id, next.order, next.onDemand)
  }
  const renderMetrics = (ids: string[]) => ids.map((id) => {
    const metric = byId.get(id)!
    const pinned = layout.pinned.includes(id)
    const placed = placedMetricIds.includes(id)
    return (
      <SortableRow key={id} id={id} label={metric.lineLabel}>
        <span className="flex-1 truncate">{metric.lineLabel}</span>
        {(metric.bounded || pinned) && (
          <button type="button" className="text-muted-foreground hover:text-foreground"
            aria-label={`Pin ${metric.lineLabel}`} aria-pressed={pinned}
            onClick={() => {
              if (layout.togglePin(id)) recordUndo(() => layout.togglePin(id))
            }}>
            <Star className={cn("size-4", pinned && "fill-[#007aff] text-[#007aff]")} aria-hidden="true" />
          </button>
        )}
        <CustomizeSwitch checked={placed} disabled={!provider.enabled} aria-label={`Show ${metric.lineLabel}`}
          onCheckedChange={(checked) => {
            recordUndo(() => onTogglePlaced(id, placed))
            onTogglePlaced(id, checked === true)
          }} />
      </SortableRow>
    )
  })

  return (
    <div className="space-y-2 pb-2">
      {provider.enabled && order.length > 0 && (
        <button type="button" className="rounded-md border px-2 py-1 text-xs hover:bg-muted"
          onClick={() => onSetProviderMetricsEnabled(provider.id, !order.every((id) => placedMetricIds.includes(id)))}>
          {order.every((id) => placedMetricIds.includes(id)) ? "Hide All" : "Show All"}
        </button>
      )}
      <DndContext sensors={sensors} collisionDetection={closestCenter}
        onDragEnd={({ active, over }) => { if (over) move(String(active.id), String(over.id)) }}>
        <MetricBucket title="Always Visible" id={alwaysDrop} ids={always}>{renderMetrics(always)}</MetricBucket>
        <MetricBucket title="On Demand" id={demandDrop} ids={demand}>{renderMetrics(demand)}</MetricBucket>
      </DndContext>
      {layout.pinNotice && <p role="status" className="px-2 text-xs text-muted-foreground">{layout.pinNotice}</p>}
    </div>
  )
}
