// Receives Apple Pay payments from an iOS Shortcuts automation.
// POST { amount, merchant, time? } with x-ingest-token: <personal token>.
import { createHash, timingSafeEqual } from "node:crypto";

export const TOKEN_PATTERN = /^[a-f0-9]{48}$/;
export const MAX_AMOUNT = 99_999_999_999.999;
const DUMMY_TOKEN = "0".repeat(48);

export type ExpenseCategory =
  | "food"
  | "groceries"
  | "transport"
  | "health"
  | "bills"
  | "shopping"
  | "entertainment"
  | "other";

// Keep classification rules in one ordered table: the first matching rule wins.
const CATEGORY_RULES: ReadonlyArray<readonly [RegExp, ExpenseCategory]> = [
  [/restaurant|cafe|coffee|starbucks|kudu|albaik|baik|mcdonald|kfc|burger|pizza|مطعم|كافيه|قهوة|البيك|كودو/i, "food"],
  [/panda|tamimi|carrefour|lulu|danube|othaim|nesto|supermarket|grocer|بنده|التميمي|كارفور|لولو|الدانوب|العثيم/i, "groceries"],
  [/uber|careem|bolt|taxi|petrol|aramco|adnoc|enoc|fuel|station|اوبر|كريم|محطة/i, "transport"],
  [/pharmacy|clinic|hospital|nahdi|dawaa|صيدلية|النهدي|الدواء|مستشفى/i, "health"],
  [/(?:\bstc\b)|mobily|zain|(?:\bdu\b)|etisalat|electric|water|اتصالات|موبايلي|زين/i, "bills"],
  [/amazon|noon|shein|ikea|extra|jarir|mall|امازون|نون|جرير|اكسترا/i, "shopping"],
  [/netflix|spotify|cinema|vox|muvi|shahid|سينما|شاهد/i, "entertainment"],
];

export function categorize(merchant: string): ExpenseCategory {
  for (const [pattern, category] of CATEGORY_RULES) {
    if (pattern.test(merchant)) return category;
  }
  return "other";
}

function decimalPlaces(value: number): number {
  const [mantissa, exponentText] = value.toString().toLowerCase().split("e");
  const exponent = exponentText === undefined ? 0 : Number(exponentText);
  return Math.max(0, (mantissa.split(".")[1]?.length ?? 0) - exponent);
}

function validAmount(value: number, currency: string): boolean {
  return Number.isFinite(value) && value >= 0 && value <= MAX_AMOUNT && decimalPlaces(value) <= minorUnits(currency);
}

// ⃁ is the Saudi Riyal sign (Unicode 17); iOS Wallet amounts use it.
const CURRENCY_WRAPPER = /SAR|SR|USD|EUR|GBP|AED|KWD|BHD|QAR|OMR|ر\.س\.?|د\.إ\.?|ر\.ق\.?|د\.ك\.?|د\.ب\.?|ر\.ع\.?|ريال(?:\s+سعودي)?|[$€£⃁]/;
const CURRENCY_PREFIX = new RegExp(`^(${CURRENCY_WRAPPER.source})\\s*`, "i");
const CURRENCY_SUFFIX = new RegExp(`\\s*(${CURRENCY_WRAPPER.source})$`, "i");
const WRAPPER_CURRENCY_CODES: Record<string, string> = {
  SAR: "SAR", SR: "SAR", رس: "SAR", ريال: "SAR", ريالسعودي: "SAR",
  AED: "AED", دإ: "AED",
  QAR: "QAR", رق: "QAR",
  KWD: "KWD", دك: "KWD",
  BHD: "BHD", دب: "BHD",
  OMR: "OMR", رع: "OMR", "⃁": "SAR",
  USD: "USD", "$": "USD", EUR: "EUR", "€": "EUR", GBP: "GBP", "£": "GBP",
};

function minorUnits(currency: string): number {
  return /^(?:KWD|BHD|OMR)$/i.test(currency) ? 3 : 2;
}

