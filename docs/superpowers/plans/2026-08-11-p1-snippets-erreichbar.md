# P1: Snippets erreichbar machen — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Snippets sind dort auslösbar, wo gearbeitet wird — Menüleiste,
Kontextmenü am Host, Terminal-Kopfzeile, Rechtsklick im Terminal — und die
Entscheidung „einfügen oder ausführen" fällt beim Auslösen statt beim
Anlegen.

**Architecture:** Ein Core-Typ `SnippetMenuModel` rechnet aus Snippets,
Tag-Filter und Verbindungszustand die fertige Menüstruktur aus; die vier
Auslöseflächen rendern nur noch daraus. Das Flag `runsImmediately`
verschwindet aus `Snippet`; `SnippetKeystrokes.bytes(for:execute:)` bekommt
die Entscheidung vom Aufrufer. Tags sind eine Modellregel, kein
Formulardetail.

**Tech Stack:** Swift 6, `.swiftLanguageMode(.v5)`, SwiftPM, macOS 15+,
SwiftUI, Swift Testing (`@Test`/`#expect`), zwei Testtargets
(`macSCPCoreTests`, `macSCPAppKitTests`).

## Global Constraints

- **Code, Kommentare, Testnamen: Englisch.** Interne Doku (`docs/`) darf
  Deutsch sein.
- **Nutzer-sichtbare Strings** über `L10n.string(_:_:)`; **jeder neue
  Schlüssel in allen vier Katalogen** (en/de/fr/pl). Nachweis: vorhandener
  Wächtertest plus `plutil -lint` über alle acht Kataloge.
- **Snippets enthalten nie Zugangsdaten.** Der Store ist JSON; Secrets
  leben ausschließlich im Schlüsselbund. Kein Snippet-Feld nimmt ein
  Secret auf, und kein Snippet-Text darf in einer Fehlermeldung landen.
- **Kein Secret in Log, Fehler oder Testfehlermeldung.** `#expect`
  expandiert seinen Ausdruck.
- **Nie eine Zeilennummer in einen Kommentar schreiben.** Das Ding benennen.
- **Die Prosa dieses Plans ist eine zu prüfende Behauptung, kein Fakt.** In
  der Vorphase steckte in fünf von elf Tasks ein echter Fehler im Brief.
  Stimmt etwas nicht mit dem Code überein: melden, nicht still umbauen.
- **Ein Test, der gegen eine konstante Rückgabe grün bleibt, ist kein
  Test.** Diese Probe vor jedem Commit selbst durchführen.
- **Commit/Push nur auf Anfrage** des Koordinators. Kein `scripts/release`.
- **Die GUI wird nicht gestartet.** `scripts/package-app` ist erlaubt.
- Conventional Commits, Englisch, Footer auf jedem Commit:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Volle Suite grün vor jedem Commit. Ausgangsstand: **1786 Tests in 150
  Suiten** — neu messen, nie abschreiben.

## Dateistruktur

| Datei | Verantwortung |
|---|---|
| `Sources/macSCPCore/Terminal/Snippet.swift` | Modell: `runsImmediately` raus, `tags` rein, Tag-Regel im Initializer |
| `Sources/macSCPCore/Terminal/SnippetKeystrokes.swift` | `bytes(for:execute:)` |
| `Sources/macSCPCore/Terminal/SnippetTagSuggestions.swift` | **neu** — Vorschlagsliste beim Tippen |
| `Sources/macSCPCore/Terminal/SnippetMenuModel.swift` | **neu** — die Struktur, aus der alle vier Flächen rendern |
| `Sources/MacSCPAppKit/SnippetTagField.swift` | **neu** — Token-Feld mit Vorschlägen |
| `Sources/MacSCPAppKit/SnippetsSheet.swift` | Editor ohne Häkchen, Filterzeile |
| `Sources/MacSCPAppKit/SnippetMenuItems.swift` | **neu** — die geteilte SwiftUI-Darstellung einer `SnippetMenuModel` |
| `Sources/MacSCPAppKit/MacSCPApp.swift` | Menüleiste auf das Modell |
| `Sources/MacSCPAppKit/SessionSidebar.swift` | Kontextmenü am Host |
| `Sources/MacSCPAppKit/ContentView+Detail.swift` | Terminal-Kopfzeile + Popover |
| `Sources/MacSCPAppKit/SSHTerminalView.swift` | Rechtsklick |
| `Sources/MacSCPAppKit/KeyboardShortcutsCatalog.swift` | Kürzel-Eintrag |

