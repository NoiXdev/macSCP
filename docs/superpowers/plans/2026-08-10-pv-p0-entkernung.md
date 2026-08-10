# PV + P0: View-Testbarkeit prüfen und `ContentView` entkernen — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Feststellen, ob SwiftUI-Views in diesem Paket testbar sind, und
`ContentView` (3464 Zeilen, ~3330 in einer `View`-Struktur) so entkernen,
dass die Entscheidungslogik in geprüften Typen liegt und die Datei in
lesbare Stücke zerfällt.

**Architecture:** Zwei Sorten Arbeit, klar getrennt. **Herausziehen:**
reine Entscheidungsfunktionen werden zu eigenen Typen mit Tests — das ist
die Linie aus M29-P2. **Aufteilen:** die `@ViewBuilder`-Blöcke wandern als
`extension ContentView` in eigene Dateien, **ohne dass ein einziges
`@State` den Besitzer wechselt** — Zustandsbesitz zu verschieben ist die
riskanteste Operation in SwiftUI und die einzige, die kein Test hier
abfangen kann.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, macOS 15+,
SwiftUI, Swift Testing (`@Test`/`#expect`), zwei Testtargets
(`macSCPCoreTests`, `macSCPAppKitTests`).

## Global Constraints

- **Code, Kommentare, Testnamen, `reason:`-Strings: Englisch.** Keine
  deutschen Bezeichner oder Kommentare in Quelldateien.
- **Nutzer-sichtbare Strings** gehen über `L10n.string(_:_:)` bzw.
  `String(localized:)`; nie hartkodiert. Neue Schlüssel in **allen vier**
  Katalogen (en/de/fr/pl), Prüfung mit dem vorhandenen Wächtertest und
  `plutil -lint`.
- **Nie eine Zeilennummer in einen Kommentar schreiben.** Das Ding
  benennen, nicht die Zeile.
- **Ein Kommentar, der etwas über den Code behauptet, braucht dieselbe
  Prüfung wie ein Test.** Die Prosa in diesem Plan ist eine zu prüfende
  Behauptung, keine Wahrheit: stimmt sie nicht mit dem Code überein, ist
  **der Plan** falsch — melden, nicht still umbauen.
- **Kein Secret wird geloggt, gedruckt oder in eine Fehlermeldung
  geschrieben** — auch nicht in eine Testfehlermeldung. `#expect` expandiert
  seinen Ausdruck in die Meldung; einen geheimnistragenden Wert vorher in
  ein `Bool` heben.
- **Kein `try?` entscheidet über eine Löschung.**
- **Commit/Push nur auf ausdrückliche Anfrage** des Koordinators. Kein
  `scripts/release` — das veröffentlicht.
- **Die GUI wird nicht gestartet.** `scripts/package-app` (Build) ist
  erlaubt, `open dist/macSCP.app` nicht.
- Commit-Footer auf jedem Commit:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Conventional Commits, Commit-Messages auf Englisch.
- Volle Suite vor jedem Commit: `swift test`. Erwartet grün:
  **1756 Tests in 144 Suiten** (Stand vor diesem Plan; die Zahl wächst mit
  jedem Task und wird im Bericht neu gemessen, nie aus dem Plan abgeschrieben).

## Dateistruktur

**Neu (Herausziehen — je Datei ein Typ, je Typ eine Testdatei):**

| Datei | Verantwortung |
|---|---|
| `Sources/MacSCPAppKit/TabCloseWarning.swift` | Warntext beim Schließen eines Tabs |
| `Sources/MacSCPAppKit/SubmitRefusalText.swift` | `SubmitRefusal` → lokalisierter Text |
| `Sources/macSCPCore/Sessions/SessionSecretPolicy.swift` | Welcher Wert in den eigenen Secret-Slot einer Sitzung geschrieben wird |
| `Sources/MacSCPAppKit/CrossSessionTargets.swift` | Ableitung der Ziel-Sitzungen aus den Tabs |
| `Sources/MacSCPAppKit/ImportFeedbackText.swift` | Fehler- und Ergebnistexte für Session-Import/-Export |

**Neu (Aufteilen — `extension ContentView`, kein Zustandsumzug):**

| Datei | Inhalt |
|---|---|
| `Sources/MacSCPAppKit/ContentView+Sheets.swift` | `sheetsAndAlerts` |
| `Sources/MacSCPAppKit/ContentView+Lifecycle.swift` | `lifecycleAndToolbar`, `performWindowSetup`, `handleWindowWillClose`, `updateMainWindowPresence`, `wireMenuBarBridge` |
| `Sources/MacSCPAppKit/ContentView+Detail.swift` | `detail`, `mainContent`, `splitLayout`, `windowChrome`, `terminalPanel` |
| `Sources/MacSCPAppKit/ContentView+Transfers.swift` | `uploadButton`, `downloadButton`, `transferSelection`, `transferToSession`, `uploadDropped`, `remotePromiseProvider`, `copyPaths`, `openInEditor` |
| `Sources/MacSCPAppKit/ContentView+ExportImport.swift` | `performExport`, `handleExportResult`, `handleImportFileSelection`, `decodeImport`, `applyImport` |

**Geändert:** `Sources/MacSCPAppKit/ContentView.swift` (schrumpft),
`Tests/macSCPAppKitTests/` (neue Testdateien),
`Sources/MacSCPAppKit/Resources/Localizable.xcstrings` + die drei anderen
Kataloge, falls ein Task Schlüssel verschiebt (er verschiebt sie
unverändert — **kein neuer Schlüssel entsteht in P0**).

---

# PV — Der Vorversuch

### Task 1: Sind SwiftUI-Views in diesem Paket testbar?

**Zeitbudget: höchstens ein Arbeitsgang.** Dieser Task liefert eine
Antwort, kein Produkt. Es wird **kein Produktionscode** geändert.

