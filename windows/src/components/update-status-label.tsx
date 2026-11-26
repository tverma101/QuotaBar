import { useTranslation } from "react-i18next"
import type { UpdateStatus } from "@/hooks/use-app-update"
import { cn } from "@/lib/utils"

type UpdateStatusLabelProps = {
  version: string
  updateStatus: UpdateStatus
  onUpdateInstall: () => void
  onUpdateCheck: () => void
  onShowAbout: () => void
  className?: string
}

/**
 * The footer's version label doubles as the updater's status: it shows download progress, then a
 * "Ready to update" action that installs the signed update and relaunches. A failed background check
 * stays quiet (it is logged) so an offline machine keeps showing the version.
 */
export function UpdateStatusLabel({
  version,
  updateStatus,
  onUpdateInstall,
  onUpdateCheck,
  onShowAbout,
  className,
}: UpdateStatusLabelProps) {
  const { t } = useTranslation()
  const base = cn(
    "truncate rounded-[4px] text-left outline-none transition-colors focus-visible:ring-2 focus-visible:ring-ring",
    className,
  )

  switch (updateStatus.status) {
    case "downloading":
      return (
        <span className={base} role="status">
          {updateStatus.progress >= 0
            ? t("footer.downloadingUpdate", { progress: updateStatus.progress })
            : t("footer.downloadingUpdatePending")}
        </span>
      )
    case "ready":
      return (
        <button
          type="button"
          onClick={onUpdateInstall}
          aria-label={t("footer.restartToInstall", { version: updateStatus.version })}
          className={cn(base, "font-medium text-primary hover:text-primary/90 hover:underline underline-offset-2")}
        >
          {t("footer.readyToUpdate")}
        </button>
      )
    case "installing":
      return (
        <span className={base} role="status">
          {t("footer.installing")}
        </span>
      )
    case "error":
      if (updateStatus.message !== "Update check failed") {
        return (
          <button type="button" onClick={onUpdateCheck} className={cn(base, "text-destructive")}>
            {t("footer.updateFailed")}
          </button>
        )
      }
      break
  }

  return (
    <button type="button" onClick={onShowAbout} className={cn(base, "hover:text-foreground")}>
      QuotaBar {version}
    </button>
  )
}
