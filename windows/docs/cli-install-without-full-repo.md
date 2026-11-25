# Run the Windows CLI

The Windows x64 installer includes `quotabar-cli.exe` in the per-user QuotaBar folder. Open PowerShell and run it by its full path. [Download the Windows installer](../README.md)

```powershell
& "$env:LOCALAPPDATA\QuotaBar\quotabar-cli.exe" read
& "$env:LOCALAPPDATA\QuotaBar\quotabar-cli.exe" read codex --force --diagnose
```

`read` uses fresh tray snapshots when available and refreshes missing or stale data. Add `--force` for a fresh probe. [CLI guide](../../docs/cli.md#windows)

## Build Just the CLI

With Git and stable Rust installed, make a shallow checkout of the release tag and build the CLI crate. Cargo embeds the bundled provider plugins during the build.

```powershell
git clone --depth 1 --branch v0.7.2-beta.2 https://github.com/tverma101/QuotaBar.git
cd QuotaBar/windows
cargo build --release --locked -p quotabar-cli
.\target\release\quotabar-cli.exe read codex
```
