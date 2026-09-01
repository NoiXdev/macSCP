# Snippet editor part 3 — declared variables: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A snippet can declare variables that are prompted for when
triggered and inserted into the command safely quoted.

**Architecture:** The declaration lives in the snippet model and travels
with the export. Substitution is a pure function in Core that, for both
placements (placeholder in the text, prepended environment assignment),
yields either a resolved command or a rejection. Remembered values live in
their own store, never in the snippet. The app prompts before sending and
hands the result into the existing path from part 2.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, macOS 15+,
Swift Testing (`@Test`/`#expect`), SwiftUI + AppKit.

**Spec:** `docs/superpowers/specs/2026-08-19-snippet-variablen-design.md`

## Global Constraints

- Code, comments, identifiers, test names, commit messages: **English**.
  Internal docs under `docs/` stay German.
- Conventional Commits. Footer on **every** commit:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- TDD red→green. Every new piece of logic ships with tests.
- **Every commit builds and tests the whole package** (`swift build && swift test`).
  CI checks each one individually. Starting value: **2217 tests in 199 suites**, green.
- User-visible strings go through `L10n.string`, in **all four**
  catalogs (`en`, `de`, `fr`, `pl`). A guard test keeps the key sets
  equal.
- `"\r\n"` is **one** `Character` in Swift; line rules always go through
  `isNewline`, never `contains("\n")`.
- **No line number in a comment.** Writing a number or an
  enumeration of call sites means counting them in that same moment.
- A comment that describes other code is **corrected in the same pass
  that makes it wrong.** The predecessor branch had four
  review rounds on this.
- **Snippets never contain credentials.** Neither the declaration nor a
  remembered value may ever travel into the export or the session log.
- The app is **not** launched.

---

## Files

**New:**

- `Sources/macSCPCore/Terminal/SnippetVariable.swift` — the declaration,
  including the naming rule.
- `Sources/macSCPCore/Terminal/PosixQuoting.swift` — the quoting primitive
  extracted from `SSHCommandBuilder`, so it has **one** home.
- `Sources/macSCPCore/Terminal/SnippetVariableSubstitution.swift` — the
  substitution and the two rejections.
- `Sources/macSCPCore/Terminal/SnippetVariableMemoryStore.swift` —
  remembered values.
- `Sources/MacSCPAppKit/SnippetVariablePromptSheet.swift` — the prompt sheet.
- One test file each for the four Core types.

**Changed:** `Snippet.swift`, `SSHCommandBuilder.swift`, `SnippetsSheet.swift`,
`ContentView.swift`, the four `Localizable.strings`.

**Unchanged, even though you'd expect otherwise:** `SnippetExportCodec.swift`. Its
payload is `[Snippet]`; declarations travel along as soon as the model has them.
A test pins this down; the code does not change.

---

## Task 1: Core — the declaration in the model

**Files:**
- Create: `Sources/macSCPCore/Terminal/SnippetVariable.swift`
- Create: `Tests/macSCPCoreTests/SnippetVariableTests.swift`
- Modify: `Sources/macSCPCore/Terminal/Snippet.swift`
- Modify: `Tests/macSCPCoreTests/SnippetExportCodecTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct SnippetVariable: Codable, Equatable, Sendable` mit
    `name`, `prompt`, `kind`, `placement`, `defaultValue`, `remembersLastValue`
  - `public enum SnippetVariable.Kind: Codable, Equatable, Sendable { case freeText; case selection([String]) }`
  - `public enum SnippetVariable.Placement: String, Codable, Equatable, Sendable { case placeholder; case environment }`
  - `public static func SnippetVariable.isValidName(_:) -> Bool`
  - `Snippet.variables: [SnippetVariable]`

- [ ] **Step 1: Write the failing tests**

`Tests/macSCPCoreTests/SnippetVariableTests.swift`:

