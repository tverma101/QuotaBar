import { cleanup, render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { afterEach, expect, it, vi } from "vitest"
import { PanelOptions } from "@/components/modern/panel-options"

afterEach(cleanup)

it("opens the ordered Options menu from the keyboard and activates History", async () => {
  const user = userEvent.setup()
  const onHistory = vi.fn()
  render(<PanelOptions onHistory={onHistory} onCustomize={vi.fn()} onSettings={vi.fn()} onAbout={vi.fn()} onQuit={vi.fn()} />)

  await user.tab()
  await user.keyboard("{Enter}")
  expect(screen.getAllByRole("menuitem").map((item) => item.textContent)).toEqual([
    "Customize", "Usage History", "Settings", "About QuotaBar", "Quit QuotaBar",
  ])
  await user.click(screen.getByRole("menuitem", { name: "Usage History" }))
  expect(onHistory).toHaveBeenCalledOnce()
})
