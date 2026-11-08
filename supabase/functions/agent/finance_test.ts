import { readFileSync } from "node:fs";
import { strict as assert } from "node:assert";
import {
  FinanceError,
  computeBudget,
  describeInstallments,
  resolveCalendar,
  simulatePurchase,
} from "./finance.ts";
import type { BudgetSummary, CalendarContext } from "./finance.ts";

type TestBody = () => void | Promise<void>;
declare const Deno: { test(name: string, body: TestBody): void };

// Deno supplies Deno.test natively. Under Node 22 the same declarations run through node:test.
const host = globalThis as unknown as {
  Deno?: { test(name: string, body: TestBody): void };
};
if (host.Deno === undefined) {
  const { test } = await import("node:test");
  host.Deno = {
    test: (name, body) => {
      test(name, body);
    },
  };
}

interface FixtureCase {
  name: string;
  profile: Record<string, unknown>;
  plans: Record<string, unknown>[];
  expenses: Record<string, unknown>[];
  calendar: { asOf: string; monthStart: string; year: number; month: number };
  expected: {
    currency: string;
    monthly_income: string;
    installments_due_this_month: string;
    spent_this_month: string;
    safe_to_spend_this_month: string;
    provisional: boolean;
  };
}

const fixtures = JSON.parse(
  readFileSync(
    new URL("../../../test/fixtures/agent_finance.json", import.meta.url),
    "utf8",
  ),
) as FixtureCase[];

const ASOF = "2026-11-06T10:00:00.000Z";
const NOW = new Date(ASOF);
const NOV_2026 = {
  asOf: ASOF,
  monthStart: "2026-11-01T00:00:00.000Z",
  year: 2026,
  month: 11,
};
const CONTEXT: CalendarContext = resolveCalendar(NOV_2026, NOW);

const SAR_SUMMARY: BudgetSummary = {
  currency: "SAR",
  monthly_income: "15000.00",
  installments_due_this_month: "1200.50",
  spent_this_month: "250.25",
  safe_to_spend_this_month: "13549.25",
  provisional: false,
  as_of: ASOF,
  month_start: "2026-11-01T00:00:00.000Z",
  local_year: 2026,
  local_month: 11,
};

const KWD_SUMMARY: BudgetSummary = {
  currency: "KWD",
  monthly_income: "1234.567",
  installments_due_this_month: "100.125",
  spent_this_month: "12.346",
  safe_to_spend_this_month: "1122.096",
  provisional: false,
  as_of: ASOF,
  month_start: "2026-11-01T00:00:00.000Z",
  local_year: 2026,
  local_month: 11,
};

function expectCode(code: string, action: () => unknown): void {
  assert.throws(
    action,
    (error: unknown) => error instanceof FinanceError && error.code === code,
  );
}

function captureError(action: () => unknown): FinanceError {
  try {
    action();
  } catch (error) {
    if (error instanceof FinanceError) return error;
    throw error;
  }
  throw new Error("Expected a FinanceError");
}

function minor(text: string, decimals: number): bigint {
  const negative = text.startsWith("-");
  const [whole, fraction = ""] = (negative ? text.slice(1) : text).split(".");
  const units =
    BigInt(whole) * 10n ** BigInt(decimals) +
    BigInt(fraction.padEnd(decimals, "0"));
  return negative ? -units : units;
}

function sarIncome(monthly_income: unknown): string {
  return computeBudget({ currency: "SAR", monthly_income }, [], [], CONTEXT)
    .monthly_income;
}

Deno.test(
  "utc fallback captures one server instant with UTC boundaries",
  () => {
    assert.deepEqual(
      resolveCalendar(undefined, new Date("2026-11-06T10:00:00.000Z")),
      {
        asOf: "2026-11-06T10:00:00.000Z",
        monthStart: "2026-11-01T00:00:00.000Z",
        year: 2026,
        month: 11,
        source: "utc",
      },
    );
    expectCode("invalid_calendar", () =>
      resolveCalendar(undefined, new Date(Number.NaN)),
    );
  },
);

