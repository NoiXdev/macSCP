# S3 Without a Bucket, the Cheap Half — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** "It doesn't let me" stops being the answer: a new S3 form starts
with a region that most S3-compatible providers accept, and a blank bucket
or region produces a message that says what is needed and why — without
building the bucket-level browser.

**Architecture:** `S3FieldSchema.defaults` gains `region = "us-east-1"`
(visible, editable — a value the user sees is not a hidden assumption).
The region and bucket fields get their own `invalidMessageKey` instead of
the shared "Fill in all required S3 fields." Nothing changes in signing,
config or the browser. The full design — provider type, `ListBuckets`
with a permission check, a bucket-level directory kind — is
`docs/superpowers/specs/2026-09-02-s3-bucket-browser-design.md` and waits
for the maintainer.

**Tech Stack:** Swift 6, Swift Testing, `ConnectionFieldSchema` /
`FieldValues`, four `.lproj` catalogs via `CoreL10n.string`.

**Source:** `docs/superpowers/specs/2026-08-31-backlog-s3-without-bucket.md`
— its "cheap part" paragraph is this plan; its "what this is not" (no
change to the signature, no guessing the region from the endpoint) binds.

## Global Constraints

- Code, comments, identifiers, test names, commit messages: **English only**.
  Conventional Commits; footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- User-visible text in **all four catalogs** (`Sources/macSCPCore/Resources/{en,de,fr,pl}.lproj/Localizable.strings`),
  looked up via `CoreL10n.string(_:)`; German addresses the user as **du**;
  `LocalizationParityTests` and `GermanAddressFormTests` are the guards.
- **`us-east-1` is an assumption about third-party servers** (many
  S3-compatible providers do not check the region). It is named as such in
  the comment beside the default and in the region message; it is never
  applied silently to a saved session — only to a NEW form.
- **No change to SigV4 signing, `S3ConnectionConfig`, or the browser.**
- **No guessing the region from the endpoint.**
- `.swiftLanguageMode(.v6)`; warning budget 1, measured on a fresh scratch path.
- TDD, red first. Commit per task. Do not push.

---

### Task 1: A new S3 form starts with a region, and blanks say why

**Files:**
- Modify: `Sources/macSCPCore/S3/S3FieldSchema.swift` (`defaults`, and the
  `region` / `bucket` `ConnectionField`s' `invalidMessageKey`)
- Modify: `Sources/macSCPCore/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
- Test: `Tests/macSCPCoreTests/FieldValidationTests.swift` (the existing
  S3 case near line 94 asserts `core.connect.s3FieldRequired`),
  `Tests/macSCPCoreTests/ConnectionViewModelTests.swift` (two existing
  expectations near lines 1453 and 1469 build the same string), and the
  suite that covers `S3FieldSchema.defaults` (find it:
  `grep -rn "S3FieldSchema.defaults\|usePathStyle\] == false" Tests`; if
  none asserts the defaults, add the test to `FieldValidationTests`).

- [ ] **Step 1: Red — the default.** A test that `S3FieldSchema.defaults`
  carries `S3Field.region` = `"us-east-1"` (read it through the same
  `FieldValues` accessor the form uses; look at how `usePathStyle` is read
  back). Fails today (absent).
- [ ] **Step 2: Red — the messages.** Change the existing assertions that
  name `core.connect.s3FieldRequired` for a blank BUCKET to
  `core.connect.s3BucketRequired`, and add one for a blank REGION expecting
  `core.connect.s3RegionRequired`. Leave the endpoint on
  `core.connect.s3FieldRequired`. Run — the changed/added ones fail.
- [ ] **Step 3: Implement.** In `S3FieldSchema`:

```swift
// A new form starts with the region most S3-compatible providers accept
// because they do not check it. That is an ASSUMPTION about third-party
// servers, which is why it is a visible, editable default on a new form
// and never written into an existing session. AWS itself does check —
// the AWS preset's user still has to enter theirs. Measured against the
// rig's MinIO (us-east-1 in the gated suite); not measured against
// Servinga, the provider in the report.
values[S3Field.region] = "us-east-1"
```

  (use whatever subscript `FieldValues` offers for a string; `values[bool:]`
  is the toggle's.) Region field: `invalidMessageKey: "core.connect.s3RegionRequired"`;
  bucket field: `invalidMessageKey: "core.connect.s3BucketRequired"`.
- [ ] **Step 4: Strings**, `en` exact, the other three rendered from it
  (German du):

```
"core.connect.s3BucketRequired" = "Enter the bucket. macSCP opens one bucket per connection — the bucket is the first folder you see. Listing every bucket of an account is not supported yet.";
"core.connect.s3RegionRequired" = "Enter the region. It is part of the request signature, so it cannot be left empty; most S3-compatible providers accept us-east-1.";
```

- [ ] **Step 5: Run** `swift test --filter "FieldValidationTests|ConnectionViewModelTests|LocalizationParityTests|GermanAddressFormTests"`, then the full unit suite once; measure warnings on a fresh scratch path.
- [ ] **Step 6: Commit** — `feat(s3): default the region on a new form and say why bucket and region are needed`

---

### Task 2: The entry records what shipped and what waits

**Files:**
- Modify: `docs/superpowers/specs/2026-08-31-backlog-s3-without-bucket.md`

- [ ] **Step 1:** Append "Done 2026-09-02 — the cheap half": the default,
  the two messages, the assumption named, what was measured (MinIO) and
  not (Servinga), and a pointer to the design doc for the rest.
- [ ] **Step 2: Commit** — `docs(backlog): record the cheap half of s3 without a bucket`

## What is explicitly not in this plan

- No `ListBuckets`, no provider type, no bucket-level browser — see the
  design doc.
- No change to saved sessions: an existing session with an empty region
  stays as it is and gets the new message on connect.
