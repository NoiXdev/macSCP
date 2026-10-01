# The typed-findings tails — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the seven `docs/BACKLOG.md` rows the typed-findings plan left
behind on 2026-09-28, and three stale spots in that file.

**Architecture:** Six of the seven items are questions about one type,
`RemoteFSFinding`, and the two conditions it does not yet name. Four tasks
add a test where a claim was unpinned (T1, T5, T6) or type a condition that
was written out in prose (T3); one adds a finding for a case whose sentence
is currently wrong (T2); one records a decision in a comment (T4); one closes
the rows (T7).

**Tech Stack:** Swift 6 (`swiftLanguageMode(.v6)`), SwiftPM, Swift Testing
(`@Test`/`#expect`), macOS 15 minimum. Spec:
`docs/superpowers/specs/2026-10-01-typed-findings-tails-design.md`.

**Worktree:** `/Users/noidee/macSCP/.claude/worktrees/typed-findings-tails`,
branch `typed-findings-tails`, base `develop` at `0f55446d`. Run everything
from the worktree; never `cd` to `/Users/noidee/macSCP`.

## Global Constraints

- **Build and test:** `swift test --build-system native`. The default build
  system fails on SwiftTerm's `Shaders.metal`.
- **Code and comments: English only.** No German in source files.
- **Never hardcode a display string.** User-facing text goes through
  `CoreL10n.string(_:)` in Core, `L10n.string(_:_:)` / `L10n.text(_:_:)` in
  the App.
- **Four catalogues, always together:** `en` (the source text), `de`, `fr`,
  `pl`, under `Sources/macSCPCore/Resources/<locale>.lproj/Localizable.strings`.
  The German catalogue addresses the user as **du**;
  `GermanAddressFormTests` holds it to that.
- **No `default:` in any switch over `RemoteFSFinding` or its `Name`** — a
  finding added later must decide every question explicitly.
- **Tests never block the cooperative pool:** no `syncShutdownGracefully()`,
  no `futureResult.wait()`, no `DispatchSemaphore.wait()`. Every wait is an
  `await`.
- **No wall-clock ceiling in a test.** A floor (`elapsed >= …`) is allowed; an
  upper bound on elapsed time is not. Nothing in this plan measures time.
- **No `#require` on a non-optional.**
- **A negative check needs a positive check beside it**, asserting that the
  thing it scans is there at all.
- **Source-scanning guards read comments too.** Scan through
  `SourceCorpus.code(of:)`, which blanks comments and string literals, not
  raw file text.
