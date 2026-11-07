/** Narrow declarations for the Deno runtime boundary used by Edge entrypoints. */
declare namespace Deno {
  const env: {
    get(name: string): string | undefined;
  };
  function serve(
    handler: (request: Request) => Response | Promise<Response>,
  ): void;
  function test(name: string, body: () => void | Promise<void>): void;
}

/** Supabase SDK types are resolved from the exact CI-installed npm package. */
declare module "npm:@supabase/supabase-js@2" {
  export { createClient } from "@supabase/supabase-js";
}
