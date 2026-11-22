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

On Windows x64, check out the same approved tag used for the DMG. Build the per-user setup executable from PowerShell in `windows/`:

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

Sign the setup executable with the release publisher's Windows code-signing identity if available. Verify the installer on a Windows 11 x64 user profile. Check the default location, Start menu, first launch, Settings, tray dismiss and reopen, provider refresh, and the [local HTTP API](../windows/docs/local-http-api.md) while the panel is closed. Verify an upgrade preserves settings and provider selection.

## GitHub

Attach the verified DMG and Windows setup executable to the approved tag, add platform-specific installation instructions, and mark beta releases as pre-releases. State the Windows signature status in the notes. Verify both download links while signed out.
