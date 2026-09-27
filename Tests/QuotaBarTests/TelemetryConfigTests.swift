import Testing

@testable import QuotaBar

/// Guards QuotaBar's "telemetry is inert unless a maintainer configures it" guarantee.
///
/// A PostHog project token is not a public identifier, it is a credential that routes data into one
/// specific project. QuotaBar inherited the mechanism from upstream, and a stock build must not send
/// anything anywhere: a fork has no business reporting its users' activity into another project's
/// analytics account. If a real `phc_…` token is ever committed into `TelemetryConfig.bakedToken`,
/// every QuotaBar build starts shipping daily pings and crash reports to that project — silently, and
/// in violation of the documented behaviour in `docs/privacy.md`.
@Suite("Telemetry configuration")
struct TelemetryConfigTests {
    @Test("A stock build resolves to the inert placeholder")
    func stockBuildIsInert() {
        #expect(TelemetryConfig.resolvedToken(environment: [:]) == TelemetryConfig.placeholderToken)
    }

    @Test("Blank and whitespace-only overrides still resolve to the placeholder")
    func blankOverridesAreIgnored() {
        #expect(TelemetryConfig.resolvedToken(environment: ["QUOTABAR_POSTHOG_TOKEN": ""])
            == TelemetryConfig.placeholderToken)
        #expect(TelemetryConfig.resolvedToken(environment: ["QUOTABAR_POSTHOG_TOKEN": "   "])
            == TelemetryConfig.placeholderToken)
        #expect(TelemetryConfig.resolvedToken(environment: ["OPENUSAGE_POSTHOG_TOKEN": "\n\t"])
            == TelemetryConfig.placeholderToken)
    }

    @Test("A maintainer can opt in with QUOTABAR_POSTHOG_TOKEN")
    func maintainerOverrideIsHonoured() {
        #expect(TelemetryConfig.resolvedToken(environment: ["QUOTABAR_POSTHOG_TOKEN": "  phc_abc  "])
            == "phc_abc")
    }

    @Test("The legacy upstream variable name still works")
    func legacyOverrideIsHonoured() {
        #expect(TelemetryConfig.resolvedToken(environment: ["OPENUSAGE_POSTHOG_TOKEN": "phc_legacy"])
            == "phc_legacy")
    }

    @Test("QUOTABAR_POSTHOG_TOKEN wins over the legacy name")
    func rebrandedOverrideTakesPrecedence() {
        let environment = [
            "OPENUSAGE_POSTHOG_TOKEN": "phc_legacy",
            "QUOTABAR_POSTHOG_TOKEN": "phc_current",
        ]
        #expect(TelemetryConfig.resolvedToken(environment: environment) == "phc_current")
    }
}