**Files:**
- Create: `docs/superpowers/specs/2026-08-10-pv-view-testbarkeit-bericht.md`
- Ggf. temporär: `Tests/macSCPAppKitTests/ViewTestabilitySpike.swift` (wird
  am Ende entweder behalten oder gelöscht — siehe Schritt 6)
- Ggf. temporär: `Package.swift` (nur falls eine Abhängigkeit probiert wird)

**Interfaces:**
- Consumes: nichts.
- Produces: den Bericht. Nachfolgende Tasks hängen **nicht** davon ab.

- [ ] **Schritt 1: Den Ist-Zustand feststellen**

Es gibt bereits ein App-Testtarget. Sieh nach, was dort heute geht:

```bash
ls Tests/macSCPAppKitTests/ && swift test --filter macSCPAppKitTests 2>&1 | tail -5
```

Notiere im Bericht, welche Typen dort schon getestet werden — es sind
ausschließlich Nicht-View-Typen. Das ist die Ausgangslage.

- [ ] **Schritt 2: Den billigsten Versuch zuerst — geht es ohne jede neue Abhängigkeit?**

Schreibe in `Tests/macSCPAppKitTests/ViewTestabilitySpike.swift` einen
Test, der einen echten View dieses Projekts baut und etwas über ihn
behauptet. `SheetSearchField` ist der kleinste Kandidat; sieh dir seine
Signatur an und instanziiere ihn. Probiere in dieser Reihenfolge:

1. Reines Instanziieren — compiliert das überhaupt aus dem Testtarget?
2. `ImageRenderer` (SwiftUI, ab macOS 13) auf den View anwenden und
   prüfen, ob ein `NSImage` mit einer Größe größer null herauskommt.
3. Falls (2) trägt: denselben View mit zwei verschiedenen Eingaben
   rendern und prüfen, dass sich die erzeugten Bitmaps **unterscheiden**.

Punkt 3 ist der eigentliche Test: ein Renderer, der für jede Eingabe
dasselbe liefert, beweist nichts. **Ein Vorversuch ohne Positivkontrolle
kann seinen eigenen Ausfall nicht von Erfolg unterscheiden.**

- [ ] **Schritt 3: Verträgt es sich mit Swift Testing?**

Schreibe den Versuch als `@Test`-Funktion, nicht als `XCTestCase`. Falls
das scheitert, notiere die genaue Fehlermeldung — sie ist das Ergebnis.

- [ ] **Schritt 4: Läuft es ohne GUI-Sitzung?**

```bash
swift test --filter ViewTestabilitySpike 2>&1 | tail -20
```

Prüfe zusätzlich, ob der Test eine laufende Fensterserver-Sitzung braucht.
Ein Weg, das festzustellen, ohne CI zu bemühen: sieh nach, ob der Test
`NSApplication` anfasst oder eine Ausnahme über einen fehlenden
Fensterserver wirft. Notiere, was du tatsächlich beobachtet hast — nicht,
was du erwartest.

- [ ] **Schritt 5: Nur falls Schritt 2 scheitert — eine Abhängigkeit prüfen**

Erst jetzt, und nur dann. Sieh nach, welche SwiftUI-Testbibliotheken es
gibt, ob sie Swift 6 und Swift Testing unterstützen und was sie an die
Toolchain binden. **Füge nichts zu `Package.swift` hinzu, ohne es im
Bericht zu begründen**, und mache die Änderung rückgängig, falls sie
scheitert.

- [ ] **Schritt 6: Bericht schreiben und committen**

Der Bericht beantwortet genau diese fünf Fragen, jede mit dem, was du
gemessen hast:

1. Lässt sich ein View aus `MacSCPAppKit` im Testtarget instanziieren?
2. Lässt sich sein Inhalt prüfen — und **unterscheidet** sich das Ergebnis
   für unterschiedliche Eingaben?
3. Verträgt es sich mit Swift Testing?
4. Läuft es ohne GUI-Sitzung?
5. Was kostet es an Abhängigkeiten?

Am Ende steht eine **Empfehlung mit einem Satz** und, falls positiv, der
lauffähige Beispieltest. Falls negativ: `ViewTestabilitySpike.swift`
löschen, `Package.swift` zurücksetzen, und der Bericht nennt den Grund.

**„Geht wahrscheinlich" ist kein Ergebnis.** Wenn du es nicht messen
konntest, schreibe hin, was dich daran gehindert hat.

```bash
git add docs/superpowers/specs/2026-08-10-pv-view-testbarkeit-bericht.md
git commit -m "docs(app): record whether SwiftUI views in this package can be tested"
```

**STOP.** Nach diesem Task entscheidet der Koordinator zusammen mit dem
Maintainer, ob View-Tests in P0 gehören. Die folgenden Tasks laufen
unabhängig vom Ergebnis weiter.

---

# P0 — Entkernung

## Teil A: Herausziehen (Logik + Tests)

### Task 2: `TabCloseWarning`

Der Warntext beim Schließen eines Tabs entscheidet, welche zwei Gründe
genannt werden und in welcher Reihenfolge. Das ist reine Logik in einer
View-Datei.

**Files:**
- Create: `Sources/MacSCPAppKit/TabCloseWarning.swift`
- Create: `Tests/macSCPAppKitTests/TabCloseWarningTests.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift` (`hasIncomingTransfers`,
  `closeWarningMessage` und ihre Aufrufer)

**Interfaces:**
- Consumes: `SessionTab` (App-seitig, hat `id`, `transferQueue`).
- Produces:
  - `enum TabCloseWarning { static func hasIncomingTransfers(for tabID: UUID, in tabs: [SessionTab]) -> Bool }`
  - `static func message(activeTransfers: Bool, incomingTransfers: Bool) -> String`

- [ ] **Schritt 1: Den vorhandenen Code lesen**

