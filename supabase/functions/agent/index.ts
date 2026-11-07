// Deployment adapter only: secrets never enter the client or model messages.
import { createClient } from "npm:@supabase/supabase-js@2";
import { createServerAgent } from "./adapter.ts";
import type { AgentClient } from "./adapter.ts";

Deno.serve(
  createServerAgent({
    url: Deno.env.get("SUPABASE_URL"),
    anonKey: Deno.env.get("SUPABASE_ANON_KEY"),
    apiKey: Deno.env.get("ANTHROPIC_API_KEY"),
    model: Deno.env.get("ANTHROPIC_MODEL"),
    placesKey: Deno.env.get("GOOGLE_PLACES_API_KEY"),
    clientFactory: (url, key, options) =>
      createClient(url, key, options) as unknown as AgentClient,
  }),
);
