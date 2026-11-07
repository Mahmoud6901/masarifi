// Read-only financial rules for the agent. This module is pure: no environment, network,
// or database access, so it can be imported and tested directly.
// Money is exact. Inputs are validated as canonical decimal text, summed as BigInt minor
// units, and returned as canonical decimal strings with the currency's fractional digits.

export type CalendarSource = "client" | "utc";

export interface CalendarContext {
  asOf: string;
  monthStart: string;
  year: number;
  month: number;
  source: CalendarSource;
}

export interface BudgetSummary {
  currency: string;
  monthly_income: string;
  installments_due_this_month: string;
  spent_this_month: string;
  safe_to_spend_this_month: string;
  provisional: boolean;
  as_of: string;
  month_start: string;
  local_year: number;
  local_month: number;
}

export interface InstallmentView {
  id: string | null;
  name: string | null;
  provider: string | null;
  kind: string | null;
  currency: string;
  monthly_amount: string;
  remaining_payments: number;
  remaining_balance: string;
  due_day: number;
  next_due_date: string | null;
  schedule_needed: boolean;
  reserved_payment_count: number;
}

export interface PurchaseSimulation {
  amount: string;
  months: number;
  currency: string;
  per_month: string;
  base_per_month: string;
  higher_payment_amount: string | null;
  higher_payment_count: number;
  lower_payment_count: number;
  monthly_impact: string;
  total_amount: string;
  first_payment_month: string;
  safe_to_spend_before: string;
  safe_to_spend_after: string;
  monthly_installments_after: string | null;
  breaches_budget: boolean;
  affordable_this_month: boolean | null;
  provisional: boolean;
  hypothetical: true;
}

export class FinanceError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = "FinanceError";
    this.code = code;
  }
}

type Obj = Record<string, unknown>;

interface CalendarTimes {
  asOf: bigint;
  start: bigint;
  year: number;
  month: number;
}

interface ScheduleDate {
  year: number;
  month: number;
  day: number;
  text: string;
}

interface NormalizedPlan {
  id: string | null;
  name: string | null;
  provider: string | null;
  kind: string | null;
  currency: string;
  monthlyUnits: bigint;
  dueDay: number;
  remaining: number;
  active: boolean;
  nextDue: ScheduleDate | null;
}

interface Baseline {
  currency: string;
  safe: bigint;
  installments: bigint;
  provisional: boolean;
  year: number;
  month: number;
}

