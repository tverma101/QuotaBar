# Preparing a Release

## macOS

Only ship a build from the exact approved release tag. A local development build is not suitable for distribution. The release owner needs an installed **Developer ID Application** identity and a configured `notarytool` Keychain profile; never commit signing or notarization credentials. A provisioning profile is not required for notarization. iCloud Sync remains unavailable without its own matching profile.

Run [the test suites](testing.md) on the candidate. With `CODESIGN_IDENTITY` set to your Developer ID Application identity and `NOTARY_PROFILE` set to your notarytool profile name, run from the repository root:

```sh
RELEASE=1 CODESIGN_IDENTITY="$CODESIGN_IDENTITY" ./script/build_and_run.sh build
codesign --verify --deep --strict --verbose=2 dist/QuotaBar.app
codesign -dv --verbose=4 dist/QuotaBar.app
lipo -archs dist/QuotaBar.app/Contents/MacOS/QuotaBar
lipo -archs dist/QuotaBar.app/Contents/Helpers/quotabar
```

The app signature must show a Developer ID Application authority. Both binaries must report `arm64` and `x86_64`. From a clean output directory (no existing `dist/QuotaBar.dmg`), package only the staged app and the Applications shortcut:

```sh
stage=$(mktemp -d .build/quotabar-dmg.XXXXXXXX)
ditto dist/QuotaBar.app "$stage/QuotaBar.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname QuotaBar -srcfolder "$stage" -format UDZO dist/QuotaBar.dmg
codesign --timestamp --sign "$CODESIGN_IDENTITY" dist/QuotaBar.dmg
xcrun notarytool submit dist/QuotaBar.dmg --keychain-profile "$NOTARY_PROFILE" --wait
```

Stop unless notarization reports `Accepted`. Then verify the exact image you intend to ship:

```sh
xcrun stapler staple dist/QuotaBar.dmg
xcrun stapler validate dist/QuotaBar.dmg
spctl --assess --type open --context context:primary-signature --verbose=2 dist/QuotaBar.dmg
```

Before publishing, install from that image on a clean Mac user profile with Gatekeeper enabled. Verify drag-to-Applications, first launch, opening the dashboard from the menu bar, Customize with no provider signed in, Settings, and quit/reopen. Check macOS 15 and macOS 26 on both CPU architectures where available; record untested combinations instead of declaring parity. Also verify replacing the previous release retains customization, if a previous public release exists.

## Windows

Create the owner-approved version tag from the tested commit on `main`. Run **Windows CI** on that tag. The workflow uses the tag as the installer version and tests the per-user install, bundled CLI, cached limits, and uninstall before uploading `quotabar-windows-x64-qa`.

Download the artifact from that run and verify its archive SHA-256 against the digest reported by GitHub Actions. Extract the matching `QuotaBar_<version>_x64-setup.exe`. The build uses MSVC for the public installer.

To reproduce the tagged build locally, check out the same tag on Windows x64 and run these commands from PowerShell in `windows/`.

```powershell
$tag = git describe --exact-match --tags HEAD
if ($LASTEXITCODE -ne 0 -or $tag -notmatch '^v\d+\.\d+\.\d+(?:-beta\.\d+)?$') {
    throw "Check out the exact release tag before building."
}
$config = Join-Path $env:TEMP "quotabar-$tag.json"
@{ version = $tag.Substring(1) } | ConvertTo-Json -Compress | Set-Content -Encoding Ascii $config
bun install --frozen-lockfile
bun run test
bun run tauri:build --bundles nsis --config $config -- --locked
```

Publish an unsigned Windows prerelease when the owner approves it. State that the installer is unsigned and Windows may show a SmartScreen or publisher prompt. For a signed build, sign the app and CLI before packaging, then sign the installer. Use `Get-AuthenticodeSignature` to check that the installer and both installed executables report `Valid` and the expected signer.

To repeat the CI smoke test in a disposable user profile, run `./scripts/smoke-installer.ps1 -Installer <setup.exe>` from `windows/`. For Windows 11 x64 desktop QA, check first launch, Settings, tray reopen, and a refresh while the panel is closed. Verify a clean WebView2 setup and an upgrade from the previous beta that retains layout and provider settings. Record which cases ran in the release notes. [Windows local API](../windows/docs/local-http-api.md)

## GitHub

Create a draft GitHub release for the approved tag. Attach each tested installer and a `SHA256SUMS.txt` with the hash of each attached binary. Mark beta releases as prereleases. State the platforms included, link to source build instructions for other platforms, and link to the tagged CI run.

After publishing, download each asset without GitHub credentials and verify the installer hashes against the published checksum file. Link the current installer and release notes in the READMEs, and move the shipped changes from **Unreleased** into their version section in the changelog. [GitHub Releases](https://github.com/tverma101/QuotaBar/releases)
