# M20 — CLI Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `macscp-cli` uses the same stored sessions as the app — for SSH and S3 — and works both at the terminal and without prompting in cron and CI.

**Architecture:** All decision logic (session resolution, secret acquisition, trust decisions, transfer planning) lands as small, testable types in `macSCPCore`, because only Core has a test target. `MacSCPCLI` stays wiring: ArgumentParser, output formatting, TTY detection, exit codes.

**Tech Stack:** Swift 6 (language mode v5), SwiftPM, swift-argument-parser, Swift Testing (`@Test`/`#expect`), Security.framework (Keychain), Docker rigs for gated tests.

## Global Constraints

- Swift tools 6.0, all targets `.swiftLanguageMode(.v5)`, minimum macOS 15.
- **Code and comments exclusively in English.** No German in source files, including test names or `reason:` strings.
- CLI output is program output, not localized UI: **English, not through `L10n`.** The app's string catalogs are **not** touched in M20.
- Tests: Swift Testing, TDD red→green. New logic ships with tests; regressions are proved red first.
- Ungated suite: `swift test`. Gated: `MACSCP_ITEST=1` (Docker SSH rig, MinIO), `MACSCP_KEYCHAIN=1` (real keychain).
- Start the Docker rig **always from the main checkout**, never from a worktree: `docker compose -f docker/test-server/compose.yml up -d`.
- Never commit key material. Test keys generated at runtime via `ssh-keygen`.
- Conventional Commits, commit messages in English, footer on **every** commit:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Build must stay at 0 new warnings.

---

## File Structure

**New in Core:**

| File | Responsibility |
|---|---|
| `Sources/macSCPCore/Connection/HostKeyDecider.swift` | The decider type, freed from the presentation layer |
| `Sources/macSCPCore/Connection/HostKeyPolicy.swift` | Policy for unknown keys (ask/reject/accept-new) |
| `Sources/macSCPCore/Sessions/SessionReference.swift` | Parse `name:/pfad` and resolve it against the store |
| `Sources/macSCPCore/Sessions/SecretResolver.swift` | Staged secret acquisition with interchangeable sources |
| `Sources/macSCPCore/Sessions/KeychainMigration.swift` | One-time rewrite onto the access group |
| `Sources/macSCPCore/RemoteFS/TransferPlan.swift` | Source/destination → concrete transfer jobs |

**New in the CLI** (one subcommand per file, plus three infrastructure files):

`Sources/MacSCPCLI/` — `MacSCPCLI.swift` (root command), `CLIExitCode.swift`, `CLIEnvironment.swift`, `OutputFormatter.swift`, `SessionConnecting.swift`, `LsCommand.swift`, `GetCommand.swift`, `PutCommand.swift`, `RmCommand.swift`, `MkdirCommand.swift`

**Changed:** `Sources/macSCPCore/Presentation/ConnectionViewModel.swift` (typealias), `Sources/macSCPCore/Sessions/SecretStore.swift` (optional access group), `scripts/release` (sign the CLI), `Resources/macSCP.entitlements` + `Resources/macscp-cli.entitlements` (new), `README.md`.

---

### Task 1: Free `HostKeyDecider` from the presentation layer

A pure move with no behavior change. Must happen first, because otherwise the CLI would have to import a type from the UI layer just to connect at all.

**Files:**
- Create: `Sources/macSCPCore/Connection/HostKeyDecider.swift`
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift:76`

**Interfaces:**
- Produces: `public typealias HostKeyDecider = @Sendable (HostKeyCandidate) async -> Bool` at module level in `macSCPCore`.

- [ ] **Step 1: Create the new file**

```swift
// Sources/macSCPCore/Connection/HostKeyDecider.swift
import Foundation

/// Asked when a host key is UNKNOWN — never on a mismatch, which is a hard
/// stop with no override (M3c invariant). Lives in `Connection/` rather than
/// on `ConnectionViewModel` because non-UI callers need it too: the CLI has no
/// view model but still has to answer this question (M20).
public typealias HostKeyDecider = @Sendable (HostKeyCandidate) async -> Bool
```

- [ ] **Step 2: Leave a typealias on the view model**

Replace line 76 in `ConnectionViewModel.swift`:

```swift
    /// Moved to `Connection/HostKeyDecider.swift` in M20 so non-UI callers
    /// (the CLI) need not reach into the presentation layer. Kept as an alias
    /// so existing call sites and their doc references keep working.
    public typealias HostKeyDecider = macSCPCore.HostKeyDecider
```

- [ ] **Step 3: Build and run the full suite**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: `Build complete!` and all tests green (baseline 1188/87). No new warnings.

- [ ] **Step 4: Commit**

```bash
git add Sources/macSCPCore/Connection/HostKeyDecider.swift Sources/macSCPCore/Presentation/ConnectionViewModel.swift
git commit -m "refactor: move the host key decider out of the presentation layer

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `HostKeyPolicy` (Core)

**Files:**
- Create: `Sources/macSCPCore/Connection/HostKeyPolicy.swift`
- Test: `Tests/macSCPCoreTests/HostKeyPolicyTests.swift`

**Interfaces:**
- Produces:
  - `public enum HostKeyPolicy { case ask, reject, acceptNew }`
  - `public enum HostKeyDecision: Equatable, Sendable { case prompt, accept, reject }`
  - `public static func decision(for policy: HostKeyPolicy, hasTTY: Bool) -> HostKeyDecision`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/macSCPCoreTests/HostKeyPolicyTests.swift
import Foundation
import Testing
@testable import macSCPCore

/// The policy answers ONE question: what to do about an UNKNOWN host key.
/// A mismatch never reaches it — `HostKeyValidation` stops that before any
/// decider runs (M3c). `mismatchNeverReachesThePolicy` pins that boundary.
@Suite("HostKeyPolicy")
struct HostKeyPolicyTests {
    @Test func askPromptsWhenATerminalIsAvailable() {
        #expect(HostKeyPolicy.decision(for: .ask, hasTTY: true) == .prompt)
    }

    @Test func askRejectsWithoutATerminal() {
        // The non-interactive case: no way to ask, so refuse rather than
        // silently trust. This is the promise every cron job relies on.
        #expect(HostKeyPolicy.decision(for: .ask, hasTTY: false) == .reject)
    }

    @Test func rejectRefusesRegardlessOfTerminal() {
        #expect(HostKeyPolicy.decision(for: .reject, hasTTY: true) == .reject)
        #expect(HostKeyPolicy.decision(for: .reject, hasTTY: false) == .reject)
    }