Sieh dir `closeWarningMessage(for:)` und `hasIncomingTransfers(for:)` in
`ContentView.swift` an, dazu ihre Aufrufer (`requestClose` und die
Bestätigungs-Schranke). **Der Text darf sich nicht ändern** — die
L10n-Schlüssel `tabs.close.activeTransfers` und
`tabs.close.incomingTransfers` werden unverändert übernommen.

- [ ] **Schritt 2: Den fehlschlagenden Test schreiben**

```swift
import Foundation
import Testing
@testable import MacSCPAppKit

@Suite("TabCloseWarning")
struct TabCloseWarningTests {
    /// Both reasons can hold at once, and when they do the user sees both —
    /// one per line. A message that named only the first would leave them
    /// guessing which of the two applied.
    @Test func bothReasonsAreNamedWhenBothHold() {
        let text = TabCloseWarning.message(activeTransfers: true, incomingTransfers: true)

        #expect(text.split(separator: "\n").count == 2)
    }

    /// Neither reason holds: the message is empty, not a stray newline. The
    /// caller decides whether to show a dialog at all; an "empty" message
    /// that is actually "\n" makes an empty dialog look like a real warning.
    @Test func noReasonMeansNoText() {
        #expect(TabCloseWarning.message(activeTransfers: false, incomingTransfers: false).isEmpty)
    }

    /// One reason each, in isolation — proves the two lines are independent
    /// rather than one string that happens to contain both.
    @Test func eachReasonStandsAlone() {
        let active = TabCloseWarning.message(activeTransfers: true, incomingTransfers: false)
        let incoming = TabCloseWarning.message(activeTransfers: false, incomingTransfers: true)

        #expect(!active.isEmpty)
        #expect(!incoming.isEmpty)
        #expect(active != incoming)
    }
}
```

- [ ] **Schritt 3: Test rot laufen lassen**

Run: `swift test --filter TabCloseWarning`
Erwartet: FAIL, `cannot find 'TabCloseWarning' in scope`.

- [ ] **Schritt 4: Den Typ anlegen**

`Sources/MacSCPAppKit/TabCloseWarning.swift`:

```swift
import Foundation
import macSCPCore

/// The two reasons closing a tab is worth warning about, and the text that
/// names them. Lifted out of `ContentView` so the wording and the
/// both-reasons-at-once case are held by tests rather than by reading.
enum TabCloseWarning {
    /// True while any OTHER tab's queue holds a non-terminal item that
    /// targets this tab — closing it would sever those incoming
    /// cross-session streams.
    static func hasIncomingTransfers(for tabID: UUID, in tabs: [SessionTab]) -> Bool {
        tabs.contains { $0.id != tabID && $0.transferQueue.hasActiveItems(destinationTabID: tabID) }
    }

    /// One line per reason that holds, in a fixed order. Empty when neither
    /// holds — the caller decides whether a dialog appears at all.
    static func message(activeTransfers: Bool, incomingTransfers: Bool) -> String {
        var lines: [String] = []
        if activeTransfers {
            lines.append(L10n.string(
                "tabs.close.activeTransfers", "Active transfers in this tab will be canceled."))
        }
        if incomingTransfers {
            lines.append(L10n.string(
                "tabs.close.incomingTransfers",
                "Other tabs are streaming to this session; closing cancels those transfers."))
        }
        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Schritt 5: Test grün laufen lassen**

Run: `swift test --filter TabCloseWarning`
Erwartet: PASS, drei Tests.

- [ ] **Schritt 6: `ContentView` auf den neuen Typ umstellen**

Lösche `closeWarningMessage(for:)` und `hasIncomingTransfers(for:)` aus
`ContentView` und ersetze **jeden** Aufrufer. `requestClose` ruft dann:

```swift
let incoming = TabCloseWarning.hasIncomingTransfers(for: tab.id, in: tabsModel.tabs)
closeWarningText = TabCloseWarning.message(
    activeTransfers: tab.transferQueue.isActive, incomingTransfers: incoming)
```

Prüfe mit dem Compiler, nicht mit `grep`, dass keine Aufrufer übrig sind:
ein Build ohne Fehler ist der Nachweis.

- [ ] **Schritt 7: Volle Suite**

Run: `swift test`
Erwartet: alles grün, drei Tests mehr als vorher.

- [ ] **Schritt 8: Commit**

```bash
git add Sources/MacSCPAppKit/TabCloseWarning.swift Tests/macSCPAppKitTests/TabCloseWarningTests.swift Sources/MacSCPAppKit/ContentView.swift
git commit -m "refactor(app): hold the tab-close warning text in a tested type"
```

---

### Task 3: `SubmitRefusalText`

`message(for refusal:)` bildet die acht `SubmitRefusal`-Fälle auf Text ab.
M29-P2 hat den Refusal-Typ nach Core geholt; seine Übersetzung in Text ist
in `ContentView` liegen geblieben und ungeprüft.

**Files:**
- Create: `Sources/MacSCPAppKit/SubmitRefusalText.swift`
- Create: `Tests/macSCPAppKitTests/SubmitRefusalTextTests.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift`

**Interfaces:**
- Consumes: `SubmitRefusal` aus `macSCPCore` mit den Fällen
  `targetSetMissing`, `targetSetKindMismatch`, `jumpSetMissing`,
  `jumpSetNotSSH`, `jumpSessionMissing`, `jumpChainNotSupported`,
  `jumpSessionNotSSH`, `jumpSessionLoginUnresolvable`.
- Produces: `enum SubmitRefusalText { static func message(for refusal: SubmitRefusal) -> String }`

- [ ] **Schritt 1: Den vorhandenen Code lesen**

`message(for refusal:)` in `ContentView.swift`. Übernimm **jeden**
L10n-Schlüssel und jeden Default-Text unverändert. Manche Fälle setzen
Werte in den Text ein — übernimm auch die Formatierung wörtlich.

- [ ] **Schritt 2: Den fehlschlagenden Test schreiben**

Der wertvolle Test ist nicht „Fall X ergibt Text Y" — das schreibt die
Implementierung ab. Wertvoll ist die **Vollständigkeit**: kein Fall darf
leer oder mit einem anderen identisch sein.

```swift
import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("SubmitRefusalText")
struct SubmitRefusalTextTests {
    /// Every refusal case, listed by hand. A new case added to
    /// `SubmitRefusal` without a line here is caught by the exhaustive
    /// switch below, which fails to compile until it is handled.
    static let allCases: [SubmitRefusal] = [
        .targetSetMissing, .targetSetKindMismatch,
        .jumpSetMissing, .jumpSetNotSSH,
        .jumpSessionMissing, .jumpChainNotSupported,
        .jumpSessionNotSSH, .jumpSessionLoginUnresolvable,
    ]