- **Writing a number into a comment means counting it in that same moment.**
- **Every scripted replacement asserts its anchor before writing**
  (`assert old in s`, or the language's equivalent).
- **A report is written from the diff, never from the intent.**
- **Commit footer on every commit:**
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`
- **Conventional Commits**, English, enforced by CI.
- **Do not push.** The coordinator pushes after the final whole-branch review.
- **Do not launch the GUI or the app binary.**
- **No secret anywhere:** not in a store, state, log, `reason:`, notification
  text, report, row, or test-failure message.

---

## File structure

| File | Responsibility | Task |
|---|---|---|
| `Tests/macSCPCoreTests/RemoteFileSystemAppendResumeGuardTests.swift` | **new** — pins each conformer's `supportsAppendResume` and the conformer count | T1 |
| `Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift` | the permanence of `false`; the new finding at two readers' expense; the stream-pair seam | T1, T2, T5 |
| `Sources/macSCPCore/RemoteFS/RemoteFSFinding.swift` | the new case and its seven arms; the reachability argument | T1, T2 |
| `Sources/macSCPCore/WebDAV/WebDAVPropfindParser.swift` | which finding each of three readers throws | T2 |
| `Sources/macSCPCore/Resources/{en,de,fr,pl}.lproj/Localizable.strings` | the new finding's four sentences | T2 |
| `Tests/macSCPCoreTests/WebDAVPropfindParserTests.swift` | the per-reader finding | T2 |
| `Sources/macSCPCore/S3/S3FileSystem.swift` | types the listing condition it describes | T3 |
| `Sources/macSCPCore/S3/S3MultipartXML.swift` | records the two provenances as a decision | T4 |
| `Tests/macSCPCoreTests/WebDAVFileSystemWriteTests.swift` | the first test to reach `uploadStreamUnavailable` | T5 |
| `Tests/macSCPCoreTests/RemoteFSFindingTests.swift` | `everySample` as the one source of representative values; the catalogue anchor | T6 |
| `docs/BACKLOG.md` | the seven rows closed, three stale spots corrected | T7 |

---

## Task 1: `supportsAppendResume` pinned per conformer

Closes the open half of the row at `docs/BACKLOG.md:172`
(`RemoteFSFinding.resumeNotSupported` has no reader) and the row at `:177`
(`readsAsConnectionFailure` decides two questions).

**Files:**
- Create: `Tests/macSCPCoreTests/RemoteFileSystemAppendResumeGuardTests.swift`
- Modify: `Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift:417`
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFSFinding.swift:237-247`

**Interfaces:**
- Consumes: `SourceCorpus.code(of:)` and `SourceCorpus.url(of: .sources)`
  from `Tests/MacSCPTestSupport/SourceCorpus.swift`; `LocalFileSystem()`
  (all parameters defaulted, `LocalFileSystem.swift:85`);
  `WebDAVFileSystem(config:transport:)` (internal test seam,
  `WebDAVFileSystem.swift:11`).
- Produces: nothing later tasks consume.

**Background the implementer needs.** `supportsAppendResume` is declared at
`Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift:131` and given a default
of `true` in a protocol extension at `:207`. A conformer that does not
override is therefore appendable **by silence**. Counted 2026-10-01, six
types conform in `Sources/`:

| type | file:line | answer | how |
|---|---|---|---|
| `S3FileSystem` | `S3/S3FileSystem.swift:45` | `false` | overrides at `:927` |
| `WebDAVFileSystem` | `WebDAV/WebDAVFileSystem.swift:6` | `false` | overrides at `:417` |
| `LocalFileSystem` | `RemoteFS/LocalFileSystem.swift:8` | `true` | extension default |
| `CitadelFileSystem` | `SSH/CitadelFileSystem.swift:38` | `true` | extension default |
| `ThroughputPayload` | `Diagnostics/ThroughputProbe.swift:581` | `true` | extension default |
| `ThroughputSink` | `Diagnostics/ThroughputProbe.swift:638` | `true` | extension default |

`CitadelFileSystem` needs a live SSH connection and `S3FileSystem` only has a
`private init` plus an async `connect`, so neither is cheap to instantiate in
a unit test. The guard therefore has two halves: real instances for the two
that are cheap, and a source scan for the set of conformers and the set of
overriders.

- [ ] **Step 1: Write the guard**

Create `Tests/macSCPCoreTests/RemoteFileSystemAppendResumeGuardTests.swift`:

```swift
import Foundation
import MacSCPTestSupport
import Testing
@testable import macSCPCore

/// `supportsAppendResume` is defaulted to `true` in a protocol extension
/// (`RemoteFileSystem.swift:207`), so a conformer that does not override it
/// is appendable BY SILENCE. Two things follow, and this suite pins both.
///
/// 1. `WebDAVFileSystem` answers `false`, which is why
///    `RemoteFSFinding.resumeNotSupported` — thrown at
///    `WebDAVFileSystem.swift:450` when `mode != .overwrite` — has no
///    production path to a reader: `TransferEngine` writes `.append` only
///    when `effectiveResume` is true, and that needs
///    `destination.supportsAppendResume` (`TransferEngine.swift:182`). The
///    throw is defence in depth. That PAIR is what `docs/BACKLOG.md` records
///    as pinned by nothing: a WebDAV that later answered `true` would make
///    the finding live with nothing announcing it. The first test below is
///    the announcement.
/// 2. An S3 redirect refusal cannot be classified resumable, because an
///    upload's destination is S3 and S3 answers `false` — the third gate in
///    `TransferQueueViewModel.swift:1231`. See
///    `RemoteFSFinding.readsAsConnectionFailure` for the whole argument.
///
/// The source half exists because `CitadelFileSystem` needs a live
/// connection and `S3FileSystem` has only a `private init` and an async
/// `connect`, so neither can be instantiated here. It is read through
/// `SourceCorpus.code(of:)`, which blanks comments and string literals, so a
/// comment quoting a conformance or an override can neither satisfy nor trip
/// it (CLAUDE.md, "Source-scanning guards read comments too").
@Suite("RemoteFileSystem append-resume")
struct RemoteFileSystemAppendResumeGuardTests {
    /// The two conformers a unit test can build, by their real answers.
    @Test func theTwoConstructibleBackendsAnswerWhatTheQueueReads() throws {
        #expect(LocalFileSystem().supportsAppendResume == true)

        let config = WebDAVConnectionConfig(
            baseURL: "https://dav.example.com/dav", username: "u",
            useNextcloudPath: false, password: "p")
        let webdav = WebDAVFileSystem(config: config, transport: FakeHTTPTransport(replies: []))
        #expect(webdav.supportsAppendResume == false)
    }

    /// Every conformer, and every override, by name — so a seventh conformer
    /// that inherits `true` in silence turns this red instead.
    ///
    /// Both checks are POSITIVE: a set that must match, not an absence. An
    /// emptied-out scan fails them rather than reading as satisfied
    /// (CLAUDE.md, "Guards that name what they watch").
    @Test func exactlyTheseTypesConformAndExactlyTheseOverride() throws {
        var conformers: Set<String> = []
        var overriders: [String: String] = [:]

        let sources = SourceCorpus.url(of: .sources)
        for url in try SourceCorpus.files(under: sources)
        where url.pathExtension == "swift" {
            let code = try SourceCorpus.code(of: url)
            for line in code.split(separator: "\n", omittingEmptySubsequences: true) {
                let text = String(line)
                if let name = Self.conformerName(in: text) { conformers.insert(name) }
                if text.contains("var supportsAppendResume"),
                   let owner = Self.enclosingTypeName(of: url, before: text, in: code) {
                    overriders[owner] = text.contains("true") ? "true" : "false"
                }
            }
        }

        #expect(conformers == [
            "S3FileSystem", "WebDAVFileSystem", "LocalFileSystem",
            "CitadelFileSystem", "ThroughputPayload", "ThroughputSink",
        ], """
            The set of RemoteFileSystem conformers in Sources/ changed. A new \
            conformer inherits supportsAppendResume == true from the protocol \
            extension (RemoteFileSystem.swift:207) unless it overrides. Decide \
            its answer, then add it here. Found: \
            \(conformers.sorted().joined(separator: ", "))
            """)

        #expect(overriders == ["S3FileSystem": "false", "WebDAVFileSystem": "false"], """
            The set of supportsAppendResume overrides changed. Found: \
            \(overriders.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }
                .joined(separator: ", "))
            """)
    }

    /// The declared type name on a line that conforms to `RemoteFileSystem`,
    /// or `nil`. Keyed on the declaration keywords so a mere mention of the
    /// protocol does not count.
    private static func conformerName(in line: String) -> String? {
        guard line.contains("RemoteFileSystem"), line.contains(":"),
              line.contains("class ") || line.contains("struct ") || line.contains("actor ")
        else { return nil }
        let afterKeyword = line.components(separatedBy: CharacterSet(charactersIn: " "))
        guard let index = afterKeyword.firstIndex(where: {
            $0 == "class" || $0 == "struct" || $0 == "actor"
        }), afterKeyword.index(after: index) < afterKeyword.endIndex else { return nil }
        let name = afterKeyword[afterKeyword.index(after: index)]
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return name.isEmpty ? nil : name
    }

    /// The nearest preceding type declaration in the same file — enough to
    /// attribute an override, because no file here declares two conformers
    /// that both override.
    private static func enclosingTypeName(
        of url: URL, before line: String, in code: String
    ) -> String? {
        guard let cut = code.range(of: line) else { return nil }
        let head = code[code.startIndex..<cut.lowerBound]
        for candidate in head.split(separator: "\n").reversed() {
            let text = String(candidate)
            guard text.contains("class ") || text.contains("struct ")
                || text.contains("actor ") || text.contains("extension ")
            else { continue }
            let parts = text.components(separatedBy: " ")
            guard let index = parts.firstIndex(where: {
                $0 == "class" || $0 == "struct" || $0 == "actor" || $0 == "extension"
            }), parts.index(after: index) < parts.endIndex else { continue }
            return parts[parts.index(after: index)]
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        }
        return nil
    }
}
```

`FakeHTTPTransport` is declared at `Tests/macSCPCoreTests/WebDAVFileSystemTests.swift:17`
as a file-scope `final class … Sendable`, so it is visible from any file in
the `macSCPCoreTests` target; its initialiser is
`init(replies: [Reply], drainsRequestBody: Bool = true)` at `:52`, and
`replies: []` is what the existing write tests pass. Do not write a second
fake.

- [ ] **Step 2: Run the guard — it must be GREEN**

Run: `swift test --build-system native --filter RemoteFileSystemAppendResumeGuardTests`

Expected: PASS. This guard describes behaviour that is already correct, so a
passing run proves nothing yet — step 3 is what proves it.

- [ ] **Step 3: Plant a violation and watch it go red**

A guard over existing behaviour is worthless until a planted violation turns
it red. Plant it with an asserted anchor, never by hand:

```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift")
s = p.read_text()
old = "    public var supportsAppendResume: Bool { false }"
new = "    public var supportsAppendResume: Bool { true }"
assert old in s and s.count(old) == 1, "ANCHOR MISS — do not proceed"
p.write_text(s.replace(old, new))
print("planted")
PY
```

Run: `swift test --build-system native --filter RemoteFileSystemAppendResumeGuardTests`

Expected: FAIL, in **both** tests — the instance expectation
(`webdav.supportsAppendResume == false`) and the overrider set
(`WebDAVFileSystem=true`). Record both failure messages for the report.

- [ ] **Step 4: Revert the plant and prove the file is byte-identical**

Do **not** use `git checkout -- <file>`: it restores from the index and takes
any other uncommitted edit in that file with it. Revert with the inverse
asserted replacement, then prove it:

```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift")
s = p.read_text()
old = "    public var supportsAppendResume: Bool { true }"
new = "    public var supportsAppendResume: Bool { false }"
assert old in s and s.count(old) == 1, "ANCHOR MISS — do not proceed"
p.write_text(s.replace(old, new))
print("reverted")
PY
git diff --stat -- Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift
```

Expected: the `git diff --stat` prints **nothing** — the file is identical to
`HEAD`. If it prints a change, stop and read the diff before continuing.

- [ ] **Step 5: Record the two decisions in the source**

In `Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift`, replace the
`supportsAppendResume` line's surroundings so the answer reads as permanent
rather than provisional. Keep the declaration itself unchanged:

```swift
    /// Permanent, not provisional: plain WebDAV has no partial PUT, so there
    /// is no byte range to resume onto. `write(path:mode:contents:)` still
    /// refuses `.append` with `RemoteFSFinding.resumeNotSupported` as defence
    /// in depth — `TransferEngine` cannot ask for it while this answers
    /// `false` (`TransferEngine.swift:182`), so that finding's four
    /// catalogue sentences are accepted as unreached from production.
    /// `RemoteFileSystemAppendResumeGuardTests` is what makes a change here
    /// loud instead of silent.
    public var supportsAppendResume: Bool { false }
```

In `Sources/macSCPCore/RemoteFS/RemoteFSFinding.swift`, extend the
`readsAsConnectionFailure` doc comment with the reachability argument,
keeping every existing line and adding after the paragraph that ends
"— which a retry would meet again.":

```swift
    /// Measured 2026-10-01: this answer and the queue's resumability
    /// question do not collide on any reachable path, which is why they
    /// share one property. `isConnectionFailure` only selects a BRANCH at
    /// `TransferQueueViewModel.swift:1204`; four gates inside it decide the
    /// status — `bypassConflictCheck` (`:1207`), `destinationTabID != nil`
    /// (`:1216`), `!destination.supportsAppendResume` (`:1231`), and
    /// otherwise `.interrupted` (`:1240`), the only resumable outcome.
    ///
    /// `.redirectBodyNotResendable` cannot reach that last gate, for two
    /// independent reasons: it is recorded only when a request carries a body
    /// STREAM (`S3RedirectSessionDelegate.swift:119`), and the comment there
    /// records that the S3 path builds none today; and a request with a body
    /// is an upload, whose destination is S3, which answers `false` to
    /// `supportsAppendResume` — gate three. What IS reachable is
    /// `.redirectUnreadable` / `.redirectNotResignable` during a DOWNLOAD,
    /// where the destination is local and appendable, and there `.interrupted`
    /// is right: the request never reached a server that answered it, and the
    /// partial file is sound.
```

- [ ] **Step 6: Build and run the two affected suites**

Run: `swift test --build-system native --filter "RemoteFileSystemAppendResumeGuardTests|RemoteFSFindingTests"`

Expected: PASS, both suites. A comment-only change to `RemoteFSFinding.swift`
cannot alter behaviour; this run is what proves it compiles and that
`RemoteFSFindingTests` is unaffected.

- [ ] **Step 7: Commit**

```bash
git add Tests/macSCPCoreTests/RemoteFileSystemAppendResumeGuardTests.swift \
        Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift \
        Sources/macSCPCore/RemoteFS/RemoteFSFinding.swift
git commit -F - <<'MSG'
test(remotefs): pin every conformer's supportsAppendResume

supportsAppendResume is defaulted to true in a protocol extension
(RemoteFileSystem.swift:207), so a conformer is appendable by silence. Six
conformers counted in Sources/ on 2026-10-01; exactly two override, both to
false (S3, WebDAV).

The guard has two halves because CitadelFileSystem needs a live connection
and S3FileSystem has only a private init: real instances for LocalFileSystem
and WebDAVFileSystem, and a source scan for the conformer set and the
override set. Both scans are positive checks — sets that must match.

This is the PAIR docs/BACKLOG.md records as pinned by nothing for
RemoteFSFinding.resumeNotSupported: a WebDAV that later answered true would
make that finding live with nothing announcing it.

Proved by a planted violation: flipping WebDAV's false to true turned both
tests red. Reverted with an inverse asserted replacement rather than
git checkout, and git diff --stat confirmed the file byte-identical.

Also records, at readsAsConnectionFailure, why that property answers two
questions safely: the four gates in TransferQueueViewModel, and the two
independent reasons .redirectBodyNotResendable cannot reach the resumable
one.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Task 2: a finding of its own for a Depth-0 PROPFIND body

Closes the row at `docs/BACKLOG.md:173`.

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFSFinding.swift` (seven places)
- Modify: `Sources/macSCPCore/WebDAV/WebDAVPropfindParser.swift:49,67,77,101`
- Modify: `Sources/macSCPCore/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/macSCPCore/Resources/de.lproj/Localizable.strings`
- Modify: `Sources/macSCPCore/Resources/fr.lproj/Localizable.strings`
- Modify: `Sources/macSCPCore/Resources/pl.lproj/Localizable.strings`
- Test: `Tests/macSCPCoreTests/WebDAVPropfindParserTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `RemoteFSFinding.resourceDetailsUnparsable` (no payload) and its
  catalogue key `core.finding.resourceDetailsUnparsable`. Task 6 relies on
  the case existing and on `RemoteFSFinding.everySample` covering it.

**The defect.** `WebDAVPropfindParser.parsed(_:)` (`:77`) is private and
shared by three readers, and throws `.listingUnparsable` at `:101` for all
three. Two of the three are Depth-0 reads of ONE resource, so a `stat` of a
single file against a server answering malformed XML currently says "The
folder listing the server sent could not be read" — true of the mechanism,
wrong about what was asked for.

| reader | line | depth | finding after this task |
|---|---|---|---|
| `parse(_:base:requestedPath:)` | `:15` | 1, a real listing | `.listingUnparsable` (unchanged) |
| `firstResourceIsCollection(_:)` | `:49` | 0, one resource | `.resourceDetailsUnparsable` |
| `entityTag(_:base:at:)` | `:67` | 0, one resource | `.resourceDetailsUnparsable` |

`firstResourceIsCollection` is called under `try?` at
`WebDAVClaimsProbe.swift:80`, so its throw reaches no reader today; it is
changed anyway so the two Depth-0 readers agree.

- [ ] **Step 1: Write the failing test**

Append to `Tests/macSCPCoreTests/WebDAVPropfindParserTests.swift`, inside its
existing suite. If that file does not exist, create it with
`import Foundation`, `import Testing`, `@testable import macSCPCore` and a
`@Suite("WebDAVPropfindParser") struct WebDAVPropfindParserTests {}`:

```swift
    /// Malformed XML means something different to each reader, and the
    /// sentence has to match what was asked for. A Depth-1 body IS the
    /// folder listing; a Depth-0 body describes one resource, and calling
    /// that a folder listing is what `docs/BACKLOG.md` recorded as a wording
    /// regression.
    @Test func eachReaderNamesWhatItAskedFor() throws {
        let malformed = Data("<multistatus><response".utf8)
        let base = WebDAVURL(
            baseURL: try #require(URL(string: "https://dav.example.com/dav")),
            nextcloudUser: nil)

        #expect(throws: RemoteFSError.finding(.listingUnparsable)) {
            _ = try WebDAVPropfindParser.parse(malformed, base: base, requestedPath: "/")
        }
        #expect(throws: RemoteFSError.finding(.resourceDetailsUnparsable)) {
            _ = try WebDAVPropfindParser.entityTag(malformed, base: base, at: "/a.txt")
        }
        #expect(throws: RemoteFSError.finding(.resourceDetailsUnparsable)) {
            _ = try WebDAVPropfindParser.firstResourceIsCollection(malformed)
        }
    }
