# Bounded File Closes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `SFTPFile.close()` can no longer hang macSCP against a silent peer
— measured 6 of 6 on both the read and the write path
(`docs/superpowers/specs/2026-08-28-backlog-unbounded-file-closes.md`,
"Measured 2026-09-02") — and, as with the session close before it, the
unbounded call becomes **unreachable** rather than merely wrapped.

**Architecture:** The move that closed the session-level hang, applied one
level down. `BoundedSFTPSession` already owns the raw `SFTPClient` and
exposes `closeBounded()` as the only close; its `openFile` is today a pure
passthrough that hands the raw `SFTPFile` to `CitadelFileSystem`. It will
instead hand out a `BoundedSFTPFile` — `private let raw: SFTPFile`,
`fileprivate`/module-internal construction, forwarding `read`/`write`/
`readAttributes`, and `closeBounded()` built on `BoundedClose` with the
session's `closeBoundSeconds`. The raw file never reaches
`CitadelFileSystem`, so none of its close sites CAN be unbounded; the
existing `SFTPReadHandle` box wraps the bounded file instead of the raw one.
The two isolate-close tests from the measurement are the red; they assert
`returned == true` within 10 s and turn green when the bound (shorter than
10 s — read `closeBoundSeconds`) fires.

**Tech Stack:** Swift 6, Swift Testing, `BoundedClose` (`Sources/macSCPCore/RemoteFS/BoundedClose.swift`),
`BoundedSFTPSession` (`Sources/macSCPCore/SSH/BoundedSFTPSession.swift`),
Docker disposable container for the gated tests.

**Not in this plan — the second finding:** a cancelled Task does not
interrupt an in-flight SFTP request against a frozen peer (Citadel's
`sendRequest` awaits `EventLoopFuture.get()` with no cancellation handler).
That is a separate defect with a design question (a race around each
request, or tearing the channel down on cancel) and stays in the entry as
measured and open. The two cancellation tests in the measurement patch are
its red and are NOT committed here.

## Global Constraints

- Code, comments, identifiers, test names, commit messages: **English only**.
  Conventional Commits; footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Capability boundary, proved by compile error**: after Task 2 no
  `SFTPFile` value is reachable in `CitadelFileSystem.swift`; the proof is
  planting `try await file.close()` on the raw type there and watching it
  fail to compile — record the compiler's line in the report. A grep is not
  the proof.
- **Read before you heal**: the red tests capture before `thaw()` (they
  already do); do not change that.
- **The `deinit` detached close is out of scope** (a leaked task, not a
  hang — the entry says so); do not touch it beyond what the type change
  forces, and say what that forced.
- **No new deadline value**: reuse `BoundedSFTPSession.closeBoundSeconds`;
  a second number would be a second copy of the same decision.
- Only the two isolate-close tests from
  `.superpowers/sdd/2026-09-02-unbounded-file-closes-measurement/red-tests-round2.patch`
  are committed; the two `anInFlight…NotInterruptedByCancellation…` tests
  stay out (finding b). Apply the patch, then remove those two before
  committing — they would be permanently red here.
- Gated tests only under `MACSCP_ITEST=1`; disposable containers only, the
  rig's 2222 is never paused; every container removed.
- `.swiftLanguageMode(.v6)`; warning budget 1 on a fresh scratch path.
- TDD: the red is the measurement's tests; they must be seen red on this
  branch before Task 2 changes anything. Commit per task. Do not push.

---

### Task 1: The red, on this branch

**Files:**
- Modify: `Tests/macSCPAppKitTests/LivenessProbeDropIntegrationTests.swift`

- [ ] **Step 1:** `git apply .superpowers/sdd/2026-09-02-unbounded-file-closes-measurement/red-tests-round2.patch`
  (from the repo root). Remove the two `anInFlight…` tests and any helper
  only they use; keep `aReadHandleCloseAgainstAStillFrozenPeer…`,
  `aWriteFileCloseAgainstAStillFrozenPeer…`, `connectRawSFTP`,
  `UncheckedBox` and the ports they use. Rename the two kept tests to what
  they will assert once green: `aReadHandleCloseAgainstAStillFrozenPeerReturnsInsideTheBound`
  / `aWriteFileCloseAgainstAStillFrozenPeerReturnsInsideTheBound` — the
  measurement named them by the defect, this plan names them by the
  property.
