import { useEffect } from "react"
import { I18nextProvider } from "react-i18next"
import i18n, { ensureLocaleLoaded } from "@/i18n"
import { resolveUiLocale } from "@/i18n/locale-meta"
import { prefetchExchangeRates } from "@/lib/exchange-rates"
import { setLocaleFormatContext } from "@/lib/locale-format"
import { useAppPreferencesStore } from "@/stores/app-preferences-store"

function LocaleFormatSync() {
  const appLocale = useAppPreferencesStore((s) => s.appLocale)
  const displayCurrency = useAppPreferencesStore((s) => s.displayCurrency)
  const bumpExchangeRatesRevision = useAppPreferencesStore((s) => s.bumpExchangeRatesRevision)

  setLocaleFormatContext({ appLocale, displayCurrency })

  useEffect(() => {
    const lng = resolveUiLocale(appLocale)
    document.documentElement.lang = lng
    void ensureLocaleLoaded(lng).then(() => i18n.changeLanguage(lng))
  }, [appLocale])

  useEffect(() => {
    let cancelled = false
    void prefetchExchangeRates().then((ok) => {
      if (!cancelled && ok) bumpExchangeRatesRevision()
    })
    return () => {
      cancelled = true
    }
  }, [appLocale, displayCurrency, bumpExchangeRatesRevision])

  return null
}

export function I18nProvider({ children }: { children: React.ReactNode }) {
  return (
    <I18nextProvider i18n={i18n}>
      <LocaleFormatSync />
      {children}
    </I18nextProvider>
  )
}
