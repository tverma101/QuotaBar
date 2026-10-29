import XCTest
@testable import QuotaBar

@MainActor
final class OptionalMetricVisibilityTests: XCTestCase {
    func testEveryConditionalProviderRowHidesWithoutDataButHonorsExplicitEnablement() throws {
        let providers: [ProviderRuntime] = [
            AntigravityProvider(),
            ClaudeProvider(),
            CodexProvider(),
            CopilotProvider(),
            CursorProvider(),
            DevinProvider(),
            FreebuffProvider(),
            GrokProvider(),
            HermesProvider(),
            isolatedOpenCodeProvider(),
            OpenRouterProvider(),
            ZAIProvider()
        ]
        let registry = WidgetRegistry.from(providers)
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LayoutStore(registry: registry, defaults: defaults, defaultMetricIDs: [])
        let expectedConditionalIDs: Set<String> = [
            "antigravity.argonWeekly", "antigravity.claude", "antigravity.claudeWeekly",
            "claude.fable", "claude.sonnet", "claude.extra",
            "codex.spark", "codex.sparkWeekly", "codex.credits", "codex.rateLimitResets",
            "copilot.premium", "copilot.extra", "copilot.orgCredits", "copilot.orgSpend", "copilot.chat", "copilot.completions",
            "cursor.usage", "cursor.auto", "cursor.api", "cursor.grokBot", "cursor.onDemand", "cursor.requests", "cursor.credits",
            "devin.daily", "devin.extra",
            "freebuff.session", "freebuff.daily", "freebuff.weekly", "freebuff.fiveDay", "freebuff.monthly",
            "freebuff.premiumSessions", "freebuff.freePremiumSessions", "freebuff.freebucksDaily",
            "freebuff.freebucksBalance", "freebuff.monthlySpend",
            "grok.payAsYouGo",
            "opencode.session", "opencode.weekly", "opencode.monthly",
            "openrouter.credits", "openrouter.balance", "openrouter.keyLimit",
            "zai.webSearches"
        ]
        let actualConditionalIDs = Set(registry.descriptors.filter(\.hidesWhenEmpty).map(\.id))
        XCTAssertEqual(actualConditionalIDs, expectedConditionalIDs, "keep the full provider descriptor inventory covered")

        for id in expectedConditionalIDs {
            let descriptor = try XCTUnwrap(registry.descriptor(id: id), "missing descriptor: \(id)")
            XCTAssertTrue(descriptor.hidesWhenEmpty, "\(id) should be marked feature-dependent")
            XCTAssertFalse(store.showsRow(descriptor, hasData: false), "empty \(id) should stay out of the card")
            XCTAssertTrue(store.showsRow(descriptor, hasData: true), "reported \(id) should appear")

            store.setMetricEnabled(id, true)
            XCTAssertTrue(
                store.showsRow(descriptor, hasData: false),
                "explicitly enabling \(id) should keep its no-data state visible"
            )
        }

        for id in [
            "antigravity.geminiPro", "antigravity.geminiWeekly", "grok.weekly", "devin.weekly",
            "zai.session", "zai.weekly"
        ] {
            let descriptor = try XCTUnwrap(registry.descriptor(id: id), "missing core descriptor: \(id)")
            XCTAssertFalse(descriptor.hidesWhenEmpty, "documented core unknown-data row \(id) remains visible")
            XCTAssertTrue(store.showsRow(descriptor, hasData: false), "core unknown-data row \(id) remains visible")
        }
    }