const MINUTE_MICROS = 60_000_000n;
const MAX_OFFSET_MINUTES = 840n;
const MAX_CLOCK_SKEW_MICROS = 300_000_000n;
const MAX_CALENDAR_SPAN_MICROS = 32n * 86_400_000_000n;
const MAX_MONEY_EXCLUSIVE = 100_000_000_000n;
const MAX_COUNT = 2_147_483_647;
const CALENDAR_KEYS = ["asOf", "monthStart", "year", "month"];
const PURCHASE_KEYS = ["amount", "months", "currency"];
const THREE_DECIMAL_CURRENCIES = ["KWD", "BHD", "OMR"];
const CURRENCY_RE = /^[A-Z]{3}$/;
const DECIMAL_RE = /^(-?)(\d+)(?:\.(\d+))?$/;
const DATE_ONLY_RE = /^(\d{4})-(\d{2})-(\d{2})$/;
const INSTANT_RE =
  /^(\d{4})-(\d{2})-(\d{2})([T ])(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?(Z|[+-]\d{2}(?::?\d{2})?)$/;
const ZONE_RE = /^([+-])(\d{2})(?::?(\d{2}))?$/;

const MESSAGES = {
  calendar: "Calendar context is invalid. Retry to capture a fresh calendar.",
  stale:
    "Calendar context is outside the five-minute freshness window. Retry to capture a fresh calendar.",
  profile: "Profile financial data is invalid, so no budget was calculated.",
  plan: "Installment data is invalid, so no budget was calculated.",
  expense: "Expense data is invalid, so no budget was calculated.",
  summary: "Budget baseline is invalid, so no purchase was simulated.",
  input:
    "Purchase input is invalid. Use a finite amount with at most the currency precision and below 100000000000, months from 1 to 2147483647, and an optional currency matching the profile.",
  mismatch:
    "The purchase currency differs from the profile currency. Foreign-currency affordability is not calculated.",
};

export function resolveCalendar(input: unknown, now: Date): CalendarContext {
  const nowMillis = now instanceof Date ? now.getTime() : Number.NaN;
  if (!Number.isFinite(nowMillis)) fail("invalid_calendar", MESSAGES.calendar);
  const nowMicros = BigInt(nowMillis) * 1000n;
  if (input === undefined) {
    const year = now.getUTCFullYear();
    const month = now.getUTCMonth() + 1;
    return {
      asOf: formatInstant(nowMicros),
      monthStart: formatInstant(
        BigInt(utcDayMillis(year, month - 1, 1)) * 1000n,
      ),
      year,
      month,
      source: "utc",
    };
  }
  if (!isObject(input) || !hasExactKeys(input, CALENDAR_KEYS))
    fail("invalid_calendar", MESSAGES.calendar);
  const times = calendarTimes(
    input.asOf,
    input.monthStart,
    input.year,
    input.month,
  );
  const skew = times.asOf - nowMicros;
  if (skew > MAX_CLOCK_SKEW_MICROS || skew < -MAX_CLOCK_SKEW_MICROS)
    fail("stale_calendar", MESSAGES.stale);
  return {
    asOf: formatInstant(times.asOf),
    monthStart: formatInstant(times.start),
    year: times.year,
    month: times.month,
    source: "client",
  };
}

export function computeBudget(
  profile: Record<string, unknown>,
  plans: Record<string, unknown>[],
  expenses: Record<string, unknown>[],
  calendar: CalendarContext,
): BudgetSummary {
  if (!isObject(profile)) fail("invalid_profile", MESSAGES.profile);
  const currency = profile.currency;
  if (!isCurrencyCode(currency)) fail("invalid_profile", MESSAGES.profile);
  const income = must(
    moneyUnits(profile.monthly_income, currency, false),
    "invalid_profile",
    MESSAGES.profile,
  );
  if (!Array.isArray(plans)) fail("invalid_plan", MESSAGES.plan);
  if (!Array.isArray(expenses)) fail("invalid_expense", MESSAGES.expense);
  const times = contextTimes(calendar);
  const normalizedPlans = plans.map(normalizePlan);

  let spent = 0n;
  for (const raw of expenses) {
    const expense = normalizeExpense(raw);
    if (
      expense.currency === currency &&
      expense.spentAt >= times.start &&
      expense.spentAt <= times.asOf
    ) {
      spent += expense.units;
    }
  }

  let due = 0n;
  let provisional = false;
  for (const plan of normalizedPlans) {
    if (plan.currency !== currency || !plan.active || plan.remaining === 0)
      continue;
    if (plan.nextDue === null) provisional = true;
    due += plan.monthlyUnits * BigInt(reservedCount(plan, times));
  }

  return {
    currency,
    monthly_income: formatMoney(income, currency),
    installments_due_this_month: formatMoney(due, currency),
    spent_this_month: formatMoney(spent, currency),
    safe_to_spend_this_month: formatMoney(income - due - spent, currency),
    provisional,
    as_of: formatInstant(times.asOf),
    month_start: formatInstant(times.start),
    local_year: times.year,
    local_month: times.month,
  };
}

export function describeInstallments(
  plans: Record<string, unknown>[],
  calendar: CalendarContext,
): InstallmentView[] {
  if (!Array.isArray(plans)) fail("invalid_plan", MESSAGES.plan);
  const times = contextTimes(calendar);
  return plans
    .map(normalizePlan)
    .filter((plan) => plan.active && plan.remaining > 0)
    .map((plan): InstallmentView => ({
      id: plan.id,
      name: plan.name,
      provider: plan.provider,
      kind: plan.kind,
      currency: plan.currency,
      monthly_amount: formatMoney(plan.monthlyUnits, plan.currency),
      remaining_payments: plan.remaining,
      remaining_balance: formatMoney(
        plan.monthlyUnits * BigInt(plan.remaining),
        plan.currency,
      ),
      due_day: plan.dueDay,
      next_due_date: plan.nextDue === null ? null : plan.nextDue.text,
      schedule_needed: plan.nextDue === null,
      reserved_payment_count: reservedCount(plan, times),
    }));
}

export function describeExpenses(rows: Record<string, unknown>[]) {
  return rows.map((raw) => {
    const expense = normalizeExpense(raw);
    return {
      id: typeof raw.id === "string" ? raw.id : null,
      merchant: typeof raw.merchant === "string" ? raw.merchant : null,
      category: typeof raw.category === "string" ? raw.category : null,
      currency: expense.currency,
      amount: formatMoney(expense.units, expense.currency),
      spent_at: formatInstant(expense.spentAt),
    };
  });
}

// The hypothetical purchase is split into whole minor units: the first `remainder` payments
// carry one extra unit, so the payments always sum exactly to the requested amount. The first
// payment is due in the current month. No interest, fee, grace period or lender schedule.
export function simulatePurchase(
  input: Record<string, unknown>,
  summary: BudgetSummary,
): PurchaseSimulation {
  const baseline = parseBaseline(summary);
  if (
    !isObject(input) ||
    Object.keys(input).some((key) => !PURCHASE_KEYS.includes(key))
  ) {
    fail("invalid_input", MESSAGES.input);
  }
  const requestedCurrency =
    input.currency === undefined
      ? baseline.currency
      : normalizeCurrencyInput(input.currency);
  if (requestedCurrency === null) fail("invalid_input", MESSAGES.input);
  if (requestedCurrency !== baseline.currency)
    fail("currency_mismatch", MESSAGES.mismatch);
  const currency = baseline.currency;
  const rawAmount = input.amount;
  const total = must(
    typeof rawAmount === "number"
      ? moneyUnits(rawAmount, currency, false)
      : null,
    "invalid_input",
    MESSAGES.input,
  );
  const months = must(
    integerInRange(input.months === undefined ? 1 : input.months, 1, MAX_COUNT),
    "invalid_input",
    MESSAGES.input,
  );

  const count = BigInt(months);
  const base = total / count;
  const remainder = total % count;
  const first = remainder > 0n ? base + 1n : base;
  const higherCount = Number(remainder);
  const after = baseline.safe - first;
  const provisional = baseline.provisional;

  return {
    amount: formatMoney(total, currency),
    months,
    currency,
    per_month: formatMoney(first, currency),
    base_per_month: formatMoney(base, currency),
    higher_payment_amount:
      remainder > 0n ? formatMoney(base + 1n, currency) : null,
    higher_payment_count: higherCount,
    lower_payment_count: months - higherCount,
    monthly_impact: formatMoney(first, currency),
    total_amount: formatMoney(total, currency),
    first_payment_month: `${baseline.year}-${String(baseline.month).padStart(2, "0")}`,
    safe_to_spend_before: formatMoney(baseline.safe, currency),
    safe_to_spend_after: formatMoney(after, currency),
    monthly_installments_after:
      months > 1 ? formatMoney(baseline.installments + first, currency) : null,
    breaches_budget: after < 0n,
    affordable_this_month: provisional ? null : after >= 0n,
    provisional,
    hypothetical: true,
  };
}

function fail(code: string, message: string): never {
  throw new FinanceError(code, message);
}

function must<T>(value: T | null, code: string, message: string): T {
  if (value === null) fail(code, message);
  return value;
}

function isObject(value: unknown): value is Obj {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(value: Obj, keys: readonly string[]): boolean {
  return (
    Object.keys(value).length === keys.length &&
    keys.every((key) => Object.prototype.hasOwnProperty.call(value, key))
  );
}

function isCurrencyCode(value: unknown): value is string {
  return typeof value === "string" && CURRENCY_RE.test(value);
}

function normalizeCurrencyInput(value: unknown): string | null {
  return typeof value === "string" && /^[A-Za-z]{3}$/.test(value)
    ? value.toUpperCase()
    : null;
}

function currencyDecimals(currency: string): number {
  return THREE_DECIMAL_CURRENCIES.includes(currency) ? 3 : 2;
}

function minorScale(currency: string): bigint {
  return currencyDecimals(currency) === 3 ? 1000n : 100n;
}

// Accepts a finite JSON number or canonical decimal text. Exponent notation, grouping,
// signs (unless allowed), extra fractional digits and values at or above 1e11 are rejected.
function moneyUnits(
  value: unknown,
  currency: string,
  allowNegative: boolean,
  bounded = true,
): bigint | null {
  let text: string;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) return null;
    text = String(value);
  } else if (typeof value === "string") {
    text = value;
  } else {
    return null;
  }
  if (/[eE]/.test(text)) return null;
  const match = DECIMAL_RE.exec(text);
  if (!match) return null;
  const negative = match[1] === "-";
  if (negative && !allowNegative) return null;
  const decimals = currencyDecimals(currency);
  const fraction = (match[3] ?? "").replace(/0+$/, "");
  if (fraction.length > decimals) return null;
  const whole = BigInt(match[2]);
  if (bounded && whole >= MAX_MONEY_EXCLUSIVE) return null;
  const units =
    whole * minorScale(currency) + BigInt(fraction.padEnd(decimals, "0"));
  return negative ? -units : units;
}

