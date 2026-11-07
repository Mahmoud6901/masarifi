# Masarifi (مصاريفي)

Expense tracker for iPhone with Apple Pay capture, installment planning, and an AI assistant that also finds and compares places. Flutter + Supabase. Default currency SAR.

## One-time setup

### 1. Supabase

1. Create a project at supabase.com.
2. SQL editor: apply the migrations once, in order: `001_init.sql`, `002_profile_privileges.sql`, `003_apple_pay_capture.sql`, then `004_phase3_installments.sql`, all in `supabase/migrations/`. A fresh database needs all four; an existing database needs only migrations it has not applied. Do this before using token rotation, ingest or installment payments. The rollback-only scripts in `supabase/tests/` are intended for a disposable Supabase database. The reviewer ran the migrations, SQL regressions, RLS and concurrency checks in throwaway PostgreSQL 17/PostgREST containers with GoTrue stubbed; real GoTrue and the Supabase platform remain unverified.
3. Install the Supabase CLI, then:
   ```bash
   supabase link --project-ref <your-ref>
   supabase functions deploy ingest --no-verify-jwt
   supabase functions deploy agent
   supabase secrets set ANTHROPIC_API_KEY=<key> GOOGLE_PLACES_API_KEY=<key>
   ```
   `ingest` is called by the iOS Shortcut with a personal token (not a login), so it is deployed with `--no-verify-jwt`. `agent` requires a signed-in user.
4. Google Places API (New) must be enabled for the Places key.

For a disposable database that has only 001–003, `supabase/tests/004_phase3_upgrade_regression.sql` applies 004 inside a rollback transaction and checks legacy value, currency and schedule preservation. It requires `psql` with `ON_ERROR_STOP=1`; do not run it after 004 is already applied. The separate `004_phase3_installments_regression.sql` checks the resulting schema after all four migrations. Both passed in the reviewer's disposable database; neither was run against a deployed Supabase project.

### 2. Apple Pay capture

In the app: Settings shows your ingest URL and private token. Follow the steps there to create the Shortcuts "Transaction" automation.

## Release

The workflow is prepared; its first GitHub Actions/macOS run and a real IPA installation are **unexecuted**. This folder has no Git repository yet. Repository creation, the first push, secrets and release tags are user-owned setup steps; they were not performed by this task.

