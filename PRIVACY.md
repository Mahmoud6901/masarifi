# Privacy

Masarifi has no server of its own. The app talks only to the Supabase project you connect, and that project calls
Anthropic and Google only with keys you add. The author of Masarifi receives nothing.

## What leaves your iPhone

| Connection | When | What is sent | Where |
|---|---|---|---|
| Your Supabase project | When you sign in, open the app, or add or change anything | Your email and password at sign-in; your expenses, income, installments and cards | The project you connected |
| Checking a project | When you tap **Connect** | The anon key, to read the project's public sign-in settings | The project you entered |
| Your `ingest` function | Each Apple Pay tap or bank SMS your Shortcut forwards | Amount, merchant and card name from Wallet, or the SMS text, with your private token | Your Supabase project |
| Anthropic, from `ingest` | Bank SMS only, and only when `ANTHROPIC_API_KEY` is set | The SMS text | Anthropic, billed to your key |
| Anthropic, from `agent` | When you send the assistant a message | Your messages and the budget figures it looks up to answer: totals, payments and installments | Anthropic, billed to your key |
| Google Places, from `agent` | When you ask the assistant to find places, and only when `GOOGLE_PLACES_API_KEY` is set | Your search and the area you name. Never your location | Google, billed to your key |
| iCloud | When you tap **Add the Shortcut** | Nothing personal: Shortcuts opens the shared link | icloud.com |

## What stays on your iPhone

- The project URL and anon key you connected, and your sign-in session, in the app's own storage.
  **Settings → Backend → Disconnect** signs out and removes the project. Deleting the app removes both.
- Your ingest token and the Siri prompt go to the clipboard only when you tap a copy button.

## In your Supabase project

- Row-level security: each account sees only its own rows.
- Card numbers are never stored: only the Wallet card name and the last four digits a bank SMS shows.
- The ingest token lets a Shortcut add expenses to your account. Keep it private; **Settings → Regenerate token**
  replaces it.
- To delete everything, delete your user under **Authentication → Users**. All of its rows are deleted with it.

Leave `ANTHROPIC_API_KEY` unset to keep bank SMS out of Anthropic; SMS reading and the assistant then stay off.

No telemetry, analytics or crash reporting.

## Third-party privacy policies

- [Supabase](https://supabase.com/privacy)
- [Anthropic](https://www.anthropic.com/legal/privacy)
- [Google](https://policies.google.com/privacy)
