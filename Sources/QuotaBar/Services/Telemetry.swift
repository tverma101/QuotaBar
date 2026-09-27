import Foundation
import PostHog

/// Build-time configuration for the PostHog project.
///
/// ## QuotaBar ships telemetry inert
///
/// `bakedToken` is the placeholder, so a stock QuotaBar build resolves to `placeholderToken` and
/// `PostHogTelemetrySink` never calls `PostHogSDK.shared.setup` — no network, no anonymous ID, no
/// crash events. This is deliberate. The analytics mechanism is inherited from upstream, but a project
/// token identifies a *specific* PostHog project and its owner: leaving upstream's token baked in would
/// ship every QuotaBar user's daily-activity pings and crash reports into a third party's analytics
/// account, which neither the user nor the QuotaBar maintainer consented to or can see.
///
/// To enable analytics, a maintainer supplies their own US-region `phc_…` project token (a client-side,
/// write-only key, safe to commit) either as the `bakedToken` value or at runtime via
/// `QUOTABAR_POSTHOG_TOKEN`. The host is region-bound — a US token will not ingest against the EU host.
enum TelemetryConfig {
    /// Sentinel meaning "no real token configured" — the sink stays inert (no setup, no network) while
    /// the resolved token equals this. Do NOT change this value.
    static let placeholderToken = "phc_REPLACE_ME"

    /// No real project token is committed. See the note above; `Tests/QuotaBarTests/TelemetryConfigTests.swift`
    /// fails if a real token is ever reintroduced here by accident.
    private static let bakedToken = placeholderToken

    static var token: String { resolvedToken(environment: ProcessInfo.processInfo.environment) }

    /// Resolution split out from `token` so the "inert unless configured" guarantee is directly testable
    /// without mutating the real process environment.
    static func resolvedToken(environment: [String: String]) -> String {
        for key in ["QUOTABAR_POSTHOG_TOKEN", "OPENUSAGE_POSTHOG_TOKEN"] {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return bakedToken
    }

    /// US cloud. Switch to "https://eu.i.posthog.com" only with an EU-region project token.
    static let host = "https://us.i.posthog.com"
}

/// The transport seam telemetry is emitted through. Abstracted from PostHog so the recorder's
/// daily-rollup/dedup logic can be unit-tested against a fake sink.
@MainActor
protocol TelemetrySink: AnyObject {
    func capture(_ event: String, _ properties: [String: Any])
    /// Mirror the optional-analytics preference without disabling daily activity or crash reporting.
    func setOptionalAnalyticsEnabled(_ enabled: Bool)
    func flush()
}

/// Anonymous PostHog sink. The transport and crash autocapture always stay enabled; optional
/// provider events are gated in `TelemetryRecorder`. No `identify()`/`group()`/`alias()`,
/// `personProfiles = .never`, and only IDs/counts/enums are ever sent — never free-form error messages.
/// When no real project token is configured the sink is inert
/// (the app still builds and the toggle still works), so token-less builds never phone home.
@MainActor
final class PostHogTelemetrySink: TelemetrySink {
    /// Crash reporting is mandatory regardless of the optional usage-analytics preference.
    nonisolated static func errorAutocaptureEnabled(optionalAnalyticsEnabled _: Bool) -> Bool { true }

    private let configured: Bool

    init(enabled: Bool, token: String = TelemetryConfig.token, host: String = TelemetryConfig.host) {
        guard token.hasPrefix("phc_"), token != TelemetryConfig.placeholderToken else {
            configured = false
            AppLog.info(.config, "telemetry inert: no PostHog project token configured")
            return
        }
        configured = true

        let config = PostHogConfig(projectToken: token, host: host)
        // Fully anonymous: no person profiles, no anonymous->identified merge.
        config.personProfiles = .never
        // We use no feature flags and emit our own daily rollups, so skip both startup fetches/autocapture.
        config.preloadFeatureFlags = false
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        // Daily activity and crash reporting are mandatory, so the transport never opts out.
        config.optOut = false
        // Crash / uncaught-exception autocapture is always enabled (anonymous `$exception` events,
        // sent on the NEXT launch after a crash). It captures Mach exceptions, POSIX signals,
        // and uncaught NSExceptions; Swift traps may surface as a bare `SIGTRAP` without the message —
        // the symbolicated stack (dSYMs uploaded from release.yml) is what makes them actionable.
        // NOTE: this local flag is necessary but NOT sufficient — posthog-ios also gates the integration
        // on a SERVER-side switch (remote config `errorTracking.autocaptureExceptions`). "Exception
        // autocapture" must be enabled in the PostHog project settings, and because the SDK reads it from
        // cache at init, capture arms on the *second* launch after enabling (first launch fetches+caches).
        // Never reference sessionReplay / surveys / captureElementInteractions / tracingHeaders here:
        // they do not exist on a macOS target.
        config.errorTrackingConfig.autoCapture = Self.errorAutocaptureEnabled(optionalAnalyticsEnabled: enabled)
        PostHogSDK.shared.setup(config)
        // Clear a persisted SDK opt-out so both mandatory signals can send.
        PostHogSDK.shared.optIn()

        // Super properties ride on every subsequent event (anonymous, non-PII).
        PostHogSDK.shared.register([
            "app_version": AppInfo.version,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString
        ])
        AppLog.info(.config, "telemetry initialized (optionalAnalytics=\(enabled))")
    }

    func capture(_ event: String, _ properties: [String: Any]) {
        guard configured else { return }
        PostHogSDK.shared.capture(event, properties: properties)
    }

    func setOptionalAnalyticsEnabled(_ enabled: Bool) {
        guard configured else { return }
        // Never opt the SDK out: daily activity and crash reporting remain mandatory.
        PostHogSDK.shared.optIn()
        AppLog.info(.config, "optional analytics sink preference=\(enabled)")
    }

    func flush() {
        guard configured else { return }
        PostHogSDK.shared.flush()
    }
}