function formatMoney(units: bigint, currency: string): string {
  const magnitude = units < 0n ? -units : units;
  const scale = minorScale(currency);
  const whole = magnitude / scale;
  const fraction = (magnitude % scale)
    .toString()
    .padStart(currencyDecimals(currency), "0");
  return `${units < 0n ? "-" : ""}${whole.toString()}.${fraction}`;
}

function integerInRange(
  value: unknown,
  min: number,
  max: number,
): number | null {
  return typeof value === "number" &&
    Number.isSafeInteger(value) &&
    value >= min &&
    value <= max
    ? value
    : null;
}

// Date.UTC maps years 0-99 to 1900-1999. setUTCFullYear keeps the stated year exact.
function utcDayMillis(year: number, monthIndex: number, day: number): number {
  const date = new Date(0);
  date.setUTCFullYear(year, monthIndex, day);
  return date.getTime();
}

// month is 1-based. Day 0 of the following month is the last day of this one.
function daysInMonth(year: number, month: number): number {
  const date = new Date(0);
  date.setUTCFullYear(year, month, 0);
  return date.getUTCDate();
}

function floorDiv(a: bigint, b: bigint): bigint {
  const quotient = a / b;
  return a % b !== 0n && a < 0n ? quotient - 1n : quotient;
}

