import { strict as assert } from "node:assert";
import { test as nodeTest } from "node:test";
import {
  createReadRepository,
  createToolRunner,
  readWithDeadline,
} from "./repository.ts";
import type { ReadClient, ReadQuery, ReadResponse } from "./repository.ts";
import { createServerAgent } from "./adapter.ts";
import { resolveCalendar } from "./finance.ts";
const test =
  (globalThis as unknown as { Deno?: { test: typeof nodeTest } }).Deno?.test ??
  nodeTest;
type Row = Record<string, unknown>;
const now = new Date("2026-11-06T10:00:00Z");
const calendar = resolveCalendar(undefined, now);
test("stalled read-only operations have a deadline", async () => {
  await assert.rejects(readWithDeadline(new Promise(() => {}), 5), /timed out/);
});
const profile = { id: "user-a", currency: "SAR", monthly_income: 5000 };
const plan = (id: string): Row => ({
  id,
  user_id: "user-a",
  currency: "SAR",
  monthly_amount: 1,
  total_amount: 3,
  total_count: 3,
  paid_count: 0,
  due_day: 5,
  next_due_date: "2026-11-05",
  active: true,
  created_at: "2026-01-01T00:00:00Z",
});
const expense = (id: string): Row => ({
  id,
  user_id: "user-a",
  currency: "SAR",
  amount: 1,
  merchant: "Cafe",
  category: "food",
  spent_at: "2026-11-05T10:00:00Z",
});
class FakeDb implements ReadClient {
  tables: Record<string, Row[]> = {
    profiles: [{ ...profile }],
    installment_plans: [],
    expenses: [],
  };
  calls: Query[] = [];
  cap = 200;
  fail = false;
  changedCount = false;
  emptyPage = false;
  forceForeign = false;
  from(table: string): ReadQuery {
    return new Query(this, table);
  }
}
class Query implements ReadQuery {
  filters: Array<[string, unknown, string]> = [];
  orders: string[] = [];
  from = 0;
  to = 499;
  single = false;
  counted = false;
  readonly db: FakeDb;
  readonly table: string;
  constructor(db: FakeDb, table: string) {
    this.db = db;
    this.table = table;
  }
  select(_columns: string, options?: { count: "exact" }) {
    this.counted = !!options;
    return this;
  }
  eq(k: string, v: unknown) {
    this.filters.push([k, v, "eq"]);
    return this;
  }
  gte(k: string, v: string) {
    this.filters.push([k, v, "gte"]);
    return this;
  }
  lte(k: string, v: string) {
    this.filters.push([k, v, "lte"]);
    return this;
  }
  order(k: string) {
    this.orders.push(k);
    return this;
  }
  range(from: number, to: number) {
    this.from = from;
    this.to = to;
    return this;
  }
  maybeSingle() {
    this.single = true;
    return this;
  }
  then: ReadQuery["then"] = (yes, no) => this.execute().then(yes, no);
  async execute(): Promise<ReadResponse> {
    this.db.calls.push(this);
    if (this.db.fail)
      return { data: null, error: { message: "sentinel-private-error" } };
    let rows = this.db.tables[this.table]!.filter((r) =>
      this.filters.every(([k, v, op]) =>
        op === "eq"
          ? r[k] === v
          : op === "gte"
            ? Date.parse(String(r[k])) >= Date.parse(String(v))
            : Date.parse(String(r[k])) <= Date.parse(String(v)),
      ),
    );
    const count = rows.length + (this.db.changedCount && this.from > 0 ? 1 : 0);
    rows = rows.slice(
      this.from,
      Math.min(this.to + 1, this.from + this.db.cap),
    );
    if (this.db.emptyPage && this.from > 0) rows = [];
    if (this.db.forceForeign)
      rows = rows.map((r) => ({ ...r, user_id: "user-b", id: "user-b" }));
    return {
      data: this.single ? (rows[0] ?? null) : rows,
      error: null,
      count: this.counted ? count : null,
    };
  }
}
test("complete financial snapshot reads beyond 1000 rows and smaller server caps, then reuses one snapshot", async () => {
  const db = new FakeDb();
  db.tables.installment_plans = Array.from({ length: 1005 }, (_, i) =>
    plan(`p${i}`),
  );
  db.tables.installment_plans.push(
    { ...plan("inactive"), active: false },
    { ...plan("foreign"), currency: "KWD" },
  );
  db.tables.expenses = Array.from({ length: 2345 }, (_, i) => expense(`e${i}`));
  db.tables.expenses.push(
    { ...expense("foreign"), currency: "KWD", amount: 900 },
    { ...expense("future"), spent_at: "2026-11-07T00:00:00Z", amount: 900 },
    { ...expense("old"), spent_at: "2026-10-31T00:00:00Z", amount: 900 },
    { ...expense("other"), user_id: "user-b" },
  );
  const run = createToolRunner(
    createReadRepository(db, "user-a"),
    calendar,
    async () => {
      throw new Error("No place call expected");
    },
  );
  const summary = (await run("get_budget_summary", {})) as Row;
  assert.equal(summary.spent_this_month, "2345.00");
  assert.equal(summary.installments_due_this_month, "1005.00");
  assert.equal(summary.safe_to_spend_this_month, "1650.00");
  assert.equal(db.calls.filter((q) => q.table === "expenses").length, 12);
  assert.equal(
    db.calls.filter((q) => q.table === "installment_plans").length,
    6,
  );
  const reads = db.calls.length;
  db.tables.expenses = [];
  const sim = (await run("simulate_purchase", { amount: 100 })) as Row;
  assert.equal(sim.safe_to_spend_before, "1650.00");
  assert.equal(sim.safe_to_spend_after, "1550.00");
  assert.equal(db.calls.length, reads);
  for (const q of db.calls) {
    assert.ok(
      q.filters.some(
        ([k, v]) =>
          k === (q.table === "profiles" ? "id" : "user_id") && v === "user-a",
      ),
    );
  }
  assert.deepEqual(db.calls.find((q) => q.table === "expenses")!.orders, [
    "spent_at",
    "id",
  ]);
});
test("failed, incomplete, changed-count or foreign responses never return a partial total or raw error", async () => {
  for (const mode of [
    "fail",
    "emptyPage",
    "changedCount",
    "forceForeign",
  ] as const) {
    const db = new FakeDb();
    db.tables.expenses = Array.from({ length: 201 }, (_, i) =>
      expense(`e${i}`),
    );
    db[mode] = true;
    const result = (await createToolRunner(
      createReadRepository(db, "user-a"),
      calendar,
      async () => null,
    )("get_budget_summary", {})) as Row;
    assert.equal(result.error, "financial_data_unavailable");
    assert.equal(result.safe_to_spend_this_month, undefined);
    assert.ok(!JSON.stringify(result).includes("sentinel"));
  }
});
test("limited expenses page through lower caps with boundaries, category, limit and own currencies", async () => {
  const db = new FakeDb();
  db.cap = 2;
  db.tables.expenses = Array.from({ length: 6 }, (_, i) => ({
    ...expense(`e${i}`),
    currency: i === 0 ? "KWD" : "SAR",
    amount: i === 0 ? 1.255 : 1.25,
  }));
  db.tables.expenses.push({ ...expense("othercategory"), category: "other" });
  const run = createToolRunner(
    createReadRepository(db, "user-a"),
    calendar,
    async () => null,
  );
  const r = (await run("get_expenses", {
    start: "2026-11-01T00:00:00Z",
    end: "2026-11-06T00:00:00Z",
    category: "food",
    limit: 3,
  })) as { expenses: Row[]; limited: boolean };
  assert.equal(r.expenses.length, 3);
  assert.equal(r.expenses[0]!.currency, "KWD");
  assert.equal(r.expenses[0]!.amount, "1.255");
  assert.equal(r.expenses[1]!.amount, "1.25");
  assert.equal(r.limited, true);
  assert.equal(db.calls.filter((q) => q.table === "expenses").length, 2);
  assert.ok(
    db.calls
      .filter((q) => q.table === "expenses")
      .every((q) =>
        q.filters.some(([k, v]) => k === "category" && v === "food"),
      ),
  );
  const before = db.calls.length;
  const bad = await run("get_expenses", { days: "30" });
  assert.equal((bad as Row).error, "invalid_tool_input");
  assert.equal(db.calls.length, before);
});
test("provisional simulations, currency mismatches and installment details use the integrated runner", async () => {
  const db = new FakeDb();
  db.tables.installment_plans = [{ ...plan("legacy"), next_due_date: null }];
  const run = createToolRunner(
    createReadRepository(db, "user-a"),
    calendar,
    async () => null,
  );
  const sim = (await run("simulate_purchase", { amount: 6000 })) as Row;
  assert.equal(sim.provisional, true);
  assert.equal(sim.affordable_this_month, null);
  assert.equal(sim.breaches_budget, true);
  const mismatch = (await run("simulate_purchase", {
    amount: 1,
    currency: "KWD",
  })) as Row;
  assert.equal(mismatch.error, "currency_mismatch");
  assert.equal(mismatch.safe_to_spend_after, undefined);
  const result = (await run("get_installments", {})) as { plans: Row[] };
  assert.equal(result.plans[0]!.schedule_needed, true);
  assert.equal(result.plans[0]!.remaining_balance, "3.00");
});
function request(body: unknown) {
  return new Request("https://local/agent", {
    method: "POST",
    headers: { authorization: "Bearer caller-jwt" },
    body: JSON.stringify(body),
  });
}
const use = (id: string, name: string, input: Row = {}) => ({
  type: "tool_use",
  id,
  name,
  input,
});
test("server adapter verifies token, uses anon key with caller header and exposes exact tool evidence end-to-end", async () => {
  const db = new FakeDb();
  db.tables.expenses = [expense("e")];
  db.tables.installment_plans = [plan("p")];
  let modelCalls = 0;
  let authenticatedToken = "";
  const fetchImpl: typeof fetch = async (_url, opts) => {
    const body = JSON.parse(opts!.body as string) as {
      messages: Array<{ content: unknown }>;
    };
    modelCalls++;
    if (modelCalls === 1)
      return Response.json({
        id: "msg1",
        stop_reason: "tool_use",
        content: [
          use("budget", "get_budget_summary"),
          use("sim", "simulate_purchase", { amount: 10, months: 3 }),
          use("plans", "get_installments"),
        ],
      });
    const results = body.messages.at(-1)!.content as Array<{
      tool_use_id: string;
      content: string;
    }>;
    assert.equal(
      JSON.parse(results[0]!.content).safe_to_spend_this_month,
      "4998.00",
    );
    assert.equal(JSON.parse(results[1]!.content).monthly_impact, "3.34");
    assert.equal(
      JSON.parse(results[2]!.content).plans[0].remaining_balance,
      "3.00",
    );
    return Response.json({
      id: "msg2",
      stop_reason: "end_turn",
      content: [{ type: "text", text: "Tool-backed 4998.00 SAR." }],
    });
  };
  const handler = createServerAgent({
    url: "https://db.example",
    anonKey: "public-anon",
    apiKey: "sentinel-provider-key",
    now: () => now,
    fetchImpl,
    clientFactory: (url, key, opts) => {
      assert.equal(url, "https://db.example");
      assert.equal(key, "public-anon");
      assert.equal(opts.global.headers.Authorization, "Bearer caller-jwt");
      assert.equal(opts.auth.persistSession, false);
      return {
        from: (table) => db.from(table),
        auth: {
          getUser: async (token) => {
            authenticatedToken = token;
            return {
              data: { user: { id: "user-a", role: "authenticated" } },
              error: null,
            };
          },
        },
      };
    },
  });
  const response = await handler(
    request({
      messages: [{ role: "user", content: "Plan my month" }],
      calendar: {
        asOf: calendar.asOf,
        monthStart: calendar.monthStart,
        year: 2026,
        month: 11,
      },
    }),
  );
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    reply: "Tool-backed 4998.00 SAR.",
  });
  assert.equal(authenticatedToken, "caller-jwt");
  assert.equal(modelCalls, 2);
});
test("rejected identity and stale calendar cannot reach reads or the model", async () => {
  for (const role of ["anon", "service_role", "authenticated"]) {
    let reads = 0;
    let models = 0;
    const handler = createServerAgent({
      url: "https://db.example",
      anonKey: "anon",
      apiKey: "private",
      now: () => now,
      fetchImpl: async () => {
        models++;
        throw new Error("No provider call");
      },
      clientFactory: () => ({
        from: () => {
          reads++;
          throw new Error("No read");
        },
        auth: {
          getUser: async () => ({
            data: { user: { id: "user-a", role } },
            error: null,
          }),
        },
      }),
    });
    const response = await handler(
      request({
        messages: [{ role: "user", content: "Budget?" }],
        calendar: {
          asOf: "2026-11-06T09:00:00Z",
          monthStart: calendar.monthStart,
          year: 2026,
          month: 11,
        },
      }),
    );
    assert.equal(response.status, role === "authenticated" ? 400 : 401);
    assert.equal(reads, 0);
    assert.equal(models, 0);
  }
});
