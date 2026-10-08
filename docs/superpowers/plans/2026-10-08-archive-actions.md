# Archive Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compress and extract archives from the file context menu, on the
remote pane and the local one.

**Architecture:** A pure Core function turns an operation plus a selection
into an `ArchivePlan` — a tool name, a list of words each marked as our own
flag or as a user-controlled operand, and optional stdin bytes. Two renderings
read that plan: a local one handing argv straight to `SubprocessRunner` (no
shell at all) and a remote one producing an `ArchiveCommandLine` whose operands
pass through `PosixQuoting.singleQuoted`. Two runners execute it; the menu, a
destination dialog and a per-pane progress model sit above.

**Tech Stack:** Swift 6, SwiftPM, Swift Testing, Citadel (`withExec`),
`SubprocessRunner`, AppKit menus.

**Spec:** `docs/superpowers/specs/2026-10-06-archive-actions-design.md`
(committed `7157557b`, corrected `2bd2eac3` — read the corrections, they
withdraw two prescriptions the first draft made).

## Global Constraints

- Swift 6 strict, every target `.swiftLanguageMode(.v6)`, minimum macOS 15.
- Swift Testing (`@Test`/`#expect`), TDD: red before green, and the red is
  observed and quoted in the commit message, never invented.
- `swift test` with **no `--build-system` flag**. A failure on SwiftTerm's
  `Shaders.metal` saying `cannot execute tool 'metal' due to missing Metal
  Toolchain` means one `xcodebuild -downloadComponent MetalToolchain`, not a
  flag.
- Rig suites are gated behind `MACSCP_ITEST=1`, and the Docker rig is started
  **only from the main checkout**:
  `docker compose -f docker/test-server/compose.yml up -d`.
- **Tests never block the cooperative pool**: no `syncShutdownGracefully()`,
  no `futureResult.wait()`, no `DispatchSemaphore.wait()`. Every wait is an
  `await`.
- **No wall-clock ceiling in a test.** A floor (`elapsed >= …`) is fine; an
  upper bound on elapsed time measures the runner and will go red on CI.
  Hang bounds are `.timeLimit(…)`.
- A negative source-scanning check needs a positive check beside it.
- No secret reaches a store, a state, a log line, a `reason:` string, a
  notification, a report, a `docs/` row, or a test failure message.
- Never hardcode a display string: `L10n.string(_:_:)` in the App,
  `CoreL10n.string(_:)` in Core. Catalogs in **en, de, fr, pl**; the German
  catalogs address the user as **du**.
- Every written artifact is English: code, comments, test names, `docs/`,
  commit messages, branch names.
- Conventional Commits. Footer on every commit:
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`
- Commit per task; **never push** — the coordinator pushes on request.
- Do **not** launch the GUI or the app binary. Never send a secret through
  the CLI.
- User documentation ships with the feature (Task 8).

## Maintainer decisions this plan must honour

1. **Both panes**, remote and local.
2. A **"Compress" submenu** over `.zip`, `.tar.gz`, and `.gz` for a single
   file, beside an **extension-detecting extract** action
   (`.zip`, `.tar.gz`, `.tgz`, `.tar`, `.gz`). **No in-place gzip** that
   replaces its input.
3. A **lightweight per-pane progress model**, not the byte-shaped transfer
   queue (`Sources/macSCPCore/Presentation/TransferQueueViewModel.swift:85`).
4. Names reach the remote tool **through stdin**; only the archive name is
   quoted. A selection holding a name with a **newline refuses `.zip`**.
   `.gz` uses **`gzip -k`**.
5. **Extraction asks in a dialog** (2026-10-08): this folder, or a new
   subfolder. This supersedes the earlier wording "Extract Here" — a menu
   item that opens a dialog carries an ellipsis on macOS, so the title is
   "Extract…". The decision's substance is unchanged; only the title is.

## The stdin blocker, and the two decisions it forced (2026-10-08)

Task 4 came back **BLOCKED**, and the block is real. Both claims below were
measured by the implementer and then re-measured by the controller.

**Citadel 0.12.1-noix.3 cannot signal end-of-input on an exec channel.**
`TTYStdinWriter` (`.build/checkouts/Citadel/Sources/Citadel/TTY/Client/TTY.swift:75`)
has exactly two public methods, `write` and `changeSize`; its `channel` is
`internal`. Every `eof` in that file is INBOUND — the far side's EOF reaching
us. And `withExec` closes the channel only AFTER its closure returns, while
the closure cannot return until it has drained `inbound`, which for a
stdin-reading tool never ends. Observed: the rig case ran to its
`.timeLimit`, "Time limit was exceeded: 300.000 seconds", while the same
pipeline run inside the container exited 0 at once.

**The rig cannot exercise these tools either.** Measured in the `sshd`
container: `zip` **ABSENT**, `tar` is BusyBox 1.37.0 and rejects `--null`
("unrecognized option: null", exit 1). Only `unzip`, `gzip` and `gunzip` are
present.

A third thing the implementer found while blocked, and worth its own test
once unblocked: a tool that exits before reading stdin surfaces as
`ChannelError.alreadyClosed` rather than as its exit status, because
`withExec`'s catch block calls `close()` before rethrowing and that throws on
an already-closed channel — which would also hide exit 127 from
`isToolMissing`.

**Maintainer's rulings, 2026-10-08.** A list-file-over-SFTP route was measured
working and offered (`tar --null -T <ourfile>`, `zip -@ < <ourfile>`, both
handling a name with an apostrophe, no user-controlled byte on the command
line) and was NOT taken. Instead:

1. **Extend the Citadel fork** with a public stdin half-close, and fix the
   close-masks-the-error case. This is **Task 10**, below, and it runs BEFORE
   Task 4.
2. **Add the archive tools to the rig image.** This is **Task 11**, below, and
   it also runs before Task 4.

So the execution order is **1, 2, 3, 11, 10, 4, 5, 6, 7, 8, 9** — the two new
tasks are numbered at the end only so that every existing cross-reference in
this plan keeps pointing at the task it means. Task 4's brief is unchanged
except that its conformance may now call the half-close Task 10 adds.

Task 4's blocked attempt is not lost: the conformance diff, the protocol file
and the test file are saved under
`.superpowers/sdd/2026-10-08-archive-actions/task-4-attempt/`, and the patch
was verified to apply cleanly against a clean tree.

## What was measured, so no task re-derives it

All on 2026-10-08, on this machine, each command run in the form written here.

- `zip -q -r -@ out.zip` with `d` and `top file` on stdin **recurses**:
  the archive held `d/`, `d/a`, `d/sub/b'c`, `top file`.
- `printf "d\0top file\0" | tar --null -T - -czf out.tar.gz` produced the
  same five entries, so a name holding an apostrophe needs no quoting on
  either stdin path.
- `zip -h2` documents `-@` as "read names to zip from stdin (one path per
  line)" — newline-separated, no NUL option. `tar --null` is NUL-separated.
  This is the whole reason decision 4's newline refusal exists, and it
  applies to `.zip` only.
- `gzip -k -- f` with `f.gz` already present printed
  `gzip: f.gz already exists -- skipping`, **exited 1, and left `f.gz`
  unchanged**. gzip does not clobber on its own.
- **Both skip-existing flags are silent.** `unzip -n` kept the old `a`,
  extracted `b`, exited **0**, and its non-quiet output named only what it
  *extracted* ("extracting: b") — never what it skipped.
  `tar --keep-old-files -xzf` (bsdtar) likewise kept the old `a`, extracted
  `b`, exited **0**, and printed nothing at all. **So a count of skipped
  entries cannot be read from either tool's output.** Task 6 gets that count
  from a listing instead; do not try to parse it from the run.
- Listing commands: `unzip -Z1 <archive>` and `tar -tzf <archive>` each print
  one entry per line.

## File structure

**Create** (Core, new directory `Sources/macSCPCore/Archive/`):

| File | Responsibility |
|---|---|
| `ArchiveFormat.swift` | `ArchiveFormat`, `ArchiveExtractFormat`, `ArchiveOperation`, `ExtractDestination`, `ArchiveRefusal` — closed enumerations and the refusal reasons. |
| `ArchivePlan.swift` | `ArchiveWord`, `ArchivePlan`, `ArchivePlan.compress(…)`, `ArchivePlan.extract(…)`, and the **local** rendering. |
| `ArchiveCommandLine.swift` | `ArchiveCommandLine` (`fileprivate init`) and the **remote** rendering. The only file that can phrase a remote archive command. |
| `ArchiveCommandChannel.swift` | The capability seam and `ArchiveCommandExitFailure`. |
| `ArchiveNaming.swift` | The name an archive is offered, and keeping it off an existing one. |
| `ArchiveRunner.swift` | `ArchiveRunner`, `ArchiveOutcome`, `ArchiveFailure`, `ArchiveBudget`, `RemoteArchiveRunner`, `LocalArchiveRunner`. |
| `ExtractPreview.swift` | What the extract dialog needs before anything runs, and the listing plan. |
| `ArchiveActivity.swift` | The per-pane model: one operation, its state, its cancel. |

**Modify:**

| File | Change |
|---|---|
| `Sources/macSCPCore/SSH/CitadelFileSystem.swift` | conform to `ArchiveCommandChannel` beside the existing `ChecksumCommandChannel` conformance (`:1631`). |
| `Sources/macSCPCore/Presentation/BrowserContextMenu.swift` | new `BrowserMenuEntry` cases and the gate. |
| `Sources/MacSCPAppKit/RemoteFileTableView.swift` | render the entries; fold the compress run into one submenu, as `makeTransferItem` already does (`:1111`–`:1147`). |
| `Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings` | the new titles. |
| `docs/BACKLOG.md` | the closing row. |

## Interfaces at a glance

Every task's `Produces` block repeats what the next one needs; this table is
the single place to check a name against.

```swift
public enum ArchiveFormat: String, Sendable, CaseIterable, Equatable { case zip, tarGz, gz }
public enum ArchiveExtractFormat: Sendable, CaseIterable, Equatable { case zip, tar, tarGz, gz }
public enum ArchiveOperation: Sendable, Equatable {
    case compress(ArchiveFormat), extract(ArchiveExtractFormat)
}
public enum ExtractDestination: Sendable, Equatable { case thisFolder, subfolder(String) }
public enum ArchiveWord: Sendable, Equatable { case flag(String), operand(String) }
public struct ArchivePlan: Sendable, Equatable {
    public let operation: ArchiveOperation
    public let workingDirectory: String
    public let tool: String
    public let words: [ArchiveWord]
    public let stdin: Data?
}
public struct ArchiveCommandLine: Sendable, Equatable { public let text: String }
protocol ArchiveCommandChannel: Sendable {
    func run(_ line: ArchiveCommandLine, stdin: Data?) async throws -> Int
    func listing(of line: ArchiveCommandLine, limit: Int) async throws -> [String]
}
```

Write the protocol with **both** requirements in Task 4, even though only
Task 7 calls the second: adding a requirement later means editing every fake
in two finished test files, and a reviewer cannot tell a deliberate extension
from a forgotten one.

---

### Task 1: The formats, the refusals, and the proposed name

**Files:**
- Create: `Sources/macSCPCore/Archive/ArchiveFormat.swift`
- Create: `Sources/macSCPCore/Archive/ArchiveNaming.swift`
- Test: `Tests/macSCPCoreTests/ArchiveFormatTests.swift`

**Interfaces:**
- Consumes: `RemoteFileItem` (`Sources/macSCPCore/RemoteFS/RemoteFileItem.swift`
  — `name: String`, `path: String`, `kind: RemoteFileKind`, and
  `isBucket: Bool`).
