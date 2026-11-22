# Preparing a macOS Release

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

Attach the validated DMG to the approved GitHub Release, mark beta releases as **pre-release**, then test the public Assets link without signing into GitHub. Do not ship a release with only source archives. There is no auto-update feed.