    /// A refusal the user cannot read is a refusal that looks like a
    /// silent failure — the submit simply does nothing and no text appears.
    @Test func everyRefusalHasText() {
        for refusal in Self.allCases {
            let isEmpty = SubmitRefusalText.message(for: refusal).isEmpty
            #expect(isEmpty == false, "\(refusal) has no message")
        }
    }

    /// Two refusals that read identically send the user to fix the wrong
    /// thing. This is what a copy-paste slip in the mapping looks like.
    @Test func noTwoRefusalsReadTheSame() {
        var seen: [String: SubmitRefusal] = [:]
        for refusal in Self.allCases {
            let text = SubmitRefusalText.message(for: refusal)
            #expect(seen[text] == nil, "\(refusal) reads the same as \(String(describing: seen[text]))")
            seen[text] = refusal
        }
    }

    /// The list above is hand-maintained; this switch makes the compiler
    /// reject a new `SubmitRefusal` case that nobody added to it.
    @Test func theCaseListIsComplete() {
        for refusal in Self.allCases {
            switch refusal {
            case .targetSetMissing, .targetSetKindMismatch,
                .jumpSetMissing, .jumpSetNotSSH,
                .jumpSessionMissing, .jumpChainNotSupported,
                .jumpSessionNotSSH, .jumpSessionLoginUnresolvable:
                continue
            }
        }
        #expect(Self.allCases.count == 8)
    }
}
```

- [ ] **Schritt 3: Test rot laufen lassen**

Run: `swift test --filter SubmitRefusalText`
Erwartet: FAIL, `cannot find 'SubmitRefusalText' in scope`.

- [ ] **Schritt 4: Den Typ anlegen**

Verschiebe den Rumpf von `message(for refusal:)` **wörtlich** in

```swift
enum SubmitRefusalText {
    static func message(for refusal: SubmitRefusal) -> String { … }
}
```

in `Sources/MacSCPAppKit/SubmitRefusalText.swift`. Ändere keinen Text und
keinen Schlüssel. Falls der vorhandene Code auf `self` oder auf
`ContentView`-Zustand zugreift, **halte an und melde es** — dann ist er
nicht rein und dieser Plan hat sich geirrt.

- [ ] **Schritt 5: Test grün laufen lassen**

Run: `swift test --filter SubmitRefusalText`
Erwartet: PASS.

- [ ] **Schritt 6: `ContentView` umstellen**

`message(for:)` löschen, Aufrufer auf `SubmitRefusalText.message(for:)`
umstellen. Build als Nachweis.

- [ ] **Schritt 7: Volle Suite und Commit**

```bash
swift test
git add Sources/MacSCPAppKit/SubmitRefusalText.swift Tests/macSCPAppKitTests/SubmitRefusalTextTests.swift Sources/MacSCPAppKit/ContentView.swift
git commit -m "refactor(app): hold every submit refusal's text in a tested mapping"
```

---

### Task 4: `SessionSecretPolicy` (Core)

Welcher Wert in den eigenen Secret-Slot einer Sitzung geschrieben wird,
entscheidet heute eine `private func` in einer View-Datei, die sich ihre
beiden Stores selbst baut — deshalb ist sie nicht testbar. Das ist die
Sorte Entscheidung, an der dieses Projekt schon Datenverlust hatte.

**Files:**
- Create: `Sources/macSCPCore/Sessions/SessionSecretPolicy.swift`
- Create: `Tests/macSCPCoreTests/SessionSecretPolicyTests.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift`

**Interfaces:**
- Consumes: `ManagedKeyPassphrase.hasStoredPassphrase(keyPath:store:secrets:)`,
  `ManagedKeyStore`, `SecretStore`, `ConnectionKind`, `AuthKind`.
- Produces:
  ```swift
  public enum SessionSecretPolicy {
      public static func usesStoredManagedPassphrase(
          kind: ConnectionKind, authChoice: AuthKind, keyPath: String,
          keys: ManagedKeyStore, secrets: SecretStore) -> Bool
      public static func valueToPersist(
          resolvedSecret: String, kind: ConnectionKind, authChoice: AuthKind,
          keyPath: String, keys: ManagedKeyStore, secrets: SecretStore) -> String
  }
  ```

- [ ] **Schritt 1: Den vorhandenen Code lesen**

`isManagedKeyWithStoredPassphrase(_:)` und `passwordToPersist(for:)` in
`ContentView.swift`, samt ihrer Doc-Kommentare. Beachte insbesondere den
`catch`-Zweig: er gibt **`true`** zurück, also „nicht persistieren". Das
ist Absicht — ein Fehler beim Nachsehen darf nicht dazu führen, dass eine
Passphrase ein zweites Mal geschrieben wird. **Diese Richtung nicht
umdrehen.**

- [ ] **Schritt 2: Den fehlschlagenden Test schreiben**

Beachte die Secret-Regel: **kein Test darf einen geheimen Wert in eine
Fehlermeldung tragen.** `#expect` expandiert seinen Ausdruck — deshalb
wird unten erst in ein `Bool` gehoben.

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("SessionSecretPolicy")
struct SessionSecretPolicyTests {
    private func emptyStores() throws -> (ManagedKeyStore, InMemorySecretStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (ManagedKeyStore(directory: dir), InMemorySecretStore())
    }

