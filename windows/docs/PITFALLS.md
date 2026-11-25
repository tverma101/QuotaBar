# Pitfalls

## Native tests need Windows Common Controls v6

From `windows/`, run `cargo test --locked -p quotabar --lib` to run the native Tauri unit tests.
The build script embeds the Common Controls v6 manifest in both the app and the test executable.
Tauri's default resource step only links the manifest into the app binary; without it the Windows
test executable can exit with `0xc0000139` before running any tests.

## 2026-11-04 — Cloud Code may omit Gemini quota for an old or unversioned client identity

QuotaBar 1.6.1 displayed only the Claude/GPT Antigravity CLI quota although `agy /quota` showed Gemini five-hour and weekly quotas on the same account. The Cloud Code summary response was valid but incomplete for `User-Agent: antigravity`; the plugin accepted its two third-party buckets and skipped the legacy fallback. An isolated probe with `antigravity/cli/1.5.0` restored the Gemini buckets, while `antigravity/cli/1.0.0` reproduced the omission. Use a versioned client identity verified against the native CLI and check all expected bucket groups.
