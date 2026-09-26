# Upstream provenance

Status: **owned fork.** This resolves the question left open by issue #41 in `tverma101/Tools`,
where this tree was vendored and tracked with no commits and no recorded provenance.

## Upstream

- Repository: `https://github.com/robinebers/openusage`
- Author: Robin Ebers
- License: MIT (see `LICENSE`)
- Brand: the OpenUsage name and logo are trademarks of Robin Ebers and are **not** used here, per
  `TRADEMARK.md`. This project is a fork and is not the official OpenUsage.

## Imported revision

The subtree arrived in `tverma101/Tools` with its history squashed to nothing — 544 tracked files,
zero commits — so the original revision could not be recovered from local Git history.

It is now pinned by this repository's own history instead:

| Commit | What it is |
| ------ | ---------- |
| `3866cd1` | `chore: establish as-is baseline of vendored OpenUsage tree` — verbatim import, before any local change |
| `5818ab1` | `refactor: drop Sparkle auto-update pipeline` |
| `17776c5` | `refactor: rebrand OpenUsage to QuotaBar` |

`3866cd1` is the exact upstream-equivalent tree, so `git diff 3866cd1..HEAD` is the complete local
delta. The upstream version at import was `v0.7.10-beta.3`, per `CHANGELOG.md`.

To recover the true upstream SHA, diff this tree against upstream tags rather than guessing:

```sh
git clone https://github.com/robinebers/openusage /tmp/openusage-upstream
git --no-pager diff --stat 3866cd1 -- /tmp/openusage-upstream   # compare trees
```

## Local deltas from upstream

Only two, both deliberate and both traceable to a decision:

1. **Sparkle auto-updates removed** (`5818ab1`). Sparkle fetches its appcast and DMGs anonymously,
   which requires a public repository. This one is private, so the updater, its Settings section, the
   dashboard banner, the release workflow and the GitHub Pages workflows are gone. Releases are manual.
2. **Rebrand to QuotaBar** (`17776c5`). Required by `TRADEMARK.md`. Build identity, user-facing
   strings, on-disk paths and the bundle id all changed. Internal symbols (`OpenUsageISO8601`,
   `Bundle.openUsageResources`) were left alone deliberately, to keep the upstream diff small.

Pricing needed no equivalent change: `ModelPricingStore` reads the pricing supplement from upstream's
public URL, so Cursor model rates keep updating on upstream's schedule.

## Update procedure

Refreshing from upstream is now safe and reviewable:

```sh
git fetch upstream
git diff HEAD..upstream/main --stat     # what upstream changed
git merge upstream/main                 # conflicts are expected in rebranded files only
swift build && swift test
```

Expect conflicts in anything that carries the product name. Resolve toward QuotaBar naming.

## Agent modification policy

QuotaBar is a maintained fork, so the old "do not edit this subtree" quarantine no longer applies.
The engineering conventions in `AGENTS.md` govern. The upstream notices — `LICENSE`,
`CODE_OF_CONDUCT.md`, `SECURITY.md`, `CONTRIBUTING.md`, `TRADEMARK.md` — must not be removed or
rewritten, and upstream attribution must be preserved.