    func testConditionalRowFollowsSnapshotArrivalAndCustomizeOptIn() async {
        let provider = Provider(id: "opencode", displayName: "OpenCode", icon: .providerMark("opencode"))
        let descriptor = WidgetDescriptor(
            id: "opencode.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        ).hidingWhenEmpty()
        let unrelated = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Weekly", used: 25, limit: 100, format: .percent)]
        )
        let populated = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 25, limit: 100, format: .percent)]
        )
        let runtime = SequenceProviderRuntime(provider: provider, descriptors: [descriptor], snapshots: [unrelated, populated])
        let registry = WidgetRegistry(providers: [provider], descriptors: [descriptor])
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let (customizeDefaults, customizeSuiteName) = makeDefaults()
        defer { customizeDefaults.removePersistentDomain(forName: customizeSuiteName) }
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "visibility.snapshots", ttl: 600, now: { Date() })
        let dataStore = WidgetDataStore(registry: registry, providers: [runtime], cache: cache, defaults: defaults)
        let layout = LayoutStore(registry: registry, defaults: defaults, defaultMetricIDs: [descriptor.id])
        let customizeLayout = LayoutStore(
            registry: registry,
            defaults: customizeDefaults,
            defaultMetricIDs: []
        )

        await dataStore.refresh(providerID: provider.id, force: true)
        let unrelatedData = dataStore.data(for: descriptor)
        XCTAssertFalse(unrelatedData.hasData)
        XCTAssertFalse(layout.showsRow(descriptor, hasData: unrelatedData.hasData))

        XCTAssertFalse(customizeLayout.showsRow(descriptor, hasData: unrelatedData.hasData))
        customizeLayout.setMetricEnabled(descriptor.id, true)
        XCTAssertTrue(customizeLayout.showsRow(descriptor, hasData: unrelatedData.hasData))

        await dataStore.refresh(providerID: provider.id, force: true)
        let arrivedData = dataStore.data(for: descriptor)
        XCTAssertTrue(arrivedData.hasData)
        XCTAssertTrue(layout.showsRow(descriptor, hasData: arrivedData.hasData))
    }

    func testCodexCreditsKeepsMeasuredZeroAndHidesWhenTheBalanceIsOmitted() async throws {
        let codex = CodexProvider()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let measuredZero = try CodexUsageMapper.mapUsageResponse(
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"credits":{"has_credits":false}}"#.utf8)),
            now: now
        )
        let omitted = try CodexUsageMapper.mapUsageResponse(
            HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8)),
            now: now
        )
        let runtime = SequenceProviderRuntime(
            provider: codex.provider,
            descriptors: codex.widgetDescriptors,
            snapshots: [
                ProviderSnapshot.make(provider: codex.provider, plan: nil, lines: measuredZero.lines, refreshedAt: now),
                ProviderSnapshot.make(provider: codex.provider, plan: nil, lines: omitted.lines, refreshedAt: now)
            ]
        )
        let registry = WidgetRegistry.from([runtime])
        let (defaults, suiteName) = makeDefaults("codex-credit-zero")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "credits-zero.snapshots", ttl: 600),
            defaults: defaults
        )
        let layout = LayoutStore(registry: registry, defaults: defaults, defaultMetricIDs: [])
        let descriptor = try XCTUnwrap(registry.descriptor(id: "codex.credits"))

        await dataStore.refresh(providerID: "codex", force: true)
        let zeroData = dataStore.data(for: descriptor)
        XCTAssertTrue(zeroData.hasData)
        XCTAssertEqual(zeroData.unboundedDetail, "$0.00 · 0 credits")
        XCTAssertTrue(layout.showsRow(descriptor, hasData: zeroData.hasData))

        await dataStore.refresh(providerID: "codex", force: true)
        let missingData = dataStore.data(for: descriptor)
        XCTAssertFalse(missingData.hasData)
        XCTAssertFalse(layout.showsRow(descriptor, hasData: missingData.hasData))
    }

    func testOpenCodeDynamicAccountCapsHideUntilDataOrExplicitOptIn() async throws {
        let work = OpenCodeGoKey(id: UUID(), label: "Work", key: "sk-work")
        let savedKeys = try JSONEncoder().encode([work])
        let runtime = OpenCodeProvider(
            authStore: OpenCodeAuthStore(
                files: FakeFiles(["/oc/auth.json": #"{"opencode-go":{"type":"api","key":"sk-go"}}"#]),
                environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
                homeDirectory: { URL(fileURLWithPath: "/nonexistent") }
            ),
            goKeyStore: OpenCodeGoKeyStore(
                files: FakeFiles(["/oc/go-keys.json": String(decoding: savedKeys, as: UTF8.self)]),
                filePath: { "/oc/go-keys.json" }
            )
        )
        let registry = WidgetRegistry.from([runtime])
        let dynamicDescriptors = registry.descriptors(for: "opencode").filter {
            $0.id.contains(".account.")
        }
        XCTAssertEqual(dynamicDescriptors.count, 6)
        XCTAssertTrue(dynamicDescriptors.allSatisfy(\.hidesWhenEmpty))

        let (defaults, suiteName) = makeDefaults("opencode-dynamic-empty")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let layout = LayoutStore(registry: registry, defaults: defaults, defaultMetricIDs: [])
        for descriptor in dynamicDescriptors {
            XCTAssertFalse(layout.showsRow(descriptor, hasData: false))
            layout.setMetricEnabled(descriptor.id, true)
            XCTAssertTrue(layout.showsRow(descriptor, hasData: false))
        }
    }

    private func makeDefaults(_ label: String = "") -> (UserDefaults, String) {
        let name = "QuotaBarTests.OptionalMetricVisibility.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    private func isolatedOpenCodeProvider() -> OpenCodeProvider {
        OpenCodeProvider(
            authStore: OpenCodeAuthStore(
                files: FakeFiles(),
                environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/nonexistent"]),
                homeDirectory: { URL(fileURLWithPath: "/nonexistent") }
            ),
            goKeyStore: OpenCodeGoKeyStore(
                files: FakeFiles(),
                filePath: { "/nonexistent/opencode-go-keys.json" }
            )
        )
    }
}
