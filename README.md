# store-publish

Shared **Microsoft Store publishing pipeline** for all of my Store apps. One reusable GitHub
Actions workflow + the listing-as-code scripts, so each app repo only carries its listing text
and a tiny caller workflow.

The flow (package draft → merge listing-as-code → inject screenshots → commit to certification)
was built and proven on [findneedle](https://github.com/guscatalano/findneedle).

## How an app publishes

On a `v*` tag (or manual run), the app repo builds its **unsigned** msix/appx, uploads it as an
artifact, and calls this repo's reusable workflow:

```yaml
publish:
  needs: package
  uses: guscatalano/store-publish/.github/workflows/publish.yml@main
  with:
    product-id: 9NXXXXXXXXXX
    package-artifact: store-package
  secrets: inherit
```

The reusable workflow ([.github/workflows/publish.yml](.github/workflows/publish.yml)) then:

1. `msstore publish <pkg> -id <product-id> --noCommit` — pending draft with the package.
2. `msstore submission get` → [`scripts/Build-Submission.ps1`](scripts/Build-Submission.ps1) —
   merge the caller's `store/listing.*.json` (all locales) into the draft. Store field limits are
   enforced here (build fails, not certification).
3. [`scripts/Upload-Screenshots.ps1`](scripts/Upload-Screenshots.ps1) — if the caller has
   `store/screenshots/*.png`, inject them into the submission zip per locale. **No screenshots
   in the repo = the screenshots already in Partner Center stay as-is.**
4. `msstore submission update` + `msstore submission publish` — commit into certification.

## What each app repo needs

- `store/listing.en-us.json` — required. Managed fields: `Title`, `ShortDescription`,
  `Description`, `Features`, `Keywords`, `ReleaseNotes`, etc. `Title` must match the reserved
  app name in Partner Center. More locales = more `listing.<locale>.json` files (en-us is the
  template; new locales need `store/screenshots/` to exist or they're skipped).
- `store/screenshots/*.png` — optional (PNG, ≥ 1366×768, ≤ 10). Present = replaces every
  locale's screenshot set on each release.
- **Keywords must not contain other products' names** (Store policy 10.1.3 — certification
  rejected "tmux" as "a product title not published by you"). Generic terms only; comparison
  prose in the Description appears to be tolerated.
- A packaging job producing the **unsigned** package (the Store signs on ingestion) with a
  version **higher than the last submission**, uploaded as an artifact.
- The four repo secrets (same values for every app — they're seller-level, not per-app):
  `STORE_TENANT_ID`, `STORE_CLIENT_ID`, `STORE_CLIENT_SECRET`, `STORE_SELLER_ID`.
  Push them to all repos in one go with [`scripts/Push-StoreSecrets.ps1`](scripts/Push-StoreSecrets.ps1).

## Authority note

Because CI overwrites the managed listing fields on every release, **direct edits to those
fields in Partner Center get reverted on the next tag** — edit the repo's `store/listing.*.json`
instead. Unmanaged fields (pricing, availability, age ratings, gaming options) are never touched
and stay managed in Partner Center.

## First submissions (brand-new products)

A product that has never been published takes a different path automatically: `msstore publish`
refuses loose packages on first submissions, so the pipeline drives the raw submission API —
it synthesizes the en-us listing from `listing.en-us.json`, ships the package inside the same
upload zip as the screenshots (`ApplicationPackages: PendingUpload`), initializes
`AllowTargetFutureDeviceFamilies` (Desktop only), and applies `store/properties.json`
(`PriceId`, `ApplicationCategory`) if present. **Screenshots are mandatory on this path** — a
first listing without images hangs the commit.

Exactly two things cannot be code — both are one-time-per-product Partner Center UI fields that
persist for every future submission (proven on GTerminal's first submission, Aug 2026):

1. the **age rating questionnaire** (IARC) — no API at all;
2. the **Privacy policy URL** (Properties page) — the `BaseListing.PrivacyPolicy` field is
   deprecated and silently dropped by the API, and the submission resource has no privacy field.

If the commit fails on either (age rating errors are API-visible; the privacy URL surfaces as
"validation errors which cannot be exposed via API"), set them once in Partner Center and re-run
the workflow — the pipeline deletes and recreates a CommitFailed draft automatically.

## Troubleshooting

- **Stuck pending submission** (a previous run died mid-flight): clear it once with
  `msstore submission delete <product-id>`, then re-tag.
- **Version rejected**: the Store requires each submission's package version to be strictly
  higher than the last committed one. Bump and re-tag.
- **`submission update` arg too long**: the merged product JSON travels as ONE command-line
  argument (~32k char cap; the script fails at 30k). Trim listing text or drop a locale.