```swift
import Testing
@testable import macSCPCore

@Suite("SnippetVariable")
struct SnippetVariableTests {
    /// The name becomes a shell assignment for `.environment`, so it has to
    /// be a valid shell identifier. The same rule applies to `.placeholder`
    /// deliberately: two rules for one field would be a defect source with
    /// no benefit.
    @Test("a valid name starts with a letter or underscore and continues alphanumerically")
    func validNames() {
        #expect(SnippetVariable.isValidName("DBNAME"))
        #expect(SnippetVariable.isValidName("_tmp2"))
        #expect(SnippetVariable.isValidName("a"))
    }

    @Test("a name that would not survive as a shell assignment is rejected")
    func invalidNames() {
        #expect(!SnippetVariable.isValidName(""))
        #expect(!SnippetVariable.isValidName("2FAST"))
        #expect(!SnippetVariable.isValidName("DB-NAME"))
        #expect(!SnippetVariable.isValidName("DB NAME"))
        #expect(!SnippetVariable.isValidName("DB;rm -rf /"))
    }

    @Test("a snippet carries its declarations through a store round trip")
    func declarationsSurviveEncoding() throws {
        let variable = SnippetVariable(
            name: "DBNAME", prompt: "Database", kind: .selection(["prod", "staging"]),
            placement: .environment, defaultValue: "staging", remembersLastValue: true)
        let original = Snippet(name: "dump", command: "mysqldump $DBNAME", variables: [variable])
        let decoded = try JSONDecoder().decode(
            Snippet.self, from: JSONEncoder().encode(original))
        #expect(decoded.variables == [variable])
    }

    /// A store file written before this feature has no `variables` key at
    /// all. It must decode as "no variables", exactly the way `tags` was
    /// introduced — not as an error.
    @Test("a snippet written before this feature still decodes")
    func legacySnippetDecodes() throws {
        let json = #"{"id":"00000000-0000-4000-8000-000000000001","name":"n","command":"ls","tags":[]}"#
        let decoded = try JSONDecoder().decode(Snippet.self, from: Data(json.utf8))
        #expect(decoded.variables.isEmpty)
    }
}
```

Append to `Tests/macSCPCoreTests/SnippetExportCodecTests.swift`:

```swift
    /// The export payload is `[Snippet]`, so declarations travel without the
    /// codec knowing about them. This test exists because that is easy to
    /// break later by narrowing the payload, and nothing else would notice.
    @Test("declarations survive an export round trip")
    func declarationsSurviveExport() throws {
        let variable = SnippetVariable(
            name: "HOST", prompt: "Host", kind: .freeText,
            placement: .placeholder, defaultValue: "", remembersLastValue: false)
        let snippet = Snippet(name: "ping", command: "ping {{HOST}}", variables: [variable])
        let data = try SnippetExportCodec.encode(SnippetExportPayload(snippets: [snippet]))
        let decoded = try SnippetExportCodec.decode(data)
        #expect(decoded.snippets.first?.variables == [variable])
    }
```

- [ ] **Step 2: Run red**

Run: `swift test --filter SnippetVariable 2>&1 | tail -20`
Expected: compile error — `SnippetVariable` does not exist.

- [ ] **Step 3: Write the type**

`Sources/macSCPCore/Terminal/SnippetVariable.swift`:

```swift
import Foundation

/// One value a snippet asks for before it runs (snippet editor, part 3).
///
/// Declaring the variables rather than scraping them out of the command text
/// is the whole point: a declaration is visible, ordered and can carry a
/// prompt, a default and a list of allowed values. The command text alone
/// could carry none of that.
public struct SnippetVariable: Codable, Equatable, Sendable {
    /// What the user is asked for.
    public enum Kind: Codable, Equatable, Sendable {
        case freeText
        /// The allowed values, offered as a list. Prevents a typo in a value
        /// like `prod` — the kind of mistake that is expensive on the far
        /// side of a connection.
        case selection([String])
    }

    /// How the value reaches the command.
    public enum Placement: String, Codable, Equatable, Sendable {
        /// `{{NAME}}` in the command text is replaced by the quoted value.
        case placeholder
        /// `NAME='value'` is prepended, and the command uses `$NAME` — or
        /// does not mention it at all and lets a called script read it.
        case environment
    }

    public let name: String
    public let prompt: String
    public let kind: Kind
    public let placement: Placement
    public let defaultValue: String
    /// Whether the last value is kept for the next run. **Off by default,
    /// and deliberately so:** a remembered value is written to a plain JSON
    /// file, so the choice to store one is made when the declaration is
    /// created — before any value exists — rather than after someone has
    /// typed something they did not mean to persist.
    public let remembersLastValue: Bool

    public init(
        name: String, prompt: String, kind: Kind, placement: Placement,
        defaultValue: String, remembersLastValue: Bool
    ) {
        self.name = name
        self.prompt = prompt
        self.kind = kind
        self.placement = placement
        self.defaultValue = defaultValue
        self.remembersLastValue = remembersLastValue
    }

    /// Whether `name` is a POSIX shell identifier: a letter or underscore,
    /// then letters, digits or underscores.
    ///
    /// Required for `.environment`, where the name becomes the left side of
    /// a shell assignment — a name carrying a space or a `;` would not be an
    /// assignment at all but a second command. Applied to `.placeholder` too:
    /// the substitution itself would tolerate anything, but two rules for one
    /// field is a defect source that buys nothing.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        guard first.isLetter && first.isASCII || first == "_" else { return false }
        return name.allSatisfy { ($0.isLetter || $0.isNumber) && $0.isASCII || $0 == "_" }
    }
}
```

In `Snippet.swift`: add the field, the `CodingKeys` case, the initializer
parameter with default `[]`, and in the decoder `decodeIfPresent(… ) ?? []`
**exactly like `tags`** — the existing comment there explains why that
establishes backward compatibility; add `variables` to that same
rationale instead of writing a second paragraph.