Deno.test("utc fallback rolls the year at the UTC month boundary", () => {
  const context = resolveCalendar(
    undefined,
    new Date("2026-12-31T23:30:00.000Z"),
  );
  assert.deepEqual(
    [context.year, context.month, context.monthStart],
    [2026, 12, "2026-12-01T00:00:00.000Z"],
  );
});

Deno.test(
  "client calendar accepts a Riyadh month start and rejects asOf before it",
  () => {
    const riyadh = {
      asOf: "2026-10-31T23:00:00.000Z",
      monthStart: "2026-10-31T21:00:00.000Z",
      year: 2026,
      month: 11,
    };
    assert.deepEqual(resolveCalendar(riyadh, new Date(riyadh.asOf)), {
      ...riyadh,
      source: "client",
    });
    const early = { ...riyadh, asOf: "2026-10-31T20:59:00.000Z" };
    expectCode("invalid_calendar", () =>
      resolveCalendar(early, new Date(early.asOf)),
    );
  },
);

Deno.test(
  "extreme supported offsets are accepted and offsets beyond fourteen hours are rejected",
  () => {
    const kiritimati = {
      asOf: "2026-10-31T11:00:00.000Z",
      monthStart: "2026-10-31T10:00:00.000Z",
      year: 2026,
      month: 11,
    };
    assert.equal(
      resolveCalendar(kiritimati, new Date(kiritimati.asOf)).monthStart,
      "2026-10-31T10:00:00.000Z",
    );
    const baker = {
      asOf: "2027-01-01T11:59:00.000Z",
      monthStart: "2026-12-01T12:00:00.000Z",
      year: 2026,
      month: 12,
    };
    assert.equal(resolveCalendar(baker, new Date(baker.asOf)).month, 12);
    expectCode("invalid_calendar", () =>
      resolveCalendar(
        { ...NOV_2026, monthStart: "2026-10-31T09:59:00.000Z" },
        NOW,
      ),
    );
    expectCode("invalid_calendar", () =>
      resolveCalendar(
        { ...NOV_2026, monthStart: "2026-10-30T09:59:00.000Z" },
        NOW,
      ),
    );
  },
);

Deno.test(
  "DST month starts keep their own offsets without forcing one offset",
  () => {
    const eastern = {
      asOf: "2026-11-01T17:00:00.000Z",
      monthStart: "2026-11-01T04:00:00.000Z",
      year: 2026,
      month: 11,
    };
    assert.equal(
      resolveCalendar(eastern, new Date(eastern.asOf)).monthStart,
      "2026-11-01T04:00:00.000Z",
    );
    const march = {
      asOf: "2026-03-31T12:00:00.000Z",
      monthStart: "2026-03-01T05:00:00.000Z",
      year: 2026,
      month: 3,
    };
    assert.equal(resolveCalendar(march, new Date(march.asOf)).month, 3);
  },
);

Deno.test(
  "stated years 1, 99 and 9999 keep their year without the 1900 Date.UTC shift",
  () => {
    const cases = [
      {
        asOf: "0001-01-02T00:00:00.000Z",
        monthStart: "0001-01-01T00:00:00.000Z",
        year: 1,
        month: 1,
      },
      {
        asOf: "0099-03-02T00:00:00.000Z",
        monthStart: "0099-03-01T00:00:00.000Z",
        year: 99,
        month: 3,
      },
      {
        asOf: "9999-12-02T00:00:00.000Z",
        monthStart: "9999-12-01T00:00:00.000Z",
        year: 9999,
        month: 12,
      },
    ];
    for (const calendar of cases) {
      const context = resolveCalendar(calendar, new Date(calendar.asOf));
      assert.deepEqual(
        [context.monthStart, context.year, context.month],
        [calendar.monthStart, calendar.year, calendar.month],
      );
    }
  },
);

Deno.test(
  "calendar freshness is inclusive at five minutes in either direction",
  () => {
    const asOf = Date.parse(ASOF);
    assert.equal(
      resolveCalendar(NOV_2026, new Date(asOf + 300_000)).asOf,
      ASOF,
    );
    assert.equal(
      resolveCalendar(NOV_2026, new Date(asOf - 300_000)).asOf,
      ASOF,
    );
    expectCode("stale_calendar", () =>
      resolveCalendar(NOV_2026, new Date(asOf + 300_001)),
    );
    expectCode("stale_calendar", () =>
      resolveCalendar(NOV_2026, new Date(asOf - 300_001)),
    );
  },
);

