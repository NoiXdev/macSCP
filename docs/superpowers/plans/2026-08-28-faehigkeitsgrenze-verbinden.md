# Fähigkeitsgrenze beim Verbinden — Umsetzungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein anonymer Ja-sager als Entscheider lässt sich nicht mehr schreiben, und die App-Schicht kann den rohen Wählvorgang nicht mehr erreichen.

**Grundlage:** `docs/superpowers/specs/2026-08-28-faehigkeitsgrenze-verbinden-design.md`

**Architektur:** Zwei Halbschritte, die verschiedene Hälften decken. Aus den nackten Funktionstypen `HostKeyDecider` und `CertificateDecider` werden Typen mit nicht-öffentlichem Initialisierer und benannten Fabriken; `BackendDescriptor.connect` wird `internal` und bekommt einen öffentlichen Einstiegspunkt. Danach schrumpft der Wächter auf das, was Typen nicht ausdrücken.

**Von außen unsichtbar:** kein neues Verhalten, keine neue Einstellung. Diese Arbeit verändert, was sich schreiben lässt.

## Global Constraints

- Code, Kommentare, Bezeichner, Testnamen, Commit-Messages: **nur Englisch**.
- Conventional Commits; Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **TOFU bleibt unangetastet.** Ein Fingerabdruck-Konflikt ist weiterhin ein
  harter Stopp im Backend und erreicht keinen Entscheider. Wer beim Umbauen auf
  einen Pfad stößt, der das ändern würde, hält an und meldet es.
- **Die CLI entscheidet weiter, was sie heute entscheidet:** unbekannte
  Zertifikate ablehnen, Host-Keys nach `HostKeyPolicy`. Ihre Ausgaben auf
  `stderr` und ihr `CLIEnvironment.hasTTY` bleiben in der CLI — **nichts davon
  wandert nach Core.**
- Alle sechs Targets stehen auf `.swiftLanguageMode(.v6)`; **CI wird rot, sobald
  die Zahl eindeutiger Warnorte über 1 liegt.**
- **Keine Zeilennummern, keine Ortsangaben in Kommentaren.** Jede Zahl und jede
  Aufzählung wird in dem Durchgang gezählt, der sie schreibt.
- **Nur eine negative Prüfung neben einer positiven.** Siehe den Abschnitt
  „Guards that name what they watch" in `CLAUDE.md` — er ist an genau dieser
  Wächter-Familie gemessen worden.
- Ein Scratch-Pfad, nach Gebrauch gelöscht.
- Die App wird nicht gestartet, nichts gepusht.

---

### Task 1: Ein Entscheider ist ein Typ

**Files:**
- Modify: `Sources/macSCPCore/Connection/HostKeyDecider.swift`,
  `Sources/macSCPCore/WebDAV/WebDAVSessionDelegate.swift`,
  `Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift`,
  `Sources/macSCPCore/Capabilities/BackendDescriptor.swift`,
  `Sources/macSCPCore/Presentation/ConnectionViewModel.swift`,
  `Sources/MacSCPAppKit/ContentView+Lifecycle.swift`,
  `Sources/MacSCPCLI/SessionConnecting.swift`
- Test: `Tests/macSCPCoreTests/HostKeyDeciderTests.swift` (neu)

**Interfaces:**
- Produces: `HostKeyDecider` und `CertificateDecider` als `struct`s mit
  `callAsFunction`, mit den Fabriken `.asking(_:)` und `.refusing`.
  Task 2 reicht sie durch den neuen Einstiegspunkt.

**Der gemessene Ist-Zustand:** beide sind heute nackte Funktionstypen —
`public typealias HostKeyDecider = @Sendable (HostKeyCandidate) async -> Bool`
und dasselbe für `CertificateDecider`. Betroffen sind **vier** Dateien für den
einen und **drei** für den anderen, plus die Testaufrufstellen, die einen
Entscheider bauen — **zähle die, bevor du anfängst**, und schreib die Zahl in
den Bericht.

`callAsFunction` ist entscheidend für den Umfang: die Verbrauchsstellen rufen
heute `await decider(candidate)`, und genau so rufen sie danach weiter. Nur die
**Bau**stellen ändern sich.

- [ ] **Step 1: Den Test zuerst schreiben.**

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

  **`TestBox`** liegt in `Tests/macSCPCoreTests/WebDAVSessionDelegateTests.swift`
  (`final class TestBox<Value>: @unchecked Sendable`) — benutze den, statt einen
  zweiten einzuführen. Ist er dort nicht sichtbar, sag es im Bericht, statt
  einen eigenen zu bauen.

  **Zur Kandidaten-Signatur, weil ich sie beim Planschreiben zuerst falsch
  hatte:** `HostKeyCandidate.init(host:port:keyType:publicKeyBase64:)` — der
  Fingerabdruck wird daraus abgeleitet und ist kein Initialisierer-Argument.
  Prüf sie trotzdem selbst.

- [ ] **Step 2: Rot laufen lassen.**

Run: `swift test --filter HostKeyDecider`
Erwartet: FAIL — `type 'HostKeyDecider' has no member 'asking'`.

