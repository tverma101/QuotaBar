// Writes QuotaBar's signed Windows update feed (`latest.json`) for a published GitHub release.
//
// The Tauri updater in installed apps reads this feed from the `update-feed` branch, downloads the
// installer from the GitHub release, and refuses it unless its minisign signature matches the public
// key compiled into the app. This script never signs anything: the signature comes from the `.sig`
// file the tagged Windows CI build produced with the private key held in repository secrets.
//
// Usage:
//   node scripts/update-feed.mjs --tag v0.7.3 --repo owner/name --signature-file QuotaBar_0.7.3_x64-setup.exe.sig \
//     --out latest.json [--current latest.json] [--pub-date 2026-11-26T00:00:00Z]

import { readFileSync, writeFileSync, existsSync } from "node:fs"
import { pathToFileURL } from "node:url"

const TAG_PATTERN = /^v(\d+)\.(\d+)\.(\d+)(?:-beta\.(\d+))?$/
const REPO_PATTERN = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/

/** Compares two semver strings, including prerelease identifiers. */
export function compareVersions(a, b) {
  const parse = (value) => {
    const match = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/.exec(String(value))
    if (!match) throw new Error(`Not a semantic version: ${value}`)
    return { core: match.slice(1, 4).map(Number), pre: match[4] ? match[4].split(".") : [] }
  }
  const left = parse(a)
  const right = parse(b)
  for (let i = 0; i < 3; i++) {
    if (left.core[i] !== right.core[i]) return left.core[i] < right.core[i] ? -1 : 1
  }
  if (!left.pre.length || !right.pre.length) {
    if (left.pre.length === right.pre.length) return 0
    return left.pre.length ? -1 : 1 // a release outranks its prereleases
  }
  for (let i = 0; i < Math.max(left.pre.length, right.pre.length); i++) {
    const l = left.pre[i]
    const r = right.pre[i]
    if (l === undefined) return -1
    if (r === undefined) return 1
    if (l === r) continue
    const ln = /^\d+$/.test(l)
    const rn = /^\d+$/.test(r)
    if (ln && rn) return Number(l) < Number(r) ? -1 : 1
    if (ln !== rn) return ln ? -1 : 1
    return l < r ? -1 : 1
  }
  return 0
}

export function installerName(version) {
  return `QuotaBar_${version}_x64-setup.exe`
}

/** Builds the Tauri v2 updater manifest for one release. */
export function buildFeed({ tag, repo, signature, pubDate }) {
  if (!TAG_PATTERN.test(tag)) throw new Error(`Release tag must look like v1.2.3 or v1.2.3-beta.4: ${tag}`)
  if (!REPO_PATTERN.test(repo)) throw new Error(`Repository must be owner/name: ${repo}`)
  const trimmed = String(signature ?? "").trim()
  if (!/^[A-Za-z0-9+/=]{40,}$/.test(trimmed)) throw new Error("Installer signature is missing or malformed")
  const version = tag.slice(1)
  const releaseUrl = `https://github.com/${repo}/releases/tag/${tag}`
  return {
    version,
    notes: `QuotaBar ${version}. Release notes: ${releaseUrl}`,
    pub_date: pubDate,
    platforms: {
      "windows-x86_64": {
        signature: trimmed,
        url: `https://github.com/${repo}/releases/download/${tag}/${installerName(version)}`,
      },
    },
  }
}

/** The feed only moves forward, so re-running an older release can never downgrade installs. */
export function shouldReplace(currentFeed, nextFeed) {
  if (!currentFeed) return true
  return compareVersions(nextFeed.version, currentFeed.version) > 0
}

function parseArgs(argv) {
  const args = {}
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i]
    if (!key.startsWith("--") || argv[i + 1] === undefined) throw new Error(`Unexpected argument: ${key}`)
    args[key.slice(2)] = argv[i + 1]
  }
  return args
}

function main() {
  const args = parseArgs(process.argv.slice(2))
  for (const required of ["tag", "repo", "signature-file", "out"]) {
    if (!args[required]) throw new Error(`Missing --${required}`)
  }
  const next = buildFeed({
    tag: args.tag,
    repo: args.repo,
    signature: readFileSync(args["signature-file"], "utf8"),
    pubDate: args["pub-date"] ?? new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
  })
  const current = args.current && existsSync(args.current) ? JSON.parse(readFileSync(args.current, "utf8")) : null
  if (!shouldReplace(current, next)) {
    console.log(`Feed already offers ${current.version}; not replacing it with ${next.version}.`)
    process.exitCode = 0
    return
  }
  writeFileSync(args.out, JSON.stringify(next, null, 2) + "\n")
  console.log(`Wrote ${args.out} for ${next.version}`)
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  try {
    main()
  } catch (error) {
    console.error(String(error?.message ?? error))
    process.exit(1)
  }
}
