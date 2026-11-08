// Supabase Edge Function entrypoint. Tests import handler.ts directly.
import { createClient } from "npm:@supabase/supabase-js@2";
import { createIngestHandler, type IngestBackend, type IngestProfile } from "./handler.ts";
import type { RecordApplePayArgs } from "./handler.ts";
import { createClaudeSmsReader } from "./sms.ts";

export { categorize, createIngestHandler, parseAmount, parsePaymentAmount } from "./handler.ts";
export type { ExpenseCategory, HandlerOptions, IngestBackend, IngestProfile, RecordApplePayArgs } from "./handler.ts";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const backend: IngestBackend = {
  async findProfileByTokenHash(hash) {
    const { data, error } = await admin
      .from("profiles")
      .select("id, ingest_token, currency")
      .eq("ingest_token_hash", hash)
      .maybeSingle();
    return { profile: data as IngestProfile | null, error };
  },
  async recordApplePay(args: RecordApplePayArgs) {
    const { data, error } = await admin.rpc("capture_payment", args);
    return { result: data, error };
  },
};

// The SMS reader shares the assistant's key; without it, SMS capture replies
// 503 sms_reader_unavailable and Wallet capture keeps working.
const anthropicKey = Deno.env.get("ANTHROPIC_API_KEY");
const readSms = anthropicKey
  ? createClaudeSmsReader({ apiKey: anthropicKey, model: Deno.env.get("SMS_MODEL") })
  : undefined;

Deno.serve(createIngestHandler({ backend, readSms, shortcutUrl: Deno.env.get("SHORTCUT_URL") }));