- Produces: `ArchiveFormat`, `ArchiveExtractFormat`, `ArchiveOperation`,
  `ExtractDestination`, `ArchiveRefusal`, `ArchiveNaming.proposedName(…)`,
  `ArchiveNaming.free(_:takenNames:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import macSCPCore

@Suite(.timeLimit(.minutes(1)))
struct ArchiveFormatTests {
    private func file(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/d/" + name, kind: .file)
    }
    private func folder(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/d/" + name, kind: .directory)
    }

    @Test func eachCompressionFormatNamesItsOwnExtension() {
        #expect(ArchiveFormat.zip.fileExtension == "zip")
        #expect(ArchiveFormat.tarGz.fileExtension == "tar.gz")
        #expect(ArchiveFormat.gz.fileExtension == "gz")
    }

    @Test(arguments: [
        ("a.zip", ArchiveExtractFormat.zip),
        ("a.ZIP", ArchiveExtractFormat.zip),
        ("a.tar.gz", ArchiveExtractFormat.tarGz),
        ("a.tgz", ArchiveExtractFormat.tarGz),
        ("a.tar", ArchiveExtractFormat.tar),
        ("a.gz", ArchiveExtractFormat.gz),
    ])
    func anExtensionNamesTheExtractionFormat(name: String, expected: ArchiveExtractFormat) {
        #expect(ArchiveExtractFormat.detected(inName: name) == expected)
    }

    /// `.tar.gz` must win over `.gz`, or every tarball extracts as one
    /// gzipped file. The order of the checks is the whole content of this
    /// case, so it is pinned separately from the table above.
    @Test func tarGzIsNotReadAsGz() {
        #expect(ArchiveExtractFormat.detected(inName: "backup.tar.gz") == .tarGz)
        #expect(ArchiveExtractFormat.detected(inName: "backup.gz") == .gz)
    }

    @Test(arguments: ["a", "a.txt", "a.tar.bz2", "", ".gz "])
    func aNameThatClaimsNoKnownFormatIsNotDetected(name: String) {
        #expect(ArchiveExtractFormat.detected(inName: name) == nil)
    }

    @Test func oneFolderLendsItsNameToTheArchive() throws {
        let name = try ArchiveNaming.proposedName(format: .zip, selection: [folder("project")])
        #expect(name == "project.zip")
    }

    @Test func oneFileKeepsItsWholeNameIncludingItsExtension() throws {
        let name = try ArchiveNaming.proposedName(format: .tarGz, selection: [file("notes.txt")])
        #expect(name == "notes.txt.tar.gz")
    }

    /// Several objects have no shared name to inherit, so the archive gets a
    /// fixed one from Core's catalogue rather than the first row's name,
    /// which would read as if only that row were in it.
    ///
    /// Asserted against the CATALOGUE's answer, not against a literal, and
    /// with a positive beside it that the answer is not the fallback.
    /// `CoreL10n.string(_:)` is
    /// `bundle.localizedString(forKey: key, value: key, table: nil)`
    /// (`Sources/macSCPCore/L10n/CoreL10n.swift:61`-`:62`), so a MISSING key
    /// comes back as the key itself. This case first read
    /// `#expect(name.hasSuffix(".zip"))` with `#expect(name != "a.zip")` and
    /// `#expect(name != "b.zip")` — withdrawn, because the fallback string
    /// satisfies all three and the case passed whether or not the catalogue
    /// held the key. Task 1's implementer found that, not a reviewer.
    @Test func severalObjectsGetTheCatalogueName() throws {
        let fallbackIsNotWhatWeGot = CoreL10n.string("core.archive.defaultName")
            != "core.archive.defaultName"
        #expect(fallbackIsNotWhatWeGot)
        let name = try ArchiveNaming.proposedName(
            format: .zip, selection: [file("a"), folder("b")])
        #expect(name == CoreL10n.string("core.archive.defaultName") + ".zip")
    }

    @Test func gzRefusesMoreThanOneObject() {
        #expect(throws: ArchiveRefusal.gzTakesExactlyOneFile(count: 2)) {
            try ArchiveNaming.proposedName(format: .gz, selection: [file("a"), file("b")])
        }
    }

    @Test func gzRefusesAFolder() {
        #expect(throws: ArchiveRefusal.gzTakesAFileNotAFolder(name: "d")) {
            try ArchiveNaming.proposedName(format: .gz, selection: [folder("d")])
        }
    }

    @Test func anEmptySelectionIsRefused() {
        #expect(throws: ArchiveRefusal.emptySelection) {
            try ArchiveNaming.proposedName(format: .zip, selection: [])
        }
    }

    @Test func afreeNameIsTheProposedOneWhenNothingIsTaken() {
        #expect(ArchiveNaming.free("a.zip", takenNames: ["b.zip"]) == "a.zip")
    }

    /// The counter goes before the whole extension, not before the last dot,
    /// or `a.tar.gz` becomes `a.tar 2.gz` and stops being a tarball.
    @Test func afreeNameCountsUpBeforeTheWholeExtension() {
        #expect(ArchiveNaming.free("a.tar.gz", takenNames: ["a.tar.gz"]) == "a 2.tar.gz")
        #expect(
            ArchiveNaming.free("a.tar.gz", takenNames: ["a.tar.gz", "a 2.tar.gz"])
                == "a 3.tar.gz")
    }

    @Test func afreeNameWithoutAnExtensionCountsAtItsEnd() {
        #expect(ArchiveNaming.free("folder", takenNames: ["folder"]) == "folder 2")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ArchiveFormatTests`
Expected: FAIL — `cannot find 'ArchiveFormat' in scope` and the same for every
other new name. Quote the first such line in the commit message.

- [ ] **Step 3: Write `ArchiveFormat.swift`**

```swift
import Foundation

/// A format macSCP can CREATE. Deliberately smaller than what it can
/// extract: `.tar` is extractable and is not offered for compression,
/// because an uncompressed tarball is not what anyone picks from a menu
/// called "Compress".
public enum ArchiveFormat: String, Sendable, CaseIterable, Equatable {
    case zip, tarGz, gz

    /// The extension an archive of this format carries, without the dot.
    public var fileExtension: String {
        switch self {
        case .zip: "zip"
        case .tarGz: "tar.gz"
        case .gz: "gz"
        }
    }
}

/// A format macSCP can EXTRACT, read off a name's extension.
public enum ArchiveExtractFormat: Sendable, CaseIterable, Equatable {
    case zip, tar, tarGz, gz

    /// The format `name` claims by its extension, or `nil`.
    ///
    /// The order matters and is pinned by `tarGzIsNotReadAsGz`: `.tar.gz`
    /// and `.tgz` are tested BEFORE `.gz`, because every `.tar.gz` also
    /// ends in `.gz` and reading it as a single gzipped file would extract
    /// a tarball nobody asked for.
    ///
    /// Lower-cased for the comparison only: a server may hold `BACKUP.ZIP`,
    /// and the name itself is never rewritten.
    public static func detected(inName name: String) -> ArchiveExtractFormat? {
        let lower = name.lowercased()
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { return .tarGz }
        if lower.hasSuffix(".zip") { return .zip }
        if lower.hasSuffix(".tar") { return .tar }
        if lower.hasSuffix(".gz") { return .gz }
        return nil
    }
}

/// Which operation a plan carries out.
public enum ArchiveOperation: Sendable, Equatable {
    case compress(ArchiveFormat)
    case extract(ArchiveExtractFormat)
}

/// Where an extraction puts what it unpacks. The maintainer's decision of
/// 2026-10-08: the user is asked, so this is a value the dialog produces
/// and never a default a plan picks for itself.
public enum ExtractDestination: Sendable, Equatable {
    /// The directory the archive sits in.
    case thisFolder
    /// A new subfolder of it, by this name. The name is already free —
    /// `ArchiveNaming.free(_:takenNames:)` chose it.
    case subfolder(String)
}

/// Why a plan could not be made. Every case names what the user would have
/// to change, because each one is shown to them.
public enum ArchiveRefusal: Error, Equatable, Sendable {
    case emptySelection
    case gzTakesExactlyOneFile(count: Int)
    case gzTakesAFileNotAFolder(name: String)
    /// `zip -@` reads ONE PATH PER LINE from stdin (`zip -h2`, measured
    /// 2026-10-08) and Info-ZIP offers no NUL-separated alternative, so a
    /// name holding a newline cannot be handed to it safely. `.tar.gz` and
    /// `.gz` are unaffected — `tar --null -T -` is NUL-separated.
    case newlineInNameUnsupportedByZip(name: String)
    /// The selected row's name claims no format this build can extract.
    case unknownArchiveFormat(name: String)
    /// `gunzip` writes its one file beside the archive and cannot be told a
    /// destination directory without a shell redirection this design does
    /// not build, so that format extracts into the archive's own folder or
    /// not at all. Enforced here as well as in the sheet, because a rule
    /// that lives only in a dialog is a rule the next caller skips.
    case gzExtractsIntoThisFolderOnly
    /// `gzip -k` refuses an existing target itself and leaves it untouched
    /// (measured 2026-10-08: `gzip: f.gz already exists -- skipping`, exit
    /// 1, target unchanged). macSCP says so before running rather than
    /// surfacing that line.
    case gzTargetExists(name: String)
}
```

- [ ] **Step 4: Write `ArchiveNaming.swift`**

```swift
import Foundation

/// Choosing the name an archive gets, and keeping it off an existing one.
///
/// Pure, and separate from `ArchivePlan` on purpose: the name is what the
/// dialog shows the user BEFORE anything runs, so it has to be computable
/// without a channel, a process, or a directory listing beyond the names
/// the pane already holds.
public enum ArchiveNaming {
    /// The name to propose for an archive of `format` over `selection`.
    ///
    /// One object lends its WHOLE name, extension included: compressing
    /// `notes.txt` gives `notes.txt.tar.gz`, not `notes.tar.gz`, because the
    /// second loses which file came back out.
    public static func proposedName(
        format: ArchiveFormat, selection: [RemoteFileItem]
    ) throws -> String {
        guard let first = selection.first else { throw ArchiveRefusal.emptySelection }
        if format == .gz {
            guard selection.count == 1 else {
                throw ArchiveRefusal.gzTakesExactlyOneFile(count: selection.count)
            }
            guard first.kind == .file else {
                throw ArchiveRefusal.gzTakesAFileNotAFolder(name: first.name)
            }
        }
        let stem = selection.count == 1
            ? first.name
            : CoreL10n.string("core.archive.defaultName")
        return stem + "." + format.fileExtension
    }

    /// `proposed`, or the first name beside it that `takenNames` does not
    /// hold.
    ///
    /// The counter goes before the WHOLE extension — `a 2.tar.gz`, never
    /// `a.tar 2.gz` — which is why this splits on the known archive
    /// extensions rather than on the last dot.
    public static func free(_ proposed: String, takenNames: Set<String>) -> String {
        guard takenNames.contains(proposed) else { return proposed }
        let (stem, ext) = split(proposed)
        var counter = 2
        while true {
            let candidate = "\(stem) \(counter)\(ext)"
            if !takenNames.contains(candidate) { return candidate }
            counter += 1
        }
    }

    /// `name` as (stem, extension-with-its-dot). The extension is one of the
    /// known archive extensions or empty; an unknown trailing component is
    /// left in the stem, so a folder called `report.2026` counts up as
    /// `report.2026 2`.
    private static func split(_ name: String) -> (String, String) {
        let known = ["tar.gz", "tgz", "tar", "zip", "gz"]
        let lower = name.lowercased()
        for ext in known where lower.hasSuffix("." + ext) {
            let cut = name.index(name.endIndex, offsetBy: -(ext.count + 1))
            return (String(name[name.startIndex..<cut]), String(name[cut...]))
        }
        return (name, "")
    }
}
```

- [ ] **Step 5: Add the one Core catalogue key, in four languages**

`Sources/macSCPCore/Resources/en.lproj/Localizable.strings`:
```
"core.archive.defaultName" = "Archive";
```
`de.lproj`: `"core.archive.defaultName" = "Archiv";`
`fr.lproj`: `"core.archive.defaultName" = "Archive";`
`pl.lproj`: `"core.archive.defaultName" = "Archiwum";`

**Corrected after Task 1's first round.** This step first wrote the key as
`"archive.defaultName"`, with no prefix. Withdrawn: every other key in Core's
catalogue carries one. Measured 2026-10-08 —

```
grep -o '^"[a-z][a-zA-Z]*\.' Sources/macSCPCore/Resources/en.lproj/Localizable.strings | sort | uniq -c
```

printed `122 "core.` against `1 "archive.`, out of 123 keys, and that single
exception was the one this task had just added. Core prefixes everything
`core.`; the App catalogue, by contrast, is organised by FEATURE
(`settings.` 181 keys, `diagnostics.` 116, `menu.` 38, out of 1277), which is
why Task 6's `menu.*` and Task 7's new `archive.*` family are right as they
stand and are NOT renamed.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter ArchiveFormatTests`
Expected: PASS, every case.

- [ ] **Step 7: Commit**

```bash
git add Sources/macSCPCore/Archive Sources/macSCPCore/Resources Tests/macSCPCoreTests/ArchiveFormatTests.swift
git commit -m "feat(archive): the formats, the refusals, and the name an archive is offered"
```

---

### Task 2: `ArchivePlan` and its local rendering

**Files:**
- Create: `Sources/macSCPCore/Archive/ArchivePlan.swift`
- Test: `Tests/macSCPCoreTests/ArchivePlanTests.swift`

**Interfaces:**
- Consumes: Task 1's `ArchiveFormat`, `ArchiveExtractFormat`,
  `ArchiveOperation`, `ExtractDestination`, `ArchiveRefusal`.
- Produces: `ArchiveWord`, `ArchivePlan`,
  `ArchivePlan.compress(_:selection:workingDirectory:archiveName:)`,
  `ArchivePlan.extract(_:format:workingDirectory:into:)`,
  `ArchivePlan.localInvocation(resolvingToolWith:)`.

**Why a word carries its own provenance.** `ArchiveWord` is `.flag` or
`.operand`, and that is the structural boundary this feature rests on rather
than a rule a reviewer has to remember. A `.flag` is this project's own fixed
vocabulary; an `.operand` is user-controlled. The local rendering treats both
as argv elements (there is no shell, so neither needs quoting); the remote
rendering in Task 3 quotes every `.operand` and no `.flag`. Neither renderer
can mix the two up, because the distinction is in the value, not in the call.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import macSCPCore

@Suite(.timeLimit(.minutes(1)))
struct ArchivePlanTests {
    private func file(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/d/" + name, kind: .file)
    }
    private func folder(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/d/" + name, kind: .directory)
    }
    private func names(of plan: ArchivePlan) -> [String] {
        guard let stdin = plan.stdin else { return [] }
        let separator: UInt8 = plan.tool == "zip" ? 0x0A : 0x00
        return stdin.split(separator: separator).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func zipTakesItsNamesOnStdinOnePerLine() throws {
        let plan = try ArchivePlan.compress(
            .zip, selection: [folder("d"), file("top file")],
            workingDirectory: "/d", archiveName: "out.zip")
        #expect(plan.tool == "zip")
        #expect(plan.words == [.flag("-r"), .flag("-@"), .operand("./out.zip")])
        #expect(names(of: plan) == ["d", "top file"])
    }

    @Test func tarTakesItsNamesOnStdinNulSeparated() throws {
        let plan = try ArchivePlan.compress(
            .tarGz, selection: [folder("d"), file("top file")],
            workingDirectory: "/d", archiveName: "out.tar.gz")
        #expect(plan.tool == "tar")
        #expect(plan.words == [
            .flag("--null"), .flag("-T"), .flag("-"), .flag("-czf"), .operand("./out.tar.gz"),
        ])
        #expect(names(of: plan) == ["d", "top file"])
    }

    /// The selection reaches the tool as BYTES, never as a word, so nothing
    /// in it can be read as syntax. This is the property the whole design
    /// exists for; it is asserted on the plan, where it is checkable without
    /// a server.
    @Test(arguments: ["$(reboot)", "a'b", "a b", "`id`", "-rf", "a;b", "a|b", "a\\b", "ä€🙂"])
    func ahostileNameNeverBecomesAWord(hostile: String) throws {
        let plan = try ArchivePlan.compress(
            .zip, selection: [file(hostile)],
            workingDirectory: "/d", archiveName: "out.zip")
        let operands = plan.words.compactMap { word -> String? in
            if case .operand(let value) = word { return value }
            return nil
        }
        #expect(operands == ["./out.zip"])
        #expect(names(of: plan) == [hostile])
    }

    @Test func zipRefusesANameHoldingANewline() {
        #expect(throws: ArchiveRefusal.newlineInNameUnsupportedByZip(name: "two\nlines")) {
            try ArchivePlan.compress(
                .zip, selection: [file("two\nlines")],
                workingDirectory: "/d", archiveName: "out.zip")
        }
    }

    /// The same name is fine for the NUL-separated paths, which is the whole
    /// reason the refusal above is per-format and not per-feature. A
    /// positive beside the negative, as this project requires.
    @Test(arguments: [ArchiveFormat.tarGz])
    func aNameHoldingANewlineIsFineWhereTheSeparatorIsNul(format: ArchiveFormat) throws {
        let plan = try ArchivePlan.compress(
            format, selection: [file("two\nlines")],
            workingDirectory: "/d", archiveName: "out." + format.fileExtension)
        #expect(names(of: plan) == ["two\nlines"])
    }

    @Test func gzKeepsItsInputAndTakesNoStdin() throws {
        let plan = try ArchivePlan.compress(
            .gz, selection: [file("big.log")],
            workingDirectory: "/d", archiveName: "big.log.gz")
        #expect(plan.tool == "gzip")
        #expect(plan.words == [.flag("-k"), .flag("--"), .operand("big.log")])
        #expect(plan.stdin == nil)
    }

    @Test func extractingIntoThisFolderSkipsWhatIsAlreadyThere() throws {
        let plan = try ArchivePlan.extract(
            file("ar.zip"), format: .zip, workingDirectory: "/d", into: .thisFolder)
        #expect(plan.tool == "unzip")
        #expect(plan.words == [.flag("-n"), .flag("-q"), .operand("./ar.zip")])
    }

    @Test func extractingIntoASubfolderNamesItAsTheDestination() throws {
        let plan = try ArchivePlan.extract(
            file("ar.zip"), format: .zip, workingDirectory: "/d",
            into: .subfolder("ar 2"))
        #expect(plan.words == [
            .flag("-n"), .flag("-q"), .operand("./ar.zip"), .flag("-d"), .operand("./ar 2"),
        ])
    }

    @Test func extractingATarballKeepsOldFiles() throws {
        let plan = try ArchivePlan.extract(
            file("ar.tar.gz"), format: .tarGz, workingDirectory: "/d", into: .thisFolder)
        #expect(plan.tool == "tar")
        #expect(plan.words == [
            .flag("--keep-old-files"), .flag("-xzf"), .operand("./ar.tar.gz"),
        ])
    }

    /// A user-supplied archive name can begin with a dash, and this project
    /// has not measured `--` against `unzip` or `tar`. The `./` prefix makes
    /// a leading dash harmless without claiming support for a terminator
    /// that was never tested.
    @Test func auserSuppliedArchiveNameIsPrefixedSoALeadingDashIsNotAnOption() throws {
        let plan = try ArchivePlan.extract(
            file("-rf.zip"), format: .zip, workingDirectory: "/d", into: .thisFolder)
        #expect(plan.words.contains(.operand("./-rf.zip")))
    }

    @Test func thelocalInvocationIsArgvWithNoQuotingAndNoShell() throws {
        let plan = try ArchivePlan.compress(
            .zip, selection: [file("a'b")],
            workingDirectory: "/d", archiveName: "out.zip")
        let invocation = try plan.localInvocation(resolvingToolWith: { "/usr/bin/" + $0 })
        #expect(invocation.executable == URL(fileURLWithPath: "/usr/bin/zip"))
        #expect(invocation.arguments == ["-r", "-@", "./out.zip"])
        #expect(invocation.currentDirectory == URL(fileURLWithPath: "/d"))
        #expect(invocation.stdin == Data("a'b\n".utf8))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ArchivePlanTests`
Expected: FAIL — `cannot find 'ArchivePlan' in scope`.

- [ ] **Step 3: Write `ArchivePlan.swift`**

```swift
import Foundation

/// One word of an archive command, carrying whether it is OURS or the
/// user's.
///
/// This is the feature's safety boundary, expressed as a type rather than as
/// a rule. A `.flag` is this project's own fixed vocabulary, written in this
/// file and nowhere else. An `.operand` is user-controlled. The local
/// rendering passes both as argv elements — `Process` takes an array, so no
/// shell parses either — and the remote rendering quotes every `.operand`
/// and no `.flag`. Neither renderer decides which is which; the value
/// already says.
public enum ArchiveWord: Sendable, Equatable {
    case flag(String)
    case operand(String)
}

/// What one archive operation will run, as a value: no channel, no process,
/// no connection.
///
/// `stdin` carries the SELECTION for the formats whose tool reads names from
/// standard input, so an arbitrary file name never becomes a word of a
/// command. `zip -@` is newline-separated and `tar --null -T -` is
/// NUL-separated, both measured 2026-10-08; the difference is why
/// `ArchiveRefusal.newlineInNameUnsupportedByZip` exists.
public struct ArchivePlan: Sendable, Equatable {
    public let operation: ArchiveOperation
    public let workingDirectory: String
    public let tool: String
    public let words: [ArchiveWord]
    public let stdin: Data?

    /// What a local run needs: an executable, argv, a directory, and bytes.
    public struct LocalInvocation: Sendable, Equatable {
        public let executable: URL
        public let arguments: [String]
        public let currentDirectory: URL
        public let stdin: Data?
    }

    /// This plan as a local invocation. No quoting happens here and none is
    /// needed: `SubprocessRunner.run` takes `arguments: [String]` straight
    /// to `Process`, which passes them to `execve` as separate elements.
    /// There is no shell on this path at all.
    public func localInvocation(
        resolvingToolWith resolve: (String) -> String
    ) throws -> LocalInvocation {
        LocalInvocation(
            executable: URL(fileURLWithPath: resolve(tool)),
            arguments: words.map { word in
                switch word {
                case .flag(let value), .operand(let value): value
                }
            },
            currentDirectory: URL(fileURLWithPath: workingDirectory),
            stdin: stdin)
    }

    /// The plan that creates `archiveName` out of `selection`.
    ///
    /// `archiveName` is the caller's, from `ArchiveNaming` — it is not
    /// derived here, because the dialog shows it to the user before anything
    /// runs and the two must be the same string.
    public static func compress(
        _ format: ArchiveFormat, selection: [RemoteFileItem],
        workingDirectory: String, archiveName: String
    ) throws -> ArchivePlan {
        guard !selection.isEmpty else { throw ArchiveRefusal.emptySelection }
        // Every operand macSCP did not choose goes in `./`-prefixed, including
        // the archive name: `ArchiveNaming.proposedName` derives it from the
        // SELECTED item's name, so a file called `-v` would otherwise put a
        // leading dash on the command line. Added in Task 2's fix round 1
        // after a reviewer measured it, 2026-10-08:
        // `printf -- '-v\n' | zip -q -r -@ '-v2.zip'` answered "Invalid
        // command arguments (short option '.' not supported)" and exited 16,
        // where the `./` form created the archive. tar accepts both forms
        // (measured the same day, with and without a leading dash), so this
        // is one rule rather than a zip exception.
        switch format {
        case .zip:
            // One path per line, so a name holding a newline cannot be
            // passed at all — it would arrive as two names.
            for item in selection where item.name.contains("\n") {
                throw ArchiveRefusal.newlineInNameUnsupportedByZip(name: item.name)
            }
            return ArchivePlan(
                operation: .compress(format), workingDirectory: workingDirectory,
                tool: "zip",
                words: [.flag("-r"), .flag("-@"), .operand("./" + archiveName)],
                stdin: Data(selection.map(\.name).joined(separator: "\n").utf8) + Data([0x0A]))
        case .tarGz:
            var bytes = Data()
            for item in selection {
                bytes.append(Data(item.name.utf8))
                bytes.append(0x00)
            }
            return ArchivePlan(
                operation: .compress(format), workingDirectory: workingDirectory,
                tool: "tar",
                words: [
                    .flag("--null"), .flag("-T"), .flag("-"),
                    .flag("-czf"), .operand("./" + archiveName),
                ],
                stdin: bytes)
        case .gz:
            // Checked here AND in `ArchiveNaming.proposedName`, deliberately:
            // the dialog calls the naming to show a name before anything
            // runs, and a later caller could reach `compress` without having
            // gone through it. Two guards over one rule, not a leftover.
            guard selection.count == 1 else {
                throw ArchiveRefusal.gzTakesExactlyOneFile(count: selection.count)
            }
            let only = selection[0]
            guard only.kind == .file else {
                throw ArchiveRefusal.gzTakesAFileNotAFolder(name: only.name)
            }
            // `-k` keeps the input: maintainer decision 4, and the reason no
            // menu entry here destroys its source. `--` is measured against
            // gzip (2026-10-08) and is safe for a name beginning with a dash.
            return ArchivePlan(
                operation: .compress(format), workingDirectory: workingDirectory,
                tool: "gzip",
                words: [.flag("-k"), .flag("--"), .operand(only.name)],
                stdin: nil)
        }
    }

    /// The plan that unpacks `archive` into `destination`.
    ///
    /// Both tools are given their SKIP-EXISTING flag, `unzip -n` and
    /// `tar --keep-old-files`, so nothing is overwritten even when the
    /// directory changed between the dialog and the run. Measured
    /// 2026-10-08: both keep the old file, extract the rest, and exit 0 —
    /// and BOTH ARE SILENT about what they skipped, which is why the count
    /// the dialog shows comes from a listing instead.
    ///
    /// The archive's own name is the one user-controlled word on an
    /// extraction, and it is prefixed `./` rather than terminated with
    /// `--`: a name beginning with a dash is then not an option to any of
    /// these tools, and this project has measured `--` for `gzip` only.
    public static func extract(
        _ archive: RemoteFileItem, format: ArchiveExtractFormat,
        workingDirectory: String, into destination: ExtractDestination
    ) throws -> ArchivePlan {
        let source = ArchiveWord.operand("./" + archive.name)
        var words: [ArchiveWord]
        let tool: String
        switch format {
        case .zip:
            tool = "unzip"
            words = [.flag("-n"), .flag("-q"), source]
            if case .subfolder(let name) = destination {
                words += [.flag("-d"), .operand("./" + name)]
            }
        case .tar, .tarGz:
            tool = "tar"
            let read: ArchiveWord = format == .tarGz ? .flag("-xzf") : .flag("-xf")
            words = [.flag("--keep-old-files"), read, source]
            if case .subfolder(let name) = destination {
                words += [.flag("-C"), .operand("./" + name)]
            }
        case .gz:
            // Withdrawn from this plan's first draft, which read: "a
            // subfolder destination is carried out by the runner creating
            // the folder and running there; the plan's working directory is
            // what the caller passes." That does not work -- run inside the
            // new subfolder, `gunzip` would not find the archive, which sits
            // in the parent. It cannot be given a destination at all
            // without a redirection, so the combination is refused.
            guard destination == .thisFolder else {
                throw ArchiveRefusal.gzExtractsIntoThisFolderOnly
            }
            tool = "gunzip"
            words = [.flag("-k"), .flag("--"), .operand("./" + archive.name)]
        }
        return ArchivePlan(
            operation: .extract(format), workingDirectory: workingDirectory,
            tool: tool, words: words, stdin: nil)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ArchivePlanTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Archive/ArchivePlan.swift Tests/macSCPCoreTests/ArchivePlanTests.swift
git commit -m "feat(archive): the plan, with a word that carries whose it is"
```

---

### Task 3: `ArchiveCommandLine` and the remote rendering

**Files:**
- Create: `Sources/macSCPCore/Archive/ArchiveCommandLine.swift`
- Test: `Tests/macSCPCoreTests/ArchiveCommandLineTests.swift`

**Interfaces:**
- Consumes: Task 2's `ArchivePlan` and `ArchiveWord`;
  `PosixQuoting.singleQuoted(_:)`
  (`Sources/macSCPCore/Terminal/PosixQuoting.swift:27`).
- Produces: `ArchiveCommandLine` (with `public let text: String` and a
  `fileprivate init`), and `ArchivePlan.remoteCommandLine()`.

**Why `fileprivate`.** `ChecksumCommandLine` does the same
(`Sources/macSCPCore/RemoteFS/FileChecksum.swift:325`–`:331`), so the only
code that can phrase a checksum command is the file that builds them. The
same boundary here means no future file can hand the channel of Task 4 a
command string of its own: it would have to come through this file, which
quotes every operand. `RemoteChecksumProvider.swift` states the reasoning —
"A general execution entry point would have been the alternative, and it
would have been a new surface every future reviewer had to watch."

**Reuse, do not re-implement, the quoting.** `PosixQuoting.singleQuoted`
already exists and is already what the checksum command lines use
(`FileChecksum.swift:275`). It is a walk over `Unicode.Scalar`s and not
`replacingOccurrences`, because that call matches on grapheme clusters, so an
apostrophe carrying a combining mark went unescaped and met the wrapper's own
closing quote as live shell syntax — which executed arbitrary commands in real
`bash`. Writing a second helper here re-opens that.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import macSCPCore

@Suite(.timeLimit(.minutes(1)))
struct ArchiveCommandLineTests {
    private func file(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/d/" + name, kind: .file)
    }

    @Test func theLineEntersTheWorkingDirectoryAndRunsTheTool() throws {
        let plan = try ArchivePlan.compress(
            .zip, selection: [file("a")], workingDirectory: "/srv/data",
            archiveName: "out.zip")
        #expect(plan.remoteCommandLine().text == "cd '/srv/data' && zip -r -@ './out.zip'")
    }

    @Test func everyFlagIsUnquotedAndEveryOperandIsQuoted() throws {
        let plan = try ArchivePlan.compress(
            .tarGz, selection: [file("a")], workingDirectory: "/d",
            archiveName: "out.tar.gz")
        #expect(
            plan.remoteCommandLine().text
                == "cd '/d' && tar --null -T - -czf './out.tar.gz'")
    }

    /// The archive name is the one user-controlled word on the line, so it
    /// is the one this suite hammers. The value is built into a constant and
    /// the Bool computed before the expectation, because `#expect` prints
    /// the SOURCE TEXT of what it checks and a failure must not reproduce
    /// the payload.
    @Test(arguments: [
        "a'b", "$(reboot)", "`id`", "a;rm -rf /", "a b", "a|b", "a\\b", "a\nb", "ä€🙂",
    ])
    func ahostileArchiveNameBecomesExactlyOneShellWord(hostile: String) throws {
        let plan = try ArchivePlan.compress(
            .tarGz, selection: [file("x")], workingDirectory: "/d",
            archiveName: hostile)
        let expected = "cd '/d' && tar --null -T - -czf "
            + PosixQuoting.singleQuoted("./" + hostile)
        let matches = plan.remoteCommandLine().text == expected
        #expect(matches)
    }

    /// The positive beside that negative: the quoting is REACHED at all.
    /// Without this, a rendering that dropped the operand entirely would
    /// satisfy every "no unquoted metacharacter" check above.
    @Test func theOperandIsPresentInTheLine() throws {
        let plan = try ArchivePlan.compress(
            .zip, selection: [file("x")], workingDirectory: "/d",
            archiveName: "report.zip")
        #expect(plan.remoteCommandLine().text.contains("'./report.zip'"))
    }

    @Test func theSelectionIsNowhereInTheLine() throws {
        let plan = try ArchivePlan.compress(
            .tarGz, selection: [file("secret-looking-name")],
            workingDirectory: "/d", archiveName: "out.tar.gz")
        #expect(plan.remoteCommandLine().text.contains("secret-looking-name") == false)
    }

    @Test func anExtractionQuotesTheArchiveNameItWasGiven() throws {
        let plan = try ArchivePlan.extract(
            file("ar.zip"), format: .zip, workingDirectory: "/d",
            into: .subfolder("ar 2"))
        #expect(
            plan.remoteCommandLine().text
                == "cd '/d' && unzip -n -q './ar.zip' -d './ar 2'")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ArchiveCommandLineTests`
Expected: FAIL — `value of type 'ArchivePlan' has no member 'remoteCommandLine'`.

- [ ] **Step 3: Write `ArchiveCommandLine.swift`**

```swift
import Foundation

/// One line an `ArchiveCommandChannel` will run on the far side.
///
/// `fileprivate init`, exactly as `ChecksumCommandLine` has
/// (`Sources/macSCPCore/RemoteFS/FileChecksum.swift:325`): the only code
/// that can phrase an archive command is this file, and this file quotes
/// every operand. A channel therefore cannot be handed a string somebody
/// assembled elsewhere — there is no expression for it.
public struct ArchiveCommandLine: Sendable, Equatable {
    /// The line as the far side's shell will see it.
    public let text: String

    fileprivate init(text: String) {
        self.text = text
    }
}

extension ArchivePlan {
    /// This plan as one shell line.
    ///
    /// An SSH `exec` request is run by the far side through the account's
    /// login shell, so there IS a shell here — unlike the local path — and
    /// the quoting is not optional. Every `.operand` goes through
    /// `PosixQuoting.singleQuoted`; every `.flag` is written as it stands,
    /// because flags are this project's own words from `ArchivePlan` and
    /// nothing else can put one there.
    ///
    /// The `cd` is how a tool is pointed at a directory without a `-C`
    /// every tool here would need; the directory is an operand and is
    /// quoted like any other.
    public func remoteCommandLine() -> ArchiveCommandLine {
        let rendered = words.map { word in
            switch word {
            case .flag(let value): value
            case .operand(let value): PosixQuoting.singleQuoted(value)
            }
        }
        let head = "cd " + PosixQuoting.singleQuoted(workingDirectory)
        return ArchiveCommandLine(
            text: ([head, "&&", tool] + rendered).joined(separator: " "))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ArchiveCommandLineTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Archive/ArchiveCommandLine.swift Tests/macSCPCoreTests/ArchiveCommandLineTests.swift
git commit -m "feat(archive): the remote line, quoted by the one file that can phrase it"
```

---

### Task 4: The channel seam, and SSH's conformance

**Files:**
- Create: `Sources/macSCPCore/Archive/ArchiveCommandChannel.swift`
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift` (add an
  `extension CitadelFileSystem: ArchiveCommandChannel` beside the existing
  `extension CitadelFileSystem: ChecksumCommandChannel` at `:1631`)
- Test: `Tests/macSCPCoreTests/ArchiveCommandChannelTests.swift`

**Interfaces:**
- Consumes: Task 3's `ArchiveCommandLine`; Citadel's
  `SSHClient.withExec(_:environment:perform:)`
  (`.build/checkouts/Citadel/Sources/Citadel/TTY/Client/TTY.swift:456`,
  `@available(macOS 15.0, *)`), which hands the closure a `TTYStdinWriter`
  (`TTY.swift:80`, `write(_ buffer: ByteBuffer) async throws`) and reports a
  non-zero exit as `SSHClient.CommandFailed(exitCode:)` (`TTY.swift:173`).
- Produces: `ArchiveCommandChannel`, `ArchiveCommandExitFailure`.

**Why `withExec` and not the three simpler entry points.** `executeCommand`,
`executeCommandStream` and `executeCommandPair` expose no stdin, and stdin is
where the selection goes. `withExec` opens the RFC 4254 exec channel, which
its own doc comment describes as "8-bit safe and suitable for binary data
transfer without PTY escape sequence processing" — the PTY path
(`CitadelShell`) would echo what is written to it and merge stderr into
stdout, which `CitadelFileSystem.swift:1631`'s existing comment already
explains for the checksum case.

- [ ] **Step 1: Write the failing tests**

Two suites. The first is a fake and runs always; the second needs the rig.

```swift
import Testing
import Foundation
@testable import macSCPCore

/// A channel that records what it was asked to run. Exists so everything
/// above the seam is testable with no server at all.
final actor RecordingArchiveChannel: ArchiveCommandChannel {
    private(set) var lines: [String] = []
    private(set) var stdins: [Data?] = []
    private let exitStatus: Int
    init(exitStatus: Int = 0) { self.exitStatus = exitStatus }
    func run(_ line: ArchiveCommandLine, stdin: Data?) async throws -> Int {
        lines.append(line.text)
        stdins.append(stdin)
        return exitStatus
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ArchiveCommandChannelTests {
    @Test func achannelIsHandedTheLineAndTheBytesSeparately() async throws {
        let channel = RecordingArchiveChannel()
        let plan = try ArchivePlan.compress(
            .tarGz,
            selection: [RemoteFileItem(name: "a b", path: "/d/a b", kind: .file)],
            workingDirectory: "/d", archiveName: "out.tar.gz")
        let status = try await channel.run(plan.remoteCommandLine(), stdin: plan.stdin)
        #expect(status == 0)
        #expect(await channel.lines == ["cd '/d' && tar --null -T - -czf './out.tar.gz'"])
        #expect(await channel.stdins == [Data("a b\0".utf8)])
    }

    @Test func exit127IsReadAsAMissingTool() {
        #expect(ArchiveCommandExitFailure(exitCode: 127).isToolMissing)
        #expect(ArchiveCommandExitFailure(exitCode: 1).isToolMissing == false)
    }
}
```

```swift
/// The rig half: a real exec channel, a real `zip`, over the Docker server.
/// Gated, because it needs that server.
@Suite(.timeLimit(.minutes(5)), .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"))
struct ArchiveCommandChannelRigTests {
    @Test func aselectionReachesTheFarSideThroughStdinAndTheArchiveAppears() async throws {
        let fs = try await RigFixture.connectedFileSystem()
        let channel = try #require(fs as? ArchiveCommandChannel)
        let home = try await fs.homeDirectoryPath()
        let dir = home + "/archive-itest"
        try await fs.createDirectory(at: dir)
        // A name no shell could survive unquoted, written through SFTP so
        // the test does not depend on the thing it is testing.
        let awkward = "it's a $(test) file"
        try await fs.write(
            path: dir + "/" + awkward, contents: .just(Data("payload\n".utf8)))

        let plan = try ArchivePlan.compress(
            .tarGz,
            selection: [RemoteFileItem(name: awkward, path: dir + "/" + awkward, kind: .file)],
            workingDirectory: dir, archiveName: "out.tar.gz")
        let status = try await channel.run(plan.remoteCommandLine(), stdin: plan.stdin)

        #expect(status == 0)
        let listed = try await fs.list(path: dir).map(\.name)
        #expect(listed.contains("out.tar.gz"))
        // The awkward name still exists, i.e. nothing executed it away.
        #expect(listed.contains(awkward))
        try await fs.deleteTree(at: dir)
    }
}
```

> **Note for the implementer:** `RigFixture.connectedFileSystem()` and
> `.just(_:)` above stand for whatever this repository's existing rig suites
> already use to reach a connected `CitadelFileSystem` and to write a small
> file. **Do not add new helpers.** Read a neighbouring gated suite — start
> with `grep -rln 'MACSCP_ITEST' Tests/` — and use the same entry points it
> uses, with the same names. If no such helper exists, build the connection
> exactly as that suite does, inline.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ArchiveCommandChannelTests`
Expected: FAIL — `cannot find type 'ArchiveCommandChannel' in scope`.

- [ ] **Step 3: Write `ArchiveCommandChannel.swift`**

```swift
import Foundation

/// A backend capability queried via `as?`, like `RemoteShellProvider`,
/// `PresignedURLProvider` and `RemoteChecksumProvider`: run ONE archive
/// command line, with bytes on its standard input, and report its exit
/// status.
///
/// Read the parameter list, because it is the whole design. An
/// `ArchiveCommandLine` — a value only
/// `Sources/macSCPCore/Archive/ArchiveCommandLine.swift` can build — and
/// bytes. Nothing here takes a `String`, an executable name, or an argument
/// list, so a caller cannot phrase a command of its own. That is the same
/// narrowing `ChecksumCommandChannel` uses, and for the reason
/// `RemoteChecksumProvider.swift` gives there: a general execution entry
/// point would be a new surface every future reviewer had to watch.
///
/// Standard output is NOT returned. An archive tool's output is progress
/// chatter, not an answer; what the caller needs is the exit status, and the
/// files the run produced are read back through the ordinary listing.
protocol ArchiveCommandChannel: Sendable {
    func run(_ line: ArchiveCommandLine, stdin: Data?) async throws -> Int
}

/// Thrown by a conforming channel when the command's own exit status is
/// known and non-zero — as opposed to a channel-level failure (a dropped
/// connection, a bound that elapsed).
///
/// Mirrors `ChecksumCommandExitFailure`, including why 127 is worth its own
/// question: POSIX shells report "could not find the executable this line
/// names" as exit 127 regardless of which shell is running it, and that is
/// the one archive failure the user can act on by picking another format.
struct ArchiveCommandExitFailure: Error, Equatable {
    let exitCode: Int

    /// The far side has no such tool.
    var isToolMissing: Bool { exitCode == 127 }
}
```

- [ ] **Step 4: Conform `CitadelFileSystem`**

Add after the existing `ChecksumCommandChannel` extension:

```swift
extension CitadelFileSystem: ArchiveCommandChannel {
    /// Runs `line` as an SSH `exec` request on the SAME connection SFTP and
    /// the terminal use, writing `stdin` into the channel and closing it so
    /// the tool sees end-of-input.
    ///
    /// `withExec` rather than `collectingStandardOutput(of:limit:)` above:
    /// that helper has no standard input, and the selection is exactly what
    /// has to go there. `withExec` opens the same kind of child channel —
    /// 8-bit safe, no PTY — and hands out a `TTYStdinWriter`.
    ///
    /// Standard output and standard error are drained and dropped. They are
    /// an archive tool's progress chatter; keeping them would mean deciding
    /// a bound for an unbounded stream, and nothing above this reads them.
    /// Draining is not optional, though: a far side whose output nobody
    /// reads fills the channel's window and stops.
    func run(_ line: ArchiveCommandLine, stdin: Data?) async throws -> Int {
        var exitStatus = 0
        do {
            try await client.withExec(line.text) { inbound, outbound in
                if let stdin {
                    try await outbound.write(ByteBuffer(bytes: stdin))
                }
                // Draining, discarding: see the comment above.
                for try await _ in inbound {}
            }
        } catch let failure as SSHClient.CommandFailed {
            // Translated HERE, at the one place this file's exec plumbing
            // meets the archive layer, so nothing above it ever sees
            // Citadel's error types.
            exitStatus = failure.exitCode
            throw ArchiveCommandExitFailure(exitCode: exitStatus)
        }
        return exitStatus
    }
}
```

> **Updated 2026-10-08.** The note that stood here told the implementer to
> find out whether stdin could be closed and to report BLOCKED if not. It
> did, and it was: Citadel `0.12.1-noix.3` had no way to signal end-of-input.
> Task 10 added one, and the pin is now `0.12.1-noix.4`
> (`Package.swift:43`), so the call exists: **`TTYStdinWriter.closeStandardInput()`**,
> which is `channel.close(mode: .output)`. A reviewer traced the NIO state
> machine and confirmed it leaves the inbound half delivering output and the
> exit status: `SSHChildChannel._actuallyClose0`'s `.output` case only
> appends `.eof` to the pending writes and flushes, never touching the close
> promise.
>
> **But calling it is not enough, and this is a HARD REQUIREMENT of this
> task.** `sendChannelEOF` throws `protocolViolation "Sent EOF out of
> sequence."` in `.halfClosedRemote`, and that throw reaches the inbound
> stream through `errorEncountered`. So when a far side exits BEFORE reading
> its standard input — which is exactly what a missing tool does, the shell
> exiting 127 and OpenSSH sending CHANNEL_EOF while macSCP is still writing
> archive bytes — a naive closure lets that error replace
> `CommandFailed(exitCode: 127)`, and `isToolMissing` never sees 127. The
> masking Task 10's tag removes would come straight back by another path.
>
> So the closure MUST: tolerate a throw from the write and from
> `closeStandardInput()` rather than propagating it, keep draining `inbound`
> afterwards so the far side's own verdict arrives, and let the exit status
> win over any channel error. The doc comment says so, and the rig case
> below proves it.
>
> **Corrected after Task 4, 2026-10-08.** The paragraph above predicted the
> masking error would be `protocolViolation "Sent EOF out of sequence."`
> That prediction is withdrawn as the OBSERVED cause: measured against the
> real rig, a propagating write gives `ChannelError.eof` ("End of file") and
> a propagating half-close gives `ChannelError.alreadyClosed`; the
> `protocolViolation` never occurred. The REQUIREMENT is unchanged and was
> confirmed necessary — both tolerances are independently load-bearing. One
> thing stays unmeasured and is recorded as such rather than claimed: in the
> narrow window where `sendChannelEOF` really would throw, tolerance cannot
> help, because the throw poisons the inbound stream and Citadel prefers a
> stream error over the recorded exit code. Recovering from that would be a
> fork change, and it was not taken.

- [ ] **Step 4b: The rig case that pins exit 127 against a real server**

Required by the paragraph above, and the reason it is a rig case rather than
a fake: only a real `sshd` sends CHANNEL_EOF at the moment that triggers the
defect.

```swift
    /// A tool the far side does not have exits 127 WHILE macSCP is still
    /// writing the name list, so OpenSSH sends CHANNEL_EOF mid-write and the
    /// half-close then runs in `.halfClosedRemote`, where `sendChannelEOF`
    /// throws. If the closure lets that throw out, the caller sees a channel
    /// error and `isToolMissing` never sees 127 — the masking
    /// `0.12.1-noix.4` exists to remove, returning by another path.
    @Test(.timeLimit(.minutes(5)))
    func amissingToolIsReported127EvenWhileStdinIsStillBeingWritten() async throws {
        let fs = try await /* the connected rig file system, as the neighbouring gated suite builds it */
        let channel = try #require(fs as? ArchiveCommandChannel)
        let home = try await fs.homeDirectoryPath()
        // 400_000, about 5.2 MB, which is PAST the channel's outbound
        // window — and that is a guard's sensitivity, not a style choice.
        // This line first read `(0..<20_000)`, with the comment "Big enough
        // that the write is still in flight when the far side gives up: the
        // point of the case is the overlap." Withdrawn: measured
        // 2026-10-08, at 20_000 the case was VACUOUS — with both tolerances
        // removed (`try?` changed to `try`) the probe came back
        // "GREEN — 7 ran, none noticed". At 400_000 each tolerance is red
        // on its own, 3 of 3 per plant. Shrinking this number disarms the
        // case.
        let manyNames = Data(
            (0..<400_000).map { "name-\($0)" }.joined(separator: "\n").utf8)
        let plan = ArchivePlan(
            operation: .compress(.zip), workingDirectory: home,
            tool: "macscp-no-such-archiver",
            words: [.flag("-r"), .flag("-@"), .operand("./out.zip")],
            stdin: manyNames)
        await #expect(throws: ArchiveCommandExitFailure(exitCode: 127)) {
            try await channel.run(plan.remoteCommandLine(), stdin: plan.stdin)
        }
    }
```

Run it, and if it comes back with a channel error instead of 127, the closure
is not yet tolerant enough — that is the finding this case exists for, not a
reason to widen the expectation.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter ArchiveCommandChannel`
Expected: PASS (the fake suite).

Then, from the main checkout only:
```bash
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 swift test --filter ArchiveCommandChannelRigTests
```
Expected: PASS, and the awkwardly named file still present afterwards.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore/Archive/ArchiveCommandChannel.swift Sources/macSCPCore/SSH/CitadelFileSystem.swift Tests/macSCPCoreTests/ArchiveCommandChannelTests.swift
git commit -m "feat(archive): a channel that takes a line and bytes, nothing else"
```

---

### Task 5: The two runners

**Files:**
- Create: `Sources/macSCPCore/Archive/ArchiveRunner.swift`
- Test: `Tests/macSCPCoreTests/ArchiveRunnerTests.swift`

**Interfaces:**
- Consumes: Task 2's `ArchivePlan`/`LocalInvocation`, Task 3's
  `remoteCommandLine()`, Task 4's `ArchiveCommandChannel` and
  `ArchiveCommandExitFailure`; `SubprocessRunner.run`
  (`Sources/macSCPCore/Subprocess/SubprocessRunner.swift:248` — `package`,
  so a Core type may call it;
  `(URL, arguments: [String], environment:, currentDirectory: URL?, stdin: Data?, timeout: Duration, onStderrChunk:, onStdoutChunk:, onStarted:) async throws -> SubprocessResult`,
  whose `status: Int32`, `stdout: Data`, `stderr: Data`).
- Produces: `ArchiveRunner`, `ArchiveOutcome`, `LocalArchiveRunner`,
  `RemoteArchiveRunner`, `ArchiveBudget`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import macSCPCore

@Suite(.timeLimit(.minutes(5)))
struct ArchiveRunnerTests {
    /// A real `zip` over a real directory. No network, no rig: the local
    /// runner's whole job is argv plus bytes, and this is the cheapest place
    /// to prove a hostile name survives it.
    @Test func thelocalRunnerCompressesAnApostropheAndADollarSign() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let awkward = "it's $(not) run"
        try Data("payload\n".utf8).write(to: dir.appendingPathComponent(awkward))

        let plan = try ArchivePlan.compress(
            .zip,
            selection: [RemoteFileItem(
                name: awkward, path: dir.appendingPathComponent(awkward).path, kind: .file)],
            workingDirectory: dir.path, archiveName: "out.zip")
        let outcome = try await LocalArchiveRunner().run(plan)

        #expect(outcome == .finished)
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("out.zip").path))
        // Still there: the name was data, not code.
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(awkward).path))
    }

    @Test func thelocalRunnerReportsAMissingToolApart() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let plan = ArchivePlan(
            operation: .compress(.zip), workingDirectory: dir.path,
            tool: "macscp-no-such-archiver", words: [.operand("x")], stdin: nil)
        await #expect(throws: ArchiveFailure.toolMissing(tool: "macscp-no-such-archiver")) {
            try await LocalArchiveRunner().run(plan)
        }
    }

    @Test func theremoteRunnerHandsThePlanToItsChannel() async throws {
        let channel = RecordingArchiveChannel()
        let plan = try ArchivePlan.compress(
            .zip, selection: [RemoteFileItem(name: "a", path: "/d/a", kind: .file)],
            workingDirectory: "/d", archiveName: "out.zip")
        let outcome = try await RemoteArchiveRunner(channel: channel).run(plan)
        #expect(outcome == .finished)
        #expect(await channel.lines.count == 1)
    }

    @Test func theremoteRunnerTurns127IntoAMissingTool() async throws {
        let channel = FailingArchiveChannel(exitCode: 127)
        let plan = try ArchivePlan.compress(
            .zip, selection: [RemoteFileItem(name: "a", path: "/d/a", kind: .file)],
            workingDirectory: "/d", archiveName: "out.zip")
        await #expect(throws: ArchiveFailure.toolMissing(tool: "zip")) {
            try await RemoteArchiveRunner(channel: channel).run(plan)
        }
    }

    @Test func theremoteRunnerKeepsAnyOtherExitStatusAsItIs() async throws {
        let channel = FailingArchiveChannel(exitCode: 12)
        let plan = try ArchivePlan.compress(
            .zip, selection: [RemoteFileItem(name: "a", path: "/d/a", kind: .file)],
            workingDirectory: "/d", archiveName: "out.zip")
        await #expect(throws: ArchiveFailure.exited(status: 12)) {
            try await RemoteArchiveRunner(channel: channel).run(plan)
        }
    }

    /// A FLOOR, not a ceiling: the runner must not return before the tool
    /// has finished. A ceiling here would measure the machine, which this
    /// project has three CI reds on record for.
    @Test func thelocalRunnerDoesNotReturnBeforeTheArchiveExists() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0..<200 {
            try Data(repeating: 0x41, count: 4096)
                .write(to: dir.appendingPathComponent("f\(index)"))
        }
        let selection = (0..<200).map { index in
            RemoteFileItem(
                name: "f\(index)", path: dir.appendingPathComponent("f\(index)").path,
                kind: .file)
        }
        let plan = try ArchivePlan.compress(
            .zip, selection: selection, workingDirectory: dir.path,
            archiveName: "many.zip")
        _ = try await LocalArchiveRunner().run(plan)

        // The floor, stated as a COUNT rather than as an outcome: if `run`
        // returned before `zip` had finished, the archive would hold fewer
        // than the 200 entries that went in. An earlier version of this case
        // asserted only `== .finished` on a second run, which every
        // implementation passes including one that returns immediately --
        // a test that could not fail is worse than no test, so it was
        // replaced rather than kept.
        let listed = try await SubprocessRunner.run(
            URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-Z1", "./many.zip"],
            currentDirectory: dir,
            timeout: ArchiveBudget.run)
        let entryCount = listed.stdoutText
            .split(separator: "\n", omittingEmptySubsequences: true).count
        #expect(entryCount == 200)
    }
}