- [ ] **Step 2:** Run `MACSCP_ITEST=1 swift test --filter "AgainstAStillFrozenPeerReturnsInsideTheBound"`
  — both RED (returned == false after ~10 s). Paste the two lines.
- [ ] **Step 3: Commit** the red — `test(sftp): a file close against a frozen peer must return inside the bound (red)`.
  A red commit is deliberate here: the next commit's diff is then exactly
  the fix.

---

### Task 2: `BoundedSFTPFile`, and the raw file stops reaching the file system

**Files:**
- Modify: `Sources/macSCPCore/SSH/BoundedSFTPSession.swift` (new type
  beside the session, `openFile` returns it)
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift` (`readStream`,
  `write`, `SFTPReadHandle`, and every other site that touches `SFTPFile` —
  count them in this pass; the entry counted eight `.close()` calls on
  2026-08-28, five direct and three through the handle)
- Test: `Tests/macSCPCoreTests/BoundedSFTPSessionTests.swift` or its
  sibling (find where `closeBounded` is tested; add the file-level cases
  beside it)

**Interfaces:**
- Produces: `struct BoundedSFTPFile` (or `final class` — match
  `BoundedSFTPSession`'s choice and say why) with `read(from:length:)`,
  `write(_:at:)`, `readAttributes()` forwarding to the raw file, and
  `closeBounded() async -> Bool` — the only close.
  `BoundedSFTPSession.openFile(filePath:flags:) -> BoundedSFTPFile`.

- [ ] **Step 1: Read `BoundedSFTPSession`'s doc comments first** — they
  record why the session type has no `close()` at all, why the bound is a
  type-level constant and not a parameter, and what the earlier draft got
  wrong. The file type follows every one of those decisions.
- [ ] **Step 2: Unit red** (no Docker): a `BoundedSFTPFile` whose raw close
  never returns — use whatever seam the session tests use for the same
  case (`grep -n "closeBounded" Tests/macSCPCoreTests/*.swift`); if the
  session tests reach the bound only through the gated suite, say so and
  rely on Task 1's red.
- [ ] **Step 3: Implement** the type and the `openFile` change. Doc comment
  on the type: what it is, why the raw file must not escape, and the
  measurement it answers (cite the entry, not the numbers).
- [ ] **Step 4: Move every site.** `readStream`'s three closes, `write`'s
  three, `SFTPReadHandle`'s wrapper and the `deinit` — the last one only as
  far as the type forces (it may now call `closeBounded()` detached; say
  what changed and that the leaked-task question is unchanged). `try? await
  file.close()` becomes `_ = await file.closeBounded()`; where the close's
  outcome matters (the successful-completion close in `write`), decide
  whether `false` is an error to the caller — read what `disconnect()` does
  with the session's `false` and follow it; write the decision in a comment.
- [ ] **Step 5: The capability proof.** Plant `try await someRawSFTPFile.close()`
  in `CitadelFileSystem.swift` — there must be no way to name a raw
  `SFTPFile` there; the compiler's error is the proof. Record it, remove
  the plant.
- [ ] **Step 6:** `MACSCP_ITEST=1 swift test --filter "AgainstAStillFrozenPeerReturnsInsideTheBound"`
  — GREEN, three runs, durations recorded (expect ≈ `closeBoundSeconds`).
  Then the full unit suite, then the full gated suite once, warnings on a
  fresh scratch path.
- [ ] **Step 7: Commit** — `fix(sftp): a file close cannot hang — the raw file never reaches the file system`

---

### Task 3: The entry closes; the second finding stays open

**Files:**
- Modify: `docs/superpowers/specs/2026-08-28-backlog-unbounded-file-closes.md`, `docs/BACKLOG.md`

- [ ] **Step 1:** Append "Fixed 2026-09-0x": the type, the compile-error
  proof (quote it), the three green durations, which sites moved (counted
  in this pass), the `deinit` note — and, unchanged, the cancellation
  finding as measured and open with its two tests still in the patch.
  Index row to match.
- [ ] **Step 2: Commit** — `docs(backlog): close the unbounded file closes entry, keep the cancellation finding open`

## What is explicitly not in this plan

- The cancellation finding (b) — its own design.
- Any change to `BoundedClose` or to `closeBoundSeconds`.
- S3/WebDAV — `URLSession` owns its deadlines.