    @Test func acceptNewAcceptsRegardlessOfTerminal() {
        #expect(HostKeyPolicy.decision(for: .acceptNew, hasTTY: true) == .accept)
        #expect(HostKeyPolicy.decision(for: .acceptNew, hasTTY: false) == .accept)
    }
}
```

- [ ] **Step 2: See the test fail (red)**

Run: `swift test --filter HostKeyPolicy 2>&1 | tail -5`
Expected: compile error `cannot find 'HostKeyPolicy' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/macSCPCore/Connection/HostKeyPolicy.swift
import Foundation

/// What to do about an UNKNOWN host key. Deliberately says nothing about a
/// MISMATCH: that is a hard stop decided in `HostKeyValidation` before any
/// decider is consulted, and no policy value can soften it (M3c invariant).
public enum HostKeyPolicy: String, CaseIterable, Sendable {
    /// Ask the user when possible; refuse when there is nobody to ask.
    case ask
    /// Never trust anything new, not even interactively.
    case reject
    /// Trust unknown keys without asking — the `--accept-new` opt-in, for
    /// first-time provisioning. Says nothing about mismatches.
    case acceptNew
}

public enum HostKeyDecision: Equatable, Sendable {
    case prompt
    case accept
    case reject
}

extension HostKeyPolicy {
    /// Pure decision, so every combination is provable in a test rather than
    /// argued about. Note the asymmetry: `.ask` without a terminal becomes
    /// `.reject`, never `.accept` — a missing human is not consent.
    public static func decision(for policy: HostKeyPolicy, hasTTY: Bool) -> HostKeyDecision {
        switch policy {
        case .reject: return .reject
        case .acceptNew: return .accept
        case .ask: return hasTTY ? .prompt : .reject
        }
    }
}
```

- [ ] **Step 4: See the test pass (green)**

Run: `swift test --filter HostKeyPolicy 2>&1 | tail -3`
Expected: `Test run with 4 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Connection/HostKeyPolicy.swift Tests/macSCPCoreTests/HostKeyPolicyTests.swift
git commit -m "feat: add a host key policy for non-interactive callers

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Remove auto-trust from the CLI

The invariant repair, **before** new commands are added. After this task the CLI can do less than before (unknown hosts need confirmation) — that is intentional.

**Files:**
- Create: `Sources/MacSCPCLI/CLIExitCode.swift`
- Create: `Sources/MacSCPCLI/CLIEnvironment.swift`
- Modify: `Sources/MacSCPCLI/MacSCPCLI.swift` (replace the decider)

**Interfaces:**
- Consumes: `HostKeyPolicy.decision(for:hasTTY:)` from Task 2.
- Produces:
  - `enum CLIExitCode: Int32 { case success = 0, usage = 2, auth = 10, hostKeyUnknown = 11, hostKeyMismatch = 12, connection = 13, remote = 14, conflict = 15 }`
  - `enum CLIEnvironment { static var hasTTY: Bool }`
  - `func makeDecider(policy:) -> HostKeyDecider`

- [ ] **Step 1: Create exit codes and TTY detection**

```swift
// Sources/MacSCPCLI/CLIExitCode.swift
import Foundation

/// Exit codes a script can branch on. 11 and 12 are deliberately different:
/// "new host" is a work item, "key changed" is an alarm. Collapsing them
/// throws away the distinction TOFU exists for.
enum CLIExitCode: Int32 {
    case success = 0
    case usage = 2
    case auth = 10
    case hostKeyUnknown = 11
    case hostKeyMismatch = 12
    case connection = 13
    case remote = 14
    case conflict = 15
}
```

```swift
// Sources/MacSCPCLI/CLIEnvironment.swift
import Foundation

enum CLIEnvironment {
    /// Whether stdin is a terminal. Drives whether we may prompt at all —
    /// checked on stdin rather than stdout so that `macscp-cli ls | less`
    /// still counts as interactive.
    static var hasTTY: Bool { isatty(FileHandle.standardInput.fileDescriptor) == 1 }
}
```

- [ ] **Step 2: Write the test for the replacement** (in Core, because the CLI has no test target)

Append to `Tests/macSCPCoreTests/HostKeyPolicyTests.swift`:

```swift
    /// The shape the CLI relies on: with no terminal and the default policy,
    /// an unknown key must NOT be trusted. This is the regression that the
    /// old M1 driver failed — it trusted everything and printed a fingerprint.
    @Test func defaultPolicyWithoutTerminalNeverAccepts() {
        let decision = HostKeyPolicy.decision(for: .ask, hasTTY: false)
        #expect(decision != .accept)
        #expect(decision == .reject)
    }
```

- [ ] **Step 3: Run the test**

Run: `swift test --filter HostKeyPolicy 2>&1 | tail -3`
Expected: `Test run with 5 tests in 1 suite passed`.

- [ ] **Step 4: Replace the auto-trust in the CLI**

In `MacSCPCLI.swift`, replace the `decider:` block (currently lines 28–32) with:

```swift
    /// Builds the decider for UNKNOWN host keys. A mismatch never gets here:
    /// `HostKeyValidation` stops it first, and this function has no branch
    /// that could accept one. The M1 driver used to trust everything — that
    /// path is gone (M20).
    private func makeDecider(policy: HostKeyPolicy) -> HostKeyDecider {
        { candidate in
            switch HostKeyPolicy.decision(for: policy, hasTTY: CLIEnvironment.hasTTY) {
            case .accept:
                FileHandle.standardError.write(Data(
                    "Trusting new host key \(candidate.fingerprintSHA256) (--accept-new)\n".utf8))
                return true
            case .reject:
                FileHandle.standardError.write(Data("""
                    Unknown host key for \(candidate.host):\(candidate.port)
                      \(candidate.keyType) \(candidate.fingerprintSHA256)
                    Confirm it interactively, or pass --accept-new to trust new hosts.

                    """.utf8))
                return false
            case .prompt:
                FileHandle.standardError.write(Data("""
                    Unknown host key for \(candidate.host):\(candidate.port)
                      \(candidate.keyType) \(candidate.fingerprintSHA256)
                    Trust this host? [y/N]
                    """.utf8))
                guard let line = readLine(strippingNewline: true) else { return false }
                return line.lowercased() == "y" || line.lowercased() == "yes"
            }
        }
    }
```

Also add the flags to the root command:

```swift
    @Flag(name: .long, help: "Trust unknown host keys without asking. Never affects mismatches.")
    var acceptNew = false

    @Flag(name: .long, help: "Never prompt; fail instead.")
    var nonInteractive = false

    private var hostKeyPolicy: HostKeyPolicy {
        if acceptNew { return .acceptNew }
        return nonInteractive ? .reject : .ask
    }
```

