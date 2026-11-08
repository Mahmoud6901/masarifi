import { createIngestHandler, type IngestBackend, type RecordApplePayArgs } from "./handler.ts";
import { createClaudeSmsReader, groundSmsReading, numbersInText, prefilterSms, type SmsReading } from "./sms.ts";

const token = "a".repeat(48);
const instant = "2026-11-08T09:00:00Z";
// Synthetic messages in the shape Saudi banks send; digits are not real cards.
const RAJHI_ONLINE = "شراء انترنت بـ10 SR عبر1226;مدى-ابل باي من0298 لـHungerstation في 8/11/26 12:00";
const ENGLISH_POS = "Purchase of SAR 1,234.50 at JARIR BOOKSTORE with card ending 4421 on 08-11-2026";
const REFUND = "استرداد مبلغ 45.00 ر.س من NOON إلى بطاقة 7788";

function fakeBackend() {
  const records: RecordApplePayArgs[] = [];
  const implementation: IngestBackend = {
    async findProfileByTokenHash() {
      return { profile: { id: "user-1", ingest_token: token, currency: "SAR" } };
    },
    async recordApplePay(args) {
      records.push(args);
      return { result: { ok: true, duplicate: false, id: "e1", ...(args.p_kind === "refund" ? { matched: true } : {}) } };
    },
  };
  return { records, implementation };
}

