import Foundation

/// Where Muse stores its session logs on this machine.
enum MusePaths {
    static func sessionsDirectory(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".local/share/muse/sessions")
    }
}
