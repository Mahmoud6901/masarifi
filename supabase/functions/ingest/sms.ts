// Reads a bank SMS of any Saudi or Gulf bank, Arabic or English, into a
// payment. Claude extracts the fields; groundSmsReading() then keeps only
// values that literally appear in the SMS, so the model cannot invent an
// amount, card or merchant.

export type SmsKind = "purchase" | "refund" | "ignore";

export interface SmsReading {
  kind: SmsKind;
  amount?: string;
  currency?: string;
  merchant?: string;
  bank?: string;
  last4?: string;
  reason?: string;
}

export type SmsReader = (text: string, sender: string) => Promise<SmsReading>;

export const SMS_MAX_LENGTH = 1500;
export const SMS_MODEL = "claude-haiku-5-5";

// Verification-code messages are never payments; skip them without a model call.
const OTP_PATTERN = /رمز\s*(?:ال)?(?:تحقق|تفعيل|سري|مؤقت)|كلمة\s*المرور\s*المؤقتة|\bOTP\b|one[\s-]?time|verification\s*code|passcode|activation\s*code/i;

/** Cheap filter before any model call. Returns a reason to ignore, or null. */
export function prefilterSms(text: string): string | null {
  if (!/[0-9٠-٩۰-۹]/.test(text)) return "no_amount";
  if (OTP_PATTERN.test(text)) return "otp";
  return null;
}

const SYSTEM_PROMPT = `You read one bank SMS from a Saudi or Gulf bank (Arabic or English) and report it with the report_sms tool.

kind:
- "purchase": money was successfully paid from a card or account to a merchant or biller: card/POS purchase, online purchase, Apple Pay, mada, credit card purchase, SADAD or bill payment.
- "refund": money was returned for an earlier purchase: refund, reversal, استرداد, عكس عملية, إرجاع, مرتجع, credit back from a merchant.
- "ignore": anything else: OTP or verification codes, declined, failed or rejected transactions (مرفوضة, لم تتم, Declined), transfers to people or own accounts, ATM cash withdrawals, salary or deposits, balance alerts, installment or due-date reminders, promotions, card activation.

Fields (copy exactly as written in the SMS; never guess or translate):
- amount: the transaction amount as digits with "." for decimals, e.g. "10.00" or "1234.50". Not a fee, balance or limit. Convert Arabic-Indic digits to 0-9 and drop thousands separators.
- currency: ISO code. SR, SAR, ريال, ر.س and the Riyal sign mean SAR; also AED, KWD, BHD, QAR, OMR, USD, EUR, GBP.
- merchant: the merchant or biller name as written (after لدى, لـ, في, من متجر, at, from merchant). Empty if not shown.
- bank: the bank name if the SMS or sender names it, e.g. "Al Rajhi", "SAB", "Emirates NBD", "SNB", "Riyad Bank".
- last4: the last 4 digits of the CARD used, only when the SMS shows a card number (e.g. "بطاقة ***1226", "مدى 1226", "عبر1226", "card ending 1226"). Never an account number (often after "من حساب" or "من" for account), never an OTP or reference.
- reason: for "ignore", a short reason such as "otp", "declined", "transfer", "deposit", "promotion".`;

const TOOL = {
  name: "report_sms",
  description: "Report the classification and fields of the bank SMS.",
  input_schema: {
    type: "object",
    properties: {
      kind: { type: "string", enum: ["purchase", "refund", "ignore"] },
      amount: { type: "string" },
      currency: { type: "string" },
      merchant: { type: "string" },
      bank: { type: "string" },
      last4: { type: "string" },
      reason: { type: "string" },
    },
    required: ["kind"],
  },
};

export interface ClaudeSmsReaderOptions {
  apiKey: string;
  model?: string;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}

