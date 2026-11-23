import { describe, expect, it } from "vitest"
import { moveCustomizeMetric } from "@/components/modern/customize-view"

describe("moveCustomizeMetric", () => {
  it("moves into an empty bucket and back without losing other placements", () => {
    expect(moveCustomizeMetric(["a", "b"], [], "b", "bucket:on-demand")).toEqual({
      order: ["a", "b"],
      onDemand: ["b"],
    })
    expect(moveCustomizeMetric(["a"], ["b", "c"], "b", "a")).toEqual({
      order: ["b", "a", "c"],
      onDemand: ["c"],
    })
  })

  it("reorders inside a bucket and rejects an unrelated drop target", () => {
    expect(moveCustomizeMetric(["a"], ["b", "c"], "b", "c")).toEqual({
      order: ["a", "c", "b"],
      onDemand: ["c", "b"],
    })
    expect(moveCustomizeMetric(["a"], ["b"], "a", "unknown")).toBeNull()
  })
})
