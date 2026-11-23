import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, expect, it, vi } from "vitest"
import { invoke } from "@tauri-apps/api/core"
import { CodexAutoResetSetting } from "./codex-auto-reset-setting"

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }))
afterEach(() => {
  cleanup()
  vi.resetAllMocks()
})

it("does not opt in without consent and leaves the setting off when saving fails", async () => {
  vi.mocked(invoke).mockResolvedValueOnce(false).mockRejectedValueOnce(new Error("unavailable"))
  render(<CodexAutoResetSetting />)
  const toggle = screen.getByRole("checkbox", { name: "Auto-Use Expiring Codex Resets" })
  await waitFor(() => expect(toggle).toBeEnabled())
  expect(toggle).not.toBeChecked()
  expect(invoke).toHaveBeenCalledTimes(1)
  fireEvent.click(toggle)
  expect(await screen.findByRole("alert")).toHaveTextContent("Could not save")
  expect(invoke).toHaveBeenLastCalledWith("set_codex_auto_reset_enabled", { value: true })
  expect(toggle).not.toBeChecked()
})