function normalizeCurrency(value: unknown): string | null {
  if (typeof value !== "string" || !/^[A-Za-z]{3}$/.test(value.trim())) return null;
  return value.trim().toUpperCase();
}

function wrapperCurrency(value: string | undefined): string | null {
  if (!value) return null;
  const key = value.replace(/[.\s]/g, "").toUpperCase();
  return WRAPPER_CURRENCY_CODES[key] ?? null;
}

function normalizeAmountDigits(raw: string): string {
  return raw
    .replace(/[٠-٩]/g, (digit) => String(digit.charCodeAt(0) - 0x0660))
    .replace(/[۰-۹]/g, (digit) => String(digit.charCodeAt(0) - 0x06f0))
    .replace(/٫/g, ".")
    .replace(/٬/g, ",")
    .replace(/[\u200e\u200f\u061c\u202a-\u202e\u2066-\u2069]/g, "")
    .trim();
}

function parseLocalizedNumber(input: string, fractionDigits: number, commaIsGrouping: boolean, dotIsDecimal: boolean): number | null {
  // French formats use a narrow or nonbreaking space for grouping. Remove
  // spaces only after checking complete three-digit groups, never arbitrarily.
  if (/[ \u00a0\u202f]/.test(input)) {
    const spaced = /^([1-9]\d{0,2}(?:[ \u00a0\u202f]\d{3})+)(?:([.,])(\d+))?$/.exec(input);
    if (!spaced) return null;
    input = spaced[1].replace(/[ \u00a0\u202f]/g, "") + (spaced[2] ? `${spaced[2]}${spaced[3]}` : "");
  }
  if (input.startsWith(".")) input = `0${input}`;
  // Grouping and decimal marks must form a complete, conventional number.
  if (!/^(?:\d+|\d[\d.,]*\d|\d)(?:[.,]\d+)?$/.test(input)) return null;
  if (!/^\d/.test(input)) return null;

  const dots = [...input.matchAll(/\./g)].length;
  const commas = [...input.matchAll(/,/g)].length;
  let integerPart = input;
  let fraction = "";

  if (dots && commas) {
    const decimalMark = input.lastIndexOf(".") > input.lastIndexOf(",") ? "." : ",";
    if ((commaIsGrouping || dotIsDecimal) && decimalMark !== ".") return null;
    const groupingMark = decimalMark === "." ? "," : ".";
    if (input.split(decimalMark).length !== 2) return null;
    [integerPart, fraction] = input.split(decimalMark);
    if (fraction.length < 1 || !/^\d+$/.test(fraction)) return null;
    const groups = integerPart.split(groupingMark);
    if (groups.length < 2 || !/^[1-9]\d{0,2}$/.test(groups[0]) || groups.slice(1).some((g) => !/^\d{3}$/.test(g))) return null;
    integerPart = groups.join("");
  } else {
    const mark = dots ? "." : commas ? "," : null;
    if (mark) {
      const pieces = input.split(mark);
      if (pieces.length === 2) {
        const [whole, tail] = pieces;
        if (tail.length >= 1 && tail.length <= fractionDigits && !(mark === "," && commaIsGrouping)) {
          integerPart = whole;
          fraction = tail;
        } else if (mark === "," && tail.length === 3 && /^[1-9]\d{0,2}$/.test(whole) && (commaIsGrouping || fractionDigits !== 3)) {
          integerPart = whole + tail;
        } else {
          return null;
        }
      } else {
        if (mark === ".") return null;
        const groups = pieces;
        if (!/^[1-9]\d{0,2}$/.test(groups[0]) || groups.slice(1).some((g) => !/^\d{3}$/.test(g))) return null;
        integerPart = groups.join("");
      }
    }
  }

  if (fraction.length > fractionDigits) return null;
  if (!/^\d+$/.test(integerPart)) return null;
  const canonical = fraction ? `${integerPart}.${fraction}` : integerPart;
  const amount = Number(canonical);
  return Number.isFinite(amount) ? amount : null;
}

