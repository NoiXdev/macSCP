# Capability Boundary at Connect — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An anonymous yes-man can no longer be written as a decider, and the app layer can no longer reach the raw dialing procedure.

**Foundation:** `docs/superpowers/specs/2026-08-28-faehigkeitsgrenze-verbinden-design.md`

**Architecture:** Two half-steps that cover different halves. The bare function types `HostKeyDecider` and `CertificateDecider` become types with a non-public initializer and named factories; `BackendDescriptor.connect` becomes `internal` and gets a public entry point. After that, the guard shrinks down to what types cannot express.

**Invisible from outside:** no new behavior, no new setting. This work changes what can be written.

## Global Constraints

- Code, comments, identifiers, test names, commit messages: **English only**.
- Conventional Commits; footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **TOFU stays untouched.** A fingerprint mismatch remains a hard stop in the
  backend and never reaches a decider. Anyone who hits a path during the
  rework that would change that stops and reports it.
- **The CLI keeps deciding what it decides today:** rejecting unknown
  certificates, host keys per `HostKeyPolicy`. Its output on `stderr` and its
  `CLIEnvironment.hasTTY` stay in the CLI — **none of it moves to Core.**
- All six targets are on `.swiftLanguageMode(.v6)`; **CI turns red as soon as
  the number of distinct warning sites exceeds 1.**
- **No line numbers, no location references in comments.** Every number and
  every enumeration is counted in the pass that writes it.
- **Only one negative check beside a positive one.** See the section
  "Guards that name what they watch" in `CLAUDE.md` — it was measured against
  exactly this guard family.
- One scratch path, deleted after use.
- The app is not launched, nothing is pushed.

---

### Task 1: A decider is a type

**Files:**
- Modify: `Sources/macSCPCore/Connection/HostKeyDecider.swift`,
  `Sources/macSCPCore/WebDAV/WebDAVSessionDelegate.swift`,
  `Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift`,
  `Sources/macSCPCore/Capabilities/BackendDescriptor.swift`,
  `Sources/macSCPCore/Presentation/ConnectionViewModel.swift`,
  `Sources/MacSCPAppKit/ContentView+Lifecycle.swift`,
  `Sources/MacSCPCLI/SessionConnecting.swift`
- Test: `Tests/macSCPCoreTests/HostKeyDeciderTests.swift` (new)

**Interfaces:**
- Produces: `HostKeyDecider` and `CertificateDecider` as `struct`s with
  `callAsFunction`, with the factories `.asking(_:)` and `.refusing`.
  Task 2 threads them through the new entry point.

**The measured status quo:** both are bare function types today —
`public typealias HostKeyDecider = @Sendable (HostKeyCandidate) async -> Bool`
and the same for `CertificateDecider`. My file count (**four** and
**three**) was **incomplete**: `CitadelFileSystem.connect(onUnknownHostKey:)`
spells out the raw function type instead of the alias and therefore does not
show up in a search for the alias name — of all things, the direct dialing
site the guard exists for. **Count it yourself, and search for the
signature, not the name.**

`callAsFunction` is decisive for scope: consuming sites today call
`await decider(candidate)`, and they keep calling it exactly that way
afterward. Only the **construction** sites change.

- [ ] **Step 1: Write the test first.**

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("Host key decider")
struct HostKeyDeciderTests {
    private func candidate() -> HostKeyCandidate {
        HostKeyCandidate(
            host: "example.com", port: 22, keyType: "ssh-ed25519",
            publicKeyBase64: "QUJD")
    }

    @Test func askingForwardsTheAnswerItWasGiven() async {
        let yes = HostKeyDecider.asking { _ in true }
        let no = HostKeyDecider.asking { _ in false }
        #expect(await yes(candidate()) == true)
        #expect(await no(candidate()) == false)
    }

    @Test func askingSeesTheCandidateItIsAskedAbout() async {
        let seen = TestBox<String?>(nil)
        let decider = HostKeyDecider.asking { candidate in
            seen.value = candidate.host
            return false
        }
        _ = await decider(candidate())
        #expect(seen.value == "example.com")
    }

