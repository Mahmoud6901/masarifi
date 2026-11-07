# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Stack

Flutter (Dart), shipped to iPhone only as a sideloaded IPA (Sideloadly). Android code exists but is not a target. Supabase backend. System font stack; no bundled typeface.

## Users

Gulf-based individuals (first user: the owner, a Saudi-resident developer who pays with Apple Pay on an iPhone). They carry installments (loans, buy-now-pay-later, card plans) and want to know, at a glance, what is safe to spend this month. Arabic and English, RTL supported.

## Product Purpose

Masarifi (مصاريفي, "my expenses") records every Apple Pay payment automatically via an iOS Shortcuts automation, tracks installments, computes a safe-to-spend figure, and offers an AI assistant that finds and compares places and plans spending around installments.

## Positioning

The only expense tracker that is fed by the Apple Pay tap itself and reasons about installment commitments, not just past spending.

## Operating Context

Opened many times a day for seconds: after a payment, before a purchase, to check what is due. Currency defaults to SAR. Amounts are shown in the profile currency, including three-decimal Gulf currencies. Apple Pay capture arrives from a Shortcuts automation; manual entry is the fallback.

## Capabilities and Constraints

Screens: sign-in, Overview, Expenses, Installments, Assistant (chat plus place finder), Settings (currency, income, Shortcut setup with token). No bank connection, no foreign-currency conversion. The assistant is read-only. Business logic and data layer must not change in a visual redesign.

## Brand Commitments

Name: Masarifi / مصاريفي. App icon (assets/icon): Arabic meem as a coin with contactless arcs, saffron #FFC400 ground, ink #06281F, coin green #12B886. Visual reference pinned by the user: the Fey style reference (DESIGN (4).md): nocturnal matte-black terminal, single geometric sans, tight tracking, pill controls, 16px cards, colour as signal only. User decision: follow Fey's accents (orange #ffa16c, blue #479ffa, green #4ebe96); saffron is kept for the icon only. Dark and light themes both required.

## Evidence on Hand

No real transactions yet (new Supabase project, no data). No testimonials or proof exist and none may be invented.

## Product Principles

1. The safe-to-spend number is the product; every screen supports or explains it.
2. Colour is signal: positive, negative and due-soon states only, never decoration.
3. Capture should feel automatic; manual entry is quiet and secondary.
4. Gulf-first: SAR, Arabic and English, RTL correct everywhere.
5. Calm authority: no shouting, no gamification.

## Accessibility & Inclusion

Dynamic Type and Reduce Motion respected; 44pt minimum touch targets; text contrast at least 4.5:1 in both themes; Arabic RTL layouts mirrored correctly.
