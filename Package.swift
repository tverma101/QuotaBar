// swift-tools-version: 6.2
import PackageDescription

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
        .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.62.0")
    ],
    targets: [
        .target(
            name: "QuotaBar",
            dependencies: [
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