```

`WebDAVURL`'s initialiser is `init(baseURL: URL, nextcloudUser: String?)`
(`Sources/macSCPCore/WebDAV/WebDAVURL.swift:19`), checked 2026-10-01 — the
labels above are the real ones.

- [ ] **Step 2: Run it to make sure it fails**

Run: `swift test --build-system native --filter eachReaderNamesWhatItAskedFor`

Expected: FAIL to COMPILE — `RemoteFSFinding` has no member
`resourceDetailsUnparsable`. That is the red; a compile failure naming the
missing case is the correct first red for a new enum case.

- [ ] **Step 3: Add the case and its seven arms**

In `Sources/macSCPCore/RemoteFS/RemoteFSFinding.swift`, make all seven edits.
Every switch is exhaustive with no `default:`, so the compiler names each one
you forget — work until it is silent.

1. The case itself, after `case listingUnparsable`:

```swift
    /// A PROPFIND answer describing ONE resource would not parse. The
    /// sibling of `.listingUnparsable` for the two Depth-0 readers: a
    /// `stat` and a session-root probe ask about a single resource, and
    /// calling that a folder listing was wrong about what was asked for.
    case resourceDetailsUnparsable
```

2. In `Name`, on the line that already carries `listingUnparsable`:

```swift
        case nonHTTPResponse, listingUnparsable, resourceDetailsUnparsable
