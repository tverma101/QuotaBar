import SwiftUI

/// The one-time first-run hint card at the top of the dashboard. Fresh installs start with the small
/// default provider set (see `FirstRunSeeder`), so this card points the user to Customize to add more.
/// It appears only while `OnboardingStore.isCustomizeHintPending` is
/// set — marked by the seeder on a fresh install, so existing installs never see it — and goes away
/// for good only on its close button. Visiting Customize deliberately does NOT dismiss it: a quick
/// look around shouldn't cost a new user the pointer.
///
/// A grouped content card (`cardSurface`), not chrome: it scrolls with the provider sections and uses
/// the same surface they do.
struct CustomizeHintCard: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout

    var body: some View {
        DismissableHintCard(
            systemImage: "slider.horizontal.3",
            title: "Welcome to QuotaBar",
            message: "Claude, Codex, Cursor, and Freebuff are on. Add or hide providers any time.",
            buttonTitle: "Open Customize",
            action: { withAnimation(Motion.modeSwitch) { layout.screen = .customize } },
            onDismiss: { withAnimation(Motion.spring) { container.onboarding.dismissCustomizeHint() } }
        )
    }
}
