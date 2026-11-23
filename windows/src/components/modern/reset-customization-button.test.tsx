import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it, vi } from "vitest"
import { ResetCustomizationButton } from "./reset-customization-button"

describe("ResetCustomizationButton", () => {
  it("does not reset until the user confirms", async () => {
    const user = userEvent.setup()
    const reset = vi.fn()
    render(<ResetCustomizationButton onReset={reset} />)
    const trigger = screen.getByRole("button", { name: "Reset All Customization" })

    await user.click(trigger)
    await user.click(screen.getByRole("button", { name: "Cancel" }))
    expect(reset).not.toHaveBeenCalled()

    await user.click(trigger)
    await user.click(screen.getByRole("button", { name: "Reset All", exact: true }))
    expect(reset).toHaveBeenCalledOnce()
  })
})