Deno.test(
  "malformed or cross-month calendar contexts are rejected with a retryable code",
  () => {
    const malformed: unknown[] = [
      null,
      [],
      "calendar",
      42,
      { ...NOV_2026, source: "client" },
      { asOf: ASOF, monthStart: NOV_2026.monthStart, year: 2026 },
      { ...NOV_2026, asOf: "2026-11-06T10:00:00.000+03:00" },
      { ...NOV_2026, asOf: 1762423200000 },
      { ...NOV_2026, year: "2026" },
      { ...NOV_2026, year: 2026.5 },
      { ...NOV_2026, year: 0 },
      { ...NOV_2026, month: 0 },
      { ...NOV_2026, month: 13 },
      { ...NOV_2026, monthStart: "2026-11-01T00:00:30.000Z" },
      { ...NOV_2026, monthStart: "2026-10-31T18:15:30.000Z" },
      { ...NOV_2026, monthStart: "2026-10-31T09:59:00.000Z" },
      { ...NOV_2026, monthStart: "2026-10-30T09:59:00.000Z" },
      { ...NOV_2026, asOf: "2026-10-31T23:59:59.000Z" },
      { ...NOV_2026, asOf: "2026-12-02T00:00:00.000Z" },
      {
        monthStart: "2026-10-31T21:00:00.000Z",
        asOf: "2026-12-03T00:00:00.000Z",
        year: 2026,
        month: 11,
      },
    ];
    for (const input of malformed) {
      expectCode("invalid_calendar", () => resolveCalendar(input, NOW));
    }
  },
);

Deno.test("fixture parity: shared budget cases match exactly", () => {
  assert.ok(fixtures.length >= 12);
  for (const fixture of fixtures) {
    const calendar = resolveCalendar(
      fixture.calendar,
      new Date(fixture.calendar.asOf),
    );
    const summary = computeBudget(
      fixture.profile,
      fixture.plans,
      fixture.expenses,
      calendar,
    );
    assert.deepEqual(
      {
        currency: summary.currency,
        monthly_income: summary.monthly_income,
        installments_due_this_month: summary.installments_due_this_month,
        spent_this_month: summary.spent_this_month,
        safe_to_spend_this_month: summary.safe_to_spend_this_month,
        provisional: summary.provisional,
      },
      fixture.expected,
      fixture.name,
    );
    assert.deepEqual(
      [
        summary.as_of,
        summary.month_start,
        summary.local_year,
        summary.local_month,
      ],
      [
        fixture.calendar.asOf,
        fixture.calendar.monthStart,
        fixture.calendar.year,
        fixture.calendar.month,
      ],
      fixture.name,
    );
  }
});

Deno.test(
  "fixtures cover all six Gulf currencies and installment views reproduce reserved totals",
  () => {
    assert.deepEqual(
      [...new Set(fixtures.map((fixture) => fixture.expected.currency))].sort(),
      ["AED", "BHD", "KWD", "OMR", "QAR", "SAR"],
    );
    for (const fixture of fixtures) {
      const calendar = resolveCalendar(
        fixture.calendar,
        new Date(fixture.calendar.asOf),
      );
      const decimals = ["KWD", "BHD", "OMR"].includes(fixture.expected.currency)
        ? 3
        : 2;
      const reserved = describeInstallments(fixture.plans, calendar)
        .filter((view) => view.currency === fixture.expected.currency)
        .reduce(
          (sum, view) =>
            sum +
            minor(view.monthly_amount, decimals) *
              BigInt(view.reserved_payment_count),
          0n,
        );
      assert.equal(
        reserved,
        minor(fixture.expected.installments_due_this_month, decimals),
        fixture.name,
      );
    }
  },
);