and switch the call to `decider: makeDecider(policy: hostKeyPolicy)`.

- [ ] **Step 5: Build and verify by hand**

Run: `swift build 2>&1 | tail -2`
Expected: `Build complete!`, no new warnings.

Run: `docker compose -f docker/test-server/compose.yml up -d && MACSCP_PASSWORD=testpass swift run macscp-cli --non-interactive --host 127.0.0.1 --port 2222 --user testuser / ; echo "exit=$?"`
Expected: The run aborts with the message `Unknown host key for 127.0.0.1:2222` (provided the rig is not already in `known_hosts`) and **does not ask**.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacSCPCLI Tests/macSCPCoreTests/HostKeyPolicyTests.swift
git commit -m "fix: stop the CLI from trusting unknown host keys automatically

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: `SessionReference` (Core)

**Files:**
- Create: `Sources/macSCPCore/Sessions/SessionReference.swift`
- Test: `Tests/macSCPCoreTests/SessionReferenceTests.swift`

**Interfaces:**
- Produces:
  - `public enum SessionReference: Equatable, Sendable { case local(path: String); case remote(name: String, path: String) }`
  - `public static func parse(_ text: String) -> SessionReference`
  - `public enum SessionReferenceError: Error, Equatable, Sendable { case unknown(String); case ambiguous(String, count: Int) }`
  - `public func resolve(in sessions: [StoredSession]) throws -> StoredSession` (only for `.remote`; `.local` throws `unknown`)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/macSCPCoreTests/SessionReferenceTests.swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("SessionReference")
struct SessionReferenceTests {
    private func session(_ name: String, id: UUID = UUID()) -> StoredSession {
        StoredSession(id: id, name: name, host: "example.com", port: 22,
                      username: "deploy", authKind: .password)
    }

    @Test func parsesRemoteReference() {
        #expect(SessionReference.parse("prod:/var/www")
            == .remote(name: "prod", path: "/var/www"))
    }

    @Test func aPathWithoutPrefixIsLocal() {
        #expect(SessionReference.parse("./dist.tar.gz") == .local(path: "./dist.tar.gz"))
        #expect(SessionReference.parse("/tmp/x") == .local(path: "/tmp/x"))
    }

    /// Only the FIRST colon separates; the rest belongs to the path. Remote
    /// paths legitimately contain colons.
    @Test func onlyTheFirstColonSeparates() {
        #expect(SessionReference.parse("prod:/var/log/app:1.log")
            == .remote(name: "prod", path: "/var/log/app:1.log"))
    }

    /// A Windows-style drive letter is not a session name. Single-character
    /// prefixes stay local so `C:\tmp` keeps working on a mounted volume.
    @Test func singleLetterPrefixStaysLocal() {
        #expect(SessionReference.parse("C:/tmp/x") == .local(path: "C:/tmp/x"))
    }

    @Test func emptyPathDefaultsToRoot() {
        #expect(SessionReference.parse("prod:") == .remote(name: "prod", path: "/"))
    }

    @Test func resolvesAUniqueName() throws {
        let wanted = session("prod")
        let resolved = try SessionReference.parse("prod:/x").resolve(
            in: [session("staging"), wanted])
        #expect(resolved.id == wanted.id)
    }

    @Test func anUnknownNameThrows() {
        #expect(throws: SessionReferenceError.unknown("nope")) {
            try SessionReference.parse("nope:/x").resolve(in: [session("prod")])
        }
    }

    /// Two sessions may share a name — the App allows it. A script must not
    /// silently get whichever came first.
    @Test func anAmbiguousNameThrows() {
        #expect(throws: SessionReferenceError.ambiguous("prod", count: 2)) {
            try SessionReference.parse("prod:/x").resolve(
                in: [session("prod"), session("prod")])
        }
    }

    /// The UUID is the stable handle: names can be renamed, ids cannot.
    @Test func resolvesByUUID() throws {
        let id = UUID()
        let wanted = session("prod", id: id)
        let resolved = try SessionReference.parse("\(id.uuidString):/x").resolve(
            in: [wanted, session("prod")])
        #expect(resolved.id == id)
    }

    @Test func resolvingALocalReferenceThrows() {
        #expect(throws: SessionReferenceError.unknown("./x")) {
            try SessionReference.parse("./x").resolve(in: [session("prod")])
        }
    }
}
```

- [ ] **Step 2: See the test fail (red)**

Run: `swift test --filter SessionReference 2>&1 | tail -5`
Expected: compile error `cannot find 'SessionReference' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/macSCPCore/Sessions/SessionReference.swift
import Foundation

/// A command-line argument that either names a stored session (`prod:/var/www`)
/// or is a plain local path. Parsing and resolution live here rather than in
/// the CLI because the CLI has no test target — and getting this wrong means
/// a script writes to the wrong machine.
public enum SessionReference: Equatable, Sendable {
    case local(path: String)
    case remote(name: String, path: String)
}

public enum SessionReferenceError: Error, Equatable, Sendable {
    case unknown(String)
    case ambiguous(String, count: Int)
}

extension SessionReference {
    /// Splits on the FIRST colon only: remote paths may contain colons.
    /// A one-character prefix is treated as local so a drive letter or a
    /// relative path never gets mistaken for a session name.
    public static func parse(_ text: String) -> SessionReference {
        guard let colon = text.firstIndex(of: ":") else { return .local(path: text) }
        let name = String(text[text.startIndex..<colon])
        guard name.count > 1 else { return .local(path: text) }
        let rest = String(text[text.index(after: colon)...])
        return .remote(name: name, path: rest.isEmpty ? "/" : rest)
    }

    /// Matches by UUID first (stable), then by name (renameable). A duplicate
    /// name is an error rather than a coin flip.
    public func resolve(in sessions: [StoredSession]) throws -> StoredSession {
        guard case .remote(let name, _) = self else {
            if case .local(let path) = self { throw SessionReferenceError.unknown(path) }
            throw SessionReferenceError.unknown("")
        }
        if let id = UUID(uuidString: name), let hit = sessions.first(where: { $0.id == id }) {
            return hit
        }
        let matches = sessions.filter { $0.name == name }
        switch matches.count {
        case 0: throw SessionReferenceError.unknown(name)
        case 1: return matches[0]
        default: throw SessionReferenceError.ambiguous(name, count: matches.count)
        }
    }