---

## Teil A: Core

### Task 1: Das Modell — Flag raus, Tags rein

**Files:**
- Modify: `Sources/macSCPCore/Terminal/Snippet.swift`
- Modify: `Tests/macSCPCoreTests/SnippetTests.swift`

**Interfaces:**
- Produces: `Snippet(id:name:command:tags:)` (failable), `Snippet.tags: [String]`.
  `runsImmediately` existiert nicht mehr.

- [ ] **Schritt 1: Den Ist-Zustand lesen**

`Snippet.swift` samt seines `init(from:)`, und die vorhandenen Tests. Der
Zeilenumbruch-Riegel und der Weg „Decode geht durch den validierenden
Initializer" bleiben **unverändert** — sie sind der Grund, warum eine von
Hand bearbeitete Datei die Regel nicht umgehen kann. Die Tag-Regel wird
genauso gebaut.

- [ ] **Schritt 2: Die fehlschlagenden Tests schreiben**

```swift
/// Whitespace around a tag is typing noise, not part of the tag.
@Test func aTagIsTrimmed() throws {
    let snippet = try #require(Snippet(name: "n", command: "c", tags: ["  docker  "]))
    #expect(snippet.tags == ["docker"])
}

/// A tag that is only whitespace carries no meaning and would render as an
/// empty chip nobody can aim at.
@Test func anEmptyTagIsDropped() throws {
    let snippet = try #require(Snippet(name: "n", command: "c", tags: ["docker", "   ", ""]))
    #expect(snippet.tags == ["docker"])
}

/// Case is preserved — the maintainer's decision. `Docker` and `docker` are
/// two tags, and the suggestion list (not the store) is what keeps users
/// from creating both by accident.
@Test func caseIsPreserved() throws {
    let snippet = try #require(Snippet(name: "n", command: "c", tags: ["Docker", "docker"]))
    #expect(snippet.tags == ["Docker", "docker"])
}

/// Exact duplicates collapse; order is the order they were entered in.
@Test func exactDuplicatesCollapseAndOrderSurvives() throws {
    let snippet = try #require(
        Snippet(name: "n", command: "c", tags: ["b", "a", "b"]))
    #expect(snippet.tags == ["b", "a"])
}

/// A store file written before tags existed still loads, and the flag it
/// carries is ignored rather than rejected — the user keeps their snippets.
@Test func aRoundOneStoreFileLoadsWithoutTags() throws {
    let json = Data("""
        {"id":"11111111-1111-1111-1111-111111111111","name":"Restart",
         "command":"systemctl restart nginx","runsImmediately":true}
        """.utf8)

    let snippet = try JSONDecoder().decode(Snippet.self, from: json)

    #expect(snippet.tags.isEmpty)
    #expect(snippet.command == "systemctl restart nginx")
}

/// The tag rule is a model rule, so a hand-edited file cannot smuggle an
/// untrimmed tag past it — the same reason the newline rule lives here.
@Test func aHandEditedTagIsNormalizedOnDecode() throws {
    let json = Data("""
        {"id":"22222222-2222-2222-2222-222222222222","name":"n",
         "command":"c","tags":["  docker  ","",  "docker  "]}
        """.utf8)

    let snippet = try JSONDecoder().decode(Snippet.self, from: json)

    #expect(snippet.tags == ["docker"])
}
```

- [ ] **Schritt 3: Rot laufen lassen**

Run: `swift test --filter SnippetTests`
Erwartet: FAIL — `tags` gibt es nicht.

- [ ] **Schritt 4: Das Modell ändern**