1. Put the source in your GitHub repository. In Settings > Secrets and variables > Actions, add `SUPABASE_URL` and `SUPABASE_ANON_KEY`. Use the project's client anon/publishable key, never a service-role key. The URL and client key are embedded in the app; Anthropic and Places keys belong only in Supabase secrets. The workflow fails with the missing variable's name if either build secret is empty.
2. For an artifact build, open Actions > Build iOS IPA > Run workflow. Each successful configured run uploads the `Masarifi-ipa` artifact. Download and extract that artifact ZIP to obtain `Masarifi.ipa`. A manual run never publishes a GitHub Release, even when a tag is selected.
3. For a release, push a new `v*` tag after reviewing the source. The initial `pubspec.yaml` version is `1.0.0+1`, corresponding to tag `v1.0.0`. For an already configured repository, the tag commands are:

   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```

   Only a `v*` tag **push** attaches `Masarifi.ipa` to a GitHub Release. Download the IPA directly from that Release's Assets. Failed checks or a failed build do not produce an IPA.
4. Open the unsigned IPA in Sideloadly, connect the iPhone, sign in with your Apple ID and install. Sideloadly signs the app for your device; the workflow does not sign it or submit it to the App Store. A free Apple ID signs for 7 days, so re-sideload weekly. On the iPhone, use Settings > General > VPN & Device Management to trust your Apple ID when prompted.

The macOS workflow runs Flutter analysis/tests and the portable Edge Function tests/type check before `flutter build ios --release --no-codesign`. It packages `Payload/Runner.app` into `Masarifi.ipa` and fails if the app or expected archive is missing. No Apple signing certificate is required for this unsigned build.

## Local development

```bash
flutter pub get
flutter analyze
flutter test
flutter run --dart-define=SUPABASE_URL=<url> --dart-define=SUPABASE_ANON_KEY=<key>
```

Run all five portable Edge suites with an existing Node 22 installation:

```bash
node --experimental-strip-types supabase/functions/ci/run-tests.ts
```

CI installs pinned TypeScript 5.4.5, Node types 22.13.8 and Supabase JS 2.58.0 in its temporary directory for the strict check. `supabase/functions/ci/deno.d.ts` describes only the used Deno boundary and maps the `npm:` import to those SDK types. Dependency declarations use `skipLibCheck`; application and test sources remain strict. The local check used the existing compiler and Node types; the Supabase SDK types were unavailable locally, so checking against the pinned SDK remains **unexecuted until CI**.

Keep local environment files out of source control. `.gitignore` covers local `.env` variants, generated build/tooling directories, CocoaPods and Android local properties; a sanitized `.env.example` may be included. Personal ingest tokens must stay private.

## Handover

Local Flutter and portable Node tests use fake services. They establish logic and request handling, not a deployed integration. Shared Dart/TypeScript budget fixtures cover the accepted currency, calendar and provisional-schedule rules. The strict TypeScript check is separate from Deno runtime verification.

A local read-only credential audit found no real credential in the inspected source/configuration or workspace files. Candidates were test fixtures, workflow variable references and PEM delimiter strings in an ignored compiler cache, with no complete key block. No credential values were printed. This scan does not cover external repository history or replace reviewing files before the first push.

Earlier review ran migrations 001–004, SQL regressions, owner isolation and concurrent recorder/payment checks in disposable PostgreSQL 17/PostgREST containers with GoTrue stubbed. That evidence was not rerun in this release phase and does not verify real GoTrue or a hosted Supabase project.

| Remaining setup or verification | Status and owner action |
| --- | --- |
| Supabase project and migrations | **Unexecuted on hosted Supabase.** Create/link the project and apply all unapplied migrations in order 001–004 before using the app. |
| Edge deployment | **Unexecuted.** Deploy `ingest --no-verify-jwt` for the personal-token Shortcut and deploy `agent` with signed-in-user verification. |
| Provider keys and live services | **Unexecuted.** Configure server-only Anthropic/Google Places keys and enable Places API (New); verify real model/tool replies and Places results. No paid or live provider calls were made for this phase. |
| Real auth, RLS and adapters | **Unexecuted against the Supabase platform.** Verify real GoTrue sessions, owner isolation and the real Supabase JavaScript adapters after deployment. Disposable-database and fake-fetch evidence has the limits above. |
| Deno test/check/runtime | **Unexecuted.** Node and strict TypeScript are the portable CI baseline; they do not prove Deno execution. |
| First Actions/macOS build and release | **Unexecuted.** Configure the two GitHub build secrets, run the workflow and inspect/download the archive. The workflow definition has not produced a verified IPA here. |
| Device installation and Shortcut | **Unexecuted.** Install/sign the IPA, test login and a real Transaction automation, and verify amount/currency, duplicates and manual fallback. CLDR-formatted amount tests remain a proxy for real Shortcuts output. |
| Places costs | User-owned: Google Places searches may incur charges after key configuration/deployment. Each `search_places` invocation makes at most two Text Search requests: area lookup, then place search. |
| GPS search | Outside this phase. Place search uses the city/area you type and straight-line distance from its approximate centre. |

## Notes

- Each signed-in user only sees their own rows (row-level security). Anyone with your ingest token can add expenses to your account, so keep it private.
- The agent only reads data and suggests; all money math is computed in code, not by the model.
- The app and assistant budget use complete same-currency month-to-date spending and unpaid installments due by month-end, including overdue payments. Foreign amounts are shown in their own currency; no FX conversion occurs. Legacy plans need an owner-confirmed schedule and reserve one provisional payment until then. Marking an installment paid changes the plan only; capture or enter its cash expense separately. The assistant uses code-computed monetary results and gives no confident purchase verdict when the baseline is provisional.
- Google Places gives price level (and sometimes a price range), not exact menu prices. The assistant says when a price is an estimate.
- Google Places searches may incur charges after you configure a key and deploy. Each `search_places` invocation makes at most two Text Search requests (area lookup, then place search).
