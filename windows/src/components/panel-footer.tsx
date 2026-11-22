import { useMemo } from "react";
import { AboutDialog } from "@/components/about-dialog";
import { fireMotionShock } from "@/components/motion-field";
import { useNowTicker } from "@/hooks/use-now-ticker";

interface PanelFooterProps {
  version: string;
  autoUpdateNextAt: number | null;
  onRefreshAll?: () => void;
  showAbout: boolean;
  onShowAbout: () => void;
  onCloseAbout: () => void;
  /** Optional control rendered at the far right of the footer (macOS-style Options button). */
  trailing?: React.ReactNode;
}

export function PanelFooter({
  version,
  autoUpdateNextAt,
  onRefreshAll,
  showAbout,
  onShowAbout,
  onCloseAbout,
  trailing,
}: PanelFooterProps) {
  const now = useNowTicker({
    enabled: Boolean(autoUpdateNextAt),
    resetKey: autoUpdateNextAt,
  });

  const countdownLabel = useMemo(() => {
    if (!autoUpdateNextAt) return "Paused";
    const remainingMs = Math.max(0, autoUpdateNextAt - now);
    const totalSeconds = Math.ceil(remainingMs / 1000);
    if (totalSeconds >= 60) {
      const minutes = Math.ceil(totalSeconds / 60);
      return `Next refresh in ${minutes}m`;
    }
    return `Next refresh in ${totalSeconds}s`;
  }, [autoUpdateNextAt, now]);

  return (
    <>
      <div className="flex justify-between items-center h-8 pt-1.5 border-t">
        <button
          type="button"
          onClick={onShowAbout}
          className="text-xs text-muted-foreground hover:text-foreground transition-colors cursor-pointer"
        >
          QuotaBar {version}
        </button>
        <div className="flex items-center gap-2">
          {autoUpdateNextAt !== null && onRefreshAll ? (
            <button
              type="button"
              onClick={(event) => {
                event.currentTarget.blur()
                fireMotionShock()
                onRefreshAll()
              }}
              className="text-xs text-muted-foreground tabular-nums hover:text-foreground transition-colors cursor-pointer motion-tick"
              title="Refresh now"
            >
              {countdownLabel}
            </button>
          ) : (
            <span className="text-xs text-muted-foreground tabular-nums">
              {countdownLabel}
            </span>
          )}
          {trailing}
        </div>
      </div>
      {showAbout && (
        <AboutDialog version={version} onClose={onCloseAbout} />
      )}
    </>
  );
}