- [ ] **Step 4: Run green**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: green, more tests than before.

- [ ] **Step 5: Run the constant-return probe**

Temporarily replace `isValidName`'s body with `return true`.

Run: `swift test --filter SnippetVariable 2>&1 | grep -c 'failed'`
Expected: at least **1** test fails (`invalidNames`). Restore the body
afterward.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore/Terminal/SnippetVariable.swift Sources/macSCPCore/Terminal/Snippet.swift Tests/macSCPCoreTests/
git commit -m "$(cat <<'EOF'
feat(core): let a snippet declare its variables

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Core — one home for the quoting primitive

**Files:**
- Create: `Sources/macSCPCore/Terminal/PosixQuoting.swift`
- Create: `Tests/macSCPCoreTests/PosixQuotingTests.swift`
- Modify: `Sources/macSCPCore/SSH/SSHCommandBuilder.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `public enum PosixQuoting { public static func singleQuoted(_ value: String) -> String }`

**Context:** `SSHCommandBuilder` currently has a `private static func
posixSingleQuote(_:)`. Task 3 needs the same rule. It gets extracted,
**not copied** — two quoting implementations would be exactly
the kind of duplication that drifts apart eventually, and security would
hang on it here.

- [ ] **Step 1: Write the failing tests**

`Tests/macSCPCoreTests/PosixQuotingTests.swift`:

```swift
import Testing
@testable import macSCPCore

/// The one place a value becomes a single shell word.
///
/// Single quotes are used rather than double, because inside single quotes a
/// POSIX shell expands nothing at all — no `$`, no backtick, no backslash.
/// The only character that cannot appear literally is `'` itself, which is
/// why it is closed, escaped and reopened.
@Suite("PosixQuoting")
struct PosixQuotingTests {
    @Test("a plain value is wrapped in single quotes")
    func plainValue() {
        #expect(PosixQuoting.singleQuoted("backup") == "'backup'")
    }

    @Test("a value with a space stays one word")
    func valueWithSpace() {
        #expect(PosixQuoting.singleQuoted("kunden db") == "'kunden db'")
    }

    @Test("an embedded single quote is closed, escaped and reopened")
    func embeddedQuote() {
        #expect(PosixQuoting.singleQuoted("it's") == #"'it'\''s'"#)
    }

    /// The characters that would otherwise let a value become code.
    @Test("expansion characters are inert inside the quotes")
    func expansionCharacters() {
        #expect(PosixQuoting.singleQuoted("$HOME") == "'$HOME'")
        #expect(PosixQuoting.singleQuoted("`id`") == "'`id`'")
        #expect(PosixQuoting.singleQuoted("a\\b") == "'a\\b'")
    }

    /// The case this whole primitive exists for.
    @Test("a value that tries to end the word and start a command cannot")
    func injectionAttempt() {
        #expect(PosixQuoting.singleQuoted("x; rm -rf /") == "'x; rm -rf /'")
    }

    @Test("an empty value is an explicit empty word, not nothing")
    func emptyValue() {
        #expect(PosixQuoting.singleQuoted("") == "''")
    }
}
```

- [ ] **Step 2: Run red**

Run: `swift test --filter PosixQuoting 2>&1 | tail -10`
Expected: compile error.

- [ ] **Step 3: Extract**

`Sources/macSCPCore/Terminal/PosixQuoting.swift`:

```swift
import Foundation

