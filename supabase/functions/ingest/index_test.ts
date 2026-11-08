import {
  categorize,
  createIngestHandler,
  parseAmount,
  parsePaymentAmount,
  type IngestBackend,
  type RecordApplePayArgs,
} from "./handler.ts";

const token = "a".repeat(48);
const otherToken = "b".repeat(48);
const instant = "2026-01-02T03:04:05.123Z";

function backend(overrides: Partial<IngestBackend> = {}) {
  const calls: { lookup: string[]; records: RecordApplePayArgs[] } = { lookup: [], records: [] };
  const implementation: IngestBackend = {
    async findProfileByTokenHash(hash) {
      calls.lookup.push(hash);
      return { profile: { id: "user-1", ingest_token: token, currency: "SAR" } };
    },
    async recordApplePay(args) {
      calls.records.push(args);
      return { result: { ok: true, duplicate: false, id: "expense-1" } };
    },
    ...overrides,
  };
  return { calls, implementation };
}

function request(body: unknown, method = "POST", authToken = token): Request {
  return new Request("https://local.test/ingest", {
    method,
    headers: authToken === "" ? {} : { "x-ingest-token": authToken, "content-type": "application/json" },
    body: method === "POST" ? JSON.stringify(body) : undefined,
  });
}

async function status(handler: (request: Request) => Promise<Response>, req: Request): Promise<number> {
  return (await handler(req)).status;
}

Deno.test("amount parsing accepts decimal and known currency formats", () => {
  for (const [raw, expected] of [
    [12.5, 12.5],
    ["SAR 1,234.50", 1234.5],
    ["1.234,50 EUR", 1234.5],
    ["25,50", 25.5],
    ["١٬٢٣٤٫٥٠ ر.س", 1234.5],
    ["۱۲٫۷۵", 12.75],
    [".50", 0.5],
    [99999999999.99, 99999999999.99],
    [67108864.01, 67108864.01],
  ] as const) {
    if (parseAmount(raw) !== expected) throw new Error(`Unexpected parse for ${String(raw)}`);
  }
});

Deno.test("amount parsing rejects signs, garbage, precision loss, and out-of-range values", () => {
  for (const raw of [-1, "-5", "+5", 1.0000000000000004, "paid SAR 5", "5 USD extra", "SAR 25 USD", "1,23,4", "1٬2", "1.234", "0.001", "100000000000", Infinity, NaN, null, {}]) {
    if (parseAmount(raw) !== null) throw new Error(`Accepted invalid amount: ${String(raw)}`);
  }
});

Deno.test("three-decimal currency commas mean decimal fils, and genuine fils are retained", () => {
  for (const currency of ["KWD", "BHD", "OMR"]) {
    for (const [number, expected] of [["25,000", 25], ["1,250", 1.25], ["0,000", 0], ["1,255", 1.255]] as const) {
      for (const raw of [`${currency} ${number}`, `${number} ${currency}`]) {
        if (parseAmount(raw) !== expected) throw new Error(`Incorrect amount for ${raw}: ${parseAmount(raw)}`);
      }
    }
    for (const raw of [`${currency} 1.2500`]) {
      if (parseAmount(raw) !== null) throw new Error(`Rounded or regrouped unsupported precision: ${raw}`);
    }
  }
  if (parseAmount("1.234") !== null || parseAmount("1,234.500") !== null || parseAmount("SAR 1,234.500") !== null) {
    throw new Error("Default SAR accepted unsupported third decimal");
  }
  const defaultKwd = parsePaymentAmount("25,000", "KWD");
  if (defaultKwd?.amount !== 25 || defaultKwd.currency !== "KWD") throw new Error("Default KWD did not parse bare comma as decimal");
  if (parsePaymentAmount("١٬٢٣٤", "OMR")?.amount !== 1234) throw new Error("Explicit Arabic grouping was not preserved");
});

Deno.test("all offered Gulf currencies accept English and Arabic symbols with exact storage precision", () => {
  for (const [currency, symbol, threeDecimals] of [
    ["SAR", "ر.س", false], ["AED", "د.إ", false], ["QAR", "ر.ق", false],
    ["KWD", "د.ك", true], ["BHD", "د.ب", true], ["OMR", "ر.ع", true],
  ] as const) {
    const fraction = threeDecimals ? "500" : "50";
    for (const [raw, expected] of [
      [`${currency} 1,234.${fraction}`, 1234.5],
      [`1.234,${fraction} ${currency}`, 1234.5],
      [`\u200f١٬٢٣٤٫٥٠${threeDecimals ? "٠" : ""} ${symbol}.\u200f`, 1234.5],
      [`\u061c${symbol} ٥٫٠٠${threeDecimals ? "٠" : ""}\u200f`, 5],
    ] as const) {
      if (parseAmount(raw) !== expected) throw new Error(`Unsupported currency format: ${raw}`);
    }
    if (threeDecimals) {
      for (const [raw, expected] of [[`١٫٢٥٥ ${symbol}.`, 1.255], [`${symbol} ١,٢٥٥`, 1.255]] as const) {
        if (parseAmount(raw) !== expected) throw new Error(`Rejected valid fils amount: ${raw}`);
      }
    }
  }
});

