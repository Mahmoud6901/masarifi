import { test } from "node:test";

// The portable suites use Deno.test without depending on Deno runtime APIs.
Object.defineProperty(globalThis, "Deno", {
  configurable: true,
  value: { test },
});

await Promise.all([
  import("../agent/finance_test.ts"),
  import("../agent/handler_test.ts"),
  import("../agent/repository_test.ts"),
  import("../agent/places_test.ts"),
  import("../ingest/index_test.ts"),
]);
