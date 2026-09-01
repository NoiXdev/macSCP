# macSCP M6a — Polish backlog (design spec)

**Date:** 2026-07-26
**Status:** approved by the maintainer (block A + block B)
**Context:** First part of the release milestone M6 (split A: M6a polish →
M6b release). Works through the entire open ledger backlog. After M6a comes
M6b (icon, DMG, signing + notarization, README).

## Goal

Close every open backlog item from the M5 reviews: a global bandwidth limit
(shared token bucket), folder cancellation in the conflict dialog, edit
integration fixes, form/session cleanup work, a11y items in the new form
visuals, and code hygiene. After this the code is release-ready.

## Decisions (maintainer, 2026-07-26)

- Backlog scope: the **complete** open ledger backlog (not curated).
- Throttle: a **shared token bucket** per direction, a real injectable
  clock.
- Conflict "cancel" on folder transfers: **cancels the whole group**.
- Dead `paper` token: **delete it** (YAGNI), do not introduce it as a
  window background.
- Edit uploads: **excluded** from the resume banner (no re-download path).

## Block A — behavior changes

### 1. Global bandwidth bucket (replaces the virtual clock)

- New Core actor `BandwidthBucket`:
  - Configuration: `bytesPerSecond` (rate) — burst capacity = 1 second of
    rate (standard token bucket).
  - `consume(_ bytes: Int) async throws` — waits (cooperatively
    cancellable) until enough tokens are available, then deducts. Refills
    continuously based on real elapsed time since the last refill.
  - `setRate(bytesPerSecond: Int)` — runtime update on a settings change
    (the queue's existing onChange wiring).
  - Clock and sleep are injectable (an instant provider on a
    `ContinuousClock` basis + a sleep hook) → tests deterministic without
    real sleeping; default = the real clock/`Task.sleep`.
- `TransferEngine.copyFile`: the `bytesPerSecondLimit: Int` parameter +
  the injected `sleep` hook are dropped; instead `throttle:
  BandwidthBucket?` (nil = unthrottled). Before every chunk write:
  `try await throttle?.consume(chunk.count)`.
- `TransferQueueViewModel` owns **two** buckets (upload / download,
  separate settings as before; limit 0 ⇒ no bucket / nil) and passes the
  direction-matching bucket to every transfer. All parallel transfers in
  one direction thereby share exactly one limit.
- Dropped with no replacement: the virtual throttle clock including its
  over-throttling (real ≈ limit/2 on links near the limit) and the
  documented M5d resume special case ("virtual clock starts at 0") — the
  bucket knows only bytes, no transfer history.
- Cooperative cancellation stays: `consume` throws on task cancellation;
  the existing post-write check stays the gate.

### 2. Folder cancellation in the conflict dialog

- "Cancel" in the conflict dialog of a **group item** (a recursive folder
  transfer) cancels the whole group:
  - The conflicting item becomes `.cancelled`.
  - All not-yet-started items of the same group are swept out of the
    queue → `.cancelled`.
  - Already-running transfers of the same group are cancelled
    cooperatively (`.cancelled`).
  - Files already copied stay put — nothing is deleted.
- Invariants unchanged: the group's `onCompleted` fires exactly once,
  after all items are terminal; no item is terminalized twice;
  exactly-once waiters stay.
- Single-file conflict: "Cancel" still cancels only that one item, as
  before.

## Block B — fixes, a11y, hygiene

### 3. Edit integration

- **Startup sweep:** on app launch, the root directory `tmp/macscp-edit/`
  is fully cleared (no edit is running at this point; single-instance
  app). Orphaned directories from hard kills disappear reliably.
- **Resume banner:** interrupted **edit uploads** no longer appear in the
  resume banner (their temp source is deleted by `stopAll` on disconnect —
  a resume would visibly fail). They end as a normal error; the next
  editor save kicks off a fresh upload anyway.
- **Localized error text:** instead of `String(describing:)` the edit
  banner shows the existing localized error mapping from the Core layer
  (`RemoteFSError` cases + a generic fallback). A cancellation
  (`CancellationError`) deliberately shows NO banner: the only
  cancellation path is session teardown, and a banner set after that
  would wrongly reappear in the next session.

### 4. Form / session

- "New connection" after edit mode clears the fields (reset in `onNew`).
- `endEditing()` / `exitEditMode()` are consolidated into one method.
- The dense orphan-cleanup expression in `SessionStore.load()` is
  rewritten to be readable. Both are pure refactorings — existing tests
  stay green unchanged.

### 5. a11y (M5k minors)

- `FormRow` label: `.accessibilityHidden(true)` — VoiceOver now names each
  row only once (controls keep their a11y titles); the empty toggle row no
  longer emits an empty static-text element.
- `FormRow` labels dim along with the form when it is disabled during a
  connect (`\.isEnabled` environment, opacity 0.5 like the buttons).
- `PolishedButtonStyle`: a visible focus ring for Full Keyboard Access
  (ring in `remoteBlue`).

### 6. Cosmetics / hygiene

- Delete the dead `paper` token; correct stale comments in `DesignTokens`
  (staged notes) and on `errorHighlight` ("4pt outside").
- Bind duplicate L10n calls in the form (label + control title, 8×) once
  per row.
- Conflict message: stop wrongly reporting a symlink/other as "exists as
  a file".
- `applyToAll` recheck after gate acquisition in the conflict machinery
  (prevents a superfluous prompt when the rule was set while the item was
  waiting at the FIFO gate).

## Invariants

- Security and architecture invariants untouched: TOFU hardness, secrets
  only in the keychain, UI-owned lifecycles, FIFO start order,
  exactly-once waiters/onCompleted.
- Language: code + comments English; new UI/error text cataloged EN/DE.
- No new settings; the existing up/down limits only change their effect
  (global instead of per-transfer) — settings UI unchanged.

## Tests

- `BandwidthBucket`: TDD with an injected clock — rate honored, burst
  bounded, `setRate` takes effect, cancellation throws, multiple consumers
  share the limit deterministically.
- Engine/queue: throttle tests migrated from the virtual clock to a bucket
  stub; direction assignment (upload bucket vs. download bucket) tested.
- Group cancellation: new queue tests — the sweep catches exactly the
  group's items, `onCompleted` exactly-once, the single-file case
  unchanged, running group transfers cancelled cooperatively.
- Error-text mapper: catalog lookup tests (locale-pinned) for the
  `RemoteFSError` cases + cancellation + generic.
- Startup sweep & resume exclusion: unit tests at the manager/queue level.
- The existing suite (295) stays green; gated suites (`MACSCP_ITEST`,
  `MACSCP_KEYCHAIN`) before wrap-up.
- Visual smoke test: throttle live with 2 parallel transfers against a
  limit (aggregate ≈ limit instead of 2×), folder conflict → cancel stops
  the group, VoiceOver spot check of the form, focus ring via tab, "New
  connection" after edit is empty.

## Deliberately NOT in M6a

- Icon, DMG, signing, notarization, README → M6b.
- Auto-reconnect backoff (stays backlog).
- Multi-server/multi-window (v2).
- Settings-window restyling (the system-chrome line).