export function parsePaymentAmount(raw: unknown, defaultCurrency = "SAR", explicitCurrency?: unknown): { amount: number; currency: string } | null {
  const fallbackCurrency = normalizeCurrency(defaultCurrency);
  const suppliedCurrency = explicitCurrency === undefined ? null : normalizeCurrency(explicitCurrency);
  if (!fallbackCurrency || (explicitCurrency !== undefined && !suppliedCurrency)) return null;
  if (typeof raw === "number") {
    const currency = suppliedCurrency ?? fallbackCurrency;
    return validAmount(raw, currency) ? { amount: raw, currency } : null;
  }
  if (typeof raw !== "string") return null;
  let value = normalizeAmountDigits(raw);
  if (!value) return null;
  const prefix = CURRENCY_PREFIX.exec(value);
  if (prefix) value = value.slice(prefix[0].length);
  const suffix = CURRENCY_SUFFIX.exec(value);
  if (prefix && suffix) return null;
  if (suffix) value = value.slice(0, -suffix[0].length);
  const wrappedCurrency = wrapperCurrency(prefix?.[1] ?? suffix?.[1]);
  if ((prefix || suffix) && !wrappedCurrency) return null;
  if (wrappedCurrency && suppliedCurrency && wrappedCurrency !== suppliedCurrency) return null;
  const currency = wrappedCurrency ?? suppliedCurrency ?? fallbackCurrency;
  value = value.trim();
  if (!value || /[-+eE]/.test(value)) return null;
  const amount = parseLocalizedNumber(value, minorUnits(currency), raw.includes("٬"), raw.includes("٫"));
  return amount !== null && validAmount(amount, currency) ? { amount, currency } : null;
}

export function parseAmount(raw: unknown, defaultCurrency = "SAR"): number | null {
  return parsePaymentAmount(raw, defaultCurrency)?.amount ?? null;
}

function parseEventTime(value: unknown, now: () => Date): string | null {
  if (value === undefined) {
    const current = now();
    return Number.isNaN(current.getTime()) ? null : current.toISOString();
  }
  if (typeof value !== "string") return null;
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?(Z|[+-](?:0\d|1[0-5]):[0-5]\d)$/.exec(value);
  if (!match) return null;
  const [, yearText, monthText, dayText, hourText, minuteText, secondText] = match;
  const year = Number(yearText);
  const month = Number(monthText);
  const day = Number(dayText);
  const hour = Number(hourText);
  const minute = Number(minuteText);
  const second = Number(secondText);
  const leapYear = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const monthDays = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (year < 1 || month < 1 || month > 12 || day < 1 || day > monthDays[month - 1] || hour > 23 || minute > 59 || second > 59) return null;
  const timestamp = Date.parse(value);
  return Number.isNaN(timestamp) ? null : value;
}

export interface IngestProfile {
  id: string;
  ingest_token: string;
  currency: string;
}

export interface RecordApplePayArgs {
  p_user_id: string;
  p_token_hash: string;
  p_amount: number;
  p_merchant: string;
  p_spent_at: string;
  p_category: ExpenseCategory;
  p_currency: string;
}

export interface IngestBackend {
  findProfileByTokenHash(hash: string): Promise<{ profile: IngestProfile | null; error?: unknown }>;
  recordApplePay(args: RecordApplePayArgs): Promise<{ result: unknown; error?: unknown }>;
}

