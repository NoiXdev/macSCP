# P3g — The Password Hint No Longer Holds a Secret

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `pendingPasswordHintRequest` no longer holds plaintext secrets for
as long as the password hint is open — because the retained configuration
loses them at creation time, not because a further cleanup path deletes
them later.

**Architecture:** A measurement taken before planning corrected the spec's
premise: **no consumer of the retained configuration reads a secret.**
`ExternalTerminalLauncher.open` passes it on exclusively to
`SSHCommandBuilder.scriptContents(for:)`, which, per its own doc comment
and as verified by its code, reads only host, port, username, key *path*,
and jump target — never a password, never a passphrase. The launch script
thus contains no secret at all; that is exactly what the hint text itself
says ("macSCP can't hand a saved password to an external terminal — ssh
will ask you for it there").

That yields a smaller and sharper fix than the spec assumed: instead of
building a third cleanup path that future changes would have to maintain,
`ExternalTerminalRequest` gets an initializer that stores the configuration
already redacted. The state "hint open **and** password in view state" is
thereby not cleaned up, but made impossible.

Task 1 puts the redaction in Core (where it is testable), Task 2 wires it
at the one call site and corrects a doc comment that claims the opposite
of the truth.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, Swift Testing.

## Global Constraints

- Code, comments, identifiers, test names: **English only.**
- A secret must **never** be printed, logged, or embedded in a message —
  not even in a test failure message. `#expect` expands its expression:
  hoist into a `Bool` first, then check.
- Never write a line number into a comment.
- No doc comment claims something the code does not do.
- Commit footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Conventional Commits.
- Tests: TDD red→green. `swift test` must be green at the end of every
  task.

---

### Task 1: `SSHConnectionConfig.redactingSecrets()` (Core)

**Files:**
- Modify: `Sources/macSCPCore/SSH/SSHConnectionConfig.swift`
- Test: `Tests/macSCPCoreTests/SSHConnectionConfigRedactionTests.swift` (new)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `public func redactingSecrets() -> SSHConnectionConfig` on
  `SSHConnectionConfig`. Task 2 calls exactly this method.

**Why a private, non-throwing initializer:** The public initializer throws
because it validates externally supplied values. A derivation from an
already-validated configuration is not external input: every field passes
through unchanged, except the secret payloads, which no validation rule
touches. `try!` here would be a crash risk for no benefit, `try?` with
`?? self` would silently return the **unredacted** configuration on
failure — the worst possible failure direction. The private initializer
is the honest third way; because it is private, the throwing initializer
remains the one gate for external values.

- [ ] **Step 1: Write the failing tests**

New file `Tests/macSCPCoreTests/SSHConnectionConfigRedactionTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("SSHConnectionConfig redaction")
struct SSHConnectionConfigRedactionTests {
    @Test func passwordPayloadIsEmptiedButTheCaseSurvives() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", username: "tim", auth: .password("hunter2"))

        // Hoisted into a Bool on purpose: `#expect` expands its receiver,
        // and an expanded auth value must never be able to carry a secret
        // into a failure message.
        let isEmptiedPassword: Bool
        if case .password(let value) = config.redactingSecrets().auth {
            isEmptiedPassword = value.isEmpty
        } else {
            isEmptiedPassword = false
        }
        #expect(isEmptiedPassword)
    }

    @Test func privateKeyKeepsItsPathAndLosesItsPassphrase() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", username: "tim",
            auth: .privateKey(keyPath: "/keys/id_ed25519", passphrase: "hunter2"))

        let keepsPathWithoutPassphrase: Bool
        if case .privateKey(let keyPath, let passphrase) = config.redactingSecrets().auth {
            keepsPathWithoutPassphrase = keyPath == "/keys/id_ed25519" && passphrase == nil
        } else {
            keepsPathWithoutPassphrase = false
        }
        #expect(keepsPathWithoutPassphrase)
    }

    @Test func agentAuthIsUnchanged() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", username: "tim", auth: .agent)
        #expect(config.redactingSecrets().auth == .agent)
    }

    @Test func theJumpHopIsRedactedToo() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", username: "tim", auth: .agent,
            jump: SSHConnectionConfig.Jump(
                host: "bastion.example.com", port: 2222, username: "hop",
                auth: .password("hunter2")))

        let jump = config.redactingSecrets().jump
        let isEmptiedJumpPassword: Bool
        if case .password(let value) = jump?.auth {
            isEmptiedJumpPassword = value.isEmpty
        } else {
            isEmptiedJumpPassword = false
        }
        #expect(isEmptiedJumpPassword)
        #expect(jump?.host == "bastion.example.com")
        #expect(jump?.port == 2222)
        #expect(jump?.username == "hop")
    }

    @Test func everyNonSecretFieldSurvives() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", port: 2200, username: "tim", auth: .password("hunter2"))
        let redacted = config.redactingSecrets()

        #expect(redacted.host == "example.com")
        #expect(redacted.port == 2200)
        #expect(redacted.username == "tim")
    }

    /// The property that actually matters for the one caller: redaction
    /// changes nothing the external-terminal path can observe, because that
    /// path never reads a secret in the first place.
    @Test func theGeneratedScriptIsUnchangedByRedaction() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", port: 2200, username: "tim",
            auth: .privateKey(keyPath: "/keys/id_ed25519", passphrase: "hunter2"),
            jump: SSHConnectionConfig.Jump(
                host: "bastion.example.com", port: 2222, username: "hop",
                auth: .password("hunter2")))

        #expect(
            SSHCommandBuilder.scriptContents(for: config.redactingSecrets())
                == SSHCommandBuilder.scriptContents(for: config))
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "SSHConnectionConfig redaction"`
Expected: FAIL — `value of type 'SSHConnectionConfig' has no member 'redactingSecrets'`.

- [ ] **Step 3: Implement**

In `Sources/macSCPCore/SSH/SSHConnectionConfig.swift`, **inside** the
`struct SSHConnectionConfig` declaration (not in an extension — the
private initializer must stay reachable from the method), directly after
the existing throwing `init`:

```swift
    /// Non-throwing initializer for values DERIVED from an already-valid
    /// config. It skips validation deliberately: every stored field either
    /// comes through unchanged from a value the throwing init already
    /// validated, or is a secret payload that no validation rule inspects.
    /// Private, so the throwing init stays the ONE gate for externally
    /// supplied values.
    private init(validatedHost host: String, port: Int, username: String, auth: AuthMethod, jump: Jump?) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.jump = jump
    }

    /// A copy with every plaintext secret emptied, for the one situation
    /// where a config must outlive the call that resolved it: the
    /// external-terminal password hint holds one in view state while its
    /// alert is open, and neither `disconnect` nor
    /// `ConnectionViewModel.clearRetainedSecrets()` reaches view state.
    ///
    /// Nothing is lost by handing the redacted copy to that path:
    /// `SSHCommandBuilder` reads only host, port, username, key *path* and
    /// jump destination, and passes no secret to `ssh` at all (see its own
    /// doc comment) — `ssh` prompts for the password itself.
    public func redactingSecrets() -> SSHConnectionConfig {
        SSHConnectionConfig(
            validatedHost: host, port: port, username: username,
            auth: auth.redactingSecret(),
            jump: jump.map {
                Jump(
                    host: $0.host, port: $0.port, username: $0.username,
                    auth: $0.auth.redactingSecret())
            })
    }