```swift
public struct Snippet: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let command: String
    /// Free-form labels that order snippets and group the trigger surfaces.
    /// Normalized at construction: trimmed, empties dropped, exact
    /// duplicates removed, order of first appearance kept, case left as
    /// typed. `let` for the same reason `command` is — an in-place mutation
    /// would be a second, unchecked write path around that normalization.
    public let tags: [String]

    public init?(id: UUID = UUID(), name: String, command: String, tags: [String] = []) {
        guard !command.contains("\n"), !command.contains("\r") else { return nil }
        self.id = id
        self.name = name
        self.command = command
        var seen = Set<String>()
        self.tags = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    …
}
```

`init(from:)` dekodiert `tags` mit `decodeIfPresent(… ) ?? []` und routet
weiter durch den Initializer oben. **`runsImmediately` wird nicht
dekodiert** — ein unbekannter Schlüssel stört `JSONDecoder` nicht, und die
Markierung soll ja entfallen. Der Doc-Kommentar des Typs muss aufhören,
`runsImmediately` zu erwähnen; der Absatz über den Zeilenumbruch braucht
eine neue Begründung, weil sie sich nicht mehr auf das Flag stützen kann.

- [ ] **Schritt 5: Grün, dann Aufrufer**

Run: `swift test --filter SnippetTests` → PASS.
Danach den ganzen Baum bauen: jeder Aufrufer von `runsImmediately` bricht
jetzt. **Nicht reparieren, sondern melden**, wenn eine Stelle mehr als das
Weglassen des Arguments braucht — Task 2 und Task 5 nehmen sie auf. Für
diesen Task genügt es, den Compiler mit dem minimalen Eingriff zu
befriedigen (Argument weglassen, Flag-Lesestellen vorläufig auf „einfügen"
setzen) und das im Bericht zu benennen.

- [ ] **Schritt 6: Volle Suite und Commit**

```bash
swift test
git add Sources/macSCPCore/Terminal/Snippet.swift Tests/macSCPCoreTests/SnippetTests.swift
git commit -m "feat(core): give snippets tags and drop the runs-immediately flag"
```

---

### Task 2: Die Bytes — Entscheidung wandert an den Aufruf

**Files:**
- Modify: `Sources/macSCPCore/Terminal/SnippetKeystrokes.swift`
- Modify: `Tests/macSCPCoreTests/SnippetKeystrokesTests.swift`

**Interfaces:**
- Consumes: `Snippet` ohne `runsImmediately` (Task 1).
- Produces: `SnippetKeystrokes.bytes(for snippet: Snippet, execute: Bool) -> [UInt8]`

- [ ] **Schritt 1: Den vorhandenen Code und seine Tests lesen**

Besonders den Doc-Kommentar über `terminator`. Das gemessene `0x0D` und
die Beweiskette dazu **bleiben wörtlich erhalten** — sie sind das Ergebnis
einer Messung, die in Runde 1 einen echten Fehler korrigiert hat.

- [ ] **Schritt 2: Die fehlschlagenden Tests schreiben**

```swift
/// Inserting never appends a terminator — that is the whole difference
/// between putting text in the input line and running it on the far host.
/// This holds for every caller, which is why it is asserted here and not
/// left to the four trigger surfaces.
@Test func insertingNeverAppendsATerminator() throws {
    let snippet = try #require(Snippet(name: "n", command: "uptime"))

    let bytes = SnippetKeystrokes.bytes(for: snippet, execute: false)

    #expect(bytes == Array("uptime".utf8))
}

/// Executing appends exactly one carriage return — not zero, not two.
@Test func executingAppendsExactlyOneCarriageReturn() throws {
    let snippet = try #require(Snippet(name: "n", command: "uptime"))

    let bytes = SnippetKeystrokes.bytes(for: snippet, execute: true)

    #expect(bytes == Array("uptime".utf8) + [0x0D])
}

/// The two differ in exactly one byte — a regression that made them equal
/// would otherwise pass whichever of the two tests above still matched.
@Test func theTwoCallsDifferByTheTerminatorAlone() throws {
    let snippet = try #require(Snippet(name: "n", command: "df -h"))

    let inserted = SnippetKeystrokes.bytes(for: snippet, execute: false)
    let executed = SnippetKeystrokes.bytes(for: snippet, execute: true)

    #expect(executed.count == inserted.count + 1)
    #expect(Array(executed.dropLast()) == inserted)
}
```

- [ ] **Schritt 3: Rot, implementieren, grün**

