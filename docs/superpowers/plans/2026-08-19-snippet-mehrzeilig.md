# Snippet-Editor Teil 2 — mehrzeilige Snippets: Umsetzungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein Snippet darf mehrere Zeilen haben; beim Auslösen entscheidet der
Bracketed-Paste-Modus der Gegenseite, wie es gesendet wird.

**Architecture:** Eine reine Planungsfunktion in Core entscheidet aus
(Befehl, ausführen?, Klammerung?) über die Bytes — oder über eine Ablehnung.
Die App-Schicht liest den Modus aus SwiftTerms `Terminal` und reicht ihn als
`Bool` hinein; Core sieht SwiftTerm nicht. Das Modell verliert seine
Umbruch-Abweisung, der Editor wird mehrzeilig.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, macOS 15+,
Swift Testing (`@Test`/`#expect`), SwiftUI + AppKit, SwiftTerm.

**Spec:** `docs/superpowers/specs/2026-08-19-snippet-mehrzeilig-design.md`

## Global Constraints

- Code, Kommentare, Bezeichner, Testnamen, Commit-Messages: **Englisch**.
  Interne Doku unter `docs/` bleibt Deutsch.
- Conventional Commits. Footer auf **jedem** Commit:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- TDD rot→grün. Jede neue Logik kommt mit Tests; jede Regression wird zuerst
  rot bewiesen.
- Unit-Suite: `swift test`. Ausgangswert vor diesem Plan: **2197 Tests in 196
  Suiten, grün.**
- Nutzer-sichtbare Zeichenketten gehen durch `L10n.string` und existieren in
  **allen vier** Katalogen (`en`, `de`, `fr`, `pl`). Ein Wächtertest hält die
  Schlüsselmengen gleich — ein Schlüssel in nur drei Katalogen färbt die
  Suite rot.
- **Wer eine Zahl oder eine Aufzählung von Aufrufstellen in einen Kommentar
  schreibt, zählt sie im selben Moment nach** (`CLAUDE.md`). Das gilt auch
  für Zahlen, die aus diesem Plan stammen.
- Snippets enthalten **niemals** Zugangsdaten — der Store ist reines JSON.
  Keine Änderung dieses Plans darf daran rütteln.
- Die App wird **nicht** gestartet; Sichtprüfungen sind Maintainer-Sache.

---

## Dateien

**Neu:**

- `Sources/macSCPCore/Terminal/SnippetSendPlan.swift` — der Ergebnistyp und
  die Planungsfunktion. Einzige Zuständigkeit: aus Befehl + zwei Flags die
  Bytes oder die Ablehnung ableiten.
- `Tests/macSCPCoreTests/SnippetSendPlanTests.swift`

**Geändert:**

- `Sources/macSCPCore/Terminal/SnippetKeystrokes.swift` — bekommt eine
  Zeilen-Funktion, auf die der Planer aufsetzt.
- `Sources/macSCPCore/Terminal/Snippet.swift` — Initializer verliert die
  Umbruch-Abweisung und damit seine Fehlbarkeit.
- `Sources/macSCPCore/Terminal/SnippetCommandInput.swift` — **gelöscht.**
- `Sources/MacSCPAppKit/SnippetCommandEditor.swift` — mehrzeilig.
- `Sources/MacSCPAppKit/SnippetsSheet.swift` — ⌘Return, Listenzeile.
- `Sources/MacSCPAppKit/ContentView.swift` — `triggerSnippet` über den Planer.
- `Sources/MacSCPAppKit/SSHTerminalView.swift` — reicht den Modus durch.
- `Sources/macSCPCore/Presentation/TerminalPanelViewModel.swift` — nimmt ihn
  entgegen.
- Die vier `Localizable.strings`.

---

## Task 1: Core — der Sendeplan

**Files:**
- Create: `Sources/macSCPCore/Terminal/SnippetSendPlan.swift`
- Create: `Tests/macSCPCoreTests/SnippetSendPlanTests.swift`
- Modify: `Sources/macSCPCore/Terminal/SnippetKeystrokes.swift`

**Interfaces:**
- Consumes: nichts aus anderen Tasks.
- Produces:
  - `public enum SnippetSendPlan: Equatable { case send([UInt8]); case refusedMultilineInsert }`
  - `public enum SnippetSendPlanner { public static func plan(command: String, execute: Bool, bracketedPaste: Bool) -> SnippetSendPlan }`
  - `public static func SnippetKeystrokes.bytes(forLine line: String, execute: Bool) -> [UInt8]`

**Kontext, den der Umsetzer braucht:** `SnippetKeystrokes` sendet heute
`Array(snippet.command.utf8)` plus, bei `execute`, ein CR (`0x0D`). Der
Doc-Kommentar an `terminator` trägt die gemessene Belegkette dafür — **nicht
anfassen, nicht umformulieren.** Diese Aufgabe schiebt nur einen Parameter
von `Snippet` auf `String`.

- [ ] **Schritt 1: Zeilen-Funktion aus `bytes(for:execute:)` herausziehen**

In `SnippetKeystrokes.swift`: `private static let terminator` wird zu
`static let terminator` (modulintern, damit der Planer es anhängen kann; der
gesamte Doc-Kommentar bleibt unverändert stehen). Dann:

