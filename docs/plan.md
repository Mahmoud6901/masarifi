# Plan: Masarifi (مصاريفي)

Expense tracker with Apple Pay capture, a place finder, and an AI agent that manages spending around installments.

## Decisions
- **Masarifi** is the app's name (مصاريفي, "my expenses").
- **Platform:** Flutter (iOS and Android codebase). Released as an unsigned IPA from GitHub Actions and installed with Sideloadly.
- **Backend:** Supabase (Postgres, auth, Edge Functions). Multi-user with row-level security.
- **Region:** Gulf, default currency SAR, configurable per user.
- **Installments:** loans, buy-now-pay-later and card installments, modeled generically.

## How Apple Pay capture works
Apps cannot read Apple Pay history on iPhone. An iOS Shortcuts "Transaction" automation sends `{amount, merchant, time}` to the `ingest` Edge Function with a personal token after each payment.

## Phases
1. **Foundation:** Flutter project, Supabase schema (`profiles`, `expenses`, `installment_plans`), auth, row-level security.
2. **Apple Pay capture:** `ingest` function with token auth, de-duplication and rule-based categories. Setup screen with URL, token and Shortcut steps. Manual add and delete of expenses.
3. **Installments:** plan model, next due date, remaining balance, mark-paid, and a safe-to-spend budget (income − installments − spending).
4. **Place finder:** Google Places search with rating, price level and distance, compared and recommended through the agent.
5. **AI agent:** Claude API with tools `get_budget_summary`, `get_expenses`, `get_installments`, `simulate_purchase`, `search_places`. Read-only; all money math computed in code.
6. **Testing and release:** unit tests for the logic layer, analyzer clean, GitHub Actions workflow producing an unsigned IPA.

## Risks and mitigations
| Risk | Level | Mitigation |
|---|---|---|
| Shortcut automation fails silently or asks for confirmation | High | Manual add; set automation to run immediately |
| Messy merchant names | Medium | Rule-based categories; users can edit later |
| Places has no exact prices, only price level or range | High | Agent states when a price is an estimate |
| Financial data privacy | High | Row-level security, no card numbers stored, AI calls go through the backend |
| AI giving wrong financial math | Medium | Numbers computed by code; the model only explains and plans |
| Gulf coverage and currency differences | Low | Per-user currency setting |
| Free Apple ID signing expires after 7 days | Medium | Re-sideload weekly |

## Complexity
High. Estimated 3–4 weeks of full-time work for the full scope.

## Not yet done or verified
- Supabase project, SQL migration and Edge Function deployment
- Anthropic and Google Places keys
- First GitHub Actions build and a real-device test of the Shortcut flow
- GPS-based place search (currently uses the city or area you type)