Run: `swift test --filter SnippetKeystrokes` → FAIL, dann die Signatur
ändern (`if execute { bytes.append(terminator) }`), dann PASS.

- [ ] **Schritt 4: Volle Suite und Commit**

```bash
swift test
git add Sources/macSCPCore/Terminal/SnippetKeystrokes.swift Tests/macSCPCoreTests/SnippetKeystrokesTests.swift
git commit -m "feat(core): let the caller decide whether a snippet executes"
```

---

### Task 3: Die Vorschlagsliste

Die Maintainer-Entscheidung lautet „nur trimmen, Groß/Klein bleibt". Damit
sind `Docker` und `docker` zwei Tags. Gedämpft wird das **an der Eingabe**:
wer `doc` tippt, bekommt das vorhandene `Docker` angeboten.

**Files:**
- Create: `Sources/macSCPCore/Terminal/SnippetTagSuggestions.swift`
- Create: `Tests/macSCPCoreTests/SnippetTagSuggestionsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum SnippetTagSuggestions {
      public static func all(in snippets: [Snippet]) -> [(tag: String, count: Int)]
      public static func matching(_ prefix: String, in snippets: [Snippet], excluding taken: [String]) -> [(tag: String, count: Int)]
  }
  ```
  Beide sortiert: absteigend nach `count`, bei Gleichstand alphabetisch
  (Groß/Klein-unempfindlich verglichen).

- [ ] **Schritt 1: Die fehlschlagenden Tests schreiben**

```swift
/// The whole point of the suggestion list: typing lowercase must surface an
/// existing differently-cased tag, so the user picks it instead of creating
/// a second one. The store keeps the case; only the search ignores it.
@Test func aLowercasePrefixFindsADifferentlyCasedTag() throws {
    let snippets = [try #require(Snippet(name: "n", command: "c", tags: ["Docker"]))]

    let matches = SnippetTagSuggestions.matching("doc", in: snippets, excluding: [])

    #expect(matches.map(\.tag) == ["Docker"])
}

/// A tag already on the snippet being edited is not offered again.
@Test func aTagAlreadyTakenIsNotOffered() throws {
    let snippets = [try #require(Snippet(name: "n", command: "c", tags: ["docker"]))]

    let matches = SnippetTagSuggestions.matching("doc", in: snippets, excluding: ["docker"])

    #expect(matches.isEmpty)
}

/// Counts drive the order, so the tags in heaviest use come first.
@Test func theMostUsedTagComesFirst() throws {
    let snippets = [
        try #require(Snippet(name: "a", command: "c", tags: ["rare", "common"])),
        try #require(Snippet(name: "b", command: "c", tags: ["common"])),
    ]

    let all = SnippetTagSuggestions.all(in: snippets)

    #expect(all.map(\.tag) == ["common", "rare"])
    #expect(all.map(\.count) == [2, 1])
}

/// An empty prefix offers everything not already taken — that is what the
/// list shows when the field is focused but empty.
@Test func anEmptyPrefixOffersEverythingUntaken() throws {
    let snippets = [try #require(Snippet(name: "n", command: "c", tags: ["a", "b"]))]

    let matches = SnippetTagSuggestions.matching("", in: snippets, excluding: ["a"])

    #expect(matches.map(\.tag) == ["b"])
}
```

- [ ] **Schritt 2: Rot, implementieren, grün, volle Suite, Commit**

Run: `swift test --filter SnippetTagSuggestions` → FAIL → PASS.

**Vor dem Commit die Konstant-Probe:** gäbe `matching` immer `[]` zurück,
welcher Test wird rot? Gäbe es alle Tags ungefiltert zurück, welcher? Beide
Antworten in den Bericht.

```bash
git commit -m "feat(core): suggest existing tags case-insensitively"
```

---

### Task 4: `SnippetMenuModel` — ein Typ, vier Flächen

