import Foundation

extension CodexLogUsageScanner {
    static let hostedGatewayScanner = IncrementalJSONLScanner<Event>(
        maxResidentIdentities: 2,
        maxResidentItems: 16_000,
        logTag: LogTag.plugin("opencode"),
        persistence: JSONLScanCachePersistence(namespace: "codex-opencode-gateway", schemaVersion: 4)
    )
}

/// Reuses the authoritative native parse record without decoding native token/timestamp fields.
/// The existing writer validates record path and the complete source revision. This projection
/// never replaces native records; the gateway scanner persists only the resulting gateway events.
struct CodexGatewayCacheProjection: Sendable {
    let persistence: JSONLScanCachePersistence
    let identity: String
    let metadata: [String: JSONLScanCacheFileMetadata]

    struct ProjectedEvent: Codable, Sendable {
        var event: CodexLogUsageScanner.Event?
        private enum CodingKeys: String, CodingKey { case model }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let model = try container.decode(String.self, forKey: .model)
            event = OpenCodeUsageScanner.isHostedGatewayModel(model)
                ? try CodexLogUsageScanner.Event(from: decoder) : nil
        }

        func encode(to encoder: any Encoder) throws {
            if let event { try event.encode(to: encoder) }
            else {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("", forKey: .model)
            }
        }
    }

    static func load(persistence: JSONLScanCachePersistence, identity: String,
                     files: [JSONLScanning.DiscoveredFile]) -> Self {
        var matching: [String: JSONLScanCacheFileMetadata] = [:]
        let diagnosticPrefix = Self.diagnosticPrefix(persistence: persistence, identity: identity)
        do {
            if let manifest = try JSONLScanCacheWriter.shared.loadManifest(
                persistence: persistence, identity: identity
            ), manifest.formatVersion == JSONLScanCachePaths.formatVersion,
               manifest.schemaVersion == persistence.schemaVersion, manifest.identity == identity {
                for file in files {
                    if let cached = manifest.files[file.path], cached.size == file.size,
                       cached.mtime == file.mtime, cached.attributeMtime == file.attributeMtime {
                        matching[file.path] = cached
                    } else {
                        DiagnosticGate.clearFailures(prefix: Self.recordDiagnosticPrefix(
                            persistence: persistence,
                            identity: identity,
                            path: file.path
                        ))
                    }
                }
            }
            DiagnosticGate.clearFailure(diagnosticPrefix + "manifest")
        } catch {
            DiagnosticGate.logOnce(for: diagnosticPrefix + "manifest") {
                AppLog.warn(LogTag.plugin("opencode"), "native gateway parse manifest unreadable; reparsing source")
            }
        }
        return Self(persistence: persistence, identity: identity, metadata: matching)
    }

    func read(at url: URL) -> [CodexLogUsageScanner.Event]? {
        guard let expected = metadata[url.path] else { return nil }
        let failurePrefix = Self.recordDiagnosticPrefix(
            persistence: persistence, identity: identity, path: url.path
        )
        let diagnosticKey = failurePrefix + JSONLScanCachePaths.stableFingerprint([
            String(expected.size),
            String(expected.mtime.timeIntervalSinceReferenceDate),
            expected.attributeMtime.map { String($0.timeIntervalSinceReferenceDate) } ?? "no-attribute-mtime",
            expected.recordFileName
        ].joined(separator: "|"))
        do {
            guard let record = try JSONLScanCacheWriter.shared.loadRecord(
                persistence: persistence, identity: identity, path: url.path,
                metadata: expected, itemType: ProjectedEvent.self
            ) else {
                DiagnosticGate.logOnce(for: diagnosticKey) {
                    AppLog.warn(LogTag.plugin("opencode"), "native gateway parse record unreadable; reparsing source")
                }
                return nil
            }
            DiagnosticGate.clearFailures(prefix: failurePrefix)
            return record.items.compactMap(\.event)
        } catch {
            DiagnosticGate.logOnce(for: diagnosticKey) {
                AppLog.warn(LogTag.plugin("opencode"), "native gateway parse record read failed; reparsing source")
            }
            return nil
        }
    }

    private static func diagnosticPrefix(
        persistence: JSONLScanCachePersistence,
        identity: String
    ) -> String {
        let scope = [persistence.directory.standardizedFileURL.path, persistence.namespace, identity]
            .joined(separator: "|")
        return "codex.gateway.cache-projection.\(JSONLScanCachePaths.stableFingerprint(scope))."
    }

    private static func recordDiagnosticPrefix(
        persistence: JSONLScanCachePersistence,
        identity: String,
        path: String
    ) -> String {
        diagnosticPrefix(persistence: persistence, identity: identity)
            + "record.\(JSONLScanCachePaths.stableFingerprint(path))."
    }
}
