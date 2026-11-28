// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Absolute path to the Rust static library directory, so the CQuotabarCore clang target can
// link the archive produced by script/build_rust_core.sh regardless of the checkout location.
let rustCoreReleaseLibrary = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Rust/quotabar-core/target/release")
    .path

let package = Package(
    name: "QuotaBar",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        // The CLI keeps a `-cli` suffix: a bare `quotabar` would collide with the `QuotaBar`
        // library target's build output on case-insensitive filesystems (APFS default).
        .executable(name: "QuotaBar", targets: ["QuotaBarApp"]),
        .executable(name: "quotabar-cli", targets: ["QuotaBarCLI"])
    ],
    dependencies: [
        // The de-facto standard recorder + global hotkey for Mac apps (System Settings-style field).
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.1"),
        // Anonymous usage analytics and mandatory crash reporting (official first-party Swift SDK).
        .package(url: "https://github.com/PostHog/posthog-ios.git", from: "4.0.11")
    ],
    targets: [
        .target(
            name: "CQuotabarCore",
            path: "Sources/CQuotabarCore",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("quotabar_core"),
                // The Rust static library is produced by script/build_rust_core.sh (run
                // automatically by build_and_run.sh, ci.yml and script/test_suites.sh).
                .unsafeFlags(["-L", rustCoreReleaseLibrary])
            ]
        ),
        .target(
            name: "QuotaBar",
            dependencies: [
                "CQuotabarCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "PostHog", package: "posthog-ios")
            ],
            path: "Sources/QuotaBar",
            resources: [
                .copy("Resources/ProviderIcons"),
                .copy("Resources/pricing_supplement.json"),
                .copy("Resources/pricing_litellm_snapshot.json"),
                .copy("Resources/pricing_models_dev_snapshot.json")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "QuotaBarApp",
            dependencies: ["QuotaBar"],
            path: "Sources/QuotaBarApp",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "QuotaBarCLI",
            dependencies: ["QuotaBar"],
            path: "Sources/QuotaBarCLI",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "QuotaBarTests",
            dependencies: ["QuotaBar"],
            path: "Tests/QuotaBarTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "QuotaBarCLITests",
            dependencies: ["QuotaBarCLI"],
            path: "Tests/QuotaBarCLITests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
