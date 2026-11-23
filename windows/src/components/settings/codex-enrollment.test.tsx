import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { invoke } from "@tauri-apps/api/core"
import { open } from "@tauri-apps/plugin-dialog"
import { CodexEnrollment } from "./codex-enrollment"

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }))
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: vi.fn() }))
afterEach(() => {
  cleanup()
  vi.resetAllMocks()
})

describe("Codex enrollment", () => {
  it("starts the official browser flow and adds the registered account", async () => {
    const account = { instanceId: "codex:registered", label: "Work" }
    let complete: (result: typeof account) => void = () => {}
    vi.mocked(invoke).mockImplementation((command) => {
      if (command === "sign_in_to_codex") return new Promise((resolve) => {
        complete = (result) => resolve(result as never)
      })
      return Promise.resolve(undefined as never)
    })
    const onRegistered = vi.fn()
    render(<CodexEnrollment label="Work" onRegistered={onRegistered} />)
    fireEvent.click(screen.getByRole("button", { name: "Sign In to Codex…" }))
    expect(invoke).toHaveBeenCalledWith("sign_in_to_codex", { label: "Work" })
    expect(screen.getByRole("status")).toHaveTextContent("Finish signing in")
    expect(onRegistered).not.toHaveBeenCalled()
    complete(account)
    await waitFor(() => expect(onRegistered).toHaveBeenCalledWith(account))
  })

  it("imports a chosen home and shows native validation errors", async () => {
    vi.mocked(open).mockResolvedValue("C:/Codex Work")
    vi.mocked(invoke).mockRejectedValue("Unidentified Codex account.")
    const onRegistered = vi.fn()
    render(<CodexEnrollment label="Work" onRegistered={onRegistered} />)
    fireEvent.click(screen.getByRole("button", { name: "Use Existing Codex Home…" }))
    expect(await screen.findByRole("alert")).toHaveTextContent("Unidentified Codex account.")
    expect(invoke).toHaveBeenCalledWith("register_codex_home", { label: "Work", path: "C:/Codex Work" })
    expect(onRegistered).not.toHaveBeenCalled()
  })
})
