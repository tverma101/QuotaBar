import Foundation

/// Accounting-only files pulled by VM Box over SSH. They never contain credentials or transcripts.
/// The existing peer-history merger combines each VM once, without replacing local quota state.
@MainActor
final class VMBoxUsageHistory {
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/vmbox/usage", isDirectory: true)
    }

    struct Result: Equatable {
        var documents: [UsageHistoryDocument] = []
        var warnings: [String: String] = [:]
    }

    private struct Metadata: Decodable {
        var vmboxAccounts: [String: String]?
        var vmboxFetchedAt: [String: String]?
        var vmboxWarnings: [String: String]?
    }

    private struct Cached {
        var stamp: String
        var document: UsageHistoryDocument
        var metadata: Metadata
    }

    private let directory: URL
    private var cache: [URL: Cached] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    func load(identityKeys: [String: String], providerIDs: Set<String>, now: Date) -> Result {
        var result = Result()
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("vmbox-") && $0.pathExtension == "json" }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return result
        } catch {
            AppLog.warn(.config, "VM Box accounting directory is unreadable")
            return retainedResult(identityKeys: identityKeys, providerIDs: providerIDs, now: now)
        }
        guard files.count <= 16 else {
            AppLog.warn(.config, "VM Box accounting exceeds the device-file limit")
            return retainedResult(identityKeys: identityKeys, providerIDs: providerIDs, now: now)
        }
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard (attributes[.type] as? FileAttributeType) == .typeRegular,
                      let size = attributes[.size] as? NSNumber, size.intValue <= 2_097_152,
                      let modified = attributes[.modificationDate] as? Date
                else { throw CocoaError(.fileReadCorruptFile) }
                let stamp = "\(attributes[.systemFileNumber] ?? "")|\(size)|\(modified.timeIntervalSince1970)"
                if cache[file]?.stamp != stamp {
                    let data = try Data(contentsOf: file)
                    guard data.count <= 2_097_152 else { throw CocoaError(.fileReadCorruptFile) }
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .custom { decoder in
                        let raw = try decoder.singleValueContainer().decode(String.self)
                        guard let date = OpenUsageISO8601.date(from: raw) else {
                            throw DecodingError.dataCorruptedError(
                                in: try decoder.singleValueContainer(), debugDescription: "Invalid VM accounting date"
                            )
                        }
                        return date
                    }
                    let document = try decoder.decode(UsageHistoryDocument.self, from: data)
                    try document.validate()
                    guard document.deviceID.hasPrefix("vmbox-"), document.updatedAt <= now.addingTimeInterval(300) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    cache[file] = Cached(stamp: stamp, document: document,
                                         metadata: try decoder.decode(Metadata.self, from: data))
                }
            } catch {
                // Atomic writers leave no partial file; an unreadable replacement still cannot
                // erase a previously imported receipt. Retain it and make the failure visible.
                AppLog.warn(.config, "VM Box accounting file was invalid; retaining last known history")
                if let cached = cache[file] {
                    for provider in cached.document.providers.keys {
                        result.warnings[provider] = "VM Box Usage Could Not Be Read; Last Known Totals Retained"
                    }
                }
            }
        }
        let retained = retainedResult(identityKeys: identityKeys, providerIDs: providerIDs, now: now)
        result.documents = retained.documents
        result.warnings.merge(retained.warnings) { previous, _ in previous }
        return result
    }

    private func retainedResult(identityKeys: [String: String], providerIDs: Set<String>, now: Date) -> Result {
        var result = Result()
        for cached in cache.values.sorted(by: { $0.document.deviceID < $1.document.deviceID }) {
            var document = cached.document
            document.providers = [:]
            document.identities = nil
            for (family, history) in cached.document.providers {
                guard ["zai", "opencode", "antigravity", "claude", "codex"].contains(family) else { continue }
                let targetIDs: [String]
                if family == "claude" || family == "codex" {
                    guard let account = cached.metadata.vmboxAccounts?[family], !account.isEmpty else {
                        for id in providerIDs where ProviderAccountID.family(of: id) == family {
                            result.warnings[id] = "VM Box Usage Needs A Matching Account Identity"
                        }
                        continue
                    }
                    targetIDs = identityKeys.compactMap { id, identity in
                        ProviderAccountID.family(of: id) == family
                            && identity.caseInsensitiveCompare(account) == .orderedSame ? id : nil
                    }
                    guard targetIDs.count == 1 else { continue }
                    if family == "claude", let id = targetIDs.first {
                        document.identities = [id: account.lowercased()]
                        document.schema = UsageHistoryDocument.accountSchema
                    }
                } else {
                    targetIDs = providerIDs.contains(family) ? [family] : []
                }
                for id in targetIDs {
                    document.providers[id] = history
                    let stamp = cached.metadata.vmboxFetchedAt?[family]
                        .flatMap(OpenUsageISO8601.date(from:)) ?? cached.document.updatedAt
                    if now.timeIntervalSince(stamp) > 300 {
                        result.warnings[id] = "VM Box Usage Is Offline Or Outdated; Last Known Totals Retained"
                    }
                    if cached.metadata.vmboxWarnings?[family] != nil {
                        result.warnings[id] = "Some VM Box Usage Could Not Be Read; Last Known Totals Retained"
                    }
                }
            }
            if !document.providers.isEmpty { result.documents.append(document) }
        }
        result.documents = UsageHistoryDocument.newestByDevice(result.documents)
        return result
    }
}
