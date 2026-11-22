import { describe, expect, it } from "vitest"
import { multiAccountCredentialsGuideUrl } from "@/lib/docs-links"

describe("multiAccountCredentialsGuideUrl", () => {
  it("points at the fork repo blob path for the tutorial", () => {
    expect(multiAccountCredentialsGuideUrl()).toBe(
      "https://github.com/tverma101/QuotaBar/blob/HEAD/docs/providers/multi-account-credentials.md"
    )
  })
})
