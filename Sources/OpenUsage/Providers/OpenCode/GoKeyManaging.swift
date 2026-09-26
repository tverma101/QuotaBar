import Foundation

/// Where a Go key came from — OpenCode's own `auth.json` (read-only from the app's perspective)
/// or saved through the app's settings (`OpenCodeGoKeyStore`).
enum OpenCodeGoKeySource: Sendable, Equatable {
    case authFile
    case appSaved
}

/// One row in the OpenCode Go Keys settings section: a stable id (the `auth.json` entry name for
/// file keys, the saved key's UUID otherwise), a display label, a masked preview, its source, and
/// whether it is the active selection driving the card's account meters.
struct OpenCodeGoKeyEntry: Sendable, Equatable, Identifiable {
    var id: String
    var label: String
    var maskedKey: String
    var source: OpenCodeGoKeySource
    var isActive: Bool
}

/// A `ProviderRuntime` whose account meters are keyed to one of several OpenCode Go API keys.
/// The provider's Customize detail renders `OpenCodeGoKeysSection` through this capability:
/// list every usable key (auth.json + app-saved), add/remove app-saved keys, and pick which
/// key's account the card shows. Mirrors `APIKeyManaging`'s shape — the UI stays
/// provider-agnostic, the provider owns the storage.
@MainActor
protocol GoKeyManaging: ProviderRuntime {
    /// Every Go key the card can use, in fetch order: the `opencode-go` auth.json entry first, then
    /// app-saved keys. `isActive` marks the current selection.
    func goKeyEntries() -> [OpenCodeGoKeyEntry]
    /// Persist a new key via the app-owned store. Returns the stored entry.
    @discardableResult
    func saveGoKey(label: String, key: String) throws -> OpenCodeGoKey
    /// Remove an app-saved key. `auth.json` entries cannot be removed from the app.
    func removeGoKey(id: UUID) throws
    /// Make `id` (a saved key's UUID or an `auth.json` entry name) the active selection.
    func selectGoKey(id: String)
    /// The active selection, or `nil` when no key is pinned (the card shows every distinct
    /// account).
    func activeGoKeyID() -> String?
}