function ceilDiv(a: bigint, b: bigint): bigint {
  const quotient = a / b;
  return a % b !== 0n && a > 0n ? quotient + 1n : quotient;
}

function bigMax(a: bigint, b: bigint): bigint {
  return a > b ? a : b;
}

function bigMin(a: bigint, b: bigint): bigint {
  return a < b ? a : b;
}

// Canonical UTC text. Whole milliseconds render like Date#toISOString; sub-millisecond
// digits extend it to six fractional digits, matching Dart's microsecond output.
function formatInstant(micros: bigint): string {
  const millis = floorDiv(micros, 1000n);
  const subMillis = micros - millis * 1000n;
  const iso = new Date(Number(millis)).toISOString();
  return subMillis === 0n
    ? iso
    : `${iso.slice(0, 23)}${subMillis.toString().padStart(3, "0")}Z`;
}

function zoneMinutes(zone: string): number | null {
  if (zone === "Z") return 0;
  const match = ZONE_RE.exec(zone);
  if (!match) return null;
  const hours = Number(match[2]);
  const minutes = match[3] ? Number(match[3]) : 0;
  const total = hours * 60 + minutes;
  if (hours > 14 || minutes > 59 || total > 840) return null;
  return match[1] === "-" ? -total : total;
}

// Returns epoch microseconds. utcOnly requires the calendar form (T separator, Z suffix).
function parseInstant(text: string, utcOnly: boolean): bigint | null {
  const match = INSTANT_RE.exec(text);
  if (!match) return null;
  const [
    ,
    yearText,
    monthText,
    dayText,
    separator,
    hourText,
    minuteText,
    secondText,
    fractionText = "",
    zone,
  ] = match;
  if (utcOnly && (separator !== "T" || zone !== "Z")) return null;
  const year = Number(yearText);
  const month = Number(monthText);
  const day = Number(dayText);
  const hour = Number(hourText);
  const minute = Number(minuteText);
  const second = Number(secondText);
  const offset = zoneMinutes(zone);
  if (
    year < 1 ||
    month < 1 ||
    month > 12 ||
    day < 1 ||
    day > daysInMonth(year, month) ||
    hour > 23 ||
    minute > 59 ||
    second > 59 ||
    offset === null
  ) {
    return null;
  }
  const wallMillis =
    utcDayMillis(year, month - 1, day) +
    ((hour * 60 + minute) * 60 + second) * 1000;
  return (
    BigInt(wallMillis) * 1000n +
    BigInt(fractionText.padEnd(6, "0")) -
    BigInt(offset) * MINUTE_MICROS
  );
}

