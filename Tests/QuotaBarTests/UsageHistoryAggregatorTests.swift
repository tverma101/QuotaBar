import XCTest
@testable import QuotaBar

final class UsageHistoryAggregatorTests: XCTestCase {
    func testAggregationAddsMachineLocalHistoryAndIgnoresAccountWideHistory() throws {
        let local = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            lines: [],
            usageHistory: history(tokens: 100, cost: 1, model: "Opus", unknown: ["unknown-a"])
        )
        let cursor = ProviderSnapshot(
            providerID: "cursor",
            displayName: "Cursor",
            lines: [],
            usageHistory: history(tokens: 9_000, cost: 90, model: "Cursor Model")
        )
        let oldDuplicate = document(
            deviceID: "peer-a",
            updatedAt: 100,
            providers: ["claude": history(tokens: 9_999, cost: 99, model: "Opus")]
        )
        let newestDuplicate = document(
            deviceID: "peer-a",
            updatedAt: 200,
            providers: [
                "claude": history(tokens: 200, cost: 2, model: "opus", unknown: ["unknown-b"]),
                "cursor": history(tokens: 9_000, cost: 90, model: "Cursor Model")
            ]
        )
        let secondPeer = document(
            deviceID: "peer-b",
            updatedAt: 150,
            providers: ["claude": history(tokens: 50, cost: nil, model: "Sonnet")]
        )

        let merged = UsageHistoryAggregator.merged(
            localSnapshots: ["claude": local, "cursor": cursor],
            peerDocuments: [oldDuplicate, newestDuplicate, secondPeer],
            descriptors: [
                "claude": UsageHistoryDescriptor(scope: .machineLocal, estimatedCost: true, sourceNote: "logs"),
                "cursor": UsageHistoryDescriptor(scope: .accountWide, estimatedCost: true, sourceNote: "export")
            ],
            now: localDay(2026, 7, 13)
        )

