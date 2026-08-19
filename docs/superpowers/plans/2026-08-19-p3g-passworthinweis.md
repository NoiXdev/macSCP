# P3g — Der Passworthinweis hält kein Geheimnis mehr

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `pendingPasswordHintRequest` hält, solange der Passworthinweis offen
steht, keine Klartext-Geheimnisse mehr — weil die zurückgehaltene
Konfiguration sie beim Anlegen verliert, nicht weil ein weiterer Aufräumweg
sie später löscht.

**Architecture:** Eine Messung vor dem Planen hat die Prämisse der Spec
korrigiert: **kein Verbraucher der zurückgehaltenen Konfiguration liest ein
Geheimnis.** `ExternalTerminalLauncher.open` reicht sie ausschließlich an
`SSHCommandBuilder.scriptContents(for:)` weiter, und der liest laut eigenem
Doc-Kommentar und ausweislich seines Codes nur Host, Port, Benutzername,
Schlüssel*pfad* und Jump-Ziel — nie ein Passwort, nie eine Passphrase. Das
Startskript enthält also gar kein Geheimnis; genau das sagt auch der
Hinweistext selbst („macSCP can't hand a saved password to an external
terminal — ssh will ask you for it there").

Daraus folgt eine kleinere und schärfere Reparatur als die Spec annahm:
statt einen dritten Aufräumpfad zu bauen, den künftige Änderungen mitpflegen
müssten, bekommt `ExternalTerminalRequest` einen Initializer, der die
Konfiguration geschwärzt ablegt. Der Zustand „Hinweis offen **und** Passwort
im View-State" wird dadurch nicht aufgeräumt, sondern unmöglich.

Task 1 legt das Schwärzen in den Core (dort ist es testbar), Task 2
verdrahtet es an der einen Stelle und korrigiert einen Doc-Kommentar, der
das Gegenteil der Wahrheit behauptet.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, Swift Testing.

## Global Constraints

- Code, Kommentare, Bezeichner, Testnamen: **ausschließlich Englisch.**
- Ein Geheimnis darf **nie** gedruckt, geloggt oder in eine Meldung
  eingebettet werden — auch nicht in eine Testfehlermeldung. `#expect`
  expandiert seinen Ausdruck: erst in ein `Bool` heben, dann prüfen.
- Nie eine Zeilennummer in einen Kommentar schreiben.
- Kein Doc-Kommentar behauptet etwas, das der Code nicht tut.
- Commit-Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Conventional Commits.
- Tests: TDD rot→grün. `swift test` muss am Ende jeder Task grün sein.

---

### Task 1: `SSHConnectionConfig.redactingSecrets()` (Core)

**Files:**
- Modify: `Sources/macSCPCore/SSH/SSHConnectionConfig.swift`
- Test: `Tests/macSCPCoreTests/SSHConnectionConfigRedactionTests.swift` (neu)

**Interfaces:**
- Consumes: nichts aus früheren Tasks.
- Produces: `public func redactingSecrets() -> SSHConnectionConfig` auf
  `SSHConnectionConfig`. Task 2 ruft genau diese Methode auf.

**Warum ein privater, nicht-werfender Initializer:** Der öffentliche
Initializer wirft, weil er extern gelieferte Werte validiert. Eine
Ableitung aus einer bereits validierten Konfiguration ist keine externe
Eingabe: jedes Feld kommt unverändert durch, außer den Geheimnis-Nutzlasten,
die keine Validierungsregel anfasst. `try!` wäre hier ein Absturzrisiko ohne
Gegenwert, `try?` mit `?? self` gäbe im Fehlerfall stillschweigend die
**ungeschwärzte** Konfiguration zurück — die schlechtestmögliche
Fehlerrichtung. Der private Initializer ist der ehrliche dritte Weg; weil er
privat ist, bleibt der werfende Initializer das eine Tor für externe Werte.

- [ ] **Step 1: Write the failing tests**

Neue Datei `Tests/macSCPCoreTests/SSHConnectionConfigRedactionTests.swift`:

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

In `Sources/macSCPCore/SSH/SSHConnectionConfig.swift`, **innerhalb** der
`struct SSHConnectionConfig`-Deklaration (nicht in einer Extension — der
private Initializer muss von der Methode aus erreichbar bleiben), direkt
hinter dem vorhandenen werfenden `init`:

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

Und am Ende derselben Datei, auf Dateiebene:

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
Expected: PASS (6 Tests).

Danach die volle Suite: `swift test` — muss grün sein.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/SSH/SSHConnectionConfig.swift Tests/macSCPCoreTests/SSHConnectionConfigRedactionTests.swift
git commit -m "feat(core): derive a config copy without plaintext secrets"
```

---

### Task 2: Der Hinweis legt die Konfiguration geschwärzt ab (App)

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView.swift`
- Test: `Tests/macSCPAppKitTests/ExternalTerminalRequestRedactionTests.swift` (neu)

**Interfaces:**
- Consumes: `SSHConnectionConfig.redactingSecrets()` aus Task 1.
- Produces: nichts für spätere Tasks (dies ist die letzte Task).

**Kontext:** `ContentView.ExternalTerminalRequest` ist ein `struct` mit drei
`let`-Feldern und **ohne** eigenen Initializer — es nutzt bisher den
memberwise-Initializer. Der Test-Zugriff läuft über
`@testable import MacSCPAppKit`; `ContentView` ist `internal`, die
verschachtelte Struktur damit für das Test-Target sichtbar.

- [ ] **Step 1: Write the failing test**

Neue Datei `Tests/macSCPAppKitTests/ExternalTerminalRequestRedactionTests.swift`:

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
Expected: FAIL — der erste und zweite Test schlagen fehl, weil der
memberwise-Initializer die Konfiguration unverändert ablegt.

(`TerminalTarget` liegt in `Sources/macSCPCore/Settings/TerminalTarget.swift`
und hat die Fälle `builtIn`, `terminalApp`, `iTerm`, `custom` — der Test
nutzt zwei davon und ist über `import macSCPCore` versorgt.)

- [ ] **Step 3: Implement**

In `Sources/MacSCPAppKit/ContentView.swift` die Struktur um einen
Initializer ergänzen (die drei `let`-Felder bleiben unverändert):

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

Der Doc-Kommentar über `requestExternalTerminal(config:)` behauptet
derzeit, der Sinn des Hinweises sei, „that the password ends up in a launch
script". Das ist falsch: das Skript enthält kein Passwort, und die
Hinweismeldung selbst sagt das Gegenteil. Ersetze den zweiten Absatz durch:

```swift
    /// Split out of `requestExternalTerminal(for:)` rather than duplicated,
    /// so the sidebar route cannot bypass that hint — the point of the hint
    /// is that an external terminal gets NO saved password and `ssh` will
    /// prompt for it there, which is as true for a session macSCP never
    /// connected to as for one it did.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "ExternalTerminalRequest redaction"`
Expected: PASS (3 Tests).

Danach die volle Suite: `swift test` — muss grün sein.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacSCPAppKit/ContentView.swift Tests/macSCPAppKitTests/ExternalTerminalRequestRedactionTests.swift
git commit -m "fix(app): keep no plaintext secret in the password hint"
```
