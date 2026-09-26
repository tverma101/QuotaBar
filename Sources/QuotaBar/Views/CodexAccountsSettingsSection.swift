import SwiftUI

/// Settings surface for additional Codex accounts. Codex owns the sign-in itself; this view only
/// starts that official flow and displays the resulting local registration state.
struct CodexAccountsSettingsSection: View {
    let accounts: CodexAccountRegistrationStore
    let registration: CodexAccountRegistrationService

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @State private var actionError: String?
    @State private var actionNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("Codex Accounts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            VStack(spacing: 0) {
                Text("QuotaBar uses Codex's own browser sign-in. Each additional account gets its own CODEX_HOME and usage card; QuotaBar never sees or stores your credentials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(accounts.registeredHomes, id: \.self) { home in
                    registeredHomeRow(home)
                }

                if registration.state.isSigningIn {
                    signingInRow
                } else {
                    Button {
                        beginLogin()
                    } label: {
                        Label("Sign in to Codex…", systemImage: "person.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .glassButtonStyle()
                    .controlSize(.regular)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                }

                Button {
                    registerExistingHome()
                } label: {
                    Text("Use Existing Codex Home…")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .disabled(registration.state.isSigningIn)

                Text("Codex opens your default browser and completes OAuth. When it finishes, QuotaBar reloads its account catalog and starts the new usage card automatically. Removing a registration never deletes Codex credentials or history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let actionNotice {
                    inlineNotice(actionNotice, color: .secondary)
                }
                if let actionError {
                    inlineNotice(actionError, color: Theme.notice)
                }
            }
            .cardSurface()
        }
        .onChange(of: registration.state) { _, state in
            switch state {
            case .signedIn(let label):
                actionError = nil
                actionNotice = label.map { "Signed in as \($0). QuotaBar is loading this account's usage card." }
                    ?? "Codex sign-in complete. QuotaBar is loading this account's usage card."
            case .failed(let message):
                actionNotice = nil
                actionError = message
            case .idle, .signingIn:
                break
            }
        }
    }

    private var signingInRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for Codex sign-in")
                    .font(.callout.weight(.medium))
                Text("Finish the browser approval. Codex is handling the secure callback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Cancel") {
                registration.cancelLogin()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Codex sign-in in progress")
    }

    private func registeredHomeRow(_ home: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Additional Codex account")
                Text((home as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                accounts.remove(home: home)
                actionError = nil
                actionNotice = "Registration removed. Codex files were left untouched."
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Remove Codex home registration")
            .hoverTooltip("Stop tracking this home")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    private func beginLogin() {
        do {
            try registration.beginLogin()
            actionError = nil
            actionNotice = "Codex opened your browser for sign-in. Finish there; QuotaBar will load the account automatically when Codex completes."
        } catch {
            actionNotice = nil
            actionError = error.localizedDescription
            AppLog.error(.config, "Codex account sign-in failed to start: \(error.localizedDescription)")
        }
    }

    private func registerExistingHome() {
        guard let home = CodexAccountRegistrationService.chooseExistingHome() else { return }
        do {
            let label = try registration.registerExistingHome(at: home)
            actionError = nil
            actionNotice = label.map { "Registered Codex account \($0). QuotaBar is loading its usage card." }
                ?? "Codex home registered. QuotaBar is loading its account card."
        } catch {
            actionNotice = nil
            actionError = error.localizedDescription
        }
    }

    private func inlineNotice<S: ShapeStyle>(_ text: String, color: S) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
