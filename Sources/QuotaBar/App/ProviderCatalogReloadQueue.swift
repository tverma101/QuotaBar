import Foundation

enum ProviderCatalogReloadRequest: Equatable {
    case codexAccounts
    case claudeAccounts
    case openCodeGoKeys
    case openCodeEnablement
}

/// Coalesces catalog callbacks while a replacement container is loading. A full account scan covers
/// both account families and OpenCode's saved-key inventory, so the most complete request wins.
struct ProviderCatalogReloadQueue {
    private var codexAccountsPending = false
    private var claudeAccountsPending = false
    private var openCodeGoKeysPending = false
    private var openCodeEnablementPending = false

    mutating func enqueue(_ request: ProviderCatalogReloadRequest) {
        switch request {
        case .codexAccounts:
            codexAccountsPending = true
            claudeAccountsPending = false
            openCodeGoKeysPending = false
            openCodeEnablementPending = false
        case .claudeAccounts:
            claudeAccountsPending = true
            openCodeGoKeysPending = false
            openCodeEnablementPending = false
        case .openCodeGoKeys:
            openCodeGoKeysPending = true
            openCodeEnablementPending = false
        case .openCodeEnablement:
            if !openCodeGoKeysPending { openCodeEnablementPending = true }
        }
    }

    mutating func takeNext() -> ProviderCatalogReloadRequest? {
        if codexAccountsPending {
            codexAccountsPending = false
            claudeAccountsPending = false
            openCodeGoKeysPending = false
            openCodeEnablementPending = false
            return .codexAccounts
        }
        if claudeAccountsPending {
            claudeAccountsPending = false
            openCodeGoKeysPending = false
            openCodeEnablementPending = false
            return .claudeAccounts
        }
        if openCodeGoKeysPending {
            openCodeGoKeysPending = false
            openCodeEnablementPending = false
            return .openCodeGoKeys
        }
        guard openCodeEnablementPending else { return nil }
        openCodeEnablementPending = false
        return .openCodeEnablement
    }
}