/// Turning an arbitrary string into exactly one POSIX shell word.
///
/// Extracted from `SSHCommandBuilder`, which had this as a private helper,
/// so the snippet variable substitution can use the same rule instead of a
/// second implementation. Two quoting routines that drift apart is the
/// failure this extraction exists to prevent — and quoting is where a value
/// stops being data and becomes code if it is wrong.
public enum PosixQuoting {
    /// `value` wrapped in single quotes, with any embedded `'` written as
    /// `'\''` — close the quote, an escaped literal quote, reopen.
    ///
    /// Single quotes because a POSIX shell expands nothing inside them:
    /// `$`, backtick and backslash are all literal. `'` is the sole
    /// exception, which is what the escape handles.
    public static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
```

In `SSHCommandBuilder.swift`: delete `posixSingleQuote` and switch the call
site over to `PosixQuoting.singleQuoted`. **Count beforehand** how many call
sites there are, and put the number in the report:

```bash
grep -c 'posixSingleQuote' Sources/macSCPCore/SSH/SSHCommandBuilder.swift
```

- [ ] **Step 4: Run green**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: green. The existing `SSHCommandBuilderTests` check through
`shellCommand` and must **not** change — if they change, the switch has
shifted behavior. Report that instead of adjusting the tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests/PosixQuotingTests.swift
git commit -m "$(cat <<'EOF'
refactor(core): give POSIX quoting one home

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Core — substitution and the two rejections

**Files:**
- Create: `Sources/macSCPCore/Terminal/SnippetVariableSubstitution.swift`
- Create: `Tests/macSCPCoreTests/SnippetVariableSubstitutionTests.swift`

**Interfaces:**
- Consumes: `SnippetVariable` (Task 1), `PosixQuoting.singleQuoted` (Task 2),
  `SnippetHighlighter.tokens(in:language:)` (part 1, existing).
- Produces:
  - `public enum SnippetVariableSubstitution`
  - `public static func resolve(command:variables:values:) -> String`
  - `public static func firstDeclarationProblem(command:variables:) -> Problem?`
  - `public enum Problem: Equatable { case unusedPlaceholder(name: String); case placeholderInsideQuotes(name: String) }`

**Context:** `SnippetHighlighter.tokens(in:language:)` returns ranges with
kinds, including `.string` for quoted content. The check for "placeholder
sits inside quotes" asks this tokenizer, instead of building a
second state machine. Read its signature before you use it.

- [ ] **Step 1: Write the failing tests**

`Tests/macSCPCoreTests/SnippetVariableSubstitutionTests.swift`:

```swift
import Testing
@testable import macSCPCore

@Suite("SnippetVariableSubstitution")
struct SnippetVariableSubstitutionTests {
    private func placeholder(_ name: String) -> SnippetVariable {
        SnippetVariable(
            name: name, prompt: name, kind: .freeText, placement: .placeholder,
            defaultValue: "", remembersLastValue: false)
    }

    private func environment(_ name: String) -> SnippetVariable {
        SnippetVariable(
            name: name, prompt: name, kind: .freeText, placement: .environment,
            defaultValue: "", remembersLastValue: false)
    }

    @Test("a placeholder is replaced by the quoted value")
    func placeholderIsQuoted() {
        let resolved = SnippetVariableSubstitution.resolve(
            command: "mysqldump {{DB}} > out.sql", variables: [placeholder("DB")],
            values: ["DB": "kunden db"])
        #expect(resolved == "mysqldump 'kunden db' > out.sql")
    }

    @Test("a value that tries to inject a command stays one word")
    func placeholderValueCannotInject() {
        let resolved = SnippetVariableSubstitution.resolve(
            command: "echo {{MSG}}", variables: [placeholder("MSG")],
            values: ["MSG": "hi; rm -rf /"])
        #expect(resolved == "echo 'hi; rm -rf /'")
    }

    /// The collision this design had to answer: double braces occur in real
    /// commands. Only declared names are substituted, so a Go template
    /// survives untouched — no dialect, no escape rule.
    @Test("an undeclared double-brace expression is left alone")
    func undeclaredBracesSurvive() {
        let command = "kubectl get pods -o go-template='{{range .items}}{{.metadata.name}}{{end}}'"
        let resolved = SnippetVariableSubstitution.resolve(
            command: command, variables: [], values: [:])
        #expect(resolved == command)
    }

    @Test("an environment variable is prepended to a single-line command")
    func environmentSingleLine() {
        let resolved = SnippetVariableSubstitution.resolve(
            command: "./backup.sh", variables: [environment("DB")],
            values: ["DB": "kunden db"])
        #expect(resolved == "DB='kunden db' ./backup.sh")
    }

    /// A multi-line body cannot take a leading assignment on the same line —
    /// it would only scope to the first line. It becomes its own line, which
    /// is why the variable then outlives the run in that session.
    @Test("an environment variable becomes its own line for a multi-line body")
    func environmentMultiLine() {
        let resolved = SnippetVariableSubstitution.resolve(
            command: "cd /srv\nmake all", variables: [environment("DB")],
            values: ["DB": "x"])
        #expect(resolved == "DB='x'\ncd /srv\nmake all")
    }

    @Test("several environment variables keep declaration order")
    func environmentOrder() {
        let resolved = SnippetVariableSubstitution.resolve(
            command: "./run.sh", variables: [environment("A"), environment("B")],
            values: ["A": "1", "B": "2"])
        #expect(resolved == "A='1' B='2' ./run.sh")
    }

    @Test("a declared placeholder that appears nowhere is a problem")
    func unusedPlaceholderIsRejected() {
        let problem = SnippetVariableSubstitution.firstDeclarationProblem(
            command: "ls -la", variables: [placeholder("DB")])
        #expect(problem == .unusedPlaceholder(name: "DB"))
    }

    /// Deliberately NOT a problem: an environment variable that the command
    /// never mentions is the normal case — the called script reads it.
    @Test("an environment variable the command never mentions is fine")
    func unmentionedEnvironmentIsFine() {
        let problem = SnippetVariableSubstitution.firstDeclarationProblem(
            command: "./backup.sh", variables: [environment("DB")])
        #expect(problem == nil)
    }