/// A channel that always fails with one exit code.
final actor FailingArchiveChannel: ArchiveCommandChannel {
    private let exitCode: Int
    init(exitCode: Int) { self.exitCode = exitCode }
    func run(_ line: ArchiveCommandLine, stdin: Data?) async throws -> Int {
        throw ArchiveCommandExitFailure(exitCode: exitCode)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ArchiveRunnerTests`
Expected: FAIL — `cannot find 'LocalArchiveRunner' in scope`.

- [ ] **Step 3: Write `ArchiveRunner.swift`**

```swift
import Foundation

/// How an archive run ended, as far as the runner can tell.
public enum ArchiveOutcome: Sendable, Equatable {
    case finished
    case cancelled
}

/// Why an archive run did not finish. Each case maps to one sentence the
/// user is shown; none of them carries a tool's raw output, because that
/// output is a far side's text and belongs in no `reason:` string.
public enum ArchiveFailure: Error, Equatable, Sendable {
    /// Exit 127, or a local executable that is not there.
    case toolMissing(tool: String)
    /// Any other non-zero status.
    case exited(status: Int)
}

/// The budget an archive run gets. Far above `SubprocessRunner.run`'s own
/// 60-second default, which is sized for short CLI calls: compressing a
/// large folder legitimately takes many minutes, and a budget that cuts it
/// off would be a wall-clock ceiling on the USER's machine.
public enum ArchiveBudget {
    public static let run: Duration = .seconds(60 * 60)
}

/// Runs a plan. Holds no policy: which command to run was decided by
/// `ArchivePlan`.
public protocol ArchiveRunner: Sendable {
    func run(_ plan: ArchivePlan) async throws -> ArchiveOutcome
}

/// The local pane's runner. No shell anywhere on this path.
public struct LocalArchiveRunner: ArchiveRunner {
    public init() {}

    public func run(_ plan: ArchivePlan) async throws -> ArchiveOutcome {
        let invocation = try plan.localInvocation(resolvingToolWith: Self.resolve(_:))
        guard FileManager.default.isExecutableFile(atPath: invocation.executable.path) else {
            throw ArchiveFailure.toolMissing(tool: plan.tool)
        }
        let result = try await SubprocessRunner.run(
            invocation.executable,
            arguments: invocation.arguments,
            currentDirectory: invocation.currentDirectory,
            stdin: invocation.stdin,
            timeout: ArchiveBudget.run)
        if Task.isCancelled { return .cancelled }
        switch result.status {
        case 0: return .finished
        case 127: throw ArchiveFailure.toolMissing(tool: plan.tool)
        case let status: throw ArchiveFailure.exited(status: Int(status))
        }
    }

    /// `/usr/bin/<tool>` for every tool this feature names. Spelled as a
    /// path rather than found through `PATH`, because a `PATH` lookup is a
    /// second way for this process to choose an executable and macOS ships
    /// all five at that location.
    static func resolve(_ tool: String) -> String { "/usr/bin/" + tool }
}

/// The remote pane's runner, over whichever backend answered the capability.
public struct RemoteArchiveRunner: ArchiveRunner {
    private let channel: any ArchiveCommandChannel

    public init(channel: any ArchiveCommandChannel) {
        self.channel = channel
    }

    public func run(_ plan: ArchivePlan) async throws -> ArchiveOutcome {
        do {
            let status = try await channel.run(plan.remoteCommandLine(), stdin: plan.stdin)
            if Task.isCancelled { return .cancelled }
            guard status == 0 else { throw ArchiveFailure.exited(status: status) }
            return .finished
        } catch let failure as ArchiveCommandExitFailure {
            if failure.isToolMissing { throw ArchiveFailure.toolMissing(tool: plan.tool) }
            throw ArchiveFailure.exited(status: failure.exitCode)
        }
    }
}
```

> **Note for the implementer:** `RemoteArchiveRunner`'s initializer takes
> `any ArchiveCommandChannel`, and that protocol is internal (Task 4), so
> the type cannot be `public` with a `public init` taking it. Make the
> initializer `package` or the protocol `public` — **choose the smaller
> widening**, state which you chose and why in your report, and keep the
> protocol's narrowing intact either way (no method that takes a `String`).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ArchiveRunnerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Archive/ArchiveRunner.swift Tests/macSCPCoreTests/ArchiveRunnerTests.swift
git commit -m "feat(archive): the local and the remote runner, and one failure vocabulary"
```

---

### Task 6: The menu entries and the gate

**Files:**
- Modify: `Sources/macSCPCore/Presentation/BrowserContextMenu.swift`
- Modify: `Sources/MacSCPAppKit/RemoteFileTableView.swift`
- Modify: `Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
- Test: `Tests/macSCPCoreTests/ArchiveMenuEntriesTests.swift`

**Interfaces:**
- Consumes: Task 1's `ArchiveFormat`, `ArchiveExtractFormat`.
- Produces: `BrowserMenuEntry.compressTo(ArchiveFormat)` and
  `BrowserMenuEntry.extractArchive(ArchiveExtractFormat)`; a new
  `supportsArchiving: Bool = false` parameter on
  `BrowserContextMenu.entries(for:side:…)`.

**The shape, and why it is flat.** Core emits one `.compressTo` entry per
offered format, in a run, plus `.extractArchive` when the single selected row
names a format. The AppKit layer folds the `.compressTo` run into one
"Compress" submenu — exactly what `makeTransferItem`
(`Sources/MacSCPAppKit/RemoteFileTableView.swift:1111`–`:1147`) already does
for the run of `.transferToSession` entries. Keeping the model flat is why
the decision logic stays unit-testable in Core, which is what that file's own
header says it is for.

**The gate:** `supportsArchiving` defaults to `false`, so every existing call
site keeps exactly the menu it has. Where it is `false` the entries are
**absent, not disabled** — the `computeChecksum` judgement at
`BrowserContextMenu.swift:37`.

**Corrected after Task 5, 2026-10-08.** This paragraph first read: "The
caller passes `fs is ArchiveCommandChannel` for a remote pane and `true` for
a local one." Withdrawn, because it does not compile from the App target:
`ArchiveCommandChannel` is **internal to macSCPCore** on purpose, and Swift
will not let a `package` or `public` signature name it. Task 5's implementer
hit this and built the seam instead —
`RemoteArchiveRunner.init?(backend: any Sendable)`
(`Sources/macSCPCore/Archive/ArchiveRunner.swift:84`), which does the `as?`
inside the module that owns the protocol and answers `nil` when the backend
cannot archive.

So the caller passes `RemoteArchiveRunner(backend: fs) != nil` for a remote
pane and `true` for a local one. That is a better gate than a protocol check
and not merely a workaround: the menu then offers archiving exactly when a
runner can be made for that pane, so the entry and the thing that would run
it cannot disagree.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import macSCPCore

@Suite(.timeLimit(.minutes(1)))
struct ArchiveMenuEntriesTests {
    private func file(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/d/" + name, kind: .file)
    }
    private func folder(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/d/" + name, kind: .directory)
    }
    private func entries(
        _ selection: [RemoteFileItem], archiving: Bool = true
    ) -> [BrowserMenuEntry] {
        BrowserContextMenu.entries(
            for: selection, side: .remote, supportsArchiving: archiving)
    }

    @Test func abackendThatCannotRunCommandsOffersNoArchiveEntryAtAll() {
        let offered = entries([folder("d")], archiving: false)
        #expect(offered.contains { if case .compressTo = $0 { true } else { false } } == false)
        #expect(offered.contains { if case .extractArchive = $0 { true } else { false } } == false)
    }

    /// The positive beside that negative: with the gate open the entries ARE
    /// there. Without this, a model that stopped emitting them entirely
    /// would satisfy the case above.
    @Test func abackendThatCanRunCommandsOffersThem() {
        let offered = entries([folder("d")])
        #expect(offered.contains(.compressTo(.zip)))
        #expect(offered.contains(.compressTo(.tarGz)))
    }

    @Test func gzIsOfferedOnlyForASingleFile() {
        #expect(entries([file("a.log")]).contains(.compressTo(.gz)))
        #expect(entries([folder("d")]).contains(.compressTo(.gz)) == false)
        #expect(entries([file("a"), file("b")]).contains(.compressTo(.gz)) == false)
    }

    @Test func thecompressEntriesSitInOneUnbrokenRunInFormatOrder() throws {
        let offered = entries([file("a.log")])
        let positions = offered.indices.filter { index in
            if case .compressTo = offered[index] { return true } else { return false }
        }
        #expect(positions == Array(positions.first!...positions.last!))
        #expect(
            positions.map { offered[$0] }
                == [.compressTo(.zip), .compressTo(.tarGz), .compressTo(.gz)])
    }

    @Test func extractIsOfferedForOneRowWhoseNameNamesAFormat() {
        #expect(entries([file("ar.tar.gz")]).contains(.extractArchive(.tarGz)))
        #expect(entries([file("notes.txt")]).contains { 
            if case .extractArchive = $0 { true } else { false }
        } == false)
    }

    @Test func extractIsNotOfferedForSeveralRows() {
        #expect(entries([file("a.zip"), file("b.zip")]).contains { 
            if case .extractArchive = $0 { true } else { false }
        } == false)
    }

    /// A bucket row still answers only `copyPath` — the rule at the top of
    /// `entries(for:…)`. Archiving must not reach around it.
    @Test func abucketRowGetsNoArchiveEntry() {
        let bucket = RemoteFileItem(
            name: "b", path: "/b", kind: .directory, isBucket: true)
        let offered = BrowserContextMenu.entries(
            for: [bucket], side: .remote, supportsArchiving: true,
            scope: .containerList)
        #expect(offered == [.copyPath])
    }
}
```

> **Note for the implementer:** `scope: .containerList` above stands for
> whatever `BrowserScope` value makes `isContainerRow(path:)` true in the
> existing bucket tests. Read `Tests/macSCPCoreTests` for the suite that
> already covers `BrowserContextMenu`'s bucket rule and reuse its spelling;
> do not invent a case.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ArchiveMenuEntriesTests`
Expected: FAIL — `type 'BrowserMenuEntry' has no member 'compressTo'`.

- [ ] **Step 3: Extend the Core model**

In `BrowserContextMenu.swift`, add to `BrowserMenuEntry`:

```swift
    case compressTo(ArchiveFormat)             // one per offered format; the App folds the run into one submenu
    case extractArchive(ArchiveExtractFormat)  // single row whose name names a format
```

Add the parameter to `entries(for:side:…)` — `supportsArchiving: Bool = false`,
documented like `supportsChecksum` is. **Declare it immediately after
`supportsChecksum` and before `scope`.** Swift requires arguments in
declaration order, and this suite calls
`entries(for:side:supportsArchiving:)` and
`entries(for:side:supportsArchiving:scope:)` — both of which compile only at
that position. Emit, immediately before
`entries.append(.delete)`:

```swift
        // The archive run, flat and in format order; the AppKit layer folds
        // it into one "Compress" submenu the way it folds the transfer run.
        // `.gz` compresses exactly one FILE and produces no container, so it
        // is offered only there — `ArchiveNaming.proposedName` refuses the
        // other cases and a menu entry whose only outcome is a refusal is
        // not an offer (the `computeChecksum` reasoning above).
        if supportsArchiving {
            entries.append(.compressTo(.zip))
            entries.append(.compressTo(.tarGz))
            if selection.count == 1, selection[0].kind == .file {
                entries.append(.compressTo(.gz))
            }
            // `kind == .file` added after Task 6's review, 2026-10-09. This
            // condition first checked only the count and the name, so a
            // FOLDER called `backup.zip` offered "Extract…" — an omission in
            // this plan rather than a choice. A directory is not an archive
            // whatever it is called, and `unzip`/`tar` would fail on it after
            // the user had already answered the destination dialog.
            if selection.count == 1, selection[0].kind == .file,
               let format = ArchiveExtractFormat.detected(inName: selection[0].name) {
                entries.append(.extractArchive(format))
            }
        }
```

- [ ] **Step 4: Render them in AppKit**

In `makeItem(_:selection:)`, add two cases. `.compressTo` is consumed by
`menuNeedsUpdate` like `.transferToSession` is, so its arm here asserts and
degrades, copying the existing placeholder shape at the top of that switch:

```swift
            case .compressTo:
                assertionFailure("compressTo is folded into one submenu in menuNeedsUpdate")
                let placeholder = NSMenuItem(
                    title: L10n.string("menu.compress", "Compress"), action: nil, keyEquivalent: "")
                placeholder.isEnabled = false
                return placeholder
            case .extractArchive:
                return actionItem(
                    title: L10n.string("menu.extract", "Extract…"), entry: entry, selection: selection)
```

In `menuNeedsUpdate`, fold the `.compressTo` run with a `makeCompressItem`
built on the same pattern as `makeTransferItem` (`:1123`–`:1147`): a parent
item titled `menu.compress`, whose submenu holds one `actionItem` per format
in the run, titled `archive.format.zip` / `archive.format.tarGz` /
`archive.format.gz`.

- [ ] **Step 5: Add the App catalogue keys, in four languages**

`en.lproj`:
```
"menu.compress" = "Compress";
"menu.extract" = "Extract…";
"archive.format.zip" = "ZIP Archive";
"archive.format.tarGz" = "Compressed Tarball";
"archive.format.gz" = "Compressed File";
```
`de.lproj` (du-Form, and these are nouns so the question does not arise here):
```
"menu.compress" = "Komprimieren";
"menu.extract" = "Entpacken…";
"archive.format.zip" = "ZIP-Archiv";
"archive.format.tarGz" = "Komprimiertes Tar-Archiv";
"archive.format.gz" = "Komprimierte Datei";
```
`fr.lproj`:
```
"menu.compress" = "Compresser";
"menu.extract" = "Extraire…";
"archive.format.zip" = "Archive ZIP";
"archive.format.tarGz" = "Archive tar compressée";
"archive.format.gz" = "Fichier compressé";
```
`pl.lproj`:
```
"menu.compress" = "Kompresuj";
"menu.extract" = "Wypakuj…";
"archive.format.zip" = "Archiwum ZIP";
"archive.format.tarGz" = "Skompresowane archiwum tar";
"archive.format.gz" = "Skompresowany plik";
```

> **Note for the implementer:** this repository has localization checks. Run
> the whole suite, not just the filter, and fix whatever they say about key
> coverage across the four catalogues before committing.

- [ ] **Step 6: Run the tests and the whole suite**

Run: `swift test --filter ArchiveMenuEntriesTests`, then `swift test`.
Expected: PASS, and no existing `BrowserContextMenu` case red — the new
parameter defaults to `false`, so every old call site keeps its menu.

- [ ] **Step 7: Commit**

```bash
git add Sources/macSCPCore/Presentation/BrowserContextMenu.swift Sources/MacSCPAppKit Tests/macSCPCoreTests/ArchiveMenuEntriesTests.swift
git commit -m "feat(archive): the context-menu entries, absent where a backend cannot run them"
```

---

### Task 7: The extract dialog, and the collision count it shows

**Files:**
- Create: `Sources/macSCPCore/Archive/ExtractPreview.swift`
- Create: `Sources/MacSCPAppKit/ExtractDestinationSheet.swift`
- **Not modified any more:** `Sources/macSCPCore/Archive/ArchiveCommandChannel.swift`.
  This line first read "(the seam gains its bounded listing requirement — see
  the note below)". Withdrawn: Task 4 delivered BOTH requirements, as this
  plan's own interfaces section told it to, and gave `listing(of:limit:)` a
  rig test as well. Task 7 only CALLS it. Its `limit` is in **bytes** — pass
  a byte bound, not an entry count, or a 300-entry archive's listing trips a
  bound meant as a number of entries.
- Modify: `Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
- Test: `Tests/macSCPCoreTests/ExtractPreviewTests.swift`

**Interfaces:**
- Consumes: Task 1's `ExtractDestination`, `ArchiveExtractFormat`,
  `ArchiveNaming.free(_:takenNames:)`; Task 2's `ArchivePlan`; Task 4's
  `ArchiveCommandChannel`.
- Produces: `ExtractPreview`, `ExtractPreview.make(…)`,
  `ArchivePlan.listing(of:format:workingDirectory:)`.

**Maintainer decision 5 built out.** The dialog offers this folder or a new
subfolder, with the subfolder's name prefilled from the archive and already
free. When extracting here would land on existing names, the dialog says how
many — and that count comes from a LISTING, because both skip-existing flags
are silent: measured 2026-10-08, `unzip -n` named only what it extracted and
`tar --keep-old-files` printed nothing, both exiting 0. Do not try to read the
count from the run.

The skip-existing flags stay on the "this folder" plan anyway (Task 2). They
are not the reporting mechanism; they are what keeps the promise when the
directory changes between the dialog and the run.

**`.gz` offers only "this folder".** `gunzip` writes one file beside the
archive and cannot be told a destination directory without a shell
redirection, which this design does not build. The sheet hides the subfolder
option for that format, and `ArchivePlan.extract` refuses the combination so
the rule is enforced below the UI as well as in it.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import macSCPCore

@Suite(.timeLimit(.minutes(1)))
struct ExtractPreviewTests {
    @Test func thelistingCommandForAZipAsksUnzipForNamesOnly() {
        let plan = ArchivePlan.listing(
            of: "ar.zip", format: .zip, workingDirectory: "/d")
        #expect(plan.tool == "unzip")
        #expect(plan.words == [.flag("-Z1"), .operand("./ar.zip")])
    }

    @Test func thelistingCommandForATarballAsksTarForNamesOnly() {
        let plan = ArchivePlan.listing(
            of: "ar.tar.gz", format: .tarGz, workingDirectory: "/d")
        #expect(plan.tool == "tar")
        #expect(plan.words == [.flag("-tzf"), .operand("./ar.tar.gz")])
    }

    /// A `.gz` holds exactly one file and no listing tool is needed: the
    /// name is the archive's own, minus the extension.
    @Test func agzNeedsNoListingBecauseItsOneEntryIsItsName() {
        let preview = ExtractPreview.make(
            archiveName: "big.log.gz", format: .gz,
            archiveEntries: nil, namesInFolder: ["big.log"])
        #expect(preview.entryCount == 1)
        #expect(preview.collidingHere == 1)
        #expect(preview.allowsSubfolder == false)
    }

    @Test func theCollisionCountIsTheOverlapWithTheFolder() {
        let preview = ExtractPreview.make(
            archiveName: "ar.zip", format: .zip,
            archiveEntries: ["a", "b", "c/d"], namesInFolder: ["a", "z"])
        #expect(preview.entryCount == 3)
        #expect(preview.collidingHere == 1)
        #expect(preview.allowsSubfolder)
    }

    /// An entry inside the archive's own subdirectory collides on its TOP
    /// component, because that is what extraction creates in this folder.
    @Test func anEntryDeepInTheArchiveCollidesOnItsTopComponent() {
        let preview = ExtractPreview.make(
            archiveName: "ar.zip", format: .zip,
            archiveEntries: ["top/", "top/a", "top/b"], namesInFolder: ["top"])
        #expect(preview.collidingHere == 1)
    }

    @Test func theProposedSubfolderDropsTheExtensionAndIsFree() {
        let preview = ExtractPreview.make(
            archiveName: "backup.tar.gz", format: .tarGz,
            archiveEntries: ["a"], namesInFolder: ["backup", "backup 2"])
        #expect(preview.proposedSubfolder == "backup 3")
    }

    @Test func agzRefusesASubfolderPlanBelowTheUserInterfaceToo() {
        #expect(throws: ArchiveRefusal.gzExtractsIntoThisFolderOnly) {
            try ArchivePlan.extract(
                RemoteFileItem(name: "f.gz", path: "/d/f.gz", kind: .file),
                format: .gz, workingDirectory: "/d", into: .subfolder("f"))
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ExtractPreviewTests`
Expected: FAIL — `cannot find 'ExtractPreview' in scope`.

- [ ] **Step 3: Write `ExtractPreview.swift`**

```swift
import Foundation

/// What the destination dialog needs to know before anything is extracted.
///
/// Pure. The two inputs are the archive's entry names — from a listing the
/// caller already ran, or `nil` for a `.gz`, whose single entry is its own
/// name — and the names the pane is already showing. Both are data the
/// caller has; this type runs nothing.
public struct ExtractPreview: Sendable, Equatable {
    /// How many entries the archive holds.
    public let entryCount: Int
    /// How many of them would land on a name this folder already has.
    /// Counted on the TOP path component, because that is what extraction
    /// creates here.
    public let collidingHere: Int
    /// The free subfolder name to prefill.
    public let proposedSubfolder: String
    /// `false` for `.gz`: `gunzip` cannot be told a directory without a
    /// shell redirection this design does not build.
    public let allowsSubfolder: Bool

    public static func make(
        archiveName: String, format: ArchiveExtractFormat,
        archiveEntries: [String]?, namesInFolder: Set<String>
    ) -> ExtractPreview {
        let stem = Self.stem(of: archiveName, format: format)
        let entries = archiveEntries ?? [stem]
        let tops = Set(entries.compactMap { entry -> String? in
            let top = entry.split(separator: "/").first.map(String.init)
            return top?.isEmpty == false ? top : nil
        })
        return ExtractPreview(
            entryCount: entries.count,
            collidingHere: tops.intersection(namesInFolder).count,
            proposedSubfolder: ArchiveNaming.free(stem, takenNames: namesInFolder),
            allowsSubfolder: format != .gz)
    }

    /// `archiveName` without the extension its format implies. `.tgz` is
    /// handled as well as `.tar.gz`, since both detect as `.tarGz`.
    private static func stem(of name: String, format: ArchiveExtractFormat) -> String {
        let candidates: [String]
        switch format {
        case .zip: candidates = [".zip"]
        case .tar: candidates = [".tar"]
        case .tarGz: candidates = [".tar.gz", ".tgz"]
        case .gz: candidates = [".gz"]
        }
        let lower = name.lowercased()
        for suffix in candidates where lower.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }
}

extension ArchivePlan {
    /// The plan that asks an archive what it holds, one entry per line.
    ///
    /// `unzip -Z1` and `tar -tzf` each print exactly that (measured
    /// 2026-10-08). This is the only archive plan whose STANDARD OUTPUT is
    /// read, which is why the channel's listing method is bounded and this
    /// one is not run through `ArchiveRunner`.
    public static func listing(
        of archiveName: String, format: ArchiveExtractFormat, workingDirectory: String
    ) -> ArchivePlan {
        let source = ArchiveWord.operand("./" + archiveName)
        switch format {
        case .zip:
            return ArchivePlan(
                operation: .extract(format), workingDirectory: workingDirectory,
                tool: "unzip", words: [.flag("-Z1"), source], stdin: nil)
        case .tar, .tarGz:
            return ArchivePlan(
                operation: .extract(format), workingDirectory: workingDirectory,
                tool: "tar", words: [.flag(format == .tarGz ? "-tzf" : "-tf"), source],
                stdin: nil)
        case .gz:
            // Never used: `ExtractPreview.make` is given `nil` entries for
            // this format and derives the one name itself. Returning a plan
            // that lists the archive's own name keeps the function total
            // rather than trapping.
            return ArchivePlan(
                operation: .extract(format), workingDirectory: workingDirectory,
                tool: "gzip", words: [.flag("-l"), .flag("--"), source], stdin: nil)
        }
    }
}
```

- [ ] **Step 4: ~~Give the seam its bounded listing~~ — already done in Task 4**

Withdrawn, not deleted, so the task numbering and the reasoning stay
readable. This step said to add a second requirement to
`ArchiveCommandChannel` and to update the fakes in two test files. Task 4
wrote both requirements and both conformances, plus rig coverage for the
listing, so there is nothing to add here. What remains for Task 7 is to CALL
`listing(of:limit:)` with a byte bound.

<details><summary>The withdrawn step, kept for the record</summary>

`ArchiveCommandChannel` (Task 4) gains a second requirement:

```swift
    /// The STANDARD OUTPUT of a listing line, one entry per element,
    /// bounded. The bound exists because an archive can hold millions of
    /// entries and this output is read into memory; past it the channel
    /// throws rather than truncating, since a truncated listing would
    /// under-report collisions, which is the one direction this feature
    /// must not be wrong in.
    func listing(of line: ArchiveCommandLine, limit: Int) async throws -> [String]
```

Conform `CitadelFileSystem` using the EXISTING
`client.collectingStandardOutput(of:limit:)` plumbing
(`Sources/macSCPCore/SSH/CitadelFileSystem.swift`, used by
`standardOutput(of line: ChecksumCommandLine)` at `:1666`) and split on
newlines. Add the method to `RecordingArchiveChannel` and
`FailingArchiveChannel` in the test files, and to a `LocalArchiveChannel` the
local pane uses — the local side reaches the same listing through
`SubprocessRunner.run`'s `stdout`.

</details>

- [ ] **Step 4c: The LOCAL listing, which nothing delivers yet**

Added 2026-10-09, after measuring: `grep -rn 'func listing(' Sources/` prints
exactly two lines, the protocol requirement and `CitadelFileSystem`'s
conformance. **There is no local listing path at all** —
`LocalArchiveRunner` has only `run`. The dialog needs an archive's entries on
BOTH panes, so this is a gap in this plan rather than something Task 4 left
out, and it is closed here.

Give `LocalArchiveRunner` a method with the same shape as the channel's:

```swift
    /// The entries `plan` lists, one per element, bounded in BYTES of
    /// standard output.
    ///
    /// Same contract as `ArchiveCommandChannel.listing(of:limit:)`, and the
    /// same reason for the bound: an archive can hold millions of entries and
    /// this output is read into memory. Past the bound it THROWS rather than
    /// truncating, because a truncated listing under-reports collisions, and
    /// that is the one direction this feature must not be wrong in.
    func listing(_ plan: ArchivePlan, limit: Int) async throws -> [String]
```

built on `SubprocessRunner.run` over `plan.localInvocation(…)`, splitting
`stdout` on newlines and dropping empties. A non-zero status is an
`ArchiveFailure` exactly as `run` maps it. Test it against a real `zip` in a
temporary directory, and test the bound by listing an archive whose entry
names exceed a deliberately tiny limit — the refusal is the property, not the
number.

- [ ] **Step 5: Build the sheet**

`ExtractDestinationSheet.swift`, following whichever sheet pattern this
repository already uses for a small modal choice — read
`Sources/MacSCPAppKit/PresignedURLSheet.swift` and match it. Content: a
radio pair (this folder / a new subfolder with an editable prefilled name),
the entry count, and, when `collidingHere > 0`, a line naming it. The
subfolder option is disabled when `allowsSubfolder` is `false`. Keys:

`en.lproj`:
```
"archive.extract.title" = "Extract Archive";
"archive.extract.here" = "Into this folder";
"archive.extract.subfolder" = "Into a new folder:";
"archive.extract.entries" = "archive.extract.entries";
"archive.extract.collisions" = "archive.extract.collisions";
"archive.extract.gzHereOnly" = "A compressed file is always extracted into this folder.";
```
The two counted lines are PLURALS and belong in
`Localizable.stringsdict` beside the catalogue, not in it. Measured
2026-10-08 against the existing files, so the shape is copied rather than
guessed: all four languages hold **14** plural entries
(`grep -c 'NSStringLocalizedFormatKey' Sources/MacSCPAppKit/Resources/<l>.lproj/Localizable.stringsdict`),
`en`, `de` and `fr` use `one`/`other` throughout, and `pl` uses
`one`/`few`/`many` —

```
grep -o '<key>\(zero\|one\|two\|few\|many\|other\)</key>' Sources/MacSCPAppKit/Resources/pl.lproj/Localizable.stringsdict | sort | uniq -c
```

printed `14 few`, `14 many`, `14 one` and **`8 other`**. So six of the
existing Polish entries carry no `other` at all. **Write the new entries with
`one`/`few`/`many`/`other`** — the shape the 8 use, not the 6: a Polish
plural without `other` has no rule left for a fractional or unmatched count.
The German addresses the user as **du**.

- [ ] **Step 6: Run the tests and the whole suite**

Run: `swift test --filter ExtractPreviewTests`, then `swift test`.
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/macSCPCore/Archive Sources/MacSCPAppKit Tests/macSCPCoreTests/ExtractPreviewTests.swift
git commit -m "feat(archive): the extract dialog, and a collision count no tool would report"
```

---

### Task 8: The per-pane progress model, and the wiring

**Files:**
- Create: `Sources/macSCPCore/Archive/ArchiveActivity.swift`
- Modify: `Sources/MacSCPAppKit/ContentView+Detail.swift` (the
  `onMenuAction` call site that already keys off `action.id` at `:553`)
- Modify: `Sources/MacSCPAppKit/BrowserPane.swift` (the activity row)
- Test: `Tests/macSCPCoreTests/ArchiveActivityTests.swift`

**Interfaces:**
- Consumes: every earlier task.
- Produces: `ArchiveActivity` (an `@Observable` or `ObservableObject` to
  match this repository's other pane models — read `BrowserPane.swift` and
  follow it), with `state: ArchiveActivity.State`, `start(_:runner:)` and
  `cancel()`.

**Maintainer decision 3 built out.** At most one archive operation per pane.
A non-modal row in the pane shows the title and a cancel; cancelling cancels
the task, which closes the exec channel or terminates the child. On
completion the pane reloads its listing. **The transfer queue is not
touched** — `TransferQueueViewModel.Item.Status` stays byte-shaped.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import macSCPCore

@Suite(.timeLimit(.minutes(1)))
struct ArchiveActivityTests {
    /// A runner that parks until the test releases it, so the running state
    /// can be read WHILE it is running. Parked on a continuation, awaited —
    /// never a semaphore, which would block a cooperative thread.
    private actor ParkedRunner: ArchiveRunner {
        private var release: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?
        func whenStarted() async { await withCheckedContinuation { started = $0 } }
        func releaseNow() { release?.resume(); release = nil }
        func run(_ plan: ArchivePlan) async throws -> ArchiveOutcome {
            started?.resume(); started = nil
            await withCheckedContinuation { release = $0 }
            return .finished
        }
    }

    @Test func apaneRunsOneOperationAndReportsItWhileItRuns() async throws {
        let activity = ArchiveActivity()
        let runner = ParkedRunner()
        let plan = try ArchivePlan.compress(
            .zip, selection: [RemoteFileItem(name: "a", path: "/d/a", kind: .file)],
            workingDirectory: "/d", archiveName: "out.zip")

        activity.start(plan, runner: runner)
        await runner.whenStarted()
        // Read BEFORE the healing: once the runner is released the state
        // reaches `.idle` and this assertion would pass over a model that
        // never reported running at all.
        #expect(activity.state == .running(title: "out.zip"))

        await runner.releaseNow()
        try await activity.waitUntilIdle()
        #expect(activity.state == .idle)
    }

    @Test func asecondOperationIsRefusedWhileOneRuns() async throws {
        let activity = ArchiveActivity()
        let runner = ParkedRunner()
        let plan = try ArchivePlan.compress(
            .zip, selection: [RemoteFileItem(name: "a", path: "/d/a", kind: .file)],
            workingDirectory: "/d", archiveName: "out.zip")
        activity.start(plan, runner: runner)
        await runner.whenStarted()
        #expect(activity.start(plan, runner: runner) == false)
        await runner.releaseNow()
        try await activity.waitUntilIdle()
    }

    @Test func cancellingEndsItAsCancelledAndNotAsAFailure() async throws {
        let activity = ArchiveActivity()
        let runner = ParkedRunner()
        let plan = try ArchivePlan.compress(
            .zip, selection: [RemoteFileItem(name: "a", path: "/d/a", kind: .file)],
            workingDirectory: "/d", archiveName: "out.zip")
        activity.start(plan, runner: runner)
        await runner.whenStarted()
        activity.cancel()
        try await activity.waitUntilIdle()
        #expect(activity.lastOutcome == .cancelled)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ArchiveActivityTests`
Expected: FAIL — `cannot find 'ArchiveActivity' in scope`.

- [ ] **Step 3: Write `ArchiveActivity.swift`**

One operation at a time: `start` returns `false` when one is already
running. `cancel()` cancels the stored `Task`. `waitUntilIdle()` is an
`await` over a continuation the finishing task resumes — the test helper this
suite needs, and it must be an `await`, never a poll and never a sleep.
`state` is `.idle` or `.running(title:)`; `lastOutcome` keeps
`.finished`/`.cancelled` or the `ArchiveFailure`, so the pane can show one
sentence. Map `ArchiveFailure` to catalogue keys: `.toolMissing(tool:)` to
`archive.error.toolMissing`, `.exited(status:)` to `archive.error.exited`,
and **`.timedOut` to `archive.error.timedOut`** — in en, de, fr and pl, with
the German in du-form. **No tool output goes into any of them** — a far
side's text is not ours to pass on.

**Added after Task 5, 2026-10-08.** This step first named two cases only.
`.timedOut` did not exist when the plan was written; Task 5's review found
that a local cancel or timeout never became `.cancelled` at all, because
`SubprocessRunner.run` THROWS `SubprocessCancelled`/`SubprocessTimeout`, and
that both those types' `description` embeds "stderr so far: <text>" — so the
fix catches both, returns `.cancelled` for a cancel, and adds a payload-free
`.timedOut` for the timeout. A third key is owed, and a switch over
`ArchiveFailure` that still has two arms will not compile.

- [ ] **Step 4: Wire it**

At the `onMenuAction` site in `ContentView+Detail.swift`, handle the two new
entries: build the plan (`ArchiveNaming.proposedName` →
`ArchiveNaming.free(_:takenNames:)` over the names the pane holds →
`ArchivePlan.compress`), choose the runner, and hand it to the pane's
`ArchiveActivity`.

**Corrected after Task 5, 2026-10-08.** The runner choice first read
"(`fs as? ArchiveCommandChannel` → `RemoteArchiveRunner`, local pane →
`LocalArchiveRunner`)". Withdrawn: that `as?` cannot compile from the App
target, because `ArchiveCommandChannel` is internal to macSCPCore. Use
`RemoteArchiveRunner(backend: fs)` — a failable initializer that does the
capability question inside Core — and `LocalArchiveRunner()` for the local
pane. For `.extractArchive`, run the listing plan
first, build the `ExtractPreview`, show the sheet, and start the plan the
sheet's answer names. Reload the listing when the activity goes idle.

Surface every `ArchiveRefusal` as the sheet or an alert, through the
catalogue — the refusals are all user-facing, which is why they carry names
rather than numbers.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS. Do **not** launch the app.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore/Archive/ArchiveActivity.swift Sources/MacSCPAppKit Tests/macSCPCoreTests/ArchiveActivityTests.swift
git commit -m "feat(archive): one operation per pane, cancellable, outside the transfer queue"
```

---

### Task 9: Closeout — the backlog row and the user documentation

**Files:**
- Modify: `docs/BACKLOG.md`
- Create: `/Users/noidee/_dev/noix-docs/src/content/docs/macscp/guide/archives.md`

- [ ] **Step 1: Close the backlog row**

Correct the "Custom actions in the file context menu" row in place, quoting
what it withdraws. It says **"Not started."** and describes both halves; the
archive half is now done and the builder half is not, so the row must say
exactly that — and the withdrawal quotes the two words it replaces. Name the
commits, the spec, this plan, and the measured facts a later reader would
otherwise have to re-derive (the `zip -@` newline limit, the two silent skip
flags, `gzip -k`'s own refusal).

Every figure gets the command that produced it, the command must run in the
form it is committed (a `docs/BACKLOG.md` cell takes **no pipe** — several
`-e` patterns instead), and **run it again after writing the sentence**.

- [ ] **Step 2: Write the user documentation**

In a **git worktree of `noix-docs` on its own branch** — the repository is
shared with other products and other sessions, so never work on a branch or
a working tree someone else has open. One page under `guide/`, following
`reference/contributing-docs.md`. It must say: where the entries are, which
formats, that extraction asks where to put things, that nothing is
overwritten, and that a server without `zip` says so. Mark the feature as
**coming in the next version**. **No tech-stack terms** — no SSH, no SFTP,
no `zip -@`, no exec channel; this is a public text.

Then `npm run build` and `npm run check`, both of which must pass. Do not
push or merge: the maintainer asks for that.

- [ ] **Step 3: Commit (both repositories, separately)**

```bash
git add docs/BACKLOG.md
git commit -m "docs(backlog): the archive half of the context-menu row, closed from the diff"
```

---

## Self-review

Run after the last task, by the coordinator, not a subagent:

1. **Spec coverage.** Each of the spec's sections against a task: formats and
   refusals → 1; the plan value → 2; the remote line and quoting → 3; the
   seam → 4; the runners and exit 127 → 5; the menu and the gate → 6; the
   dialog, collisions and the never-overwrite rule → 7; progress and
   cancellation → 8; the record and the docs → 9.
2. **The spec's corrections honoured.** `ArchiveCommandChannel`, not
   `RemoteCommandRunner`; `PosixQuoting.singleQuoted` reused, not
   re-implemented. `grep -rn 'RemoteCommandRunner' Sources/ Tests/` must
   print nothing, and `grep -rc 'PosixQuoting' Sources/macSCPCore/Archive/`
   must print a non-zero count for `ArchiveCommandLine.swift` — the positive
   beside that negative.
3. **No second quoting helper.** `grep -rn "'\\\\''" Sources/macSCPCore/Archive/`
   must print nothing: that escape belongs to `PosixQuoting` alone.
4. **No wall-clock ceiling got in.**
   `grep -rn 'elapsed <' Tests/macSCPCoreTests/Archive*` must print nothing.

---

### Task 10: The Citadel fork gains a stdin half-close

**Runs BEFORE Task 4.** Numbered 10 so every cross-reference above keeps
pointing at the task it means.

**Repositories:** a clone of `https://github.com/NoiXdev/Citadel` (none
exists on this machine yet — make it outside `/Users/noidee/macSCP`, e.g.
`/Users/noidee/_dev/Citadel`), plus `Package.swift` here.

**Files:**
- In the fork: `Sources/Citadel/TTY/Client/TTY.swift` (`TTYStdinWriter`, and
  `withExec`'s `catch`), plus a test in the fork's own suite.
- Here: `Package.swift` (the `exact:` pin) and
  `docs/superpowers/specs/2026-08-20-backlog-dependencies.md` (the fork
  record).

**What the change is.** Two things, both measured as missing:

1. `TTYStdinWriter` gains a public method that half-closes the channel's
   outbound side, so a tool reading standard input sees end-of-input while
   the inbound half stays open for the remaining output and the exit status.
   In NIO terms that is a channel `close(mode: .output)`; check what the
   handler chain actually supports before settling on a spelling.
2. `withExec`'s `catch` calls `close()` and then rethrows, so a channel the
   far side already closed throws `ChannelError.alreadyClosed` OVER the
   `CommandFailed` that carries the exit status — which would hide exit 127
   from `isToolMissing`. The original error must survive.

- [ ] **Step 1: The fork debt check, BEFORE touching anything**

CLAUDE.md requires this at every fork change, and requires the numbers to be
written down even when they are zero. In the fork clone:

```bash
git remote add upstream https://github.com/orlandos-nl/Citadel.git
git fetch upstream
git log --oneline 0.12.1..upstream/main
gh api repos/orlandos-nl/Citadel/security-advisories
```

Classify every commit security / correctness / feature / noise. **A security
commit upstream is cherry-picked FIRST, before any feature work.** Then
answer, in the report: can the fork be retired — does upstream now carry
what it carries? Write the count and the date into the fork record either
way.

- [ ] **Step 2: Write the failing test in the fork's own suite**

A test that writes bytes, half-closes, and asserts the command both
terminated and reported its status. Follow the fork's existing test style;
do not import anything from macSCP.

- [ ] **Step 3: Run it to see it fail**

Expected: the command never terminates, or the status is missing. Quote the
exact failure.

- [ ] **Step 4: Implement both halves, and run the fork's whole suite**

Green, and quoted in the report.

- [ ] **Step 5: Verify against macSCP WITHOUT pushing**

Point this repository's `Package.swift` at the local clone
(`.package(path: "/Users/noidee/_dev/Citadel")`) **as a temporary local
edit you do not commit**, run `swift build`, and confirm the half-close is
reachable from `CitadelFileSystem`. Then put the `exact:` pin back.

- [ ] **Step 6: STOP and report**

Pushing a branch and a tag to `NoiXdev/Citadel`, and opening a PR against
`orlandos-nl/Citadel`, are outward-facing actions on a shared repository.
Do them only on the maintainer's explicit go-ahead. Report: the upstream
count and date, the retirement answer, the observed red, the green, what the
half-close is spelled as, and that nothing was pushed.

- [ ] **Step 7: After the go-ahead — tag, pin, record**

Tag `0.12.1-noix.4`, push it, bump the `exact:` pin here with a comment
saying what the tag carries and why, open the upstream PR, and write the
tag, the PR and the measurements into the fork record. Every fork change is
reviewed like code here: red first, the fork's own suite green, a real
observed red in the commit message, and **no fabricated hash**.

---

### Task 11: The rig image gains the archive tools

**Runs BEFORE Task 4**, and is independent of Task 10.

**Files:**
- Modify: `docker/test-server/` — whatever file builds or configures the
  `sshd` service (read the compose file first; the service may need a small
  Dockerfile where it currently uses an image directly).
- Modify: `docker/test-server/README.md` — the rig's own record.

**What is missing, measured 2026-10-08 in the running `sshd` container:**

| tool | state |
|---|---|
| `zip` | **absent** |
| `tar` | BusyBox 1.37.0 — rejects `--null` ("unrecognized option: null", exit 1) |
| `unzip` | `/usr/bin/unzip` |
| `gzip` | `/bin/gzip` |
| `gunzip` | `/bin/gunzip` |

The image is `lscr.io/linuxserver/openssh-server`, which is Alpine-based, so
`zip` and GNU `tar` are `apk add zip tar` away — but confirm that rather than
assume it, and prefer the image's own documented way of installing extra
packages over a hand-rolled Dockerfile if one exists.

- [ ] **Step 1: Add the packages**

- [ ] **Step 2: Recreate the service and measure, from the MAIN checkout only**

```bash
docker compose -f docker/test-server/compose.yml up -d --force-recreate sshd
docker compose -f docker/test-server/compose.yml exec -T sshd sh -c 'command -v zip unzip gzip gunzip tar; tar --version | head -1'
```

Expected: all five present, and `tar --version` naming GNU tar rather than
BusyBox.

- [ ] **Step 3: Prove `--null` and `-@` now work there**

```bash
docker compose -f docker/test-server/compose.yml exec -T sshd sh -c 'cd /tmp && rm -rf p && mkdir p && cd p && printf x > a && printf "y" > "b'"'"'c" && printf "a\0b'"'"'c\0" | tar --null -T - -czf ../p.tgz && tar -tzf ../p.tgz && printf "a\nb'"'"'c\n" | zip -q -@ ../p.zip && unzip -Z1 ../p.zip'
```

Expected: both listings naming `a` and `b'c`. Quote the output.

- [ ] **Step 4: Record it in the rig's README**

What was added, why, and the measurement above. `docker/test-server/README.md`
is the rig's own record, and the next person to rebuild the image reads it
rather than this plan.

- [ ] **Step 5: Verify the existing gated suites still pass**

```bash
MACSCP_ITEST=1 swift test
```

A changed image must not break the rig suites that already use it. Quote the
result.

- [ ] **Step 6: Commit**

```bash
git add docker/test-server
git commit -m "test(rig): the archive tools the remote half needs"
```