Deno.test("exact fils and binary-float traps stay exact", () => {
  const kwd = computeBudget(
    { currency: "KWD", monthly_income: 0.3 },
    [],
    [
      { amount: 0.1, currency: "KWD", spent_at: "2026-11-02T00:00:00+00:00" },
      { amount: 0.2, currency: "KWD", spent_at: "2026-11-03T00:00:00+00:00" },
    ],
    CONTEXT,
  );
  assert.deepEqual(
    [kwd.monthly_income, kwd.spent_this_month, kwd.safe_to_spend_this_month],
    ["0.300", "0.300", "0.000"],
  );
  const sar = computeBudget(
    { currency: "SAR", monthly_income: 0.3 },
    [],
    [
      { amount: 0.1, currency: "SAR", spent_at: "2026-11-02T00:00:00+00:00" },
      { amount: 0.2, currency: "SAR", spent_at: "2026-11-03T00:00:00+00:00" },
    ],
    CONTEXT,
  );
  assert.deepEqual(
    [sar.spent_this_month, sar.safe_to_spend_this_month],
    ["0.30", "0.00"],
  );
});

Deno.test("refunds reduce spending and over-refunds are rejected", () => {
  const budget = computeBudget(
    { currency: "SAR", monthly_income: 1000 },
    [],
    [
      { amount: 100, refunded_amount: 30, currency: "SAR", spent_at: "2026-11-02T00:00:00+00:00" },
      { amount: 50, refunded_amount: 50, currency: "SAR", spent_at: "2026-11-03T00:00:00+00:00" },
      { amount: 20, refunded_amount: null, currency: "SAR", spent_at: "2026-11-04T00:00:00+00:00" },
    ],
    CONTEXT,
  );
  assert.deepEqual(
    [budget.spent_this_month, budget.safe_to_spend_this_month],
    ["90.00", "910.00"],
  );
  assert.throws(() =>
    computeBudget(
      { currency: "SAR", monthly_income: 0 },
      [],
      [{ amount: 10, refunded_amount: 11, currency: "SAR", spent_at: "2026-11-02T00:00:00+00:00" }],
      CONTEXT,
    )
  );
});

Deno.test(
  "canonical decimal inputs accept exact precision and reject ambiguous text",
  () => {
    assert.equal(sarIncome("100.500"), "100.50");
    assert.equal(sarIncome(0), "0.00");
    assert.equal(sarIncome("99999999999.99"), "99999999999.99");
    for (const bad of [
      "100.505",
      "1,000",
      " 1",
      "1e3",
      "-1",
      ".5",
      "5.",
      "100000000000",
      100000000000,
      1.005,
      1e21,
      Number.NaN,
      Number.POSITIVE_INFINITY,
    ]) {
      expectCode("invalid_profile", () => sarIncome(bad));
    }
    expectCode("invalid_profile", () =>
      computeBudget(
        { currency: "KWD", monthly_income: "10.0001" },
        [],
        [],
        CONTEXT,
      ),
    );
  },
);

Deno.test(
  "expense timestamps compare as instants and rows are validated before filtering",
  () => {
    const profile = { currency: "SAR", monthly_income: 100 };
    const atAsOf = computeBudget(
      profile,
      [],
      [{ amount: 10, currency: "SAR", spent_at: "2026-11-06T13:00:00+03:00" }],
      CONTEXT,
    );
    assert.equal(atAsOf.spent_this_month, "10.00");
    const decimalText = computeBudget(
      profile,
      [],
      [{ amount: "12.5", currency: "SAR", spent_at: "2026-11-06T09:00:00Z" }],
      CONTEXT,
    );
    assert.equal(decimalText.spent_this_month, "12.50");
    const bad: Record<string, unknown>[] = [
      { amount: 1, currency: "SAR", spent_at: "2026-11-06" },
      { amount: 1, currency: "SAR", spent_at: "2026-11-06T10:00:00" },
      { amount: "12,5", currency: "SAR", spent_at: "2026-11-06T10:00:00Z" },
      { amount: 1.005, currency: "SAR", spent_at: "2026-11-06T10:00:00Z" },
      { amount: 1, currency: "sar", spent_at: "2026-11-06T10:00:00Z" },
      { amount: 1, currency: "SAR", spent_at: 12345 },
    ];
    for (const row of bad) {
      expectCode("invalid_expense", () =>
        computeBudget(profile, [], [row], CONTEXT),
      );
    }
    const foreign = computeBudget(
      profile,
      [],
      [{ amount: 1.005, currency: "KWD", spent_at: "2026-11-06T10:00:00Z" }],
      CONTEXT,
    );
    assert.equal(foreign.spent_this_month, "0.00");
  },
);