```

And at the end of the same file, at file scope:

```swift
extension SSHConnectionConfig.AuthMethod {
    /// Empties the plaintext payload while keeping the case itself: callers
    /// branch on WHICH method a config uses (`if case .password`), so
    /// erasing the case would change behaviour, whereas erasing the payload
    /// cannot — only the dialer ever reads it.
    fileprivate func redactingSecret() -> SSHConnectionConfig.AuthMethod {
        switch self {
        case .password:
            return .password("")
        case .privateKey(let keyPath, _):
            return .privateKey(keyPath: keyPath, passphrase: nil)
        case .agent:
            return .agent
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "SSHConnectionConfig redaction"`
Expected: PASS (6 tests).

Then the full suite: `swift test` — must be green.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/SSH/SSHConnectionConfig.swift Tests/macSCPCoreTests/SSHConnectionConfigRedactionTests.swift
git commit -m "feat(core): derive a config copy without plaintext secrets"
```

---

### Task 2: The hint stores the configuration redacted (App)

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView.swift`
- Test: `Tests/macSCPAppKitTests/ExternalTerminalRequestRedactionTests.swift` (new)

**Interfaces:**
- Consumes: `SSHConnectionConfig.redactingSecrets()` from Task 1.
- Produces: nothing for later tasks (this is the last task).

**Context:** `ContentView.ExternalTerminalRequest` is a `struct` with three
`let` fields and **no** own initializer — it currently uses the memberwise
initializer. Test access goes through
`@testable import MacSCPAppKit`; `ContentView` is `internal`, making the
nested struct visible to the test target.

- [ ] **Step 1: Write the failing test**

New file `Tests/macSCPAppKitTests/ExternalTerminalRequestRedactionTests.swift`:

```swift
import Foundation
import Testing
import macSCPCore
@testable import MacSCPAppKit

/// The password hint is the one place in the app where a resolved config
/// outlives the call that produced it. It must not carry a secret while it
/// waits: view state is reached by neither `disconnect` nor
/// `clearRetainedSecrets`.
///
/// `@MainActor` mirrors `ExternalTerminalLauncherTests`: `ContentView` is a
/// SwiftUI `View`, and its main-actor isolation is the kind of thing that
/// makes synchronous call sites in a non-isolated suite fail to compile.
/// Marking the suite costs nothing if the isolation turns out not to reach
/// the nested type.
@Suite("ExternalTerminalRequest redaction")
@MainActor
struct ExternalTerminalRequestRedactionTests {
    @Test func theRetainedConfigCarriesNoPassword() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", username: "tim", auth: .password("hunter2"))

        let request = ContentView.ExternalTerminalRequest(
            config: config, target: .terminalApp, customPath: nil)

        // Hoisted into a Bool: `#expect` expands its receiver, and no
        // expansion may be able to print a password.
        let isEmptiedPassword: Bool
        if case .password(let value) = request.config.auth {
            isEmptiedPassword = value.isEmpty
        } else {
            isEmptiedPassword = false
        }
        #expect(isEmptiedPassword)
    }

    @Test func theRetainedConfigCarriesNoKeyPassphrase() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", username: "tim",
            auth: .privateKey(keyPath: "/keys/id_ed25519", passphrase: "hunter2"))

        let request = ContentView.ExternalTerminalRequest(
            config: config, target: .terminalApp, customPath: nil)

        let hasNoPassphrase: Bool
        if case .privateKey(_, let passphrase) = request.config.auth {
            hasNoPassphrase = passphrase == nil
        } else {
            hasNoPassphrase = false
        }
        #expect(hasNoPassphrase)
    }