```swift
    /// The keystrokes for a single command line: `line` as UTF-8, followed
    /// by `terminator` only when `execute` is `true`.
    ///
    /// `bytes(for:execute:)` below is this function applied to a snippet's
    /// whole command, which is the right thing only while that command is a
    /// single line. `SnippetSendPlanner` calls this one per line for the
    /// multi-line fallback.
    public static func bytes(forLine line: String, execute: Bool) -> [UInt8] {
        var bytes = Array(line.utf8)
        if execute {
            bytes.append(terminator)
        }
        return bytes
    }

    /// The keystrokes for `snippet`: its command as UTF-8, followed by
    /// `terminator` only when `execute` is `true`.
    ///
    /// Inserting (`execute: false`) never appends a terminator, whatever else
    /// changes here — the text lands in the input line exactly as if typed,
    /// and the user still presses Return. That guarantee is asserted once, at
    /// this seam, rather than at each surface that calls it.
    public static func bytes(for snippet: Snippet, execute: Bool) -> [UInt8] {
        bytes(forLine: snippet.command, execute: execute)
    }
```

- [ ] **Schritt 2: Bauen und die bestehende Suite laufen lassen**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: 2197 Tests, grün. Diese Umstellung ändert kein Verhalten; wird sie
rot, stimmt etwas anderes nicht.

- [ ] **Schritt 3: Die fehlschlagenden Tests schreiben**

`Tests/macSCPCoreTests/SnippetSendPlanTests.swift`:

```swift
import Testing
@testable import macSCPCore

/// `SnippetSendPlanner` turns a command plus two flags into the bytes that
/// go to the shell — or into a refusal.
///
/// The bracketed-paste rule is not this project's invention: SwiftTerm's own
/// ⌘V path on macOS wraps a paste in these two sequences exactly when the
/// remote has enabled mode 2004, and sends the pasted text's raw UTF-8
/// between them with no line-ending translation of any kind
/// (`MacTerminalView.paste(_:)` → `insertText(_:replacementRange:isPaste:)`
/// → `send(txt:)` → `[UInt8](txt.utf8)`). macSCP follows that rule so a
/// snippet behaves like a paste the user performed themselves.
@Suite("SnippetSendPlanner")
struct SnippetSendPlanTests {
    private static let start: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
    private static let end: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
    private static let cr: UInt8 = 0x0D

    /// Compared against `SnippetKeystrokes` rather than against a byte
    /// literal written out here: the point is that the planner delegates
    /// for this case, not that someone transcribed the same bytes twice.
    /// Deliberately takes a plain `String` and never builds a `Snippet` —
    /// this suite must not care whether that initializer is failable, which
    /// is a thing Task 2 changes.
    @Test("a single line inserts exactly the bytes it always did")
    func singleLineInsertIsUnchanged() {
        let plan = SnippetSendPlanner.plan(
            command: "docker ps -a", execute: false, bracketedPaste: false)
        #expect(plan == .send(SnippetKeystrokes.bytes(forLine: "docker ps -a", execute: false)))
    }

    @Test("a single line executes exactly the bytes it always did")
    func singleLineExecuteIsUnchanged() {
        let plan = SnippetSendPlanner.plan(
            command: "docker ps -a", execute: true, bracketedPaste: true)
        #expect(plan == .send(SnippetKeystrokes.bytes(forLine: "docker ps -a", execute: true)))
    }

    @Test("a single line is never bracketed, even when the mode is on")
    func singleLineIsNeverBracketed() {
        let plan = SnippetSendPlanner.plan(
            command: "echo hi", execute: false, bracketedPaste: true)
        guard case .send(let bytes) = plan else {
            Issue.record("expected bytes, got \(plan)")
            return
        }
        #expect(!bytes.starts(with: Self.start))
    }

    @Test("multiple lines are bracketed verbatim when the mode is on")
    func multilineIsBracketed() {
        let plan = SnippetSendPlanner.plan(
            command: "cd /tmp\nls -la", execute: false, bracketedPaste: true)
        #expect(plan == .send(Self.start + Array("cd /tmp\nls -la".utf8) + Self.end))
    }

    @Test("a bracketed execute appends one carriage return after the closing sequence")
    func bracketedExecuteAppendsOneReturn() {
        let plan = SnippetSendPlanner.plan(
            command: "cd /tmp\nls -la", execute: true, bracketedPaste: true)
        #expect(plan == .send(Self.start + Array("cd /tmp\nls -la".utf8) + Self.end + [Self.cr]))
    }

    @Test("without bracketing, executing sends each line with its own return")
    func unbracketedExecuteIsLineByLine() {
        let plan = SnippetSendPlanner.plan(
            command: "cd /tmp\nls -la", execute: true, bracketedPaste: false)
        #expect(plan == .send(Array("cd /tmp".utf8) + [Self.cr] + Array("ls -la".utf8) + [Self.cr]))
    }

    @Test("without bracketing, inserting several lines is refused instead of executed")
    func unbracketedMultilineInsertIsRefused() {
        let plan = SnippetSendPlanner.plan(
            command: "cd /tmp\nls -la", execute: false, bracketedPaste: false)
        #expect(plan == .refusedMultilineInsert)
    }

    /// `"\r\n"` is ONE `Character` in Swift, so a rule written with
    /// `contains("\n")` does not see a CRLF command at all — the trap
    /// `Snippet.init?` was fixed for in P3e. A CRLF command must be treated
    /// as two lines here too, not as one line containing junk.
    func crlfCountsAsALineBreak() {
        let plan = SnippetSendPlanner.plan(
            command: "cd /tmp\r\nls -la", execute: false, bracketedPaste: false)
        #expect(plan == .refusedMultilineInsert)
    }

    /// The line-by-line fallback normalizes: whatever separator the command
    /// carries, each line is terminated with the same CR a keypress sends.
    @Test("the line-by-line fallback normalizes CRLF to the terminator")
    func lineByLineNormalizesCRLF() {
        let plan = SnippetSendPlanner.plan(
            command: "a\r\nb", execute: true, bracketedPaste: false)
        #expect(plan == .send(Array("a".utf8) + [Self.cr] + Array("b".utf8) + [Self.cr]))
    }

    /// A trailing newline makes a final empty line, and it is NOT dropped:
    /// at a prompt an empty line is a harmless no-op, and silently trimming
    /// input the user typed is the larger surprise.
    @Test("a trailing newline produces a trailing empty line")
    func trailingNewlineKeepsItsEmptyLine() {
        let plan = SnippetSendPlanner.plan(
            command: "echo hi\n", execute: true, bracketedPaste: false)
        #expect(plan == .send(Array("echo hi".utf8) + [Self.cr] + [Self.cr]))
    }
}
```

