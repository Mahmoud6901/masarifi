import {
  computeBudget,
  describeExpenses,
  describeInstallments,
  FinanceError,
  resolveCalendar,
  simulatePurchase,
} from "./finance.ts";
import type { CalendarContext, BudgetSummary } from "./finance.ts";
import { validateToolInput } from "./handler.ts";
import type { ToolRunner } from "./handler.ts";

type Row = Record<string, unknown>;
export interface ReadResponse {
  data: unknown;
  error: unknown;
  count?: number | null;
}
// Deliberately contains only reads. Caller identity and query scoping stay outside the model.
export interface ReadQuery extends PromiseLike<ReadResponse> {
  select(columns: string, options?: { count: "exact" }): ReadQuery;
  eq(column: string, value: unknown): ReadQuery;
  gte(column: string, value: string): ReadQuery;
  lte(column: string, value: string): ReadQuery;
  order(column: string, options: { ascending: boolean }): ReadQuery;
  range(from: number, to: number): ReadQuery;
  maybeSingle(): ReadQuery;
}
export interface ReadClient {
  from(table: string): ReadQuery;
}
export interface ReadRepository {
  profile(): Promise<Row>;
  plans(): Promise<Row[]>;
  budgetExpenses(currency: string, calendar: CalendarContext): Promise<Row[]>;
  expenses(input: Row, calendar: CalendarContext): Promise<Row[]>;
}
class ReadFailure extends Error {}
function failed(): never {
  throw new ReadFailure("Could not load complete financial data. Try again.");
}
const record = (v: unknown): v is Row =>
  typeof v === "object" && v !== null && !Array.isArray(v);

export async function readWithDeadline<T>(
  read: PromiseLike<T>,
  timeoutMs = 10000,
): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      Promise.resolve(read),
      new Promise<never>((_, reject) => {
        timer = setTimeout(
          () => reject(new ReadFailure("The data read timed out.")),
          timeoutMs,
        );
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

export function createReadRepository(
  db: ReadClient,
  owner: string,
  timeoutMs = 10000,
): ReadRepository {
  async function pages(
    build: () => ReadQuery,
    maximum?: number,
  ): Promise<Row[]> {
    const rows: Row[] = [],
      seen = new Set<string>();
    let expected: number | undefined;
    while (true) {
      const response = await readWithDeadline(
        build().range(
          rows.length,
          rows.length + Math.min(499, (maximum ?? Infinity) - rows.length - 1),
        ),
        timeoutMs,
      );
      if (
        response.error ||
        !Array.isArray(response.data) ||
        !Number.isSafeInteger(response.count) ||
        response.count! < 0
      )
        failed();
      if (expected !== undefined && expected !== response.count) failed();
      expected = response.count!;
      for (const row of response.data as unknown[]) {
        if (
          !record(row) ||
          row.user_id !== owner ||
          typeof row.id !== "string" ||
          seen.has(row.id)
        )
          failed();
        seen.add(row.id);
        rows.push(row);
      }
      if (
        rows.length > expected ||
        (maximum !== undefined && rows.length > maximum)
      )
        failed();
      if (rows.length === expected || rows.length === maximum) return rows;
      if (response.data.length === 0) failed();
    }
  }
  function expensesQuery() {
    return db
      .from("expenses")
      .select("id,user_id,amount,refunded_amount,currency,merchant,category,spent_at", {
        count: "exact",
      })
      .eq("user_id", owner)
      .order("spent_at", { ascending: false })
      .order("id", { ascending: false });
  }
  return {
    async profile() {
      const { data, error } = await readWithDeadline(
        db
          .from("profiles")
          .select("id,currency,monthly_income")
          .eq("id", owner)
          .maybeSingle(),
        timeoutMs,
      );
      if (error || !record(data) || data.id !== owner) failed();
      return data;
    },
    plans: () =>
      pages(() =>
        db
          .from("installment_plans")
          .select(
            "id,user_id,name,provider,kind,currency,monthly_amount,total_amount,total_count,paid_count,due_day,next_due_date,active,created_at",
            { count: "exact" },
          )
          .eq("user_id", owner)
          .order("created_at", { ascending: false })
          .order("id", { ascending: false }),
      ),
    budgetExpenses: (currency, calendar) =>
      pages(() =>
        expensesQuery()
          .eq("currency", currency)
          .gte("spent_at", calendar.monthStart)
          .lte("spent_at", calendar.asOf),
      ),
    expenses: (input, calendar) => {
      const end = typeof input.end === "string" ? input.end : calendar.asOf;
      const start =
        typeof input.start === "string"
          ? input.start
          : new Date(
              Date.parse(end) - Number(input.days ?? 30) * 86400000,
            ).toISOString();
      if (Date.parse(start) > Date.parse(end))
        throw new FinanceError(
          "invalid_input",
          "The expense start must not be after the end.",
        );
      return pages(
        () => {
          let q = expensesQuery().gte("spent_at", start).lte("spent_at", end);
          if (typeof input.category === "string")
            q = q.eq("category", input.category);
          return q;
        },
        Number(input.limit ?? 50),
      );
    },
  };
}

export function createToolRunner(
  repository: ReadRepository,
  calendar: CalendarContext,
  places: (input: Row) => Promise<unknown>,
): ToolRunner {
  let profilePromise: Promise<Row> | undefined;
  let plansPromise: Promise<Row[]> | undefined;
  let snapshotPromise: Promise<BudgetSummary> | undefined;
  const profile = () =>
    (profilePromise ??= repository.profile().then((p) => {
      computeBudget(p, [], [], calendar);
      return p;
    }));
  const plans = () => (plansPromise ??= repository.plans());
  const snapshot = () =>
    (snapshotPromise ??= (async () => {
      const p = await profile();
      const [planRows, expenseRows] = await Promise.all([
        plans(),
        repository.budgetExpenses(p.currency as string, calendar),
      ]);
      return computeBudget(p, planRows, expenseRows, calendar);
    })());
  return async (name, raw) => {
    const validation = validateToolInput(name, raw);
    if (!validation.ok)
      return { error: "invalid_tool_input", message: validation.message };
    const input = validation.input;
    try {
      switch (name) {
        case "get_budget_summary":
          return await snapshot();
        case "simulate_purchase":
          return simulatePurchase(input, await snapshot());
        case "get_installments":
          return {
            currency: (await profile()).currency,
            as_of: calendar.asOf,
            plans: describeInstallments(await plans(), calendar),
            complete: true,
          };
        case "get_expenses":
          return {
            currency: (await profile()).currency,
            as_of: calendar.asOf,
            expenses: describeExpenses(
              await repository.expenses(input, calendar),
            ),
            limit: input.limit,
            limited: true,
          };
        case "search_places":
          return await places(input);
        default:
          return {
            error: "unknown_tool",
            message: "That tool is not available.",
          };
      }
    } catch (error) {
      if (error instanceof FinanceError)
        return { error: error.code, message: error.message };
      return {
        error: "financial_data_unavailable",
        message: "Could not load complete financial data. Try again.",
      };
    }
  };
}
export { resolveCalendar };