**Files:**
- Create: `Sources/macSCPCore/Terminal/SnippetMenuModel.swift`
- Create: `Tests/macSCPCoreTests/SnippetMenuModelTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct SnippetMenuModel: Equatable, Sendable {
      public enum DisabledReason: Equatable, Sendable {
          case notConnected
          case backendHasNoShell
      }
      public struct Group: Identifiable, Equatable, Sendable {
          public var id: String { tag ?? "" }
          public let tag: String?          // nil = the untagged group
          public let snippets: [Snippet]
      }
      public let groups: [Group]
      public let disabledReason: DisabledReason?
      public var isEmpty: Bool { groups.isEmpty }

      public static func build(
          snippets: [Snippet], isConnected: Bool, supportsShell: Bool
      ) -> SnippetMenuModel
  }
  ```

**Zwei Entscheidungen, die hier festgeschrieben werden, damit sie nicht in
vier Views je anders ausfallen:**

1. **Ein Snippet mit zwei Tags erscheint unter beiden.** Das ist, was ein
   Tag bedeutet — man sucht es dort, wo man es einsortiert hat. Doppelte
   Einträge im Menü sind der Preis und sind gewollt.
2. **Untagged kommt zuletzt**, in einer Gruppe mit `tag == nil`. Sonst
   wären genau die Snippets unauffindbar, die noch nicht einsortiert sind.

- [ ] **Schritt 1: Die fehlschlagenden Tests schreiben**

```swift
/// A snippet carrying two tags is reachable under both — that is what a tag
/// is for. The duplicate entry is deliberate, not an oversight.
@Test func aSnippetWithTwoTagsAppearsUnderBoth() throws {
    let snippet = try #require(Snippet(name: "n", command: "c", tags: ["a", "b"]))

    let model = SnippetMenuModel.build(
        snippets: [snippet], isConnected: true, supportsShell: true)

    #expect(model.groups.map(\.tag) == ["a", "b"])
    #expect(model.groups.allSatisfy { $0.snippets == [snippet] })
}

/// Untagged snippets are last, never dropped — otherwise the ones nobody
/// has sorted yet become unreachable, which is the state every new snippet
/// starts in.
@Test func untaggedSnippetsComeLastAndAreNeverDropped() throws {
    let tagged = try #require(Snippet(name: "t", command: "c", tags: ["a"]))
    let untagged = try #require(Snippet(name: "u", command: "c"))

    let model = SnippetMenuModel.build(
        snippets: [untagged, tagged], isConnected: true, supportsShell: true)

    #expect(model.groups.map(\.tag) == ["a", nil])
    #expect(model.groups.last?.snippets == [untagged])
}

/// Order inside a group is store order, not alphabetical — the user's own
/// arrangement survives.
@Test func orderInsideAGroupIsStoreOrder() throws {
    let second = try #require(Snippet(name: "zeta", command: "c", tags: ["a"]))
    let first = try #require(Snippet(name: "alpha", command: "c", tags: ["a"]))

    let model = SnippetMenuModel.build(
        snippets: [second, first], isConnected: true, supportsShell: true)

    #expect(model.groups.first?.snippets.map(\.name) == ["zeta", "alpha"])
}

/// Without a connection there is no shell to send to. The entries stay
/// visible — a disabled entry teaches where the feature lives; a missing
/// one teaches nothing — but they carry the reason.
@Test func aDisconnectedTabDisablesTheEntriesWithoutHidingThem() throws {
    let snippet = try #require(Snippet(name: "n", command: "c"))

    let model = SnippetMenuModel.build(
        snippets: [snippet], isConnected: false, supportsShell: true)

    #expect(model.disabledReason == .notConnected)
    #expect(model.groups.isEmpty == false)
}

/// S3 and WebDAV have no shell at all. That is a different reason from "not
/// connected yet" and the two must not collapse — the first is permanent
/// for this backend, the second goes away when the user connects.
@Test func aBackendWithoutAShellIsADistinctReason() throws {
    let snippet = try #require(Snippet(name: "n", command: "c"))

    let model = SnippetMenuModel.build(
        snippets: [snippet], isConnected: true, supportsShell: false)

    #expect(model.disabledReason == .backendHasNoShell)
}

/// No snippets means no groups — the surfaces show their own empty hint
/// rather than an empty group box.
@Test func noSnippetsMeansNoGroups() {
    let model = SnippetMenuModel.build(
        snippets: [], isConnected: true, supportsShell: true)

    #expect(model.isEmpty)
    #expect(model.disabledReason == nil)
}
```

