import Foundation

/// Every local directory where an Antigravity client keeps its conversation databases. Discovery only
/// lists directories on the user's disk; it never reads credentials or writes into another app's profile.
///
/// - `~/.gemini/antigravity*/conversations`: the app, IDE, CLI, and compatible clients.
/// - `~/.config/antigravity/conversations`: the XDG location some clients use.
/// - `~/.t3/userdata/providers/antigravity/<instance>/antigravity-acp/conversations`: T3 Code runs
///   Antigravity through its ACP adapter with a private home per instance, so its usage never appears
///   under `~/.gemini`.
enum AntigravityConversationRoots {
    static let t3ProfilesRootSubpath = ".t3/userdata/providers/antigravity"
    static let xdgConversationsSubpath = ".config/antigravity/conversations"

    static func discover(home: URL) -> AntigravityDbUsageScanner.ConversationDirectoryDiscovery {
        var directories: [String] = []
        var failures: [String: String] = [:]

        let geminiRoot = home.appendingPathComponent(".gemini", isDirectory: true)
        do {
            let discovery = try AntigravityDbUsageScanner.discoverConversationDirectories(in: geminiRoot)
            directories.append(contentsOf: discovery.directories)
            failures.merge(discovery.failures) { _, new in new }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // No ~/.gemini yet; the other roots may still hold conversations.
        } catch {
            // A broken ~/.gemini must not freeze readable sibling roots. Recording the failure keeps the
            // cached rows for that root and surfaces the read warning while the others still update.
            failures[geminiRoot.path] = error.localizedDescription
        }

        let xdgConversations = home.appendingPathComponent(xdgConversationsSubpath, isDirectory: true)
        if isDirectory(xdgConversations) {
            directories.append(xdgConversations.path)
        }

        let t3Root = home.appendingPathComponent(t3ProfilesRootSubpath, isDirectory: true)
        do {
            directories.append(contentsOf: try t3ConversationDirectories(in: t3Root))
        } catch {
            failures[t3Root.path] = error.localizedDescription
        }

        return AntigravityDbUsageScanner.ConversationDirectoryDiscovery(
            directories: Array(Set(directories)).sorted(),
            failures: failures
        )
    }

    /// T3 Code's private instance stores, canonicalized so a symlinked profile is read once. A missing
    /// profiles root is the normal "no T3 Code" case; one that exists but cannot be listed throws so the
    /// caller reports it instead of silently dropping usage.
    static func t3ConversationDirectories(in root: URL) throws -> [String] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        var found = Set<String>()
        for name in try fileManager.contentsOfDirectory(atPath: root.path).sorted() {
            let conversations = root
                .appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("antigravity-acp", isDirectory: true)
                .appendingPathComponent("conversations", isDirectory: true)
            guard isDirectory(conversations) else { continue }
            found.insert(conversations.resolvingSymlinksInPath().path)
        }
        return found.sorted()
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