function parseDateOnly(value: unknown): ScheduleDate | null {
  if (typeof value !== "string") return null;
  const match = DATE_ONLY_RE.exec(value);
  if (!match) return null;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  if (
    year < 1 ||
    month < 1 ||
    month > 12 ||
    day < 1 ||
    day > daysInMonth(year, month)
  )
    return null;
  return { year, month, day, text: value };
}

// The month start must be local midnight on day 1 for some whole-minute offset in
// [-14h, +14h]. asOf must fall in the stated local month for some supported offset, so
// a DST change between month start and now does not force a single offset.
function calendarTimes(
  asOfText: unknown,
  monthStartText: unknown,
  year: unknown,
  month: unknown,
): CalendarTimes {
  if (
    typeof asOfText !== "string" ||
    typeof monthStartText !== "string" ||
    typeof year !== "number" ||
    typeof month !== "number" ||
    !Number.isInteger(year) ||
    !Number.isInteger(month) ||
    year < 1 ||
    year > 9999 ||
    month < 1 ||
    month > 12
  ) {
    fail("invalid_calendar", MESSAGES.calendar);
  }
  const asOf = must(
    parseInstant(asOfText, true),
    "invalid_calendar",
    MESSAGES.calendar,
  );
  const start = must(
    parseInstant(monthStartText, true),
    "invalid_calendar",
    MESSAGES.calendar,
  );
  const midnight = BigInt(utcDayMillis(year, month - 1, 1)) * 1000n;
  const offset = midnight - start;
  const maxOffset = MAX_OFFSET_MINUTES * MINUTE_MICROS;
  if (
    offset % MINUTE_MICROS !== 0n ||
    offset < -maxOffset ||
    offset > maxOffset
  ) {
    fail("invalid_calendar", MESSAGES.calendar);
  }
  if (asOf < start || asOf - start > MAX_CALENDAR_SPAN_MICROS)
    fail("invalid_calendar", MESSAGES.calendar);
  const nextMidnight = BigInt(utcDayMillis(year, month, 1)) * 1000n;
  const lowest = bigMax(-maxOffset, midnight - asOf);
  const highest = bigMin(maxOffset, nextMidnight - asOf - 1n);
  if (ceilDiv(lowest, MINUTE_MICROS) * MINUTE_MICROS > highest)
    fail("invalid_calendar", MESSAGES.calendar);
  return { asOf, start, year, month };
}

function contextTimes(calendar: unknown): CalendarTimes {
  if (!isObject(calendar)) fail("invalid_calendar", MESSAGES.calendar);
  return calendarTimes(
    calendar.asOf,
    calendar.monthStart,
    calendar.year,
    calendar.month,
  );
}