- [ ] **Schritt 2: Rot, implementieren, grün**

Gruppen-Reihenfolge: Tags alphabetisch (Groß/Klein-unempfindlich
verglichen, bei Gleichstand stabil), `nil` zuletzt.

**Wenn `isConnected == false` und `supportsShell == false` gleichzeitig
gelten:** entscheide dich für einen Vorrang, schreibe ihn in den
Doc-Kommentar und pinne ihn mit einem Test. Ein Fall ohne festgelegte
Antwort wird sonst in vier Views vier Mal anders geraten.

- [ ] **Schritt 3: Konstant-Probe, volle Suite, Commit**

Gäbe `build` immer ein Modell ohne Gruppen zurück — welcher Test wird rot?
Immer `disabledReason == nil`? In den Bericht.

```bash
git commit -m "feat(core): derive the snippet menu structure in one tested place"
```

---

## Teil B: App

### Task 5: Das Verwaltungs-Sheet — Häkchen raus, Tags rein

**Files:**
- Create: `Sources/MacSCPAppKit/SnippetTagField.swift`
- Modify: `Sources/MacSCPAppKit/SnippetsSheet.swift`
- Modify: die vier `Localizable.xcstrings` (en/de/fr/pl)
- Modify: `Tests/macSCPAppKitTests/SnippetsPresentationTests.swift` (falls
  `SnippetMenuEntry.title(for:)` entfällt — siehe unten)

- [ ] **Schritt 1: Lesen, was da ist**

`SnippetsSheet.swift` ganz, `SnippetsPresentation.swift` ganz.
`SheetSearchField` aus M18 existiert und wird wiederverwendet.

**`SnippetMenuEntry.title(for:)` verliert seinen Zweck** — es markierte
ausführende Snippets im Titel, und ausführende Snippets gibt es nicht mehr.
Entferne es samt seinen Tests. Prüfe per Compiler, nicht per `grep`, dass
kein Aufrufer bleibt.

- [ ] **Schritt 2: Das Token-Feld**

`SnippetTagField` ist ein `View` mit `@Binding var tags: [String]` und
einem `suggestions: (String) -> [(tag: String, count: Int)]`-Closure (aus
`SnippetTagSuggestions`, hereingereicht statt selbst gebaut — dieselbe
Naht, die `SessionSecretPolicy` testbar gemacht hat).

Verhalten: gesetzte Tags als Chips mit Entfernen-Knopf; beim Tippen eine
Vorschlagsliste mit Anzahl; **letzter Eintrag immer** „*x* als neuen Tag
anlegen". Return übernimmt den markierten Vorschlag, Komma schließt den
getippten Tag ab, Backspace im leeren Feld entfernt den letzten Chip.

**Neue L10n-Schlüssel** (Vorschlag, Wortlaut ist deine Entscheidung, aber
in allen vier Katalogen identisch benannt):
`snippets.tags.label`, `snippets.tags.placeholder`,
`snippets.tags.createNew`, `snippets.tags.remove`,
`snippets.filter.all`, `snippets.filter.untagged`.

- [ ] **Schritt 3: Editor und Filterzeile**

Im Editor: das „sofort ausführen"-Häkchen **entfernen**, das Tag-Feld
darunter. Unter dem vorhandenen Suchfeld eine Chip-Zeile: „Alle", je ein
Chip pro Tag mit Anzahl, dazu „ohne Tag". **Einwertig** — ein Chip zur
Zeit, „Alle" setzt zurück.

- [ ] **Schritt 4: Kataloge und Suite**

```bash
swift test
for f in $(git ls-files '*.xcstrings'); do plutil -lint "$f"; done
```
Erwartet: Suite grün, alle Kataloge OK, der vorhandene Wächtertest hält die
Schlüsselmengen zusammen.

- [ ] **Schritt 5: Commit**

```bash
git commit -m "feat(app): tag snippets in the editor and filter the list by tag"
```

---

### Task 6: Die Menüleiste auf das Modell

**Files:**
- Create: `Sources/MacSCPAppKit/SnippetMenuItems.swift`
- Modify: `Sources/MacSCPAppKit/MacSCPApp.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift` (`triggerSnippet`)
- Modify: `Sources/MacSCPAppKit/KeyboardShortcutsCatalog.swift`
- Modify: die vier Kataloge

