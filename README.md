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

0. **Looks at the submission slot first.** A product has exactly one, and whatever is in it
   decides whether this tag can be submitted at all — see [One slot](#one-slot-per-product).
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

## One slot per product

The Store holds **exactly one submission per product**. While a version is in certification the
next one cannot be created at all — so a tag can go green through every test and publish
nothing, which is what it did on GTerminal 0.12.4, and why 0.12.9 was tagged on top of a
still-certifying 0.12.8.

Before creating the draft, the pipeline now asks what is in the slot and
[decides](scripts/Resolve-Slot.ps1):

| What is in the slot | What happens |
| --- | --- |
| Nothing | Publish. |
| An uncommitted draft | Overwritten by `--noCommit`, as before. |
| `CommitFailed` / `CertificationFailed` | Deleted and recreated — a wedged draft can be neither updated nor re-committed (409 InvalidState), and this is the API's own remedy. |
| In flight (`Certification`, `PreProcessing`, …) | Stops, naming the version that holds the slot — unless `supersede-pending` is on, in which case it is deleted and the new tag takes the slot. |

```yaml
with:
  product-id: 9NXXXXXXXXXX
  package-artifact: store-package
  supersede-pending: true   # newest tag wins; default false
```

Turn `supersede-pending` on only where the newest build is always the one you want out: it
cancels a release that may be minutes from going live.

**The pending submission is `msstore apps get` → `PendingApplicationSubmission.Id`, never the
exit code of `msstore submission get`.** Asked with nothing pending, that command prints
"Could not find a Pending Submission, but found the Last Published Submission", hands back the
*published* one — and exits 0. Anything keyed on that exit code reads a finished release as a
draft in progress.

## Troubleshooting

- **Stuck pending submission** (a previous run died mid-flight): handled automatically now — a
  `CommitFailed`/`CertificationFailed` draft is deleted and recreated. To clear one by hand:
  `msstore submission delete <product-id>`.
- **"already in the Store's one submission slot"**: an earlier version is still certifying. Wait
  for it, cancel it in Partner Center, or set `supersede-pending: true`. See
  [One slot](#one-slot-per-product).
- **Version rejected**: the Store requires each submission's package version to be strictly
  higher than the last committed one. Bump and re-tag.
- **`submission update` arg too long**: the merged product JSON travels as ONE command-line
  argument (~32k char cap; the script fails at 30k). Trim listing text or drop a locale.