        let claude = try XCTUnwrap(merged["claude"])
        XCTAssertEqual(claude.series.daily, [
            DailyUsageEntry(date: "2026-07-13", totalTokens: 350, costUSD: nil, costIsComplete: false)
        ], "the unknown model rows make the merged dollar subtotal incomplete")
        XCTAssertEqual(claude.modelUsage?.daily[0].models.map(\.model), ["Opus", "Sonnet"])
        XCTAssertEqual(claude.modelUsage?.daily[0].models.first?.totalTokens, 300)
        XCTAssertEqual(claude.unknownModelsByDay["2026-07-13"], ["unknown-a", "unknown-b"])
        XCTAssertNil(merged["cursor"], "account-wide Cursor history must never be added across Macs")
    }

    func testAggregationExcludesRowsOutsideLifetimeWindow() throws {
        let now = localDay(2026, 7, 13)
        let includedDate = Calendar.current.date(byAdding: .year, value: -10, to: now)!
        let excludedDate = Calendar.current.date(byAdding: .day, value: -1, to: includedDate)!
        XCTAssertTrue(UsageHistoryWindow.lifetimeDayKeys(through: now).contains(DailyUsageAccumulator.dayKey(from: includedDate)))
        XCTAssertFalse(UsageHistoryWindow.lifetimeDayKeys(through: now).contains(DailyUsageAccumulator.dayKey(from: excludedDate)))
        let includedKey = DailyUsageAccumulator.dayKey(from: includedDate)
        let excludedKey = DailyUsageAccumulator.dayKey(from: excludedDate)
        let peerHistory = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-07-13", totalTokens: 10, costUSD: 1),
                DailyUsageEntry(date: includedKey, totalTokens: 20, costUSD: 2),
                DailyUsageEntry(date: excludedKey, totalTokens: 9_000, costUSD: 90)
            ]),
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: "2026-07-13", models: [
                    ModelUsageEntry(model: "Current", totalTokens: 10, costUSD: 1)
                ]),
                DailyModelUsageEntry(date: includedKey, models: [
                    ModelUsageEntry(model: "Older detail", totalTokens: 20, costUSD: 2)
                ]),
                DailyModelUsageEntry(date: excludedKey, models: [
                    ModelUsageEntry(model: "Stale", totalTokens: 9_000, costUSD: 90)
                ])
            ]),
            unknownModelsByDay: [
                "2026-07-13": ["current-unknown"],
                includedKey: ["older-unknown"],
                excludedKey: ["stale-unknown"]
            ],
            apiEstimateByDay: ["2026-07-13": 1, includedKey: 2, excludedKey: 90]
        )

        let merged = UsageHistoryAggregator.merged(
            localSnapshots: [:],
            peerDocuments: [document(deviceID: "peer", updatedAt: 100, providers: ["claude": peerHistory])],
            descriptors: [
                "claude": UsageHistoryDescriptor(scope: .machineLocal, estimatedCost: true, sourceNote: "logs")
            ],
            now: now
        )

        let claude = try XCTUnwrap(merged["claude"])
        XCTAssertEqual(claude.series.daily.map(\.date), ["2026-07-13", includedKey])
        XCTAssertEqual(claude.series.daily.reduce(0) { $0 + $1.totalTokens }, 30)
        XCTAssertEqual(claude.modelUsage?.daily.flatMap(\.models).map(\.model), ["Current"])
        XCTAssertEqual(claude.unknownModelsByDay, ["2026-07-13": ["current-unknown"]])
        XCTAssertEqual(claude.apiEstimateByDay, ["2026-07-13": 1, includedKey: 2])
        XCTAssertEqual(claude.apiEstimateIncompleteDays, Set(["2026-07-13", includedKey]),
                       "full-retention estimate completeness survives model-name pruning")
    }

    func testAggregationSaturatesCombinedTokenTotals() throws {
        let local = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            lines: [],
            usageHistory: history(tokens: .max, cost: nil, model: "Opus")
        )
        let peer = document(
            deviceID: "peer",
            updatedAt: 100,
            providers: ["claude": history(tokens: 1, cost: nil, model: "Opus")]
        )
        let merged = UsageHistoryAggregator.merged(
            localSnapshots: ["claude": local],
            peerDocuments: [peer],
            descriptors: ["claude": UsageHistoryDescriptor(scope: .machineLocal, estimatedCost: true, sourceNote: "logs")],
            now: localDay(2026, 7, 13)
        )

        XCTAssertEqual(merged["claude"]?.series.daily.first?.totalTokens, .max)
        XCTAssertEqual(merged["claude"]?.modelUsage?.daily.first?.models.first?.totalTokens, .max)
    }

    func testClaudeOrganizationsMatchByIdentityInsteadOfCardID() throws {
        let personalID = "claude"
        let workID = "claude@1234abcd"
        let personal = ProviderSnapshot(
            providerID: personalID,
            displayName: "Claude Personal",
            lines: [],
            usageHistory: history(tokens: 100, cost: 1, model: "Opus")
        )
        let work = ProviderSnapshot(
            providerID: workID,
            displayName: "Claude Work",
            lines: [],
            usageHistory: history(tokens: 200, cost: 2, model: "Sonnet")
        )
        let codex = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            lines: [],
            usageHistory: history(tokens: 300, cost: 3, model: "GPT")
        )
        var peer = document(
            deviceID: "peer",
            updatedAt: 200,
            providers: [
                "claude": history(tokens: 40, cost: 4, model: "Sonnet"),
                "claude@abcdef12": history(tokens: 30, cost: 3, model: "Opus"),
                "codex": history(tokens: 50, cost: 5, model: "GPT"),
            ]
        )
        peer.schema = UsageHistoryDocument.accountSchema
        peer.identities = ["claude": "USER|WORK", "claude@abcdef12": "user|personal"]
        XCTAssertNoThrow(try peer.validate())

        let descriptor = UsageHistoryDescriptor(scope: .machineLocal, estimatedCost: true, sourceNote: "logs")
        let merged = UsageHistoryAggregator.merged(
            localSnapshots: [personalID: personal, workID: work, "codex": codex],
            peerDocuments: [peer],
            descriptors: [personalID: descriptor, workID: descriptor, "codex": descriptor],
            providerIdentityKeys: [personalID: "user|personal", workID: "user|work", "codex": "different-codex"],
            now: localDay(2026, 7, 13)
        )

        XCTAssertEqual(try XCTUnwrap(merged[personalID]).series.daily.first?.totalTokens, 130)
        XCTAssertEqual(try XCTUnwrap(merged[workID]).series.daily.first?.totalTokens, 240)
        XCTAssertEqual(try XCTUnwrap(merged["codex"]).series.daily.first?.totalTokens, 350)
    }

    func testMismatchedClaudeIdentityNeverFallsBackToMatchingCardID() throws {
        let local = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            lines: [],
            usageHistory: history(tokens: 100, cost: 1, model: "Opus")
        )
        var peer = document(
            deviceID: "peer",
            updatedAt: 200,
            providers: ["claude": history(tokens: 900, cost: 9, model: "Opus")]
        )
        peer.identities = ["claude": "user|different"]

        let merged = UsageHistoryAggregator.merged(
            localSnapshots: ["claude": local],
            peerDocuments: [peer],
            descriptors: [
                "claude": UsageHistoryDescriptor(scope: .machineLocal, estimatedCost: true, sourceNote: "logs")
            ],
            providerIdentityKeys: ["claude": "user|personal"],
            now: localDay(2026, 7, 13)
        )

        XCTAssertEqual(try XCTUnwrap(merged["claude"]).series.daily.first?.totalTokens, 100)
    }

    func testLegacyClaudeHistoryMergesOnlyWhenOneOrganizationExists() throws {
        let peer = document(
            deviceID: "peer",
            updatedAt: 200,
            providers: [
                "claude": history(tokens: 90, cost: 9, model: "Opus"),
                "codex": history(tokens: 50, cost: 5, model: "GPT"),
            ]
        )
        let descriptor = UsageHistoryDescriptor(scope: .machineLocal, estimatedCost: true, sourceNote: "logs")

        let single = UsageHistoryAggregator.merged(
            localSnapshots: [:],
            peerDocuments: [peer],
            descriptors: ["claude": descriptor, "codex": descriptor],
            providerIdentityKeys: ["claude": "user|personal"],
            now: localDay(2026, 7, 13)
        )
        XCTAssertEqual(try XCTUnwrap(single["claude"]).series.daily.first?.totalTokens, 90)

        let switched = UsageHistoryAggregator.merged(
            localSnapshots: [:],
            peerDocuments: [peer],
            descriptors: ["claude@1234abcd": descriptor],
            providerIdentityKeys: ["claude@1234abcd": "user|personal"],
            now: localDay(2026, 7, 13)
        )
        XCTAssertEqual(try XCTUnwrap(switched["claude@1234abcd"]).series.daily.first?.totalTokens, 90)

        let multiple = UsageHistoryAggregator.merged(
            localSnapshots: [:],
            peerDocuments: [peer],
            descriptors: ["claude": descriptor, "claude@1234abcd": descriptor, "codex": descriptor],
            providerIdentityKeys: ["claude": "user|personal", "claude@1234abcd": "user|work"],
            now: localDay(2026, 7, 13)
        )
        XCTAssertNil(multiple["claude"])
        XCTAssertNil(multiple["claude@1234abcd"])
        XCTAssertEqual(try XCTUnwrap(multiple["codex"]).series.daily.first?.totalTokens, 50)
    }

    @MainActor
    func testCloudExportUsesLegacySchemaUntilAnOwnedClaudeAccountCardExists() throws {
        let suiteName = "UsageHistoryAggregatorTests.Export.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let personal = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let work = Provider(id: "claude@1234abcd", displayName: "Claude Work", icon: .providerMark("claude"))
        let codex = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let providers = [personal, work, codex]
        let descriptors = providers.map {
            WidgetDescriptor.usageTrend(provider: $0)
                .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "logs")
        }
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
        let identities = ["claude": "User|Personal", "claude@1234abcd": "user|work", "codex": "codex-account"]
        for provider in providers {
            cache.store(
                ProviderSnapshot(
                    providerID: provider.id,
                    displayName: provider.displayName,
                    lines: [],
                    usageHistory: history(tokens: 10, cost: 1, model: "model")
                ),
                producedByIdentityKey: identities[provider.id]
            )
        }

        let single = WidgetDataStore(
            registry: WidgetRegistry(providers: [personal, codex], descriptors: descriptors.filter {
                $0.providerID != work.id
            }),
            providers: [], cache: cache, defaults: defaults,
            providerIdentityKeys: identities
        ).localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac")

        XCTAssertEqual(single.schema, UsageHistoryDocument.currentSchema)
        XCTAssertEqual(single.identities, ["claude": "user|personal"])
        XCTAssertNotNil(single.providers["codex"])
        XCTAssertNoThrow(try single.validate())

        let switched = WidgetDataStore(
            registry: WidgetRegistry(providers: [work, codex], descriptors: descriptors.filter {
                $0.providerID != personal.id
            }),
            providers: [], cache: cache, defaults: defaults,
            providerIdentityKeys: identities
        ).localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac")

        XCTAssertEqual(switched.schema, UsageHistoryDocument.currentSchema)
        XCTAssertEqual(switched.identities, ["claude": "user|work"])
        XCTAssertEqual(Set(switched.providers.keys), ["claude", "codex"])
        XCTAssertNoThrow(try switched.validate())

        let multiple = WidgetDataStore(
            registry: WidgetRegistry(providers: providers, descriptors: descriptors),
            providers: [], cache: cache, defaults: defaults,
            providerIdentityKeys: identities
        ).localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac")

        XCTAssertEqual(multiple.schema, UsageHistoryDocument.accountSchema)
        XCTAssertEqual(multiple.identities, ["claude": "user|personal", "claude@1234abcd": "user|work"])
        XCTAssertEqual(Set(multiple.providers.keys), ["claude", "claude@1234abcd", "codex"])
        XCTAssertNoThrow(try multiple.validate())
    }

    @MainActor
    func testCloudExportKeepsLifetimeTotalsButBoundsModelDetailsToThirtyDays() throws {
        let suiteName = "UsageHistoryAggregatorTests.ExportWindow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = localDay(2026, 7, 13)
        let oldDate = Calendar.current.date(byAdding: .day, value: -90, to: now)!
        let oldKey = DailyUsageAccumulator.dayKey(from: oldDate)
        let history = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-07-13", totalTokens: 100, costUSD: 1),
                DailyUsageEntry(date: oldKey, totalTokens: 200, costUSD: 2)
            ]),
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: "2026-07-13", models: [
                    ModelUsageEntry(model: "Current", totalTokens: 100, costUSD: 1)
                ]),
                DailyModelUsageEntry(date: oldKey, models: [
                    ModelUsageEntry(model: "Older", totalTokens: 200, costUSD: 2)
                ])
            ]),
            unknownModelsByDay: ["2026-07-13": ["current-unknown"], oldKey: ["old-unknown"]],
            apiEstimateByDay: ["2026-07-13": 1, oldKey: 2]
        )
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let descriptor = WidgetDescriptor.usageTrend(provider: provider)
            .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "logs")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
        cache.store(ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [],
            usageHistory: history
        ))
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [],
            cache: cache,
            defaults: defaults,
            now: { now }
        )

        let exported = try XCTUnwrap(store.localHistoryDocument(
            deviceID: "this-mac",
            deviceName: "This Mac",
            updatedAt: now
        ).providers["claude"])

        XCTAssertEqual(exported.series.daily.map(\.date), ["2026-07-13", oldKey])
        XCTAssertEqual(exported.modelUsage?.daily.map(\.date), ["2026-07-13"])
        XCTAssertEqual(exported.unknownModelsByDay, ["2026-07-13": ["current-unknown"]])
        XCTAssertEqual(exported.apiEstimateByDay, ["2026-07-13": 1, oldKey: 2])
    }

    func testRendererReplacesOnlySpendRowsAndKeepsLocalState() throws {
        let local = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            plan: "Max",
            lines: [
                .progress(label: "Session", used: 40, limit: 100, format: .percent),
                .values(label: "Today", values: [MetricValue(number: 1, kind: .dollars)]),
                .badge(label: "Local notice", text: "Keep me", colorHex: "#123456")
            ],
            refreshedAt: Date(timeIntervalSince1970: 500),
            warning: "Local warning"
        )
        let combined = history(tokens: 350, cost: 3, model: "Opus")

        let rendered = UsageHistorySnapshotRenderer.render(
            local: local,
            history: combined,
            descriptor: UsageHistoryDescriptor(scope: .machineLocal, estimatedCost: true, sourceNote: "From logs"),
            now: localDay(2026, 7, 13)
        )

        XCTAssertEqual(rendered.plan, "Max")
        XCTAssertEqual(rendered.warning, "Local warning")
        XCTAssertEqual(rendered.refreshedAt, local.refreshedAt)
        XCTAssertEqual(rendered.line(label: "Session"), local.line(label: "Session"))
        XCTAssertEqual(rendered.line(label: "Local notice"), local.line(label: "Local notice"))
        guard case .values(_, let values, _, _, _, let breakdown) = rendered.line(label: "Today") else {
            return XCTFail("Today should be rebuilt as a values row")
        }
        XCTAssertEqual(values.map(\.number), [3, 350])
        XCTAssertEqual(breakdown?.totalTokens, 350)
        XCTAssertEqual(breakdown?.models.map(\.model), ["Opus"])
        XCTAssertTrue(rendered.lines.contains { $0.label == "Usage Trend" })
        XCTAssertEqual(rendered.usageHistory, combined)
    }

    @MainActor
    func testRenderedSnapshotExposesLifetimePeerHistoryWithoutChangingLocalExport() throws {
        let suiteName = "UsageHistoryAggregatorTests.RenderedPeers.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = localDay(2026, 7, 13)
        let oldDate = Calendar.current.date(byAdding: .day, value: -3_300, to: now)!
        let oldKey = DailyUsageAccumulator.dayKey(from: oldDate)
        let localHistory = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-07-13", totalTokens: 100, costUSD: 1),
                DailyUsageEntry(date: oldKey, totalTokens: 1_000, costUSD: 10)
            ]),
            unknownModelsByDay: [:]
        )
        let peerHistory = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-07-13", totalTokens: 200, costUSD: 2),
                DailyUsageEntry(date: oldKey, totalTokens: 2_000, costUSD: 20)
            ]),
            unknownModelsByDay: [:]
        )
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let descriptor = WidgetDescriptor.usageTrend(provider: provider)
            .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "logs")
        let registry = WidgetRegistry(providers: [provider], descriptors: [descriptor])
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
        cache.store(ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [],
            usageHistory: localHistory
        ))
        let store = WidgetDataStore(
            registry: registry,
            providers: [],
            cache: cache,
            defaults: defaults,
            now: { now }
        )

        store.setPeerHistoryDocuments(
            [document(deviceID: "peer", updatedAt: 200, providers: ["claude": peerHistory])],
            ownDeviceID: "this-mac"
        )

        XCTAssertEqual(store.snapshots["claude"]?.usageHistory?.series.daily.map(\.totalTokens), [300, 3_000])
        XCTAssertEqual(store.localSnapshots["claude"]?.usageHistory?.series.daily.map(\.totalTokens), [100, 1_000])
    }

    func testGapFillMergePreservesModelVariants() throws {
        let primary = LogUsageScan(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-07-13", totalTokens: 100, costUSD: 0.1)
            ]),
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: "2026-07-13", models: [
                    ModelUsageEntry(
                        model: "gpt-5.4",
                        totalTokens: 100,
                        costUSD: 0.1,
                        variants: [ModelUsageVariant(model: "anthropic/openai/gpt-5.4", totalTokens: 100, costUSD: 0.1)]
                    )
                ])
            ]),
            unknownModelsByDay: [:]
        )

        let merged = try XCTUnwrap(DailyUsageAccumulator.mergedPreferringPrimary(primary, fillingGapsFrom: []).scan)
        let model = try XCTUnwrap(merged.modelUsage?.daily.first?.models.first)
        XCTAssertEqual(model.totalTokens, 100)
        XCTAssertEqual(model.variants?.map(\.model), ["anthropic/openai/gpt-5.4"])
    }

    private func history(
        tokens: Int,
        cost: Double?,
        model: String,
        unknown: Set<String> = []
    ) -> ProviderUsageHistory {
        ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-07-13", totalTokens: tokens, costUSD: cost)
            ]),
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: "2026-07-13", models: [
                    ModelUsageEntry(model: model, totalTokens: tokens, costUSD: cost)
                ])
            ]),
            unknownModelsByDay: unknown.isEmpty ? [:] : ["2026-07-13": unknown]
        )
    }

    private func document(
        deviceID: String,
        updatedAt: TimeInterval,
        providers: [String: ProviderUsageHistory]
    ) -> UsageHistoryDocument {
        UsageHistoryDocument(
            deviceID: deviceID,
            deviceName: deviceID,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            providers: providers
        )
    }

    private func localDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}