    @Test func refusingAnswersNoWithoutAsking() async {
        #expect(await HostKeyDecider.refusing(candidate()) == false)
    }
}
```

  **`TestBox`** lives in `Tests/macSCPCoreTests/WebDAVSessionDelegateTests.swift`
  (`final class TestBox<Value>: @unchecked Sendable`) — use that one instead of
  introducing a second one. If it is not visible there, say so in the report
  instead of building your own.

  **On the candidate signature, because I had it wrong myself while writing
  the plan:** `HostKeyCandidate.init(host:port:keyType:publicKeyBase64:)` —
  the fingerprint is derived from it and is not an initializer argument.
  Verify it yourself anyway.

- [ ] **Step 2: Run it red.**

Run: `swift test --filter HostKeyDecider`
Expected: FAIL — `type 'HostKeyDecider' has no member 'asking'`.

- [ ] **Step 3: Implement.** `HostKeyDecider.swift` becomes:

```swift
import Foundation

/// The answer to "this host key is UNKNOWN — trust it?".
///
/// A type rather than a closure, and that is the whole point. As a bare
/// `@Sendable (HostKeyCandidate) async -> Bool`, any call site could pass
/// `{ _ in true }` and answer the question on the user's behalf — which is
/// exactly what a source guard caught six times in six different spellings,
/// each looking complete from inside the previous round. What a caller can
/// write now is a factory with a name.
///
/// Never asked on a MISMATCH: `HostKeyValidation` stops that before any
/// decider is consulted, and no factory here can change that.
public struct HostKeyDecider: Sendable {
    private let answer: @Sendable (HostKeyCandidate) async -> Bool

    private init(_ answer: @escaping @Sendable (HostKeyCandidate) async -> Bool) {
        self.answer = answer
    }

    public func callAsFunction(_ candidate: HostKeyCandidate) async -> Bool {
        await answer(candidate)
    }

    /// Puts the question to someone who answers it — the app's prompt, the
    /// CLI's policy and its terminal. The closure PRESENTS; it is not meant
    /// to decide on its own, and a guard watches that the app wires this to
    /// the real prompt (see the wiring guard for what that check does and
    /// does not see).
    public static func asking(
        _ present: @escaping @Sendable (HostKeyCandidate) async -> Bool
    ) -> HostKeyDecider {
        HostKeyDecider(present)
    }

