---
version: 1
slug: "lib-screens"
primary_target: "lib/screens"
related_targets: []
---

# Surface brief: Masarifi app (all six screens, iOS)

Mode: Operate. Scope: sign-in, Overview, Expenses, Installments, Assistant, Settings. Redesign of the visual layer only; data layer and logic untouched. Dark and light themes.

Audience and job: one Gulf resident glancing for seconds, many times a day: what is safe to spend, what is due, what did I just pay.

## Direction contract

THESIS: A calm nocturnal terminal for personal money. The safe-to-spend figure is the one big thing; everything else is quiet data. Refuses the stock Material look (seed-colour tonal cards, filled buttons, Roboto).
OWN-WORLD: Dark ground #0b0b0b, cards #191919 at 16px radius, wells #131313, white type with tight negative tracking, graphite #868f97 secondary text. Pill (99px) controls, ghost buttons with a faint white halo. Colour is signal only: growth green #4ebe96 for positive/safe, warm orange #ffa16c for the one highlighted word and due-soon, blue #479ffa for the active nav underline, a desaturated red for negative. Light theme mirrors it: warm off-white ground, same roles, inverted surfaces. System font (SF Pro / SF Arabic), tabular figures for money.
STORY: The visitor sees how much they can safely spend, trusts it because it is derived from income, installments and spending, and acts (add, pay, ask).
FIRST VIEWPORT: Overview. Top: small graphite caption "Safe to spend this month" and the amount at about 54pt, tracking -0.08em, with the currency small beside it; one word of the headline in orange only when overspent. Under it three quiet stat rows (income, installments due, spent). Then a card list of the latest payments with an Apple Pay mark. Floating pill dock at the bottom with five line icons, active item underlined in blue.
FORM: Fey-style terminal for an Operate surface, pinned by the user (reference: DESIGN (4).md). Position: user-pinned, not rolled. seed: none (unavailable)
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Unresolved decisions
- Calibre is not available; the system font stands in. A bundled face could replace it later.
- No simulator on this Windows machine: verification is by rendered widget tests, not a device screenshot.