```

3. In `name`, after the `.listingUnparsable` arm:

```swift
        case .resourceDetailsUnparsable: return .resourceDetailsUnparsable
```

4. In `messageKey(for:)`, add `.resourceDetailsUnparsable` to the
   **second** case list — the one returning `"core.finding.\(name.rawValue)"`
   without a format specifier, since this finding carries no payload.

5. In `message`, add `.resourceDetailsUnparsable` to the final case list —
   the one returning `CoreL10n.string(messageKey)` unformatted.

6. In `logSentence`, after the `.listingUnparsable` arm:

```swift
        case .resourceDetailsUnparsable:
            return "the information the server sent about this item could not be read"
```

7. In `readsAsConnectionFailure`, add `.resourceDetailsUnparsable` to the
   `false` list: a malformed answer is a fact about what the server sent,
   which a retry would meet again.

- [ ] **Step 4: Add the four catalogue sentences**

Insert each beside the existing `core.finding.listingUnparsable` line in its
own catalogue, so the two siblings sit together. The `en` text is the source
the other three are measured against, and `logSentence` above is this
sentence with a lower-case first character — Task 6 pins exactly that.

`Sources/macSCPCore/Resources/en.lproj/Localizable.strings`:

```
"core.finding.resourceDetailsUnparsable" = "The information the server sent about this item could not be read";
```

`de.lproj` — the German catalogue addresses the user as **du**; this sentence
addresses nobody, so there is no pronoun to get wrong:

```
"core.finding.resourceDetailsUnparsable" = "Die Angaben, die der Server zu diesem Eintrag geschickt hat, konnten nicht gelesen werden";
```

`fr.lproj`:

```
"core.finding.resourceDetailsUnparsable" = "Les informations envoyées par le serveur sur cet élément n'ont pas pu être lues";
```

`pl.lproj`:

```
"core.finding.resourceDetailsUnparsable" = "Nie udało się odczytać informacji o tym elemencie przysłanych przez serwer";
```

- [ ] **Step 5: Make each reader name its own finding**

In `Sources/macSCPCore/WebDAV/WebDAVPropfindParser.swift`, give the private
`parsed(_:)` a parameter and pass it from each reader.

Change the signature and the throw:

```swift
    /// One XML pass, shared by the three readers above — each of which says
    /// which finding a malformed body is for IT, because the answer differs:
    /// a Depth-1 body IS the folder listing, a Depth-0 body describes one
    /// resource. Passing it in rather than throwing one finding for all
    /// three is what closed the `docs/BACKLOG.md` wording row.
    private static func parsed(
        _ data: Data, unparsable finding: RemoteFSFinding
    ) throws -> Delegate {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        guard parser.parse() else { throw RemoteFSError.finding(finding) }
        return delegate
    }
```

The long comment that currently sits at `:80-100` explaining why
`.listingUnparsable` was reused for all three is now wrong and must be
**deleted**, not left in place — it describes a decision this task reverses.
Its replacement is the shorter comment above.

Then the three call sites:

- `parse(_:base:requestedPath:)` at `:18`:
  `let delegate = try parsed(data, unparsable: .listingUnparsable)`
- `firstResourceIsCollection(_:)` at `:50`:
  `try parsed(data, unparsable: .resourceDetailsUnparsable).entries.first?.isCollection`
- `entityTag(_:base:at:)` at `:69`:
  `for entry in try parsed(data, unparsable: .resourceDetailsUnparsable).entries`

- [ ] **Step 6: Clean build, because this task is the one the hazard names**

`docs/BACKLOG.md` carries the row "An incremental build can crash after
`RemoteFSFinding` gains a case". This task is exactly that change, so do not
trust an incremental build:

```bash
rm -rf .build
swift test --build-system native --filter "WebDAVPropfindParser|RemoteFSFinding|LocalizationParity"
```

The `.build` directory being removed here is **this worktree's own** — never
run that command in `/Users/noidee/macSCP`.

Expected: PASS. In particular
`LocalizationParityTests.everyRemoteFSFindingHasItsOwnSentence` must pass: it
walks `Name.allCases` and requires every catalogue to carry a sentence for
every finding, and requires each sentence to be unique within its catalogue.
If it fails for a missing key, a catalogue edit was dropped; if it fails for
a duplicate, the new sentence collides with an existing one and needs
rewording, not silencing.

- [ ] **Step 7: Run the whole suite**

Run: `swift test --build-system native`

Expected: PASS except the one known failure recorded in `docs/BACKLOG.md`
(`ViewTestabilitySpike`'s pixel comparison, an expired measurement on
macOS 27). Any other red belongs to this task. Note the test count for the
report — the baseline at the branch point was 6623 in 568 suites.

- [ ] **Step 8: Commit**

```bash
git add Sources/macSCPCore/RemoteFS/RemoteFSFinding.swift \
        Sources/macSCPCore/WebDAV/WebDAVPropfindParser.swift \
        Sources/macSCPCore/Resources/en.lproj/Localizable.strings \
        Sources/macSCPCore/Resources/de.lproj/Localizable.strings \
        Sources/macSCPCore/Resources/fr.lproj/Localizable.strings \
        Sources/macSCPCore/Resources/pl.lproj/Localizable.strings \
        Tests/macSCPCoreTests/WebDAVPropfindParserTests.swift
git commit -F - <<'MSG'
fix(webdav): a Depth-0 PROPFIND no longer blames the folder listing

WebDAVPropfindParser.parsed threw .listingUnparsable for all three of its
readers, but two of them read a Depth-0 body describing ONE resource. A stat
of a single file against a server answering malformed XML therefore said the
folder listing could not be read, for an operation that listed no folder.

parsed now takes the finding to throw, and each reader names its own:
.listingUnparsable for the Depth-1 listing, the new
.resourceDetailsUnparsable for entityTag and firstResourceIsCollection. The
comment that justified reusing one finding for all three is deleted rather
than left to contradict the code.

The new finding carries no payload and reads as a fact about the answer
rather than a connection failure, so readsAsConnectionFailure answers false.
Four catalogue sentences, en/de/fr/pl; everyRemoteFSFindingHasItsOwnSentence
enforces their presence and distinctness without being edited. Findings go
from 17 to 18.

Built clean rather than incrementally, per the docs/BACKLOG.md row about an
incremental build crashing after RemoteFSFinding gains a case.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Task 3: `parseObjectKeys` throws the finding it describes

