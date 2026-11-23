import { DatabaseSync } from "node:sqlite"
import { expect, it } from "vitest"
import { makeCtx } from "../test-helpers.js"
import "./plugin.js"

const probe = globalThis.__openusage_plugin.probe

function fixture() {
  const ctx = makeCtx()
  const db = new DatabaseSync(":memory:")
  const path = "C:\\Hermes Data/state.db"
  ctx.nowIso = new Date(2026, 1, 4, 12).toISOString()
  ctx.host.env.get.mockImplementation(name => name === "HERMES_HOME" ? "C:\\Hermes Data" : null)
  ctx.host.fs.writeText(path, "")
  ctx.host.sqlite.query.mockImplementation((file, sql) => {
    expect(file).toBe(path)
    return JSON.stringify(db.prepare(sql).all())
  })
  db.exec(`CREATE TABLE sessions (
    id TEXT PRIMARY KEY, started_at, ended_at, billing_provider, billing_base_url, model,
    input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens,
    estimated_cost_usd, api_call_count
  )`)
  return { ctx, db }
}

it("reads calendar periods, excludes gateway billing, and preserves missing estimates and active writes", () => {
  const { ctx, db } = fixture()
  const insert = db.prepare("INSERT INTO sessions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)")
  const on = day => new Date(2026, 1, day, 9).getTime() / 1000
  insert.run("today", on(4), on(4) + 1, null, null, "A", 11, 2, 3, 4, 5, 1)
  insert.run("ongoing", on(3), null, null, null, "B", 6, 0, 0, 0, 0, 0)
  insert.run("month", on(1), on(1) + 1, null, null, "C", 10, 0, 0, 0, 0, 2)
  insert.run("go", on(4), null, "OPENCODE-GO", null, "D", 100, 0, 0, 0, 0, 1)
  insert.run("zen", on(4), null, null, "https://opencode.ai/zen", "D", 100, 0, 0, 0, 0, 1)
  const { lines } = probe(ctx)
  expect(lines.map(line => line.label)).toEqual(["Today", "This Week", "This Month", "Usage Trend"])
  expect(lines.slice(0, 3).map(line => line.value)).toEqual(["~$1.00 · 25 tokens", "~31 tokens", "~41 tokens"])
  expect(lines[1].modelBreakdown).toEqual([
    expect.objectContaining({ model: "A", tokens: 25, costUsd: 1 }),
    expect.objectContaining({ model: "B", tokens: 6, costUsd: undefined }),
  ])
  expect(ctx.host.usageDaily.ingest).toHaveBeenCalledWith({
    displayName: "Hermes",
    daily: [
      { date: "2026-02-01", totalTokens: 10, totalCost: 2 },
      { date: "2026-02-03", totalTokens: 6, totalCost: null },
      { date: "2026-02-04", totalTokens: 25, totalCost: 1 },
    ],
  })
  db.close()
})

it("uses the optional model table without counting its rows again in totals", () => {
  const { ctx, db } = fixture()
  const on = new Date(2026, 1, 4, 9).getTime() / 1000
  db.exec(`INSERT INTO sessions VALUES ('s', ${on}, ${on}+1, NULL, NULL, 'Main', 40, 0, 0, 0, 0, 4, 1);
    CREATE TABLE session_model_usage (session_id, model, input_tokens, output_tokens, cache_read_tokens,
      cache_write_tokens, reasoning_tokens, estimated_cost_usd);
    INSERT INTO session_model_usage VALUES ('s','Tool',30,0,0,0,0,3), ('s','Main',10,0,0,0,0,1);`)
  const { lines } = probe(ctx)
  expect(lines[0].value).toBe("~$4.00 · 40 tokens")
  expect(lines[0].modelBreakdown.map(row => [row.model, row.tokens])).toEqual([["Tool", 30], ["Main", 10]])
  db.close()
})

it("does not publish partial totals for corrupt accounting", () => {
  const { ctx, db } = fixture()
  const on = new Date(2026, 1, 4, 9).getTime() / 1000
  db.exec(`INSERT INTO sessions VALUES ('s', ${on}, NULL, NULL, NULL, 'Main', 'bad', 1, 0, 0, 0, 1, 1)`)
  expect(() => probe(ctx)).toThrow("Hermes usage history could not be read.")
  expect(ctx.host.usageDaily.ingest).not.toHaveBeenCalled()
  db.close()
})