Deno.test(
  "malformed profile and plan rows fail closed with controlled codes",
  () => {
    const profile = { currency: "SAR", monthly_income: 100 };
    for (const bad of [
      { ...profile, currency: "sar" },
      { monthly_income: 100 },
      { ...profile, monthly_income: -1 },
      { ...profile, monthly_income: Number.NaN },
    ]) {
      expectCode("invalid_profile", () => computeBudget(bad, [], [], CONTEXT));
    }
    const plan = {
      id: "p",
      name: "Plan",
      provider: "Bank",
      kind: "loan",
      currency: "SAR",
      monthly_amount: 10,
      total_amount: 20,
      total_count: 2,
      paid_count: 1,
      due_day: 10,
      next_due_date: "2026-11-10",
      active: true,
    };
    const badPlans: Record<string, unknown>[] = [
      { ...plan, paid_count: 3 },
      { ...plan, total_count: 0, paid_count: 0 },
      { ...plan, due_day: 0 },
      { ...plan, due_day: 32 },
      { ...plan, active: "true" },
      { ...plan, next_due_date: "2026-02-30" },
      { ...plan, next_due_date: "2026-11-1" },
      { ...plan, due_day: 31, next_due_date: "2027-02-15" },
      { ...plan, monthly_amount: -1 },
      { ...plan, monthly_amount: 10.001 },
      { ...plan, id: 5 },
      { ...plan, paid_count: "1" },
      { ...plan, total_count: 2147483648 },
      { ...plan, paid_count: 2, active: true },
      { ...plan, paid_count: 2, active: false, next_due_date: "2026-11-10" },
      { ...plan, currency: "sar" },
    ];
    for (const row of badPlans) {
      expectCode("invalid_plan", () =>
        computeBudget(profile, [row], [], CONTEXT),
      );
      expectCode("invalid_plan", () => describeInstallments([row], CONTEXT));
    }
    expectCode("invalid_plan", () =>
      computeBudget(
        profile,
        {} as unknown as Record<string, unknown>[],
        [],
        CONTEXT,
      ),
    );
    expectCode("invalid_expense", () =>
      computeBudget(
        profile,
        [],
        {} as unknown as Record<string, unknown>[],
        CONTEXT,
      ),
    );
    expectCode("invalid_calendar", () =>
      computeBudget(profile, [], [], { ...CONTEXT, asOf: "not-a-time" }),
    );
  },
);