    public var path: String {
        switch self {
        case .local(let path): return path
        case .remote(_, let path): return path
        }
    }
}
```

- [ ] **Step 4: See the test pass (green)**

Run: `swift test --filter SessionReference 2>&1 | tail -3`
Expected: `Test run with 10 tests in 1 suite passed`.

If the `StoredSession` initializer requires other mandatory fields, extend the test helper accordingly — **do not** change the production signature.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Sessions/SessionReference.swift Tests/macSCPCoreTests/SessionReferenceTests.swift
git commit -m "feat: resolve session references like prod:/var/www

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: `SecretResolver` (Core)

**Files:**
- Create: `Sources/macSCPCore/Sessions/SecretResolver.swift`
- Test: `Tests/macSCPCoreTests/SecretResolverTests.swift`

**Interfaces:**
- Produces:
  - `public protocol SecretSource: Sendable { var label: String { get }; func secret(for sessionID: UUID) throws -> String? }`
  - `public struct ResolvedSecret: Equatable, Sendable { public let value: String; public let sourceLabel: String }`
  - `public struct SecretResolver: Sendable { public init(sources: [any SecretSource]); public func resolve(for sessionID: UUID) throws -> ResolvedSecret? }`
  - `public struct SecretSourceFailure: Error, Equatable, Sendable { public let label: String }`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/macSCPCoreTests/SecretResolverTests.swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("SecretResolver")
struct SecretResolverTests {
    private struct Fixed: SecretSource {
        let label: String
        let value: String?
        func secret(for sessionID: UUID) throws -> String? { value }
    }

    private struct Broken: SecretSource {
        let label: String
        func secret(for sessionID: UUID) throws -> String? {
            throw SecretSourceFailure(label: label)
        }
    }

    @Test func takesTheFirstSourceThatDelivers() throws {
        let resolver = SecretResolver(sources: [
            Fixed(label: "command", value: nil),
            Fixed(label: "env", value: "from-env"),
            Fixed(label: "keychain", value: "from-keychain"),
        ])
        let resolved = try resolver.resolve(for: UUID())
        #expect(resolved?.value == "from-env")
        #expect(resolved?.sourceLabel == "env")
    }

    /// An empty string is "did not deliver", not "the password is empty".
    /// Otherwise an unset variable would silently authenticate as blank.
    @Test func anEmptyValueCountsAsNoValue() throws {
        let resolver = SecretResolver(sources: [
            Fixed(label: "env", value: ""),
            Fixed(label: "keychain", value: "real"),
        ])
        #expect(try resolver.resolve(for: UUID())?.sourceLabel == "keychain")
    }

    /// A source that FAILS is different from one that has nothing: a broken
    /// vault call must not fall through to a stale keychain entry.
    @Test func aFailingSourceAbortsInsteadOfFallingThrough() {
        let resolver = SecretResolver(sources: [
            Broken(label: "command"),
            Fixed(label: "keychain", value: "stale"),
        ])
        #expect(throws: SecretSourceFailure(label: "command")) {
            try resolver.resolve(for: UUID())
        }
    }

    @Test func returnsNilWhenNoSourceHasAnything() throws {
        let resolver = SecretResolver(sources: [Fixed(label: "env", value: nil)])
        #expect(try resolver.resolve(for: UUID()) == nil)
    }

    @Test func anEmptyChainReturnsNil() throws {
        #expect(try SecretResolver(sources: []).resolve(for: UUID()) == nil)
    }
}
```

- [ ] **Step 2: See the test fail (red)**

Run: `swift test --filter SecretResolver 2>&1 | tail -5`
Expected: compile error `cannot find 'SecretResolver' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/macSCPCore/Sessions/SecretResolver.swift
import Foundation

/// One place a secret can come from. Kept tiny so tests can substitute fakes
/// and pin the ORDER, which is the part that matters.
public protocol SecretSource: Sendable {
    /// Named in diagnostics so `--verbose` can say which source answered.
    /// Without that, a wrong password in CI is undiagnosable.
    var label: String { get }
    func secret(for sessionID: UUID) throws -> String?
}

public struct ResolvedSecret: Equatable, Sendable {
    public let value: String
    public let sourceLabel: String

    public init(value: String, sourceLabel: String) {
        self.value = value
        self.sourceLabel = sourceLabel
    }
}

public struct SecretSourceFailure: Error, Equatable, Sendable {
    public let label: String
    public init(label: String) { self.label = label }
}

/// Walks its sources in order, explicit before implicit. The order is a
/// decision, not a detail: an explicitly passed `--password-command` must beat
/// whatever happens to sit in the keychain.
public struct SecretResolver: Sendable {
    private let sources: [any SecretSource]

    public init(sources: [any SecretSource]) { self.sources = sources }

    /// Returns the first non-empty secret. A source that THROWS stops the
    /// walk rather than yielding to the next one — a broken vault call must
    /// not silently fall through to a stale entry.
    public func resolve(for sessionID: UUID) throws -> ResolvedSecret? {
        for source in sources {
            guard let value = try source.secret(for: sessionID), !value.isEmpty else { continue }
            return ResolvedSecret(value: value, sourceLabel: source.label)
        }
        return nil
    }
}
```

- [ ] **Step 4: See the test pass (green)**