    @Test func everythingTheLauncherNeedsSurvives() throws {
        let config = try SSHConnectionConfig(
            host: "example.com", port: 2200, username: "tim", auth: .password("hunter2"))

        let request = ContentView.ExternalTerminalRequest(
            config: config, target: .custom, customPath: "/Applications/Ghostty.app")

        #expect(request.config.host == "example.com")
        #expect(request.config.port == 2200)
        #expect(request.config.username == "tim")
        #expect(request.target == .custom)
        #expect(request.customPath == "/Applications/Ghostty.app")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter "ExternalTerminalRequest redaction"`
Expected: FAIL — the first and second tests fail because the memberwise
initializer stores the configuration unchanged.

(`TerminalTarget` lives in `Sources/macSCPCore/Settings/TerminalTarget.swift`
and has the cases `builtIn`, `terminalApp`, `iTerm`, `custom` — the test
uses two of them and is supplied via `import macSCPCore`.)

- [ ] **Step 3: Implement**

In `Sources/MacSCPAppKit/ContentView.swift`, add an initializer to the
struct (the three `let` fields stay unchanged):

```swift
    struct ExternalTerminalRequest {
        let config: SSHConnectionConfig
        let target: TerminalTarget
        let customPath: String?

        /// Stores the config with its plaintext secrets emptied.
        ///
        /// The launch path reads none of them — `SSHCommandBuilder` passes
        /// no secret to `ssh`, which is exactly what the hint tells the
        /// user — so holding one here would buy nothing and cost a
        /// plaintext password sitting in view state for as long as the
        /// alert stays open, in a place neither `disconnect` nor
        /// `ConnectionViewModel.clearRetainedSecrets()` reaches. Redacting
        /// on the way in makes that state unrepresentable, instead of
        /// adding a third clearing path that every later change would have
        /// to remember.
        init(config: SSHConnectionConfig, target: TerminalTarget, customPath: String?) {
            self.config = config.redactingSecrets()
            self.target = target
            self.customPath = customPath
        }
    }
```

- [ ] **Step 4: Correct the untrue doc comment**

The doc comment on `requestExternalTerminal(config:)` currently claims the
purpose of the hint is, "that the password ends up in a launch script".
That is false: the script contains no password, and the hint message
itself says the opposite. Replace the second paragraph with:

```swift
    /// Split out of `requestExternalTerminal(for:)` rather than duplicated,
    /// so the sidebar route cannot bypass that hint — the point of the hint
    /// is that an external terminal gets NO saved password and `ssh` will
    /// prompt for it there, which is as true for a session macSCP never
    /// connected to as for one it did.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "ExternalTerminalRequest redaction"`
Expected: PASS (3 tests).

Then the full suite: `swift test` — must be green.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacSCPAppKit/ContentView.swift Tests/macSCPAppKitTests/ExternalTerminalRequestRedactionTests.swift
git commit -m "fix(app): keep no plaintext secret in the password hint"
```
