# P3a: Host-Tags und Sidebar-Filter — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gespeicherte Hosts bekommen Tags, und die Sidebar bekommt ihr
erstes Filterelement — eine Chip-Reihe, die auf einen Tag einschränkt.

**Architecture:** Die Tag-Normalisierung liegt als **eine** Funktion in
Core und wird von `Snippet` und `StoredSession` aufgerufen. Welche Gruppen
und Sitzungen bei aktivem Tag sichtbar sind und welcher Leer-Zustand gilt,
ist ein testbarer Core-Typ; die Sidebar liest daraus und entscheidet nichts
selbst.

**Tech Stack:** Swift 6, `.swiftLanguageMode(.v5)`, SwiftPM, macOS 15+,
SwiftUI, Swift Testing, zwei Testtargets.

Spec: `docs/superpowers/specs/2026-08-18-p3-ordnung-design.md`, Abschnitt P3a.

## Global Constraints

- **Code, Kommentare, Testnamen: Englisch.** Interne Doku (`docs/`) Deutsch.
- **Jeder neue L10n-Schlüssel in allen vier Katalogen** (en/de/fr/pl),
  identische Schlüsselmengen. Nachweis:
  `for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done`
- **Nie eine Zeilennummer in einen Kommentar.**
- **Kein Secret in Log, Fehler oder Testfehlermeldung.**
- **Die Prosa dieses Plans ist eine zu prüfende Behauptung.** In den beiden
  Vorphasen steckte in mehreren Briefs ein echter Fehler. Weicht der Code
  ab, ist **der Plan** falsch — melden, nicht anpassen.
- **Zwei Proben vor jedem Commit**, beide:
  1. Bliebe ein Test grün, wenn die Funktion konstant zurückgäbe?
  2. **Welche Behauptung meines Doc-Kommentars beobachtet kein Test?**
     Diese Frage hat in P2 in jeder Task eine echte Lücke gefunden, darunter
     ein Critical und einen schlicht falschen Kommentar.
- **Die GUI wird nicht gestartet.** `scripts/package-app` ist erlaubt,
  `scripts/release` nicht.
- Conventional Commits, Englisch, Footer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Volle Suite grün vor jedem Commit. Ausgangsstand: **1958 Tests in 166
  Suiten** — selbst nachmessen, nie abschreiben.

## Dateien

| Datei | Zuständig für |
|---|---|
| `Sources/macSCPCore/Tags/TagList.swift` (neu) | die eine Normalisierungsregel |
| `Sources/macSCPCore/Terminal/Snippet.swift` | ruft sie auf statt sie zu wiederholen |
| `Sources/macSCPCore/Sessions/StoredSession.swift` | `tags`-Feld + Decode-Standard |
| `Sources/macSCPCore/Sessions/SessionExportCodec.swift` | `tags` im Austauschformat |
| `Sources/macSCPCore/Presentation/SidebarVisibility.swift` (neu) | was bei aktivem Tag sichtbar ist |
| `Sources/macSCPCore/Presentation/SessionListViewModel.swift` | `save(… tags:)` |
| `Sources/MacSCPAppKit/ConnectionFormView.swift` | Tag-Feld im Formular |
| `Sources/MacSCPAppKit/SessionSidebar.swift` | Chip-Reihe, Leer-Zustand, Verdrahtung |

---

### Task 1: Eine Regel, zwei Aufrufer

**Gemessener Ist-Zustand:** `Snippet.init?` normalisiert inline:

```swift
var seen = Set<String>()
self.tags = tags
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty && seen.insert($0).inserted }
```

Prüfe das selbst am Code, bevor du es verschiebst.

**Files:**
- Create: `Sources/macSCPCore/Tags/TagList.swift`
- Modify: `Sources/macSCPCore/Terminal/Snippet.swift`
- Create: `Tests/macSCPCoreTests/TagListTests.swift`

**Interfaces:**
- Produces: `public enum TagList { public static func normalized(_ tags: [String]) -> [String] }`

- [ ] **Schritt 1: Die Tests zuerst**