- [ ] **Step 3: Umsetzen.** `HostKeyDecider.swift` wird:

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

  **Dasselbe für `CertificateDecider`** in `WebDAVSessionDelegate.swift`, mit
  `ServerCertificateCandidate` statt `HostKeyCandidate` und einem eigenen
  Doc-Kommentar, der sagt, was dort der harte Stopp ist. Eine zweite Testdatei
  dafür, nach demselben Muster — **nicht** dieselben Tests kopieren, sondern die
  Fragen stellen, die für Zertifikate gelten.

- [ ] **Step 4: Die Baustellen nachziehen.** Jede Stelle, die heute eine
  Closure übergibt, benutzt jetzt eine Fabrik. Die CLI behält ihre
  `makeDecider(policy:)` unverändert im Rumpf und wickelt sie in `.asking`;
  ihre `stderr`-Ausgaben und `CLIEnvironment.hasTTY` bleiben, wo sie sind.
- [ ] **Step 5:** Volle Suite grün, keine neue Warnung.
- [ ] **Step 6: Commit** — `refactor(connection): make a decider a type, not a closure`

---

### Task 2: Wählen ist keine Fähigkeit der App-Schicht

**Files:**
- Modify: `Sources/macSCPCore/Capabilities/BackendDescriptor.swift`,
  `Sources/MacSCPAppKit/ContentView+Lifecycle.swift`,
  `Sources/MacSCPCLI/SessionConnecting.swift`
- Test: `Tests/macSCPCoreTests/` (neu, für den Einstiegspunkt)

**Interfaces:**
- Consumes: die zwei Entscheider-Typen aus Task 1.
- Produces: `BackendDescriptor.openConnection(_:hostKey:certificate:timeoutSeconds:)`
  als **einzigen** öffentlichen Weg zu einer Verbindung.

**Der gemessene Ist-Zustand:** genau **zwei** echte Aufrufer außerhalb Core —
`ContentView+Lifecycle` und `SessionConnecting`. **Kein** Test wählt über den
Descriptor; jeder Treffer in `Tests/` ist Probenmaterial in einem Wächter.
**170** Core-Testdateien importieren `@testable` und behalten Zugriff auf
Internes. Prüf beide Zahlen selbst, bevor du dich darauf verlässt.

- [ ] **Step 1:** `public let connect:` im Descriptor wird `let connect:`
  (modulintern), und daneben entsteht:

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

- [ ] **Step 2:** Beide Aufrufer auf `openConnection` umstellen.
- [ ] **Step 3: Belegen, dass die Grenze wirkt.** Schreib in den Bericht das
  Ergebnis eines Versuchs: `BackendDescriptor.descriptor(for:).connect(…)` in
  einer App-Datei — **muss ein Compile-Fehler sein**, und der Fehlertext gehört
  zitiert. Probe danach entfernen.
- [ ] **Step 4:** Volle Suite grün, keine neue Warnung.
- [ ] **Step 5: Commit** — `refactor(connection): take dialing out of the app layer's reach`

---

### Task 3: Der Wächter schrumpft

**Files:**
- Modify: `Tests/macSCPAppKitTests/ReconnectWiringGuardTests.swift`,
  `Tests/macSCPAppKitTests/ConnectTimeoutAppWiringGuardTests.swift`

**Interfaces:**
- Consumes: alles aus Task 1 und 2.

**Der gemessene Ist-Zustand:** die Suite hält Probenmaterial, das den rohen
Wählvorgang als Zeichenkette enthält — unter anderem die `async let`-Form aus
Runde 6. Vieles davon prüft ab jetzt etwas, das nicht mehr kompiliert.

- [ ] **Step 1: Aufzählen, was jede Prüfung noch leistet.** Für jede Prüfung
  eine Zeile: deckt der Compiler das jetzt ab, oder nicht? **Was er abdeckt,
  wird gelöscht** — nicht „für alle Fälle" behalten. Ein Wächter neben einer
  Garantie lässt den nächsten Leser der Suite mehr vertrauen, als sie verdient.
- [ ] **Step 2: Den Rest belegen.** Übrig bleiben soll, was ein Typ nicht sagen
  kann — insbesondere, dass die App ihre `.asking`-Fabrik an die **echte**
  Abfrage hängt und nicht an einen Ja-sager. Pflanze `.asking { _ in true }` in
  der App-Schicht und belege, dass der Rest-Wächter **rot** wird. Wird er es
  nicht, ist er kein Wächter mehr, sondern Zierde — dann sag das.
- [ ] **Step 3: Die Grenzen-Aussage neu schreiben.** Sie ist über sechs Runden
  gewachsen und beschreibt größtenteils Löcher, die es nicht mehr gibt. Sie
  muss nach diesem Schritt **wahr** sein: was der Compiler hält, was der Rest
  bewacht, und was weiterhin niemand sieht.
- [ ] **Step 4:** Volle Suite grün, keine neue Warnung.
- [ ] **Step 5: Commit** — `test(connection): keep only what types cannot say`

---

## Was ausdrücklich nicht dazugehört

- **Keine Änderung an TOFU** und keine an dem, was die CLI entscheidet.
- **Kein Umzug von CLI-Ausgaben oder `hasTTY` nach Core.**
- Keine neue Einstellung, kein neues Verhalten für den Nutzer.
- Keine Antwort auf die verbleibende Grenze: `.asking { _ in true }` bleibt
  schreibbar. Der Entwurf sagt, warum das in Ordnung ist — sichtbar statt
  unmöglich — und Task 3 macht sie zu dem, was der Wächter bewacht.