Closes the row at `docs/BACKLOG.md:174`.

**Files:**
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift:1204`
- Test: `Tests/macSCPCoreTests/S3FileSystemTests.swift`

**Interfaces:**
- Consumes: `RemoteFSFinding.listingUnparsable`, which exists before this
  plan.
- Produces: nothing later tasks consume.

**The defect.** `S3FileSystem.swift:1204`, inside `parseObjectKeys(_:)`
(declared `:1153`), throws
`RemoteFSError.protocolError(reason: "Failed to parse S3 ListObjectsV2 response: \(reason)")`
— the same condition `.listingUnparsable` names and
`S3ListParser.swift:41` already throws as a finding. It is the last untyped
copy of that condition.

It is invisible today: `parseObjectKeys` is reached only from
`allObjectKeys(bucket:underPrefix:)` (`:1128`), whose only callers are
`rename` (`:804`) and `deleteTree` (`:880`), neither of which the transfer
queue's mapper catches. It becomes user-visible the moment either operation
joins the queue's catch set, which is why the copy is worth removing now.

- [ ] **Step 1: Write the failing test**

Add to `Tests/macSCPCoreTests/S3FileSystemTests.swift`, inside the existing
suite. It uses the file's own `connect(responses:)` helper (`:105`) — read
that helper and the fixtures around it, and follow the shape of the nearest
existing test that drives `rename` or `deleteTree` against a malformed
listing body. Build the malformed body as:

```swift
    /// `parseObjectKeys` used to throw its condition as prose, which was a
    /// second untyped copy of what `.listingUnparsable` names and
    /// `S3ListParser` already throws. Same condition, one spelling.
    @Test func anUnparsableObjectListingThrowsTheTypedFinding() async throws {
        let malformed = Data("<ListBucketResult><Contents".utf8)
        let (fs, _) = try await connect(responses: [
            (malformed, httpResponse(status: 200)),
        ])

        await #expect(throws: RemoteFSError.finding(.listingUnparsable)) {
            try await fs.deleteTree(path: "/bucket/folder")
        }
    }
```

`httpResponse(status:headers:)` is this suite's own helper at
`Tests/macSCPCoreTests/S3FileSystemTests.swift:99`, and `connect(responses:)`
(`:105`) already prepends one empty-listing response for the connect
handshake — so the array above is what the backend answers AFTER it is
connected. If `deleteTree` needs a further round trip before it reaches
`parseObjectKeys`, supply the responses that get it there; the assertion is
about which error comes out, not about the number of round trips.

- [ ] **Step 2: Run it to make sure it fails**

Run: `swift test --build-system native --filter anUnparsableObjectListingThrowsTheTypedFinding`

Expected: FAIL, with the thrown error reported as
`protocolError(reason: "Failed to parse S3 ListObjectsV2 response: …")`
rather than `finding(.listingUnparsable)`. Record the actual message.

- [ ] **Step 3: Type the throw**

In `Sources/macSCPCore/S3/S3FileSystem.swift`, replace the throw at `:1204`:

```swift
            // The same condition `.listingUnparsable` names, and the one
            // `S3ListParser.swift` already throws as a finding. The parser's
            // own `reason` is dropped with it: it is XML-shape prose no
            // reader acts on, and a finding is this module's own text in four
            // languages (the 2026-09-28 typed-findings decision).
            throw RemoteFSError.finding(.listingUnparsable)
```

Delete the now-unused local that held the interpolated `reason`, if the
compiler reports one as unused. Do not silence a warning with `_ =`:
`MAX_WARNINGS` is 0 on CI.

- [ ] **Step 4: Run the test and the S3 suite**

Run: `swift test --build-system native --filter S3FileSystemTests`

Expected: PASS, including the new test. If another test in the suite asserted
the old prose, it is a second reader of the removed copy — update it to the
finding and say so in the commit body.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/S3/S3FileSystem.swift \
        Tests/macSCPCoreTests/S3FileSystemTests.swift
git commit -F - <<'MSG'
refactor(s3): parseObjectKeys throws the finding it describes

S3FileSystem.swift:1204 threw RemoteFSError.protocolError with English prose
naming the same condition .listingUnparsable names and S3ListParser.swift:41
already throws as a finding. It was the last untyped copy of that condition.

Invisible today: parseObjectKeys is reached only from allObjectKeys, whose
callers are rename and deleteTree, neither of which the transfer queue's
mapper catches — so the text was dropped before any reader. It becomes
user-visible the moment either operation joins that catch set, which is the
reason to remove the copy now rather than later.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Task 4: `parseUploadID` recorded as a deliberate passthrough

Closes the row at `docs/BACKLOG.md:175`, by the maintainer's decision of
2026-10-01: **no new finding here.**

**Files:**
- Modify: `Sources/macSCPCore/S3/S3MultipartXML.swift:20`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

**Why no code change.** `S3MultipartXML.swift:20` composes
`"Failed to parse S3 InitiateMultipartUpload response: \(reason)"`, where
`reason` falls back from Foundation's `parserError?.localizedDescription` — a
foreign string, out of scope by the maintainer's decision of 2026-09-28 — to
this project's own `"no UploadId element"`. One construction, two
provenances. Splitting it would cost four catalogue sentences, two of them in
`fr`/`pl` catalogues whose native-speaker review was closed unreviewed, to
type a phrase that reaches no reader. The maintainer decided against it. What
this task leaves behind is a decision a later reader can find, instead of an
oversight they re-discover.

- [ ] **Step 1: Record the decision at the site**

In `Sources/macSCPCore/S3/S3MultipartXML.swift`, above the composition at
`:20`, add:

```swift
        // TWO PROVENANCES IN ONE SENTENCE, left that way on purpose
        // (maintainer's decision, 2026-10-01; docs/BACKLOG.md row
        // "`S3MultipartXML.parseUploadID` composes one sentence out of an
        // in-scope half and a foreign half").
        //
        // `reason` is either Foundation's own `parserError`
        // `localizedDescription` — a foreign string, out of scope for typing
        // since 2026-09-28 — or this project's own "no UploadId element".
        // Typing the second half would mean a finding, which the parity
        // guard turns into four catalogue sentences; the phrase reaches no
        // reader today, and two of those four would go into catalogues whose
        // native-speaker review was closed unreviewed. So the in-scope half
        // stays untyped here, deliberately, and this comment is the record.
        // Revisit if this error ever reaches a user-facing surface.
```

Read the surrounding code first and place the comment where it describes the
composition, not the function's entry.

- [ ] **Step 2: Build and run the S3 suites**

Run: `swift test --build-system native --filter "S3Multipart|S3FileSystemTests"`

Expected: PASS. A comment-only change cannot alter behaviour; this run proves
it compiles.

- [ ] **Step 3: Commit**

```bash
git add Sources/macSCPCore/S3/S3MultipartXML.swift
git commit -F - <<'MSG'
docs(s3): parseUploadID's two provenances are a decision, not an oversight

The sentence at S3MultipartXML.swift:20 mixes Foundation's own parser error
text with this project's "no UploadId element". The maintainer decided on
2026-10-01 not to split it: typing the in-scope half means a finding, the
parity guard turns a finding into four catalogue sentences, and the phrase
reaches no reader today — two of those four would land in fr/pl catalogues
whose native-speaker review was closed unreviewed.

No behaviour change. The comment is the deliverable: a later reader finds a
decision with its cost named, instead of re-discovering the question.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Task 5: a seam for the upload-stream finding

