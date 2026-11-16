# Masarifi (مصاريفي)

An iPhone expense tracker for the Gulf. Every Apple Pay tap and bank SMS lands in
your budget on its own, installments included, and an AI assistant helps you plan
around them. Your data lives in **your own** Supabase project, not with the author.

[Download the IPA](https://github.com/Mahmoud6901/masarifi/releases/latest) · [العربية](README.ar.md) ·
[Report a problem](https://github.com/Mahmoud6901/masarifi/issues/new?template=bug_report.yml)

- **Automatic capture:** Apple Pay taps (Wallet automation) and bank SMS
  (read by AI), saved once even when both arrive. New cards are learned and bank
  refunds are matched to the original payment.
- **Safe to spend this month:** income − installments due − spending so far.
- **Installments:** swipe right when a month is paid, left when it isn't (that
  month moves to the end of the plan), with Undo.
- **Expenses:** the last five months, each with its total and a per-category line.
- **Assistant:** asks about your budget, simulates a purchase, and finds and
  compares places (Google Places).
- English interface, laid out right to left on an iPhone set to Arabic; dark
  and light themes. Default currency SAR; AED,
  KWD, QAR, BHD and OMR also supported.

## 1. Install the app

Masarifi is not on the App Store. You install the IPA yourself:

1. Download **`Masarifi.ipa`** from the [latest release](../../releases/latest).
2. Install it with a sideloading tool and your Apple ID:
   - [Sideloadly](https://sideloadly.io) (Windows or Mac): connect the iPhone,
     drop in the IPA, sign in, install.
   - Or [AltStore](https://altstore.io) / [SideStore](https://sidestore.io),
     which can refresh the app from the iPhone itself.
3. On the iPhone, trust your Apple ID under **Settings › General › VPN & Device
   Management**, and turn on **Settings › Privacy & Security › Developer Mode**
   if iOS asks.

With a free Apple ID the install lasts 7 days; re-sign it weekly (AltStore and
SideStore can do this for you).

## 2. Set up your backend (once, about 15 minutes)

1. Create a free project at [supabase.com](https://supabase.com).
2. In **SQL Editor**, run each file in [`supabase/migrations`](supabase/migrations)
   in order: `001` → `005`.
3. Deploy the two functions with the [Supabase CLI](https://supabase.com/docs/guides/cli):

   ```bash
   supabase login
   supabase link --project-ref <your-project-ref>
   supabase functions deploy ingest --no-verify-jwt
   supabase functions deploy agent
   ```

   `ingest` is called by your Shortcut with a private token, not a login, so it
   is deployed without JWT verification. `agent` requires a signed-in user.
4. Add secrets under **Project Settings › Edge Functions › Secrets** (or
   `supabase secrets set NAME=value`):

   | Secret | Needed for |
   | --- | --- |
   | `ANTHROPIC_API_KEY` | The assistant and reading bank SMS. Without it, SMS reading is off. |
   | `GOOGLE_PLACES_API_KEY` | The place finder (enable *Places API (New)*). Optional. |
   | `SHORTCUT_URL` | Optional: an iCloud link to your own copy of the Masarifi shortcut. |
   | `ANTHROPIC_MODEL`, `SMS_MODEL` | Optional model overrides. |

5. Open Masarifi. On **Connect your backend**, paste the **Project URL** and the
   **anon key** from **Project Settings › API**. The app refuses the
   `service_role` and secret keys; never put those on a phone.
6. Create your account in the app. By default Supabase emails a confirmation
   link first.

Supabase's free tier is enough for one person. Anthropic and Google bill you
directly for what your own project uses.

## 3. Capture payments automatically (Shortcuts)

Masarifi receives payments from one Shortcut named **Masarifi**, run by two
automations. Your ingest URL and private token are in the app under
**Settings › Payment capture**.

**Get the Masarifi shortcut** (either way):

- Tap **Copy Siri prompt** and paste it into *Describe a shortcut* in the
  Shortcuts app. It builds the shortcut with your URL and token already in it.
- Or, when your project has a `SHORTCUT_URL` secret, tap **Add the Shortcut**:
  it copies your token and opens that shared shortcut; paste your ingest URL and
  token when Shortcuts asks.

**Then add the two triggers** in the Shortcuts app:

1. **Apple Pay:** a shortcut that starts with *When Any Card is tapped*, then a
   *Dictionary* of `amount`, `merchant` and `card` from the Wallet input, then
   *Run Shortcut* **Masarifi** with the Dictionary as input.
2. **Bank SMS:** save each bank's SMS sender as a contact. Make a shortcut that
   starts with *When I receive a message* where *Sender* is your banks, then
   *Run Shortcut* **Masarifi** with the *Message* as input.

Set both to run immediately. After a payment you get a short notification such
as `✓ 10.50 SAR · HungerStation`. In-app and online payments are caught by the
bank SMS.

## Privacy

- Everything is stored in your Supabase project, behind row-level security:
  each account sees only its own rows. The author of Masarifi has no access.
- The ingest token lets a Shortcut add expenses to your account. Keep it
  private; **Settings › Regenerate token** replaces it.
- No card numbers are stored: only the Wallet card name and the last four
  digits a bank SMS shows.
- Bank SMS text is sent from **your** `ingest` function to Anthropic with
  **your** key to read the amount. Leave `ANTHROPIC_API_KEY` unset to keep SMS
  out of it.
- The assistant only reads your data and suggests; all money math is computed in
  code, not by the model.

[PRIVACY.md](PRIVACY.md) lists every connection the app and your functions make.

## Build from source

Masarifi builds with Flutter 3.47.9. See [CONTRIBUTING.md](CONTRIBUTING.md) for
setup, tests and releases.

```bash
flutter pub get
flutter analyze
flutter test
flutter run    # shows the Connect screen
```

To skip the Connect screen in a personal build, pass your project at build time:

```bash
flutter run --dart-define=SUPABASE_URL=<url> --dart-define=SUPABASE_ANON_KEY=<anon key>
```

Edge Function tests run on Node 22:

```bash
node --experimental-strip-types supabase/functions/ci/run-tests.ts
```

Pushing a `v*` tag runs [the iOS workflow](.github/workflows/ios-ipa.yml): it
analyzes, tests, builds an unsigned IPA with no backend inside and attaches it
to a GitHub Release. Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## Report a problem

Include the Masarifi version, your iOS version, what you did and what you
expected. For a capture problem, include the Shortcut's reply line. Issues are
public: never paste your ingest token, keys, project URL or bank SMS.
[Open a bug report](https://github.com/Mahmoud6901/masarifi/issues/new?template=bug_report.yml)
or [share how setup went](https://github.com/Mahmoud6901/masarifi/issues/new?template=first_use_feedback.yml).

## License

[MIT](LICENSE)