- [ ] **Schritt 1: Lesen**

`snippetMenuItems` und `snippetButton` in `MacSCPApp.swift`,
`triggerSnippet` in `ContentView.swift`, `SnippetsLoad` in
`SnippetsPresentation.swift` (**bleibt** — ein unlesbarer Store darf nie
wie ein leerer aussehen).

- [ ] **Schritt 2: Die geteilte Darstellung**

`SnippetMenuItems` ist ein `View`, der aus einer `SnippetMenuModel` die
Einträge rendert: Untermenü je Gruppe, pro Snippet **zwei** Aktionen
(„Einfügen", „Ausführen"). Es bekommt die Aktion als Closure
`(Snippet, Bool) -> Void` herein — dasselbe Stück wird in Task 7 und 8
wiederverwendet, damit die vier Flächen nachweislich aus einem Modell
lesen.

- [ ] **Schritt 3: `triggerSnippet` auf zwei Aktionen**

`triggerSnippet(_ snippet: Snippet, execute: Bool)`, reicht `execute` an
`SnippetKeystrokes.bytes(for:execute:)` durch. Sonst unverändert.

- [ ] **Schritt 4: Kürzel**

⌃⌘1–3 **fügen** die ersten drei Snippets in Speicherreihenfolge ein.
**Ausführen bekommt kein Kürzel** — ein Tastendruck, der sofort auf einem
Host läuft, hat keinen guten Fehlerfall. Den Shortcuts-Katalog aus M11q
mitpflegen; sein Doc-Kommentar nennt das als Pflicht.

- [ ] **Schritt 5: Suite, Kataloge, Commit**

```bash
swift test && for f in $(git ls-files '*.xcstrings'); do plutil -lint "$f"; done
git commit -m "feat(app): offer insert and execute for every snippet in the Terminal menu"
```

---

### Task 7: Kontextmenü am Host

**Files:**
- Modify: `Sources/MacSCPAppKit/SessionSidebar.swift`
- Modify: die vier Kataloge

- [ ] **Schritt 1: Lesen**

Die vorhandenen `.contextMenu`-Blöcke in `SessionSidebar.swift` — es gibt
mehrere, für Sitzungszeile, Gruppe und importierten Host. **Nur die
Sitzungszeile** bekommt den Snippet-Eintrag.

- [ ] **Schritt 2: Verdrahten**

Ein Untermenü „Snippet", das `SnippetMenuItems` mit derselben
`SnippetMenuModel` rendert. Deaktiviert über
`BackendDescriptor.descriptor(for:).capabilities.supportsShell` — S3- und
WebDAV-Sitzungen zeigen den Eintrag grau statt ins Leere zu laufen.

**Zu klären und im Bericht zu beantworten:** eine Sitzung in der Sidebar
ist nicht notwendig die **aktive** — auf welche Shell schickt der Eintrag?
Entscheide dich, schreibe es in den Doc-Kommentar, und wenn die Antwort
„nur für die aktive Sitzung, sonst deaktiviert" lautet, sag das dem Nutzer
im Menü statt es stumm zu tun.

- [ ] **Schritt 3: Suite, Kataloge, Commit**

```bash
git commit -m "feat(app): reach snippets from a session's context menu"
```

---

