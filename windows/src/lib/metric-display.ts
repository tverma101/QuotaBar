/**
 * Presentation helpers shared by the Modern dashboard and Customize: the
 * title-cased label a row shows, and which metrics sit behind a provider's
 * "On Demand" caret by default (ported from macOS `DefaultLayout.expandedMetricIDs`).
 */

const LABEL_ALIASES: Record<string, string> = {
  "Extra usage spent": "Extra Usage",
  "Grok Bot usage": "Grok Bot",
  "On-demand": "On-Demand",
}

const SMALL_WORDS = new Set(["a", "an", "and", "as", "at", "by", "for", "in", "of", "on", "or", "the", "to", "vs"])

/** "Total usage" → "Total Usage"; model ids and words with digits stay as written. */
export function displayMetricLabel(label: string): string {
  const alias = LABEL_ALIASES[label]
  if (alias) return alias
  return label
    .split(" ")
    .map((word, index) => {
      if (!/^[a-z][a-z'-]*$/.test(word)) return word
      if (index > 0 && SMALL_WORDS.has(word)) return word
      return word.charAt(0).toUpperCase() + word.slice(1)
    })
    .join(" ")
}

const SPEND_ROW_LABELS = new Set(["Today", "Yesterday", "Last 30 Days", "This Week", "This Month"])

/** Providers whose spend rows stay above the fold (macOS keeps Freebuff fully visible). */
const SPEND_ROWS_ALWAYS_VISIBLE = new Set(["freebuff"])

const ON_DEMAND_BY_PROVIDER: Record<string, string[]> = {
  antigravity: ["Argon Weekly", "Session — Claude and GPT Models", "Weekly — Claude and GPT Models"],
  claude: ["Sonnet", "Claude Design", "Rate Limit Resets"],
  codex: ["Spark", "Spark Weekly", "Reviews", "Credits", "Rate Limit Resets"],
  cursor: ["Grok Bot usage", "On-demand", "Requests", "Credits"],
  copilot: ["Chat", "Completions"],
  devin: ["Extra usage balance"],
  grok: ["Pay as you go"],
  openrouter: ["Key Limit"],
  zai: ["Web Searches"],
}

export function isDefaultOnDemand(baseProviderId: string, lineLabel: string): boolean {
  if (SPEND_ROW_LABELS.has(lineLabel)) return !SPEND_ROWS_ALWAYS_VISIBLE.has(baseProviderId)
  return ON_DEMAND_BY_PROVIDER[baseProviderId]?.includes(lineLabel) ?? false
}

/** A user override (from Customize) wins over the provider default. */
export function isMetricOnDemand(
  metricIdValue: string,
  baseProviderId: string,
  lineLabel: string,
  overrides: Record<string, boolean>,
): boolean {
  const override = overrides[metricIdValue]
  if (typeof override === "boolean") return override
  return isDefaultOnDemand(baseProviderId, lineLabel)
}