Closes the row at `docs/BACKLOG.md:176`.

**Files:**
- Modify: `Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift:6-25,455-465`
- Test: `Tests/macSCPCoreTests/WebDAVFileSystemWriteTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `WebDAVFileSystem.BoundStreamFactory`, a
  `@Sendable (Int) -> (input: InputStream, output: OutputStream)?` type alias,
  and a second parameter on the internal test-seam initialiser
  `init(config:transport:boundStreams:)` defaulted to the Foundation call. No
  later task consumes it.

**The defect.** `write(path:mode:contents:)` calls the static
`Stream.getBoundStreams` at `:459` and throws `.uploadStreamUnavailable` at
`:462` when it hands back no pair. A reviewer proved the site unpinned on
2026-09-28 by substituting a different finding there and watching the whole
suite stay green. `uploadStreamUnavailable` appears in `Tests/` only inside
`RemoteFSFindingTests`' exhaustive switches, never at this site.

The seam follows `DetachedProbe.Launch` — a `@Sendable` closure type alias
with a production default, not a protocol for one call.

- [ ] **Step 1: Write the failing test**

Add to `Tests/macSCPCoreTests/WebDAVFileSystemWriteTests.swift`, inside the
existing suite, beside `appendModeIsRefused` (`:298`):

```swift
    /// The one line in this file that no test could reach before a seam
    /// existed: `Stream.getBoundStreams` is a static Foundation call, so the
    /// "it handed back no pair" branch was unreachable from a test and a
    /// reviewer could substitute a different finding there with the suite
    /// staying green (docs/BACKLOG.md, 2026-09-28).
    @Test func noBoundStreamPairIsReportedAsTheUploadStreamFinding() async throws {
        let transport = FakeHTTPTransport(replies: [])
        let fs = WebDAVFileSystem(
            config: config, transport: transport, boundStreams: { _ in nil })

        await #expect(throws: RemoteFSError.finding(.uploadStreamUnavailable)) {
            try await fs.write(path: "/a.txt", mode: .overwrite, contents: stream("data"))
        }
        #expect(transport.requests.isEmpty, """
            No request may be made when the body stream could not be created.
            """)
    }
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `swift test --build-system native --filter noBoundStreamPairIsReportedAsTheUploadStreamFinding`

Expected: FAIL to COMPILE — `init(config:transport:)` has no `boundStreams`
parameter.

- [ ] **Step 3: Add the seam**

In `Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift`, declare the alias and
the stored property beside `transport` (`:8`):

```swift
    /// How a bound stream pair is obtained. A closure rather than a protocol:
    /// `Stream.getBoundStreams` is one static Foundation call, and the shape
    /// here follows `DetachedProbe.Launch` — a `@Sendable` alias with a
    /// production default — rather than inventing a factory protocol for a
    /// single line. Its reason for existing is that the "no pair" branch in
    /// `write(path:mode:contents:)` was reachable from no test, which let a
    /// reviewer substitute a different finding there unnoticed.
    typealias BoundStreamFactory =
        @Sendable (_ bufferSize: Int) -> (input: InputStream, output: OutputStream)?

    static let foundationBoundStreams: BoundStreamFactory = { bufferSize in
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: bufferSize,
                               inputStream: &input, outputStream: &output)
        guard let input, let output else { return nil }
        return (input, output)
    }

    private let boundStreams: BoundStreamFactory
```

Give both initialisers the parameter, defaulted, so no production call site
changes. The internal test seam at `:11`:

```swift
    /// Test seam: inject a transport, skip the network entirely. The
    /// `boundStreams` default is the Foundation call every production path
    /// uses; a test overrides it to reach the "no pair" branch.
    init(config: WebDAVConnectionConfig, transport: any HTTPTransport,
         boundStreams: BoundStreamFactory = WebDAVFileSystem.foundationBoundStreams) {
```

…assigning `self.boundStreams = boundStreams` alongside the existing
assignments, and the same for the `private init(base:transport:session:)` at
`:20`. Whatever calls that private initialiser (the `connect` path) needs no
edit, because the parameter is defaulted.

Then replace the call at `:455-462`:

```swift
        guard let (input, output) = boundStreams(TransferChunk.size) else {
            throw RemoteFSError.finding(.uploadStreamUnavailable)
        }
```

Keep everything after it — `request.httpBodyStream = input`, the
`BoundStreamWriter` and its comment — unchanged.

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --build-system native --filter WebDAVFileSystemWriteTests`

Expected: PASS, the whole suite, including the new test and the existing
`appendModeIsRefused`.

- [ ] **Step 5: Prove the seam pins the site**

The point of this task is that substituting the finding at that line must now
be caught. Plant it:

```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift")
s = p.read_text()
old = """        guard let (input, output) = boundStreams(TransferChunk.size) else {
            throw RemoteFSError.finding(.uploadStreamUnavailable)
        }"""
new = """        guard let (input, output) = boundStreams(TransferChunk.size) else {
            throw RemoteFSError.finding(.outOfStorage)
        }"""
assert old in s and s.count(old) == 1, "ANCHOR MISS — do not proceed"
p.write_text(s.replace(old, new))
print("planted")
PY
swift test --build-system native --filter noBoundStreamPairIsReportedAsTheUploadStreamFinding
```

Expected: FAIL — this is the proof the 2026-09-28 reviewer could not get.
Revert with the inverse asserted replacement (swap `old` and `new` above),
then confirm `git diff` against `HEAD` shows only the intended seam, not the
probe.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift \
        Tests/macSCPCoreTests/WebDAVFileSystemWriteTests.swift
git commit -F - <<'MSG'
test(webdav): a seam that reaches the upload-stream finding

Stream.getBoundStreams is a static Foundation call, so the branch that throws
.uploadStreamUnavailable when it hands back no pair was reachable from no
test. On 2026-09-28 a reviewer proved it: substituting a different finding at
that line left the whole suite green.

WebDAVFileSystem gains a BoundStreamFactory — a @Sendable closure alias with
Stream.getBoundStreams as its default, the DetachedProbe.Launch shape rather
than a protocol for one call — as a defaulted parameter on both
initialisers, so no production call site changes. A test injects a factory
returning no pair and reaches the throw for the first time, and asserts that
no request is made.

Proved by planting .outOfStorage at that line: the new test went red.
Reverted with an inverse asserted replacement.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Task 6: `logSentence` anchored to the `en` catalogue

Closes the row at `docs/BACKLOG.md:178`.

**Files:**
- Modify: `Tests/macSCPCoreTests/RemoteFSFindingTests.swift:128-161`

**Interfaces:**
- Consumes: `RemoteFSFinding.resourceDetailsUnparsable` from Task 2 — this
  task's exhaustive switch does not compile without it.
- Produces: `RemoteFSFinding.everySample`, a
  `[(finding: RemoteFSFinding, formatArgument: String?)]`, with the existing
  `everyCase` redefined as `everySample.map(\.finding)` so its three current
  callers are untouched.

**The defect.** The type carries two texts on purpose — `message` from the
catalogue in the reader's language, `logSentence` fixed English for the
diagnostic log and the CLI — but nothing compares `logSentence` against the
`en` entry for the same key, so the two can drift silently. The tests that
read `logSentence` check that it is non-empty, that it carries no URL, and
that a dial and a CLI line render it; none reads `en.lproj` beside it.

**What a guard can assert, measured 2026-10-01.** `logSentence` is
deliberately NOT equal to its catalogue entry: the doc comment at
`RemoteFSFinding.swift:188` says the log's sentences are lower-case phrases
that a `reason=` field completes. Compared with the `en` entry lower-cased at
the first character, **16 of 17 match exactly**; the exception is
`resumeRangeIgnored`, whose sentence opens with the proper noun "S3", which
must not become "s3". The relation that holds for all of them is: equal, with
the **first character compared case-insensitively**. Counted in the same
pass, **0 of the 17** `en` sentences end with a period, so nothing needs
stripping — do not add a branch for punctuation that does not exist.

Three keys carry a ` %@` suffix and their values a `%@`
(`unexpectedStatus`, `pathExistsAndIsNotADirectory`,
`uploadPartUnacknowledged`, counted at `RemoteFSFinding.swift:153-154`), so
the comparison formats the catalogue value with the same argument the sample
carries.

- [ ] **Step 1: Turn `everyCase` into one source of truth**

In `Tests/macSCPCoreTests/RemoteFSFindingTests.swift`, replace the
`extension RemoteFSFinding` block at `:128-161` with a version carrying the
format argument beside each sample. One exhaustive switch, two readers — not
a second copy:

```swift
extension RemoteFSFinding {
    /// One sample per `Name`, with the argument its catalogue key
    /// interpolates — by exhaustive switch, so a finding added to the enum
    /// does not compile until it has a sample, and cannot be left out of
    /// the guards above.
    ///
    /// The payloads are placeholders: a status code, a path this project
    /// owns and an upload part number it counted out itself, which is
    /// exactly what the three payload-carrying findings are allowed to hold
    /// (counted in the switch below, 2026-10-01: three of eighteen).
    ///
    /// `formatArgument` is `nil` for a finding whose key carries no format
    /// specifier, and the interpolated value as a string for the three that
    /// do — which is what lets
    /// `everyLogSentenceMatchesItsEnglishCatalogueEntry` format the
    /// catalogue value the same way `message` would.
    static var everySample: [(finding: RemoteFSFinding, formatArgument: String?)] {
        Name.allCases.map { name in
            switch name {
            case .resumeRangeIgnored: return (.resumeRangeIgnored, nil)
            case .sourceChangedSinceInterruption: return (.sourceChangedSinceInterruption, nil)
            case .unexpectedStatus: return (.unexpectedStatus(code: 418), "418")
            case .directoryAlreadyExists: return (.directoryAlreadyExists, nil)
            case .destinationAlreadyExists: return (.destinationAlreadyExists, nil)
            case .outOfStorage: return (.outOfStorage, nil)
            case .uploadStreamUnavailable: return (.uploadStreamUnavailable, nil)
            case .pathExistsAndIsNotADirectory:
                return (.pathExistsAndIsNotADirectory(path: "/srv/x"), "/srv/x")
            case .nonHTTPResponse: return (.nonHTTPResponse, nil)
            case .listingUnparsable: return (.listingUnparsable, nil)
            case .resourceDetailsUnparsable: return (.resourceDetailsUnparsable, nil)
            case .redirectUnreadable: return (.redirectUnreadable, nil)
            case .redirectBodyNotResendable: return (.redirectBodyNotResendable, nil)
            case .redirectNotResignable: return (.redirectNotResignable, nil)
            case .resumeNotSupported: return (.resumeNotSupported, nil)
            case .noSuchBucket: return (.noSuchBucket, nil)
            case .uploadPartUnacknowledged: return (.uploadPartUnacknowledged(part: 7), "7")
            case .requestBodyUnencodable: return (.requestBodyUnencodable, nil)
            }
        }
    }

    /// The samples alone — what the guards that need no argument read.
    static var everyCase: [RemoteFSFinding] { everySample.map(\.finding) }
}
```

- [ ] **Step 2: Write the failing guard**

Add to `RemoteFSFindingTests`' suite body:

```swift
    /// `logSentence` is a second English text beside the `en` catalogue, on
    /// purpose — the log's sentences are lower-case phrases a `reason=`
    /// field completes (`RemoteFSFinding.swift:188`). Nothing held the two
    /// together, so they could drift silently; this is what holds them.
    ///
    /// Measured 2026-10-01 across all of them: equal, with the first
    /// character compared case-insensitively. The first character is the one
    /// difference the two texts are allowed to have, and it is a real one —
    /// `resumeRangeIgnored` opens with "S3", which must not be lower-cased
    /// to "s3". None of the catalogue sentences ends with a period, so
    /// nothing is stripped here.
    ///
    /// The catalogue is read off disk rather than through
    /// `CoreL10n.string` / `message`: those resolve through the test
    /// process's current locale, and this property must hold whatever locale
    /// runs the test, not only under `en`. Same reason, and same route, as
    /// `S3FileSystemTests.rangeIgnoredReasonStillMatchesTheFindingsEnglishCatalogueEntry`.
    @Test func everyLogSentenceMatchesItsEnglishCatalogueEntry() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let enCatalogue = repoRoot
            .appendingPathComponent("Sources/macSCPCore/Resources/en.lproj/Localizable.strings")
            .path(percentEncoded: false)
        let catalogue = try #require(NSDictionary(contentsOfFile: enCatalogue) as? [String: String])

        #expect(RemoteFSFinding.everySample.isEmpty == false, """
            everySample came back empty, so the loop below checked nothing.
            """)

        for (finding, argument) in RemoteFSFinding.everySample {
            let key = finding.messageKey
            let english = try #require(catalogue[key], """
                No en entry for \(finding.name) at key \(key).
                """)
            let expected = argument.map { String(format: english, $0) } ?? english
            let actual = finding.logSentence

            #expect(actual.count == expected.count, """
                \(finding.name): logSentence and its en entry differ in length.
                log: \(actual)
                en : \(expected)
                """)
            #expect(actual.dropFirst() == expected.dropFirst(), """
                \(finding.name): logSentence and its en entry differ after the \
                first character. Only the first character may differ, and only \
                in case.
                log: \(actual)
                en : \(expected)
                """)
            #expect(actual.prefix(1).lowercased() == expected.prefix(1).lowercased(), """
                \(finding.name): logSentence and its en entry differ in their \
                first character beyond case.
                log: \(actual)
                en : \(expected)
                """)
        }
    }
```

- [ ] **Step 3: Run it — it must be GREEN, then prove it with a plant**

Run: `swift test --build-system native --filter RemoteFSFindingTests`

Expected: PASS. As in Task 1, a guard over correct behaviour proves nothing
until a planted drift turns it red. Plant one in the catalogue:

```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("Sources/macSCPCore/Resources/en.lproj/Localizable.strings")
s = p.read_text(encoding="utf-8")
old = '"core.finding.outOfStorage" = "The server is out of storage";'
new = '"core.finding.outOfStorage" = "The server has run out of storage";'
assert old in s and s.count(old) == 1, "ANCHOR MISS — read the real line and retry"
p.write_text(s.replace(old, new), encoding="utf-8")
print("planted")
PY
swift test --build-system native --filter everyLogSentenceMatchesItsEnglishCatalogueEntry
```

Expected: FAIL, naming `outOfStorage`. If the anchor misses, read the real
`outOfStorage` line and plant on that text instead — do not skip the plant.

Then revert with the inverse asserted replacement and confirm
`git diff --stat -- Sources/macSCPCore/Resources/en.lproj/Localizable.strings`
prints nothing.

- [ ] **Step 4: Run the whole suite**

Run: `swift test --build-system native`

Expected: PASS except the one known `ViewTestabilitySpike` failure. The three
existing constant-comparison tests
(`S3FileSystemTests` `:599` and `:615`, `WebDAVFileSystemTests` `:404`) keep
their own subjects and must stay green — this guard does not replace them.

- [ ] **Step 5: Commit**

```bash
git add Tests/macSCPCoreTests/RemoteFSFindingTests.swift
git commit -F - <<'MSG'
test(remotefs): hold every logSentence to its English catalogue entry

RemoteFSFinding carries two English texts on purpose — message from the
catalogue, logSentence fixed for the diagnostic log and the CLI — but nothing
compared them, so they could drift silently.

They are not equal, and must not be: the log's sentences are lower-case
phrases a reason= field completes. Measured 2026-10-01 over all of them, the
relation that holds is equality with the first character compared
case-insensitively. That one allowed difference is real — resumeRangeIgnored
opens with "S3", which must not become "s3". No catalogue sentence ends with
a period, so nothing is stripped; a stripping branch would go unexercised.

everyCase becomes everySample, which carries each sample's format argument
beside it, so the three payload-bearing keys can be formatted the way message
formats them. One exhaustive switch feeds both readers rather than a second
copy, and everyCase keeps its three existing callers unchanged.

Proved by planting a reworded outOfStorage entry: the guard named it. The
guard also asserts everySample is non-empty, so an emptied-out list cannot
read as a pass.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Task 7: closeout

**Files:**
- Modify: `docs/BACKLOG.md` — seven rows closed, three stale spots corrected
- Possibly modify: the user documentation repository (see Step 3)

**Interfaces:**
- Consumes: the commits of Tasks 1–6, by hash.
- Produces: nothing.

- [ ] **Step 1: Close the seven rows from the diff, not from the plan**

Read the actual commits first — `git log --oneline` for this branch and
`git diff --stat 0f55446d..HEAD` — and write each row's closing sentence from
what the diff shows. A report written from intent rather than from the diff is
the failure this project has a rule about.

Each of the seven rows gets, appended to its existing text (never replacing
it — the rows are a measurement record):

- `:172` `resumeNotSupported` — **Done**, with the date, the commit, and
  what pinned the PAIR: the conformer set and the override set, plus the two
  real instances. Record the decision that WebDAV's `false` is permanent.
- `:173` Depth-0 PROPFIND — **Done**, with the new finding's name, the three
  readers' table, and that the finding count went 17 → 18.
- `:174` `parseObjectKeys` — **Done**, noting the change is invisible today
  and why it was still worth making.
- `:175` `parseUploadID` — **Done by a DECISION, not a change**, naming the
  maintainer's decision of 2026-10-01 and its cost argument.
- `:176` upload-stream seam — **Done**, naming the alias, and that the plant
  that was green on 2026-09-28 is red now.
- `:177` `readsAsConnectionFailure` — **Done by a MEASUREMENT, not a
  change**, with the four gates and both independent reasons.
- `:178` `logSentence` — **Done**, with the relation that was measured
  (16 of 17 under the naive rule, all under the first-character rule) and the
  zero for trailing periods.

- [ ] **Step 2: Correct the three stale spots**

All three are claims this file makes about other code that are no longer
true. Verify each one again before writing the correction — the point of this
step is that a citation gets re-read, not re-remembered.

1. The row "Wall-clock ceilings still in the tree" (`:20`) ends by saying
   `ConnectionDiagnosticsTests.theRunnerWalksTheUniversalStepsInTheOrderTheReportPrints`
   (`:205`, `[.ok, .ok, .ok, .ok, .ok]`) "keeps the shape and is open". It
   does not. Confirm with
   `grep -rn "\[\.ok" Tests/macSCPCoreTests/ConnectionDiagnostics*.swift`
   (expected: no output) and read the case at
   `Tests/macSCPCoreTests/ConnectionDiagnosticsTests.swift:198`, which
   asserts the order and `failed.isEmpty`. Replace the stale sentence with
   what the tree now says, naming the date it was checked.
2. "If you don't know where to start" (`:301`) lists three candidates. Its
   third, "The capability boundary", is **Implemented since 2026-08-28** per
   the row at `:120`; the other two ("Single click no longer connects",
   "Known-hosts column sorting") have no row in the file — confirm with
   `grep -n "Single click no longer connects" docs/BACKLOG.md`, which should
   return only the line inside this section. Replace the three with
   candidates that are actually open, chosen from the rows, and say when the
   section was last checked.
3. The `:172` row cites `Sources/MacSCPAppKit/RemoteBrowserViewModel.swift`.
   The file is at `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift`
   — confirm with `ls`, then correct the path.

- [ ] **Step 3: Decide the user documentation by reading, not by assuming**

One change in this branch alters a sentence a user can see: Task 2's new
finding, for a server answering malformed XML to a single-resource request.
Everything else is a test, a comment, or an error path no reader reaches.

The user docs live in the separate repository
`/Users/noidee/_dev/noix-docs` (GitHub `NoiXdev/noix-docs`), under
`src/content/docs/macscp/`. Read
`src/content/docs/macscp/reference/troubleshooting.md` and decide whether a
reader looking up this message would find it. Report the decision and the
reason either way; if an edit is warranted, do it in a git worktree on its
own branch, run both `npm run build` and `npm run check`, and report both
results. That repository is shared with other products and other sessions —
never touch a branch or working tree someone else has open.

- [ ] **Step 4: Run the whole suite one last time**

Run: `swift test --build-system native`

Expected: PASS except the one known `ViewTestabilitySpike` failure. Record
the test and suite counts; the baseline at the branch point was 6623 tests in
568 suites.

- [ ] **Step 5: Commit**

```bash
git add docs/BACKLOG.md
git commit -F - <<'MSG'
docs(backlog): the seven typed-findings tails, and three stale citations

Closes the seven rows the typed-findings plan left on 2026-09-28. Two of them
close without a code change: parseUploadID by the maintainer's decision of
2026-10-01, and readsAsConnectionFailure by a measurement that dissolved its
premise — isConnectionFailure only selects a branch, and four gates inside it
decide the status.

Three stale spots in this file, found while reading those rows rather than
searched for:

- The wall-clock row called its twin in ConnectionDiagnosticsTests open; the
  [.ok, .ok, .ok, .ok, .ok] assertion is gone from the tree.
- "If you don't know where to start" recommended the capability boundary,
  implemented since 2026-08-28, and two candidates with no row in the file.
- The resumeNotSupported row named the wrong module for
  RemoteBrowserViewModel.swift.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Notes for the coordinator

- **Task order matters once:** Task 6's exhaustive switch does not compile
  without Task 2's case. Tasks 1, 3, 4 and 5 are independent of each other
  and of Task 2.
- **Task 2 owns the clean build.** It is the change the "incremental build can
  crash after `RemoteFSFinding` gains a case" row describes.
- **The known red.** `ViewTestabilitySpike`'s pixel comparison fails on
  macOS 27 and is recorded in `docs/BACKLOG.md` as an expired measurement. It
  is not this plan's to fix; a reviewer seeing it should not treat it as a
  regression.
- **Every planted probe is reverted by an inverse asserted replacement**, not
  by `git checkout -- <file>`, which restores from the index and takes other
  uncommitted edits with it. After each revert, `git diff --stat` on that one
  file must print nothing.
- **Do not push.** The whole-branch review comes first.