```swift
@Test func normalizationTrimsDropsEmptiesAndDeduplicatesKeepingOrder() {
    #expect(TagList.normalized(["  docker ", "", "web", "docker", "   "])
            == ["docker", "web"])
}

@Test func normalizationKeepsCaseSoTwoSpellingsStayTwoTags() {
    #expect(TagList.normalized(["Docker", "docker"]) == ["Docker", "docker"])
}

@Test func normalizationIsIdempotent() {
    let once = TagList.normalized([" a ", "b", "a"])
    #expect(TagList.normalized(once) == once)
}
```

- [ ] **Schritt 2: Rot laufen lassen**

Run: `swift test --filter TagListTests`
Erwartet: FAIL, `TagList` existiert nicht.

- [ ] **Schritt 3: Die Funktion**

```swift
/// The one normalization every tag vocabulary in this app goes through:
/// trimmed, empties dropped, exact duplicates dropped, order of first
/// appearance kept, case left as typed.
///
/// Case is deliberately preserved — `Docker` and `docker` stay two tags.
/// Damping that is the input control's job (a case-insensitive suggestion
/// list), not this function's: folding case here would silently rewrite
/// what the user typed.
///
/// Host tags and snippet tags remain INDEPENDENT vocabularies — a host tag
/// hides no snippet. Only the rule is shared, because two copies of one
/// rule drift apart without any test noticing.
public enum TagList {
    public static func normalized(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
```

- [ ] **Schritt 4: `Snippet` ruft auf statt zu wiederholen**

In `Snippet.init?` die vier Zeilen ersetzen durch:

```swift
self.tags = TagList.normalized(tags)
```

Den Doc-Kommentar an `Snippet.tags` so anpassen, dass er auf `TagList`
verweist, statt die Regel ein zweites Mal in Prosa zu beschreiben.

- [ ] **Schritt 5: Der Äquivalenz-Wächter**

Ein Test, der beide Wege gegen dieselben Eingaben vergleicht — er ist der
Grund, warum diese Task existiert:

```swift
@Test func snippetTagsGoThroughTheSharedRule() {
    let inputs: [[String]] = [
        ["  docker ", "", "web", "docker"],
        ["Docker", "docker"],
        [],
        ["   "],
        ["a", "b", "a", "b"],
    ]
    for input in inputs {
        let snippet = Snippet(name: "n", command: "c", tags: input)
        #expect(snippet?.tags == TagList.normalized(input))
    }
}
```

- [ ] **Schritt 6: Grün + volle Suite + Commit**

```bash
swift test --filter TagListTests
swift test
git commit -m "refactor(core): give both tag vocabularies one normalization"
```

---

### Task 2: `tags` am `StoredSession`

**Gemessener Ist-Zustand:** `StoredSession` hat einen **expliziten**
`init(from:)` mit `private enum CodingKeys`. `paneVisibility` wird dort als
`decodeIfPresent(…) ?? .filesOnly` gelesen — genau das Muster, das dieses
Feld braucht. `groupID` ist der Präzedenzfall für ein Feld, das zur Sitzung
gehört, aber **keine Verbindungseigenschaft** ist. Tags gehören in dieselbe
Kategorie, **nicht** in `FieldValues`.

**Files:**
- Modify: `Sources/macSCPCore/Sessions/StoredSession.swift`
- Create: `Tests/macSCPCoreTests/StoredSessionTagsTests.swift`

**Interfaces:**
- Consumes: `TagList.normalized(_:)` aus Task 1
- Produces: `StoredSession.tags: [String]`, Parameter `tags: [String] = []` in `init`

- [ ] **Schritt 1: Der Test zuerst — gegen eine wörtliche Alt-Datei**

```swift
@Test func aStoredSessionWithoutTheTagsKeyDecodesAsUntagged() throws {
    let json = """
    {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"box","kind":"ssh"}
    """
    let session = try JSONDecoder().decode(StoredSession.self, from: Data(json.utf8))
    #expect(session.tags.isEmpty)
}

@Test func decodingNormalizesTagsSoAHandEditedFileCannotSmuggleDuplicates() throws {
    let json = """
    {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"box","kind":"ssh",
     "tags":["  docker ","docker",""]}
    """
    let session = try JSONDecoder().decode(StoredSession.self, from: Data(json.utf8))
    #expect(session.tags == ["docker"])
}

@Test func tagsSurviveAnEncodeDecodeRoundTrip() throws {
    let original = StoredSession(name: "box", tags: ["docker", "web"])
    let data = try JSONEncoder().encode(original)
    let restored = try JSONDecoder().decode(StoredSession.self, from: data)
    #expect(restored.tags == ["docker", "web"])
}
```

