import { describe, expect, it } from "vitest"
import { nextUpdateLabel } from "@/components/modern/modern-footer"

describe("nextUpdateLabel", () => {
  it.each([
    [null, "Auto Update Paused"],
    [-2000, "Next update in 0s"],
    [1, "Next update in 1s"],
    [59000, "Next update in 59s"],
    [60000, "Next update in 1m"],
    [60001, "Next update in 2m"],
  ] as const)("formats a countdown offset of %s", (offset, expected) => {
    const now = 100_000
    expect(nextUpdateLabel(offset === null ? null : now + offset, now)).toBe(expected)
  })
})