function post(body: unknown): Request {
  return new Request("https://local.test/ingest", {
    method: "POST",
    headers: { "x-ingest-token": token, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

const reader = (reading: SmsReading) => {
  const calls: string[] = [];
  return { calls, read: async (text: string) => { calls.push(text); return reading; } };
};

Deno.test("prefilter skips OTPs and digit-free messages without a model call", () => {
  if (prefilterSms("مرحبا بك في البنك") !== "no_amount") throw new Error("digit-free message not skipped");
  if (prefilterSms("رمز التحقق 4821 لعملية شراء بمبلغ 10 SR") !== "otp") throw new Error("Arabic OTP not skipped");
  if (prefilterSms("Your OTP is 123456 for SAR 50.00") !== "otp") throw new Error("English OTP not skipped");
  if (prefilterSms(RAJHI_ONLINE) !== null) throw new Error("purchase was skipped");
});

Deno.test("numbers are read with grouping, decimals and Arabic-Indic digits", () => {
  const values = numbersInText("مبلغ ١٬٢٣٤٫٥٠ ريال و 1,000 و 7.5");
  for (const expected of [1234.5, 1000, 7.5]) {
    if (!values.includes(expected)) throw new Error(`missing ${expected} in ${values}`);
  }
});

Deno.test("grounding keeps only what the SMS says", () => {
  const ok = groundSmsReading(RAJHI_ONLINE, { kind: "purchase", amount: "10", currency: "SAR", merchant: "Hungerstation", last4: "1226", bank: "Al Rajhi" });
  if (!ok || ok.amount !== "10" || ok.last4 !== "1226" || ok.merchant !== "Hungerstation" || ok.currency !== "SAR") throw new Error(`bad grounding ${JSON.stringify(ok)}`);
  if (groundSmsReading(RAJHI_ONLINE, { kind: "purchase", amount: "15" }) !== null) throw new Error("invented amount accepted");
  const noCard = groundSmsReading(RAJHI_ONLINE, { kind: "purchase", amount: "10", last4: "9999", merchant: "HungerStation Ltd" });
  if (!noCard || noCard.last4 !== undefined || noCard.merchant !== "") throw new Error("invented card or merchant kept");
  const grouped = groundSmsReading(ENGLISH_POS, { kind: "purchase", amount: "1234.50", merchant: "JARIR BOOKSTORE", last4: "4421" });
  if (grouped?.amount !== "1234.50" || grouped.last4 !== "4421") throw new Error("grouped amount not grounded");
  if (groundSmsReading(REFUND, { kind: "ignore", reason: "promotion" }) !== null) throw new Error("ignore was grounded");
  if (groundSmsReading(RAJHI_ONLINE, { kind: "purchase", amount: "abc" }) !== null) throw new Error("non-numeric amount accepted");
});

Deno.test("Claude reader forces the report tool and parses its input", async () => {
  let sent: { url: string; headers: Record<string, string>; body: Record<string, unknown> } | null = null;
  const fetchImpl = (async (url: string, init: RequestInit) => {
    sent = { url, headers: init.headers as Record<string, string>, body: JSON.parse(init.body as string) };
    return new Response(JSON.stringify({
      content: [{ type: "tool_use", name: "report_sms", input: { kind: "purchase", amount: " 10 ", merchant: "Hungerstation", last4: "1226" } }],
    }), { status: 200 });
  }) as unknown as typeof fetch;
  const read = createClaudeSmsReader({ apiKey: "test-key", fetchImpl });
  const reading = await read(RAJHI_ONLINE, "AlRajhiBank");
  if (reading.kind !== "purchase" || reading.amount !== "10" || reading.last4 !== "1226") throw new Error(`bad reading ${JSON.stringify(reading)}`);
  const request = sent!;
  if (request.url !== "https://api.anthropic.com/v1/messages" || request.headers["x-api-key"] !== "test-key") throw new Error("wrong endpoint or key header");
  if (request.body.model !== "claude-haiku-5-5" || (request.body.tool_choice as { name?: string }).name !== "report_sms") throw new Error("tool not forced or wrong model");
  if (!String((request.body.messages as Array<{ content: string }>)[0].content).includes("AlRajhiBank")) throw new Error("sender not passed");

  const failing = createClaudeSmsReader({ apiKey: "k", fetchImpl: (async () => new Response("{}", { status: 529 })) as unknown as typeof fetch });
  let threw = false;
  try { await failing("x 1", ""); } catch { threw = true; }
  if (!threw) throw new Error("HTTP failure did not throw");
  const garbage = createClaudeSmsReader({ apiKey: "k", fetchImpl: (async () => new Response(JSON.stringify({ content: [{ type: "text" }] }), { status: 200 })) as unknown as typeof fetch });
  threw = false;
  try { await garbage("x 1", ""); } catch { threw = true; }
  if (!threw) throw new Error("missing tool output did not throw");
});

Deno.test("SMS purchase is captured with card digits and bank", async () => {
  const fake = fakeBackend();
  const sms = reader({ kind: "purchase", amount: "10", currency: "SAR", merchant: "Hungerstation", last4: "1226", bank: "Al Rajhi" });
  const handler = createIngestHandler({ backend: fake.implementation, readSms: sms.read });
  // The Shortcut sends empty Wallet fields when a message triggered it.
  const response = await handler(post({ amount: "", merchant: "", text: RAJHI_ONLINE, sender: "AlRajhiBank", time: instant }));
  const reply = await response.json();
  const record = fake.records[0];
  if (response.status !== 200 || reply.kind !== "purchase" || reply.id !== "e1") throw new Error(`bad reply ${JSON.stringify(reply)}`);
  if (record.p_source !== "sms" || record.p_kind !== "purchase" || record.p_amount !== 10 || record.p_last4 !== "1226"
      || record.p_bank !== "Al Rajhi" || record.p_merchant !== "Hungerstation" || record.p_spent_at !== instant || record.p_wallet_name !== null) {
    throw new Error(`bad args ${JSON.stringify(record)}`);
  }
});

Deno.test("SMS refund is sent as a refund without a category", async () => {
  const fake = fakeBackend();
  const sms = reader({ kind: "refund", amount: "45.00", currency: "SAR", merchant: "NOON", last4: "7788" });
  const response = await createIngestHandler({ backend: fake.implementation, readSms: sms.read })(post({ text: REFUND, time: instant }));
  const reply = await response.json();
  if (response.status !== 200 || reply.kind !== "refund" || reply.matched !== true) throw new Error(`bad reply ${JSON.stringify(reply)}`);
  if (fake.records[0].p_kind !== "refund" || fake.records[0].p_category !== null || fake.records[0].p_amount !== 45) throw new Error("bad refund args");
});

Deno.test("ignored, unverifiable and OTP messages write nothing", async () => {
  const fake = fakeBackend();
  const ignore = reader({ kind: "ignore", reason: "declined" });
  let reply = await (await createIngestHandler({ backend: fake.implementation, readSms: ignore.read })(post({ text: "عملية مرفوضة بمبلغ 10 SR", time: instant }))).json();
  if (reply.ignored !== "declined") throw new Error("declined not ignored");
  const invented = reader({ kind: "purchase", amount: "99", merchant: "X" });
  reply = await (await createIngestHandler({ backend: fake.implementation, readSms: invented.read })(post({ text: RAJHI_ONLINE, time: instant }))).json();
  if (reply.ignored !== "amount_not_in_sms") throw new Error("invented amount not rejected");
  const otp = reader({ kind: "purchase", amount: "10" });
  reply = await (await createIngestHandler({ backend: fake.implementation, readSms: otp.read })(post({ text: "رمز التحقق 1234 لشراء 10 SR", time: instant }))).json();
  if (reply.ignored !== "otp" || otp.calls.length !== 0) throw new Error("OTP reached the model");
  if (fake.records.length !== 0) throw new Error("ignored message wrote a record");
});

Deno.test("SMS without a configured reader or with a failing reader reports it", async () => {
  const fake = fakeBackend();
  const none = await createIngestHandler({ backend: fake.implementation })(post({ text: RAJHI_ONLINE, time: instant }));
  if (none.status !== 503 || (await none.json()).error !== "sms_reader_unavailable") throw new Error("missing reader not reported");
  const broken = await createIngestHandler({ backend: fake.implementation, readSms: async () => { throw new Error("boom"); } })(post({ text: RAJHI_ONLINE, time: instant }));
  if (broken.status !== 502) throw new Error("reader failure not reported");
  const longText = await createIngestHandler({ backend: fake.implementation, readSms: async () => ({ kind: "ignore" }) })(post({ text: "1".repeat(1501), time: instant }));
  if (longText.status !== 400 || (await longText.json()).field !== "text") throw new Error("oversized SMS not rejected");
  if (fake.records.length !== 0) throw new Error("failed SMS wrote a record");
});

Deno.test("Wallet tap sends the card name and wins over the SMS path", async () => {
  const fake = fakeBackend();
  const sms = reader({ kind: "purchase", amount: "1" });
  const response = await createIngestHandler({ backend: fake.implementation, readSms: sms.read })(post({
    amount: "⃁ 25.50", merchant: "Starbucks", card: "  AlRajhi mada-Visa Classic ", text: "Starbucks 25.50", time: instant,
  }));
  if (response.status !== 200 || sms.calls.length !== 0) throw new Error("Wallet payload went to the SMS reader");
  const record = fake.records[0];
  if (record.p_source !== "apple_pay" || record.p_wallet_name !== "AlRajhi mada-Visa Classic" || record.p_amount !== 25.5 || record.p_last4 !== null) {
    throw new Error(`bad wallet args ${JSON.stringify(record)}`);
  }
});

Deno.test("GET /shortcut hands out only a valid iCloud Shortcut link", async () => {
  const fake = fakeBackend();
  const link = "https://www.icloud.com/shortcuts/" + "0123456789abcdef".repeat(2);
  const get = (path: string) => new Request(`https://local.test/ingest${path}`, { method: "GET" });
  const ok = await createIngestHandler({ backend: fake.implementation, shortcutUrl: ` ${link} ` })(get("/shortcut"));
  const body = await ok.json();
  if (ok.status !== 200 || body.url !== link) throw new Error(`Expected the link, got ${ok.status} ${JSON.stringify(body)}`);
  const missing = await createIngestHandler({ backend: fake.implementation })(get("/shortcut"));
  if (missing.status !== 404) throw new Error("Unset link must be 404");
  const evil = await createIngestHandler({ backend: fake.implementation, shortcutUrl: "https://evil.example/shortcuts/x" })(get("/shortcut"));
  if (evil.status !== 404) throw new Error("Non-iCloud link must never be served");
  const other = await createIngestHandler({ backend: fake.implementation, shortcutUrl: link })(get(""));
  if (other.status !== 405) throw new Error("Other GETs stay 405");
  if (fake.records.length !== 0) throw new Error("GET must never write");
});

Deno.test("a Wallet Dictionary forwarded as text is saved as an Apple Pay payment", async () => {
  for (const text of [
    { Amount: "⃁10.50", Merchant: "HungerStation", Card: "Cashback Signature" },
    JSON.stringify({ amount: "SAR 10.50", merchant: "HungerStation", card: "Cashback Signature" }),
  ]) {
    const fake = fakeBackend();
    const sms = reader({ kind: "ignore" });
    const response = await createIngestHandler({ backend: fake.implementation, readSms: sms.read })(post({ text, time: instant }));
    const record = fake.records[0];
    if (response.status !== 200 || !record) throw new Error(`Expected a save, got ${response.status}`);
    if (record.p_source !== "apple_pay" || record.p_amount !== 10.5 || record.p_merchant !== "HungerStation") throw new Error(JSON.stringify(record));
    if (record.p_wallet_name !== "Cashback Signature") throw new Error("Card name lost");
    if (sms.calls.length !== 0) throw new Error("A Wallet dictionary must never reach the SMS reader");
  }
  const fake = fakeBackend();
  const sms = reader({ kind: "ignore" });
  await createIngestHandler({ backend: fake.implementation, readSms: sms.read })(post({ text: "{not json شراء 10 SR", time: instant }));
  if (sms.calls.length !== 1) throw new Error("Brace-led SMS text must still be read as SMS");
});