Deno.test("representable Intl Gulf currency formats parse exactly across common locales", () => {
  // CLDR output is a local formatting proxy; this is not a device Shortcut test.
  for (const currency of ["SAR", "AED", "QAR", "KWD", "BHD", "OMR"]) {
    for (const locale of ["en-US", "en-GB", "ar-SA", "ar-AE", "ar-QA", "ar-KW", "ar-BH", "ar-OM", "de-DE", "fr-FR"]) {
      const formatter = new Intl.NumberFormat(locale, { style: "currency", currency });
      for (const value of [5, 25, 1.25, 1234.5]) {
        const raw = formatter.format(value);
        if (parseAmount(raw) !== value) throw new Error(`Wrong ${locale}/${currency} parse: ${raw} -> ${parseAmount(raw)}, expected ${value}`);
      }
    }
  }
});

Deno.test("handler persists exact fils values and rejects SAR overprecision", async () => {
  const fake = backend();
  const handler = createIngestHandler({ backend: fake.implementation });
  for (const [amount, expectedCurrency] of [["25,000 KWD", "KWD"], ["BHD 1,255", "BHD"], ["١٫٢٥٥ ر.ع.", "OMR"]] as const) {
    const response = await handler(request({ amount, merchant: "Shop" }));
    const expected = amount.startsWith("25") ? 25 : 1.255;
    const stored = fake.calls.records.at(-1);
    if (response.status !== 200 || stored?.p_amount !== expected || stored.p_currency !== expectedCurrency) throw new Error(`Wrong stored amount or currency: ${amount}`);
  }
  const recorded = fake.calls.records.length;
  for (const amount of ["SAR 1,234.500", "1,234.500"]) {
    if (await status(handler, request({ amount, merchant: "Shop" })) !== 400) throw new Error(`Expected invalid precision 400: ${amount}`);
  }
  if (fake.calls.records.length !== recorded) throw new Error("Invalid precision wrote a record");
});

Deno.test("handler stores Wallet Riyal-sign amounts and names the failing field", async () => {
  const fake = backend();
  const handler = createIngestHandler({ backend: fake.implementation });
  const ok = await handler(request({ amount: "⃁ 10.00", merchant: "HungerStation" }));
  const stored = fake.calls.records.at(-1);
  if (ok.status !== 200 || stored?.p_amount !== 10 || stored.p_currency !== "SAR") throw new Error("Riyal-sign amount was not stored as 10 SAR");
  const recorded = fake.calls.records.length;
  const warn = console.warn;
  console.warn = () => {};
  try {
    for (const [body, field] of [
      [{ amount: "ten", merchant: "Shop" }, "amount"],
      [{ amount: 1, merchant: "  " }, "merchant"],
      [{ amount: 1, merchant: "Shop", time: "8 Nov 2026" }, "time"],
    ] as const) {
      const response = await handler(request(body));
      const reply = await response.json();
      if (response.status !== 400 || reply.error !== "invalid_payload" || reply.field !== field) throw new Error(`Expected 400 naming ${field}`);
    }
  } finally {
    console.warn = warn;
  }
  if (fake.calls.records.length !== recorded) throw new Error("Rejected payload wrote a record");
});

Deno.test("category rules keep deterministic English, Arabic, and fallback matches", () => {
  const checks: [string, string][] = [
    ["Kudu Cafe", "food"],
    ["مشتريات البيك", "food"],
    ["Tamimi Market", "groceries"],
    ["صيدلية النهدي", "health"],
    ["Uber", "transport"],
    ["Netflix", "entertainment"],
    ["Corner Shop", "other"],
  ];
  for (const [merchant, expected] of checks) {
    if (categorize(merchant) !== expected) throw new Error(`Wrong category for ${merchant}`);
  }
});