Deno.test(
  "installment descriptions list only active unfinished plans with exact balances and reserves",
  () => {
    const views = describeInstallments(
      [
        {
          id: "a",
          name: "Phone",
          provider: "Bank A",
          kind: "bnpl",
          currency: "SAR",
          monthly_amount: 100.41,
          total_amount: 502.05,
          total_count: 5,
          paid_count: 3,
          due_day: 10,
          next_due_date: "2026-11-10",
          active: true,
        },
        {
          id: "b",
          currency: "SAR",
          monthly_amount: 50,
          total_count: 2,
          paid_count: 2,
          due_day: 5,
          next_due_date: null,
          active: false,
        },
        {
          id: "c",
          currency: "SAR",
          monthly_amount: 60,
          total_count: 3,
          paid_count: 1,
          due_day: 5,
          next_due_date: "2026-11-05",
          active: false,
        },
        {
          id: "d",
          currency: "KWD",
          monthly_amount: 12.5,
          total_count: 4,
          paid_count: 0,
          due_day: 20,
          next_due_date: null,
          active: true,
        },
        {
          id: "e",
          currency: "SAR",
          monthly_amount: 50,
          total_count: 6,
          paid_count: 4,
          due_day: 1,
          next_due_date: "2026-08-01",
          active: true,
        },
        {
          id: "f",
          currency: "SAR",
          monthly_amount: 10,
          total_count: 3,
          paid_count: 0,
          due_day: 5,
          next_due_date: "2027-01-05",
          active: true,
        },
        {
          id: "g",
          currency: "SAR",
          monthly_amount: 7,
          total_count: 3,
          paid_count: 1,
          due_day: 31,
          next_due_date: "2027-02-28",
          active: true,
        },
      ],
      CONTEXT,
    );
    assert.deepEqual(views, [
      {
        id: "a",
        name: "Phone",
        provider: "Bank A",
        kind: "bnpl",
        currency: "SAR",
        monthly_amount: "100.41",
        remaining_payments: 2,
        remaining_balance: "200.82",
        due_day: 10,
        next_due_date: "2026-11-10",
        schedule_needed: false,
        reserved_payment_count: 1,
      },
      {
        id: "d",
        name: null,
        provider: null,
        kind: null,
        currency: "KWD",
        monthly_amount: "12.500",
        remaining_payments: 4,
        remaining_balance: "50.000",
        due_day: 20,
        next_due_date: null,
        schedule_needed: true,
        reserved_payment_count: 1,
      },
      {
        id: "e",
        name: null,
        provider: null,
        kind: null,
        currency: "SAR",
        monthly_amount: "50.00",
        remaining_payments: 2,
        remaining_balance: "100.00",
        due_day: 1,
        next_due_date: "2026-08-01",
        schedule_needed: false,
        reserved_payment_count: 2,
      },
      {
        id: "f",
        name: null,
        provider: null,
        kind: null,
        currency: "SAR",
        monthly_amount: "10.00",
        remaining_payments: 3,
        remaining_balance: "30.00",
        due_day: 5,
        next_due_date: "2027-01-05",
        schedule_needed: false,
        reserved_payment_count: 0,
      },
      {
        id: "g",
        name: null,
        provider: null,
        kind: null,
        currency: "SAR",
        monthly_amount: "7.00",
        remaining_payments: 2,
        remaining_balance: "14.00",
        due_day: 31,
        next_due_date: "2027-02-28",
        schedule_needed: false,
        reserved_payment_count: 0,
      },
    ]);
    assert.deepEqual(describeInstallments([], CONTEXT), []);
  },
);

Deno.test("purchase split allocates whole minor units exactly", () => {
  assert.deepEqual(simulatePurchase({ amount: 100, months: 3 }, SAR_SUMMARY), {
    amount: "100.00",
    months: 3,
    currency: "SAR",
    per_month: "33.34",
    base_per_month: "33.33",
    higher_payment_amount: "33.34",
    higher_payment_count: 1,
    lower_payment_count: 2,
    monthly_impact: "33.34",
    total_amount: "100.00",
    first_payment_month: "2026-11",
    safe_to_spend_before: "13549.25",
    safe_to_spend_after: "13515.91",
    monthly_installments_after: "1233.84",
    breaches_budget: false,
    affordable_this_month: true,
    provisional: false,
    hypothetical: true,
  });
  const kwd = simulatePurchase({ amount: 10.001, months: 2 }, KWD_SUMMARY);
  assert.deepEqual(
    [
      kwd.per_month,
      kwd.base_per_month,
      kwd.higher_payment_amount,
      kwd.higher_payment_count,
      kwd.lower_payment_count,
      kwd.total_amount,
      kwd.safe_to_spend_after,
      kwd.monthly_installments_after,
    ],
    ["5.001", "5.000", "5.001", 1, 1, "10.001", "1117.095", "105.126"],
  );
  const zero = simulatePurchase({ amount: 0 }, SAR_SUMMARY);
  assert.deepEqual(
    [
      zero.per_month,
      zero.base_per_month,
      zero.higher_payment_amount,
      zero.higher_payment_count,
      zero.lower_payment_count,
      zero.total_amount,
      zero.safe_to_spend_after,
      zero.monthly_installments_after,
      zero.breaches_budget,
      zero.affordable_this_month,
    ],
    ["0.00", "0.00", null, 0, 1, "0.00", "13549.25", null, false, true],
  );
  const huge = simulatePurchase(
    { amount: 0.01, months: 2147483647 },
    SAR_SUMMARY,
  );
  assert.deepEqual(
    [
      huge.per_month,
      huge.base_per_month,
      huge.higher_payment_amount,
      huge.higher_payment_count,
      huge.lower_payment_count,
      huge.total_amount,
      huge.monthly_installments_after,
    ],
    ["0.01", "0.00", "0.01", 1, 2147483646, "0.01", "1200.51"],
  );
});

