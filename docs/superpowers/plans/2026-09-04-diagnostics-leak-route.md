# Diagnostics Leak Route Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** No diagnosis row can carry a credential that arrived inside a
backend error's free text: every `RemoteFSError` is rendered to a fixed
sentence chosen by its case, never by describing the value, and a guard
keeps `String(describing:)` out of the diagnostics module.

**Architecture:** `DialSupport.reason(for:)`
(`Sources/macSCPCore/Diagnostics/DialProbes.swift`) already maps
`HostKeyError`, `SSHKeyError` and `AgentError` case by case; its
`RemoteFSError` arm is the one that still says `String(describing: error)`
(line 210 at HEAD d74122c4). That arm becomes an exhaustive `switch`: the
cases that carry a PATH keep it (a path is the finding, the same ruling
the `SSHKeyError.fileNotFound` arm records), the cases that carry free
text (`connectionFailed(reason:)`, `protocolError(reason:)`) drop the
text — that text is where an endpoint with userinfo travels — and the
sentence names the case. `URLText.withoutUserinfo` stays as the
backstop on the outcome (`DiagnosticOutcome.redacted`), which a `/` in
a password defeats and which therefore cannot be the only line. A
source-scanning guard forbids `String(describing:` in
`Sources/macSCPCore/Diagnostics/` outside comments.

**Tech Stack:** Swift 6 strict, Swift Testing, the existing
`ConnectionDiagnosticsTests` fixtures (`probeDescriptor`, the dial
contribution seam).

**Spec:** `docs/BACKLOG.md`, row "Diagnostics: error text as a leak
route" (measured 2026-09-03): "`DialSupport.reason(for:)` renders
`RemoteFSError` through `String(describing:)`, so any backend error that
carries configuration text (an endpoint string with userinfo, a path)
can reach a diagnosis row … Open: map `RemoteFSError` cases to fixed
sentences in the diagnostics module (no `String(describing:)` on a
configuration-carrying error anywhere in `Diagnostics/`), with a guard
that scans for it." Callers of `reason(for:)` at HEAD: five
(`ContributionProbes.swift:51`, `:97`, `DialProbes.swift:71`, `:80`,
`:248`) — every dial and contribution failure passes through it.

## Global Constraints

- English only; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; commit per task; zero warnings; do not push.
- A secret's value never reaches a row, a log, an error or a test failure message: the test keeps the planted value in a named constant and computes the `Bool` before the `#expect` (CLAUDE.md, "A value a test must not leak has two exits, not one").
- Red first: a planted `RemoteFSError.connectionFailed(reason:)` whose text carries `KEY:SECRET@host` reaches a dial row with the secret in it today — that red is observed before the change.
- Every sentence English and fixed per case; the `switch` is exhaustive with no `default`, so a case added to `RemoteFSError` is a compile error here, not a silent `String(describing:)`.
- A negative source-scanning check needs a positive check beside it; comments quoting code near an anchor move the anchor — the guard blanks comments and strings before scanning (`SwiftSource.blankingCommentsAndStrings` from `Tests/macSCPCoreTests/SwiftSourceStripping.swift`; if it throws on a raw string in `Diagnostics/`, count the raw strings and say so).
- A number in a comment is counted (the callers of `reason(for:)`; the cases of `RemoteFSError`).
- No wall-clock ceiling; tests never block the pool; no `#require` on a non-optional.

---

### Task 1: Fixed sentences for `RemoteFSError`

**Files:**
- Modify: `Sources/macSCPCore/Diagnostics/DialProbes.swift:209-210` (the `RemoteFSError` arm)
- Test: `Tests/macSCPCoreTests/ConnectionDiagnosticsTests.swift` (beside `theSSHDialNeverPutsTheSecretInTheReport`: a dial contribution that throws `RemoteFSError.connectionFailed(reason: "\(scheme)://\(key):\(secret)@host:9000 refused")` → the dial row's `outcome` reason and `detail` contain neither the secret nor the key (Bools first), and the row still says the connection failed; a second case per path-carrying error: `notFound(path:)` keeps its path; a third: `bucketLevelRefused(operation:path:)` names the operation through its own catalogue-key derivation, not the enum's description)

**Interfaces:**
- Consumes: `RemoteFSError` (`Sources/macSCPCore/RemoteFS/RemoteFSError.swift` — read every case, count them, and the `BucketLevelOperation` nested enum), `URLText.withoutUserinfo` (unchanged).
- Produces: `DialSupport.reason(for:)` with an exhaustive `RemoteFSError` arm.

- [ ] **Step 1: Red first.** The `KEY:SECRET@host` case: `swift test --filter ConnectionDiagnosticsTests` — red with the Bool false (the row carries the userinfo, or — if `redacted` happens to strip it — plant a password containing `/` so the backstop's known hole shows; record which shape was red).
- [ ] **Step 2: Implement** the arm. Sentences, one per case, in this shape: `connectionFailed` → "the connection failed" (text dropped — say why in the comment: the reason is where an endpoint travels); `authenticationFailed` → "authentication failed"; `jumpAuthenticationFailed` → "authentication at the jump host failed"; `notFound(path)` → "nothing at \(path)"; `permissionDenied(path)` → "permission denied at \(path)"; `protocolError` → "the server answered something this app could not use" (text dropped); `bucketListForbidden` → "the key may not list the account's buckets"; `bucketListEmpty` → "the account has no buckets"; `bucketLevelRefused(operation, path)` → "\(operation) is not available at the bucket list (\(path))" with the operation's own name derivation; `crossBucketRenameRefused(from, to)` → "a rename across buckets is refused" (paths dropped — they are bucket-qualified paths, the finding is the refusal). Every case that exists at HEAD is covered; if the file has more cases than this list, each gets a sentence of the same kind and the report says so.
- [ ] **Step 3: Green**; full `swift test`; zero warnings.
- [ ] **Step 4: Commit** `fix(diagnostics): a backend error reaches a row as a fixed sentence, never as its description`.

---

### Task 2: The guard, and the row

**Files:**
- Create: `Tests/macSCPCoreTests/DiagnosticsNoDescribingGuardTests.swift`
- Modify: `docs/BACKLOG.md` (the row → **Done 2026-09-04**: the arm's shape, the cases counted, the red observed, the guard's two checks, the commits)

- [ ] **Step 1: Write the guard**: every Swift file under `Sources/macSCPCore/Diagnostics/` (enumerate from `#filePath`; positive: at least five files, and `DialProbes.swift` among them), blanked of comments and strings, contains no `String(describing:`; positive companion: the UNBLANKED `DialProbes.swift` contains the phrase the doc comment uses about never describing an error (read the comment at ~:146 and anchor on a distinctive clause), so the negative check is known to be reading the right file; and a self-test that plants `String(describing: error)` into an in-memory copy and sees the check fail.
- [ ] **Step 2: Measure sensitivity** with `scripts/mutation-probe --filter DiagnosticsNoDescribingGuardTests --apply "perl -0pi -e 's/return \"the connection failed\"/return String(describing: error)/' Sources/macSCPCore/Diagnostics/DialProbes.swift"` — RESULT RED, the line in the commit body.
- [ ] **Step 3: The row**; count the `RemoteFSError` cases the arm covers and the callers of `reason(for:)` at HEAD.
- [ ] **Step 4: Commit** `test(diagnostics): a guard keeps String(describing:) out of the diagnostics module`.
