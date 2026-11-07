import Foundation

public struct FreebuffActiveSession: Hashable, Sendable, Codable {
    public var instanceID: String
    public var expiresAt: Date
    public var model: String?
    public var threadID: String?
    public var chatTitle: String?
    public var projectPath: String?

    public init(
        instanceID: String,
        expiresAt: Date,
        model: String? = nil,
        threadID: String? = nil,
        chatTitle: String? = nil,
        projectPath: String? = nil
    ) {
        self.instanceID = instanceID
        self.expiresAt = expiresAt
        self.model = model
        self.threadID = threadID
        self.chatTitle = chatTitle
        self.projectPath = projectPath
    }

    /// Label for the session subtitle. A short mode such as "fast" stays. Provider routes
    /// (`deepseek/deepseek-v4-flash`) and opaque catalogue ids (`m-096e…`) are omitted: capitalized
    /// and truncated they repeat as "Deepseek/Deepseek…" on every row.
    public var subtitleModel: String? {
        Self.subtitleModel(from: model)
    }

    public static func subtitleModel(from raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let lower = trimmed.lowercased()
        if lower.contains("/") || lower.contains(":") { return nil }
        if lower.hasPrefix("m-") {
            let rest = lower.dropFirst(2)
            if !rest.isEmpty, rest.allSatisfy({ $0.isHexDigit || $0 == "-" }) { return nil }
        }
        if trimmed.count > 18 { return nil }
        guard let first = trimmed.first else { return nil }
        if trimmed == lower {
            return first.uppercased() + trimmed.dropFirst()
        }
        return trimmed
    }
}