    /// A password login has no managed key involved at all, so its own
    /// secret is what gets persisted.
    @Test func aPasswordLoginPersistsItsOwnSecret() throws {
        let (keys, secrets) = try emptyStores()

        let value = SessionSecretPolicy.valueToPersist(
            resolvedSecret: "s3cret", kind: .ssh, authChoice: .password,
            keyPath: "", keys: keys, secrets: secrets)

        let matches = value == "s3cret"
        #expect(matches)
    }

    /// An agent login holds no secret at all; nothing is written.
    @Test func anAgentLoginPersistsNothing() throws {
        let (keys, secrets) = try emptyStores()

        let isEmpty = SessionSecretPolicy.valueToPersist(
            resolvedSecret: "", kind: .ssh, authChoice: .agent,
            keyPath: "", keys: keys, secrets: secrets).isEmpty
        #expect(isEmpty)
    }

    /// A private-key login whose key is NOT managed here still persists its
    /// own passphrase — the exemption is only for keys whose passphrase this
    /// app already keeps under the key's own identifier.
    @Test func anUnmanagedKeyPersistsItsOwnPassphrase() throws {
        let (keys, secrets) = try emptyStores()

        let isEmpty = SessionSecretPolicy.valueToPersist(
            resolvedSecret: "passphrase", kind: .ssh, authChoice: .privateKey,
            keyPath: "/nowhere/id_ed25519", keys: keys, secrets: secrets).isEmpty
        #expect(isEmpty == false)
    }

    /// The whitespace around a pasted path must not decide the answer — a
    /// trailing space would otherwise make a managed key look unmanaged and
    /// duplicate its passphrase into a second keychain slot.
    @Test func aPaddedKeyPathAnswersLikeItsTrimmedForm() throws {
        let (keys, secrets) = try emptyStores()

        let padded = SessionSecretPolicy.usesStoredManagedPassphrase(
            kind: .ssh, authChoice: .privateKey, keyPath: "  /nowhere/id_ed25519  ",
            keys: keys, secrets: secrets)
        let trimmed = SessionSecretPolicy.usesStoredManagedPassphrase(
            kind: .ssh, authChoice: .privateKey, keyPath: "/nowhere/id_ed25519",
            keys: keys, secrets: secrets)

        #expect(padded == trimmed)
    }
}
```

- [ ] **Schritt 3: Test rot laufen lassen**

Run: `swift test --filter SessionSecretPolicy`
Erwartet: FAIL, `cannot find 'SessionSecretPolicy' in scope`.

- [ ] **Schritt 4: Den Typ anlegen**

Der Rumpf ist der vorhandene, nur mit hereingereichten Stores statt
selbstgebauten. **Der `catch`-Zweig bleibt `true`.** Schreibe den Grund als
Doc-Kommentar an die Funktion, nicht als Wiederholung dieses Plans.

- [ ] **Schritt 5: Test grün laufen lassen**

Run: `swift test --filter SessionSecretPolicy`
Erwartet: PASS, vier Tests.

- [ ] **Schritt 6: `ContentView` umstellen**

Beide `private func` löschen; die Aufrufer reichen
`ManagedKeyStore(directory: SessionStore.defaultDirectory)` und
`KeychainSecretStore()` herein — dieselben Werte wie bisher, jetzt nur
sichtbar am Aufrufort.

- [ ] **Schritt 7: Volle Suite und Commit**

```bash
swift test
git add Sources/macSCPCore/Sessions/SessionSecretPolicy.swift Tests/macSCPCoreTests/SessionSecretPolicyTests.swift Sources/MacSCPAppKit/ContentView.swift
git commit -m "refactor(core): move the session secret-slot decision out of the view"
```

---

### Task 5: `CrossSessionTargets`

Welche anderen Tabs als Transferziel angeboten werden, ist eine Ableitung
über die Tab-Liste — heute in `ContentView`, ungeprüft, obwohl sie
entscheidet, wohin Dateien wandern.

**Files:**
- Create: `Sources/MacSCPAppKit/CrossSessionTargets.swift`
- Create: `Tests/macSCPAppKitTests/CrossSessionTargetsTests.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift`

**Interfaces:**
- Consumes: `SessionTab` (mit `id`, `displayTitle`, `session`,
  `connectionViewModel.kind`), `CrossSessionTarget` aus `macSCPCore`
  (`init(id:title:remotePath:kind:)`).
- Produces:
  `enum CrossSessionTargets { static func targets(excluding tabID: UUID, in tabs: [SessionTab]) -> [CrossSessionTarget] }`

- [ ] **Schritt 1: Den vorhandenen Code lesen**

`crossSessionTargets(for:)` in `ContentView.swift`. Zwei Regeln stecken
darin: der eigene Tab fällt weg, und ein Tab **ohne** Sitzung fällt weg.

- [ ] **Schritt 2: Den fehlschlagenden Test schreiben**

Sieh dir zuerst `Tests/macSCPAppKitTests/SessionTabTests.swift` an — dort
steht, wie ein `SessionTab` in einem Test gebaut wird. Benutze denselben
Weg; erfinde keinen zweiten.

```swift
import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("CrossSessionTargets")
struct CrossSessionTargetsTests {
    /// A tab never offers itself as a transfer destination — "copy to
    /// here" through the cross-session path would enqueue a job whose
    /// source and destination are the same remote.
    @Test func aTabIsNotOfferedAsItsOwnTarget() {
        let mine = SessionTab()
        let targets = CrossSessionTargets.targets(excluding: mine.id, in: [mine])

        #expect(targets.isEmpty)
    }