- [ ] **Schritt 2: Rot laufen lassen**

Run: `swift test --filter StoredSessionTagsTests`
Erwartet: FAIL — `tags` existiert nicht (Compile-Fehler beim dritten Test,
`session.tags` beim ersten).

- [ ] **Schritt 3: Das Feld**

Eigenschaft neben `paneVisibility`:

```swift
/// Free-form labels for the sidebar's tag filter. Normalized through
/// `TagList` on every write path — the initializer AND the decoder — so a
/// hand-edited store file cannot smuggle an untrimmed or duplicate tag
/// past the rule.
///
/// Beside `groupID` and `paneVisibility` rather than inside `FieldValues`:
/// a tag is a property of the saved session, not of the protocol it speaks.
public var tags: [String] = []
```

`init`: Parameter `tags: [String] = []`, zugewiesen als
`self.tags = TagList.normalized(tags)`.

`CodingKeys`: `tags` ergänzen.

`init(from:)`:

```swift
tags = TagList.normalized(try c.decodeIfPresent([String].self, forKey: .tags) ?? [])
```

- [ ] **Schritt 4: Grün + volle Suite + Commit**

```bash
swift test --filter StoredSessionTagsTests
swift test
git commit -m "feat(core): let a saved session carry tags"
```

---

### Task 3: Tags überleben Export und Import

**Gemessener Ist-Zustand:** `ExportedSession` in
`Sources/macSCPCore/Sessions/SessionExportCodec.swift` trägt
`public var paneVisibility: PaneVisibility?`, listet es in seinen
`CodingKeys` und schreibt es mit `encodeIfPresent`. Sieh dir an, was der
Export mit `paneVisibility` **und** mit `groupID` tut, und mach es genauso.
Schreib in den Bericht, was du vorgefunden hast.

**Files:**
- Modify: `Sources/macSCPCore/Sessions/SessionExportCodec.swift`
- Modify/Create: die zugehörigen Tests

**Interfaces:**
- Consumes: `StoredSession.tags` aus Task 2

- [ ] **Schritt 1: Der Test zuerst**

```swift
@Test func exportRoundTripCarriesTags() throws {
    let session = StoredSession(name: "box", tags: ["docker", "web"])
    let exported = ExportedSession(from: session)   // die tatsächliche
                                                    // Bau-Stelle benutzen
    let data = try JSONEncoder().encode(exported)
    let restored = try JSONDecoder().decode(ExportedSession.self, from: data)
    #expect(restored.tags == ["docker", "web"])
}

@Test func anExportFileWithoutTheTagsKeyImportsAsUntagged() throws {
    // Wörtliches Alt-JSON eines ExportedSession, ohne "tags".
    // Die genauen Pflichtfelder aus dem Typ ablesen, nicht raten.
}
```

Den zweiten Test **ausformulieren**, sobald du die Pflichtfelder von
`ExportedSession` gelesen hast — er ist der Migrationsnachweis und darf
nicht als Skizze stehen bleiben.

- [ ] **Schritt 2: Rot, dann Feld ergänzen**

`tags` an `ExportedSession` nach dem Muster von `paneVisibility`
(inkl. `CodingKeys`, `decodeIfPresent`, `encodeIfPresent` bzw. `encode` —
**wie der vorhandene Präzedenzfall es macht**, nicht wie du es lieber
hättest). Beide Richtungen verdrahten: Sitzung → Export und Import →
Sitzung.

- [ ] **Schritt 3: Grün + volle Suite + Commit**

```bash
swift test
git commit -m "feat(core): carry session tags through export and import"
```

---

### Task 4: Was bei aktivem Tag sichtbar ist (Core)