**Beachte:** `crlfCountsAsALineBreak` hat oben **absichtlich kein** `@Test` —
das ist ein Fehler, den Schritt 5 findet. Siehe dort.

- [ ] **Schritt 4: Rot laufen lassen**

Run: `swift test --filter SnippetSendPlan 2>&1 | tail -20`
Expected: Compile-Fehler — `SnippetSendPlanner` und `SnippetSendPlan` gibt es
nicht.

- [ ] **Schritt 5: Das fehlende `@Test` ergänzen**

`crlfCountsAsALineBreak` trägt keine `@Test`-Annotation und wird deshalb nie
ausgeführt — ein Test, der nichts beweist, ist schlimmer als keiner. Setze
`@Test("a CRLF command counts as two lines")` davor.

Run danach: `swift test --filter SnippetSendPlan 2>&1 | grep -c 'Test .* passed\|Test .* failed'`
Expected: **10** Testfunktionen werden gezählt (nicht 9).

- [ ] **Schritt 6: Die minimale Implementierung schreiben**

`Sources/macSCPCore/Terminal/SnippetSendPlan.swift`:

```swift
import Foundation

/// What should go to the shell for one snippet trigger — or why nothing
/// should.
///
/// A plain `[UInt8]` cannot express the one case that matters: inserting a
/// multi-line command into a shell that has not enabled bracketed paste
/// would EXECUTE its leading lines, because the embedded line breaks are
/// what a Return keypress sends. The menu entry says "insert"; bytes that
/// run things are not an insert. So the refusal is part of the result type
/// and the caller has to look at it.
public enum SnippetSendPlan: Equatable {
    case send([UInt8])
    /// Inserting is impossible here without also executing — the caller
    /// explains and offers to execute instead.
    case refusedMultilineInsert
}

/// Decides what a snippet trigger sends.
///
/// Pure: the caller supplies whether the remote has bracketed paste on,
/// which the App layer reads from SwiftTerm's `Terminal`. Core neither
/// imports SwiftTerm nor needs a terminal to be tested.
public enum SnippetSendPlanner {
    /// `ESC [ 2 0 0 ~` — the sequence a terminal emits before pasted text
    /// while the remote has mode 2004 on. Byte-for-byte SwiftTerm's
    /// `EscapeSequences.bracketedPasteStart`; spelled out here because Core
    /// does not import SwiftTerm, and pinned by this file's tests.
    private static let bracketedPasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
    /// `ESC [ 2 0 1 ~` — the matching closing sequence
    /// (`EscapeSequences.bracketedPasteEnd`).
    private static let bracketedPasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]

    /// The bytes for `command`, or a refusal.
    ///
    /// A single-line command takes the path it always took and is **never**
    /// bracketed: that keeps the overwhelmingly common case byte-identical
    /// to what shipped before multi-line snippets existed.
    ///
    /// Between the brackets goes the command's raw UTF-8, unchanged — that
    /// is what SwiftTerm's own ⌘V does with the clipboard's string, with no
    /// line-ending translation. The line-by-line fallback does normalize,
    /// because there each line ends with the byte a Return keypress sends.
    public static func plan(
        command: String, execute: Bool, bracketedPaste: Bool
    ) -> SnippetSendPlan {
        // `\r\n` is ONE `Character` in Swift, so `isNewline` per character is
        // the whole rule -- `contains("\n")` would miss a CRLF command.
        guard command.contains(where: \.isNewline) else {
            return .send(SnippetKeystrokes.bytes(forLine: command, execute: execute))
        }
        if bracketedPaste {
            var bytes = bracketedPasteStart
            bytes.append(contentsOf: Array(command.utf8))
            bytes.append(contentsOf: bracketedPasteEnd)
            if execute {
                bytes.append(SnippetKeystrokes.terminator)
            }
            return .send(bytes)
        }
        guard execute else { return .refusedMultilineInsert }
        let lines = command.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var bytes: [UInt8] = []
        for line in lines {
            bytes.append(contentsOf: SnippetKeystrokes.bytes(forLine: String(line), execute: true))
        }
        return .send(bytes)
    }
}
```

- [ ] **Schritt 7: Grün laufen lassen**

Run: `swift test --filter SnippetSendPlan 2>&1 | tail -5`
Expected: alle 10 grün.

- [ ] **Schritt 8: Die Konstant-Rückgabe-Probe von Hand fahren**

Ersetze den Rumpf von `plan` vorübergehend durch
`return .send(Array(command.utf8))` und lasse die Suite laufen.

Run: `swift test --filter SnippetSendPlan 2>&1 | grep -c 'failed'`
Expected: **mindestens 5** Tests scheitern. Scheitern weniger, prüfen die
Tests zu wenig — melde das, statt weiterzugehen. Stelle den Rumpf danach
wieder her und lasse die Suite erneut grün laufen.

- [ ] **Schritt 9: Committen**

```bash
git add Sources/macSCPCore/Terminal/SnippetSendPlan.swift Sources/macSCPCore/Terminal/SnippetKeystrokes.swift Tests/macSCPCoreTests/SnippetSendPlanTests.swift
git commit -m "$(cat <<'EOF'
feat(core): plan snippet bytes from the bracketed paste mode

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Core — das Modell nimmt Umbrüche an

**Files:**
- Modify: `Sources/macSCPCore/Terminal/Snippet.swift`
- Delete: `Sources/macSCPCore/Terminal/SnippetCommandInput.swift`
- Modify: `Tests/macSCPCoreTests/SnippetHighlighterTests.swift` (drei
  `SnippetCommandInput`-Tests entfallen)
- Modify: alle Dateien mit `Snippet(`-Aufrufen (siehe Schritt 4)
- Modify: `Sources/MacSCPAppKit/SnippetCommandEditor.swift` (nur der
  Sanitizer-Aufruf, siehe Schritt 5)
- Modify: `Tests/macSCPCoreTests/SnippetTests.swift`,
  `Tests/macSCPCoreTests/SnippetAuditDetailTests.swift`

**Interfaces:**
- Consumes: nichts aus Task 1.
- Produces: `public init(id: UUID = UUID(), name: String, command: String, tags: [String] = [])`
  — **nicht mehr fehlbar.** Task 3 und 4 verlassen sich darauf, dass ein
  mehrzeiliger Befehl konstruierbar ist.

**Kontext:** Die Umbruch-Abweisung war der **einzige** Grund, aus dem
`Snippet.init?` scheitern konnte. Fällt sie, ist ein `init?`, das nie `nil`
liefert, eine Lüge — jeder spätere Leser schriebe ein `guard let` für nichts.
Deshalb wird der Initializer nicht-fehlbar, und die Aufrufstellen ziehen mit.
Das ist mechanisch und umfangreich; es ist Absicht, dass es eine eigene
Aufgabe ist.

- [ ] **Schritt 1: Den fehlschlagenden Test schreiben**

An `Tests/macSCPCoreTests/SnippetTests.swift` anhängen:

```swift
    /// Part 2: a snippet may span lines. `"\r\n"` is ONE `Character` in
    /// Swift, so it gets its own case — a rule written with
    /// `contains("\n")` would not see it.
    @Test("a multi-line command is accepted and kept verbatim")
    func multilineCommandIsKept() {
        let snippet = Snippet(name: "deploy", command: "cd /srv\r\nmake all\n")
        #expect(snippet.command == "cd /srv\r\nmake all\n")
    }

    @Test("a multi-line command survives a store round trip")
    func multilineCommandSurvivesEncoding() throws {
        let original = Snippet(name: "deploy", command: "cd /srv\r\nmake all")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Snippet.self, from: data)
        #expect(decoded.command == original.command)
    }
```

An `Tests/macSCPCoreTests/SnippetAuditDetailTests.swift` anhängen:

```swift
    /// The audit log is one line per event. `SnippetAuditDetail` already
    /// collapsed whitespace when a command could not contain a newline —
    /// this pins that the rule actually covers newlines, now that a command
    /// can carry them. In Swift every `isNewline` character is also
    /// `isWhitespace`, which is why the existing rule suffices.
    @Test("a multi-line command is logged on a single line")
    func multilineCommandLogsOnOneLine() {
        let snippet = Snippet(name: "deploy", command: "cd /srv\nmake all")
        let text = SnippetAuditDetail.text(for: snippet)
        #expect(!text.contains(where: \.isNewline))
        #expect(text.contains("cd /srv make all"))
    }
```

- [ ] **Schritt 2: Rot laufen lassen**

Run: `swift test --filter 'Snippet' 2>&1 | tail -20`
Expected: Compile-Fehler in den neuen Tests — `Snippet(...)` liefert ein
`Snippet?`, das sich nicht mit `String` vergleichen lässt.

- [ ] **Schritt 3: Den Initializer umstellen**

In `Snippet.swift` den Doc-Kommentar an `command` kürzen (der Absatz über die
Einzeiligkeit stimmt nicht mehr; der Absatz über `let` und die Normalisierung
bleibt) und den Initializer ersetzen:

```swift
    /// Normalizes `tags` via `TagList.normalized` — see that type's doc
    /// comment for the exact rule.
    ///
    /// No longer failable (snippet editor, part 2): the single-line rule was
    /// the only thing this initializer ever rejected, and a command may now
    /// span lines. How a multi-line command reaches the shell is
    /// `SnippetSendPlanner`'s decision, not the model's.
    public init(id: UUID = UUID(), name: String, command: String, tags: [String] = []) {
        self.id = id
        self.name = name
        self.command = command
        self.tags = TagList.normalized(tags)
    }
```

Und im Decoder den `guard let`-Block durch den direkten Aufruf ersetzen:

```swift
        let tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self = Self(id: id, name: name, command: command, tags: tags)
```

Der Kommentar darüber („Via the normalizing (and validating) init …") wird zu
„Via the normalizing init — otherwise decode would be a second write path
that a hand-edited store file could use to smuggle an untrimmed or duplicate
tag past the normalization above."

- [ ] **Schritt 4: Die Aufrufstellen nachziehen**

Run: `grep -rn 'Snippet(name:\|Snippet(id:' Sources/ Tests/ | wc -l`

Notiere die Zahl **jetzt**; sie ist die Arbeitsmenge und gehört in den
Bericht. Entferne an jeder dieser Stellen das nachgestellte `!` bzw. wickle
`try #require(...)` ab. Betroffen sind Dateien in `Sources/macSCPCore/`,
`Tests/macSCPCoreTests/` und `Tests/macSCPAppKitTests/`.

Run danach: `swift build 2>&1 | grep -c error`
Expected: `0`.

- [ ] **Schritt 5: Den Sanitizer löschen**

```bash
git rm Sources/macSCPCore/Terminal/SnippetCommandInput.swift
```

Entferne die drei `SnippetCommandInput`-Zeilen aus
`Tests/macSCPCoreTests/SnippetHighlighterTests.swift` samt der Testfunktionen,
die sie tragen, und deren Doc-Kommentaren.

Entferne im selben Zug den einen verbleibenden Aufruf in
`Sources/MacSCPAppKit/SnippetCommandEditor.swift`: die Delegate-Methode
`textView(_:shouldChangeTextIn:replacementString:)` tat nichts anderes als
zu sanitisieren und entfällt vollständig. **Nur diese Methode** — der Rest
des Editors gehört Task 3.

Das gehört hierher und nicht in Task 3, damit jeder Commit dieses Zweigs für
sich baut; ein Commit, der die App-Schicht nicht übersetzt, ist an den
CI-Gates dieses Projekts kein zulässiger Zwischenstand. Der Editor nimmt
damit ab jetzt eingefügte Umbrüche an, während eine getippte Eingabetaste
noch verschluckt wird — ein stimmiger Zwischenzustand, den Task 3 auflöst.

Run: `grep -rn 'SnippetCommandInput' Sources/ Tests/`
Expected: **keine Treffer.**

- [ ] **Schritt 6: Die zwei Doc-Kommentare korrigieren, die jetzt falsch sind**

`Tests/macSCPCoreTests/SnippetExportCodecTests.swift` (Zeilenbereich um den
Kommentar „`Snippet.init(from:)` refuses a multi-line command") und
`Tests/macSCPCoreTests/SnippetImportPlannerTests.swift` („`Snippet.init?` only
rejects a multi-line command, not a blank name") behaupten beide eine Regel,
die es nicht mehr gibt. Suche sie mit

```bash
grep -rn 'refuses a multi-line\|rejects a multi-line' Tests/
```

und schreibe sie auf das um, was der jeweilige Test tatsächlich prüft. Prüfe
im selben Durchgang, ob der zugehörige Test noch etwas beweist — tut er es
nicht mehr, melde das, statt ihn stillschweigend stehen zu lassen.

- [ ] **Schritt 7: Bauen und die volle Suite laufen lassen**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: grün — **die ganze Suite, nicht nur Core.** Baut die App-Schicht
nicht, ist Schritt 5 unvollständig.

- [ ] **Schritt 8: Committen**

```bash
git add -A Sources/macSCPCore Tests/macSCPCoreTests Tests/macSCPAppKitTests
git commit -m "$(cat <<'EOF'
feat(core): let a snippet command span lines

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: App — der Editor wird mehrzeilig

**Files:**
- Modify: `Sources/MacSCPAppKit/SnippetCommandEditor.swift`
- Modify: `Sources/MacSCPAppKit/SnippetsSheet.swift`
- Modify: `Tests/macSCPAppKitTests/SnippetCommandEditorGuardTests.swift`

**Interfaces:**
- Consumes: aus Task 2, dass `Snippet(name:command:)` nicht mehr fehlbar ist
  und Umbrüche annimmt.
- Produces: nichts, worauf Task 4 sich stützt.

**Kontext:** Der Editor ist ein `NSTextView` in einem
`NSViewRepresentable`, gebaut in Teil 1 und vom Maintainer am laufenden Build
geprüft. Was dort steht, ist teuer erarbeitet — insbesondere die
abgeschalteten automatischen Ersetzungen, die Tab-Behandlung und die
Nicht-Umbruch-Einstellung. **Nichts davon anfassen**, außer was hier
ausdrücklich genannt ist.

- [ ] **Schritt 1: Die Wächtertests umdrehen (rot)**

In `SnippetCommandEditorGuardTests.swift`: Der Suite-Doc-Kommentar nennt
Punkt 4 „Return swallowed at the command layer" mit der Begründung „This
field is single-line". Beides gilt nicht mehr. Ersetze den Absatz durch:

```swift
/// 4. **Return inserts a line break.** Part 2 made a snippet command
///    multi-line, so a typed Return has something to insert and must NOT be
///    claimed at the command layer. A reappearing `insertNewline(_:)` case
///    in `textView(_:doCommandBy:)` would silently make the field
///    single-line again, and the failure would look like "Return does
///    nothing" rather than like a bug.
```

Und benenne den Test `insertNewlineIsClaimedInDoCommandBy` in
`insertNewlineIsNotClaimedInDoCommandBy` um, mit umgekehrter Erwartung: der
Selektor darf in `doCommandBy` **nicht** vorkommen. Passe die zwei
Selbsttests dieses Tests entsprechend an.

Ergänze einen Wächter für das neue Speichern-Kürzel, im Stil der Nachbarn in
dieser Datei (Quelltext-Scan, fail-closed, mit Selbsttest):

```swift
    /// The snippet editor's Save button carries ⌘Return, not the plain
    /// default action: Return belongs to the command field now, which is
    /// multi-line. A Save button that reverted to `.defaultAction` would
    /// take Return back and make line breaks untypeable — and the failure
    /// would present as "the editor saves when I try to add a line".
    @Test("the snippet editor saves on command-Return")
    func snippetEditorSavesOnCommandReturn() throws {
        let source = try String(contentsOf: Self.sheetSourceFile, encoding: .utf8)
        let body = try Self.functionBody(containing: "SnippetCommandEditor(", in: source)
        #expect(body.contains("keyboardShortcut(.return, modifiers: .command)"))
        #expect(!body.contains("keyboardShortcut(.defaultAction)"))
    }

    @Test("the command-Return scan reacts to a reverted shortcut")
    func commandReturnScanReactsToRegression() throws {
        let reverted = """
            func editorSheet() -> some View {
                SnippetCommandEditor(text: $command)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
            """
        let body = try Self.functionBody(containing: "SnippetCommandEditor(", in: reverted)
        #expect(!body.contains("keyboardShortcut(.return, modifiers: .command)"))
    }
```

Sollte `functionBody(containing:in:)` die Editor-Aufrufstelle nicht in einer
Funktion finden, die auch den Speichern-Knopf enthält, dann liegen beide
nicht im selben Rumpf — melde das, statt den Scan aufzuweichen.

Run: `swift test --filter SnippetCommandEditor 2>&1 | tail -10`
Expected: rot — der Selektor steht noch da.

- [ ] **Schritt 2: Den Editor umstellen**

In `SnippetCommandEditor.swift`:

1. Den `case #selector(NSResponder.insertNewline(_:))`-Zweig aus
   `textView(_:doCommandBy:)` entfernen (Tab und Shift-Tab bleiben).
2. Im `shouldChangeTextIn:`-Delegate den Sanitizer-Aufruf entfernen; die
   Methode entfällt damit vollständig, weil sie nichts anderes tat.
3. Den Doc-Kommentar des Typs überarbeiten: Hazard 4 hieß „Newlines" und
   beschrieb das Ersetzen. Er wird zu:

```swift
/// 4. **Line breaks are content.** Part 2 made a snippet command
///    multi-line: a typed Return inserts, a pasted multi-line string is
///    kept as it stands, and `Snippet` stores both verbatim. What reaches
///    the shell is `SnippetSendPlanner`'s decision, made at trigger time
///    from the remote's bracketed-paste mode — not this view's.
```

4. `textView.isVerticallyResizable` bleibt `false` und
   `autoresizingMask` bleibt `[.height]`: die Höhe kommt weiterhin aus der
   Formularzeile. Der Kommentar dort begründet das mit „one-line field" —
   ändere die Begründung auf „the row decides the height; the view reports
   how tall it would like to be through `intrinsicHeight` below", **nicht**
   die Einstellung.
5. Ergänze eine gemessene Wunschhöhe, die die Aufrufstelle lesen kann:

```swift
    /// How tall this field wants to be for `text`: one line's height per
    /// line, plus the container insets, clamped so a long script cannot push
    /// the sheet off screen. Beyond the clamp the view scrolls vertically.
    ///
    /// The bounds are estimates and belong in the maintainer's visual check
    /// — no test in this project draws an `NSViewRepresentable`.
    static func intrinsicHeight(for text: String) -> CGFloat {
        let lineHeight: CGFloat = 16
        let insets: CGFloat = 8
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        let clamped = min(max(lines, 1), 8)
        return CGFloat(clamped) * lineHeight + insets
    }
```

6. `scroll.hasVerticalScroller = true` setzen (statt `false`), damit ein
   Rumpf jenseits der Obergrenze erreichbar bleibt.

- [ ] **Schritt 3: Die Aufrufstelle im Sheet umstellen**

In `SnippetsSheet.swift` die feste `.frame(height: 24)` durch die gemessene
Höhe ersetzen und das Speichern-Kürzel setzen. Suche die Stelle mit

```bash
grep -n 'SnippetCommandEditor(' Sources/MacSCPAppKit/SnippetsSheet.swift
```

und ersetze `.frame(height: 24)` durch
`.frame(height: SnippetCommandEditor.intrinsicHeight(for: command))`.

Der Speichern-Knopf **dieses** Sheets verliert `.keyboardShortcut(.defaultAction)`
und bekommt `.keyboardShortcut(.return, modifiers: .command)`. Zähle vorher
nach, welche `.defaultAction`-Stellen die Datei hat, und ändere **nur** die
im Snippet-Editor:

```bash
grep -n 'keyboardShortcut(.defaultAction)' Sources/MacSCPAppKit/SnippetsSheet.swift
```

Trage die Zahl in den Bericht ein und begründe im Commit, welche du
angefasst hast.

- [ ] **Schritt 4: Die Listenzeile ehrlich machen**

Der Befehlstext wird an drei Stellen einzeilig dargestellt — im Sheet
(`SnippetsSheet.row`), in der Vorschauzeile am Terminal-Panel
(`ContentView+Detail.commandPreviewLine`) und im Aktions-Sheet
(`SnippetActionSheet`). Prüfe alle drei nach:

```bash
grep -rn 'Text(snippet.command)\|snippet.command$' Sources/MacSCPAppKit/
```

`.lineLimit(1)` zeigt bei einem mehrzeiligen Befehl nur die erste Zeile,
**ohne** dass erkennbar wäre, dass weitere folgen. Lege dafür einen
getesteten Helfer in Core an, statt die Regel dreimal in Views zu schreiben —
`Sources/macSCPCore/Terminal/SnippetCommandSummary.swift`:

```swift
import Foundation

/// One line standing in for a command that may have several.
///
/// Three surfaces show a command in a single line — the snippets sheet's
/// row, the terminal panel's hover preview, and the action sheet's header.
/// `.lineLimit(1)` alone would show the first line and silently drop the
/// rest, so "cd /srv" and "cd /srv" + "rm -rf build" would look identical
/// in the list. The count is the whole point.
public enum SnippetCommandSummary {
    /// `command`'s first line, plus how many lines follow when there are
    /// any. Returns the command unchanged when it is a single line, so the
    /// common case gains no decoration at all.
    public static func firstLine(of command: String) -> (text: String, moreLines: Int) {
        let lines = command.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let first = lines.first, lines.count > 1 else { return (command, 0) }
        return (String(first), lines.count - 1)
    }
}
```

Test dazu in `Tests/macSCPCoreTests/SnippetCommandSummaryTests.swift`:

```swift
import Testing
@testable import macSCPCore

@Suite("SnippetCommandSummary")
struct SnippetCommandSummaryTests {
    @Test("a single-line command is returned unchanged with no follow-up count")
    func singleLineIsUnchanged() {
        let summary = SnippetCommandSummary.firstLine(of: "docker ps -a")
        #expect(summary.text == "docker ps -a")
        #expect(summary.moreLines == 0)
    }

    @Test("a two-line command reports its first line and one follower")
    func twoLinesReportOneFollower() {
        let summary = SnippetCommandSummary.firstLine(of: "cd /srv\nmake all")
        #expect(summary.text == "cd /srv")
        #expect(summary.moreLines == 1)
    }

    /// `"\r\n"` is ONE `Character` in Swift — a split written against "\n"
    /// alone would see one line here, not two.
    @Test("CRLF separates lines like any other break")
    func crlfSeparatesLines() {
        let summary = SnippetCommandSummary.firstLine(of: "a\r\nb\r\nc")
        #expect(summary.text == "a")
        #expect(summary.moreLines == 2)
    }

    @Test("a trailing newline counts the empty line it creates")
    func trailingNewlineCounts() {
        let summary = SnippetCommandSummary.firstLine(of: "echo hi\n")
        #expect(summary.text == "echo hi")
        #expect(summary.moreLines == 1)
    }
}
```

Verdrahte ihn an den beiden einzeiligen Stellen. In `SnippetsSheet.row`
ersetzt

```swift
                Text(snippet.command)
```

diesen Block:

```swift
                let summary = SnippetCommandSummary.firstLine(of: snippet.command)
                HStack(spacing: 4) {
                    Text(summary.text)
                    if summary.moreLines > 0 {
                        Text(String(
                            format: L10n.string("snippets.command.moreLines %lld", "+%lld more"),
                            summary.moreLines))
                            .foregroundStyle(DesignTokens.inkTertiary)
                    }
                }
```

In `ContentView+Detail.commandPreviewLine` dieselbe Ableitung auf den dort
per `SnippetPreviewLine.row(hovered:pinned:)` gefundenen Befehl anwenden;
der Fallback-Text („Point at a snippet…") bleibt unverändert.

Das **Aktions-Sheet** (`SnippetActionSheet.swift`) zeigt den Befehl als
Ganzes und ist die einzige Stelle, die ihn vollständig zeigen soll: dort
entfällt jede Kürzung, der `Text(snippet.command)` bekommt kein
`lineLimit`. Prüfe beim Anfassen nach, ob dort eines steht.

Der Schlüssel `snippets.command.moreLines %lld` geht in alle vier Kataloge;
die Texte stehen in Task 4 Schritt 4. Die Form — Formatmarker **im
Schlüssel**, Aufruf über `String(format:)` — ist die dieses Projekts, siehe
`AuditLogSheet.swift` mit `audit.count %lld`. Weiche nicht davon ab.

- [ ] **Schritt 5: Bauen und die Suite laufen lassen**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: grün, und mehr Tests als vor Task 2 (die neuen aus Task 1 und 2
minus die drei gelöschten Sanitizer-Tests).

- [ ] **Schritt 6: Committen**

```bash
git add -A Sources/MacSCPAppKit Tests/macSCPAppKitTests
git commit -m "$(cat <<'EOF'
feat(app): make the snippet command field multi-line

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: App — Verdrahtung, Ablehnung, Übersetzungen

**Files:**
- Modify: `Sources/macSCPCore/Presentation/TerminalPanelViewModel.swift`
- Modify: `Sources/MacSCPAppKit/SSHTerminalView.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift`
- Modify: `Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `SnippetSendPlanner.plan(command:execute:bracketedPaste:)` und
  `SnippetSendPlan` aus Task 1.
- Produces: nichts.

**Kontext:** `triggerSnippet` in `ContentView.swift` ruft heute
`SnippetKeystrokes.bytes(for:execute:)` und `terminal.send(bytes)`. `terminal`
ist ein `TerminalPanelViewModel` (Core) — es kennt SwiftTerm nicht. Die
SwiftTerm-`TerminalView` entsteht in `SSHTerminalView.makeNSView`. Der
etablierte Weg zwischen beiden ist ein Closure, den die View dem Modell
übergibt: `viewModel.onOutput = { [weak terminal] bytes in … }` steht genau
dort. Diese Aufgabe nutzt dieselbe Form für die Rückrichtung.

- [ ] **Schritt 1: Den Kanal im Modell anlegen**

In `TerminalPanelViewModel.swift`, neben `onOutput`:

```swift
    /// Whether the remote has bracketed paste (mode 2004) on, as the local
    /// emulator has observed it. Set by the terminal view, the same way
    /// `onOutput` is; `nil` while no view is attached, which reads as "off"
    /// — the conservative answer, since it only ever costs a refusal or a
    /// line-by-line send, never an unexpected execution.
    public var bracketedPasteQuery: (() -> Bool)?

    /// `bracketedPasteQuery`'s answer, defaulting to `false`.
    public var remoteWantsBracketedPaste: Bool { bracketedPasteQuery?() ?? false }
```

- [ ] **Schritt 2: Die View füllt ihn**

In `SSHTerminalView.makeNSView`, unmittelbar bei `viewModel.onOutput = …`:

```swift
        viewModel.bracketedPasteQuery = { [weak terminal] in
            terminal?.getTerminal().bracketedPasteMode ?? false
        }
```

- [ ] **Schritt 3: `triggerSnippet` über den Planer führen**

In `ContentView.swift` den Block ab `let bytes = SnippetKeystrokes.bytes(...)`
ersetzen:

```swift
        let plan = SnippetSendPlanner.plan(
            command: snippet.command, execute: execute,
            bracketedPaste: terminal.remoteWantsBracketedPaste)
        guard case .send(let bytes) = plan else {
            // The remote cannot take a multi-line paste without running it,
            // and this entry promised to insert. Explain instead of sending
            // bytes that would execute -- see `SnippetSendPlan`.
            pendingMultilineInsertRefusal = snippet
            return
        }
```

Der Rest (`guard execute else { terminal.send(bytes); return }` und der
Audit-Zweig) bleibt unverändert. Ergänze `@State var pendingMultilineInsertRefusal: Snippet?` neben den
übrigen `@State`-Feldern in `ContentView.swift` und den Alert dort, wo die
Datei ihre übrigen Alerts trägt:

```swift
        .alert(
            L10n.string("snippets.insert.multilineRefused.title", "This snippet has several lines"),
            isPresented: Binding(
                get: { pendingMultilineInsertRefusal != nil },
                set: { if !$0 { pendingMultilineInsertRefusal = nil } }),
            presenting: pendingMultilineInsertRefusal
        ) { snippet in
            Button(L10n.string("snippets.insert.multilineRefused.execute", "Execute")) {
                pendingMultilineInsertRefusal = nil
                triggerSnippet(snippet, execute: true)
            }
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {
                pendingMultilineInsertRefusal = nil
            }
        } message: { _ in
            Text(L10n.string(
                "snippets.insert.multilineRefused.body",
                "The remote shell cannot take a multi-line command without running it. Execute it instead?"))
        }
```

**Vor dem Schreiben nachsehen:** ob `common.cancel` als Schlüssel existiert.

```bash
grep -n '"common.cancel"' Sources/MacSCPAppKit/Resources/en.lproj/Localizable.strings
```

Findet das nichts, nimm den Schlüssel, den die Nachbar-Alerts dieser Datei
für ihren Abbrechen-Knopf benutzen — und trage in den Bericht ein, welcher
das war.

- [ ] **Schritt 4: Die Texte in alle vier Kataloge**

Vier Schlüssel, in `en`, `de`, `fr` und `pl`. `snippets.command.moreLines %lld`
gehört zu Task 3 Schritt 4 und wird hier mit eingetragen, damit die vier
Kataloge in einem Zug gleichziehen. Setze sie in jedem Katalog an
dieselbe Stelle wie die übrigen `snippets.*`-Schlüssel:

```
"snippets.insert.multilineRefused.title" = "This snippet has several lines";
"snippets.insert.multilineRefused.body" = "The remote shell cannot take a multi-line command without running it. Execute it instead?";
"snippets.insert.multilineRefused.execute" = "Execute";
"snippets.command.moreLines %lld" = "+%lld more";
```

Deutsch:

```
"snippets.insert.multilineRefused.title" = "Dieses Snippet hat mehrere Zeilen";
"snippets.insert.multilineRefused.body" = "Die Gegenstelle kann einen mehrzeiligen Befehl nicht übernehmen, ohne ihn auszuführen. Stattdessen ausführen?";
"snippets.insert.multilineRefused.execute" = "Ausführen";
"snippets.command.moreLines %lld" = "+%lld weitere";
```

Französisch:

```
"snippets.insert.multilineRefused.title" = "Cet extrait comporte plusieurs lignes";
"snippets.insert.multilineRefused.body" = "L’interpréteur distant ne peut pas recevoir une commande multiligne sans l’exécuter. L’exécuter à la place ?";
"snippets.insert.multilineRefused.execute" = "Exécuter";
"snippets.command.moreLines %lld" = "+%lld de plus";
```

Polnisch:

```
"snippets.insert.multilineRefused.title" = "Ten fragment ma kilka wierszy";
"snippets.insert.multilineRefused.body" = "Zdalna powłoka nie może przyjąć polecenia wielowierszowego bez jego wykonania. Wykonać je zamiast tego?";
"snippets.insert.multilineRefused.execute" = "Wykonaj";
"snippets.command.moreLines %lld" = "+%lld więcej";
```

- [ ] **Schritt 5: Bauen und die volle Suite laufen lassen**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: grün. Fehlt ein Schlüssel in einem Katalog, färbt der
L10n-Wächtertest die Suite rot — das ist der beabsichtigte Fangnetzeffekt.

- [ ] **Schritt 6: Committen**

```bash
git add -A Sources
git commit -m "$(cat <<'EOF'
feat(app): send multi-line snippets by the remote's paste mode

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Abschluss

Nach Task 4 gehört ein Abschlussbericht nach
`docs/superpowers/specs/2026-08-19-snippet-mehrzeilig-abschluss.md`, deutsch,
mit:

- den gemessenen Suite-Zahlen vorher und nachher,
- der in Task 2 Schritt 4 gezählten Aufrufstellen-Zahl,
- der in Task 3 Schritt 3 gezählten `.defaultAction`-Zahl,
- **ausdrücklich** der ausstehenden Sichtprüfung: das Mitwachsen des Feldes
  samt Obergrenze, ⌘Return, die drei Anzeigestellen mit einem mehrzeiligen
  Befehl, und ein geklammertes Einfügen gegen eine echte Shell mit
  eingeschaltetem Modus.

Teil 1 hat gezeigt, dass für `NSViewRepresentable` weder die grüne Suite noch
das Review ausreicht: der Blick auf die laufende App fand dort zwei Fehler,
die beide plausibel aussahen. Dieser Abschnitt ist keine Fußnote.
