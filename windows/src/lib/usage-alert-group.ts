/**
 * Groups usage alerts that fire in the same refresh pass into one notification,
 * like the macOS app stacks simultaneous alerts in one notification thread.
 * Title is the verdict ("Almost Out", "Will Run Out"), the subtitle names the
 * provider and metric, and the body explains the verdict.
 */
export type UsageAlertKind = "lowRemaining" | "pace"

export type UsageAlertEvent = {
  key: string
  kind: UsageAlertKind
  providerId: string
  providerName: string
  metricLabel: string
  body: string
}

export type GroupedUsageAlert = {
  title: string
  subtitle: string
  body: string
  providerIds: string[]
}

export const USAGE_ALERT_GROUP_DELAY_MS = 1500

export function usageAlertTitle(kind: UsageAlertKind): string {
  return kind === "lowRemaining" ? "Almost Out" : "Will Run Out"
}

function subject(event: UsageAlertEvent): string {
  return `${event.providerName} ${event.metricLabel}`
}

export function groupUsageAlerts(events: UsageAlertEvent[]): GroupedUsageAlert | null {
  const unique = [...new Map(events.map((event) => [event.key, event])).values()]
  if (unique.length === 0) return null
  const providerIds = [...new Set(unique.map((event) => event.providerId))]
  if (unique.length === 1) {
    const [event] = unique
    return {
      title: usageAlertTitle(event.kind),
      subtitle: subject(event),
      body: event.body,
      providerIds,
    }
  }
  const kinds = new Set(unique.map((event) => event.kind))
  return {
    title: kinds.size === 1 ? usageAlertTitle(unique[0].kind) : `${unique.length} Usage Alerts`,
    subtitle: [...new Set(unique.map(subject))].join(", "),
    body: unique
      .map((event) =>
        kinds.size === 1 ? `${subject(event)}: ${event.body}` : `${usageAlertTitle(event.kind)}: ${subject(event)}`,
      )
      .join("\n"),
    providerIds,
  }
}

export function createUsageAlertBatcher(
  deliver: (alert: GroupedUsageAlert) => void,
  delayMs = USAGE_ALERT_GROUP_DELAY_MS,
) {
  let pending: UsageAlertEvent[] = []
  let timer: ReturnType<typeof setTimeout> | null = null
  const flush = () => {
    timer = null
    const grouped = groupUsageAlerts(pending)
    pending = []
    if (grouped) deliver(grouped)
  }
  return {
    add(event: UsageAlertEvent) {
      pending.push(event)
      if (timer == null) timer = setTimeout(flush, delayMs)
    },
    flush() {
      if (timer != null) clearTimeout(timer)
      flush()
    },
    cancel() {
      if (timer != null) clearTimeout(timer)
      timer = null
      pending = []
    },
  }
}