**Warum Core:** In P2 lag eine Anzeigeentscheidung im View-Body und war am
Ende nur noch mit einem Quelltext-Wächter zu sichern, nachdem sie ein leeres
Fenster erzeugen konnte. Diese Entscheidung wird von vornherein ein
testbarer Typ.

**Gemessener Ist-Zustand:** `SessionListViewModel.sessions(inGroup:)`
filtert `sessions.filter { $0.groupID == groupID }`. `StoredGroup` hat
`id` und `name`. Die Sidebar rendert Gruppen als `Section` und daneben eine
eigene Section „IMPORTIERT". `SnippetTagFilter` liegt in der **App**-Schicht
(`SnippetsPresentation.swift`) und ist hier **nicht** wiederverwendbar — es
beantwortet eine andere Frage (passt ein Snippet?) als diese (was zeigt die
Liste?).

**Files:**
- Create: `Sources/macSCPCore/Presentation/SidebarVisibility.swift`
- Create: `Tests/macSCPCoreTests/SidebarVisibilityTests.swift`

**Interfaces:**
- Produces:

```swift
public struct SidebarVisibility: Equatable, Sendable {
    public enum Emptiness: Equatable, Sendable {
        case notEmpty
        case noSessionsAtAll
        case filterMatchesNothing
    }
    public let groups: [StoredGroup]
    public let ungrouped: [StoredSession]
    public let sessionsByGroup: [UUID: [StoredSession]]
    public let showsImportedSection: Bool
    public let emptiness: Emptiness

    public static func compute(
        sessions: [StoredSession],
        groups: [StoredGroup],
        activeTag: String?
    ) -> SidebarVisibility

    public static func availableTags(in sessions: [StoredSession]) -> [String]

    public static func resolvedTag(_ activeTag: String?, in sessions: [StoredSession]) -> String?
}
```

- [ ] **Schritt 1: Die Tests zuerst**

```swift
private func session(_ name: String, group: UUID? = nil, tags: [String] = [])
    -> StoredSession {
    StoredSession(name: name, groupID: group, tags: tags)
}

@Test func withoutAFilterEverythingShows() {
    let g = StoredGroup(name: "prod")
    let v = SidebarVisibility.compute(
        sessions: [session("a", group: g.id), session("b")],
        groups: [g], activeTag: nil)
    #expect(v.groups == [g])
    #expect(v.ungrouped.map(\.name) == ["b"])
    #expect(v.showsImportedSection)
    #expect(v.emptiness == .notEmpty)
}

@Test func anActiveTagHidesGroupsWithoutAMatchAndTheImportedSection() {
    let hit = StoredGroup(name: "prod")
    let miss = StoredGroup(name: "lab")
    let v = SidebarVisibility.compute(
        sessions: [session("a", group: hit.id, tags: ["docker"]),
                   session("b", group: miss.id)],
        groups: [hit, miss], activeTag: "docker")
    #expect(v.groups == [hit])
    #expect(v.sessionsByGroup[hit.id]?.map(\.name) == ["a"])
    #expect(v.sessionsByGroup[miss.id] == nil)
    #expect(!v.showsImportedSection)
}

@Test func theTwoEmptyStatesAreDistinguishable() {
    let none = SidebarVisibility.compute(sessions: [], groups: [], activeTag: nil)
    #expect(none.emptiness == .noSessionsAtAll)

    let filtered = SidebarVisibility.compute(
        sessions: [session("a", tags: ["web"])], groups: [], activeTag: "docker")
    #expect(filtered.emptiness == .filterMatchesNothing)
}

@Test func tagComparisonIsExactSoTwoSpellingsStayTwoTags() {
    let v = SidebarVisibility.compute(
        sessions: [session("a", tags: ["Docker"])], groups: [], activeTag: "docker")
    #expect(v.emptiness == .filterMatchesNothing)
}

@Test func availableTagsAreSortedAndDeduplicatedAcrossSessions() {
    #expect(SidebarVisibility.availableTags(in: [
        session("a", tags: ["web", "docker"]),
        session("b", tags: ["docker"]),
    ]) == ["docker", "web"])
}

@Test func aTagNobodyCarriesAnymoreResolvesToNoFilter() {
    #expect(SidebarVisibility.resolvedTag("gone", in: [session("a", tags: ["web"])]) == nil)
    #expect(SidebarVisibility.resolvedTag("web", in: [session("a", tags: ["web"])]) == "web")
}
```

