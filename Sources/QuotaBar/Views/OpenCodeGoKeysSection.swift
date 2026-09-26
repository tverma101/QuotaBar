import SwiftUI

/// The OpenCode Go Keys card in the provider's Customize detail: every key the card can use
/// (`auth.json` entries read-only + keys saved through the app), an add-expander for a new key,
/// and per-row selection — tapping a row pins the card to that key's account (the meters swap),
/// tapping "Show All Accounts" unpins back to every distinct account. Removing an app-saved key
/// is a per-row clear; `auth.json` keys cannot be removed from the app.
///
/// After any change the card clears the provider's failure backoff and forces a refresh so the
/// dashboard reflects the new key or selection immediately.
struct OpenCodeGoKeysSection: View {
    let provider: any GoKeyManaging
    @Environment(WidgetDataStore.self) private var dataStore
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    @State private var isOpen = false
    /// The key list, seeded on appear and re-read after each mutation so the rows stay truthful.
    @State private var entries: [OpenCodeGoKeyEntry] = []

    // Transient add-editor state.
    @State private var labelInput = ""
    @State private var keyInput = ""
    @State private var actionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("OpenCode Go Keys")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                headerRow
                if isOpen {
                    Divider()
                    addBlock
                }
                if !entries.isEmpty {
                    Divider()
                    keyRows
                }
            }
            .cardSurface()
            .clipShape(Theme.cardShape)
        }
        .onAppear {
            refreshEntries()
            if entries.isEmpty { isOpen = true }
        }
    }

    // MARK: - Rows

    private var headerRow: some View {
        HStack(spacing: 10) {
            ProviderIcon(source: provider.provider.icon)
                .frame(width: 18, height: 18)
            Text(provider.provider.displayName)
            Spacer(minLength: 8)
            Button(isOpen ? "Done" : "Add Key") {
                toggleExpand()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    /// One row per key, plus the "Show All Accounts" unpin row when more than one key exists.
    /// Tapping a row pins the card to that key's account; the checkmark marks the active state.
    private var keyRows: some View {
        VStack(spacing: 0) {
            if entries.count > 1 {
                selectionRow(
                    id: nil,
                    label: "Show All Accounts",
                    detail: "Every distinct account",
                    masked: nil,
                    source: nil,
                    removeAction: nil
                )
            }
            ForEach(entries) { entry in
                Divider()
                selectionRow(
                    id: entry.id,
                    label: entry.label,
                    detail: sourceHint(entry.source),
                    masked: entry.maskedKey,
                    source: entry.source,
                    removeAction: entry.source == .appSaved ? { remove(entry) } : nil
                )
            }
        }
    }

    private func selectionRow(
        id: String?,
        label: String,
        detail: String,
        masked: String?,
        source: OpenCodeGoKeySource?,
        removeAction: (() -> Void)?
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: id != nil && isActive(id) ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(id != nil && isActive(id) ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    if let masked {
                        Text(masked)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospaced()
                    }
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if let removeAction {
                Button(action: removeAction) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(label)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let id {
                select(id)
            } else {
                clearSelection()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    // MARK: - Add editor

    private var addBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a Go key from another account — e.g. the opencode-go key of a second machine.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("Label (optional)", text: $labelInput)
                .textFieldStyle(.roundedBorder)
            SecureField("sk-…", text: $keyInput)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!hasKeyInput)
                Button("Cancel") {
                    resetEditor()
                    isOpen = false
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(Theme.notice)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Rectangle().fill(.fill.quinary))
    }

    // MARK: - Helpers

    private var hasKeyInput: Bool {
        !keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isActive(_ id: String?) -> Bool {
        guard let id else { return false }
        return entries.first { $0.id == id }?.isActive == true
    }

    private func sourceHint(_ source: OpenCodeGoKeySource) -> String {
        switch source {
        case .authFile: "From OpenCode"
        case .appSaved: "Saved in App"
        }
    }

    private func refreshEntries() {
        entries = provider.goKeyEntries()
    }

    private func toggleExpand() {
        isOpen.toggle()
        if isOpen { resetEditor() }
    }

    private func resetEditor() {
        labelInput = ""
        keyInput = ""
        actionError = nil
    }

    private func select(_ id: String) {
        provider.selectGoKey(id: id)
        refreshEntries()
        triggerRefresh()
    }

    private func clearSelection() {
        // No protocol-level clear: selecting nothing = the default "show all accounts" state.
        if provider.activeGoKeyID() != nil {
            OpenCodeGoKeyStore.setActiveSelection(nil)
        }
        refreshEntries()
        triggerRefresh()
    }

    private func save() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try provider.saveGoKey(label: labelInput, key: key)
            resetEditor()
            refreshEntries()
            triggerRefresh()
        } catch {
            actionError = error.localizedDescription
            AppLog.error(.auth, "OpenCode Go key save failed: \(error.localizedDescription)")
        }
    }

    private func remove(_ entry: OpenCodeGoKeyEntry) {
        guard let id = UUID(uuidString: entry.id) else { return }
        do {
            try provider.removeGoKey(id: id)
            refreshEntries()
            triggerRefresh()
        } catch {
            actionError = error.localizedDescription
            AppLog.error(.auth, "OpenCode Go key remove failed: \(error.localizedDescription)")
        }
    }

    /// Clear any failure backoff so the wake refresh actually probes the provider, then force a
    /// refresh so the dashboard shows the new key's or selection's data immediately.
    private func triggerRefresh() {
        let id = provider.provider.id
        dataStore.clearFailureBackoff(for: id)
        Task { await dataStore.refresh(providerID: id, force: true) }
    }
}
