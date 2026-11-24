import Foundation

/// T3 Code runs Antigravity through its own ACP adapter, giving every instance a private GEMINI_HOME
/// at `~/.t3/userdata/providers/antigravity/<instance-key>/antigravity-acp`. The conversation stores
/// and the instance's file-based OAuth credential live there — invisible to `~/.gemini` discovery,
/// which is why usage written by T3's Antigravity never appeared in QuotaBar. T3 Code's own usage
/// reader scans these private roots; QuotaBar mirrors that, read-only, never writing into another
/// app's profile.
enum AntigravityT3Support {
    static let profilesRootSubpath = ".t3/userdata/providers/antigravity"
    static let credentialFileName = "acp_token.json"

    /// The private conversation directories, canonicalized (symlinks resolved), deduplicated and
    /// sorted. A missing profiles root is the normal "no T3 Code" case and yields `[]`; a root that
    /// exists but cannot be listed throws so the caller can fail loudly instead of silently dropping
    /// usage it should have read.
    static func conversationDirectories(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> [String] {
        let fileManager = FileManager.default
        let root = home.appendingPathComponent(profilesRootSubpath, isDirectory: true)
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let names = try fileManager.contentsOfDirectory(atPath: root.path)
        var found = Set<String>()
        for name in names.sorted() {
            let conversations = root
                .appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("antigravity-acp", isDirectory: true)
                .appendingPathComponent("conversations", isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: conversations.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            found.insert(conversations.resolvingSymlinksInPath().path)
        }
        return found.sorted()
    }

    /// The instances' file-based OAuth credentials, most recently active profile first (the running
    /// instance is the one writing conversations), ties broken by path for determinism. A missing or
    /// unreadable profiles root is the normal "no T3 Code" case and yields `[]`.
    static func credentialFiles(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        let fileManager = FileManager.default
        let root = home.appendingPathComponent(profilesRootSubpath, isDirectory: true)
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        var candidates: [(url: URL, activity: Date)] = []
        for name in names.sorted() {
            let profile = root
                .appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("antigravity-acp", isDirectory: true)
            let credential = profile.appendingPathComponent(credentialFileName, isDirectory: false)
            guard fileManager.fileExists(atPath: credential.path) else { continue }
            let conversations = profile.appendingPathComponent("conversations", isDirectory: true)
            let activity = (try? fileManager.attributesOfItem(atPath: conversations.path))?[.modificationDate] as? Date
            candidates.append((credential, activity ?? .distantPast))
        }
        return candidates.sorted { lhs, rhs in
            if lhs.activity != rhs.activity { return lhs.activity > rhs.activity }
            return lhs.url.path < rhs.url.path
        }.map(\.url)
    }
}