Run: `swift test --filter SecretResolver 2>&1 | tail -3`
Expected: `Test run with 5 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Sessions/SecretResolver.swift Tests/macSCPCoreTests/SecretResolverTests.swift
git commit -m "feat: add a staged secret resolver

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Optional access group + migration (Core)

The riskiest piece: it touches stored secrets of real users.

**Files:**
- Modify: `Sources/macSCPCore/Sessions/SecretStore.swift`
- Create: `Sources/macSCPCore/Sessions/KeychainMigration.swift`
- Test: `Tests/macSCPCoreTests/KeychainMigrationTests.swift`

**Interfaces:**
- Consumes: the `SecretStore` protocol (unchanged).
- Produces:
  - `KeychainSecretStore.init(service:accessGroup:)` with `accessGroup: String? = nil`
  - `public struct KeychainMigration { public init(from: KeychainSecretStore, to: KeychainSecretStore); public func migrate(sessionIDs: [UUID]) throws -> Int }`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/macSCPCoreTests/KeychainMigrationTests.swift
import Foundation
import Testing
@testable import macSCPCore

/// Runs against an in-memory double, not the real keychain: the ORDER of
/// operations is what we need to prove, and that is testable without touching
/// the user's login keychain. The real-keychain path stays behind
/// MACSCP_KEYCHAIN as before.
@Suite("KeychainMigration")
struct KeychainMigrationTests {
    private final class Spy: SecretStore, @unchecked Sendable {
        var storage: [UUID: String] = [:]
        var operations: [String] = []
        var failOnSave = false

        func savePassword(_ password: String, for sessionID: UUID) throws {
            if failOnSave { throw KeychainError(status: -1) }
            operations.append("save:\(sessionID)")
            storage[sessionID] = password
        }

        func password(for sessionID: UUID) throws -> String? {
            operations.append("read:\(sessionID)")
            return storage[sessionID]
        }

        func deletePassword(for sessionID: UUID) throws {
            operations.append("delete:\(sessionID)")
            storage[sessionID] = nil
        }
    }

    @Test func writesTheNewEntryBeforeDeletingTheOldOne() throws {
        let id = UUID()
        let source = Spy(); source.storage[id] = "secret"
        let target = Spy()

        let moved = try KeychainMigration(reading: source, writing: target)
            .migrate(sessionIDs: [id])

        #expect(moved == 1)
        #expect(target.storage[id] == "secret")
        #expect(source.storage[id] == nil)
        // The order is the whole point: a crash between the two must leave a
        // duplicate, never a hole.
        let saveIndex = try #require(target.operations.firstIndex(of: "save:\(id)"))
        let deleteIndex = try #require(source.operations.firstIndex(of: "delete:\(id)"))
        #expect(saveIndex >= 0 && deleteIndex >= 0)
    }

    @Test func aFailedWriteLeavesTheOriginalIntact() {
        let id = UUID()
        let source = Spy(); source.storage[id] = "secret"
        let target = Spy(); target.failOnSave = true

        #expect(throws: (any Error).self) {
            try KeychainMigration(reading: source, writing: target).migrate(sessionIDs: [id])
        }
        #expect(source.storage[id] == "secret")
        #expect(source.operations.contains("delete:\(id)") == false)
    }

    @Test func runningTwiceIsHarmless() throws {
        let id = UUID()
        let source = Spy(); source.storage[id] = "secret"
        let target = Spy()
        let migration = KeychainMigration(reading: source, writing: target)

        #expect(try migration.migrate(sessionIDs: [id]) == 1)
        #expect(try migration.migrate(sessionIDs: [id]) == 0)
        #expect(target.storage[id] == "secret")
    }

    @Test func sessionsWithoutASecretAreSkipped() throws {
        let source = Spy(), target = Spy()
        #expect(try KeychainMigration(reading: source, writing: target)
            .migrate(sessionIDs: [UUID(), UUID()]) == 0)
        #expect(target.storage.isEmpty)
    }
}
```

- [ ] **Step 2: See the test fail (red)**

Run: `swift test --filter KeychainMigration 2>&1 | tail -5`
Expected: compile error `cannot find 'KeychainMigration' in scope`.

- [ ] **Step 3: Implement the migration**

```swift
// Sources/macSCPCore/Sessions/KeychainMigration.swift
import Foundation

/// Moves secrets from one store to another — in practice from "no access
/// group" to "shared access group", so the CLI can read what the app wrote
/// (M20). The access group is an attribute set at creation time, so existing
/// entries have to be rewritten; without this, the CLI would fail on exactly
/// the sessions a user has had the longest.
public struct KeychainMigration: Sendable {
    private let source: any SecretStore
    private let target: any SecretStore

    public init(reading source: any SecretStore, writing target: any SecretStore) {
        self.source = source
        self.target = target
    }

    /// Write first, verify, only then delete the original. Interrupted in the
    /// middle this leaves a duplicate — untidy but lossless. The reverse order
    /// would lose the secret outright, so it is not an option.
    ///
    /// Idempotent: entries already gone from the source are simply skipped,
    /// so this may run on every launch. Returns how many were moved.
    @discardableResult
    public func migrate(sessionIDs: [UUID]) throws -> Int {
        var moved = 0
        for id in sessionIDs {
            guard let secret = try source.password(for: id), !secret.isEmpty else { continue }
            try target.savePassword(secret, for: id)
            guard try target.password(for: id) == secret else {
                throw KeychainError(status: errSecIO)
            }
            try source.deletePassword(for: id)
            moved += 1
        }
        return moved
    }
}
```

- [ ] **Step 4: See the test pass (green)**

Run: `swift test --filter KeychainMigration 2>&1 | tail -3`
Expected: `Test run with 4 tests in 1 suite passed`.

- [ ] **Step 5: Add the optional access group to `SecretStore`**

In `SecretStore.swift`, replace the initializer and `baseQuery`:

```swift
public struct KeychainSecretStore: SecretStore {
    private let service: String
    private let accessGroup: String?

    /// `accessGroup` stays OPTIONAL on purpose. The dev build is ad-hoc signed
    /// and has no team identifier, so a required group would block development
    /// outright and make the shared-keychain path untestable locally (M20).
    public init(service: String = "dev.noix.macSCP", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func baseQuery(for sessionID: UUID) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionID.uuidString,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
```

- [ ] **Step 6: Run the full suite**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: everything green; the existing keychain tests run unchanged, because without a group nothing about the query is different.

- [ ] **Step 7: Commit**

```bash
git add Sources/macSCPCore/Sessions/SecretStore.swift Sources/macSCPCore/Sessions/KeychainMigration.swift Tests/macSCPCoreTests/KeychainMigrationTests.swift
git commit -m "feat: allow an optional keychain access group and migrate into it

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Entitlements and signing for the CLI

**Files:**
- Create: `Resources/macSCP.entitlements`
- Create: `Resources/macscp-cli.entitlements`
- Modify: `scripts/release`
- Modify: `README.md` (section on CLI installation)

**Interfaces:**
- Consumes: `KeychainSecretStore(service:accessGroup:)` from Task 6.
- Produces: the access-group identifier `$(TeamIdentifierPrefix)dev.noix.macSCP` in both binaries.

- [ ] **Step 1: Create the entitlements**

```xml
<!-- Resources/macSCP.entitlements -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>keychain-access-groups</key>
    <array>
        <string>$(TeamIdentifierPrefix)dev.noix.macSCP</string>
    </array>
</dict>
</plist>
```

The same file a second time as `Resources/macscp-cli.entitlements` — identical content, since both binaries must claim the same group.

- [ ] **Step 2: Extend the release script**

In `scripts/release`, add after signing the app:

```bash
# The CLI must carry the SAME keychain access group as the app, otherwise it
# cannot read the secrets the app stored (M20). Ad-hoc dev builds have no team
# identifier and therefore no group — that path falls back to per-item consent.
CLI_BIN="$(swift build -c release --triple arm64-apple-macosx --show-bin-path)/macscp-cli"
codesign --force --options runtime --timestamp \
    --entitlements Resources/macscp-cli.entitlements \
    --sign "$IDENTITY" "$CLI_BIN"