function normalizePlan(raw: unknown): NormalizedPlan {
  if (!isObject(raw)) fail("invalid_plan", MESSAGES.plan);
  const currency = raw.currency;
  if (!isCurrencyCode(currency)) fail("invalid_plan", MESSAGES.plan);
  const monthlyUnits = must(
    moneyUnits(raw.monthly_amount, currency, false),
    "invalid_plan",
    MESSAGES.plan,
  );
  if (raw.total_amount !== undefined && raw.total_amount !== null) {
    must(
      moneyUnits(raw.total_amount, currency, false),
      "invalid_plan",
      MESSAGES.plan,
    );
  }
  const totalCount = must(
    integerInRange(raw.total_count, 1, MAX_COUNT),
    "invalid_plan",
    MESSAGES.plan,
  );
  const paidCount = must(
    integerInRange(raw.paid_count, 0, MAX_COUNT),
    "invalid_plan",
    MESSAGES.plan,
  );
  const dueDay = must(
    integerInRange(raw.due_day, 1, 31),
    "invalid_plan",
    MESSAGES.plan,
  );
  const active = raw.active;
  if (typeof active !== "boolean" || paidCount > totalCount)
    fail("invalid_plan", MESSAGES.plan);
  for (const key of ["id", "name", "provider", "kind"]) {
    const value = raw[key];
    if (value !== undefined && value !== null && typeof value !== "string")
      fail("invalid_plan", MESSAGES.plan);
  }
  let nextDue: ScheduleDate | null = null;
  if (raw.next_due_date !== undefined && raw.next_due_date !== null) {
    const parsed = parseDateOnly(raw.next_due_date);
    // The database stores the clamped nominal day, so a mismatch means the row is malformed.
    if (
      parsed === null ||
      parsed.day !== Math.min(dueDay, daysInMonth(parsed.year, parsed.month))
    ) {
      fail("invalid_plan", MESSAGES.plan);
    }
    nextDue = parsed;
  }
  const remaining = totalCount - paidCount;
  if (remaining === 0 && (active || nextDue !== null))
    fail("invalid_plan", MESSAGES.plan);
  return {
    id: typeof raw.id === "string" ? raw.id : null,
    name: typeof raw.name === "string" ? raw.name : null,
    provider: typeof raw.provider === "string" ? raw.provider : null,
    kind: typeof raw.kind === "string" ? raw.kind : null,
    currency,
    monthlyUnits,
    dueDay,
    remaining,
    active,
    nextDue,
  };
}

function normalizeExpense(raw: unknown): {
  currency: string;
  units: bigint;
  spentAt: bigint;
} {
  if (!isObject(raw)) fail("invalid_expense", MESSAGES.expense);
  const currency = raw.currency;
  if (!isCurrencyCode(currency)) fail("invalid_expense", MESSAGES.expense);
  const units = must(
    moneyUnits(raw.amount, currency, false),
    "invalid_expense",
    MESSAGES.expense,
  );
  const spentText = raw.spent_at;
  if (typeof spentText !== "string") fail("invalid_expense", MESSAGES.expense);
  const spentAt = must(
    parseInstant(spentText, false),
    "invalid_expense",
    MESSAGES.expense,
  );
  return { currency, units, spentAt };
}

// Reserve unpaid slots from the earliest unpaid month through the current month, capped at
// the remaining count. Future-month plans reserve nothing. An unset schedule reserves one
// slot and is reported as provisional by the callers.
function reservedCount(plan: NormalizedPlan, times: CalendarTimes): number {
  if (plan.nextDue === null) return 1;
  const months =
    (times.year - plan.nextDue.year) * 12 +
    times.month -
    plan.nextDue.month +
    1;
  return Math.min(Math.max(months, 0), plan.remaining);
}

function parseBaseline(summary: unknown): Baseline {
  if (!isObject(summary)) fail("invalid_summary", MESSAGES.summary);
  const currency = summary.currency;
  const provisional = summary.provisional;
  if (!isCurrencyCode(currency) || typeof provisional !== "boolean")
    fail("invalid_summary", MESSAGES.summary);
  const safe = must(
    moneyUnits(summary.safe_to_spend_this_month, currency, true, false),
    "invalid_summary",
    MESSAGES.summary,
  );
  const installments = must(
    moneyUnits(summary.installments_due_this_month, currency, false, false),
    "invalid_summary",
    MESSAGES.summary,
  );
  must(
    moneyUnits(summary.monthly_income, currency, false),
    "invalid_summary",
    MESSAGES.summary,
  );
  must(
    moneyUnits(summary.spent_this_month, currency, false, false),
    "invalid_summary",
    MESSAGES.summary,
  );
  if (
    typeof summary.as_of !== "string" ||
    parseInstant(summary.as_of, true) === null
  ) {
    fail("invalid_summary", MESSAGES.summary);
  }
  if (
    typeof summary.month_start !== "string" ||
    parseInstant(summary.month_start, true) === null
  ) {
    fail("invalid_summary", MESSAGES.summary);
  }
  const year = must(
    integerInRange(summary.local_year, 1, 9999),
    "invalid_summary",
    MESSAGES.summary,
  );
  const month = must(
    integerInRange(summary.local_month, 1, 12),
    "invalid_summary",
    MESSAGES.summary,
  );
  return { currency, safe, installments, provisional, year, month };
}