    /// A tab that is not connected has no remote to receive anything, so it
    /// is skipped rather than offered as a target that silently does
    /// nothing when clicked.
    @Test func aTabWithoutASessionIsSkipped() {
        let mine = SessionTab()
        let other = SessionTab()
        let targets = CrossSessionTargets.targets(excluding: mine.id, in: [mine, other])

        #expect(targets.isEmpty)
    }
}
```

**Falls `SessionTab()` so nicht baubar ist oder eine verbundene Sitzung im
Test nicht herstellbar ist:** halte an und melde es. Schreibe **keinen**
Test, der nur die beiden leeren Fälle prüft und so tut, als sei das die
ganze Regel — melde stattdessen, was fehlt, damit der Koordinator
entscheidet.

- [ ] **Schritt 3: Test rot laufen lassen**

Run: `swift test --filter CrossSessionTargets`
Erwartet: FAIL, `cannot find 'CrossSessionTargets' in scope`.

- [ ] **Schritt 4: Den Typ anlegen, Test grün, `ContentView` umstellen**

```swift
enum CrossSessionTargets {
    static func targets(excluding tabID: UUID, in tabs: [SessionTab]) -> [CrossSessionTarget] {
        tabs.compactMap { other in
            guard other.id != tabID, let session = other.session else { return nil }
            return CrossSessionTarget(
                id: other.id, title: other.displayTitle,
                remotePath: session.remote.currentPath,
                kind: other.connectionViewModel.kind)
        }
    }
}
```

Run: `swift test --filter CrossSessionTargets` → PASS.
Dann `crossSessionTargets(for:)` löschen und die Aufrufer umstellen.

- [ ] **Schritt 5: Volle Suite und Commit**

```bash
swift test
git add Sources/MacSCPAppKit/CrossSessionTargets.swift Tests/macSCPAppKitTests/CrossSessionTargetsTests.swift Sources/MacSCPAppKit/ContentView.swift
git commit -m "refactor(app): derive cross-session transfer targets in a tested type"
```

---

### Task 6: `ImportFeedbackText`

Drei Textabbildungen für Session-Import und -Export liegen als
`private func` in `ContentView`: `readErrorMessage(_:)`,
`importErrorText(for:)` und `importResultText(…)`.

**Files:**
- Create: `Sources/MacSCPAppKit/ImportFeedbackText.swift`
- Create: `Tests/macSCPAppKitTests/ImportFeedbackTextTests.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift`

**Interfaces:**
- Consumes: `SessionExportError` aus `macSCPCore`.
- Produces: `enum ImportFeedbackText` mit den drei Funktionen unter
  denselben Namen und Signaturen, die sie heute in `ContentView` haben.

- [ ] **Schritt 1: Die drei Funktionen lesen und ihre genauen Signaturen notieren**

`readErrorMessage(_:)`, `importErrorText(for:)`, `importResultText(…)` in
`ContentView.swift`. Notiere die Parameterliste von `importResultText`
wörtlich — sie hat mehrere Parameter und der Plan schreibt sie bewusst
nicht ab, damit hier keine erfundene Signatur entsteht.

- [ ] **Schritt 2: Den fehlschlagenden Test schreiben**

Derselbe Zuschnitt wie in Task 3: nicht Text gegen Text, sondern
Vollständigkeit und Unterscheidbarkeit.

```swift
import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("ImportFeedbackText")
struct ImportFeedbackTextTests {
    /// An import that failed and says nothing is indistinguishable from one
    /// that silently did nothing.
    @Test func everyExportErrorHasText() {
        for error in SessionExportError.allTestCases {
            let isEmpty = ImportFeedbackText.importErrorText(for: error).isEmpty
            #expect(isEmpty == false, "\(error) has no message")
        }
    }

