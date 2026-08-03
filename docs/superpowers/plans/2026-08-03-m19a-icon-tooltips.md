# M19a — Tooltips an Icon-Aktionen + Wächter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Jede anklickbare Fläche, die nur ein Symbol zeigt, sagt beim Überfahren, was sie tut — und ein Test erzwingt, dass das bei künftigen Symbolen eine bewusste Entscheidung bleibt.

**Architecture:** Zwei fehlende `.help`-Modifier in der App, plus ein Quelltext-Wächter im einzigen vorhandenen Testtarget (`macSCPCoreTests`), der die App-Quellen liest und für jedes Symbol entweder ein `.help` in der Nähe oder einen begründeten Eintrag auf einer Liste dekorativer Symbole verlangt.

**Tech Stack:** Swift (SwiftPM, `.swiftLanguageMode(.v5)`), Swift Testing, SwiftUI, macOS 15+.

## Global Constraints

- Swift `.swiftLanguageMode(.v5)`, minimum macOS 15; **keine neue externe Dependency**.
- Code, Kommentare, Testnamen: **Englisch**. UI-Strings EN/DE/FR/PL, typografische Zeichen in nicht-englischen Werten (kein ASCII `"`).
- Der Wächter prüft **ausschließlich**, ob pro Symbol entschieden wurde — er wird nicht zum schleichenden Stil-Linter.
- Conventional Commits; Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

