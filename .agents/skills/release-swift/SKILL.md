---
name: release-swift
description: Cut a release of QuotaBar (Swift menu-bar app): pick a version, generate a categorized changelog, tag from `main`, build a signed and notarized DMG, and publish the GitHub Release with notes. Use to ship an Early Access beta or a stable release.
---

# Release Swift

QuotaBar has **no automated release pipeline and no auto-update mechanism.** Sparkle, the `appcast.xml`
feed, `.github/workflows/release.yml`, and the `gh-pages` deploy were all removed — the upstream feed is
served from a public repository this fork has no claim on, so continuing to point builds at it would
ship users to someone else's updates.

Everything below is therefore a **manual, owner-driven process**. This skill generates the changelog and
drives the steps; the owner performs the signing and notarization with their own Apple credentials,
because those secrets must not live in this repository.

## Channels

- **Beta (Early Access):** suffixed tag like `v0.7.1-beta.1`, published as a GitHub **pre-release**.
  GitHub "Latest" is untouched, so it does not displace the current stable for anyone who installed by
  hand.
- **Stable:** plain tag like `v0.7.1`, published as a normal release and becomes GitHub "Latest".

The tag IS the version. Do not edit version files, and **never change the version without explicit
owner approval** — the line continues upstream's `0.7.x` so the two codebases stay comparable. Beta
builds add a `-beta.N` suffix.

## Before you start

Verify the tree is releasable. A release must not ship with a known-red suite:

```sh
git switch main && git pull
swift build -j 2 --disable-index-store --scratch-path /tmp/qb-scratch
swift test  -j 2 --disable-index-store --scratch-path /tmp/qb-scratch
```

`--disable-index-store` is not optional on memory-constrained machines; see `AGENTS.md`.

## Cutting a release

### 1. Choose the version

Next number in the current lane (default bump: patch). Beta builds add a `-beta.N` suffix. **Confirm
with the owner before proceeding.**

### 2. Generate the changelog

Collect commits since the **previous release in the same channel** and categorize each:

- **Stable cut:** span from the **last stable tag** to this one (e.g. `v0.7.0...v0.7.1`), so the notes
  roll up the entire beta series plus any post-beta commits. Never start a stable changelog at the last
  beta — that would omit every beta in the lane.
- **Beta cut:** span from the previous tag (the prior beta, or the last stable if it's the first beta in
  a lane) to this one.

| Commit prefix | Category |
|---|---|
| `feat`, `feature`, or starts with "Add" | New Features |
| `fix` or starts with "Fix" | Bug Fixes |
| `refactor`, `enhance` | Refactor |
| `chore`, `style`, `docs`, `perf`, `test`, `ci`, `build` | Chores |
| Uncategorized | Bug Fixes |

Author attribution (required on every entry):

- With a PR number `(#123)`: `gh pr view 123 --json author -q '.author.login'`.
- Without a PR number: `gh api /repos/tverma101/QuotaBar/commits/{full_hash} -q '.author.login'`.
- If the API returns null, fall back to the git author name.

Output the changelog in a code block (template below) for review.

### 3. Owner approval

Wait for explicit approval of the changelog before changing any files. Accept edits if offered.

### 4. Record it in CHANGELOG.md

Prepend the approved section right after the `# Changelog` header. Commit on `main`:

```sh
git add CHANGELOG.md && git commit -m "docs: changelog for v{version}"
```

### 5. Tag and push

Never tag automatically — ask the owner first.

```sh
git tag -a v{version} -m "v{version}"
git push origin main
git push origin v{version}
```

### 6. Owner builds, signs, and notarizes the DMG

The owner does this with their own Apple Developer credentials; they are never committed here.
`script/build_and_run.sh` stages a bundle signed with an **Apple Development** identity, which runs
locally but will not install on another machine. For a distributable artifact the owner needs a
**Developer ID Application** certificate and notarization, and must set these in their own shell:

```sh
export CODESIGN_IDENTITY="Developer ID Application: <name> (<TEAM>)"
```

Then stage, notarize, staple, and produce the DMG. Confirm the staged bundle reports the expected
identity before packaging:

```sh
codesign -dv --verbose=4 dist/QuotaBar.app 2>&1 | rg 'Authority|Identifier'
```

**Notarization requires a provisioning profile.** Note that the Keychain access-group entitlement is
only emitted when a matching profile is installed — adding an unauthorized `keychain-access-groups`
entry makes the app fail to launch with `RBSRequestErrorDomain Code=5` (POSIX 163). See `AGENTS.md`
and `Sources/QuotaBar/Services/SystemClients.swift` before changing entitlements during a release.

### 7. Publish the release and attach the notes

```sh
gh release create v{version} dist/QuotaBar-<version>.dmg \
  --title "QuotaBar <version>" \
  --notes-file /tmp/notes-v{version}.md \
  --prerelease            # beta only; omit for stable
```

**Never leave a release blank.** Beta and stable are separate releases, not one release with channels:
there is no appcast to route between them.

### 8. Verify (never leave a draft)

```sh
gh release view v{version} --json isDraft,isPrerelease,assets,body \
  --jq '{isDraft, isPrerelease, assets:[.assets[].name], bodyLen:(.body|length)}'
spctl -a -vv -t install dist/QuotaBar-<version>.dmg   # must be accepted / notarized
```

Require `isDraft=false`, `isPrerelease=true` for beta or `false` for stable, a
`QuotaBar-<version>.dmg` asset, `bodyLen>0`, and `spctl` accepting the DMG.

Because there is no auto-update, **say so in the release notes** and tell users to replace the app
bundle in `/Applications` by hand. An install is not self-updating.

## Changelog template

Only include category sections that have entries.

~~~markdown
## v{version}

### New Features
- {message} ([#{pr}](https://github.com/tverma101/QuotaBar/pull/{pr})) by @{author}

### Bug Fixes
- {message} ([#{pr}](https://github.com/tverma101/QuotaBar/pull/{pr})) by @{author}

### Refactor
- {message} by @{author}

### Chores
- {message} by @{author}

---

### Changelog
**Full Changelog**: [{prev_tag}...v{version}](https://github.com/tverma101/QuotaBar/compare/{prev_tag}...v{version})

- [{short_hash}](https://github.com/tverma101/QuotaBar/commit/{full_hash}) {commit message} by @{author}
~~~

`{prev_tag}` is the previous release **in the same channel**: last stable for a stable cut, last beta
(or last stable for the first beta in a lane) for a beta cut.

## Rules

- 7-char short commit hashes; tags always prefixed with `v`.
- Stable changelogs span last-stable → this-stable (roll up the whole beta series); beta changelogs span
  previous-tag → this-beta.
- Never push or tag automatically — ask the owner first.
- Never change the version without explicit owner approval.
- Always publish notes to the GitHub Release — never blank.
- The version is the tag; never edit version files.
- Never commit signing, notarization, or provisioning credentials.
- There is no appcast. If auto-update is ever reintroduced, it needs a `keychain`-safe
  `SUFeedURL` on a QuotaBar-owned domain plus a new decision about channels — that is a design change,
  not a release step.
