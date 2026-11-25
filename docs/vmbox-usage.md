# VM Box Provider Usage

Quota Bar imports accounting receipts from `~/.local/share/vmbox/usage/vmbox-*.json` every 30 seconds. VM Box pulls those files over authenticated SSH while its Mac link is running. This works independently of iCloud Sync.

The existing provider history rows combine Mac and VM token usage. Older Z.ai catalogs keep their existing **ZCode Tokens** tile; catalogs with daily ZCode history use those daily rows. Existing metric visibility, ordering and menu-bar pins stay under the user's control.

Quota balances and remaining credits continue to come from the provider's account API. They are never added across machines. A VM receipt contains daily token counts and, where recorded, reported costs. Missing prices remain unknown.

The importer reuses `openusage.history.v1` and its validation rules. VM Box adds optional `vmboxAccounts`, `vmboxFetchedAt` and `vmboxWarnings` metadata. Claude and Codex receipts require a matching local account identity; an unidentified account is not assigned to the current card. Account-wide histories such as Cursor are excluded.

Each VM has a stable device ID. Only the newest whole receipt for a device participates in a merge, so repeated pulls and duplicate files do not add the same VM twice. Imported history is used for display; it is not written back into the Mac's native provider cache or exported as Mac-local iCloud history.

When a VM goes offline, its last received totals remain visible with an outdated warning after five minutes. An invalid replacement retains the last valid receipt in the running app and reports a warning. Receipts contain no prompts, transcripts or authentication credentials.

Use `vmbox usage` to inspect the shared Quota Bar balances and the most recent receipt timestamps. `vmbox usage-sync` pulls accounting from an already running VM without starting compute. Restart Quota Bar after installing this integration; existing app processes cannot load new code.