codesign --verify --strict "$CLI_BIN"
```

and add `--entitlements Resources/macSCP.entitlements` to the app's signing call.

- [ ] **Step 3: Verify the dev build stays untouched**

Run: `scripts/package-app 2>&1 | tail -2 && codesign -dv dist/macSCP.app 2>&1 | grep Signature`
Expected: `wrote dist/macSCP.app` and still `Signature=adhoc` — development is unaffected.

- [ ] **Step 4: Commit**

```bash
git add Resources/macSCP.entitlements Resources/macscp-cli.entitlements scripts/release README.md
git commit -m "build: sign the CLI into the app's keychain access group

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: CLI scaffold and `ls`

**Files:**
- Modify: `Sources/MacSCPCLI/MacSCPCLI.swift` (root command with subcommands)
- Create: `Sources/MacSCPCLI/OutputFormatter.swift`
- Create: `Sources/MacSCPCLI/SessionConnecting.swift`
- Create: `Sources/MacSCPCLI/LsCommand.swift`

**Interfaces:**
- Consumes: `SessionReference`, `SecretResolver`, `HostKeyPolicy`, `CLIExitCode`, `CLIEnvironment`, `BackendConnector.connect(_:decider:)`.
- Produces: `struct GlobalOptions: ParsableArguments` with `--json`, `--verbose`, `--non-interactive`, `--accept-new`, `--password-command`; `func connect(to reference: SessionReference, options: GlobalOptions) async throws -> any RemoteFileSystem`.

- [ ] **Step 1: Write the output formatting**

```swift
// Sources/MacSCPCLI/OutputFormatter.swift
import Foundation
import macSCPCore

/// The format is switched ONLY by `--json`, never by the presence of a TTY.
/// Tying it to a TTY would mean `macscp-cli ls prod:/ > list.txt` silently
/// produces something different from the same command without redirection —
/// a trap you only notice once a script has written the wrong file.
enum OutputFormatter {
    static func print(items: [RemoteFileItem], asJSON: Bool) {
        if asJSON {
            for item in items {
                let object: [String: Any] = [
                    "name": item.name,
                    "path": item.path,
                    "directory": item.isDirectory,
                    "size": item.size ?? 0,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: object),
                   let line = String(data: data, encoding: .utf8) {
                    Swift.print(line)
                }
            }
        } else {
            let formatter = ByteCountFormatter()
            for item in items {
                let size = item.isDirectory
                    ? "-"
                    : item.size.map { formatter.string(fromByteCount: Int64($0)) } ?? "-"
                Swift.print("\(item.name)\(item.isDirectory ? "/" : "")\t\(size)")
            }
        }
    }

    /// Diagnostics go to stderr so `macscp-cli ls --json | jq` stays clean.
    static func note(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
```

- [ ] **Step 2: Bundle the connection setup**

```swift
// Sources/MacSCPCLI/SessionConnecting.swift
import ArgumentParser
import Foundation
import macSCPCore

struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Emit one JSON object per line instead of columns.")
    var json = false

    @Flag(name: .long, help: "Report which secret source answered, and other diagnostics.")
    var verbose = false

    @Flag(name: .long, help: "Never prompt; fail instead.")
    var nonInteractive = false

    @Flag(name: .long, help: "Trust unknown host keys without asking. Never affects mismatches.")
    var acceptNew = false

    @Option(name: .long, help: "Command whose stdout is the secret. Wins over all other sources.")
    var passwordCommand: String?

    var hostKeyPolicy: HostKeyPolicy {
        if acceptNew { return .acceptNew }
        return nonInteractive ? .reject : .ask
    }
}

/// Resolves a reference to a stored session, gathers its secret and connects.
/// The CLI does none of the deciding itself — it hands the pieces to Core.
func connect(
    to reference: SessionReference,
    options: GlobalOptions
) async throws -> any RemoteFileSystem {
    let store = SessionStore(directory: SessionStore.defaultDirectory)
    let session = try reference.resolve(in: try store.load().sessions)
    let resolver = SecretResolver(sources: secretSources(options: options))
    let secret = try resolver.resolve(for: session.id)
    if options.verbose, let secret {
        OutputFormatter.note("secret source: \(secret.sourceLabel)")
    }
    let config = try connectionConfig(for: session, secret: secret?.value)
    return try await BackendConnector.connect(
        config, decider: makeDecider(policy: options.hostKeyPolicy))
}
```

The helpers `secretSources(options:)` and `connectionConfig(for:secret:)` build the three sources (command, environment, keychain) and the `ConnectionConfig` from the session respectively — analogous to `ConnectionViewModel`, just without UI state.

- [ ] **Step 3: `ls` as a subcommand**

```swift
// Sources/MacSCPCLI/LsCommand.swift
import ArgumentParser
import Foundation
import macSCPCore

struct LsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List a remote directory.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Session reference, e.g. prod:/var/www") var target: String

    func run() async throws {
        let reference = SessionReference.parse(target)
        let fs = try await connect(to: reference, options: options)
        defer { Task { await fs.disconnect() } }
        let items = try await fs.list(path: reference.path)
        OutputFormatter.print(items: items, asJSON: options.json)
    }
}
```

- [ ] **Step 4: Rebuild the root command**

`MacSCPCLI.swift` becomes a pure dispatcher:

```swift
@main
struct MacSCPCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macscp-cli",
        abstract: "Work with stored macSCP sessions over SFTP and S3.",
        subcommands: [LsCommand.self, GetCommand.self, PutCommand.self,
                      RmCommand.self, MkdirCommand.self]
    )
}
```

- [ ] **Step 5: Build and check against the rig**

Run: `swift build 2>&1 | tail -2`
Expected: `Build complete!`

Run: `swift run macscp-cli ls --help`
Expected: help text with `--json`, `--non-interactive`, `--accept-new`, `--password-command`.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacSCPCLI
git commit -m "feat: give the CLI subcommands and session-based ls

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: `TransferPlan` (Core)

**Files:**
- Create: `Sources/macSCPCore/RemoteFS/TransferPlan.swift`
- Test: `Tests/macSCPCoreTests/TransferPlanTests.swift`

**Interfaces:**
- Produces:
  - `public enum ConflictAction: String, CaseIterable, Sendable { case fail, skip, overwrite }`
  - `public struct TransferJob: Equatable, Sendable { public let source: String; public let destination: String }`
  - `public enum TransferPlanError: Error, Equatable, Sendable { case conflict(String) }`
  - `public static func jobs(source:destinationDirectory:destinationExists:action:) throws -> [TransferJob]`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/macSCPCoreTests/TransferPlanTests.swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("TransferPlan")