Deno.test("handler returns 405 and rejects missing, malformed, unmatched, and mismatched tokens", async () => {
  const fake = backend();
  const handler = createIngestHandler({ backend: fake.implementation });
  if (await status(handler, request({}, "GET")) !== 405) throw new Error("Expected 405");
  if (await status(handler, request({}, "POST", "")) !== 401) throw new Error("Expected missing token 401");
  if (await status(handler, request({}, "POST", "too-short")) !== 401) throw new Error("Expected malformed token 401");

  const unmatched = backend({ async findProfileByTokenHash() { return { profile: null }; } });
  if (await status(createIngestHandler({ backend: unmatched.implementation }), request({})) !== 401) throw new Error("Expected unmatched token 401");
  if (unmatched.calls.records.length !== 0) throw new Error("Unmatched token wrote a record");

  const mismatched = backend({ async findProfileByTokenHash() { return { profile: { id: "user-1", ingest_token: otherToken, currency: "SAR" } }; } });
  if (await status(createIngestHandler({ backend: mismatched.implementation }), request({})) !== 401) throw new Error("Expected mismatch 401");
  if (mismatched.calls.records.length !== 0) throw new Error("Mismatched token wrote a record");

  const malformedStored = backend({ async findProfileByTokenHash() { return { profile: { id: "user-1", ingest_token: "bad", currency: "SAR" } }; } });
  if (await status(createIngestHandler({ backend: malformedStored.implementation }), request({}, "POST", "0".repeat(48))) !== 401) throw new Error("Malformed stored token authenticated through dummy compare");
});

Deno.test("lookup failure is sanitized as 500", async () => {
  const fake = backend({ async findProfileByTokenHash() { return { profile: null, error: new Error("raw backend detail") }; } });
  const response = await createIngestHandler({ backend: fake.implementation })(request({ amount: 1, merchant: "Shop" }));
  if (response.status !== 500 || (await response.text()).includes("raw backend detail")) throw new Error("Lookup error was not sanitized");
});

Deno.test("handler validates JSON shape, amount, merchant, and ISO timestamp", async () => {
  const fake = backend();
  const handler = createIngestHandler({ backend: fake.implementation, now: () => new Date(instant) });
  const invalidBodies = [null, [], { amount: "-5", merchant: "Shop" }, { amount: 1, merchant: { name: "Shop" } },
    { amount: 1, merchant: "  " }, { amount: 1, merchant: "x".repeat(201) },
    { amount: 1, merchant: "Shop", time: "2026-02-30T12:00:00Z" },
    { amount: 1, merchant: "Shop", time: "2026-01-01T12:00:00" },
    { amount: 1, merchant: "Shop", time: "0000-01-01T12:00:00Z" },
    { amount: 1, merchant: "Shop", time: "2026-01-01T12:00:00+16:00" },
    { amount: 1, merchant: "Shop", time: "2026-01-01T12:00:00.1234567Z" },
    { amount: 1, merchant: "Shop", time: 42 }];
  for (const body of invalidBodies) {
    if (await status(handler, request(body)) !== 400) throw new Error(`Expected 400 for ${JSON.stringify(body)}`);
  }
  if (fake.calls.records.length !== 0) throw new Error("Invalid payload wrote a record");

  const malformed = await handler(new Request("https://local.test/ingest", {
    method: "POST", headers: { "x-ingest-token": token, "content-type": "application/json" }, body: "{",
  }));
  if (malformed.status !== 400) throw new Error("Expected malformed JSON 400");
});

Deno.test("timestamp offsets and microsecond precision are preserved without using fallback time", async () => {
  const fake = backend();
  const handler = createIngestHandler({ backend: fake.implementation, now: () => { throw new Error("Unexpected clock use"); } });
  const time = "2024-02-29T12:30:00.123456+03:00";
  const response = await handler(request({ amount: 1, merchant: "Shop", time }));
  if (response.status !== 200 || fake.calls.records[0]?.p_spent_at !== time) throw new Error("Valid timestamp was not preserved");
});

Deno.test("thrown backend errors and malformed results fail without leaking details", async () => {
  for (const overrides of [
    { async findProfileByTokenHash() { throw new Error("private lookup detail"); } },
    { async recordApplePay() { throw new Error("private RPC detail"); } },
    { async recordApplePay() { return { result: null }; } },
    { async recordApplePay() { return { result: { ok: true, duplicate: "yes" } }; } },
  ]) {
    const fake = backend(overrides);
    const response = await createIngestHandler({ backend: fake.implementation })(request({ amount: 1, merchant: "Shop" }));
    const body = await response.text();
    if (response.status !== 500 || body.includes("private")) throw new Error("Failure was not sanitized");
  }
});

