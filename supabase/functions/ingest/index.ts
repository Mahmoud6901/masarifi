// Supabase Edge Function entrypoint. Tests import handler.ts directly.
import { createClient } from "npm:@supabase/supabase-js@2";
import { createIngestHandler, type IngestBackend, type IngestProfile } from "./handler.ts";
import type { RecordApplePayArgs } from "./handler.ts";

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
    const { data, error } = await admin.rpc("record_apple_pay", args);
    return { result: data, error };
  },
};

Deno.serve(createIngestHandler({ backend }));
