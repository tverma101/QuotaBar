import Foundation
import os

/// Read-only catalog of providers and the widgets they register, built from the live
/// `ProviderRuntime`s at launch.
///
/// The registry is immutable once built, and its lookups are read on every render through
/// `LayoutStore`'s `@Observable` computed properties (display groups, metric order, pin counts).
/// So the accessors are backed by lookup maps precomputed once at construction — O(1)/O(k) instead
/// of linear scans of every descriptor on every call.
struct WidgetRegistry: Sendable {
    let providers: [Provider]
    let descriptors: [WidgetDescriptor]

    /// Descriptor by id — backs `descriptor(id:)`.
    private let descriptorsByID: [String: WidgetDescriptor]
    /// Provider by id — backs `provider(id:)`.
    private let providersByID: [String: Provider]
    /// Per-provider descriptor lists, preserving the original `descriptors` order within each provider
    /// (a stable `filter` walk), so `descriptors(for:)` returns the exact sequence the UI metric order
    /// depends on.
    private let descriptorsByProvider: [String: [WidgetDescriptor]]
    /// Per-provider history descriptor, precomputed — the accessor used to rebuild the map on every
    /// read, and the store reads it a dozen times per refresh tick.
    private let historyDescriptors: [String: UsageHistoryDescriptor]
    /// Per-provider limit descriptors, precomputed for the same reason.
    private let limitDescriptors: [String: [WidgetDescriptor]]

    /// Test instrumentation: how many times the history map was built. It is built once per registry,
    /// so reading the accessor must not change the count.
    static let historyMapBuildCount = OSAllocatedUnfairLock(initialState: 0)

    init(providers: [Provider], descriptors: [WidgetDescriptor]) {
        self.providers = providers
        self.descriptors = descriptors
        self.descriptorsByID = Dictionary(
            descriptors.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.providersByID = Dictionary(
            providers.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var byProvider: [String: [WidgetDescriptor]] = [:]
        for descriptor in descriptors {
            byProvider[descriptor.providerID, default: []].append(descriptor)
        }
        self.descriptorsByProvider = byProvider
        let history = byProvider.compactMapValues { descriptors in
            descriptors.compactMap(\.historyResource).first
        }
        WidgetRegistry.historyMapBuildCount.withLock { $0 += 1 }
        self.historyDescriptors = history
        self.limitDescriptors = byProvider.mapValues { $0.filter { !$0.limitResources.isEmpty } }
    }

    func descriptor(id: String) -> WidgetDescriptor? { descriptorsByID[id] }
    func provider(id: String) -> Provider? { providersByID[id] }
    func descriptors(for providerID: String) -> [WidgetDescriptor] {
        descriptorsByProvider[providerID] ?? []
    }

    /// Saved order filtered to installed providers, with newly introduced providers appended in the
    /// canonical registry order. Account-scoped providers that are new to an existing layout are
    /// inserted beside their family card, so a second Codex card does not disappear below unrelated
    /// providers on a tall dashboard. Shared by the dashboard, local API, and one-shot CLI.
    func orderedProviderIDs(savedOrder: [String]) -> [String] {
        let defaults = providers.map(\.id)
        let known = Set(defaults)
        var ordered = savedOrder.filter { known.contains($0) }
        var seen = Set<String>()
        ordered = ordered.filter { seen.insert($0).inserted }

        for providerID in defaults where seen.insert(providerID).inserted {
            let family = ProviderAccountID.family(of: providerID)
            guard family != providerID,
                  let familyIndex = ordered.lastIndex(where: { ProviderAccountID.family(of: $0) == family })
            else {
                ordered.append(providerID)
                continue
            }
            ordered.insert(providerID, at: ordered.index(after: familyIndex))
        }
        return ordered
    }

    var limitDescriptorsByProvider: [String: [WidgetDescriptor]] {
        limitDescriptors
    }

    var historyDescriptorsByProvider: [String: UsageHistoryDescriptor] {
        historyDescriptors
    }

    @MainActor
    static func from(_ runtimes: [ProviderRuntime]) -> WidgetRegistry {
        let providers = runtimes.map(\.provider)
        let metrics = runtimes.flatMap(\.widgetDescriptors)
        return WidgetRegistry(providers: providers, descriptors: metrics)
    }
}