Deno.test("handler records trimmed merchant with token digest, category, and captured fallback time", async () => {
  const fake = backend();
  let clockCalls = 0;
  const handler = createIngestHandler({ backend: fake.implementation, now: () => { clockCalls++; return new Date(instant); } });
  const response = await handler(request({ amount: "SAR 25,50", merchant: "  Kudu Cafe  " }));
  const result = await response.json();
  const record = fake.calls.records[0];
  if (response.status !== 200 || result.duplicate !== false || result.id !== "expense-1") throw new Error("Unexpected record response");
  if (record.p_user_id !== "user-1" || record.p_merchant !== "Kudu Cafe" || record.p_amount !== 25.5 || record.p_category !== "food") throw new Error("Incorrect RPC arguments");
  if (record.p_spent_at !== instant || clockCalls !== 1) throw new Error("Fallback time was not captured once");
  if (!/^[a-f0-9]{64}$/.test(record.p_token_hash) || fake.calls.lookup[0] !== record.p_token_hash) throw new Error("Expected SHA-256 digest lookup and RPC argument");
  if (record.p_currency !== "SAR") throw new Error("Resolved profile currency was not sent to RPC");
});

Deno.test("currency wrappers, explicit currency, profile currency, and conflicts resolve consistently", async () => {
  for (const [raw, expected] of [
    ["ر.س 5", "SAR"], ["د.إ 5", "AED"], ["ر.ق 5", "QAR"],
    ["د.ك 1.255", "KWD"], ["د.ب 1.255", "BHD"], ["ر.ع 1.255", "OMR"],
    ["$5", "USD"], ["€5", "EUR"], ["£5", "GBP"], ["SR 5", "SAR"],
    ["⃁ 10.00", "SAR"], ["⃁10.00", "SAR"], ["10.00 ⃁", "SAR"], ["⃁ 10.00", "SAR"],
  ] as const) {
    const parsed = parsePaymentAmount(raw);
    if (parsed?.currency !== expected) throw new Error(`Wrong wrapper currency for ${raw}`);
  }
  // iOS Wallet writes Saudi amounts with the Riyal sign (U+20C1).
  if (parsePaymentAmount("⃁ 1,234.50", "SAR")?.amount !== 1234.5) throw new Error("Riyal sign amount not parsed");
  if (parsePaymentAmount("⃁ 10.00", "SAR", "AED") !== null) throw new Error("Riyal sign conflicting with explicit currency was accepted");
  const profileKwd = backend({ async findProfileByTokenHash() { return { profile: { id: "user-1", ingest_token: token, currency: "KWD" } }; } });
  const handler = createIngestHandler({ backend: profileKwd.implementation });
  const profileAmount = await handler(request({ amount: "1,255", merchant: "Shop" }));
  if (profileAmount.status !== 200 || profileKwd.calls.records[0]?.p_amount !== 1.255 || profileKwd.calls.records[0]?.p_currency !== "KWD") {
    throw new Error("Authenticated profile currency was not applied to bare input");
  }
  const explicitForeign = await handler(request({ amount: "USD 1.25", currency: "USD", merchant: "Shop" }));
  if (explicitForeign.status !== 200 || profileKwd.calls.records[1]?.p_currency !== "USD") throw new Error("Foreign explicit currency was not retained");
  const conflict = await handler(request({ amount: "KWD 1.255", currency: "BHD", merchant: "Shop" }));
  if (conflict.status !== 400 || profileKwd.calls.records.length !== 2) throw new Error("Wrapper/explicit conflict was not rejected");
});

Deno.test("duplicate RPC response is preserved and known SQL validation errors map to 400", async () => {
  const duplicate = backend({ async recordApplePay() { return { result: { ok: true, duplicate: true, id: "prior" } }; } });
  const response = await createIngestHandler({ backend: duplicate.implementation })(request({ amount: 1, merchant: "Shop", time: instant }));
  if (response.status !== 200 || (await response.json()).duplicate !== true) throw new Error("Duplicate was not returned");

  for (const code of ["22023", "22003"]) {
    const invalid = backend({ async recordApplePay() { return { result: null, error: { code, message: "private detail" } }; } });
    const failed = await createIngestHandler({ backend: invalid.implementation })(request({ amount: 1, merchant: "Shop" }));
    if (failed.status !== 400 || (await failed.text()).includes("private detail")) throw new Error(`SQLSTATE ${code} was not sanitized as 400`);
  }
});

Deno.test("revoked token and internal RPC failures are mapped without exposing backend errors", async () => {
  const revoked = backend({ async recordApplePay() { return { result: null, error: { code: "28000", message: "secret detail" } }; } });
  const denied = await createIngestHandler({ backend: revoked.implementation })(request({ amount: 1, merchant: "Shop" }));
  if (denied.status !== 401 || (await denied.text()).includes("secret detail")) throw new Error("Revoked token response was not sanitized");

  const failed = backend({ async recordApplePay() { return { result: null, error: { code: "XX000", message: "secret detail" } }; } });
  const response = await createIngestHandler({ backend: failed.implementation })(request({ amount: 1, merchant: "Shop" }));
  if (response.status !== 500 || (await response.text()).includes("secret detail")) throw new Error("RPC error was not sanitized");
});