export interface HandlerOptions {
  backend: IngestBackend;
  now?: () => Date;
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

function tokenDigest(token: string): string {
  return createHash("sha256").update(token, "utf8").digest("hex");
}

function safeTokenMatch(candidate: string, stored: string): boolean {
  const candidateBytes = new TextEncoder().encode(candidate);
  const storedBytes = new TextEncoder().encode(stored);
  // Both values are format checked to be 48 ASCII bytes before reaching this primitive.
  return candidateBytes.byteLength === storedBytes.byteLength && timingSafeEqual(candidateBytes, storedBytes);
}

function errorCode(error: unknown): string | undefined {
  if (typeof error !== "object" || error === null || !("code" in error)) return undefined;
  const code = (error as { code?: unknown }).code;
  return typeof code === "string" ? code : undefined;
}

function validPayload(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function createIngestHandler({ backend, now = () => new Date() }: HandlerOptions) {
  return async (request: Request): Promise<Response> => {
    if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

    const token = request.headers.get("x-ingest-token");
    if (token === null || !TOKEN_PATTERN.test(token)) return json({ error: "invalid_token" }, 401);

    let profile: IngestProfile | null;
    try {
      const found = await backend.findProfileByTokenHash(tokenDigest(token));
      if (found.error) return json({ error: "internal_error" }, 500);
      profile = found.profile;
    } catch {
      return json({ error: "internal_error" }, 500);
    }

    const storedToken = profile?.ingest_token;
    const storedTokenValid = typeof storedToken === "string" && TOKEN_PATTERN.test(storedToken);
    const comparisonToken = storedTokenValid ? storedToken : DUMMY_TOKEN;
    const tokenMatches = safeTokenMatch(token, comparisonToken);
    if (!profile || !storedTokenValid || !tokenMatches) return json({ error: "invalid_token" }, 401);

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return json({ error: "invalid_json" }, 400);
    }
    if (!validPayload(body)) return json({ error: "invalid_payload" }, 400);

    // Name the failing field so a Shortcut's notification says what to fix.
    // Logs carry only the field and the value's shape (digits masked as 9),
    // never the amount, merchant or token.
    const reject = (field: string, value: unknown) => {
      const shape = typeof value === "string"
        ? value.replace(/[0-9٠-٩۰-۹]/g, "9").slice(0, 40)
          // Escape non-ASCII so log viewers cannot hide symbols like U+20C1.
          .replace(/[^\x20-\x7e]/g, (ch) => `\\u${ch.charCodeAt(0).toString(16).padStart(4, "0")}`)
        : typeof value;
      console.warn(JSON.stringify({ ingest_rejected: field, shape }));
      return json({ error: "invalid_payload", field }, 400);
    };
    const payment = parsePaymentAmount(body.amount, profile.currency, body.currency);
    if (payment === null) return reject("amount", body.amount);
    const merchant = typeof body.merchant === "string" ? body.merchant.trim() : "";
    if (!merchant || [...merchant].length > 200) return reject("merchant", typeof body.merchant);
    const spentAt = parseEventTime(body.time, now);
    if (!spentAt) return reject("time", body.time);

    const args: RecordApplePayArgs = {
      p_user_id: profile.id,
      p_token_hash: tokenDigest(token),
      p_amount: payment.amount,
      p_merchant: merchant,
      p_spent_at: spentAt,
      p_category: categorize(merchant),
      p_currency: payment.currency,
    };

    try {
      const recorded = await backend.recordApplePay(args);
      if (recorded.error) {
        const code = errorCode(recorded.error);
        if (code === "28000") return json({ error: "invalid_token" }, 401);
        if (code === "22023" || code === "22003") return json({ error: "invalid_payload" }, 400);
        return json({ error: "internal_error" }, 500);
      }
      if (typeof recorded.result !== "object" || recorded.result === null) return json({ error: "internal_error" }, 500);
      const result = recorded.result as { ok?: unknown; duplicate?: unknown; id?: unknown };
      if (result.ok !== true || typeof result.duplicate !== "boolean") return json({ error: "internal_error" }, 500);
      return json({ ok: true, duplicate: result.duplicate, ...(typeof result.id === "string" ? { id: result.id } : {}) });
    } catch {
      return json({ error: "internal_error" }, 500);
    }
  };
}