Deno.test("every split reconstructs the requested total in minor units", () => {
  for (const amount of ["0.01", "0.99", "10.00", "1234.57"]) {
    for (let months = 1; months <= 12; months++) {
      const sim = simulatePurchase(
        { amount: Number(amount), months },
        SAR_SUMMARY,
      );
      const base = minor(sim.base_per_month, 2);
      const higher =
        sim.higher_payment_amount === null
          ? base
          : minor(sim.higher_payment_amount, 2);
      const higherCount = BigInt(sim.higher_payment_count);
      const lowerCount = BigInt(sim.lower_payment_count);
      assert.equal(higherCount + lowerCount, BigInt(months));
      assert.equal(
        base * lowerCount + higher * higherCount,
        minor(amount, 2),
        `${amount} over ${months}`,
      );
      assert.equal(
        minor(sim.per_month, 2),
        higherCount > 0n ? higher : base,
        `${amount} over ${months}`,
      );
    }
  }
});

Deno.test(
  "affordability is provisional when the baseline has schedule-needed plans",
  () => {
    const provisional = simulatePurchase(
      { amount: 100 },
      { ...SAR_SUMMARY, provisional: true },
    );
    assert.deepEqual(
      [
        provisional.affordable_this_month,
        provisional.breaches_budget,
        provisional.provisional,
        provisional.safe_to_spend_after,
      ],
      [null, false, true, "13449.25"],
    );
    const overProvisional = simulatePurchase(
      { amount: 14000 },
      { ...SAR_SUMMARY, provisional: true },
    );
    assert.equal(overProvisional.breaches_budget, true);
    assert.equal(overProvisional.affordable_this_month, null);
    const boundary = simulatePurchase({ amount: 13549.25 }, SAR_SUMMARY);
    assert.deepEqual(
      [
        boundary.safe_to_spend_after,
        boundary.affordable_this_month,
        boundary.breaches_budget,
      ],
      ["0.00", true, false],
    );
    const over = simulatePurchase({ amount: 14000 }, SAR_SUMMARY);
    assert.deepEqual(
      [
        over.safe_to_spend_after,
        over.affordable_this_month,
        over.breaches_budget,
      ],
      ["-450.75", false, true],
    );
    const negativeBaseline = simulatePurchase(
      { amount: 0 },
      { ...SAR_SUMMARY, safe_to_spend_this_month: "-50.00" },
    );
    assert.deepEqual(
      [negativeBaseline.safe_to_spend_after, negativeBaseline.breaches_budget],
      ["-50.00", true],
    );
  },
);

Deno.test(
  "simulation accepts derived aggregate totals beyond the per-row storage range",
  () => {
    const plan = {
      currency: "SAR",
      monthly_amount: 60000000000,
      total_count: 1,
      paid_count: 0,
      due_day: 5,
      next_due_date: "2026-11-05",
      active: true,
    };
    const expense = { currency: "SAR", amount: 60000000000, spent_at: ASOF };
    const summary = computeBudget(
      { currency: "SAR", monthly_income: 100 },
      [plan, plan],
      [expense, expense],
      CONTEXT,
    );
    assert.equal(summary.spent_this_month, "120000000000.00");
    assert.equal(summary.installments_due_this_month, "120000000000.00");
    const result = simulatePurchase({ amount: 0.02, months: 2 }, summary);
    assert.equal(result.safe_to_spend_before, "-239999999900.00");
    assert.equal(result.safe_to_spend_after, "-239999999900.01");
    assert.equal(result.monthly_installments_after, "120000000000.01");
  },
);