export function createClaudeSmsReader(options: ClaudeSmsReaderOptions): SmsReader {
  const fetchImpl = options.fetchImpl ?? fetch;
  return async (text, sender) => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), options.timeoutMs ?? 15_000);
    try {
      const response = await fetchImpl("https://api.anthropic.com/v1/messages", {
        method: "POST",
        signal: controller.signal,
        headers: {
          "content-type": "application/json",
          "x-api-key": options.apiKey,
          "anthropic-version": "2023-06-01",
        },
        body: JSON.stringify({
          model: options.model || SMS_MODEL,
          max_tokens: 300,
          system: SYSTEM_PROMPT,
          tools: [TOOL],
          tool_choice: { type: "tool", name: TOOL.name },
          messages: [{
            role: "user",
            content: `Sender: ${sender.slice(0, 60) || "unknown"}\nSMS:\n${text}`,
          }],
        }),
      });
      if (!response.ok) throw new Error(`sms_reader_http_${response.status}`);
      const payload = await response.json() as { content?: Array<{ type?: string; input?: unknown }> };
      const use = payload.content?.find((block) => block.type === "tool_use");
      const input = use?.input as Record<string, unknown> | undefined;
      if (!input || !["purchase", "refund", "ignore"].includes(input.kind as string)) {
        throw new Error("sms_reader_bad_output");
      }
      const str = (value: unknown) => typeof value === "string" && value.trim() ? value.trim() : undefined;
      return {
        kind: input.kind as SmsKind,
        amount: str(input.amount),
        currency: str(input.currency),
        merchant: str(input.merchant),
        bank: str(input.bank),
        last4: str(input.last4),
        reason: str(input.reason),
      };
    } finally {
      clearTimeout(timer);
    }
  };
}

function asciiDigits(value: string): string {
  return value
    .replace(/[٠-٩]/g, (d) => String(d.charCodeAt(0) - 0x0660))
    .replace(/[۰-۹]/g, (d) => String(d.charCodeAt(0) - 0x06f0))
    .replace(/٫/g, ".")
    .replace(/٬/g, ",");
}

/** Every number written in the SMS, with thousands separators removed. */
export function numbersInText(text: string): number[] {
  const normalized = asciiDigits(text);
  const out: number[] = [];
  for (const match of normalized.matchAll(/\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?/g)) {
    const value = Number(match[0].replace(/,/g, ""));
    if (Number.isFinite(value)) out.push(value);
  }
  return out;
}

export interface GroundedSms {
  kind: "purchase" | "refund";
  amount: string;
  currency?: string;
  merchant: string;
  bank?: string;
  last4?: string;
}

/**
 * Keeps only what the SMS really says. Returns null when the reading's amount
 * is not one of the numbers in the text (a model error or invention).
 */
export function groundSmsReading(text: string, reading: SmsReading): GroundedSms | null {
  if (reading.kind === "ignore" || !reading.amount) return null;
  const amountText = asciiDigits(reading.amount).replace(/,/g, "").trim();
  if (!/^\d+(?:\.\d{1,3})?$/.test(amountText)) return null;
  const amount = Number(amountText);
  if (!(amount > 0) || !numbersInText(text).includes(amount)) return null;

  const digits = asciiDigits(text);
  const cardDigits = reading.last4 ? asciiDigits(reading.last4) : "";
  const last4 = /^\d{4}$/.test(cardDigits) && digits.includes(cardDigits) ? cardDigits : undefined;
  const merchantRaw = reading.merchant?.replace(/\s+/g, " ").trim() ?? "";
  // A merchant name the SMS does not contain is dropped, not trusted.
  const merchant = merchantRaw && text.replace(/\s+/g, " ").toLowerCase().includes(merchantRaw.toLowerCase())
    ? [...merchantRaw].slice(0, 200).join("")
    : "";
  const currency = reading.currency && /^[A-Za-z]{3}$/.test(reading.currency) ? reading.currency.toUpperCase() : undefined;
  const bank = reading.bank ? [...reading.bank.replace(/\s+/g, " ").trim()].slice(0, 80).join("") || undefined : undefined;
  return { kind: reading.kind, amount: amountText, currency, merchant, bank, last4 };
}
