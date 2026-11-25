# Windows Release Versions

Public Windows installers use the approved QuotaBar release tag, for example `v0.7.2-beta.2`. Building from that tag sets the Tauri app and NSIS installer version to `0.7.2-beta.2`. The in-app footer reports the Tauri app version.

The versions in `package.json`, the Rust crates, and the base Tauri config serve frontend builds, Cargo, and local development. Leave those versions alone when cutting a public prerelease. Older port notes refer to the original Tauri project's `1.x` version history. [Windows release process](../../docs/releasing.md#windows) · [Changelog](../../CHANGELOG.md)
