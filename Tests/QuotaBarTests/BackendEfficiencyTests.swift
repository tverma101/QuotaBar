import Darwin
import Foundation
import XCTest
@testable import QuotaBar

/// Opt-in measurement of what the Swift/UI side actually pays for a full provider refresh.
///
/// Run with:
/// `QUOTABAR_SWIFT_BACKEND_BENCH=1 swift test --filter BackendEfficiencyTests`
///
/// The provider IDs come from the engine, so this measures the same batch the accounting pass
/// sends. The fold scope suppresses live quota, so nothing performs network I/O; local scanners
/// read the signed-in profile's own history exactly as a panel-open pass does.
final class BackendEfficiencyTests: XCTestCase {
    private struct ProvidersReply: Decodable {
        struct Entry: Decodable { let id: String }
        let ok: [Entry]
    }

    private struct BatchReply: Decodable {
        struct Payload: Decodable {
            let snapshots: [String: ProviderSnapshot]
            let errors: [String: String]
        }
        let ok: Payload
    }

    private final class Heartbeat: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func tick() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    private func average(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(max(values.count, 1))
    }

    private func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private nonisolated static func batchRequest(providerIDs: [String]) -> [String: Any] {
        [
            "method": "refreshBatch",
            "params": [
                "scope": "localAccounting",
                "items": providerIDs.map { ["providerId": $0] },
                "skipModelCatalogRefresh": true,
                "perProviderTimeoutSeconds": 30.0,
            ],
        ]
    }

    func testMeasureSwiftBridgeFoldRefresh() async throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_SWIFT_BACKEND_BENCH"] == "1" else {
            throw XCTSkip("set QUOTABAR_SWIFT_BACKEND_BENCH=1 to run the backend measurement")
        }
        let iterations = ProcessInfo.processInfo.environment["QUOTABAR_BENCH_ITERATIONS"]
            .flatMap(Int.init) ?? 7
        RustEngine.prepare()
        let providersData = try await RustEngine.call(["method": "providers", "params": [:]])
            .get()
        let providerIDs = try decoder.decode(ProvidersReply.self, from: providersData).ok.map(\.id)
        XCTAssertFalse(providerIDs.isEmpty)
        let request = Self.batchRequest(providerIDs: providerIDs)

        // Warm the process-wide pricing catalog and provider setup so the reported numbers describe
        // a periodic refresh, not first launch.
        _ = await RustEngine.call(request)
        _ = await RustEngine.call(request)

        var wallMs: [Double] = []
        var decodeMs: [Double] = []
        var netHeapBytes: [Int] = []
        var mainActorTicks: [Int] = []
        var replyBytes = 0
        for _ in 0..<iterations {
            let heartbeat = Heartbeat()
            let heartbeatTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(2))
                    heartbeat.tick()
                }
            }
            var before = malloc_statistics_t()
            malloc_zone_statistics(nil, &before)
            let started = DispatchTime.now().uptimeNanoseconds
            let result = await Task { @MainActor in
                await RustEngine.call(Self.batchRequest(providerIDs: providerIDs))
            }.value
            let elapsed = milliseconds(since: started)
            let ticks = heartbeat.count
            heartbeatTask.cancel()
            await heartbeatTask.value
            var after = malloc_statistics_t()
            malloc_zone_statistics(nil, &after)
            let data = try result.get()
            replyBytes = data.count

            let decodeStarted = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<10 {
                _ = try decoder.decode(BatchReply.self, from: data)
            }
            decodeMs.append(milliseconds(since: decodeStarted) / 10)
            wallMs.append(elapsed)
            netHeapBytes.append(Int(after.size_in_use) - Int(before.size_in_use))
            mainActorTicks.append(ticks)
        }

        // Split the batch cost by provider. This is still the real engine path (same host
        // callbacks, same local scanners); it only isolates which provider dominates a fold pass.
        var perProvider: [(String, [Double])] = []
        for providerID in providerIDs {
            var samples: [Double] = []
            for _ in 0..<3 {
                let started = DispatchTime.now().uptimeNanoseconds
                _ = await RustEngine.call([
                    "method": "refresh",
                    "params": [
                        "providerId": providerID,
                        "scope": "localAccounting",
                        "skipModelCatalogRefresh": true,
                    ],
                ])
                samples.append(milliseconds(since: started))
            }
            perProvider.append((providerID, samples))
        }
        let providerBreakdown = perProvider
            .sorted { ($0.1.first ?? 0) > ($1.1.first ?? 0) }
            .map { provider, samples in
                let values = samples.map { String(format: "%.1f", $0) }.joined(separator: "/")
                return "\(provider):\(values)"
            }
            .joined(separator: ",")

        var postWarmBatch: [Double] = []
        for _ in 0..<3 {
            let started = DispatchTime.now().uptimeNanoseconds
            _ = await RustEngine.call(Self.batchRequest(providerIDs: providerIDs))
            postWarmBatch.append(milliseconds(since: started))
        }

        // Request encoding is Swift work inside the measured call; report it separately.
        var encodeMs: [Double] = []
        for _ in 0..<20 {
            let started = DispatchTime.now().uptimeNanoseconds
            _ = try JSONSerialization.data(withJSONObject: request)
            encodeMs.append(milliseconds(since: started))
        }

        print(
            "SWIFT_BENCH fold_refresh providers=\(providerIDs.count) iterations=\(iterations) "
                + "avg_call_wall_ms=\(String(format: "%.2f", average(wallMs))) "
                + "avg_decode_ms=\(String(format: "%.3f", average(decodeMs))) "
                + "avg_request_encode_ms=\(String(format: "%.3f", average(encodeMs))) "
                + "avg_net_heap_bytes=\(netHeapBytes.reduce(0, +) / max(netHeapBytes.count, 1)) "
                + "main_actor_ticks=\(mainActorTicks.reduce(0, +) / max(mainActorTicks.count, 1)) "
                + "reply_bytes=\(replyBytes) "
                + "post_warm_batch_ms=\(postWarmBatch.map { String(format: "%.1f", $0) }.joined(separator: "/")) "
                + "per_provider_ms=\(providerBreakdown)"
        )
    }
}