    /// Answers no without asking anyone. For callers with nobody to ask.
    public static let refusing = HostKeyDecider { _ in false }
}
```

  **The same for `CertificateDecider`** in `WebDAVSessionDelegate.swift`, with
  `ServerCertificateCandidate` instead of `HostKeyCandidate` and its own doc
  comment saying what the hard stop is there. A second test file for it,
  following the same pattern — **do not** copy the same tests, ask the
  questions that apply to certificates.

- [ ] **Step 4: Update the construction sites.** Every place that currently
  passes a closure now uses a factory. The CLI keeps its
  `makeDecider(policy:)` unchanged in body and wraps it in `.asking`;
  its `stderr` output and `CLIEnvironment.hasTTY` stay where they are.
- [ ] **Step 5:** Full suite green, no new warning.
- [ ] **Step 6: Commit** — `refactor(connection): make a decider a type, not a closure`

---

### Task 2: Dialing is not a capability of the app layer

**Files:**
- Modify: `Sources/macSCPCore/Capabilities/BackendDescriptor.swift`,
  `Sources/MacSCPAppKit/ContentView+Lifecycle.swift`,
  `Sources/MacSCPCLI/SessionConnecting.swift`
- Test: `Tests/macSCPCoreTests/` (new, for the entry point)

**Interfaces:**
- Consumes: the two decider types from Task 1.
- Produces: `BackendDescriptor.openConnection(_:hostKey:certificate:timeoutSeconds:)`
  as the **only** public path to a connection.

**The measured status quo:** exactly **two** real callers outside Core —
`ContentView+Lifecycle` and `SessionConnecting`. **No** test dials through
the descriptor; every hit in `Tests/` is sample material inside a guard.
**170** Core test files import `@testable` and retain access to internals.
Verify both numbers yourself before relying on them.

- [ ] **Step 1:** `public let connect:` in the descriptor becomes `let connect:`
  (module-internal), and next to it comes:

```swift
extension BackendDescriptor {
    /// The one way to open a connection from outside this module.
    ///
    /// `connect` itself is module-internal so that "dialing past the shared
    /// path" is not a violation a test has to find, but something that does
    /// not compile. Core's own tests import `@testable` and keep their
    /// access; the app and the command line do not have it.
    public static func openConnection(
        _ config: ConnectionConfig,
        hostKey: HostKeyDecider,
        certificate: CertificateDecider,
        timeoutSeconds: Int
    ) async throws -> any RemoteFileSystem {
        try await descriptor(for: config.kind)
            .connect(config, hostKey, certificate, timeoutSeconds)
    }
}
```

- [ ] **Step 2:** Switch both callers over to `openConnection`.
- [ ] **Step 3: Prove the boundary holds.** Write into the report the
  result of an attempt: `BackendDescriptor.descriptor(for:).connect(…)` in
  an app file — **must be a compile error**, and the error text belongs
  quoted. Remove the probe afterward.
- [ ] **Step 4:** Full suite green, no new warning.
- [ ] **Step 5: Commit** — `refactor(connection): take dialing out of the app layer's reach`

---

### Task 3: The guard shrinks

**Files:**
- Modify: `Tests/macSCPAppKitTests/ReconnectWiringGuardTests.swift`,
  `Tests/macSCPAppKitTests/ConnectTimeoutAppWiringGuardTests.swift`

**Interfaces:**
- Consumes: everything from Task 1 and 2.

**The measured status quo:** the suite holds sample material that carries
the raw dialing procedure as a string — among other things the `async let`
form from round 6. Much of it now checks something that no longer compiles.

- [ ] **Step 1: Enumerate what each check still accomplishes.** For each
  check, one line: does the compiler cover this now, or not? **What it
  covers gets deleted** — not kept "just in case." A guard standing beside
  a guarantee lets the suite's next reader trust it more than it deserves.
- [ ] **Step 2: Prove the rest.**

  **Correction to this plan, measured after Task 1:** the app layer builds
  **no** host key decider. It threads it through; the prompt is wired in
  Core (`ConnectionViewModel.connect` → `presentHostKeyPrompt`). A
  **certificate** decider, by contrast, is built there, with
  `.asking { candidate in await certificateBridge.ask(candidate) }`. The
  original version of this step claimed both for host keys and was wrong.

  What should remain, then, is exactly **one** thing a type cannot say:
  that the four `.asking` call sites hang off whatever actually asks, and
  not off a yes-man. **Count them yourself**, rather than taking the four
  on faith.

  Plant `.asking { _ in true }` at each of these sites and prove whether a
  guard goes **red**. If it does not, the rest is no longer a guard but
  decoration — **say so, instead of building one.** A new scan over four
  call sites would be the seventh attempt of the same family; whether it is
  worth it is a maintainer decision, not part of this task.
- [ ] **Step 3: Rewrite the boundary statement.** It has grown over six
  rounds and mostly describes holes that no longer exist. After this step
  it must be **true**: what the compiler holds, what the rest guards, and
  what still nobody sees.
- [ ] **Step 4:** Full suite green, no new warning.
- [ ] **Step 5: Commit** — `test(connection): keep only what types cannot say`

---

## What is explicitly out of scope

- **No change to TOFU** and none to what the CLI decides.
- **No move of CLI output or `hasTTY` to Core.**
- No new setting, no new behavior for the user.
- No answer to the remaining boundary: `.asking { _ in true }` stays
  writable. The design says why that is fine — visible instead of
  impossible — and Task 3 makes it into what the guard watches.