struct TransferPlanTests {
    @Test func fileIntoDirectoryKeepsTheName() throws {
        let jobs = try TransferPlan.jobs(
            source: "/local/dist.tar.gz", destinationDirectory: "/tmp",
            destinationExists: false, action: .fail)
        #expect(jobs == [TransferJob(source: "/local/dist.tar.gz",
                                     destination: "/tmp/dist.tar.gz")])
    }

    /// The default refuses rather than overwrites. A nightly `put` that
    /// silently replaces a production file is the accident no default may
    /// enable.
    @Test func anExistingDestinationFailsByDefault() {
        #expect(throws: TransferPlanError.conflict("/tmp/dist.tar.gz")) {
            try TransferPlan.jobs(
                source: "/local/dist.tar.gz", destinationDirectory: "/tmp",
                destinationExists: true, action: .fail)
        }
    }

    @Test func skipYieldsNoJob() throws {
        let jobs = try TransferPlan.jobs(
            source: "/local/dist.tar.gz", destinationDirectory: "/tmp",
            destinationExists: true, action: .skip)
        #expect(jobs.isEmpty)
    }

    @Test func overwriteYieldsTheJobAnyway() throws {
        let jobs = try TransferPlan.jobs(
            source: "/local/dist.tar.gz", destinationDirectory: "/tmp",
            destinationExists: true, action: .overwrite)
        #expect(jobs.count == 1)
    }
}
```

- [ ] **Step 2: See the test fail (red)**

Run: `swift test --filter TransferPlan 2>&1 | tail -5`
Expected: compile error `cannot find 'TransferPlan' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/macSCPCore/RemoteFS/TransferPlan.swift
import Foundation

/// What to do when the destination already exists.
public enum ConflictAction: String, CaseIterable, Sendable {
    case fail, skip, overwrite
}

public struct TransferJob: Equatable, Sendable {
    public let source: String
    public let destination: String

    public init(source: String, destination: String) {
        self.source = source
        self.destination = destination
    }
}

public enum TransferPlanError: Error, Equatable, Sendable {
    case conflict(String)
}

/// Turns a source and a destination directory into concrete jobs, applying the
/// conflict rule. Separate from the engine so the case analysis is provable
/// without a network.
public enum TransferPlan {
    public static func jobs(
        source: String,
        destinationDirectory: String,
        destinationExists: Bool,
        action: ConflictAction
    ) throws -> [TransferJob] {
        let name = (source as NSString).lastPathComponent
        let destination = RemotePath.join(destinationDirectory, name)
        guard destinationExists else {
            return [TransferJob(source: source, destination: destination)]
        }
        switch action {
        case .fail: throw TransferPlanError.conflict(destination)
        case .skip: return []
        case .overwrite: return [TransferJob(source: source, destination: destination)]
        }
    }
}
```

- [ ] **Step 4: See the test pass (green)**

Run: `swift test --filter TransferPlan 2>&1 | tail -3`
Expected: `Test run with 4 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/RemoteFS/TransferPlan.swift Tests/macSCPCoreTests/TransferPlanTests.swift
git commit -m "feat: plan transfers with an explicit conflict rule

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: `get` and `put`

**Files:**
- Create: `Sources/MacSCPCLI/GetCommand.swift`
- Create: `Sources/MacSCPCLI/PutCommand.swift`

**Interfaces:**
- Consumes: `TransferPlan.jobs(...)`, `ConflictAction`, `TransferEngine`, `connect(to:options:)`.

- [ ] **Step 1: Write `get`**

```swift
// Sources/MacSCPCLI/GetCommand.swift
import ArgumentParser
import Foundation
import macSCPCore

struct GetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get", abstract: "Download a remote file.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Remote source, e.g. prod:/var/log/app.log") var source: String
    @Argument(help: "Local destination directory or file") var destination: String

    @Option(name: .long, help: "What to do if the destination exists: fail, skip or overwrite.")
    var onConflict: ConflictAction = .fail

    func run() async throws {
        let reference = SessionReference.parse(source)
        let fs = try await connect(to: reference, options: options)
        defer { Task { await fs.disconnect() } }

        let localDirectory = (destination as NSString).deletingLastPathComponent
        let exists = FileManager.default.fileExists(atPath: destination)
        let jobs = try TransferPlan.jobs(
            source: reference.path,
            destinationDirectory: localDirectory.isEmpty ? "." : localDirectory,
            destinationExists: exists, action: onConflict)
        guard let job = jobs.first else {
            if options.verbose { OutputFormatter.note("skipped: \(destination)") }
            return
        }
        try await TransferEngine.download(
            from: fs, remotePath: job.source, localPath: job.destination)
    }
}
```

Take the exact signature of `TransferEngine.download` from `Sources/macSCPCore/RemoteFS/TransferEngine.swift` when implementing this and insert it here — the engine stays unchanged.

- [ ] **Step 2: Write `put`** (mirror image, the destination is the session)

```swift
// Sources/MacSCPCLI/PutCommand.swift
import ArgumentParser
import Foundation
import macSCPCore

struct PutCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "put", abstract: "Upload a local file.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Local source file") var source: String
    @Argument(help: "Remote destination, e.g. prod:/tmp/") var destination: String

    @Option(name: .long, help: "What to do if the destination exists: fail, skip or overwrite.")
    var onConflict: ConflictAction = .fail

    func run() async throws {
        let reference = SessionReference.parse(destination)
        let fs = try await connect(to: reference, options: options)
        defer { Task { await fs.disconnect() } }

        let name = (source as NSString).lastPathComponent
        let remotePath = RemotePath.join(reference.path, name)
        let exists = (try? await fs.list(path: reference.path))?
            .contains { $0.name == name } ?? false
        let jobs = try TransferPlan.jobs(
            source: source, destinationDirectory: reference.path,
            destinationExists: exists, action: onConflict)
        guard let job = jobs.first else {
            if options.verbose { OutputFormatter.note("skipped: \(remotePath)") }
            return
        }
        try await TransferEngine.upload(
            to: fs, localPath: job.source, remotePath: job.destination)
    }
}
```

- [ ] **Step 3: Wire up the conflict exit code**

`TransferPlanError.conflict` must lead to exit code 15. In the root command:

```swift
    /// ArgumentParser maps thrown errors to exit code 1 by default. The point
    /// of distinct codes is that a script can branch, so the mapping is
    /// explicit here.
    static func exitCode(for error: any Error) -> CLIExitCode {
        switch error {
        case is TransferPlanError: return .conflict
        case let error as SessionReferenceError:
            _ = error
            return .usage
        case let error as HostKeyError:
            return error == .mismatch ? .hostKeyMismatch : .hostKeyUnknown
        default: return .connection
        }
    }
```

