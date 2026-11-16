# Contributing

## Set up

- [Flutter](https://docs.flutter.dev/get-started/install) **3.47.9** (stable). CI pins this version: Flutter 3.50
  deprecates `package:flutter/material.dart` in favour of `package:material_ui`, and that migration is still to do.
- Xcode on a Mac to build or run on an iPhone. Analysis and tests run anywhere.
- Node 22 for the Edge Function tests.
- The [Supabase CLI](https://supabase.com/docs/guides/cli) to deploy the functions.

```bash
flutter pub get
```

## Run

Use a separate Supabase project for development, not the one that holds your real spending. Set it up as the
[README](README.md#2-set-up-your-backend-once-about-15-minutes) describes.

```bash
flutter run    # shows the Connect screen
flutter run --dart-define=SUPABASE_URL=<url> --dart-define=SUPABASE_ANON_KEY=<anon key>   # skips it
```

## Test

```bash
flutter analyze
flutter test
node --experimental-strip-types supabase/functions/ci/run-tests.ts
```

`supabase/tests` holds SQL regression scripts for the migrations. Run them with
`psql -v ON_ERROR_STOP=1` against a disposable database that has the migrations applied; each script rolls itself back.

## Release

Update `version` in `pubspec.yaml` and add the changes to [CHANGELOG.md](CHANGELOG.md), then push a tag such as
`v1.5.1`. [The iOS workflow](.github/workflows/ios-ipa.yml) analyzes, tests, builds an unsigned IPA with no backend inside
and attaches it to a GitHub Release.

## Never commit personal data

- No project URLs, keys, ingest tokens, bank SMS or real amounts in code, tests or issues. Use placeholders such as
  `https://abcd1234.supabase.co` and the fixtures in `test/fixtures`.
- `supabase/.temp/` is ignored because it holds your linked project ref.
- CI runs [gitleaks](https://github.com/gitleaks/gitleaks) on every push to `main` and every pull request.