### Task 8: Terminal-Kopfzeile mit Popover

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView+Detail.swift` (`terminalPanel`)
- Modify: die vier Kataloge

- [ ] **Schritt 1: Messen, bevor du baust**

Notiere den **heutigen** Randwert und die Höhe des Terminal-Streifens aus
`terminalPanel`. Die Zahl kommt in den Bericht. **Ändere sie nicht** — der
Rand ist P2, nicht dieser Task. Diese Kopfzeile kommt hinzu, weil das
Popover sie braucht.

- [ ] **Schritt 2: Die Kopfzeile**

Schmale Zeile über der Terminalfläche: links der Host, rechts ein
Snippet-Knopf. Der Knopf öffnet ein Popover mit `SheetSearchField` und
`SnippetMenuItems` auf derselben `SnippetMenuModel`.

- [ ] **Schritt 3: Suite, Kataloge, Commit**

```bash
git commit -m "feat(app): give the terminal panel a header with a snippet picker"
```

---

### Task 9: Rechtsklick im Terminal

**Files:**
- Modify: `Sources/MacSCPAppKit/SSHTerminalView.swift`

- [ ] **Schritt 1: Messen, nicht folgern**

Aus dem Quelltext von SwiftTerms `MacTerminalView` ist bekannt: **keine
Überschreibung von `rightMouseDown`, kein `menu(for:)`**, wohl aber eine
`paste(_:)`-Aktion. Daraus folgt **nicht**, dass ein gesetztes Menü auch
ankommt.

Stelle fest, ob ein auf der gehosteten View gesetztes `NSMenu` beim
Rechtsklick erscheint, und ob dadurch etwas verlorengeht, das die
Terminalfläche heute mit der rechten Maustaste tut. Halte fest, **wie** du
es festgestellt hast. Geht es nicht ohne GUI-Start: sag das, und trage den
Punkt als offene Sichtprüfung in den Bericht — **starte die GUI nicht**.

- [ ] **Schritt 2: Verdrahten oder melden**

Trägt es: dieselben Einträge wie in Task 6, über `SnippetMenuItems`.
Trägt es nicht: **melden statt improvisieren.** Ein halb funktionierender
Rechtsklick ist schlechter als keiner.

- [ ] **Schritt 3: Suite und Commit**

```bash
git commit -m "feat(app): reach snippets by right-clicking the terminal"
```

---

## Teil C: Abschluss

### Task 10: Phasenabschluss

**Files:**
- Create: `docs/superpowers/specs/2026-08-11-p1-snippets-abschluss.md`

- [ ] **Schritt 1: Messen**

```bash
swift test 2>&1 | tail -3
for f in $(git ls-files '*.xcstrings'); do plutil -lint "$f"; done
MACSCP_VERSION="1.2.0-dev" MACSCP_BUILD="$(git rev-list --count HEAD)" ./scripts/package-app
```
Alle Zahlen neu messen. **Die App wird nicht gestartet.**

- [ ] **Schritt 2: Bericht**

Er nennt: die gemessenen Zahlen; dass alle vier Flächen aus **einem**
Modell lesen und dass das der Nachweis im Code ist, kein Test; welche
Kriterien Review-Punkte statt Tests sind; das Ergebnis der
Rechtsklick-Messung; und **ausdrücklich**, dass die GUI nicht gestartet
wurde und welche Sichtprüfungen beim Maintainer liegen — Kopfzeile,
Popover, Kontextmenü, Filterzeile, Token-Feld.

- [ ] **Schritt 3: Commit**

```bash
git commit -m "docs(app): record the snippet trigger surfaces"
```

---

## Selbstreview dieses Plans

**Spec-Abdeckung** (Abschnitt „P1" der Spec): Modell + Migration → T1.
Tag-Regel → T1. Vorschlagsliste → T3. Bytes → T2. `SnippetMenuModel` → T4.
Tag-Eingabefeld → T5. Filterzeile → T5. Vier Auslöseflächen → T6/T7/T8/T9.
Kürzel + Katalog → T6. Beide „zu messen"-Punkte: Rechtsklick → T9 Schritt 1;
Terminal-Rand → T8 Schritt 1 misst ihn, ändert ihn aber bewusst erst in P2.

**Drei Stellen, an denen dieser Plan bewusst nicht rät**, sondern den
Implementierer entscheiden und begründen lässt: der Vorrang zwischen
`notConnected` und `backendHasNoShell` (T4), auf welche Shell das
Host-Kontextmenü schickt (T7), und ob der Rechtsklick überhaupt trägt (T9).
Alle drei sind mit „entscheiden, in den Doc-Kommentar schreiben, pinnen"
bzw. „melden statt improvisieren" versehen — nicht mit einer erfundenen
Antwort.

**Nicht Teil davon:** der Terminal-Rand und das reine Terminal-Fenster
(P2), Host-Tags und Import/Export (P3), der Massen-Runner, mehrzeilige
Kommandos, Syntax-Hervorhebung, Platzhalter, Agent-Forwarding.