- [ ] **Schritt 2: Rot laufen lassen**

Run: `swift test --filter SidebarVisibilityTests`
Erwartet: FAIL — `SidebarVisibility` existiert nicht.

- [ ] **Schritt 3: Der Typ**

`compute` filtert bei nicht-nil `activeTag` auf `tags.contains(activeTag)`
(exakter Vergleich, wie `SnippetTagFilter.matches` es tut), lässt Gruppen
ohne Treffer weg, setzt `showsImportedSection = (activeTag == nil)` und
bestimmt `emptiness` aus (sind überhaupt Sitzungen da?) und (ist gefiltert
und nichts übrig?).

`availableTags` sammelt alle Tags aller Sitzungen, dedupliziert und sortiert
sie (`sorted()`, damit die Chip-Reihe stabil steht).

`resolvedTag` gibt `nil` zurück, wenn den Tag niemand mehr trägt.

**Die zweite Probe hier ausdrücklich stellen:** jede Behauptung, die du in
den Doc-Kommentar schreibst, braucht einen Test, der sie beobachtet — oder
sie darf nicht dort stehen.

- [ ] **Schritt 4: Grün + volle Suite + Commit**

```bash
swift test --filter SidebarVisibilityTests
swift test
git commit -m "feat(core): decide what the sidebar shows while a tag is active"
```

---

### Task 5: Tags im Verbindungsformular

**Gemessener Ist-Zustand:** `SessionListViewModel.save` hat heute die
Signatur

```swift
public func save(
    name: String, values: FieldValues, password: String,
    kind: ConnectionKind = .ssh,
    groupID: UUID? = nil, loginSetID: UUID? = nil,
    jump: StoredSession.JumpSpec? = nil, jumpSecret: String? = nil
) -> StoredSession?
```

Sie sucht eine bestehende Sitzung **über den Namen** und mutiert sie,
sonst baut sie eine neue. `ConnectionFormView` (rund 1000 Zeilen) rendert
das Namensfeld in einem `TextField` nahe dem Formularanfang; die
Backend-Felder kommen aus dem generischen `SchemaFormView`. Ein Tag ist
**kein** Schema-Feld und gehört neben den Namen, nicht in den Renderer.

`SnippetTagField` (`Sources/MacSCPAppKit/SnippetTagField.swift`) ist ein
`View` mit `@Binding var tags: [String]`. **Miss selbst nach, ob es sich
ohne Änderung wiederverwenden lässt** — hängt es an Snippet-spezifischen
Vorschlägen, dann trenne den Vorschlagsteil ab oder baue ein gleich
aussehendes Feld, das dieselbe `TagList`-Regel benutzt. Was davon zutrifft,
gehört in den Bericht.

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift`
- Modify: `Sources/MacSCPAppKit/ConnectionFormView.swift`
- Modify: alle vier `Localizable.strings`
- Modify/Create: Tests

**Interfaces:**
- Consumes: `StoredSession.tags`, `TagList.normalized(_:)`
- Produces: `save(… tags: [String] = [])`

- [ ] **Schritt 1: Der VM-Test zuerst**

```swift
@Test func savingCarriesTagsOntoTheStoredSession() throws {
    // Vorhandenen VM-Testaufbau dieses Testtargets benutzen.
    let saved = viewModel.save(name: "box", values: values, password: "",
                               tags: ["  docker ", "docker", "web"])
    #expect(saved?.tags == ["docker", "web"])
}

