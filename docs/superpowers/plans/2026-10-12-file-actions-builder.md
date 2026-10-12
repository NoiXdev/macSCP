# User-defined file actions — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user write their own command templates and run them from the file context menu on the current selection.

**Architecture:** A `FileAction` is its own type with its own store, editor and export, and it reuses the snippet subsystem's security machinery rather than copying it — both `SnippetVariableSubstitution.resolve` and `.firstDeclarationProblem` already take `command: String` and `[SnippetVariable]` rather than a `Snippet`, which is what makes the separate type affordable. A remote action is resolved and **typed into the session's shell** as a snippet is, so nothing in Core executes it; a local action is resolved into an argv and spawned directly, following `ArchivePlan.localInvocation`.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v6)`), SwiftPM, Swift Testing, SwiftUI + AppKit.

**Spec:** `docs/superpowers/specs/2026-10-12-file-actions-builder-design.md` (`7fbeec52`, amended `beb1bed4`). Read it with this plan; the plan argues from it.

**Base:** `develop` at `beb1bed4`.

## Global Constraints

- **Code and comments: English only.** No German in source files.
- **Never hardcode a display string.** `L10n.string(_:_:)` in the App, `CoreL10n.string(_:)` in Core. Four catalogues: `en` (the source text), `de`, `fr`, `pl`. The German catalogue addresses the user as **du**.
- Tests: Swift Testing (`@Test`/`#expect`), **TDD red→green**. The observed red is **quoted in the commit message, never invented**.
- `swift test` and `swift build` take **no `--build-system` flag**.
- **No wall-clock ceiling in a test.** A floor is fine; a hang bound is `.timeLimit`.
- **In test targets every wait is an `await`** — no `syncShutdownGracefully()`, no `futureResult.wait()`, no `DispatchSemaphore.wait()`.
- **A negative source-scanning check needs a positive check beside it.**
- **A guard that spells a symbol it could read instead is waiting for a rename.** Derive where you can.
- **A value a test must not leak has two exits:** `#expect` prints the source text of its expression, so compute the `Bool` first.
- **A number or an enumeration written into a comment is counted in that same moment.**
- **A scripted replacement asserts its anchor is unique** before writing.
- **Never bare `git stash` / `git stash pop`** — the stack is shared with other sessions. **Never `git checkout -- <file>`**. A plant that edits a tracked file goes through `scripts/mutation-probe`, whose `BUILD FAILED`, `PLANT FAILED` and `PLANT CHANGED` are each its own non-pass outcome.
- Conventional Commits. Footer on every commit: `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`
- **Commit freely; push only when the maintainer asks.**
- **Do not launch the GUI/app binary.** Task 12 names the maintainer's own steps.
- **`docs/BACKLOG.md` is a measurement record:** a correction quotes verbatim what it withdraws, a figure travels with the command that produced it, a cell carries **no pipe at all**, and the command is re-run after the sentence is written.
- `/Users/noidee/_dev/noix-docs` is shared with other products and sessions. Work in a worktree on its own branch; push or merge only when the maintainer asks. User docs are public texts and carry **no tech-stack terms**.

## Review Focus

Five input classes the spec implies and that no task's own happy-path tests would reach. Each line's test is added to the task that owns the code, named there. Ordered by how likely it is to bite someone.

1. **A file name that is itself shell syntax** — `$(id)`, a name holding `; rm -rf ~ ;`, a name holding backticks. The quoter holds, but every test that pins it today pins a **user-typed** value; nothing pins a value that arrived from the server's listing. → Task 4.
2. **A file name containing a newline.** POSIX permits it. A resolved command then holds a newline, which flips `SnippetSendPlanner.plan` out of its `.send` branch into the bracketed-paste branch — a send shape chosen by server data rather than by the user. → Task 4.
3. **A file name beginning with `-`.** Refused on the local path per the spec's consequence 3, and that refusal needs a test in both directions: refused for `{{NAME}}`, and **not** refused for `{{PATH}}`, which is absolute and cannot begin with a hyphen. → Task 4.
4. **A combining-mark apostrophe in a file name.** The exact failure `ShellScalar.swift` records — an apostrophe followed by U+0308 breaking out of its own single quotes — now arriving from the server instead of from a text field. → Task 4.
5. **A selection that yields zero invocations.** An empty selection reaching the planner at all. The planner must say so rather than returning an empty list, which a caller reads as "planned, nothing to do". *An earlier draft of this line also named "a selection holding only directories", which is wrong: an action applies to a directory as readily as to a file, so such a selection yields one invocation per directory.* → Task 4.

All five land on Task 4 because that is where a selection becomes a command. Task 4 is therefore the task to review hardest.

---

## File Structure

| File | Change | Responsible for |
|---|---|---|
| `Sources/macSCPCore/FileActions/FileAction.swift` | Create | The type, its multi-selection choice, deterministic encoding |
| `Sources/macSCPCore/FileActions/FileActionTemplate.swift` | Create | Validity: the declaration gate, reserved names, the two local-only refusals |
| `Sources/macSCPCore/FileActions/FileActionSelectionValues.swift` | Create | Binding `PATH`, `DIR`, `NAME` from one selected item |
| `Sources/macSCPCore/FileActions/FileActionPlan.swift` | Create | Selection → the commands or argvs that will run, and the refusals |
| `Sources/macSCPCore/FileActions/FileActionActivity.swift` | Create | What a pane shows while a local action runs |
| `Sources/macSCPCore/FileActions/FileActionStore.swift` | Create | Persistence, mirroring `SnippetStore` |
| `Sources/macSCPCore/FileActions/FileActionExportCodec.swift` | Create | Export/import with its own probe, so the two kinds cannot mix |
| `Sources/macSCPCore/Presentation/BrowserContextMenu.swift` | Modify | `BrowserPaneSide` conformances; the new menu entry; offering it |
| `Sources/macSCPCore/Terminal/SnippetDryRun.swift` | Modify | `describing` generalized off `Snippet` |
| `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift` | Modify | Holds the pane's `fileActionActivity` |
| `Sources/MacSCPAppKit/BrowserPane+FileActions.swift` | Create | Menu dispatch and the two run paths |
| `Sources/MacSCPAppKit/FileActionConfirmSheet.swift` | Create | The resolved commands, before anything runs |
| `Sources/MacSCPAppKit/FileActionsSheet.swift` | Create | The list of stored actions, with import and export |
| `Sources/MacSCPAppKit/FileActionEditor.swift` | Create | Writing one action, and refusing it legibly |
| `Sources/MacSCPAppKit/BrowserPane.swift` | Modify | The menu switch, the sheet, the activity row |
| `Sources/MacSCPAppKit/MacSCPCommands.swift`, `MacSCPApp.swift`, `ContentView+Sheets.swift` | Modify | The "Manage File Actions…" item and its bridge |
| `Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings` | Modify | Every string the three surfaces show |
| `docs/BACKLOG.md` | Modify | Row 251 corrected again: both halves done |
| noix-docs `guide/` and `reference/changelog.md` | Modify | The user documentation |

Execution order: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 → 12.

---

### Task 1: `FileAction`, the type

**Files:**
- Create: `Sources/macSCPCore/FileActions/FileAction.swift`
- Modify: `Sources/macSCPCore/Presentation/BrowserContextMenu.swift` (the `BrowserPaneSide` declaration, line 5)
- Test: `Tests/macSCPCoreTests/FileActionTests.swift`

**Interfaces:**
- Consumes: `SnippetVariable` (`Sources/macSCPCore/Terminal/SnippetVariable.swift`), `BrowserPaneSide`.
- Produces: `FileAction`, `FileActionPerSelection`, and `BrowserPaneSide` gaining `String` raw values plus `Codable` and `Hashable`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/macSCPCoreTests/FileActionTests.swift`:

```swift
import Foundation
import Testing

@testable import macSCPCore

@Suite("FileAction")
struct FileActionTests {
    @Test func roundTripsThroughJSON() throws {
        let action = FileAction(
            name: "Count lines", command: "wc -l {{PATH}}",
            runsOn: [.remote], perSelection: .onceWithEveryPath)
        let data = try JSONEncoder().encode(action)
        let back = try JSONDecoder().decode(FileAction.self, from: data)
        #expect(back == action)
    }

    /// A `Set`'s iteration order is not stable across process launches, so an
    /// encoder that wrote it straight out would rewrite the store file
    /// differently on every save. The encoding sorts by raw value instead.
    @Test func runsOnEncodesSortedByRawValue() throws {
        let action = FileAction(
            name: "n", command: "c", runsOn: [.remote, .local],
            perSelection: .oncePerFile)
        let json = try #require(String(data: try JSONEncoder().encode(action), encoding: .utf8))
        #expect(json.contains("[\"local\",\"remote\"]"))
    }

    /// An absent `variables` key decodes to none, so a store file written
    /// before an action had variables keeps loading.
    @Test func anAbsentVariablesKeyDecodesToNone() throws {
        let json = """
            {"id":"7E4F7E1C-0000-4000-8000-000000000001","name":"n",
             "command":"c","runsOn":["remote"],"perSelection":"onceWithEveryPath"}
            """
        let action = try JSONDecoder().decode(FileAction.self, from: Data(json.utf8))
        #expect(action.variables.isEmpty)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter FileActionTests`
Expected: a **build failure** — no such type. Quote what the compiler printed, verbatim.

- [ ] **Step 3: Give `BrowserPaneSide` the conformances the field needs**

In `Sources/macSCPCore/Presentation/BrowserContextMenu.swift`, line 5 reads:

```swift
public enum BrowserPaneSide: Sendable { case local, remote }
```

Replace it with:

```swift
/// Raw values and `Codable`/`Hashable` since the file-actions plan of
/// 2026-10-12: a `FileAction` persists which sides it may run on, and a
/// stored side has to survive a relaunch by name rather than by ordinal.
public enum BrowserPaneSide: String, Codable, Hashable, Sendable {
    case local, remote
}
```

- [ ] **Step 4: Write the type**

Create `Sources/macSCPCore/FileActions/FileAction.swift`:

```swift
import Foundation

/// Whether one invocation covers the whole selection or each file gets its
/// own. `zip -r out.zip a b c` wants the first; `gzip a` wants the second,
/// because the tool takes one operand.
public enum FileActionPerSelection: String, Codable, Equatable, Sendable {
    case onceWithEveryPath
    case oncePerFile
}

/// A user-authored command template, run from the file context menu on the
/// current selection.
///
/// Deliberately NOT a `Snippet`, on the maintainer's ruling of 2026-10-12,
/// so that an export of one kind cannot carry the other. What it shares with
/// a snippet is the security machinery, not the type: both
/// `SnippetVariableSubstitution.resolve` and `.firstDeclarationProblem` take
/// a command and `[SnippetVariable]` rather than a `Snippet`, so they are
/// used here directly.
///
/// **There is no `skipsPlaceholderPlacementCheck`, and that is the point.**
/// A snippet's values are typed by the user, so waiving the position check
/// is a decision about their own input. An action's values come from the
/// server's directory listing, where the check is the protection rather than
/// a hurdle. The waiver is therefore not expressible, rather than available
/// and discouraged.
public struct FileAction: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let command: String
    public let variables: [SnippetVariable]
    /// The panes this action may run on. Never empty — `FileActionTemplate`
    /// refuses an action that declares no side.
    public let runsOn: Set<BrowserPaneSide>
    public let perSelection: FileActionPerSelection

    public init(
        id: UUID = UUID(), name: String, command: String,
        variables: [SnippetVariable] = [],
        runsOn: Set<BrowserPaneSide> = [.remote],
        perSelection: FileActionPerSelection = .onceWithEveryPath
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.variables = variables
        self.runsOn = runsOn
        self.perSelection = perSelection
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, command, variables, runsOn, perSelection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        variables = try container.decodeIfPresent([SnippetVariable].self, forKey: .variables) ?? []
        runsOn = Set(try container.decode([BrowserPaneSide].self, forKey: .runsOn))
        perSelection = try container.decode(FileActionPerSelection.self, forKey: .perSelection)
    }

    /// Writes `runsOn` as an array SORTED BY RAW VALUE. A `Set`'s own order
    /// is not stable across process launches, so encoding it directly would
    /// make the store file's bytes change on a save that changed nothing.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(command, forKey: .command)
        try container.encode(variables, forKey: .variables)
        try container.encode(runsOn.map(\.rawValue).sorted(), forKey: .runsOn)
        try container.encode(perSelection, forKey: .perSelection)
    }
}
```

- [ ] **Step 5: Run them to verify they pass**

Run: `swift test --filter FileActionTests`
Expected: 3 tests, 0 failures.

- [ ] **Step 6: Run the whole suite once**

Run: `swift test`
Expected: the only failure is `Tests/macSCPAppKitTests/ViewTestabilitySpike.swift:202`, this machine's standing failure (`docs/BACKLOG.md`, the row about an AppKit rendering assumption macOS 27 falsifies). Report it as seen; it is green on CI's runner.

- [ ] **Step 7: Commit**

```bash
git add Sources/macSCPCore/FileActions/FileAction.swift Sources/macSCPCore/Presentation/BrowserContextMenu.swift Tests/macSCPCoreTests/FileActionTests.swift
git commit -F - <<'MSG'
feat(actions): FileAction, a user-authored command template for the file menu

<< the red from Step 2, pasted exactly as the compiler printed it >>

Its own type rather than a Snippet, on the maintainer's ruling, so an
export of one kind cannot carry the other. It carries no
skipsPlaceholderPlacementCheck: a snippet's values are the user's own, an
action's come from the server's listing, and there the position check is
the protection rather than a hurdle.

runsOn encodes sorted by raw value, because a Set's iteration order is not
stable across launches and a store file that rewrites itself on a save
that changed nothing is a diff nobody can read.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

### Task 2: `FileActionTemplate`, the validity gate

**Files:**
- Create: `Sources/macSCPCore/FileActions/FileActionTemplate.swift`
- Test: `Tests/macSCPCoreTests/FileActionTemplateTests.swift`

**Interfaces:**
- Consumes: `FileAction` (Task 1); `SnippetVariableSubstitution.firstDeclarationProblem(command:variables:skipsPlacementCheck:)`, whose third parameter defaults to `false` and is therefore **not passed**; `SnippetCommandSurvey.survey(_:) -> Reading`.
- Produces: `FileActionTemplate.Problem`, `FileActionTemplate.reservedNames`, `FileActionTemplate.firstProblem(in:) -> Problem?`, `FileActionTemplate.isOneSimpleCommand(_:) -> Bool`.

**How "one simple command" is derived, and why not the obvious way.** Counting `.commandName` spans does **not** count commands: an assignment prefix contributes `.commandName` spans of its own, which that span's own comment in `SnippetCommandSurvey` spells out (`PGPASSWORD='secret' psql -h {{HOST}}` is named there as an everyday snippet). The derivation used instead is coverage: the survey appends a span for every **word** and for a comment, and appends none for an operator — a `|` or `&` is `advance()` then `beginCommand()`, and a redirection operator is consumed by `readRedirectionOperator()`. So **a command is one simple command exactly when every non-whitespace scalar lies inside some span.** It reads only the public `Reading`, so the survey is not touched and there is no second tokenizer. Where it is uncertain it refuses: an assignment prefix whose `=` falls outside a span comes out "not simple", which is the right answer anyway, because `VAR=x cmd` needs a shell and an argv cannot express it.

- [ ] **Step 1: Write the failing tests**

Create `Tests/macSCPCoreTests/FileActionTemplateTests.swift`:

```swift
import Foundation
import Testing

@testable import macSCPCore

@Suite("FileActionTemplate")
struct FileActionTemplateTests {
    private func remoteAction(
        _ command: String, variables: [SnippetVariable] = []
    ) -> FileAction {
        FileAction(name: "n", command: command, variables: variables, runsOn: [.remote])
    }

    private func localAction(
        _ command: String, variables: [SnippetVariable] = []
    ) -> FileAction {
        FileAction(name: "n", command: command, variables: variables, runsOn: [.local])
    }

    private func declared(_ name: String, placement: SnippetVariable.Placement) -> SnippetVariable {
        SnippetVariable(
            name: name, prompt: "p", kind: .freeText, placement: placement,
            defaultValue: "", remembersLastValue: false)
    }

    @Test func aPlainRemoteTemplateHasNoProblem() {
        #expect(FileActionTemplate.firstProblem(in: remoteAction("wc -l {{PATH}}")) == nil)
    }

    @Test func anActionDeclaringNoSideIsRefused() {
        let action = FileAction(name: "n", command: "wc -l {{PATH}}", runsOn: [])
        #expect(FileActionTemplate.firstProblem(in: action) == .noSideDeclared)
    }

    /// The three names the selection binds. `PATH` is the worst of them: a
    /// declared `PATH` with `.environment` placement would emit
    /// `export PATH='…';` into the user's own shell.
    @Test func eachReservedNameIsRefusedAsADeclaredVariable() {
        for name in ["PATH", "DIR", "NAME"] {
            let action = remoteAction(
                "wc -l {{\(name)}}", variables: [declared(name, placement: .placeholder)])
            #expect(
                FileActionTemplate.firstProblem(in: action) == .reservedVariableName(name),
                "\(name) was not refused")
        }
    }

    /// `.environment` prepends `export NAME='value';` as its own statement,
    /// and the local path has no shell to run a statement in.
    @Test func environmentPlacementIsRefusedForALocalCapableAction() {
        let action = localAction("wc -l {{PATH}}", variables: [declared("MODE", placement: .environment)])
        #expect(
            FileActionTemplate.firstProblem(in: action)
                == .environmentPlacementIsNotRunnableLocally(variable: "MODE"))
    }