Deno.test(
  "purchase input rejects coercion, extraneous fields, bad counts and foreign currencies",
  () => {
    const invalid: Record<string, unknown>[] = [
      { amount: "10" },
      { amount: null },
      {},
      { amount: Number.NaN },
      { amount: Number.POSITIVE_INFINITY },
      { amount: -1 },
      { amount: 1.005 },
      { amount: 1e-7 },
      { amount: 0.1 + 0.2 },
      { amount: 100000000000 },
      { amount: 1, price: 2 },
      { amount: 1, months: 0 },
      { amount: 1, months: -1 },
      { amount: 1, months: 1.5 },
      { amount: 1, months: "2" },
      { amount: 1, months: null },
      { amount: 1, months: 2147483648 },
      { amount: 1, months: Number.NaN },
      { amount: 1, currency: "SA" },
      { amount: 1, currency: null },
      { amount: 1, currency: "SA R" },
    ];
    for (const input of invalid) {
      expectCode("invalid_input", () => simulatePurchase(input, SAR_SUMMARY));
    }
    expectCode("invalid_input", () =>
      simulatePurchase(null as unknown as Record<string, unknown>, SAR_SUMMARY),
    );
    expectCode("currency_mismatch", () =>
      simulatePurchase({ amount: 1, currency: "usd" }, SAR_SUMMARY),
    );
    expectCode("currency_mismatch", () =>
      simulatePurchase({ amount: 1, currency: "KWD" }, SAR_SUMMARY),
    );
    assert.equal(
      simulatePurchase({ amount: 1, currency: "sar" }, SAR_SUMMARY).currency,
      "SAR",
    );
    assert.equal(
      simulatePurchase({ amount: 1.001, currency: "kwd" }, KWD_SUMMARY)
        .currency,
      "KWD",
    );
    expectCode("invalid_input", () =>
      simulatePurchase({ amount: 1.0001 }, KWD_SUMMARY),
    );
    assert.equal(
      simulatePurchase({ amount: 99999999999.99 }, SAR_SUMMARY).total_amount,
      "99999999999.99",
    );
  },
);

Deno.test(
  "malformed budget baselines are rejected before any simulation",
  () => {
    expectCode("invalid_summary", () =>
      simulatePurchase(
        { amount: 1 },
        { ...SAR_SUMMARY, safe_to_spend_this_month: "1,000.00" },
      ),
    );
    expectCode("invalid_summary", () =>
      simulatePurchase({ amount: 1 }, { ...SAR_SUMMARY, currency: "sar" }),
    );
    expectCode("invalid_summary", () =>
      simulatePurchase(
        { amount: 1 },
        { ...SAR_SUMMARY, provisional: "no" as unknown as boolean },
      ),
    );
    expectCode("invalid_summary", () =>
      simulatePurchase({ amount: 1 }, { ...SAR_SUMMARY, as_of: "2026-11-06" }),
    );
  },
);

Deno.test(
  "budget and simulation never mutate inputs and errors never echo caller values",
  () => {
    const plans = [
      {
        id: "a",
        currency: "SAR",
        monthly_amount: 10,
        total_count: 3,
        paid_count: 1,
        due_day: 5,
        next_due_date: "2026-11-05",
        active: true,
      },
    ];
    const expenses = [
      { amount: 5, currency: "SAR", spent_at: "2026-11-03T00:00:00+00:00" },
    ];
    const profile = { currency: "SAR", monthly_income: 100 };
    const before = structuredClone({ profile, plans, expenses });
    computeBudget(profile, plans, expenses, CONTEXT);
    describeInstallments(plans, CONTEXT);
    assert.deepEqual({ profile, plans, expenses }, before);
    const input = { amount: 100, months: 3 };
    const inputBefore = structuredClone(input);
    simulatePurchase(input, SAR_SUMMARY);
    assert.deepEqual(input, inputBefore);
    const error = captureError(() =>
      simulatePurchase({ currency: "SECRET-TOKEN-VALUE" }, SAR_SUMMARY),
    );
    assert.equal(error.code, "invalid_input");
    assert.equal(error.name, "FinanceError");
    assert.ok(!error.message.includes("SECRET"));
  },
);

Deno.test(
  "finance module has no runtime, environment, or network dependency",
  () => {
    const source = readFileSync(
      new URL("./finance.ts", import.meta.url),
      "utf8",
    );
    for (const forbidden of [
      "Deno.",
      "process.env",
      "fetch(",
      "Date.UTC(",
      "node:",
    ]) {
      assert.ok(!source.includes(forbidden), forbidden);
    }
    assert.doesNotMatch(source, /^import\s/m);
  },
);