    @Test("a placeholder inside quotes is a problem")
    func quotedPlaceholderIsRejected() {
        let problem = SnippetVariableSubstitution.firstDeclarationProblem(
            command: #"echo "{{DB}}""#, variables: [placeholder("DB")])
        #expect(problem == .placeholderInsideQuotes(name: "DB"))
    }

    @Test("a placeholder outside quotes is fine even when the command has quotes elsewhere")
    func unquotedPlaceholderBesideQuotesIsFine() {
        let problem = SnippetVariableSubstitution.firstDeclarationProblem(
            command: #"echo "start" {{DB}}"#, variables: [placeholder("DB")])
        #expect(problem == nil)
    }
}
```

- [ ] **Step 2: Run red**

Run: `swift test --filter SnippetVariableSubstitution 2>&1 | tail -10`
Expected: compile error.

- [ ] **Step 3: Implement**

`Sources/macSCPCore/Terminal/SnippetVariableSubstitution.swift`:

```swift
import Foundation

/// Turning a snippet's template into the command that actually runs.
///
/// Pure: values in, resolved command out. Nothing here talks to a store, a
/// terminal or a view — which is what makes the quoting, the one part where
/// a wrong answer turns data into code, fully testable.
public enum SnippetVariableSubstitution {
    /// What is wrong with a set of declarations, if anything.
    public enum Problem: Equatable {
        /// A placeholder declaration whose `{{NAME}}` appears nowhere: the
        /// user would be asked for a value that reaches nothing.
        case unusedPlaceholder(name: String)
        /// `echo "{{NAME}}"` — the value is already quoted by this type, so
        /// surrounding quotes would show up literally in the output.
        case placeholderInsideQuotes(name: String)
    }

    /// `command` with every declared variable applied.
    ///
    /// Placeholders are replaced by the quoted value; environment
    /// declarations are prepended as assignments in declaration order.
    /// A missing value is treated as the empty string rather than skipped —
    /// leaving `{{NAME}}` in a command that then runs would be worse than an
    /// empty argument.
    public static func resolve(
        command: String, variables: [SnippetVariable], values: [String: String]
    ) -> String {
        var resolved = command
        for variable in variables where variable.placement == .placeholder {
            resolved = resolved.replacingOccurrences(
                of: "{{\(variable.name)}}",
                with: PosixQuoting.singleQuoted(values[variable.name] ?? ""))
        }

        let assignments = variables
            .filter { $0.placement == .environment }
            .map { "\($0.name)=\(PosixQuoting.singleQuoted(values[$0.name] ?? ""))" }
        guard !assignments.isEmpty else { return resolved }

        // A leading `NAME=value command` assignment scopes to that ONE
        // command. For a multi-line body that would set it for the first
        // line only, so it becomes its own line instead -- which is why the
        // variable then outlives the run in that session, a fact the editor's
        // hint text states.
        let separator = resolved.contains(where: \.isNewline) ? "\n" : " "
        return assignments.joined(separator: " ") + separator + resolved
    }

    /// The first thing that would make these declarations wrong, or `nil`.
    ///
    /// The unused check applies to `.placeholder` **only**, and that is not
    /// an oversight: for `.environment` the intended and most common case is
    /// precisely that the command never mentions the name — `DB='x'
    /// ./backup.sh` sets it for a script that reads it itself. Checking for
    /// `$NAME` there would reject the natural usage.
    public static func firstDeclarationProblem(
        command: String, variables: [SnippetVariable]
    ) -> Problem? {
        let stringRanges = SnippetHighlighter.tokens(in: command, language: .shell)
            .filter { $0.kind == .string }
            .map(\.range)

        for variable in variables where variable.placement == .placeholder {
            let needle = "{{\(variable.name)}}"
            guard let first = command.range(of: needle) else {
                return .unusedPlaceholder(name: variable.name)
            }
            if stringRanges.contains(where: { $0.contains(first.lowerBound) }) {
                return .placeholderInsideQuotes(name: variable.name)
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run green**

Run: `swift build && swift test 2>&1 | tail -3`

- [ ] **Step 5: Run two mutation probes**

(a) Replace `PosixQuoting.singleQuoted(…)` in `resolve` with the raw value.
Run: `swift test --filter SnippetVariableSubstitution 2>&1 | grep -c failed`
Expected: at least **2** (the values with a space and with `;`).

(b) Make `firstDeclarationProblem` return `nil` unconditionally.
Expected: at least **2** fail.

Restore both times and run green again.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore/Terminal/SnippetVariableSubstitution.swift Tests/macSCPCoreTests/SnippetVariableSubstitutionTests.swift
git commit -m "$(cat <<'EOF'
feat(core): resolve declared snippet variables into a command

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Core — remembered values

**Files:**
- Create: `Sources/macSCPCore/Terminal/SnippetVariableMemoryStore.swift`
- Create: `Tests/macSCPCoreTests/SnippetVariableMemoryStoreTests.swift`
- Modify: `Sources/macSCPCore/Terminal/SnippetStore.swift`

**Interfaces:**
- Consumes: nothing from Tasks 1–3.
- Produces:
  - `public final class SnippetVariableMemoryStore` mit
    `init(directory: URL) throws`,
    `func value(snippetID: UUID, name: String) -> String?`,
    `func remember(_ value: String, snippetID: UUID, name: String) throws`,
    `func forget(snippetID: UUID) throws`

**Context:** `SnippetStore` writes `snippets.json` into a directory it
receives in its initializer. This store lands alongside it as
`snippet-variables.json`. **Why separate:** a snippet that changes itself
when it runs would no longer be a template record — and the export would
carry the values along.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("SnippetVariableMemoryStore")
struct SnippetVariableMemoryStoreTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a remembered value comes back")
    func rememberAndRead() throws {
        let store = try SnippetVariableMemoryStore(directory: try makeDirectory())
        let id = UUID()
        try store.remember("kunden db", snippetID: id, name: "DB")
        #expect(store.value(snippetID: id, name: "DB") == "kunden db")
    }

    @Test("an unknown variable has no value")
    func unknownIsNil() throws {
        let store = try SnippetVariableMemoryStore(directory: try makeDirectory())
        #expect(store.value(snippetID: UUID(), name: "DB") == nil)
    }

    @Test("values survive a reopen")
    func survivesReopen() throws {
        let directory = try makeDirectory()
        let id = UUID()
        try SnippetVariableMemoryStore(directory: directory)
            .remember("x", snippetID: id, name: "DB")
        let reopened = try SnippetVariableMemoryStore(directory: directory)
        #expect(reopened.value(snippetID: id, name: "DB") == "x")
    }

    /// Deleting a snippet must take its remembered values with it — the same
    /// coupling deleting a session has with its keychain entry. Otherwise a
    /// value outlives the thing that explains what it was for.
    @Test("forgetting a snippet drops all its values")
    func forgetDropsEverything() throws {
        let store = try SnippetVariableMemoryStore(directory: try makeDirectory())
        let id = UUID()
        try store.remember("a", snippetID: id, name: "ONE")
        try store.remember("b", snippetID: id, name: "TWO")
        try store.forget(snippetID: id)
        #expect(store.value(snippetID: id, name: "ONE") == nil)
        #expect(store.value(snippetID: id, name: "TWO") == nil)
    }

    @Test("forgetting one snippet leaves another alone")
    func forgetIsScoped() throws {
        let store = try SnippetVariableMemoryStore(directory: try makeDirectory())
        let kept = UUID()
        let dropped = UUID()
        try store.remember("keep", snippetID: kept, name: "DB")
        try store.remember("drop", snippetID: dropped, name: "DB")
        try store.forget(snippetID: dropped)
        #expect(store.value(snippetID: kept, name: "DB") == "keep")
    }
}
```

- [ ] **Step 2: Run red**

Run: `swift test --filter SnippetVariableMemoryStore 2>&1 | tail -10`

- [ ] **Step 3: Implement, and couple the deletion**

The store writes `snippet-variables.json` with `options: .atomic`, the way
`SnippetStore` does — look it up there instead of doing it differently.

`SnippetStore.remove(id:)` must take the remembered values along. **Decide
while reading the existing code** whether the coupling belongs in
`SnippetStore` (in which case it needs a reference to the memory store
there) or at the call site in the app. State in the report which you
chose and why — and if you leave the coupling in the app, add a test that
proves it actually happens there.

- [ ] **Step 4: Run green**

Run: `swift build && swift test 2>&1 | tail -3`

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests/SnippetVariableMemoryStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(core): remember opted-in snippet variable values

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: App — variables in the editor

**On the steps of this task and the next:** they prescribe behavior and
text, but no finished SwiftUI layout. That is deliberate, and the lesson
from part 2: there, a prescribed view arrangement that no test could check
produced the branch's only critical. Layout belongs modeled on the
existing code and in visual review, not in a plan literal. Everything a
test can hold, by contrast, is written out as code.

**Files:**
- Modify: `Sources/MacSCPAppKit/SnippetsSheet.swift`
- Modify: die vier `Localizable.strings`
- Modify: `Tests/macSCPAppKitTests/SnippetCommandEditorGuardTests.swift`

**Interfaces:**
- Consumes: `SnippetVariable`, `SnippetVariableSubstitution.firstDeclarationProblem`.
- Produces: nothing for Task 6.

- [ ] **Step 1: Build the section**

Below the command field, a "Variables" section: one row per declaration
with name, label, kind, placement, default value and the remember
checkbox, plus a plus to add and a minus per row. Follow the rhythm that
`SnippetsSheet` and `FormRow` already set — **read both before inventing
your own arrangement.**

Below the section, a hint text that says two things, because both are
surprising: that a value is inserted as **one** shell word, and that an
environment variable on a **multi-line** command stays set in the session
after the run.

- [ ] **Step 2: Reject saving**

`isSaveDisabled` gets two more reasons: an invalid or duplicate variable
name, and a `firstDeclarationProblem != nil`. The reason is shown visibly,
not just the button greyed out — someone who doesn't know why saving
doesn't work stops trying rather than continuing.

- [ ] **Step 3: The text into all four catalogs**

English:

```
"snippets.variables.title" = "Variables";
"snippets.variables.add" = "Add variable";
"snippets.variables.name" = "Name";
"snippets.variables.prompt" = "Prompt";
"snippets.variables.default" = "Default";
"snippets.variables.remember" = "Remember last value";
"snippets.variables.placement.placeholder" = "Placeholder in the command";
"snippets.variables.placement.environment" = "Environment variable";
"snippets.variables.kind.freeText" = "Free text";
"snippets.variables.kind.selection" = "Choice";
"snippets.variables.hint" = "A value is inserted as a single shell word. An environment variable in a multi-line command stays set in the session after the run.";
"snippets.variables.error.invalidName" = "A variable name must start with a letter or underscore and may contain only letters, digits and underscores.";
"snippets.variables.error.duplicateName" = "Two variables share a name.";
"snippets.variables.error.unusedPlaceholder" = "“%@” is never used in the command.";
"snippets.variables.error.quotedPlaceholder" = "“%@” sits inside quotes. Remove them — the value is quoted for you.";
```

German:

```
"snippets.variables.title" = "Variablen";
"snippets.variables.add" = "Variable hinzufügen";
"snippets.variables.name" = "Name";
"snippets.variables.prompt" = "Abfragetext";
"snippets.variables.default" = "Vorgabe";
"snippets.variables.remember" = "Letzten Wert merken";
"snippets.variables.placement.placeholder" = "Platzhalter im Kommando";
"snippets.variables.placement.environment" = "Umgebungsvariable";
"snippets.variables.kind.freeText" = "Freitext";
"snippets.variables.kind.selection" = "Auswahl";
"snippets.variables.hint" = "Ein Wert wird als ein einzelnes Shell-Wort eingesetzt. Eine Umgebungsvariable bleibt bei einem mehrzeiligen Kommando nach dem Lauf in der Sitzung gesetzt.";
"snippets.variables.error.invalidName" = "Ein Variablenname beginnt mit einem Buchstaben oder Unterstrich und enthält nur Buchstaben, Ziffern und Unterstriche.";
"snippets.variables.error.duplicateName" = "Zwei Variablen haben denselben Namen.";
"snippets.variables.error.unusedPlaceholder" = "„%@“ kommt im Kommando nicht vor.";
"snippets.variables.error.quotedPlaceholder" = "„%@“ steht in Anführungszeichen. Nimm sie weg — der Wert wird für dich gequotet.";
```

French:

```
"snippets.variables.title" = "Variables";
"snippets.variables.add" = "Ajouter une variable";
"snippets.variables.name" = "Nom";
"snippets.variables.prompt" = "Invite";
"snippets.variables.default" = "Valeur par défaut";
"snippets.variables.remember" = "Mémoriser la dernière valeur";
"snippets.variables.placement.placeholder" = "Paramètre fictif dans la commande";
"snippets.variables.placement.environment" = "Variable d’environnement";
"snippets.variables.kind.freeText" = "Texte libre";
"snippets.variables.kind.selection" = "Choix";
"snippets.variables.hint" = "Une valeur est insérée comme un seul mot du shell. Dans une commande multiligne, une variable d’environnement reste définie dans la session après l’exécution.";
"snippets.variables.error.invalidName" = "Un nom de variable commence par une lettre ou un tiret bas et ne contient que des lettres, des chiffres et des tirets bas.";
"snippets.variables.error.duplicateName" = "Deux variables portent le même nom.";
"snippets.variables.error.unusedPlaceholder" = "« %@ » n’apparaît jamais dans la commande.";
"snippets.variables.error.quotedPlaceholder" = "« %@ » se trouve entre guillemets. Retirez-les — la valeur est protégée pour vous.";
```

Polish:

```
"snippets.variables.title" = "Zmienne";
"snippets.variables.add" = "Dodaj zmienną";
"snippets.variables.name" = "Nazwa";
"snippets.variables.prompt" = "Pytanie";
"snippets.variables.default" = "Wartość domyślna";
"snippets.variables.remember" = "Zapamiętaj ostatnią wartość";
"snippets.variables.placement.placeholder" = "Symbol zastępczy w poleceniu";
"snippets.variables.placement.environment" = "Zmienna środowiskowa";
"snippets.variables.kind.freeText" = "Dowolny tekst";
"snippets.variables.kind.selection" = "Wybór";
"snippets.variables.hint" = "Wartość jest wstawiana jako jedno słowo powłoki. W poleceniu wielowierszowym zmienna środowiskowa pozostaje ustawiona w sesji po wykonaniu.";
"snippets.variables.error.invalidName" = "Nazwa zmiennej zaczyna się od litery lub podkreślenia i zawiera tylko litery, cyfry i podkreślenia.";
"snippets.variables.error.duplicateName" = "Dwie zmienne mają tę samą nazwę.";
"snippets.variables.error.unusedPlaceholder" = "„%@” nie występuje w poleceniu.";
"snippets.variables.error.quotedPlaceholder" = "„%@” znajduje się w cudzysłowie. Usuń go — wartość zostanie zacytowana za Ciebie.";
```

- [ ] **Step 4: Build and run the suite**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: green. If a key is missing from a catalog, the guard turns red.

- [ ] **Step 5: Commit**

```bash
git add -A Sources/MacSCPAppKit Tests/macSCPAppKitTests
git commit -m "$(cat <<'EOF'
feat(app): declare snippet variables in the editor

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: App — prompting on trigger

**Files:**
- Create: `Sources/MacSCPAppKit/SnippetVariablePromptSheet.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift`
- Modify: die vier `Localizable.strings`

**Interfaces:**
- Consumes: `SnippetVariableSubstitution.resolve`, `SnippetVariableMemoryStore`.
- Produces: nothing.

**Context:** `ContentView.triggerSnippet(_:execute:)` currently runs
directly through `SnippetSendPlanner`. The prompt inserts itself
**before** that; from the resolved command onward, the path from part 2
stays unchanged.

**A trap the predecessor branch learned the hard way:** a sheet requested
from within a sheet or popover that is in the middle of closing gets
swallowed by SwiftUI. The four triggers in `ContentView+Detail.swift`
therefore already close **first** and trigger afterward. When wiring this
in, check that this still holds, and state in the report how many
triggers you checked.

- [ ] **Step 1: Build the sheet**

One field per declaration, pre-filled from a remembered value, otherwise
from `defaultValue`; `.selection` becomes a picker. Cancel sends nothing.

- [ ] **Step 2: Wire up `triggerSnippet`**

If the snippet has no declarations, everything stays as it is today —
**no** sheet. Otherwise: show the sheet, on confirmation remember the
checked values, then `SnippetVariableSubstitution.resolve(...)` and hand
the resolved command into the existing path.

- [ ] **Step 3: The text into all four catalogs**

```
en: "snippets.variables.promptTitle" = "Values for “%@”";
en: "snippets.variables.promptRun" = "Run";
de: "snippets.variables.promptTitle" = "Werte für „%@“";
de: "snippets.variables.promptRun" = "Ausführen";
fr: "snippets.variables.promptTitle" = "Valeurs pour « %@ »";
fr: "snippets.variables.promptRun" = "Exécuter";
pl: "snippets.variables.promptTitle" = "Wartości dla „%@”";
pl: "snippets.variables.promptRun" = "Wykonaj";
```

- [ ] **Step 4: Write the log test**

Append to `Tests/macSCPCoreTests/SnippetAuditDetailTests.swift`:

```swift
    /// The audit log records the TEMPLATE, never a value. This is free today
    /// — `SnippetAuditDetail` reads `snippet.command`, which is the template
    /// — and a rule that is free is broken for free at the next rework.
    @Test("a variable value never reaches the audit text")
    func variableValuesStayOutOfTheAuditLog() {
        let variable = SnippetVariable(
            name: "DB", prompt: "Database", kind: .freeText, placement: .placeholder,
            defaultValue: "", remembersLastValue: false)
        let snippet = Snippet(
            name: "dump", command: "mysqldump {{DB}}", variables: [variable])
        let text = SnippetAuditDetail.text(for: snippet)
        #expect(text.contains("{{DB}}"))
        #expect(!text.contains("kunden"))
    }
```

- [ ] **Step 5: Build and run the suite**

Run: `swift build && swift test 2>&1 | tail -3`

- [ ] **Step 6: Commit**

```bash
git add -A Sources Tests
git commit -m "$(cat <<'EOF'
feat(app): ask for declared variables before a snippet runs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Wrap-up

Closing report per
`docs/superpowers/specs/2026-08-19-snippet-variables-closeout.md`, in
German, with the measured suite numbers, the call-site count counted in
Task 2, the decision from Task 4 Step 3, and **explicitly** the
outstanding visual review: the variables section in the editor, the
rejections with their texts, the prompt sheet from every trigger, and a
run with a value that contains a quote mark.

Part 1 and part 2 both showed that in this layer, neither the green suite
nor the review is enough.