    /// The same action is fine when it declares only the remote side, where
    /// there IS a shell.
    @Test func environmentPlacementIsAcceptedForARemoteOnlyAction() {
        let action = remoteAction(
            "wc -l $MODE {{PATH}}", variables: [declared("MODE", placement: .environment)])
        #expect(FileActionTemplate.firstProblem(in: action) == nil)
    }

    @Test func aPipelineIsRefusedForALocalCapableActionAndAcceptedForARemoteOne() {
        let command = "grep x {{PATH}} | wc -l"
        #expect(FileActionTemplate.firstProblem(in: localAction(command)) == .notOneSimpleCommandForLocal)
        #expect(FileActionTemplate.firstProblem(in: remoteAction(command)) == nil)
    }

    @Test func aRedirectionIsRefusedForALocalCapableAction() {
        #expect(
            FileActionTemplate.firstProblem(in: localAction("wc -l {{PATH}} > out.txt"))
                == .notOneSimpleCommandForLocal)
    }

    @Test func oneSimpleCommandIsRecognisedAsSuch() {
        #expect(FileActionTemplate.isOneSimpleCommand("wc -l {{PATH}}"))
        #expect(FileActionTemplate.isOneSimpleCommand("tar -czf out.tgz 'a b'"))
        #expect(FileActionTemplate.isOneSimpleCommand("ls | wc") == false)
        #expect(FileActionTemplate.isOneSimpleCommand("ls; ls") == false)
        #expect(FileActionTemplate.isOneSimpleCommand("ls > f") == false)
    }

    /// Without the synthesized variables the position of `{{PATH}}` would
    /// never be checked, and a quoted placeholder is exactly the position
    /// `.argument` exists to insist on. This is the test that pins the
    /// synthesis, so it is also the test that pins the design's central
    /// security claim.
    @Test func aSelectionPlaceholderInsideQuotesIsRefusedThoughNobodyDeclaredIt() {
        let action = remoteAction("wc -l '{{PATH}}'")
        let problem = FileActionTemplate.firstProblem(in: action)
        let isDeclarationProblem: Bool
        if case .declaration = problem { isDeclarationProblem = true } else { isDeclarationProblem = false }
        #expect(isDeclarationProblem)
    }

    @Test func syntheticVariablesNamesOnlyTheReservedNamesTheCommandUses() {
        let names = FileActionTemplate.syntheticVariables(for: "cp {{PATH}} {{NAME}}.bak").map(\.name)
        #expect(names == ["NAME", "PATH"])
        #expect(
            FileActionTemplate.syntheticVariables(for: "zip -r o.zip {{PATHS}}").map(\.name)
                == ["PATHS"])
        #expect(FileActionTemplate.syntheticVariables(for: "ls -l").isEmpty)
    }

    @Test func aPerFileNameIsRefusedWhenOneInvocationCoversTheWholeSelection() {
        let everyPath = FileAction(
            name: "n", command: "cp {{PATH}} {{NAME}}.bak", runsOn: [.remote],
            perSelection: .onceWithEveryPath)
        #expect(
            FileActionTemplate.firstProblem(in: everyPath)
                == .reservedNameDoesNotFitTheForm(name: "NAME", form: .onceWithEveryPath))
        let perFile = FileAction(
            name: "n", command: "cp {{PATH}} {{NAME}}.bak", runsOn: [.remote],
            perSelection: .oncePerFile)
        #expect(FileActionTemplate.firstProblem(in: perFile) == nil)
    }

    @Test func theListNameIsRefusedInThePerFileForm() {
        let perFile = FileAction(
            name: "n", command: "zip -r out.zip {{PATHS}}", runsOn: [.remote],
            perSelection: .oncePerFile)
        #expect(
            FileActionTemplate.firstProblem(in: perFile)
                == .reservedNameDoesNotFitTheForm(name: "PATHS", form: .oncePerFile))
        let everyPath = FileAction(
            name: "n", command: "zip -r out.zip {{PATHS}}", runsOn: [.remote],
            perSelection: .onceWithEveryPath)
        #expect(FileActionTemplate.firstProblem(in: everyPath) == nil)
    }

    /// `{{DIR}}` is the one reserved name that fits both forms, because a
    /// pane's listing never spans directories.
    @Test func theDirectoryNameFitsBothForms() {
        for form in [FileActionPerSelection.oncePerFile, .onceWithEveryPath] {
            let command = form == .oncePerFile ? "ls {{DIR}} {{PATH}}" : "ls {{DIR}} {{PATHS}}"
            let action = FileAction(
                name: "n", command: command, runsOn: [.remote], perSelection: form)
            #expect(FileActionTemplate.firstProblem(in: action) == nil, "\(form) refused {{DIR}}")
        }
    }

    /// The placement check runs with no way to switch it off. A store file
    /// carrying the snippet subsystem's waiver key decodes — unknown keys
    /// are ignored — and the check still reports the problem, which is what
    /// makes the absence of the field a boundary rather than a default.
    @Test func aStoredWaiverKeyDoesNotSwitchOffThePlacementCheck() throws {
        let json = """
            {"id":"7E4F7E1C-0000-4000-8000-000000000002","name":"n",
             "command":"wc -l '{{MODE}}'","runsOn":["remote"],
             "perSelection":"onceWithEveryPath",
             "skipsPlaceholderPlacementCheck":true,
             "variables":[{"name":"MODE","prompt":"p","kind":{"freeText":{}},
                           "placement":"placeholder","defaultValue":"",
                           "remembersLastValue":false}]}
            """
        let action = try JSONDecoder().decode(FileAction.self, from: Data(json.utf8))
        let problem = FileActionTemplate.firstProblem(in: action)
        #expect(problem != nil)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter FileActionTemplateTests`
Expected: a build failure — no such type. Quote it verbatim.

**If `SnippetVariable`'s `Kind` does not decode from the JSON spelling used in the last test**, read `SnippetVariable.Kind`'s synthesized coding and correct the fixture's spelling to match, then say so in the report. Do not change `SnippetVariable` to suit the fixture.

- [ ] **Step 3: Write the gate**

Create `Sources/macSCPCore/FileActions/FileActionTemplate.swift`:

```swift
import Foundation

/// Whether an action can run at all, and on the sides it claims.
///
/// Everything here is a refusal the author sees in the editor before the
/// action is saved, so none of it is a run-time surprise.
public enum FileActionTemplate {
    public enum Problem: Equatable, Sendable {
        /// What `SnippetVariableSubstitution.firstDeclarationProblem`
        /// answered. It is always asked with the placement check ON: the
        /// third parameter defaults to `false` and is not passed here.
        case declaration(SnippetVariableSubstitution.Problem)
        /// A declared variable took one of the names the selection binds.
        case reservedVariableName(String)
        /// `.environment` placement prepends `export NAME='value';` as its
        /// own statement; the local path has no shell to run one in.
        case environmentPlacementIsNotRunnableLocally(variable: String)
        /// A local-capable action's command must be ONE simple command. An
        /// argv cannot interpret a pipeline or a redirection, and building
        /// one from a pipeline's words would drop the operator and run
        /// something else — silently.
        case notOneSimpleCommandForLocal
        /// `runsOn` is empty, so the action could never be offered anywhere.
        case noSideDeclared
        /// A reserved name that does not fit this action's selection form.
        /// `{{PATH}}` and `{{NAME}}` are one file's, so they need
        /// `.oncePerFile`; `{{PATHS}}` is the whole selection's, so it needs
        /// `.onceWithEveryPath`. `{{DIR}}` fits both, because a pane's
        /// listing never spans directories -- `FileSearch` is "bounded
        /// strictly to the entries already loaded -- no recursion into
        /// subdirectories".
        case reservedNameDoesNotFitTheForm(name: String, form: FileActionPerSelection)
    }

    /// Every name the selection supplies. A declared variable may not take
    /// one: it would have two sources, and for `PATH` with `.environment`
    /// placement it would overwrite the user's own `PATH` for the rest of
    /// that shell session.
    ///
    /// Four rather than three because the list has its own name. A single
    /// name meaning one file in one action and a list in another would read
    /// correctly while being written and change what a command does when
    /// the form is switched, with nothing on screen saying so.
    public static let reservedNames: Set<String> = ["PATH", "PATHS", "DIR", "NAME"]

    /// Which reserved names a selection form supplies.
    public static func names(fitting form: FileActionPerSelection) -> Set<String> {
        switch form {
        case .oncePerFile: return ["PATH", "DIR", "NAME"]
        case .onceWithEveryPath: return ["PATHS", "DIR"]
        }
    }

    /// The three reserved names this command actually uses, as
    /// `SnippetVariable`s, so that the placement check covers them.
    ///
    /// **This is load-bearing, not bookkeeping.**
    /// `SnippetVariableSubstitution.firstDeclarationProblem` checks the
    /// placement of the variables it is GIVEN, and the selection-derived
    /// three are not declared by the author. Without synthesizing them, the
    /// position of `{{PATH}}` would never be checked -- and the position
    /// check is the whole of what stops a server-chosen name from being
    /// read as something other than one literal word.
    /// `PATHS` is included even though `FileActionPlanner` expands it
    /// before `resolve` is called rather than through `resolve`: a
    /// `{{PATHS}}` sitting inside quotes is exactly as wrong as a
    /// `{{PATH}}` there, so its POSITION is checked here either way.
    public static func syntheticVariables(for command: String) -> [SnippetVariable] {
        reservedNames.sorted()
            .filter { command.contains("{{\($0)}}") }
            .map {
                SnippetVariable(
                    name: $0, prompt: "", kind: .freeText, placement: .placeholder,
                    defaultValue: "", remembersLastValue: false)
            }
    }

    /// The first reason this action cannot run, or `nil`.
    public static func firstProblem(in action: FileAction) -> Problem? {
        if action.runsOn.isEmpty { return .noSideDeclared }

        for variable in action.variables where reservedNames.contains(variable.name) {
            return .reservedVariableName(variable.name)
        }

        let fitting = names(fitting: action.perSelection)
        for name in reservedNames.sorted()
        where !fitting.contains(name) && action.command.contains("{{\(name)}}") {
            return .reservedNameDoesNotFitTheForm(name: name, form: action.perSelection)
        }

        if action.runsOn.contains(.local) {
            for variable in action.variables where variable.placement == .environment {
                return .environmentPlacementIsNotRunnableLocally(variable: variable.name)
            }
            if !isOneSimpleCommand(action.command) {
                return .notOneSimpleCommandForLocal
            }
        }

        // The author's declarations AND the synthesized three. The third
        // parameter of `firstDeclarationProblem` is `skipsPlacementCheck`,
        // it defaults to `false`, and it is deliberately not passed.
        if let problem = SnippetVariableSubstitution.firstDeclarationProblem(
            command: action.command,
            variables: action.variables + syntheticVariables(for: action.command))
        {
            return .declaration(problem)
        }
        return nil
    }

    /// Whether `command` is one simple command — no operator that begins a
    /// second command, and no redirection.
    ///
    /// Derived from `SnippetCommandSurvey`'s public reading rather than from
    /// a second tokenizer: the survey appends a span for every word and for
    /// a comment, and appends NONE for an operator (`|` and `&` are
    /// `advance()` then `beginCommand()`; a redirection operator is consumed
    /// by its own reader). So an operator is exactly a non-whitespace scalar
    /// that no span covers.
    ///
    /// Counting `.commandName` spans would have been the obvious derivation
    /// and it is wrong: an assignment prefix contributes `.commandName`
    /// spans of its own, which that placement's comment in the survey names
    /// in those terms.
    ///
    /// Where this is uncertain it refuses. An assignment prefix whose `=`
    /// falls outside a span reads as "not simple", and that is the right
    /// answer regardless — `VAR=x cmd` needs a shell, and an argv cannot
    /// express it.
    public static func isOneSimpleCommand(_ command: String) -> Bool {
        guard case .surveyed(let spans) = SnippetCommandSurvey.survey(command) else {
            return false
        }
        let scalars = command.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            defer { index = scalars.index(after: index) }
            if scalars[index].properties.isWhitespace { continue }
            let covered = spans.contains { $0.range.contains(index) }
            if !covered { return false }
        }
        return true
    }
}
```

**Why `$0.range.contains(index)` type-checks across the two views:** an index into `String.UnicodeScalarView` IS a `String.Index`, so a range the survey produced by a scalar walk can be compared with an index from any other view without conversion. `ShellScalar.swift` says so in those terms, and names it as the mechanical reason the survey hands its spans to callers that found their occurrences by ordinary text search.

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter FileActionTemplateTests`
Expected: 14 tests, 0 failures.

- [ ] **Step 5: Prove the coverage derivation is sensitive**

Through the harness, never by hand. Write the plant to a file first — an inline `python3 -I -c "…"` is refused by the worktree guard, measured 2026-10-09 on the preceding plan:

```bash
cat > "$TMPDIR/plant-simple-command.py" <<'PY'
import io
p = 'Sources/macSCPCore/FileActions/FileActionTemplate.swift'
s = io.open(p, encoding='utf-8').read()
old = '            if !covered { return false }'
assert s.count(old) == 1, 'anchor not unique: %d' % s.count(old)
s = s.replace(old, '            if !covered { continue }')
io.open(p, 'w', encoding='utf-8').write(s)
PY
scripts/mutation-probe --filter FileActionTemplateTests --apply "python3 -I $TMPDIR/plant-simple-command.py"
rm -f "$TMPDIR/plant-simple-command.py"
```

Expected: RED, caught by `aPipelineIsRefusedForALocalCapableActionAndAcceptedForARemoteOne` and `oneSimpleCommandIsRecognisedAsSuch`. `BUILD FAILED`, `PLANT FAILED` and `PLANT CHANGED` are each their own outcome and none is a pass — if you get one, the probe proved nothing. Record the outcome verbatim.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore/FileActions/FileActionTemplate.swift Tests/macSCPCoreTests/FileActionTemplateTests.swift
git commit -F - <<'MSG'
feat(actions): the gate that decides whether an action can run, and where

<< the red from Step 2, pasted as the compiler printed it >>

Six refusals, all of them shown to the author in the editor rather than at
run time: a declaration problem from the snippet subsystem's own check, a
declared variable taking one of the three names the selection binds, an
.environment placement on an action claiming the local side where no shell
exists, a local-capable command that is more than one simple command, an
action that declares no side, and {{NAME}} in an action whose single
invocation covers a whole selection, where it has no one value.

The load-bearing part is syntheticVariables. firstDeclarationProblem
checks the placement of the variables it is GIVEN, and the three
selection-derived names are not declared by the author -- so without
synthesizing them the position of {{PATH}} would never be checked, and
that position check is the whole of what keeps a server-chosen name one
literal word. A test pins it by planting a quoted {{PATH}} that nobody
declared.

"One simple command" is derived from the survey's public reading by
coverage: the survey appends a span for every word and none for an
operator, so an operator is a non-whitespace scalar no span covers.
Counting commandName spans would have been the obvious derivation and is
wrong -- an assignment prefix contributes commandName spans of its own.

<< the mutation-probe outcome from Step 5, with the command >>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

### Task 3: `FileActionSelectionValues`, binding the selection

**Files:**
- Create: `Sources/macSCPCore/FileActions/FileActionSelectionValues.swift`
- Test: `Tests/macSCPCoreTests/FileActionSelectionValuesTests.swift`

**Interfaces:**
- Consumes: `RemoteFileItem` (`Sources/macSCPCore/RemoteFS/RemoteFileItem.swift`), `RemotePath.parent(of:)` and `RemotePath.normalizedAbsolute(_:)` (same file, the `RemotePath` enum).
- Produces: `FileActionSelectionValues.values(for:) -> [String: String]`, keyed `"PATH"`, `"DIR"`, `"NAME"` — the three names `FileActionTemplate.reservedNames` holds.

**Why the path is normalized first, and this is not a tidiness point.** `RemotePath`'s own doc comment reads: "Expects absolute, single-slash-normalized paths (e.g. "/home/user/docs"). Behavior on other input (relative paths, double slashes, etc.) is unspecified." A path from a server's directory listing is exactly unspecified input under this subsystem's threat model, so calling `parent(of:)` on it directly would be outside that function's contract. `RemotePath.normalizedAbsolute` is documented as **the one** function in that type that is safe on hostile input — "the 'behavior on other input is unspecified' caveat in this type's doc comment does not apply here" — so the binding routes through it first.

- [ ] **Step 1: Write the failing tests**

Create `Tests/macSCPCoreTests/FileActionSelectionValuesTests.swift`:

```swift
import Foundation
import Testing

@testable import macSCPCore

@Suite("FileActionSelectionValues")
struct FileActionSelectionValuesTests {
    private func item(path: String, name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: path, kind: .file)
    }

    @Test func bindsTheThreeReservedNames() {
        let values = FileActionSelectionValues.values(for: item(path: "/var/log/syslog", name: "syslog"))
        #expect(values["PATH"] == "/var/log/syslog")
        #expect(values["DIR"] == "/var/log")
        #expect(values["NAME"] == "syslog")
    }

    /// The three a SINGLE item supplies. `PATHS` is the whole selection's
    /// and is expanded by `FileActionPlanner`, not bound here, so it is
    /// absent by construction rather than by omission — and this equality
    /// is what would fail if it were ever added in the wrong place.
    @Test func bindsTheThreeNamesASingleItemSupplies() {
        let values = FileActionSelectionValues.values(for: item(path: "/a/b", name: "b"))
        #expect(Set(values.keys) == ["PATH", "DIR", "NAME"])
        #expect(Set(values.keys).isSubset(of: FileActionTemplate.reservedNames))
    }

    @Test func anItemAtTheRootGetsTheRootAsItsDirectory() {
        let values = FileActionSelectionValues.values(for: item(path: "/only", name: "only"))
        #expect(values["DIR"] == "/")
    }

    /// A listing is unspecified input for `RemotePath`, so the path is
    /// normalized before its parent is taken. A doubled slash from a server
    /// must not reach `parent(of:)` raw.
    @Test func aDoubledSlashFromTheServerIsNormalizedBeforeTheParentIsTaken() {
        let values = FileActionSelectionValues.values(for: item(path: "//var//log//syslog", name: "syslog"))
        #expect(values["PATH"] == "/var/log/syslog")
        #expect(values["DIR"] == "/var/log")
    }

    /// A trailing slash on a directory item must not make its own name the
    /// directory.
    @Test func aTrailingSlashDoesNotMakeTheItemItsOwnParent() {
        let values = FileActionSelectionValues.values(for: item(path: "/var/log/", name: "log"))
        #expect(values["PATH"] == "/var/log")
        #expect(values["DIR"] == "/var")
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter FileActionSelectionValuesTests`
Expected: a build failure. Quote it verbatim.

**If `RemoteFileItem.init` does not accept exactly `(name:path:kind:)`**, read its initializer and correct the two helpers in the test to the real signature, then say so in the report.

- [ ] **Step 3: Write the binding**

Create `Sources/macSCPCore/FileActions/FileActionSelectionValues.swift`:

```swift
import Foundation

/// The values one selected item binds, under the names
/// `FileActionTemplate.reservedNames` holds.
///
/// **All three are server data.** They come from a directory listing, not
/// from anything the user typed, which is the trust boundary this whole
/// subsystem exists to hold. Every one of them is wrapped by
/// `PosixQuoting.singleQuoted` on the way into a remote command, and
/// checked for a leading hyphen on the way into a local argv.
public enum FileActionSelectionValues {
    /// `PATH` and `DIR` are ABSOLUTE, because a remote action is typed into
    /// the user's own shell and that shell's working directory is wherever
    /// the user left it — not the directory the pane is showing. This
    /// feature issues no `cd`: that would change the state of a shell the
    /// user is also using by hand.
    ///
    /// The path is normalized first. `RemotePath` states that it "expects
    /// absolute, single-slash-normalized paths" and that behaviour on other
    /// input is unspecified, and a server's listing is other input;
    /// `normalizedAbsolute` is the one function in that type documented as
    /// safe on hostile input.
    public static func values(for item: RemoteFileItem) -> [String: String] {
        let path = RemotePath.normalizedAbsolute(item.path)
        return [
            "PATH": path,
            "DIR": RemotePath.parent(of: path),
            "NAME": item.name,
        ]
    }
}
```

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter FileActionSelectionValuesTests`
Expected: 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/FileActions/FileActionSelectionValues.swift Tests/macSCPCoreTests/FileActionSelectionValuesTests.swift
git commit -F - <<'MSG'
feat(actions): bind PATH, DIR and NAME from a selected item

<< the red from Step 2, pasted as the compiler printed it >>

The path is normalized through RemotePath.normalizedAbsolute before its
parent is taken. RemotePath's own doc comment says it expects
single-slash-normalized input and that behaviour on anything else is
unspecified, and a server's directory listing is anything else;
normalizedAbsolute is the one function in that type documented as safe on
hostile input.

PATH and DIR are absolute because a remote action is typed into the user's
own shell, whose working directory is wherever they left it, and this
feature issues no cd.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

### Task 4: `FileActionPlanner`, where a selection becomes a command

**This is the task to review hardest.** All five Review Focus entries land here, because this is the one place server data turns into something that runs.

**Files:**
- Create: `Sources/macSCPCore/FileActions/FileActionPlan.swift`
- Test: `Tests/macSCPCoreTests/FileActionPlannerTests.swift`

**Interfaces:**
- Consumes: `FileAction`, `FileActionPerSelection` (Task 1); `FileActionTemplate.firstProblem(in:)`, `.syntheticVariables(for:)` (Task 2); `FileActionSelectionValues.values(for:)` (Task 3); `SnippetVariableSubstitution.resolve(command:variables:values:)` and `.occurrences(of:in:)` — the latter is `static` and not `private`, so it is reachable from this module; `PosixQuoting.singleQuoted(_:)`; `SnippetCommandSurvey.survey(_:)`.
- Produces: `FileActionInvocation(executable:arguments:)`, `FileActionPlan.shellLines([String])` / `.invocations([FileActionInvocation])`, `FileActionPlanner.Refusal`, `FileActionPlanner.plan(action:selection:side:promptedValues:) -> Result<FileActionPlan, Refusal>`.

**Three mechanics worth stating before the code, because each replaces an obvious wrong way.**

`{{PATHS}}` is expanded **before** `resolve` and not through it. `resolve` substitutes one single-quoted value per name, and a list is not one value — passing a pre-joined string would get it quoted a second time. The positions are found with `SnippetVariableSubstitution.occurrences(of:in:)`, the project's own scalar walk, rather than `replacingOccurrences`: Foundation matches on grapheme clusters, so a metacharacter followed by a combining mark is not found, which is one of the two halves of the failure `ShellScalar.swift` records.

The **executable is always a literal.** `firstDeclarationProblem` refuses a placeholder at `.commandName`, so the first word of a valid template is never a value — which is why no part of this task has to ask what happens when a server-chosen name becomes the program being run.

The **local argv is split on whitespace, and that is only safe because quoting is refused.** `FileActionTemplate` refuses a local-capable template that holds quoting, so a word boundary is a whitespace boundary. This task checks it again from the spans rather than trusting the gate, because the two run at different times.

- [ ] **Step 1: Write the failing tests**

Create `Tests/macSCPCoreTests/FileActionPlannerTests.swift`:

```swift
import Foundation
import Testing

@testable import macSCPCore

@Suite("FileActionPlanner")
struct FileActionPlannerTests {
    private func item(_ path: String, _ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: path, kind: .file)
    }

    private func action(
        _ command: String, runsOn: Set<BrowserPaneSide> = [.remote],
        form: FileActionPerSelection = .oncePerFile
    ) -> FileAction {
        FileAction(name: "n", command: command, runsOn: runsOn, perSelection: form)
    }

    private func lines(
        _ action: FileAction, _ selection: [RemoteFileItem]
    ) throws -> [String] {
        let plan = try FileActionPlanner.plan(
            action: action, selection: selection, side: .remote).get()
        guard case .shellLines(let lines) = plan else {
            Issue.record("expected shell lines, got \(plan)")
            return []
        }
        return lines
    }

    // MARK: - The two forms

    @Test func oncePerFileProducesOneLinePerItem() throws {
        let produced = try lines(
            action("wc -l {{PATH}}"), [item("/a/x", "x"), item("/a/y", "y")])
        #expect(produced == ["wc -l '/a/x'", "wc -l '/a/y'"])
    }

    @Test func onceWithEveryPathProducesOneLineHoldingEveryPath() throws {
        let produced = try lines(
            action("zip -r out.zip {{PATHS}}", form: .onceWithEveryPath),
            [item("/a/x", "x"), item("/a/y", "y")])
        #expect(produced == ["zip -r out.zip '/a/x' '/a/y'"])
    }

    @Test func theDirectoryIsTheOneTheSelectionShares() throws {
        let produced = try lines(
            action("ls {{DIR}} {{PATHS}}", form: .onceWithEveryPath),
            [item("/a/x", "x"), item("/a/y", "y")])
        #expect(produced == ["ls '/a' '/a/x' '/a/y'"])
    }

    // MARK: - Review Focus 1: a file name that is itself shell syntax

    /// The quoter holds. Every test that pins it today pins a value the USER
    /// typed; this one pins a value that arrived from a directory listing,
    /// which is the only kind this subsystem ever sees.
    @Test func aNameThatIsShellSyntaxStaysOneLiteralWord() throws {
        let hostile = [
            "/tmp/$(id)",
            "/tmp/`id`",
            "/tmp/; rm -rf ~ ;",
            "/tmp/${HOME}",
            "/tmp/a&&b",
        ]
        for path in hostile {
            let produced = try lines(action("wc -l {{PATH}}"), [item(path, "x")])
            #expect(produced == ["wc -l \(PosixQuoting.singleQuoted(path))"], "\(path)")
        }
    }

    /// A single quote in the name is the case the quoter exists for: it has
    /// to close, escape and reopen.
    @Test func aNameHoldingASingleQuoteIsQuotedByTheProjectsQuoter() throws {
        let path = "/tmp/it's"
        let produced = try lines(action("wc -l {{PATH}}"), [item(path, "it's")])
        #expect(produced == ["wc -l \(PosixQuoting.singleQuoted(path))"])
    }

    // MARK: - Review Focus 2: a newline in a file name

    /// POSIX permits it. The resolved line then holds a newline, and that
    /// flips `SnippetSendPlanner.plan` out of its `.send` branch — a send
    /// SHAPE chosen by server data. The planner's job is to produce the line
    /// correctly; this test records that the shape changes, so the App task
    /// that sends it cannot be written in ignorance of it.
    @Test func aNameHoldingANewlineIsStillOneQuotedWordAndChangesTheSendShape() throws {
        let path = "/tmp/two\nlines"
        let produced = try lines(action("wc -l {{PATH}}"), [item(path, "two\nlines")])
        #expect(produced == ["wc -l \(PosixQuoting.singleQuoted(path))"])

        let plan = SnippetSendPlanner.plan(
            command: produced[0], execute: true, bracketedPaste: true)
        let isPlainSend: Bool
        if case .send = plan { isPlainSend = true } else { isPlainSend = false }
        #expect(isPlainSend == false)
    }

    // MARK: - Review Focus 3: a name beginning with a hyphen

    /// Refused on the LOCAL path, where there is no shell and the only way a
    /// value stops being a value is by being read as an option. Refused
    /// rather than prefixed `./`, because the author placed the placeholder
    /// and macSCP cannot know whether a prefix belongs there.
    @Test func aNameBeginningWithAHyphenIsRefusedOnTheLocalPath() {
        let result = FileActionPlanner.plan(
            action: action("gzip {{NAME}}", runsOn: [.local]),
            selection: [item("/a/-rf", "-rf")], side: .local)
        #expect(
            result == .failure(.valueWouldBeReadAsAnOption(name: "NAME", value: "-rf")))
    }

    /// The positive beside it: `{{PATH}}` cannot trip that refusal, because
    /// it is absolute and so begins with a slash. Without this the test
    /// above would also pass on a planner that refused everything.
    @Test func anAbsolutePathIsNeverRefusedAsAnOption() throws {
        let plan = try FileActionPlanner.plan(
            action: action("gzip {{PATH}}", runsOn: [.local]),
            selection: [item("/a/-rf", "-rf")], side: .local).get()
        #expect(plan == .invocations([FileActionInvocation(executable: "gzip", arguments: ["/a/-rf"])]))
    }

    /// And on the remote path the same name is fine, because the quoting
    /// holds and a quoted `-rf` is an operand.
    @Test func aNameBeginningWithAHyphenIsNotRefusedOnTheRemotePath() throws {
        let produced = try lines(action("gzip {{NAME}}"), [item("/a/-rf", "-rf")])
        #expect(produced == ["gzip '-rf'"])
    }

    // MARK: - Review Focus 4: a combining mark after a metacharacter

    /// The exact shape `ShellScalar.swift` records — an apostrophe followed
    /// by U+0308 COMBINING DIAERESIS is ONE `Character` that does not
    /// compare equal to `"'"` — now arriving from a listing rather than
    /// from a text field.
    @Test func anApostropheFollowedByACombiningMarkIsStillEscaped() throws {
        let path = "/tmp/a'\u{0308}b"
        let produced = try lines(action("wc -l {{PATH}}"), [item(path, "a'\u{0308}b")])
        #expect(produced == ["wc -l \(PosixQuoting.singleQuoted(path))"])
        let quotedCloses = produced[0].hasSuffix("'")
        #expect(quotedCloses)
    }

    // MARK: - Review Focus 5: nothing to run

    @Test func anEmptySelectionIsRefusedRatherThanPlannedAsNoCommands() {
        #expect(
            FileActionPlanner.plan(action: action("wc -l {{PATH}}"), selection: [], side: .remote)
                == .failure(.nothingToRun))
    }

    // MARK: - Sides and quoting

    @Test func aSideTheActionDidNotDeclareIsRefused() {
        #expect(
            FileActionPlanner.plan(
                action: action("wc -l {{PATH}}", runsOn: [.remote]),
                selection: [item("/a/x", "x")], side: .local)
                == .failure(.sideNotDeclared(.local)))
    }

    @Test func aTemplateProblemIsReportedBeforeAnythingElse() {
        let noSide = FileAction(name: "n", command: "wc -l {{PATH}}", runsOn: [])
        #expect(
            FileActionPlanner.plan(action: noSide, selection: [], side: .remote)
                == .failure(.template(.noSideDeclared)))
    }

    @Test func aLocalInvocationSplitsTheTemplateIntoWords() throws {
        let plan = try FileActionPlanner.plan(
            action: action("gzip -k {{PATH}}", runsOn: [.local]),
            selection: [item("/a/x", "x")], side: .local).get()
        #expect(
            plan == .invocations([
                FileActionInvocation(executable: "gzip", arguments: ["-k", "/a/x"])
            ]))
    }

    @Test func aPlaceholderInsideAWordBecomesOneArgument() throws {
        let plan = try FileActionPlanner.plan(
            action: action("cp {{PATH}} {{NAME}}.bak", runsOn: [.local]),
            selection: [item("/a/x", "x")], side: .local).get()
        #expect(
            plan == .invocations([
                FileActionInvocation(executable: "cp", arguments: ["/a/x", "x.bak"])
            ]))
    }

    @Test func everyPathBecomesSeveralArgumentsInOneLocalInvocation() throws {
        let plan = try FileActionPlanner.plan(
            action: action("zip -r out.zip {{PATHS}}", runsOn: [.local], form: .onceWithEveryPath),
            selection: [item("/a/x", "x"), item("/a/y", "y")], side: .local).get()
        #expect(
            plan == .invocations([
                FileActionInvocation(
                    executable: "zip", arguments: ["-r", "out.zip", "/a/x", "/a/y"])
            ]))
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter FileActionPlannerTests`
Expected: a build failure. Quote it verbatim.

- [ ] **Step 3: Write the planner**

Create `Sources/macSCPCore/FileActions/FileActionPlan.swift`:

```swift
import Foundation

/// One direct spawn. There is no shell on this path, so there is no quoting
/// and shell injection is not prevented but impossible; the only way a value
/// can stop being a value here is by being read as an option, and
/// `FileActionPlanner` refuses that rather than guessing a `./` prefix.
public struct FileActionInvocation: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

/// What will run, in order.
public enum FileActionPlan: Equatable, Sendable {
    /// Lines to type into the session's shell. More than one only for
    /// `.oncePerFile`. The shell runs them in order and **a failure does not
    /// stop the rest**: nothing here reads the shell's output, so nothing
    /// here has anything to decide on.
    case shellLines([String])
    /// Direct spawns, in order.
    case invocations([FileActionInvocation])
}

/// Turns an action plus a selection into the thing that will run.
public enum FileActionPlanner {
    public enum Refusal: Equatable, Sendable {
        case template(FileActionTemplate.Problem)
        case sideNotDeclared(BrowserPaneSide)
        /// An empty selection. Reported rather than returned as an empty
        /// list, which a caller would read as "planned, nothing to do".
        case nothingToRun
        /// A selection-derived value begins with `-`, so a tool on the local
        /// path would read it as an option. Only `{{NAME}}` can reach this:
        /// `{{PATH}}` and `{{PATHS}}` are absolute.
        case valueWouldBeReadAsAnOption(name: String, value: String)
        /// A local-capable template holds quoting. The argv is built by
        /// splitting on whitespace, and a quoted run spans word boundaries.
        case quotingIsNotRunnableLocally
    }

    public static func plan(
        action: FileAction, selection: [RemoteFileItem], side: BrowserPaneSide,
        promptedValues: [String: String] = [:]
    ) -> Result<FileActionPlan, Refusal> {
        if let problem = FileActionTemplate.firstProblem(in: action) {
            return .failure(.template(problem))
        }
        guard action.runsOn.contains(side) else { return .failure(.sideNotDeclared(side)) }
        guard !selection.isEmpty else { return .failure(.nothingToRun) }

        let groups: [[RemoteFileItem]]
        switch action.perSelection {
        case .oncePerFile: groups = selection.map { [$0] }
        case .onceWithEveryPath: groups = [selection]
        }

        switch side {
        case .remote:
            return .success(.shellLines(groups.map { remoteLine(action, $0, promptedValues) }))
        case .local:
            var invocations: [FileActionInvocation] = []
            for group in groups {
                switch localInvocation(action, group, promptedValues) {
                case .success(let invocation): invocations.append(invocation)
                case .failure(let refusal): return .failure(refusal)
                }
            }
            return .success(.invocations(invocations))
        }
    }

    // MARK: - Remote

    private static func remoteLine(
        _ action: FileAction, _ group: [RemoteFileItem], _ promptedValues: [String: String]
    ) -> String {
        var command = action.command
        if action.perSelection == .onceWithEveryPath {
            let list = group
                .map { PosixQuoting.singleQuoted(selectionValue("PATH", of: $0)) }
                .joined(separator: " ")
            command = replacing("PATHS", with: list, in: command)
        }
        var values = promptedValues
        if let first = group.first {
            let bound = FileActionSelectionValues.values(for: first)
            switch action.perSelection {
            case .oncePerFile:
                values.merge(bound) { _, new in new }
            case .onceWithEveryPath:
                // Only `DIR` is well defined for a whole selection, and every
                // item shares it: a pane's listing never spans directories.
                values["DIR"] = bound["DIR"]
            }
        }
        return SnippetVariableSubstitution.resolve(
            command: command,
            variables: action.variables + FileActionTemplate.syntheticVariables(for: command),
            values: values)
    }

    /// Replaces every `{{name}}` with `replacement`, finding the positions
    /// with the project's own scalar-correct finder rather than with
    /// `replacingOccurrences`, which compares on grapheme clusters and so
    /// does not find a metacharacter followed by a combining mark.
    private static func replacing(
        _ name: String, with replacement: String, in command: String
    ) -> String {
        let ranges = SnippetVariableSubstitution.occurrences(of: name, in: command)
        guard !ranges.isEmpty else { return command }
        var result = ""
        var cursor = command.startIndex
        for range in ranges {
            result += command[cursor..<range.lowerBound]
            result += replacement
            cursor = range.upperBound
        }
        result += command[cursor...]
        return result
    }

    // MARK: - Local

    private static func localInvocation(
        _ action: FileAction, _ group: [RemoteFileItem], _ promptedValues: [String: String]
    ) -> Result<FileActionInvocation, Refusal> {
        // Checked again here rather than trusted from the gate: the two run
        // at different times, and this is the one that is about to spawn.
        guard case .surveyed(let spans) = SnippetCommandSurvey.survey(action.command),
            spans.allSatisfy({ $0.placement != .quoted })
        else {
            return .failure(.quotingIsNotRunnableLocally)
        }

        var words: [String] = []
        for word in action.command.split(whereSeparator: \.isWhitespace).map(String.init) {
            if action.perSelection == .onceWithEveryPath,
                word == "{{PATHS}}"
            {
                words.append(contentsOf: group.map { selectionValue("PATH", of: $0) })
                continue
            }
            var substituted = word
            var carriedASelectionValue: (name: String, value: String)?
            if let first = group.first {
                for (name, value) in FileActionSelectionValues.values(for: first).sorted(by: { $0.key < $1.key })
                where substituted.contains("{{\(name)}}") {
                    substituted = replacing(name, with: value, in: substituted)
                    if carriedASelectionValue == nil {
                        carriedASelectionValue = (name, value)
                    }
                }
            }
            for (name, value) in promptedValues.sorted(by: { $0.key < $1.key })
            where substituted.contains("{{\(name)}}") {
                substituted = replacing(name, with: value, in: substituted)
            }
            if let carried = carriedASelectionValue, substituted.hasPrefix("-") {
                return .failure(
                    .valueWouldBeReadAsAnOption(name: carried.name, value: carried.value))
            }
            words.append(substituted)
        }

        guard let executable = words.first else { return .failure(.nothingToRun) }
        return .success(
            FileActionInvocation(executable: executable, arguments: Array(words.dropFirst())))
    }

    private static func selectionValue(_ name: String, of item: RemoteFileItem) -> String {
        FileActionSelectionValues.values(for: item)[name] ?? ""
    }
}
```

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter FileActionPlannerTests`
Expected: 16 tests, 0 failures.

If `.invocations` equality fails on the `{{PATHS}}` case because `out.zip` was itself substituted, read the failure rather than loosening the expectation: the template's literal words must pass through untouched.

- [ ] **Step 5: Prove the hyphen refusal is sensitive**

```bash
cat > "$TMPDIR/plant-option-check.py" <<'PY'
import io
p = 'Sources/macSCPCore/FileActions/FileActionPlan.swift'
s = io.open(p, encoding='utf-8').read()
old = '            if let carried = carriedASelectionValue, substituted.hasPrefix("-") {'
assert s.count(old) == 1, 'anchor not unique: %d' % s.count(old)
s = s.replace(old, '            if false, let carried = carriedASelectionValue {')
io.open(p, 'w', encoding='utf-8').write(s)
PY
scripts/mutation-probe --filter FileActionPlannerTests --apply "python3 -I $TMPDIR/plant-option-check.py"
rm -f "$TMPDIR/plant-option-check.py"
```

Expected: RED, caught by `aNameBeginningWithAHyphenIsRefusedOnTheLocalPath`. `BUILD FAILED`, `PLANT FAILED` and `PLANT CHANGED` are each their own outcome and none is a pass. Record the outcome verbatim.

- [ ] **Step 6: Run the whole suite**

Run: `swift test`
Expected: the only failure is the standing `ViewTestabilitySpike.swift:202`.

- [ ] **Step 7: Commit**

```bash
git add Sources/macSCPCore/FileActions/FileActionPlan.swift Tests/macSCPCoreTests/FileActionPlannerTests.swift
git commit -F - <<'MSG'
feat(actions): turn a selection into the commands that will run

<< the red from Step 2, pasted as the compiler printed it >>

This is the one place server data becomes something that runs, so the
tests are mostly about names a server chose rather than about the happy
path: a name that is itself shell syntax, a name holding a newline, a name
holding an apostrophe followed by a combining mark, a name beginning with
a hyphen, and an empty selection.

{{PATHS}} is expanded before resolve rather than through it, because
resolve substitutes one single-quoted value per name and a list is not one
value. Its positions are found with the project's own scalar-correct
finder; replacingOccurrences compares on grapheme clusters and would not
find a metacharacter followed by a combining mark.

A name beginning with a hyphen is refused on the local path rather than
prefixed ./, because the author places the placeholder and macSCP cannot
know whether the prefix belongs there. The positive beside that refusal is
that an absolute path can never trip it.

<< the mutation-probe outcome from Step 5, with the command >>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

### Task 5: `SnippetDryRun.describing` off `Snippet`

**Files:**
- Modify: `Sources/macSCPCore/Terminal/SnippetDryRun.swift` (`describing`, line 115)
- Test: `Tests/macSCPCoreTests/SnippetDryRunTests.swift` (add one case; the file's existing cases must stay green)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `SnippetDryRun.describing(command:variables:skipsPlacementCheck:values:execute:bracketedPaste:) -> SnippetDryRun`, plus the existing `describing(_:values:execute:bracketedPaste:)` kept as a forwarding overload.

**Why a refactor rather than a second type.** `describing` takes a `Snippet` and reads three things off it — `command`, `variables`, `skipsPlaceholderPlacementCheck`. A `FileActionDryRun` would be a second copy of a function whose whole job is to assemble four existing calls. Taking the three pieces instead makes it the same function for both kinds, which is the condition under which the separate `FileAction` type is affordable at all.

- [ ] **Step 1: Write the failing test**

Append to `Tests/macSCPCoreTests/SnippetDryRunTests.swift`, inside its existing suite:

```swift
    /// The same description, reached without a `Snippet`. The file-actions
    /// plan of 2026-10-12 needs this overload; the `Snippet` one forwards to
    /// it, so the two cannot drift.
    @Test func describingTakesThePiecesAndAgreesWithTheSnippetOverload() {
        let snippet = Snippet(name: "n", command: "wc -l {{F}}", variables: [
            SnippetVariable(
                name: "F", prompt: "p", kind: .freeText, placement: .placeholder,
                defaultValue: "", remembersLastValue: false)
        ])
        let viaSnippet = SnippetDryRun.describing(
            snippet, values: ["F": "/a/x"], execute: true, bracketedPaste: false)
        let viaPieces = SnippetDryRun.describing(
            command: snippet.command, variables: snippet.variables,
            skipsPlacementCheck: snippet.skipsPlaceholderPlacementCheck,
            values: ["F": "/a/x"], execute: true, bracketedPaste: false)
        #expect(viaPieces == viaSnippet)
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter describingTakesThePiecesAndAgreesWithTheSnippetOverload`
Expected: a build failure — no such overload. Quote it verbatim.

- [ ] **Step 3: Split the function**

In `Sources/macSCPCore/Terminal/SnippetDryRun.swift`, rename the existing body's parameters so the work happens on the three pieces, and keep the `Snippet` entry point forwarding to it. The existing body begins:

```swift
    public static func describing(
        _ snippet: Snippet, values: [String: String], execute: Bool, bracketedPaste: Bool
    ) -> SnippetDryRun {
        let resolved = SnippetVariableSubstitution.resolve(
            command: snippet.command, variables: snippet.variables, values: values)
```

Replace that signature and those first lines with:

```swift
    /// The `Snippet` entry point, kept so every existing caller is
    /// unchanged. It forwards; there is one implementation.
    public static func describing(
        _ snippet: Snippet, values: [String: String], execute: Bool, bracketedPaste: Bool
    ) -> SnippetDryRun {
        describing(
            command: snippet.command, variables: snippet.variables,
            skipsPlacementCheck: snippet.skipsPlaceholderPlacementCheck,
            values: values, execute: execute, bracketedPaste: bracketedPaste)
    }

    /// The same description from the three pieces a `Snippet` carries, so a
    /// `FileAction` reaches it without this file knowing that type exists
    /// (file-actions plan, 2026-10-12).
    public static func describing(
        command: String, variables: [SnippetVariable], skipsPlacementCheck: Bool,
        values: [String: String], execute: Bool, bracketedPaste: Bool
    ) -> SnippetDryRun {
        let resolved = SnippetVariableSubstitution.resolve(
            command: command, variables: variables, values: values)
```

Then, in the rest of that body, replace every `snippet.command` with `command`, every `snippet.variables` with `variables`, and `snippet.skipsPlaceholderPlacementCheck` with `skipsPlacementCheck`. **Assert before each replacement that its anchor is unique**, or do it by hand and read the diff back; a silent miss here compiles only if the old names are still in scope, which after the signature change they are not — so the compiler is the net, and the report says what the diff shows rather than what the edit intended.

- [ ] **Step 4: Run the whole dry-run suite**

Run: `swift test --filter SnippetDryRun`
Expected: every existing case plus the new one, 0 failures. **A single existing case going red here means the refactor changed behaviour** — stop and report rather than adjusting the case.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Terminal/SnippetDryRun.swift Tests/macSCPCoreTests/SnippetDryRunTests.swift
git commit -F - <<'MSG'
refactor(snippets): describe a dry run from the pieces, not from a Snippet

<< the red from Step 2, pasted as the compiler printed it >>

One implementation, two entry points: the Snippet overload forwards, so
every existing caller is unchanged and the two cannot drift. A FileAction
reaches the same description without this file knowing that type exists,
which is what keeps the security machinery one copy while the two kinds
stay separate types.

<< the dry-run suite figure from Step 4, with the command >>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

### Task 6: `FileActionStore`

**Files:**
- Create: `Sources/macSCPCore/FileActions/FileActionStore.swift`
- Test: `Tests/macSCPCoreTests/FileActionStoreTests.swift`

**Interfaces:**
- Consumes: `FileAction` (Task 1).
- Produces: `FileActionStore(directory:)`, `.all() throws -> [FileAction]`, `.save(_:) throws`, `.remove(id:) throws`.

**Mirrors `SnippetStore`** — stateless, atomic writes, a sibling JSON file. Two deliberate differences: the file is `file-actions.json`, so a store of one kind can never be read as the other; and `remove(id:)` returns nothing, because `SnippetStore.remove` returns a `VariableCleanupOutcome` about remembered variable values and an action has no such memory.

- [ ] **Step 1: Write the failing tests**

Create `Tests/macSCPCoreTests/FileActionStoreTests.swift`:

```swift
import Foundation
import Testing

@testable import macSCPCore

@Suite("FileActionStore")
struct FileActionStoreTests {
    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-actions-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func anAbsentFileReadsAsNoActions() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try FileActionStore(directory: dir).all().isEmpty)
    }

    @Test func savedActionsSurviveAReload() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileActionStore(directory: dir)
        let action = FileAction(name: "Count", command: "wc -l {{PATH}}")
        try store.save(action)
        #expect(try FileActionStore(directory: dir).all() == [action])
    }

    /// Replacing in place, not removing and appending: the menu lists
    /// actions in this order, so an edit must not move one to the end.
    @Test func savingAnEditedActionKeepsItsPlaceInTheList() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileActionStore(directory: dir)
        let first = FileAction(name: "A", command: "wc -l {{PATH}}")
        let second = FileAction(name: "B", command: "ls {{PATH}}")
        try store.save(first)
        try store.save(second)
        var edited = first
        edited.name = "A edited"
        try store.save(edited)
        #expect(try store.all().map(\.name) == ["A edited", "B"])
    }

    @Test func removingAnActionLeavesTheOthers() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileActionStore(directory: dir)
        let first = FileAction(name: "A", command: "wc -l {{PATH}}")
        let second = FileAction(name: "B", command: "ls {{PATH}}")
        try store.save(first)
        try store.save(second)
        try store.remove(id: first.id)
        #expect(try store.all().map(\.name) == ["B"])
    }

    /// Its own file, so a snippet store can never be read as actions. The
    /// positive beside that: the actions file IS the one that appeared.
    @Test func theStoreWritesItsOwnFileAndNotTheSnippetsOne() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileActionStore(directory: dir).save(FileAction(name: "A", command: "ls {{PATH}}"))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))
        #expect(names.contains("file-actions.json"))
        #expect(names.contains("snippets.json") == false)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter FileActionStoreTests`
Expected: a build failure. Quote it verbatim.

- [ ] **Step 3: Write the store**

Create `Sources/macSCPCore/FileActions/FileActionStore.swift`:

```swift
import Foundation

/// JSON persistence for user-defined file actions (`file-actions.json`),
/// following the same stateless, atomic-write pattern as `SnippetStore`.
///
/// Its **own file**, which is the point rather than a detail: an action and
/// a snippet are different kinds with different trust properties, and a
/// single file holding both would be one decode away from treating one as
/// the other. Secret-free by construction — a `FileAction` holds a command
/// template and nothing else.
public struct FileActionStore: Sendable {
    private let directory: URL
    private let fileURL: URL

    public init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("file-actions.json")
    }

    public func all() throws -> [FileAction] {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return []
        }
        return try JSONDecoder().decode([FileAction].self, from: try Data(contentsOf: fileURL))
    }

    /// Adds `action` at the end, or replaces the entry with the same `id`
    /// **in place**. In place rather than remove-and-append because the
    /// context menu lists actions in exactly this order, and an edit that
    /// moved one to the end would reorder the menu with nothing asking for
    /// it.
    public func save(_ action: FileAction) throws {
        var actions = try all()
        if let index = actions.firstIndex(where: { $0.id == action.id }) {
            actions[index] = action
        } else {
            actions.append(action)
        }
        try persist(actions)
    }

    public func remove(id: UUID) throws {
        try persist(try all().filter { $0.id != id })
    }

    private func persist(_ actions: [FileAction]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(actions)
        try data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter FileActionStoreTests`
Expected: 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/FileActions/FileActionStore.swift Tests/macSCPCoreTests/FileActionStoreTests.swift
git commit -F - <<'MSG'
feat(actions): persist file actions in their own file

<< the red from Step 2, pasted as the compiler printed it >>

file-actions.json beside snippets.json rather than inside it: an action
and a snippet are different kinds with different trust properties, and one
file holding both would be a single decode away from reading one as the
other. A test asserts the actions file appeared and the snippets file did
not.

save replaces in place rather than removing and appending, because the
context menu lists actions in store order and an edit must not move one to
the end.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

### Task 7: `FileActionExportCodec`

**Files:**
- Create: `Sources/macSCPCore/FileActions/FileActionExportCodec.swift`
- Test: `Tests/macSCPCoreTests/FileActionExportCodecTests.swift`

**Interfaces:**
- Consumes: `FileAction` (Task 1).
- Produces: `ExportedFileAction`, `FileActionExportPayload(actions:)`, `FileActionExportCodec.encode(_:) throws -> Data`, `.decode(_:) throws -> FileActionExportPayload`, `.probe(_:) throws -> Bool`.

**The one property this task exists for:** a snippet export file must not decode as actions, and an action export file must not decode as snippets. `SnippetExportCodec.probe(_:)` answers "is this a snippets file"; this codec's `probe` answers the same question about actions, and each must answer `false` for the other's payload. That is the structural half of the maintainer's "its own type" ruling — the half a rule in a document cannot enforce.

- [ ] **Step 1: Write the failing tests**

Create `Tests/macSCPCoreTests/FileActionExportCodecTests.swift`:

```swift
import Foundation
import Testing

@testable import macSCPCore

@Suite("FileActionExportCodec")
struct FileActionExportCodecTests {
    private let action = FileAction(
        name: "Count", command: "wc -l {{PATH}}", runsOn: [.remote, .local],
        perSelection: .oncePerFile)

    @Test func roundTripsThroughThePayload() throws {
        let data = try FileActionExportCodec.encode(
            FileActionExportPayload(actions: [ExportedFileAction(action)]))
        let back = try FileActionExportCodec.decode(data)
        #expect(back.actions.count == 1)
        #expect(back.actions[0].name == "Count")
        #expect(back.actions[0].command == "wc -l {{PATH}}")
    }

    @Test func probeAcceptsItsOwnPayload() throws {
        let data = try FileActionExportCodec.encode(
            FileActionExportPayload(actions: [ExportedFileAction(action)]))
        #expect(try FileActionExportCodec.probe(data) == true)
    }

    /// The property the separate type exists for, in both directions.
    @Test func neitherCodecAcceptsTheOthersPayload() throws {
        let actions = try FileActionExportCodec.encode(
            FileActionExportPayload(actions: [ExportedFileAction(action)]))
        let snippets = try SnippetExportCodec.encode(
            SnippetExportPayload(snippets: [
                ExportedSnippet(Snippet(name: "n", command: "ls"))
            ]))
        #expect(try FileActionExportCodec.probe(snippets) == false)
        #expect(try SnippetExportCodec.probe(actions) == false)
    }

    /// An export carries no `runsOn` waiver and no stored id trickery: what
    /// it carries is the template and the two choices that decide what the
    /// template means. An imported action arrives with both set, so there is
    /// no "absent means anything" case to reason about later.
    @Test func anExportCarriesTheFormAndTheSides() throws {
        let data = try FileActionExportCodec.encode(
            FileActionExportPayload(actions: [ExportedFileAction(action)]))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"perSelection\""))
        #expect(text.contains("\"runsOn\""))
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter FileActionExportCodecTests`
Expected: a build failure. Quote it verbatim.

**Read `Sources/macSCPCore/Terminal/SnippetExportCodec.swift` first** — `ExportedSnippet`, `SnippetExportPayload` and the three `SnippetExportCodec` functions are the shape to mirror, including how `probe` decides. If `SnippetExportCodec.probe` turns out to accept any JSON object with the right top-level key, say so in the report: the cross-rejection test above then depends on the two keys differing, and that is worth stating rather than assuming.

- [ ] **Step 3: Write the codec**

Create `Sources/macSCPCore/FileActions/FileActionExportCodec.swift`, mirroring `SnippetExportCodec`:

```swift
import Foundation

/// One action in an export file. A separate type from `FileAction` for the
/// same reason `ExportedSnippet` is separate from `Snippet`: an export is a
/// wire format, and a field the wire format does not name cannot be
/// expressed by an import — which is a capability boundary rather than an
/// import-side cleanup rule someone has to remember.
public struct ExportedFileAction: Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var command: String
    public var variables: [SnippetVariable]?
    public var runsOn: [BrowserPaneSide]
    public var perSelection: FileActionPerSelection

    public init(_ action: FileAction) {
        self.id = action.id
        self.name = action.name
        self.command = action.command
        self.variables = action.variables.isEmpty ? nil : action.variables
        self.runsOn = action.runsOn.map(\.rawValue).sorted().compactMap(BrowserPaneSide.init)
        self.perSelection = action.perSelection
    }

    /// The action this entry describes, with a fresh identity so an import
    /// never silently overwrites an action the user already has.
    public func imported() -> FileAction {
        FileAction(
            name: name, command: command, variables: variables ?? [],
            runsOn: Set(runsOn), perSelection: perSelection)
    }
}

/// The top-level object of an export file. Its key is `actions`, which is
/// what tells it apart from a snippets file.
public struct FileActionExportPayload: Codable, Equatable, Sendable {
    public var actions: [ExportedFileAction]

    public init(actions: [ExportedFileAction]) {
        self.actions = actions
    }
}

public enum FileActionExportCodec {
    public static func encode(_ payload: FileActionExportPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    public static func decode(_ data: Data) throws -> FileActionExportPayload {
        try JSONDecoder().decode(FileActionExportPayload.self, from: data)
    }

    /// Whether `data` is an actions export. Answers `false` for a snippets
    /// file, which is the half of the separation a document cannot enforce.
    public static func probe(_ data: Data) throws -> Bool {
        (try? decode(data)) != nil
    }
}
```

**If `probe` as written also returns `true` for a snippets payload** — because `JSONDecoder` ignores unknown keys and an absent `actions` key is the only thing distinguishing them — make `actions` required in a way the decoder enforces and say in the report which of the two it was. The test in Step 1 is the arbiter; do not weaken it.

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter FileActionExportCodecTests`
Expected: 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/FileActions/FileActionExportCodec.swift Tests/macSCPCoreTests/FileActionExportCodecTests.swift
git commit -F - <<'MSG'
feat(actions): export and import actions, and never snippets

<< the red from Step 2, pasted as the compiler printed it >>

The test that matters runs in both directions: an actions file does not
probe as snippets and a snippets file does not probe as actions. That is
the structural half of the ruling that an action is its own type -- the
half a sentence in a document cannot enforce.

An imported action arrives with a fresh identity, so an import never
silently overwrites an action the user already has.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

### Task 8: the menu entry

**Files:**
- Modify: `Sources/macSCPCore/Presentation/BrowserContextMenu.swift` (`BrowserMenuEntry`, line 28; `BrowserContextMenu.entries`, line 101)
- Test: `Tests/macSCPCoreTests/BrowserContextMenuTests.swift` (add cases to the existing suite)

**Interfaces:**
- Consumes: `FileAction` (Task 1), `FileActionTemplate.firstProblem(in:)` (Task 2).
- Produces: `BrowserMenuEntry.userFileAction(FileAction)`, and `BrowserContextMenu.entries` gaining a parameter `userFileActions: [FileAction] = []`.

**Where the entries go and why not beside the backend ones.** `BrowserMenuEntry` already has `backendFileAction(FileActionContribution)` for a protocol-contributed action. A user action is a different thing — the backend's is a capability of the connection, the user's is something they wrote — so it gets its own case rather than being squeezed through `FileActionContribution`, whose fields are `id`, `titleKey` and `titleDefault` and which has no room for a template. The new entries are offered **last**, after `delete`, so adding actions never moves an existing entry a user's muscle memory has learned.

**Which actions are offered:** those whose `runsOn` contains this pane's side, and which `FileActionTemplate.firstProblem(in:)` reports no problem for. A saved action that has become invalid — the editor refused to save it, but a hand-edited store file can hold one — is **not offered**, rather than offered and failing on click.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/macSCPCoreTests/BrowserContextMenuTests.swift`, inside its existing suite. The real signature, read 2026-10-12, is `entries(for selection: [RemoteFileItem], side: BrowserPaneSide, crossSessionTargets: [CrossSessionTarget] = [], fileActions: [FileActionContribution] = [], supportsChecksum: Bool = false, supportsArchiving: Bool = false, scope: BrowserScope = .ordinary, destination: BrowserScope = .ordinary) -> [BrowserMenuEntry]`. **`fileActions:` is already taken by the BACKEND contributions**, which is why the new parameter is `userFileActions:`. Read the suite's existing helpers and use them — `Self.file` below stands for whatever single-file fixture it already has:

```swift
    // MARK: - User-defined actions (file-actions plan, 2026-10-12)

    @Test func aUserActionIsOfferedOnTheSideItDeclares() {
        let remoteOnly = FileAction(name: "Count", command: "wc -l {{PATH}}", runsOn: [.remote])
        let onRemote = BrowserContextMenu.entries(
            for: [Self.file], side: .remote, userFileActions: [remoteOnly])
        let onLocal = BrowserContextMenu.entries(
            for: [Self.file], side: .local, userFileActions: [remoteOnly])
        #expect(onRemote.contains(.userFileAction(remoteOnly)))
        #expect(onLocal.contains(.userFileAction(remoteOnly)) == false)
    }

    /// A store file can hold an action the editor would have refused. It is
    /// not offered, rather than offered and failing when clicked.
    @Test func anInvalidActionIsNotOffered() {
        let invalid = FileAction(name: "Broken", command: "wc -l '{{PATH}}'", runsOn: [.remote])
        #expect(FileActionTemplate.firstProblem(in: invalid) != nil)
        let entries = BrowserContextMenu.entries(
            for: [Self.file], side: .remote, userFileActions: [invalid])
        #expect(entries.contains(.userFileAction(invalid)) == false)
    }

    /// Offered last, so adding one never moves an entry a user's hand has
    /// learned. The positive beside that: `delete` is still present.
    @Test func userActionsComeAfterEveryBuiltInEntry() {
        let action = FileAction(name: "Count", command: "wc -l {{PATH}}", runsOn: [.remote])
        let entries = BrowserContextMenu.entries(
            for: [Self.file], side: .remote, userFileActions: [action])
        let deleteIndex = entries.firstIndex(of: .delete)
        let actionIndex = entries.firstIndex(of: .userFileAction(action))
        #expect(deleteIndex != nil)
        #expect(actionIndex != nil)
        if let deleteIndex, let actionIndex { #expect(actionIndex > deleteIndex) }
    }

    @Test func noUserActionsLeavesTheMenuExactlyAsItWas() {
        let without = BrowserContextMenu.entries(for: [Self.file], side: .remote)
        let withEmpty = BrowserContextMenu.entries(
            for: [Self.file], side: .remote, userFileActions: [])
        #expect(withEmpty == without)
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter BrowserContextMenu`
Expected: a build failure, and the existing cases in that suite must be the ones that still compile. Quote the red verbatim.

- [ ] **Step 3: Add the case and offer it**

In `Sources/macSCPCore/Presentation/BrowserContextMenu.swift`, after the `backendFileAction` case of `BrowserMenuEntry`:

```swift
    /// An action the USER wrote (file-actions plan, 2026-10-12). Its own
    /// case rather than a `FileActionContribution`: that type carries an
    /// id and a title and has nowhere to put a template, and a backend's
    /// action is a capability of the connection while this one is
    /// something the user authored.
    case userFileAction(FileAction)
```

Give `entries` a new parameter with a default, so every existing caller is unchanged, and append the offered actions at the very end of the built list:

```swift
        // Offered LAST, after `delete`: adding an action must never move an
        // entry a user's hand has learned. Only actions that declare this
        // side and that `FileActionTemplate` finds no problem with — a
        // hand-edited store file can hold one the editor would have refused,
        // and an entry that fails when clicked is worse than one that is
        // absent.
        entries += userFileActions
            .filter { $0.runsOn.contains(side) && FileActionTemplate.firstProblem(in: $0) == nil }
            .map { .userFileAction($0) }
```

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter BrowserContextMenu`
Expected: every existing case plus the four new ones, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Presentation/BrowserContextMenu.swift Tests/macSCPCoreTests/BrowserContextMenuTests.swift
git commit -F - <<'MSG'
feat(actions): offer a user's actions in the file context menu

<< the red from Step 2, pasted as the compiler printed it >>

Its own BrowserMenuEntry case rather than a FileActionContribution: that
type carries an id and a title with nowhere to put a template, and a
backend's action is a capability of the connection where this one is
something the user wrote.

Offered last, after delete, so adding an action never moves an entry a
user's hand has learned -- with a test that pins the order and a positive
beside it that delete is still there. An action the gate finds a problem
with is not offered at all, because a hand-edited store file can hold one
and an entry that fails when clicked is worse than one that is absent.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

### Task 9: the menu dispatch and the confirmation sheet

**Files:**
- Create: `Sources/MacSCPAppKit/BrowserPane+FileActions.swift`
- Create: `Sources/MacSCPAppKit/FileActionConfirmSheet.swift`
- Modify: `Sources/MacSCPAppKit/BrowserPane.swift` (the menu `switch`, around line 317, where `.compressTo` and `.extractArchive` are handled; plus one `@State` and one `.sheet`)
- Modify: `Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
- Test: `Tests/macSCPAppKitTests/FileActionPaneWiringGuardTests.swift`

**Interfaces:**
- Consumes: `BrowserMenuEntry.userFileAction(FileAction)` (Task 8); `FileActionPlanner.plan(action:selection:side:promptedValues:)` and `FileActionPlan` (Task 4).
- Produces: `BrowserPane.beginFileAction(_:selection:)`, the `@State var fileActionRequest: FileActionRequest?`, and `FileActionConfirmSheet`. Task 10 adds the run and consumes `fileActionRequest`.

**Nothing runs in this task.** The sheet is reached, it shows the resolved commands, and its confirm button calls a closure Task 10 fills in. Splitting it this way is deliberate: a reviewer can reject the sheet without rejecting the execution, and the sheet is the surface where a reader checks that server names became what they expected.

Catalogue keys, five: `fileAction.confirm.title`, `fileAction.confirm.message`, `fileAction.confirm.run`, `fileAction.confirm.cancel`, `fileAction.confirm.refused`.

- [ ] **Step 1: Write the failing guard**

Create `Tests/macSCPAppKitTests/FileActionPaneWiringGuardTests.swift`:

```swift
import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit

/// Guards the wiring of the user-defined file actions (file-actions plan,
/// 2026-10-12) where a unit test cannot reach: the pane dispatching the
/// menu entry, the sheet it opens, and — from Task 10 — the rule that a run
/// is owned by the activity rather than by a `Task` nothing owns.
///
/// Structural claims read `SourceCorpus.code` (comments AND string literals
/// blanked), catalogue-key claims read `SourceCorpus.commentFree`.
///
/// Known blind spot: SOURCE TEXT only. That the sheet renders and that the
/// confirm button is reachable by mouse are sight checks, and Task 12
/// assigns them to the maintainer.
@Suite("File action pane wiring guard")
struct FileActionPaneWiringGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func path(_ relative: String) -> URL {
        repoRoot.appendingPathComponent(relative)
    }

    private static func code(_ name: String) throws -> String {
        try SourceCorpus.code(of: path("Sources/MacSCPAppKit/\(name)"))
    }

    private static func literals(_ name: String) throws -> String {
        try SourceCorpus.commentFree(of: path("Sources/MacSCPAppKit/\(name)"))
    }

    private static func catalog(_ locale: String) throws -> [String: String] {
        let data = try Data(
            contentsOf: path("Sources/MacSCPAppKit/Resources/\(locale).lproj/Localizable.strings"))
        return try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    private static let keys = [
        "fileAction.confirm.title",
        "fileAction.confirm.message",
        "fileAction.confirm.run",
        "fileAction.confirm.cancel",
        "fileAction.confirm.refused",
    ]

    @Test func theMenuEntryReachesTheExtensionAndNotAnInlineClosure() throws {
        let pane = try Self.code("BrowserPane.swift")
        #expect(pane.contains("case .userFileAction(let action):"))
        #expect(pane.contains("beginFileAction(action, selection: selection)"))
    }

    @Test func theExtensionBuildsThePlanThroughThePlanner() throws {
        let code = try Self.code("BrowserPane+FileActions.swift")
        #expect(code.contains("FileActionPlanner.plan("))
        #expect(code.contains("fileActionRequest ="))
    }

    @Test func theSheetIsPresentedFromTheRequest() throws {
        let pane = try Self.code("BrowserPane.swift")
        #expect(pane.contains("FileActionConfirmSheet("))
        #expect(pane.contains("$fileActionRequest"))
    }

    @Test func everyConfirmKeyIsInAllFourCatalogues() throws {
        for locale in ["en", "de", "fr", "pl"] {
            let entries = try Self.catalog(locale)
            for key in Self.keys {
                let value = entries[key] ?? ""
                #expect(value.isEmpty == false, "\(locale) has no \(key)")
            }
        }
    }

    @Test func theSheetUsesTheCatalogueKeysAndNoBareStrings() throws {
        let literals = try Self.literals("FileActionConfirmSheet.swift")
        for key in Self.keys {
            #expect(literals.contains("\"\(key)\""), "the sheet does not use \(key)")
        }
    }

    @Test func theGermanConfirmMessageAddressesTheUserAsDu() throws {
        let message = try #require(try Self.catalog("de")["fileAction.confirm.message"])
        #expect(message.contains(" du "))
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter FileActionPaneWiringGuardTests`
Expected: red on every case. Quote the actual failures.

- [ ] **Step 3: Write the request and the dispatch**

Create `Sources/MacSCPAppKit/BrowserPane+FileActions.swift`:

```swift
import SwiftUI
import macSCPCore

/// What the confirmation sheet is about: the action, what it will run, and
/// the selection it was built from.
struct FileActionRequest: Identifiable {
    let id = UUID()
    let action: FileAction
    let selection: [RemoteFileItem]
    let outcome: Result<FileActionPlan, FileActionPlanner.Refusal>
}

extension BrowserPane {
    /// Builds the plan and opens the confirmation sheet. **Nothing runs
    /// here** — the sheet's confirm button is what starts it, and the run
    /// itself is owned by the activity (see `BrowserPane+Archive.swift`'s
    /// own guard and the comment on `FileActionActivity`).
    func beginFileAction(_ action: FileAction, selection: [RemoteFileItem]) {
        fileActionRequest = FileActionRequest(
            action: action, selection: selection,
            outcome: FileActionPlanner.plan(
                action: action, selection: selection, side: side))
    }
}
```

**`side` is `BrowserPane`'s own stored property** — `BrowserPane.swift:16`, `let side: BrowserPaneSide`, and its neighbour's doc comment at `:25` calls it "the single source" for exactly this question. Do **not** derive the side from `supportsArchiving`: that one is a capability ("whether this pane can run the archive actions"), not an identity, and on a remote pane it can be `false` while the pane is still the remote one.

- [ ] **Step 4: Write the sheet**

Create `Sources/MacSCPAppKit/FileActionConfirmSheet.swift`: a sheet taking a `FileActionRequest` and two closures (`onRun`, `onCancel`), showing the action's name as the title, the resolved command lines or invocations one per line in a monospaced, selectable, scrollable list, and a refusal sentence in place of the list when `outcome` is a failure — with the Run button absent in that case. Every string through `L10n.string`. Model the structure on `ExtractDestinationSheet.swift`, which `BrowserPane.swift` presents at around line 480.

- [ ] **Step 5: Wire the pane**

In `Sources/MacSCPAppKit/BrowserPane.swift`: add `@State var fileActionRequest: FileActionRequest?` beside the existing `@State var extractRequest: ExtractRequest?` (line 181); add the case to the menu `switch` beside `.compressTo` / `.extractArchive`:

```swift
                        case .userFileAction(let action):
                            beginFileAction(action, selection: selection)
```

and present the sheet beside the existing `ExtractDestinationSheet` presentation.

- [ ] **Step 6: Add the five strings to all four catalogues**

`en`:

```
"fileAction.confirm.title" = "Run action";
"fileAction.confirm.message" = "This is what will run. The file names come from the server, so read them before you continue.";
"fileAction.confirm.run" = "Run";
"fileAction.confirm.cancel" = "Cancel";
"fileAction.confirm.refused" = "This action cannot run on this selection.";
```

`de` — du-form, and the message must contain `" du "` for the test above:

```
"fileAction.confirm.title" = "Aktion ausführen";
"fileAction.confirm.message" = "Das wird ausgeführt. Die Dateinamen kommen vom Server, also lies sie, bevor du weitermachst.";
"fileAction.confirm.run" = "Ausführen";
"fileAction.confirm.cancel" = "Abbrechen";
"fileAction.confirm.refused" = "Diese Aktion lässt sich auf diese Auswahl nicht anwenden.";
```

`fr`:

```
"fileAction.confirm.title" = "Exécuter l'action";
"fileAction.confirm.message" = "Voici ce qui va être exécuté. Les noms de fichiers viennent du serveur : lisez-les avant de continuer.";
"fileAction.confirm.run" = "Exécuter";
"fileAction.confirm.cancel" = "Annuler";
"fileAction.confirm.refused" = "Cette action ne peut pas s'appliquer à cette sélection.";
```

`pl`:

```
"fileAction.confirm.title" = "Uruchom akcję";
"fileAction.confirm.message" = "Oto, co zostanie uruchomione. Nazwy plików pochodzą z serwera, więc przeczytaj je przed kontynuowaniem.";
"fileAction.confirm.run" = "Uruchom";
"fileAction.confirm.cancel" = "Anuluj";
"fileAction.confirm.refused" = "Tej akcji nie można zastosować do tego wyboru.";
```

- [ ] **Step 7: Run the guard, then the suite**

Run: `swift test --filter FileActionPaneWiringGuardTests`
Expected: 6 tests, 0 failures.

Run: `swift test`
Expected: the only failure is the standing `ViewTestabilitySpike.swift:202`.

- [ ] **Step 8: Commit**

```bash
git add Sources/MacSCPAppKit/BrowserPane+FileActions.swift Sources/MacSCPAppKit/FileActionConfirmSheet.swift Sources/MacSCPAppKit/BrowserPane.swift Sources/MacSCPAppKit/Resources Tests/macSCPAppKitTests/FileActionPaneWiringGuardTests.swift
git commit -F - <<'MSG'
feat(actions): the menu reaches a sheet that shows what will run

<< the red from Step 2, pasted as the run printed it >>

Nothing runs in this commit. The sheet shows the resolved commands and its
confirm button calls a closure the next commit fills in, so the surface
where a reader checks what the server's names became can be reviewed
without reviewing execution.

The confirmation is not optional, and the message says why in four
languages: the file names come from the server.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

### Task 10: the two run paths, owned by an activity

**Files:**
- Create: `Sources/macSCPCore/FileActions/FileActionActivity.swift`
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift` (beside `archiveActivity`, line 76)
- Modify: `Sources/MacSCPAppKit/BrowserPane+FileActions.swift` (the run)
- Modify: `Sources/MacSCPAppKit/BrowserPane.swift` (the activity row, beside `ArchiveActivityRow` at line 253)
- Test: `Tests/macSCPCoreTests/FileActionActivityTests.swift`, and new cases in `Tests/macSCPAppKitTests/FileActionPaneWiringGuardTests.swift`

**Interfaces:**
- Consumes: `FileActionPlan` and `FileActionInvocation` (Task 4); `FileActionRequest` (Task 9).
- Produces: `FileActionActivity` with `run(_:using:)` and `cancel()`, `RemoteBrowserViewModel.fileActionActivity`.

**The rule this task must not break, and it is not a style point.** `ArchivePaneWiringGuardTests.noPreparationRunsInATaskNothingOwns` forbids `BrowserPane+Archive.swift` from holding `Task {`, `Task(`, `Task.detached`, `Task.init`, `Task<`, `Task{`, `DispatchQueue` or `Thread`, and its doc comment gives the measured reason: "An unstructured `Task` here would be owned by nothing: a tab closed while the folder was being read found no operation to cancel, and the run started afterwards on a pane that no longer existed." The same applies here. The work is started **inside `FileActionActivity`**, so the one `cancel()` a tab's teardown calls reaches it. Note the `Task{` spelling with no space: it is legal Swift, the whitespace-collapsed view leaves it as `Task{`, and a check for `"Task {"` alone does not match it — that hole was found by a whole-branch review on 2026-10-09, and this task's guard copies all eight spellings.

**Remote runs by typing, not by executing.** The resolved lines go to the terminal panel through the same path a snippet takes. Core gains no execution entry point for them, which is the whole reason the design could withdraw the predecessor spec's justification. Only the **local** path spawns, and it spawns an argv with no shell.

- [ ] **Step 1: Write the failing tests**

Create `Tests/macSCPCoreTests/FileActionActivityTests.swift` with cases for: an idle activity reports `isRunning == false`; a run over a two-invocation plan reports each in order through an injected runner; `cancel()` during a run ends it without starting the remaining invocations; and a runner that throws ends the activity with a failure rather than leaving it running. Use an injected runner closure — **no real process is spawned in a unit test** — and every wait is an `await`; no `DispatchSemaphore`, no `.wait()`. Give the cancellation case a `.timeLimit(.minutes(1))` hang bound and **no wall-clock ceiling**: assert the ordering and the end state, never how long they took.

Append to `Tests/macSCPAppKitTests/FileActionPaneWiringGuardTests.swift`:

```swift
    /// The same rule `ArchivePaneWiringGuardTests` holds the archive
    /// extension to, and for the same measured reason: a run owned by an
    /// unstructured `Task` survives the pane that started it, and a tab
    /// closed mid-run finds nothing to cancel. All eight spellings, because
    /// a guard that buys one and reveals another is not a guard.
    @Test func noRunHappensInATaskNothingOwns() throws {
        let code = try Self.code("BrowserPane+FileActions.swift")
        #expect(code.contains("viewModel.fileActionActivity.run("))
        #expect(!code.contains("Task {"))
        #expect(!code.contains("Task("))
        #expect(!code.contains("Task.detached"))
        #expect(!code.contains("Task.init"))
        #expect(!code.contains("Task<"))
        #expect(!code.contains("Task{"))
        #expect(!code.contains("DispatchQueue"))
        #expect(!code.contains("Thread"))
    }

    /// A remote action is TYPED into the shell, not executed by Core. The
    /// positive beside the absence: the send path is named.
    @Test func theRemotePathSendsAndDoesNotExecute() throws {
        let code = try Self.code("BrowserPane+FileActions.swift")
        #expect(code.contains("SnippetSendPlanner.plan("))
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter FileActionActivity` and `swift test --filter FileActionPaneWiringGuardTests`
Expected: red. Quote both verbatim.

- [ ] **Step 3: Write the activity, then the two paths**

`FileActionActivity` mirrors `ArchiveActivity`'s shape — read that file — with a `State` of idle/running/ended, an `Ending` carrying success or a failure, `isRunning`, a `title`, `run(_ plan: FileActionPlan, using runner: ...)` that owns its own work, and `cancel()`. In `RemoteBrowserViewModel`, beside line 76:

```swift
    public let fileActionActivity = FileActionActivity()
```

In `BrowserPane+FileActions.swift`, the confirm closure calls `viewModel.fileActionActivity.run(...)` for the local path and the send path for the remote one. In `BrowserPane.swift`, add the activity row beside `ArchiveActivityRow(activity: viewModel.archiveActivity)`.

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter FileActionActivity` then `swift test --filter FileActionPaneWiringGuardTests` then `swift test`
Expected: 0 failures beyond the standing `ViewTestabilitySpike.swift:202`.

- [ ] **Step 5: Prove the no-Task guard is sensitive**

```bash
cat > "$TMPDIR/plant-unowned-task.py" <<'PY'
import io
p = 'Sources/MacSCPAppKit/BrowserPane+FileActions.swift'
s = io.open(p, encoding='utf-8').read()
old = '    func beginFileAction('
assert s.count(old) == 1, 'anchor not unique: %d' % s.count(old)
s = s.replace(old, '    func plantedUnownedRun() { Task{ } }\n\n' + old)
io.open(p, 'w', encoding='utf-8').write(s)
PY
scripts/mutation-probe --filter FileActionPaneWiringGuardTests --apply "python3 -I $TMPDIR/plant-unowned-task.py"
rm -f "$TMPDIR/plant-unowned-task.py"
```

Expected: RED on `noRunHappensInATaskNothingOwns`. The plant deliberately uses the no-space `Task{` spelling, which is the one a review found a guard missing on 2026-10-09. `BUILD FAILED`, `PLANT FAILED` and `PLANT CHANGED` are each their own outcome and none is a pass. Record it verbatim.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore/FileActions/FileActionActivity.swift Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift Sources/MacSCPAppKit/BrowserPane+FileActions.swift Sources/MacSCPAppKit/BrowserPane.swift Tests/macSCPCoreTests/FileActionActivityTests.swift Tests/macSCPAppKitTests/FileActionPaneWiringGuardTests.swift
git commit -F - <<'MSG'
feat(actions): run an action, owned by an activity rather than by a Task

<< the reds from Step 2, pasted as the runs printed them >>

The run lives inside FileActionActivity, so the one cancel() a tab's
teardown calls reaches it. The archive extension is held to the same rule
for a measured reason: a run owned by an unstructured Task survives the
pane that started it, and a tab closed mid-run found nothing to cancel.
The guard copies all eight spellings, including the no-space Task{ that a
whole-branch review found a sibling guard missing.

A remote action is typed into the user's shell through the snippet send
path. Core gains no execution entry point, which is what let this design
withdraw the predecessor spec's reason for deferring the builder. Only the
local path spawns, and it spawns an argv with no shell.

<< the mutation-probe outcome from Step 5, with the command >>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

### Task 11: the editor

**Files:**
- Create: `Sources/MacSCPAppKit/FileActionsSheet.swift`
- Create: `Sources/MacSCPAppKit/FileActionEditor.swift`
- Modify: `Sources/MacSCPAppKit/MacSCPCommands.swift` (a menu item beside "Manage Snippets…", around line 270)
- Modify: `Sources/MacSCPAppKit/MacSCPApp.swift` (the bridge, around line 159) and `Sources/MacSCPAppKit/ContentView+Sheets.swift` (the route, around line 563)
- Modify: `Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
- Test: `Tests/macSCPAppKitTests/FileActionEditorWiringGuardTests.swift`

**Interfaces:**
- Consumes: `FileAction`, `FileActionPerSelection` (Task 1); `FileActionTemplate.firstProblem(in:)` and `.Problem` (Task 2); `FileActionStore` (Task 6); `FileActionExportCodec` (Task 7); `SnippetDryRun.describing(command:variables:skipsPlacementCheck:values:execute:bracketedPaste:)` (Task 5).
- Produces: nothing a later task consumes. Task 12 documents it.

**What the editor is, concretely.** `SnippetsSheet.swift` and `SnippetCommandEditor.swift` are the shape to follow — read both. The actions sheet lists the stored actions in store order with add, edit, duplicate, remove, and import/export through `FileActionExportCodec`. The editor carries: the name; the command, in `SnippetCommandEditor` (it already highlights shell syntax); the selection form as a two-way picker; the two sides as toggles; and the declared variables, reusing whatever `SnippetCommandEditor`'s own variable list uses.

**The editor's one job beyond data entry is to refuse, legibly.** `FileActionTemplate.firstProblem(in:)` is evaluated as the author types and its result is shown as a sentence, with Save disabled while there is one. Every `Problem` case needs its own sentence — six of them, and each must say what to do, not only what is wrong:

| Case | What the sentence must convey |
|---|---|
| `declaration` | which placeholder sits where it may not, and that a placeholder must be a plain unquoted argument |
| `reservedVariableName` | that the name is one the selection supplies, so it cannot also be asked for |
| `environmentPlacementIsNotRunnableLocally` | that an environment variable needs a shell, and this action also runs locally where there is none |
| `notOneSimpleCommandForLocal` | that a local action is one command with no pipe and no redirection |
| `noSideDeclared` | that an action has to run somewhere |
| `reservedNameDoesNotFitTheForm` | which name fits which form, naming the other one — `{{PATH}}` for once per file, `{{PATHS}}` for once for the whole selection |

The six catalogue keys for those sentences, so they are not improvised one per locale: `fileAction.problem.declaration`, `fileAction.problem.reservedName`, `fileAction.problem.environmentLocal`, `fileAction.problem.notOneCommand`, `fileAction.problem.noSide`, `fileAction.problem.formMismatch`.

**Count the catalogue keys as you add them and put the number in the guard**, rather than writing a figure from this table: the table is a plan and the catalogue is the tree.

- [ ] **Step 1: Write the failing guard**

Create `Tests/macSCPAppKitTests/FileActionEditorWiringGuardTests.swift`, modelled on `FileActionPaneWiringGuardTests` (Task 9) and on `TerminalMouseWiringGuardTests`'s catalogue cases. It asserts, all positively: the editor evaluates `FileActionTemplate.firstProblem(` ; it binds a picker to `perSelection` and toggles to `runsOn`; the sheet calls `FileActionStore` for its list and its saves and `FileActionExportCodec` for import and export; **every key the editor uses is present and non-empty in all four catalogues**; the German strings contain `" du "` in at least the explanatory sentences; and the editor's dry-run preview reaches `SnippetDryRun.describing(command:` — the piece-taking overload, not the `Snippet` one, which it has no `Snippet` to pass.

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter FileActionEditorWiringGuardTests`
Expected: red on every case. Quote the actual failures.

- [ ] **Step 3: Build the sheet and the editor; add every string to all four catalogues**

Follow `SnippetsSheet.swift` and `SnippetCommandEditor.swift`. Every display string through `L10n.string`. The German catalogue addresses the user as **du**.

- [ ] **Step 4: Add the menu item**

"Manage File Actions…" beside "Manage Snippets…", through the same bridge shape — `MacSCPCommands.swift` for the item, `MacSCPApp.swift` for the bridge, `ContentView+Sheets.swift` for the route. The snippets item "stays enabled" without a connection (that file says so around line 270); an actions item has the same property, because writing an action needs no server.

- [ ] **Step 5: Run the guard, then the suite**

Run: `swift test --filter FileActionEditorWiringGuardTests` then `swift test`
Expected: 0 failures beyond the standing `ViewTestabilitySpike.swift:202`.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacSCPAppKit Tests/macSCPAppKitTests/FileActionEditorWiringGuardTests.swift
git commit -F - <<'MSG'
feat(actions): write, store, import and export your own file actions

<< the red from Step 2, pasted as the run printed it >>

The editor's job beyond data entry is to refuse legibly: every one of the
gate's six problems has its own sentence, in four languages, and each says
what to do rather than only what is wrong. Save is disabled while a
problem stands, so an action that cannot run cannot be saved -- which is
what lets the context menu treat a stored-but-invalid action as a
hand-edited file rather than as a case the editor produces.

Reachable without a connection, like Manage Snippets: writing an action
needs no server.

<< the catalogue-key count, with the command that produced it >>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

### Task 12: closeout — the record, the docs, and the maintainer's steps

**Files:**
- Modify: `docs/BACKLOG.md` (the row opening "Custom actions in the file context menu")
- Modify (noix-docs worktree): `src/content/docs/macscp/guide/`, `src/content/docs/macscp/reference/changelog.md`

**Interfaces:** consumes everything above; produces nothing code reads.

- [ ] **Step 1: Correct the backlog row in place**

Find it by content, never by number — a row added above it moves it:

```bash
/usr/bin/grep -n 'Custom actions in the file context menu' docs/BACKLOG.md
```

That row was corrected on 2026-10-09 to read, verbatim, "**Partly done 2026-10-09: the archive half is done, the user-defined-action builder is not started.**" **That sentence is now false and must be withdrawn with its wording quoted**, and replaced by the closure of both halves with this plan's commits named. Check the rest of the row for further clauses the builder overtook — the 2026-10-09 pass found a third falsified claim the brief had not named, so read every clause rather than only the opening.

The cell takes **no pipe character at all**. A figure in it travels with the command that produced it, using several `-e` patterns rather than one `-E` alternation. Re-run every command after writing the sentence that quotes it.

- [ ] **Step 2: Check the row's shape**

```bash
awk -F'|' '/Custom actions in the file context menu/ {print NF}' docs/BACKLOG.md
```

Expected: the same field count as a neighbour row, checked with the same command. A different number means a pipe got in.

- [ ] **Step 3: Correct the predecessor spec's cross-reference**

`docs/superpowers/specs/2026-10-06-archive-actions-design.md` says the builder "can sit on the seam this design builds". It did not sit on that seam — it sat on the snippet subsystem's. Quote the clause and say where the builder actually went, so a reader following the pointer is not sent to the wrong subsystem.

- [ ] **Step 4: The user documentation**

In a **new worktree** of `/Users/noidee/_dev/noix-docs` on its own branch off `origin/main` — the main checkout is on someone else's branch, and that repository is shared with other products and sessions. A new page under `src/content/docs/macscp/guide/` for file actions, marked unreleased in whatever spelling that repository uses **at the time you look** (two spellings were in flight on 2026-10-12: italic one-liners on `origin/main` and a `:::note` aside on two unmerged branches — check, and say in the report which you found and chose). One row in the `## Unreleased` table of `reference/changelog.md`.

No tech-stack terms: do not name the snippet subsystem, the survey, any type, or Swift. Say what the app does. Do say the two things a user must understand to use this safely: that the file names come from the server and the confirmation sheet is where they read them, and that an action declares which pane it works on.

Then, in that worktree: `npm install && npm run build && npm run check`. Both must pass. Commit on that branch. **Do not push and do not merge.**

- [ ] **Step 5: The maintainer's steps — NOT yours**

**Do not mark this step done, do not launch the app, and do not claim any of it was verified.** Write it into the report as outstanding, addressed to the maintainer:

1. Write an action `wc -l {{PATH}}`, once per file, remote only. Run it on one file. The line should appear in the terminal and run.
2. Create a file on the server whose name holds a space and a single quote. Run the same action on it. The quoting should hold and the command should succeed.
3. Write `zip -r out.zip {{PATHS}}`, once for the whole selection, and run it on three files. One command, three quoted paths.
4. Write `gzip -k {{PATH}}`, local only, and run it on a local file. The result surface should show it.
5. Switch that action's form to "once for the whole selection" and confirm the editor refuses `{{PATH}}` and names `{{PATHS}}`.
6. Confirm the sheet appears every time, and that cancelling it runs nothing.

Step 2 and step 6 are the two that matter most: the first is the trust boundary this whole subsystem exists for, and the second is the only thing standing between a server-chosen name and a command the user did not read.

- [ ] **Step 6: Report**

Written from the diff, not from the intent. State every withdrawal with the wording it replaced, the field-count check, the `npm` results with their commands, which unreleased-marker spelling you found and chose, and that Step 5 is outstanding and belongs to the maintainer.
