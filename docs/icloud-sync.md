# iCloud Sync

**Sync Across Macs** is off by default. When it is on, each Mac writes one versioned QuotaBar history
file to the app's private iCloud container and reads the files written by other Macs signed into the same
iCloud account. A random device ID is kept in the login Keychain so the same Mac continues updating its
existing file after app preferences are reset or the app is reinstalled. There is no folder picker,
pairing code, or separate account. QuotaBar resolves that ID only when sync is enabled, and reads it
silently; while sync is off, it does not access the iCloud sync Keychain item.

The file contains up to 10 years of daily tokens, spend, and public-rate estimates, plus 30 days of
model totals and unknown-model names for sources that are local to one Mac: Claude, Codex, Grok, and
OpenCode. Older per-model detail is omitted because the spend tiles and provider breakdowns show only
the 30-day window. The file also includes Claude account and
organization identities when available, but never credentials, account limits, raw logs, or provider
responses. Cursor's history is already account-wide, so it stays local and is never added across Macs.
Disabling a provider immediately removes its peer contributions from the combined view and omits it from
this Mac's next iCloud write, while its local cached snapshot remains.

Claude history that identifies its account and organization is combined only with matching accounts on
other Macs. Older single-account history without account information remains compatible when only one
Claude card is visible, and is ignored when multiple cards are visible. Codex syncing works the same way
it did before.

QuotaBar combines the valid files in memory and rebuilds Today, Yesterday, Last 30 Days, Usage Trend,
unknown-model warnings, and model breakdowns. Merged history keeps up to 10 years of calendar days;
the spend tiles and trend still show their 30-day window. A provider's own scan or ledger retention may
be shorter. The same combined spend rows and history feed the dashboard, Total
Spend, menu-bar pins, share cards, and the local HTTP API. Both `/v1/usage` and `/v1/limits` read the
same rendered snapshots; the former is the deprecated UI-oriented format and the latter is the
normalized format. Quotas, plans, balances, and provider errors remain this Mac's own values inside
those snapshots. Peer rows outside the ten-year merged-history window are ignored.

This Mac updates its file after local usage history changes, initial sync setup, or a provider enablement
change. Quota-only refreshes do not rewrite the history file. iCloud delivery is eventually consistent, so another Mac can take longer than five minutes to
receive it, especially while offline. Downloaded changes reload immediately when macOS reports them.

Settings lists each valid device file with the time that Mac generated it. To remove a Mac from the
combined summary, turn sync off on that Mac; this deletes its file from iCloud. Turning sync off also
stops that Mac from reading peers and immediately returns every surface there to local-only spend.
Malformed files are ignored and reported in Settings and the app log.

## Development and release setup

Apple requires the iCloud container assignment to be present in the provisioning profile embedded in
the app. QuotaBar uses separate resources so development builds cannot write production history:

- `com.tverma101.quotabar.dev` uses `iCloud.com.tverma101.quotabar.dev`.
- `com.tverma101.quotabar` uses `iCloud.com.tverma101.quotabar`.

Create a `MAC_APP_DEVELOPMENT` profile that includes every registered development Mac and a
`MAC_APP_DIRECT` profile for releases. Install the development profile on each included Mac. The
development build automatically selects the newest non-expired profile matching the development
bundle and iCloud container from Xcode's current profile directory or the legacy MobileDevice
directory:

```bash
./script/build_and_run.sh
```

Set `ICLOUD_PROVISIONING_PROFILE=/path/to/profile.mobileprovision` only when you need to override
that automatic selection. An explicit missing path fails the build instead of silently producing an
app without iCloud access.

The release workflow reads the base64-encoded `MAC_APP_DIRECT` profile from the repository Actions
secret `APPLE_DEVELOPER_ID_ICLOUD_PROFILE`. Keep the original provisioning profiles and signing `.p12`
in a password manager, never in the repository. A provisioning profile contains certificates and
entitlements rather than private keys, but treating it as a signing asset keeps rotation predictable.

To inspect the actual history written by a running build, find the file first and only call `jq` when a
file exists:

```bash
file=$(find "$HOME/Library/Mobile Documents" \
  -type f -path '*openusage*/QuotaBar/History/v1/*.json' -print -quit)

if [[ -n "$file" ]]; then
  jq . "$file"
else
  echo "No QuotaBar iCloud history file found"
fi
```

No file is expected when sync is off, the app is signed without the matching profile, or the first
write has not completed. The Settings error and app log distinguish those cases; the spinner only
appears while an iCloud read or write is actually in progress.