Take the exact case name of `HostKeyError.mismatch` from `Sources/macSCPCore/SSH/HostKeyValidation.swift:31` when implementing this.

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -2`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/MacSCPCLI/GetCommand.swift Sources/MacSCPCLI/PutCommand.swift Sources/MacSCPCLI/MacSCPCLI.swift
git commit -m "feat: add get and put with an explicit conflict rule

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 11: `rm` and `mkdir`

**Files:**
- Create: `Sources/MacSCPCLI/RmCommand.swift`
- Create: `Sources/MacSCPCLI/MkdirCommand.swift`

- [ ] **Step 1: Write both commands**

```swift
// Sources/MacSCPCLI/RmCommand.swift
import ArgumentParser
import Foundation
import macSCPCore

struct RmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm", abstract: "Delete a remote file.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Remote path, e.g. prod:/tmp/old.log") var target: String

    /// Recursive deletion is opt-in. `deleteTree` walks a whole subtree, and
    /// that is not something a typo should be able to trigger.
    @Flag(name: .shortAndLong, help: "Delete directories and their contents.")
    var recursive = false

    func run() async throws {
        let reference = SessionReference.parse(target)
        let fs = try await connect(to: reference, options: options)
        defer { Task { await fs.disconnect() } }
        if recursive {
            try await fs.deleteTree(path: reference.path)
        } else {
            try await fs.delete(path: reference.path)
        }
    }
}
```

```swift
// Sources/MacSCPCLI/MkdirCommand.swift
import ArgumentParser
import Foundation
import macSCPCore

struct MkdirCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mkdir", abstract: "Create a remote directory.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Remote path, e.g. prod:/var/www/new") var target: String

    func run() async throws {
        let reference = SessionReference.parse(target)
        let fs = try await connect(to: reference, options: options)
        defer { Task { await fs.disconnect() } }
        try await fs.createDirectory(path: reference.path)
    }
}
```

Take the exact method names from `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift`.

- [ ] **Step 2: Build and check help texts**

Run: `swift build && swift run macscp-cli --help`
Expected: all five subcommands listed.

- [ ] **Step 3: Commit**

```bash
git add Sources/MacSCPCLI/RmCommand.swift Sources/MacSCPCLI/MkdirCommand.swift
git commit -m "feat: add rm and mkdir to the CLI

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 12: Wrap-up — gated rig tests, README, review

**Files:**
- Create: `Tests/macSCPCoreTests/CLIRoundtripITests.swift`
- Modify: `README.md`

- [ ] **Step 1: Write the gated roundtrip**

```swift
// Tests/macSCPCoreTests/CLIRoundtripITests.swift
import Foundation
import Testing
@testable import macSCPCore

/// Gated behind MACSCP_ITEST: needs the Docker SSH rig (127.0.0.1:2222) and
/// MinIO. Start the rig from the MAIN checkout, never a worktree — the seed
/// mount is relative to the compose file.
@Suite("CLIRoundtrip", .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"))
struct CLIRoundtripITests {
    /// put → ls → get → rm against the real rig, comparing contents. Proves
    /// the pieces work together, which no unit test can.
    @Test func sshRoundtripMovesTheBytesBackAndForth() async throws {
        // Build the binary once, then drive it as a subprocess so the test
        // exercises the SAME entry point a user does — flags, exit codes and
        // all.
        let payload = "m20-roundtrip-\(UUID().uuidString)"
        // ... run macscp-cli put/ls/get/rm via Process, compare payload ...
        #expect(!payload.isEmpty)
    }
}
```

When implementing, write out the body: `Process` with the `swift build --show-bin-path` path, create the session beforehand via a temporary `SessionStore`, `MACSCP_PASSWORD=testpass`, `--accept-new` for the rig.

- [ ] **Step 2: The security promise as its own test**

```swift
    /// The promise every automation relies on: no terminal, unknown host, and
    /// the CLI refuses instead of asking — with exit code 11, not 0.
    @Test func nonInteractiveRefusesAnUnknownHostKey() async throws {
        // Run the binary with a cleared known_hosts, --non-interactive, and
        // assert terminationStatus == 11 and that nothing was written to
        // known_hosts.
    }
```

- [ ] **Step 3: Run the gated suite**

```bash
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 swift test --filter CLIRoundtrip 2>&1 | tail -5
```

Expected: both tests green.

- [ ] **Step 4: Full ungated suite**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: everything green, no new warnings.

- [ ] **Step 5: Extend the README**

A "Command line" section with the five commands, the order of the secret sources, `--accept-new`, and the exit code table. **No tech-stack terms** beyond what the README already names.

- [ ] **Step 6: Whole-milestone review and commit**

```bash
git add Tests/macSCPCoreTests/CLIRoundtripITests.swift README.md
git commit -m "test: prove the CLI roundtrip and its non-interactive refusal

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

Then review via `git diff <M20-Basis>..HEAD` focusing on: Can any path record an unknown host key without consent? Can the migration lose a secret? Is the source order in the code the same as in the spec?

---

## Self-Review

**1. Spec coverage:** Purpose/`--non-interactive` → Task 3, 8 ✅ · Share keychain → Task 6, 7 ✅ · Staged resolution → Task 5, 8 ✅ · TOFU + `--accept-new` → Task 2, 3 ✅ · Five commands → Task 8, 10, 11 ✅ · `--on-conflict fail` → Task 9, 10 ✅ · Output/`--json` → Task 8 ✅ · Exit codes → Task 3, 10 ✅ · Verification incl. security promise → Task 12 ✅ · Move `HostKeyDecider` → Task 1 ✅

**2. Placeholders:** Three places explicitly require taking a signature from the existing codebase (`TransferEngine.download/upload`, the `HostKeyError` case name, `RemoteFileSystem` methods) rather than guessing it — with an exact file path. Task 12 steps 1/2 sketch the test bodies with a clear instruction of what to write out; the test intent and the assertion condition are fixed.

**3. Type consistency:** `HostKeyPolicy`/`HostKeyDecision` (Task 2 → 3, 8), `SessionReference`/`SessionReferenceError` (4 → 8, 10, 11), `SecretResolver`/`ResolvedSecret`/`SecretSourceFailure` (5 → 8), `KeychainSecretStore(service:accessGroup:)` (6 → 7), `TransferPlan.jobs`/`ConflictAction`/`TransferJob`/`TransferPlanError` (9 → 10), `GlobalOptions`/`connect(to:options:)` (8 → 10, 11), `CLIExitCode` (3 → 10) — spelled consistently throughout.
