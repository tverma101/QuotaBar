import QuotaBar
import SwiftUI
import Darwin

@main
enum QuotaBarMain {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--diagnose") {
            let status = await HeadlessDiagnosticCommand.run(
                arguments: arguments,
                defaultsDomain: Bundle.main.bundleIdentifier ?? "com.tverma101.quotabar"
            )
            exit(status)
        }
        OpenUsageApp.main()
    }
}

struct OpenUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu-bar app: the status item and custom panel are AppKit-owned (see StatusItemController),
        // so no window scene is wanted. `Settings` gives SwiftUI a valid scene without creating
        // an activation window.
        Settings {
            EmptyView()
        }
    }
}