@Test func savingAgainUnderTheSameNameReplacesTheTags() throws {
    _ = viewModel.save(name: "box", values: values, password: "", tags: ["web"])
    let again = viewModel.save(name: "box", values: values, password: "", tags: ["docker"])
    #expect(again?.tags == ["docker"])
}
```

Der zweite Test ist kein Beiwerk: `save` mutiert eine namensgleiche
Sitzung, und ohne ihn bliebe offen, ob Tags dabei ersetzt oder ergänzt
werden. Er pinnt „ersetzt".

- [ ] **Schritt 2: Rot, dann `save` erweitern**

Parameter `tags: [String] = []` **ans Ende** der Signatur, damit kein
vorhandener Aufrufer bricht. Im Rumpf `session.tags = TagList.normalized(tags)`
an derselben Stelle, an der `groupID` gesetzt wird.

- [ ] **Schritt 3: Das Formularfeld**

Ein Tag-Feld direkt unter dem Namensfeld, mit `L10n.string`-Beschriftung.
Neue Schlüssel:

- `form.tags.label` — „Tags"
- `form.tags.help` — „Comma-separated. Used by the sidebar filter."

Beide in **allen vier** Katalogen von `MacSCPAppKit`. Der Formularzustand
hält `[String]`; die Umwandlung Text↔Liste macht das Feld, nicht der
Formular-ViewModel.

Beim Bearbeiten einer bestehenden Sitzung wird das Feld mit deren Tags
vorbelegt, und beim Speichern gehen sie an `save(… tags:)`. Prüfe beide
Wege am Code, statt sie anzunehmen.

- [ ] **Schritt 4: Katalog-Nachweis + volle Suite + Commit**

```bash
for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done
swift test
git commit -m "feat(app): tag a saved connection from its form"
```

---

### Task 6: Die Sidebar — Chips, Ausblenden, Leer-Zustand

**Gemessener Ist-Zustand:** `SessionSidebar` (rund 680 Zeilen) läuft
ungefiltert durch `viewModel.sessions(inGroup:)`, rendert Gruppen als
`Section(isExpanded:)` mit einem `Set<UUID>` im View-Zustand, hat eine
eigene Section `importedSection` und **keinen Leer-Zustand**. Prüfe das
selbst; weicht es ab, ist der Plan falsch.

`SnippetTagFilterRow` und `SnippetTagFilterChip` in `SnippetsSheet.swift`
sind `private` — sie sind die **optische** Vorlage, aber nicht direkt
benutzbar. Entweder du hebst sie in eine geteilte Datei, oder du baust die
Sidebar-Reihe danebendran. Entscheide bewusst und begründe es im Bericht;
eine wörtliche Kopie ist die eine Option, die dieses Projekt nicht will.

**Files:**
- Modify: `Sources/MacSCPAppKit/SessionSidebar.swift`
- Modify: alle vier `Localizable.strings`
- Create: `Tests/macSCPAppKitTests/SidebarFilterWiringTests.swift`

**Interfaces:**
- Consumes: `SidebarVisibility.compute/availableTags/resolvedTag` aus Task 4

- [ ] **Schritt 1: Zustand + Chip-Reihe**

`@State private var activeTag: String?` in `SessionSidebar` — **nicht**
persistiert, nicht in `SettingsStore`. Der Filter ist eine Sicht, keine
Einstellung.

Die Chip-Reihe steht über der Liste, speist sich aus
`SidebarVisibility.availableTags(in: viewModel.sessions)` und zeigt gar
nichts, solange keine Sitzung einen Tag trägt — eine leere Chip-Leiste über
einer Liste ohne Tags wäre nur Rahmen.

Neue Schlüssel (alle vier Kataloge):

- `sidebar.filter.all` — „All"
- `sidebar.empty.noSessions` — „No saved connections yet."
- `sidebar.empty.noMatches` — „No connection has this tag."
- `sidebar.empty.clearFilter` — „Show all"

- [ ] **Schritt 2: Liste und Sections lesen aus `SidebarVisibility`**

Ein `let visibility = SidebarVisibility.compute(sessions: viewModel.sessions,
groups: viewModel.groups, activeTag: activeTag)` an **einer** Stelle, und
Gruppen, Sitzungen, `importedSection` und Leer-Zustand lesen daraus.

**Ausdrücklich nicht:** ein zweites `if` im Body, das `session.tags`
direkt prüft. Genau diese Form — die Entscheidung noch einmal im View
nachgebaut — war in P2 der Critical.

- [ ] **Schritt 3: Der Rückfall**

Wenn der aktive Tag verschwindet (Sitzung gelöscht, Tag entfernt), fällt
der Filter zurück:

```swift
.onChange(of: viewModel.sessions) { _, sessions in
    activeTag = SidebarVisibility.resolvedTag(activeTag, in: sessions)
}
```

- [ ] **Schritt 4: Der Wächter**

`SessionSidebar` lässt sich in diesem Projekt nicht instanziieren — es gibt
kein View-Testwerkzeug. Deshalb ein Quelltext-Wächter nach dem Muster von
`PaneRenderConditionGuardTests` und `PaneVisibilityWiringGuardTests`
(beide in `Tests/macSCPAppKitTests/`): er prüft, dass die Sidebar ihre
Sichtbarkeit aus `SidebarVisibility` liest und **nicht** irgendwo `.tags`
direkt gegen `activeTag` hält.

Beweise ihn: baue die Bedingung testweise zurück auf einen direkten
`tags`-Vergleich, zeig den roten Lauf, stell es wieder her, zeig grün.
**Dokumentiere seine blinden Flecken im eigenen Doc-Kommentar**, so ehrlich
wie die beiden vorhandenen es tun — ein Wächter, der dichter verkauft wird
als er ist, wäre schlechter als keiner.

- [ ] **Schritt 5: Katalog-Nachweis + volle Suite + Commit**

```bash
for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done
swift test
git commit -m "feat(app): filter the sidebar by host tag"
```

---

### Task 7: Phasenabschluss

**Files:**
- Create: `docs/superpowers/specs/2026-08-18-p3a-abschluss.md`

- [ ] **Schritt 1: Messen**

```bash
swift test 2>&1 | tail -3
for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done
MACSCP_VERSION="1.2.0-dev" MACSCP_BUILD="$(git rev-list --count HEAD)" ./scripts/package-app
```

Den Build **im Hintergrund** starten und weiterarbeiten; danach prüfen:
`lipo -archs` auf beide Binaries, beide Ressourcen-Bundles, alle vier
`.lproj`, `plutil -lint` auf die Info.plist. **Die App wird nicht
gestartet.**

- [ ] **Schritt 2: Der Bericht**

Er nennt die gemessenen Zahlen; was durch Tests gehalten wird und was nur
durch Review (der Wächter aus Task 6 gehört ausdrücklich in die zweite
Spalte, mit seinen blinden Flecken); was der Export mit dem neuen Feld tut
und warum; ob `SnippetTagField` wiederverwendet wurde oder nicht und
weshalb; und **ausdrücklich**, dass die GUI nicht gestartet wurde — mit der
Liste dessen, was der Maintainer ansehen muss: die Chip-Reihe, das Tag-Feld
im Formular, das Ausblenden von Gruppen und „IMPORTIERT" bei aktivem
Filter, und beide Leer-Zustände.

- [ ] **Schritt 3: Commit**

```bash
git commit -m "docs(app): record the host tags phase"
```

---

## Selbstreview dieses Plans

**Spec-Abdeckung:** Eine Regel, zwei Vokabulare → Task 1. Feld neben
`groupID`, `decodeIfPresent`, Standard `[]` → Task 2. Export/Import → Task 3.
Chip-Filter, Ausblenden von Gruppen und „IMPORTIERT", Rückfall,
Entscheidung in Core → Tasks 4 und 6. Beide Leer-Zustände → Tasks 4 und 6.
Formularfeld → Task 5. Nicht persistierter Filterzustand → Task 6, Schritt 1.

**Platzhalter:** Einer bleibt bewusst offen — der zweite Test in Task 3
kann erst formuliert werden, wenn die Pflichtfelder von `ExportedSession`
gelesen sind, und der Schritt sagt das ausdrücklich, statt es zu verstecken.

**Typkonsistenz:** `TagList.normalized(_:)` wird in den Tasks 1, 2 und 5
gleich geschrieben. `SidebarVisibility.compute/availableTags/resolvedTag`
in den Tasks 4 und 6 gleich. `save(… tags:)` in Task 5 einmal definiert.
