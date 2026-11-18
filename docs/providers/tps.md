# TPS Tracker

Experimental. Estimates how fast the model was generating tokens per second from the session logs
your coding agents already write on this Mac — no network, no credentials, nothing leaves the machine.
The estimates live in the **Total Spend panel** as its **TPS** lens — never as a dashboard card.

## Where you see it

The Total Spend ring at the top of the dashboard has a title pull-down: **Cost**, **Cost/MTok**,
**Tokens**, **TPS**. Pick **TPS** and the whole panel becomes TPS:

- **Window switcher** — **Today / 7 Days / 14 Days**, the same capsule control the spend lenses use
  for their periods. All three are views of one 14-day fold bucketed by day, so switching is
  instant and never re-reads a log file. Your choice survives relaunches.
- **Ring** — each provider's share of generation pace (rate-based arcs, same morph math as Cost/MTok).
- **Center** — your combined estimate for the selected window, token-weighted across every corpus
  (Claude, Codex, Grok, Muse, Pi, Z.ai, Antigravity).
- **Legend** — per provider: its average tokens/sec in the window, ranked fastest first.
- **Per-provider Model TPS** — below the overview, one block per provider (its color, name, and its
  own tokens/sec), each listing that provider's models ranked by output tokens with their
  paired-report rates. Up to 6 models per provider, with a "… N more models" footer when there's
  more. Each provider's pace and model mix read separately instead of one merged list.

The caption under the ring says what the number is: estimated from local logs, tool-call intervals
excluded, not a benchmark. A window with too few qualifying intervals shows its empty state — a
quiet day is "no data yet", never a fabricated zero.

The **Timing** stays put in TPS mode (it is a rolling window, not a day); the Today / Yesterday /
30 Days switcher only shows for Cost, Cost/MTok and Tokens — TPS has its own window switcher above.

## Enabling and disabling

TPS Tracker is enabled by default on new installs. Existing installs leave it off until you flip it
on — there is no row for it in the dashboard anymore, by design. Turn it on or off in
**Customize → TPS Tracker**: the toggle governs whether the fold runs at all. Turning it off stops
the fold; the TPS lens then shows its empty state with instructions. The toggle is a provider-level
switch; there are no per-metric placement options for TPS rows.

If the fold fails you get a loud error state in the panel with a Retry — never a silent zero.

## How the number is computed

Output tokens per consecutive usage report, folded over the last 14 days:

Seven corpora are folded; JSONL ones reuse the same incremental parse caches their spend tiles use:

- Claude Code writes one usage block per assistant message in `~/.claude/projects/**/*.jsonl`
  (or the `projects/` dir under each `CLAUDE_CONFIG_DIR` root, plus Claude desktop sandboxes).
- Codex writes `token_count` events in `$CODEX_HOME/sessions/**/rollout-*.jsonl` (or `~/.codex`).
- Grok writes completed-turn updates in `$GROK_HOME/sessions/**/updates.jsonl` (or `~/.grok`),
  coordinator sessions only.
- Muse writes attribution lines in `~/.local/share/muse/sessions/**/session.jsonl`.
- Pi writes assistant messages in `PI_CODING_AGENT_SESSION_DIR` (or `~/.pi/agent/sessions/**/*.jsonl`).
- ZCode's `model_usage` table (`~/.zcode/cli/db/db.sqlite`) carries one row per API call with
  `started_at`, `first_token_at`/`completed_at`, `output_tokens` and `model_id`. When the server
  reported first-token timing, the fold uses the stream interval verbatim (up to five minutes of
  generation per row); rows without a stream window fold through the same pair rule as the rest.
- Antigravity (agy CLI, desktop app, IDE, and T3 Code's private ACP instances) keeps one SQLite
  conversation database per conversation under `~/.gemini/antigravity*/conversations`,
  `~/.config/antigravity/conversations`, and
  `~/.t3/userdata/providers/antigravity/*/antigravity-acp/conversations` (UUID-shaped `.db` files).
  The fold reads each one
  read-only (immutable when no `-wal` exists), pulls `PLANNER_RESPONSE` steps and measures
  `output_tokens` over the row's own `created_at → finished_generating_at` stream window when the
  row has one (up to five minutes), falling back to the pair rule otherwise. Response ids dedupe
  across stores (forked copies). Open, error and cancelled planner rows contribute tokens but no
  timing — the Antigravity reader is derived from the Agent Speed project (MIT).

For every pair of consecutive reports inside one source, QuotaBar takes the output-token delta
divided by the elapsed seconds. Intervals shorter than 0.2 s (timer granularity) and longer than
60 s (tool-call round trips or idle time) are excluded — those are not model generation. The result
is a token-weighted mean, so heavy generations pull the estimate toward their own rate. A corpus
needs at least five qualifying intervals in the window or it shows as no data; a model needs at
least three paired reports before its rate prints (below that, the row shows tokens only).

This is an **estimate of generation speed, not a benchmark**. Providers route across different
models and infrastructures without notice, and a session heavy on tool calls reads lower than a
pure generation burst. Compare like with like, or don't compare at all.

## Under the hood

Every fold reuses the incremental parse caches QuotaBar's spend tiles use (Claude's whole-file
cache keyed on `CLAUDE_CONFIG_DIR`, Codex's rollout cache, Grok/Muse/Pi's session folds), so opening
the panel never re-parses unchanged files. The scan runs on the panel's accounting phase (on open and on the five-minute
history cadence while the panel is open, fifteen minutes while closed) or on a full refresh, and
runs in the same one-shot scan-worker child as the other local folds — never on the menu-bar meter
tick, never on a quota cadence, never in parallel with another heavy local fold. The TPS data source
exports machineLocal history scope, so nothing about it participates in iCloud sync.

Providers that can't carry per-report timing are intentionally absent: Hermes (period aggregates,
no interval stream), Cursor (day-level CSV only), and the API-quota providers (Devin, Copilot,
OpenRouter). Antigravity's protobuf conversation stores DO carry per-response timing and fold into
the lens (see above). OpenCode's router ledger is the same Codex stream
shown on the Codex slice, and it isn't double-counted.

Failure handling: if a source changed mid-scan or could not be read completely, the panel keeps its
last good values and shows the error state with a Retry — it never publishes a partial rate. A missing
corpus (e.g. no Grok install) is just an absent slice, never an error.

## Troubleshooting

- **TPS lens says "No TPS data yet"** — either the TPS Tracker provider is off (enable it in
  **Customize**) or there were no qualifying intervals in the last 14 days. Run an agent for a few
  turns, then refresh.
- **One provider's slice shows, another's doesn't** — some corpora have logs and others don't, or
  one was unreadable this pass (the panel shows the error state with Retry).
- **Model TPS section is missing** — no model accumulated paired reports in the window; it appears
  on its own once generation data exists.
- **Antigravity slice is missing** — stored conversations are read from
  `~/.gemini/antigravity{,-cli,-ide}/conversations/*.db`, `~/.config/antigravity/conversations`, and
  T3 Code's private instances under `~/.t3/userdata/providers/antigravity/*/antigravity-acp/conversations`;
  fresh conversations appear on the next accounting pass. A database that cannot be opened or has
  no readable planner rows contributes nothing.
- **Today or 7 Days shows less than 14 Days** — the windows are views of the same fold; a quiet day
  simply has fewer qualifying intervals. Below five intervals a corpus shows no rate for that
  window, by design.
- **Rate looks absurdly high or low** — it is an estimate over a 0.2–60 s interval band; compare
  the same model across similar sessions, or not at all. The chart caption reiterates the caveat.