**Verankerte Fakten (im Code verifiziert):** Das Tab-`×` sitzt in `Sources/MacSCPApp/TabStripView.swift:107-113` (`Button(action: onClose)` mit `Image(systemName: "xmark")`, `.buttonStyle(.plain)`), sichtbar nur bei `isHovering`; das `+` daneben hat sein `.help` bei `:34` mit dem Schlüssel `tabs.newTabHelp` („New tab (⌘N)"). **⌘W ist als „Close Tab" bestätigt** (`MacSCPApp.swift:187-190`, und `KeyboardShortcutsCatalog.swift:36` führt es). Der `−`-Knopf sitzt in `Sources/MacSCPApp/SettingsView.swift:506-514` und trägt **bereits** `.accessibilityLabel(L10n.string("settings.openWith.rules.remove", "Remove"))` — der Schlüssel existiert also schon (`en.lproj:58`). Bewusst dekorativ: `TransferQueueBar.swift:77` (Richtungspfeil) und `:128` (Häkchen); das ⚠ (`:97`) hat sein `.help` bei `:100`, der Fehlerfall bei `:135`. Vorbild für den Wächter: der `#filePath`-Lint in `Tests/macSCPCoreTests/EmbeddedKeyPorterTests.swift` (Kommentare strippen → Leerzeichen strippen → whitespace-freie Nadeln).

**Kein App-Testtarget:** `Package.swift` hat nur `macSCPCoreTests`. Die App-Änderungen sind build-verifiziert; der Wächter liest Quelltext.

---

## Task 1: Die zwei fehlenden Hinweistexte

**Files:**
- Modify: `Sources/MacSCPApp/TabStripView.swift`
- Modify: `Sources/MacSCPApp/SettingsView.swift`
- Modify: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`

**Interfaces:**
- Produces: ein neuer Schlüssel `tabs.closeTabHelp`. Der Einstellungen-Knopf bekommt **keinen** neuen Schlüssel.

- [ ] **Step 1: Tab-`×`**

An den `Button(action: onClose)`-Block in `TabStripView.swift` (nach `.foregroundStyle(...)`, in derselben Modifier-Kette wie beim `+`) anhängen:

```swift
                .help(L10n.string("tabs.closeTabHelp", "Close tab (⌘W)"))
```

Das Kürzel gehört in den Text, weil das `+` daneben es genauso hält — nicht als Verzierung: ⌘W ist real gebunden (`MacSCPApp.swift:190`).

- [ ] **Step 2: Einstellungen-`−`**

In `SettingsView.swift` an denselben Knopf, **zusätzlich** zum vorhandenen `.accessibilityLabel`:

```swift
                        .help(L10n.string("settings.openWith.rules.remove", "Remove"))
```

Denselben Schlüssel wiederverwenden — er existiert bereits in allen vier Katalogen. `.accessibilityLabel` ist **kein** Ersatz für `.help`: es beschriftet für VoiceOver, erzeugt aber keinen Hinweis beim Überfahren. Halte genau das in einem knappen Kommentar fest, damit die Doppelung nicht später als Redundanz „aufgeräumt" wird.

- [ ] **Step 3: L10n**

`tabs.closeTabHelp` in **allen vier** Katalogen, direkt neben `tabs.newTabHelp` einsortiert:

EN:
```
"tabs.closeTabHelp" = "Close tab (⌘W)";
```
DE:
```
"tabs.closeTabHelp" = "Tab schließen (⌘W)";
```
FR:
```
"tabs.closeTabHelp" = "Fermer l’onglet (⌘W)";
```
PL:
```
"tabs.closeTabHelp" = "Zamknij kartę (⌘W)";
```

Der FR-Wert nutzt das typografische Apostroph U+2019, kein ASCII `'`.

- [ ] **Step 4: Build + Parität**

Run: `swift build && swift test --filter Localizable`
Expected: 0 neue Warnungen, Parität grün. Zusätzlich per Grep bestätigen, dass `tabs.closeTabHelp` in allen vier Dateien steht — der Paritätstest diffed nur gegen `en.lproj` und sieht einen überall fehlenden Schlüssel nicht.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacSCPApp
git commit -m "feat: explain the tab close and rule remove icons on hover

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: Der Wächter

**Files:**
- Create: `Tests/macSCPCoreTests/IconTooltipLintTests.swift`

**Interfaces:**
- Consumes: die App-Quellen unter `Sources/MacSCPApp/`, über einen aus `#filePath` abgeleiteten Pfad (wie der M19-Lint).

- [ ] **Step 1: Den Lint schreiben**

Aufbau, angelehnt an `EmbeddedKeyPorterTests`' Quelltext-Lint (dort nachlesen, insbesondere wie er den Pfad aus `#filePath` herleitet und wie er Kommentare entfernt, bevor er sucht):

1. Alle `*.swift` unter `Sources/MacSCPApp/` einlesen.
2. Zeilenkommentare entfernen, **bevor** gesucht wird (sonst zählt ein auskommentiertes Symbol mit).
3. Jedes Vorkommen von `Image(systemName:` und `systemImage:` finden, mit Datei und Zeilennummer.
4. Für jedes Vorkommen gilt es als entschieden, wenn **eines** zutrifft:
   - innerhalb der nächsten **12 Zeilen** steht ein `.help(` — die Modifier-Kette eines Icon-Knopfes ist in diesem Code nie länger (längster Ist-Fall: `TabStripView` `+`, 8 Zeilen); oder
   - Datei **und** Symbolname stehen auf `decorativeIcons`.
5. Sonst: `Issue.record` mit Datei, Zeile, Symbolname und dem Hinweis, was zu tun ist (`.help` ergänzen **oder** mit Begründung auf die Liste setzen).

Die Liste als Konstante mit Begründung je Eintrag, ungefähr so:

```swift
    /// Icons that are deliberately decorative — they are not a hit target, so
    /// a hover hint would have nothing to explain. One line of reasoning per
    /// entry: the point of this list is that somebody DECIDED, not that the
    /// list is short.
    private static let decorativeIcons: [DecorativeIcon] = [
        DecorativeIcon(file: "TransferQueueBar.swift", symbol: "arrow.up",
                       reason: "Direction glyph; the row text already says upload or download."),
        // …
    ]
```

Die realen Einträge aus dem Ist-Zustand ableiten, nicht raten: alles, was nach dem Ergänzen aus Task 1 noch ohne `.help` dasteht, gehört mit einer ehrlichen Begründung auf die Liste. Erwartet werden mindestens der Richtungspfeil und das Häkchen aus `TransferQueueBar`; prüfe die übrigen Dateien selbst und schreibe für jeden Fund eine eigene Begründung.

- [ ] **Step 2: Grenzen dokumentieren**

Doc-Kommentar am Test, der ohne Beschönigung sagt, was er leistet:

```swift
/// Guards ONE property: that every icon in the app target has been DECIDED
/// about — it carries a hover hint, or it is on the decorative list with a
/// reason. It deliberately does not check that a hint is good, or even that
/// it sits on the right element: a `.help` on a neighbouring control within
/// the window below satisfies the scan. The proximity window is a heuristic
/// and unusual formatting can fool it, and the list needs maintenance by
/// hand. In M19 a lint of this shape caught two real gaps — but only after a
/// reviewer defeated an earlier version of it with a line break, so treat
/// its reach as narrow and its value as "nobody adds an icon without
/// thinking", nothing more.
```

Ebenfalls festhalten: `.accessibilityLabel` zählt **nicht** als Erfüllung. Es beschriftet für VoiceOver und erzeugt keinen Hinweis beim Überfahren — der Einstellungen-Knopf aus Task 1 hatte genau das und brauchte trotzdem ein `.help`.

- [ ] **Step 3: Grün gegen den aufgeräumten Stand**

Run: `swift test --filter IconTooltipLint`
Expected: PASS.

- [ ] **Step 4: Rot per Mutation belegen**

Ein Symbol ohne `.help` und ohne Listeneintrag in eine App-Datei einfügen (z. B. ein `Image(systemName: "star")` in einem Knopf), Test laufen lassen — **muss rot werden**, und die Meldung muss Datei, Zeile und Symbolnamen nennen. Ausgabe im Bericht festhalten, dann die Mutation zurücknehmen und erneut grün bestätigen.

Zweite Mutation: einen der beiden in Task 1 ergänzten `.help`-Aufrufe entfernen — auch das muss rot werden. Danach zurücknehmen.

- [ ] **Step 5: Volle Suite + Commit**

Run: `swift build && swift test`
Expected: alles grün, 0 neue Warnungen.

```bash
git add Tests/macSCPCoreTests/IconTooltipLintTests.swift
git commit -m "test: require a decision for every icon in the app target

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: Abschluss

- [ ] **Step 1: Volle Suite + Parität**

Run: `swift build && swift test && swift test --filter Localizable`

- [ ] **Step 2: Sichtprüfung im Dev-Build**

Dev-Build bauen und starten, Zeiger über das `×` eines Tabs und über das `−` in „Öffnen mit" halten: beide zeigen ihren Text. Zusätzlich Idle-CPU messen (~0 %).

- [ ] **Step 3: Review**

Review über `git merge-base develop HEAD`..HEAD. Fokus: der Wächter prüft nichts anderes als die Entscheidung; seine Grenzen stehen im Doc-Kommentar statt in einer Zusage, die er nicht hält; die Liste dekorativer Symbole hat je Eintrag eine echte Begründung; Katalog-Parität per Grep, nicht nur per Test.

- [ ] **Step 4: Push (auf Maintainer-Anordnung)**

---

## Self-Review

**1. Spec coverage:** Die zwei Lücken → Task 1 ✅ · Wächter mit Liste → Task 2 ✅ · Grenzen benannt → Task 2 Step 2 ✅ · Mutationsnachweis → Task 2 Step 4 ✅ · Katalog-Parität per Grep → Task 1 Step 4 und Task 3 ✅ · dekorative Symbole bleiben ohne Tooltip → Task 2 Liste ✅

**2. Placeholder scan:** Bewusst offen mit klarer Anweisung: die realen Einträge der `decorativeIcons`-Liste (aus dem Ist-Zustand ableiten, nicht raten) und die genaue Pfad-/Kommentar-Behandlung des M19-Lints (dort nachlesen). Kein „TBD/TODO".

**3. Type consistency:** `tabs.closeTabHelp` (neu, 4 Kataloge), `settings.openWith.rules.remove` (bestehend, wiederverwendet), `decorativeIcons` / `DecorativeIcon(file:symbol:reason:)` — über beide Tasks gleich geschrieben.
