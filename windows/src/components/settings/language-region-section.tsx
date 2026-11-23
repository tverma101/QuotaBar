import { useMemo } from "react"
import { useTranslation } from "react-i18next"
import { Globe, Coins, ChevronDown } from "lucide-react"
import {
  SUPPORTED_UI_LOCALES,
  UI_LOCALE_LABELS,
  type AppLocale,
  type DisplayCurrency,
  type SupportedUiLocale,
} from "@/i18n/locale-meta"
import { buildDisplayCurrencyOptions } from "@/lib/currency-display"
import { getEffectiveIntlLocale } from "@/lib/locale-format"
import { useAppPreferencesStore } from "@/stores/app-preferences-store"
import { cn } from "@/lib/utils"

type LanguageRegionSectionProps = {
  appLocale: AppLocale
  displayCurrency: DisplayCurrency
  onAppLocaleChange: (value: AppLocale) => void
  onDisplayCurrencyChange: (value: DisplayCurrency) => void
}

export function LanguageRegionSection({
  appLocale,
  displayCurrency,
  onAppLocaleChange,
  onDisplayCurrencyChange,
}: LanguageRegionSectionProps) {
  const { t } = useTranslation()
  const exchangeRatesRevision = useAppPreferencesStore((s) => s.exchangeRatesRevision)
  const intlLocale = getEffectiveIntlLocale()

  const languageOptions = useMemo(
    () => [
      { value: "auto" as const, label: t("common.auto") },
      ...SUPPORTED_UI_LOCALES.map((locale) => ({
        value: locale as SupportedUiLocale,
        label: UI_LOCALE_LABELS[locale],
      })),
    ],
    [t],
  )

  const currencyOptions = useMemo(
    () => buildDisplayCurrencyOptions(t, intlLocale),
    [t, intlLocale, exchangeRatesRevision],
  )

  const currentLanguageLabel =
    languageOptions.find((opt) => opt.value === appLocale)?.label ?? appLocale

  return (
    <section className="space-y-3">
      <div>
        <h3 className="text-base font-semibold text-foreground tracking-tight">
          {t("settings.languageRegion.title")}
        </h3>
        <p className="text-xs text-muted-foreground mt-0.5">
          {t("settings.languageRegion.description")}
        </p>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
        {/* Language selector */}
        <div className="rounded-xl border border-border/70 bg-card/60 p-3.5 space-y-2.5 shadow-xs transition-colors hover:border-border">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-1.5 text-sm font-medium text-foreground">
              <Globe className="size-4 text-primary/80" />
              <span>{t("settings.languageRegion.language")}</span>
            </div>
            <span className="text-[11px] text-muted-foreground font-medium px-2 py-0.5 rounded-md bg-muted/60">
              {currentLanguageLabel}
            </span>
          </div>

          <div className="relative">
            <select
              aria-label={t("settings.languageRegion.languageAria")}
              className={cn(
                "w-full appearance-none rounded-lg border border-border bg-background/90 px-3 py-2 text-sm font-medium text-foreground",
                "pr-8 outline-none transition-all cursor-pointer",
                "focus:ring-2 focus:ring-primary/25 focus:border-primary",
                "hover:bg-accent/40",
              )}
              value={appLocale}
              onChange={(e) => onAppLocaleChange(e.target.value as AppLocale)}
            >
              {languageOptions.map((option) => (
                <option
                  key={option.value}
                  value={option.value}
                  className="bg-popover text-popover-foreground py-1"
                >
                  {option.label}
                </option>
              ))}
            </select>
            <ChevronDown className="pointer-events-none absolute right-2.5 top-1/2 -translate-y-1/2 size-4 text-muted-foreground" />
          </div>
        </div>

        {/* Currency selector */}
        <div className="rounded-xl border border-border/70 bg-card/60 p-3.5 space-y-2.5 shadow-xs transition-colors hover:border-border">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-1.5 text-sm font-medium text-foreground">
              <Coins className="size-4 text-primary/80" />
              <span>{t("settings.languageRegion.currency")}</span>
            </div>
          </div>

          <div className="relative">
            <select
              aria-label={t("settings.languageRegion.currencyAria")}
              className={cn(
                "w-full appearance-none rounded-lg border border-border bg-background/90 px-3 py-2 text-sm font-medium text-foreground",
                "pr-8 outline-none transition-all cursor-pointer",
                "focus:ring-2 focus:ring-primary/25 focus:border-primary",
                "hover:bg-accent/40",
              )}
              value={displayCurrency}
              onChange={(e) => onDisplayCurrencyChange(e.target.value as DisplayCurrency)}
            >
              {currencyOptions.map((option) => (
                <option
                  key={option.value}
                  value={option.value}
                  className="bg-popover text-popover-foreground py-1"
                >
                  {option.label}
                </option>
              ))}
            </select>
            <ChevronDown className="pointer-events-none absolute right-2.5 top-1/2 -translate-y-1/2 size-4 text-muted-foreground" />
          </div>
          {displayCurrency === "auto" ? (
            <p className="text-[11px] text-muted-foreground leading-snug">
              {t("settings.languageRegion.currencyAutoHint")}
            </p>
          ) : null}
        </div>
      </div>
    </section>
  )
}
