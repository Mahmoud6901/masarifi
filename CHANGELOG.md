# Changelog

All notable changes to Masarifi. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.5.0] - 2026-11-16

- Masarifi is open source under the MIT License.
- The IPA no longer contains a backend. On first launch, connect your own Supabase project with its URL and anon key.
  The app checks the project before saving it and refuses `service_role` and secret keys.
- **Settings → Backend** shows the connected project and can disconnect it.
- Builds use Flutter 3.47.9.

## [1.4.2] - 2026-11-09

- Undo and other snackbar actions are readable in dark mode.

## [1.4.1] - 2026-11-09

- Home lists only this month's payments, newest first.
- Expenses shows the last five months, each with its total after refunds and a line per category. The current month is
  open and older months fold.
- Installments: swipe right when a month is paid, left when it isn't, and that month moves to the end of the plan. Paid
  and Not paid buttons, a five-second Undo, the next month peeking behind, and future months locked until they start.

## [1.3.1] - 2026-11-08

- The Shortcut gets one short reply line, such as `✓ 10 SAR · HungerStation`, `Skipped: transfer` or `⚠ Wrong token`.
  `?format=json` keeps the JSON reply.
- Delete a payment, with confirmation, from Overview and Expenses.
- `ingest` accepts a Wallet Dictionary forwarded as text, and an SMS sent as a Message object or a list.
- The Settings steps and the Siri prompt match the working Wallet and SMS setup.

## [1.3.0] - 2026-11-08

- One Shortcut captures Apple Pay taps and bank SMS on every card. Claude reads bank SMS (purchases and refunds; codes,
  declines and transfers are ignored), and every amount, card digit and merchant must appear in the SMS itself.
- New cards are created automatically, a payment seen by both Wallet and SMS is saved once, refunds are matched to the
  original purchase, and retries are not saved twice.
- Payments show refunded amounts and card names. A Cards list with rename, and **Add the Shortcut** and **Copy Siri
  prompt** in Settings. The budget and the assistant net out refunds.
- `ingest` accepts the Saudi Riyal sign in Wallet amounts and names the failing field in error replies.

## [1.2.0] - 2026-11-07

- A full-page plan form with a back button, edit on every plan card, and the total and per-plan remaining amounts.

## [1.1.0] - 2026-11-07

- A new dark design with a light theme, a pill dock and restyled screens.

## [1.0.1] - 2026-11-07

- A new app icon: the Arabic letter meem as a coin, with contactless-tap arcs.

## [1.0.0] - 2026-11-07

- First release: Apple Pay capture through a Shortcut, installments, what is safe to spend this month, a place finder
  and an AI assistant.
