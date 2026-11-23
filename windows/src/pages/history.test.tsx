import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, expect, it, vi } from "vitest"
import { HistoryView } from "@/pages/history"

const { reportDays } = vi.hoisted(() => ({ reportDays: vi.fn() }))
vi.mock("@/hooks/use-history-report-days", () => ({ useHistoryReportDays: reportDays }))

afterEach(cleanup)

it.each([
  [null, false],
  [3100.02, false],
  [2900, true],
])("shows estimate %s only when it would add information", (apiEstimateUsd, visible) => {
  reportDays.mockReturnValue({
    rows: [{ instanceId: "cursor", dayKey: "2020-01-01", totalTokens: 25, costUsd: 3099.61, apiEstimateUsd }],
    loading: false,
    failed: false,
  })
  render(<HistoryView plugins={[{ meta: { id: "cursor", name: "Cursor" } } as never]} persistEnabled />)
  expect(screen.getByText("Lifetime")).toBeInTheDocument()
  expect(Boolean(screen.queryByText("At Public API Rates (Est.)"))).toBe(visible)
})