    /// Two different failures that read the same send the user to fix the
    /// wrong thing.
    @Test func noTwoExportErrorsReadTheSame() {
        var seen = Set<String>()
        for error in SessionExportError.allTestCases {
            let text = ImportFeedbackText.importErrorText(for: error)
            #expect(seen.insert(text).inserted, "\(error) duplicates another message")
        }
    }
}
```

`SessionExportError.allTestCases` existiert noch nicht. Lege sie im
**Testtarget** an (nicht in Core), als `extension SessionExportError` mit
einer von Hand gepflegten Liste plus einem erschöpfenden `switch`, der
den Compiler einen neuen Fall melden lässt — genau wie in Task 3.

- [ ] **Schritt 3: Test rot laufen lassen**

Run: `swift test --filter ImportFeedbackText`
Erwartet: FAIL.

- [ ] **Schritt 4: Typ anlegen, Test grün, `ContentView` umstellen**

Rümpfe wörtlich verschieben, keine Texte ändern, Aufrufer umstellen,
Build als Nachweis.

- [ ] **Schritt 5: Volle Suite und Commit**

```bash
swift test
git add Sources/MacSCPAppKit/ImportFeedbackText.swift Tests/macSCPAppKitTests/ImportFeedbackTextTests.swift Sources/MacSCPAppKit/ContentView.swift
git commit -m "refactor(app): hold import and export feedback text in a tested mapping"
```

---

## Teil B: Aufteilen (kein Zustandsumzug)

**Für alle Tasks in Teil B gilt dieselbe Zusicherung und dasselbe
Verfahren.** Lies das hier einmal; die Tasks wiederholen es nicht.

**Die Zusicherung: kein Verhalten ändert sich.** Nichts wird umbenannt,
nichts wird umsortiert, kein `@State` wechselt den Besitzer, keine
Reihenfolge von Modifikatoren ändert sich.

**Das Verfahren:** Der Block wandert als `extension ContentView` in eine
neue Datei desselben Moduls. Weil `private` in Swift **dateiweit** gilt,
verlieren verschobene Mitglieder den Zugriff auf die in `ContentView.swift`
verbliebenen `private`-Mitglieder. Deshalb:

- Ein verschobenes Mitglied wird von `private` auf **modulweit** (kein
  Zugriffsmodifikator) gesetzt.
- Ein in `ContentView.swift` verbliebenes Mitglied, das ein verschobenes
  Mitglied braucht, wird ebenfalls modulweit.
- **Nichts wird `public`.** Die Sichtbarkeit endet an `MacSCPAppKit`.

**Warum kein echter eigener View-Typ:** Ein neuer `struct SomeView: View`
verlangt, dass jeder Zustand, den er liest, explizit hereingereicht wird —
und genau dabei entstehen die Fehler, die kein Test hier abfängt. Eine
`extension` löst das Lesbarkeitsproblem, ohne den Zustandsbesitz
anzufassen. Wo ein eigener Typ leicht möglich ist, sagt der Task es
ausdrücklich.

**Der Nachweis je Task:** `swift build` ohne Fehler **und** ohne neue
Warnungen, `swift test` vollständig grün, und `git diff --stat` zeigt für
`ContentView.swift` fast nur Löschungen. Zeigt der Diff Änderungen an
Zeilen, die du nur verschieben wolltest, ist das ein Befund — nachsehen,
nicht durchwinken.

---

### Task 7: `ContentView+Detail.swift`

**Files:**
- Create: `Sources/MacSCPAppKit/ContentView+Detail.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift`

- [ ] **Schritt 1: Die Blöcke identifizieren**

`detail`, `mainContent`, `splitLayout`, `windowChrome(_:)`,
`terminalPanel(_:)`, `tabIDs`. Notiere **vor** dem Verschieben die
Zeilenzahl von `ContentView.swift`:

```bash
wc -l Sources/MacSCPAppKit/ContentView.swift
```

- [ ] **Schritt 2: Verschieben**

Neue Datei mit `import SwiftUI`, `import macSCPCore` und
`extension ContentView { … }`. Die sechs Mitglieder wörtlich hinein,
`private` entfernen. Weitere `private`-Mitglieder in `ContentView.swift`,
die dadurch unerreichbar werden, ebenfalls modulweit machen — der Compiler
zeigt dir genau, welche.

- [ ] **Schritt 3: Build und Suite**

```bash
swift build 2>&1 | tail -20 && swift test
```
Erwartet: Build ohne Fehler und ohne neue Warnungen, Suite vollständig grün.

- [ ] **Schritt 4: Den Diff prüfen**

```bash
git diff --stat Sources/MacSCPAppKit/ContentView.swift
```
Erwartet: fast ausschließlich Löschungen. Änderungen an Zeilen, die
bleiben sollten, sind ein Befund.

- [ ] **Schritt 5: Commit**

```bash
git add Sources/MacSCPAppKit/ContentView+Detail.swift Sources/MacSCPAppKit/ContentView.swift
git commit -m "refactor(app): move the detail pane builders into their own file"
```

---

### Task 8: `ContentView+Sheets.swift`

**Files:**
- Create: `Sources/MacSCPAppKit/ContentView+Sheets.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift`

Derselbe Ablauf wie Task 7, mit `sheetsAndAlerts(_:)` sowie den
Bindings, die nur dort benutzt werden (`passwordHintPresented`,
`externalTerminalErrorPresented`) und den Sheet-Präsentationsfunktionen
`presentSnippets`, `presentLoginSetsFromSettings`,
`presentServerCertificatesFromSettings`, `presentHiddenImportsFromSettings`.

Dies ist der größte Block. Prüfe nach dem Verschieben besonders, dass die
**Reihenfolge** der `.sheet`- und `.alert`-Modifikatoren unverändert ist:
bei mehreren Sheets am selben View entscheidet die Reihenfolge, welches
gewinnt.

- [ ] Schritt 1: Zeilenzahl notieren, Blöcke identifizieren
- [ ] Schritt 2: Verschieben, `private` → modulweit
- [ ] Schritt 3: `swift build` und `swift test` — beides grün
- [ ] Schritt 4: `git diff --stat` prüfen — fast nur Löschungen
- [ ] Schritt 5: Commit

```bash
git add Sources/MacSCPAppKit/ContentView+Sheets.swift Sources/MacSCPAppKit/ContentView.swift
git commit -m "refactor(app): move the sheet and alert wiring into its own file"
```

---

### Task 9: `ContentView+Lifecycle.swift`

**Files:**
- Create: `Sources/MacSCPAppKit/ContentView+Lifecycle.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift`

Inhalt: `lifecycleAndToolbar(_:)`, `performWindowSetup`,
`handleWindowWillClose(_:)`, `updateMainWindowPresence`,
`wireMenuBarBridge`, `handleCloseActiveTabCommand`, `resizeWindow(toWidth:height:)`,
`shrinkIfPristine`, `makeTab`, `attachAuditRecorder(…)`, `teardown(_:)`,
`activate(_:)`, `selectTab(atIndex:)`, `requestClose(_:)`, `performClose(_:)`.

Hier hängt die Reihenfolge der Aufräumschritte an einer Projektinvariante:
**`cancelAll` → `shutdown` → `disconnect`** in `teardown`. Wird dabei
etwas umsortiert, ist das kein Verschieben mehr.

- [ ] Schritt 1: Zeilenzahl notieren, Blöcke identifizieren
- [ ] Schritt 2: Verschieben, `private` → modulweit
- [ ] Schritt 3: `swift build` und `swift test` — beides grün
- [ ] Schritt 4: `git diff --stat` prüfen; zusätzlich die Reihenfolge in
      `teardown` gegen den Stand vor dem Verschieben halten
      (`git show HEAD:Sources/MacSCPAppKit/ContentView.swift`)
- [ ] Schritt 5: Commit

```bash
git add Sources/MacSCPAppKit/ContentView+Lifecycle.swift Sources/MacSCPAppKit/ContentView.swift
git commit -m "refactor(app): move tab lifecycle and window setup into their own file"
```

---

### Task 10: `ContentView+Transfers.swift`

**Files:**
- Create: `Sources/MacSCPAppKit/ContentView+Transfers.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift`

Inhalt: `uploadButton(in:session:)`, `downloadButton(in:session:)`,
`transferSelection(…)`, `transferToSession(…)`, `uploadDropped(_:in:)`,
`remotePromiseProvider(…)`, `copyPaths(of:)`, `openInEditor(…)`.

- [ ] Schritt 1: Zeilenzahl notieren, Blöcke identifizieren
- [ ] Schritt 2: Verschieben, `private` → modulweit
- [ ] Schritt 3: `swift build` und `swift test` — beides grün
- [ ] Schritt 4: `git diff --stat` prüfen — fast nur Löschungen
- [ ] Schritt 5: Commit

```bash
git add Sources/MacSCPAppKit/ContentView+Transfers.swift Sources/MacSCPAppKit/ContentView.swift
git commit -m "refactor(app): move the transfer actions into their own file"
```

---

### Task 11: `ContentView+ExportImport.swift`

**Files:**
- Create: `Sources/MacSCPAppKit/ContentView+ExportImport.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift`

Inhalt: `performExport(…)`, `handleExportResult(_:)`,
`handleImportFileSelection(_:)`, `decodeImport(data:password:)`,
`applyImport(_:)`.

**Achtung:** In diesem Bereich liegen Secret-Pfade. Beim Verschieben darf
kein Wert in eine Log- oder Fehlerausgabe geraten, der vorher nicht dort
war — und keiner, der dort war, wird stillschweigend entfernt (das wäre
ebenfalls eine Verhaltensänderung; falls dir einer auffällt, **melde ihn,
statt ihn zu beheben** — das ist ein eigener Befund).

- [ ] Schritt 1: Zeilenzahl notieren, Blöcke identifizieren
- [ ] Schritt 2: Verschieben, `private` → modulweit
- [ ] Schritt 3: `swift build` und `swift test` — beides grün
- [ ] Schritt 4: `git diff --stat` prüfen — fast nur Löschungen
- [ ] Schritt 5: Commit

```bash
git add Sources/MacSCPAppKit/ContentView+ExportImport.swift Sources/MacSCPAppKit/ContentView.swift
git commit -m "refactor(app): move session export and import wiring into their own file"
```

---

## Teil C: Abschluss

### Task 12: Phasenabschluss

**Files:**
- Create: `docs/superpowers/specs/2026-08-10-p0-entkernung-abschluss.md`

- [ ] **Schritt 1: Neu messen**

```bash
wc -l Sources/MacSCPAppKit/*.swift | sort -rn | head -12
swift test 2>&1 | tail -5
```

Schreibe die **gemessenen** Zahlen in den Bericht. Der Ausgangswert war
`ContentView.swift` mit 3464 Zeilen und die Suite mit 1756 Tests in 144
Suiten; beide Zahlen sind Messwerte von vor diesem Plan und werden nicht
abgeschrieben, sondern gegen das Ergebnis gehalten.

- [ ] **Schritt 2: Dev-Build**

```bash
MACSCP_VERSION="1.2.0-dev" MACSCP_BUILD="$(git rev-list --count HEAD)" ./scripts/package-app
```

Erwartet: `wrote dist/macSCP.app`. **Die App wird nicht gestartet.**

- [ ] **Schritt 3: Den Bericht schreiben**

Er nennt:

1. Die gemessenen Zeilenzahlen vorher/nachher und die neue Testzahl.
2. Welche Entscheidungslogik jetzt durch Tests gehalten wird und welche
   noch nicht.
3. **Ausdrücklich:** dass die Zusicherung „kein Verhalten geändert" durch
   Build und Suite gestützt ist, **nicht** durch eine Sichtprüfung — die
   GUI wurde nicht gestartet, und die Sichtprüfung liegt beim Maintainer.
4. Das Ergebnis von PV und was daraus für die Views folgt.
5. Was offen bleibt.

- [ ] **Schritt 4: Commit**

```bash
git add docs/superpowers/specs/2026-08-10-p0-entkernung-abschluss.md
git commit -m "docs(app): record the ContentView teardown"
```

---

## Selbstreview dieses Plans

**Spec-Abdeckung.** PV → Task 1. P0 „Aufteilen" → Tasks 7–11. P0
„Herausziehen mit Tests" → Tasks 2–6. „Kleine, einzeln committete
Schritte" → jeder Task committet einzeln, Teil B zusätzlich mit
Diff-Prüfung. „Dev-Build am Ende der Phase ist Pflicht" → Task 12
Schritt 2. „Nur `ContentView`" → keine andere große Datei kommt vor.

**Bewusste Lücke.** Die Spec nennt als Kandidaten auch „welcher Weg zum
externen Terminal genommen wird". `ExternalTerminalLauncher` ist seit
M29-P1 **bereits** ein eigener getesteter Typ; was in `ContentView` bleibt
(`requestExternalTerminal`, `performExternalOpen`), ist Verdrahtung und
wandert in Task 9 mit. Kein eigener Task nötig.

**Zwei Stellen, an denen dieser Plan raten könnte** — beide sind als
Anhalten-und-melden markiert statt als Vorgabe: die genaue Signatur von
`importResultText` (Task 6, Schritt 1) und die Frage, ob ein `SessionTab`
mit verbundener Sitzung im Test überhaupt herstellbar ist (Task 5,
Schritt 2). Ein Plan, der beides erfunden hätte, hätte Implementierer in
falsche Tests geschickt.
