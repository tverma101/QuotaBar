import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { useState } from "react"
import { describe, expect, it, vi } from "vitest"
import { PanelFooter } from "@/components/panel-footer"
import { I18nProvider } from "@/components/i18n-provider"
import type { UpdateStatus } from "@/hooks/use-app-update"

function renderFooter(props: React.ComponentProps<typeof PanelFooter>) {
  return render(
    <I18nProvider>
      <PanelFooter {...props} />
    </I18nProvider>,
  )
}

vi.mock("@tauri-apps/plugin-opener", () => ({
  openUrl: vi.fn(() => Promise.resolve()),
}))

const noop = () => {}
const updateProps = {
  updateStatus: { status: "idle" } as UpdateStatus,
  onUpdateInstall: noop,
  onUpdateCheck: noop,
}
const footerProps = { showAbout: false, onShowAbout: noop, onCloseAbout: noop, ...updateProps }

describe("PanelFooter", () => {
  it("shows countdown in minutes when >= 60 seconds", () => {
    const futureTime = Date.now() + 5 * 60 * 1000
    renderFooter({
      version: "0.0.0",
      autoUpdateNextAt: futureTime,
      ...footerProps,
    })
    expect(screen.getByText("Next refresh in 5m")).toBeTruthy()
  })

  it("shows countdown in seconds when < 60 seconds", () => {
    const futureTime = Date.now() + 30 * 1000
    renderFooter({
      version: "0.0.0",
      autoUpdateNextAt: futureTime,
      ...footerProps,
    })
    expect(screen.getByText("Next refresh in 30s")).toBeTruthy()
  })

  it("triggers refresh when clicking the countdown", async () => {
    const futureTime = Date.now() + 5 * 60 * 1000
    const onRefreshAll = vi.fn()
    renderFooter({
      version: "0.0.0",
      autoUpdateNextAt: futureTime,
      onRefreshAll,
      ...footerProps,
    })
    const button = screen.getByRole("button", { name: /Next refresh in/i })
    await userEvent.click(button)
    expect(onRefreshAll).toHaveBeenCalledTimes(1)
  })

  it("shows Paused when autoUpdateNextAt is null", () => {
    renderFooter({
      version: "0.0.0",
      autoUpdateNextAt: null,
      ...footerProps,
    })
    expect(screen.getByText("Paused")).toBeTruthy()
  })

  it("opens About dialog when clicking the version", async () => {
    function Harness() {
      const [showAbout, setShowAbout] = useState(false)
      return (
        <I18nProvider>
          <PanelFooter
            version="0.0.0"
            autoUpdateNextAt={null}
            {...updateProps}
            showAbout={showAbout}
            onShowAbout={() => setShowAbout(true)}
            onCloseAbout={() => setShowAbout(false)}
          />
        </I18nProvider>
      )
    }

    render(<Harness />)
    await userEvent.click(screen.getByRole("button", { name: /^QuotaBar / }))
    await screen.findByRole("heading", { name: "QuotaBar" })

    await userEvent.keyboard("{Escape}")
    await waitFor(() => {
      expect(screen.queryByRole("heading", { name: "QuotaBar" })).not.toBeInTheDocument()
    })
  })

  it("shows download progress, then installs the ready update", async () => {
    const onUpdateInstall = vi.fn()
    const { rerender } = renderFooter({
      version: "0.0.0",
      autoUpdateNextAt: null,
      ...footerProps,
      updateStatus: { status: "downloading", progress: 42 },
    })
    expect(screen.getByText("Downloading update 42%")).toBeTruthy()

    rerender(
      <I18nProvider>
        <PanelFooter
          version="0.0.0"
          autoUpdateNextAt={null}
          {...footerProps}
          updateStatus={{ status: "ready", version: "0.7.3" }}
          onUpdateInstall={onUpdateInstall}
        />
      </I18nProvider>,
    )
    await userEvent.click(screen.getByRole("button", { name: "Restart to install v0.7.3" }))
    expect(onUpdateInstall).toHaveBeenCalledTimes(1)
  })

  it("keeps showing the version when a background update check fails", () => {
    renderFooter({
      version: "0.0.0",
      autoUpdateNextAt: null,
      ...footerProps,
      updateStatus: { status: "error", message: "Update check failed" },
    })
    expect(screen.getByRole("button", { name: "QuotaBar 0.0.0" })).toBeTruthy()
  })

  it("offers a retry after a failed download", async () => {
    const onUpdateCheck = vi.fn()
    renderFooter({
      version: "0.0.0",
      autoUpdateNextAt: null,
      ...footerProps,
      updateStatus: { status: "error", message: "Download failed" },
      onUpdateCheck,
    })
    await userEvent.click(screen.getByRole("button", { name: "Update failed" }))
    expect(onUpdateCheck).toHaveBeenCalledTimes(1)
  })
})
