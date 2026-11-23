import i18n from "i18next"
import { initReactI18next } from "react-i18next"
import { SUPPORTED_UI_LOCALES, type SupportedUiLocale } from "@/i18n/locale-meta"
import en from "@/i18n/locales/en.json"

const localeLoaders: Partial<Record<SupportedUiLocale, () => Promise<{ default: Record<string, unknown> }>>> = {
  ko: () => import("@/i18n/locales/ko.json"),
  ja: () => import("@/i18n/locales/ja.json"),
  "zh-CN": () => import("@/i18n/locales/zh-CN.json"),
  "zh-TW": () => import("@/i18n/locales/zh-TW.json"),
  de: () => import("@/i18n/locales/de.json"),
  fr: () => import("@/i18n/locales/fr.json"),
  nl: () => import("@/i18n/locales/nl.json"),
  pl: () => import("@/i18n/locales/pl.json"),
  cs: () => import("@/i18n/locales/cs.json"),
  "pt-BR": () => import("@/i18n/locales/pt-BR.json"),
  es: () => import("@/i18n/locales/es.json"),
  it: () => import("@/i18n/locales/it.json"),
}

export async function ensureLocaleLoaded(lng: SupportedUiLocale): Promise<void> {
  if (lng === "en" || i18n.hasResourceBundle(lng, "translation")) {
    return
  }
  const loader = localeLoaders[lng]
  if (!loader) return
  const mod = await loader()
  i18n.addResourceBundle(lng, "translation", mod.default, true, true)
}

const resources = {
  en: { translation: en },
} as const

void i18n.use(initReactI18next).init({
  resources,
  lng: "en",
  fallbackLng: "en",
  supportedLngs: [...SUPPORTED_UI_LOCALES],
  nonExplicitSupportedLngs: true,
  interpolation: { escapeValue: false },
})

export default i18n
