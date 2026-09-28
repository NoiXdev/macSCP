# Typed `RemoteFSError` findings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the sixteen macSCP-authored English `reason:` strings a
user can actually read with thirteen typed findings, so every transfer
failure message is translated in `en`, `de`, `fr` and `pl`.

**Architecture:** One new `RemoteFSError` case, `.finding(RemoteFSFinding)`,
carrying a nested enum whose catalogue key is DERIVED from the case — the
`RemoteFSError.BucketLevelOperation.refusalMessageKey` pattern. Each mapper
over `RemoteFSError` gains one arm rather than one per meaning. Core keeps a
fixed English sentence per finding for the diagnostic log and the CLI, the
`TunnelFailureKind.sentence` precedent.

**Tech Stack:** Swift 6 strict concurrency, SwiftPM, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-28-typed-remote-fs-findings-design.md`
— read it for the measurement, the three-way split of the 69 sites, and what
is deliberately out of scope.

## Global Constraints

- Build and test with `swift test --build-system native`. The default build
  system fails locally on SwiftTerm's `Shaders.metal`.
- Swift 6 language mode, every target; zero warnings.
- Code, comments, test names and commit messages are English.
- Commit footer: `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
  The string `Claude Fable 5` must appear in no commit message.
- A finding may carry a status code and the caller's own path. **Never an
  endpoint, never a server's words, never a secret.** That is what lets the
  browser banner and `DialSupport` render it at all.
- User-facing strings only through `CoreL10n.string(_:)`. Four catalogues,
  `en` is the source the others are measured against. German addresses the
  user as **du** (`GermanAddressFormTests`).
- A negative check needs a positive check beside it.
- A number or an enumeration written into a comment is counted in that same
  moment.
- No wall-clock ceiling in a test. Tests never block the cooperative pool.
- Findings 1 and 2 (`resumeRangeIgnored`, `sourceChangedSinceInterruption`)
  keep their **English sentence verbatim** — both are quoted in the published
  user documentation. Every other finding's English may be rewritten.
- `TransferFailureKind.finding(_:)` composes the same frame the site composed
  before: `core.error.connectionLost %@` where the finding reads as a
  connection failure, `core.transfer.failed %@` otherwise. Composition for
  composition **at the Core level** — the audit line and the CLI keep their
  shape.
- **The App's transfer row does change shape, and that is intended.** Found
  by Task 2's review, stated here because the constraint above was written
  as if nothing changed. `TransferFailureLabel.sentence(for:)`
  (`Sources/MacSCPAppKit/TransferFailureLabel.swift:128-144`) classifies
  `.protocolError` as `.app` — "The server sent an answer that could not be
  used. (technical detail: …)", a translated sentence with English inside the
  parenthesis — and a `.finding` as `.core`, rendered as the finding's own
  translated message inside `core.transfer.failed %@`. A converted site
  therefore moves from the first shape to the second. That is the point of
  the work: the parenthesis existed to carry English no catalogue could
  reach. Every task reports the shape change for its own sites rather than
  claiming none, and Task 6 writes it into the user documentation.

---

## File Structure

**Created**
- `Sources/macSCPCore/RemoteFS/RemoteFSFinding.swift` — the finding enum, its
  `Name`, the derived `messageKey`/`message`, the English `logSentence`, and
  `readsAsConnectionFailure`.
- `Tests/macSCPCoreTests/RemoteFSFindingTests.swift` — the type's own guards.

**Modified**
- `Sources/macSCPCore/RemoteFS/RemoteFSError.swift` — the `.finding` case and
  `isConnectionFailure`.
- `Sources/macSCPCore/Presentation/TransferFailureKind.swift`,
  `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift`,
  `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift`,
  `Sources/macSCPCore/Diagnostics/DialProbes.swift`,
  `Sources/macSCPCore/CLI/CLIErrorMapping.swift` — one arm each.
- `Sources/macSCPCore/Resources/{en,de,fr,pl}.lproj/Localizable.strings`.
- `Tests/macSCPCoreTests/LocalizationParityTests.swift` — the derived-key
  guard.
- The six backends: `WebDAV/WebDAVFileSystem.swift`, `S3/S3FileSystem.swift`,
  `S3/S3Uploader.swift`, `S3/S3ListParser.swift`, `S3/S3HTTPChannel.swift`,
  `S3/S3RedirectSessionDelegate.swift`, `RemoteFS/LocalFileSystem.swift`,
  `HTTP/HTTPTransport.swift`.

---

### Task 1: `RemoteFSFinding`, its catalogue, and every consumer's arm

The type, all four catalogues, and enough arms that the package builds again.
Nothing throws a finding yet — that is Tasks 2–5.

**Files:**
- Create: `Sources/macSCPCore/RemoteFS/RemoteFSFinding.swift`
- Create: `Tests/macSCPCoreTests/RemoteFSFindingTests.swift`
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFSError.swift`
- Modify: `Sources/macSCPCore/Presentation/TransferFailureKind.swift`
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift:1618`
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift:1280`
- Modify: `Sources/macSCPCore/Diagnostics/DialProbes.swift:421`
- Modify: `Sources/macSCPCore/CLI/CLIErrorMapping.swift`
- Modify: `Sources/macSCPCore/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
- Modify: `Tests/macSCPCoreTests/LocalizationParityTests.swift`

**Interfaces — produced, and relied on by every later task:**
```swift
public enum RemoteFSFinding: Equatable, Sendable {
    case resumeRangeIgnored
    case sourceChangedSinceInterruption
    case unexpectedStatus(code: Int)
    case directoryAlreadyExists
    case destinationAlreadyExists
    case outOfStorage
    case uploadStreamUnavailable
    case pathExistsAndIsNotADirectory(path: String)
    case nonHTTPResponse
    case listingUnparsable
    case redirectUnreadable
    case redirectBodyNotResendable
    case redirectNotResignable

    public enum Name: String, CaseIterable, Sendable {
        case resumeRangeIgnored, sourceChangedSinceInterruption, unexpectedStatus
        case directoryAlreadyExists, destinationAlreadyExists, outOfStorage
        case uploadStreamUnavailable, pathExistsAndIsNotADirectory
        case nonHTTPResponse, listingUnparsable
        case redirectUnreadable, redirectBodyNotResendable, redirectNotResignable
    }
    public var name: Name { get }
    public var messageKey: String { get }
    public var message: String { get }
    public var logSentence: String { get }
    public var readsAsConnectionFailure: Bool { get }
}
// on RemoteFSError
case finding(RemoteFSFinding)
```

- [ ] **Step 1: Write the failing catalogue guard**

Append to `Tests/macSCPCoreTests/LocalizationParityTests.swift`, inside the
same suite that holds `everyBucketLevelOperationHasItsOwnSentence` (read that
test at `:628` first and mirror its structure — it is the precedent this one
is derived from):

```swift
@Test func everyRemoteFSFindingHasItsOwnSentence() throws {
    var seen: [String: String] = [:]
    var declaringCatalogs = 0
    for (reference, _) in try Self.allCatalogs() {
        guard reference.entries[RemoteFSFinding.nonHTTPResponse.messageKey] != nil
        else { continue }
        declaringCatalogs += 1
        for name in RemoteFSFinding.Name.allCases {
            let key = RemoteFSFinding.messageKey(for: name)
            let value = reference.entries[key]
            #expect(value != nil, """
                \(reference.label) has no sentence for \(name): \(key) is missing, \
                so the finding renders as its own key.
                """)
            guard let value else { continue }
            // Two findings sharing a sentence means one of them was pasted
            // rather than written.
            #expect(seen[value] == nil, """
                \(reference.label) uses the same sentence for \(name) and for \
                \(seen[value] ?? "?"): \(value)
                """)
            seen[value] = name.rawValue
        }
    }
    #expect(declaringCatalogs == 1, """
        Expected exactly one catalog to declare the finding sentences, \
        found \(declaringCatalogs).
        """)
}
```

Note the `messageKey(for:)` static: the guard needs a key from a `Name`
alone, since it has no payload to build a case with. Provide both — the
static from a `Name`, and the instance property that calls it.

- [ ] **Step 2: Run it to see it fail**

```bash
swift test --build-system native --filter everyRemoteFSFindingHasItsOwnSentence
```
Expected: FAIL to compile — `RemoteFSFinding` does not exist.

- [ ] **Step 3: Write `RemoteFSFinding`**

`Sources/macSCPCore/RemoteFS/RemoteFSFinding.swift`. Write the doc comment
first: state that the key is derived so a renamed case carries it, that a
finding never carries an endpoint or a server's words, and that
`readsAsConnectionFailure` is what `RemoteFSError.isConnectionFailure` reads
for this case.

```swift
public var name: Name {
    switch self {
    case .resumeRangeIgnored: return .resumeRangeIgnored
    case .sourceChangedSinceInterruption: return .sourceChangedSinceInterruption
    case .unexpectedStatus: return .unexpectedStatus
    case .directoryAlreadyExists: return .directoryAlreadyExists
    case .destinationAlreadyExists: return .destinationAlreadyExists
    case .outOfStorage: return .outOfStorage
    case .uploadStreamUnavailable: return .uploadStreamUnavailable
    case .pathExistsAndIsNotADirectory: return .pathExistsAndIsNotADirectory
    case .nonHTTPResponse: return .nonHTTPResponse
    case .listingUnparsable: return .listingUnparsable
    case .redirectUnreadable: return .redirectUnreadable
    case .redirectBodyNotResendable: return .redirectBodyNotResendable
    case .redirectNotResignable: return .redirectNotResignable
    }
}

/// The catalogue key for a name. A `Name` rather than a case, so a guard
/// that iterates `allCases` can ask for the key without inventing a
/// payload.
///
/// The two names that interpolate carry the format specifier in the key,
/// as this project's other argument-taking keys do
/// (`core.transfer.notFound %@`).
public static func messageKey(for name: Name) -> String {
    switch name {
    case .unexpectedStatus, .pathExistsAndIsNotADirectory:
        return "core.finding.\(name.rawValue) %@"
    case .resumeRangeIgnored, .sourceChangedSinceInterruption,
         .directoryAlreadyExists, .destinationAlreadyExists, .outOfStorage,
         .uploadStreamUnavailable, .nonHTTPResponse, .listingUnparsable,
         .redirectUnreadable, .redirectBodyNotResendable, .redirectNotResignable:
        return "core.finding.\(name.rawValue)"
    }
}

public var messageKey: String { Self.messageKey(for: name) }

public var message: String {
    switch self {
    case .unexpectedStatus(let code):
        return String(format: CoreL10n.string(messageKey), String(code))
    case .pathExistsAndIsNotADirectory(let path):
        return String(format: CoreL10n.string(messageKey), path)
    case .resumeRangeIgnored, .sourceChangedSinceInterruption,
         .directoryAlreadyExists, .destinationAlreadyExists, .outOfStorage,
         .uploadStreamUnavailable, .nonHTTPResponse, .listingUnparsable,
         .redirectUnreadable, .redirectBodyNotResendable, .redirectNotResignable:
        return CoreL10n.string(messageKey)
    }
}
```

**No `default:` in either.** Every switch in this type is exhaustive, so a
finding added later must decide whether it interpolates. A `default:` here
would hand a new payload-carrying finding a key without its ` %@` and an
un-interpolated sentence, silently, and the catalogue guard could not see it
— it derives the key the same way.

`readsAsConnectionFailure` is an exhaustive switch — no `default:`, so a
finding added later must decide:

```swift
public var readsAsConnectionFailure: Bool {
    switch self {
    case .redirectUnreadable, .redirectBodyNotResendable, .redirectNotResignable:
        return true
    case .resumeRangeIgnored, .sourceChangedSinceInterruption, .unexpectedStatus,
         .directoryAlreadyExists, .destinationAlreadyExists, .outOfStorage,
         .uploadStreamUnavailable, .pathExistsAndIsNotADirectory,
         .nonHTTPResponse, .listingUnparsable:
        return false
    }
}
```

`logSentence` is the fixed English for the diagnostic log and the CLI, also
exhaustive. Use the sentences in Step 5's `en` column, with the argument
interpolated directly (`"the server answered with status \(code)"`) — a log
line is not read through a catalogue.

- [ ] **Step 4: Add the case to `RemoteFSError` and teach `isConnectionFailure`**

```swift
/// A finding this project named, rather than a sentence it wrote: the
/// case a mapper can derive a catalogue key from. See `RemoteFSFinding`.
case finding(RemoteFSFinding)
```

```swift
public var isConnectionFailure: Bool {
    if case .connectionFailed = self { return true }
    if case .finding(let finding) = self { return finding.readsAsConnectionFailure }
    return false
}
```

Update the property's doc comment in the same pass — it currently says
"True only for `.connectionFailed`", which this change makes false. It is the
"comments that describe other code" rule applied to the line directly above
the change.

- [ ] **Step 5: Write the catalogue entries**

Append to each of the four `Localizable.strings` files under
`Sources/macSCPCore/Resources/`, in the order below.

`en.lproj`:
```
"core.finding.resumeRangeIgnored" = "S3 did not answer with the byte range asked for, so the download was not resumed";
"core.finding.sourceChangedSinceInterruption" = "The file changed on the server since the interrupted download, so nothing was added to the partial file";
"core.finding.unexpectedStatus %@" = "The server answered with status %@";
"core.finding.directoryAlreadyExists" = "A file or folder with that name already exists";
"core.finding.destinationAlreadyExists" = "The destination already exists";
"core.finding.outOfStorage" = "The server is out of storage";
"core.finding.uploadStreamUnavailable" = "The upload stream could not be created";
"core.finding.pathExistsAndIsNotADirectory %@" = "Something is already at %@ and it is not a folder";
"core.finding.nonHTTPResponse" = "The server's answer was not an HTTP response";
"core.finding.listingUnparsable" = "The folder listing the server sent could not be read";
"core.finding.redirectUnreadable" = "The server redirected the request somewhere that could not be read, so it was refused";
"core.finding.redirectBodyNotResendable" = "The server redirected an upload, and its data cannot be sent a second time, so the redirect was refused";
"core.finding.redirectNotResignable" = "The server redirected the request, and the new target could not be signed, so the redirect was refused";
```

`de.lproj`:
```
"core.finding.resumeRangeIgnored" = "S3 hat nicht den angeforderten Byte-Bereich geliefert, deshalb wurde der Download nicht fortgesetzt";
"core.finding.sourceChangedSinceInterruption" = "Die Datei hat sich auf dem Server seit dem abgebrochenen Download geändert, deshalb wurde der unvollständigen Datei nichts hinzugefügt";
"core.finding.unexpectedStatus %@" = "Der Server hat mit Status %@ geantwortet";
"core.finding.directoryAlreadyExists" = "Eine Datei oder ein Ordner mit diesem Namen ist bereits vorhanden";
"core.finding.destinationAlreadyExists" = "Das Ziel ist bereits vorhanden";
"core.finding.outOfStorage" = "Der Server hat keinen Speicherplatz mehr";
"core.finding.uploadStreamUnavailable" = "Der Upload-Datenstrom konnte nicht erstellt werden";
"core.finding.pathExistsAndIsNotADirectory %@" = "Unter %@ liegt bereits etwas, das kein Ordner ist";
"core.finding.nonHTTPResponse" = "Die Antwort des Servers war keine HTTP-Antwort";
"core.finding.listingUnparsable" = "Die Ordnerliste, die der Server geschickt hat, konnte nicht gelesen werden";
"core.finding.redirectUnreadable" = "Der Server hat die Anfrage an ein Ziel weitergeleitet, das nicht gelesen werden konnte; sie wurde abgelehnt";
"core.finding.redirectBodyNotResendable" = "Der Server hat einen Upload weitergeleitet; dessen Daten lassen sich kein zweites Mal senden, deshalb wurde die Weiterleitung abgelehnt";
"core.finding.redirectNotResignable" = "Der Server hat die Anfrage weitergeleitet; das neue Ziel konnte nicht signiert werden, deshalb wurde die Weiterleitung abgelehnt";
```

`fr.lproj`:
```
"core.finding.resumeRangeIgnored" = "S3 n'a pas répondu avec la plage d'octets demandée, le téléchargement n'a donc pas été repris";
"core.finding.sourceChangedSinceInterruption" = "Le fichier a changé sur le serveur depuis le téléchargement interrompu, rien n'a donc été ajouté au fichier partiel";
"core.finding.unexpectedStatus %@" = "Le serveur a répondu avec le statut %@";
"core.finding.directoryAlreadyExists" = "Un fichier ou un dossier portant ce nom existe déjà";
"core.finding.destinationAlreadyExists" = "La destination existe déjà";
"core.finding.outOfStorage" = "Le serveur n'a plus d'espace de stockage";
"core.finding.uploadStreamUnavailable" = "Le flux d'envoi n'a pas pu être créé";
"core.finding.pathExistsAndIsNotADirectory %@" = "Quelque chose se trouve déjà à %@ et ce n'est pas un dossier";
"core.finding.nonHTTPResponse" = "La réponse du serveur n'était pas une réponse HTTP";
"core.finding.listingUnparsable" = "La liste du dossier envoyée par le serveur n'a pas pu être lue";
"core.finding.redirectUnreadable" = "Le serveur a redirigé la requête vers une cible illisible, elle a donc été refusée";
"core.finding.redirectBodyNotResendable" = "Le serveur a redirigé un envoi, et ses données ne peuvent pas être envoyées une seconde fois : la redirection a été refusée";
"core.finding.redirectNotResignable" = "Le serveur a redirigé la requête, et la nouvelle cible n'a pas pu être signée : la redirection a été refusée";
```

`pl.lproj`:
```
"core.finding.resumeRangeIgnored" = "S3 nie odpowiedział żądanym zakresem bajtów, więc pobieranie nie zostało wznowione";
"core.finding.sourceChangedSinceInterruption" = "Plik zmienił się na serwerze od czasu przerwanego pobierania, więc do niepełnego pliku nic nie dodano";
"core.finding.unexpectedStatus %@" = "Serwer odpowiedział statusem %@";
"core.finding.directoryAlreadyExists" = "Plik lub folder o tej nazwie już istnieje";
"core.finding.destinationAlreadyExists" = "Miejsce docelowe już istnieje";
"core.finding.outOfStorage" = "Na serwerze zabrakło miejsca";
"core.finding.uploadStreamUnavailable" = "Nie udało się utworzyć strumienia wysyłania";
"core.finding.pathExistsAndIsNotADirectory %@" = "Pod %@ już coś jest i nie jest to folder";
"core.finding.nonHTTPResponse" = "Odpowiedź serwera nie była odpowiedzią HTTP";
"core.finding.listingUnparsable" = "Nie udało się odczytać listy folderu przysłanej przez serwer";
"core.finding.redirectUnreadable" = "Serwer przekierował żądanie w miejsce, którego nie dało się odczytać, więc je odrzucono";
"core.finding.redirectBodyNotResendable" = "Serwer przekierował wysyłanie, a jego danych nie można wysłać drugi raz, więc przekierowanie odrzucono";
"core.finding.redirectNotResignable" = "Serwer przekierował żądanie, a nowego celu nie udało się podpisać, więc przekierowanie odrzucono";
```

- [ ] **Step 6: Add the mapper arms**

`TransferFailureKind` gains a case and a `message` arm:
```swift
/// A finding this project named. The frame is the one the site composed
/// before it was typed, so no English message a user reads changed.
case finding(RemoteFSFinding)
```
```swift
case .finding(let finding):
    let frame = finding.readsAsConnectionFailure
        ? "core.error.connectionLost %@" : "core.transfer.failed %@"
    return String(format: CoreL10n.string(frame), finding.message)
```
and a `Name` case `finding` with its arm in `name`.

`TransferQueueViewModel.failureKind(for:)` — place the arm beside the
`.protocolError` one:
```swift
case RemoteFSError.finding(let finding):
    // No filter: a finding carries a status code or the caller's own
    // path, never text this module did not write. That is the property
    // `RemoteFSFinding`'s doc comment states and
    // `noFindingCarriesForeignText` holds.
    return .finding(finding)
```

`RemoteBrowserViewModel.message(for:path:)` — above the `.protocolError`
arm:
```swift
// Rendered, not dropped: unlike a `reason`, a finding carries no
// endpoint, so the banner and the diagnostic log can both read it.
// This does NOT make the browser a `TransferFailureKind` consumer —
// the backlog row that forbids that still stands; the finding is read
// directly.
case RemoteFSError.finding(let finding):
    return finding.message
```

`DialSupport.reason(for:)` in `DialProbes.swift` — inside the
`case let error as RemoteFSError` switch:
```swift
case .finding(let finding):
    // The log's own English, from the finding rather than from a
    // sentence a backend wrote — the `TunnelFailureKind.sentence`
    // arrangement.
    //
    // The KIND is preserved, not defaulted: ten of the thirteen
    // findings travelled as `.protocolError` and rendered as
    // `known(.serverAnswerUnusable)`, and the three redirect
    // refusals travelled as `.connectionFailed`
    // (`S3HTTPChannel.swift:129`) and rendered as
    // `known(.connectionFailed)`. Counted 2026-09-28 against the
    // spec's sixteen sites. Returning `.unknown` for all of them
    // would reclassify the redirects in the diagnostics while every
    // other consumer's frame is deliberately preserved.
    return (
        finding.readsAsConnectionFailure ? .connectionFailed : .serverAnswerUnusable,
        finding.logSentence)
```

The sentence each of these carries DOES change — from the kind's generic one
to the finding's own. That is the improvement; the classification beside it
is what must not move. Say both in the commit message.

`CLIErrorMapping.swift` — read both `RemoteFSError` switches (`:118`,
`:288`), add whatever arm each needs, and follow the file's own convention
for how it renders a case.

Then build and fix every remaining exhaustiveness break:
```bash
swift build --build-system native 2>&1 | grep -c "must be exhaustive"
```
Do not trust the list above — search for the rest rather than assuming it is
complete, and report every consumer you found that this plan did not name.

- [ ] **Step 7: Write the type's own guards**

`Tests/macSCPCoreTests/RemoteFSFindingTests.swift`:

```swift
@Test func exactlyTheRedirectFindingsReadAsAConnectionFailure() {
    let connectionFailures: Set<RemoteFSFinding.Name> =
        [.redirectUnreadable, .redirectBodyNotResendable, .redirectNotResignable]
    for finding in RemoteFSFinding.everyCase {
        #expect(
            finding.readsAsConnectionFailure
                == connectionFailures.contains(finding.name),
            "\(finding.name) reads as a connection failure: \(finding.readsAsConnectionFailure)")
        // The positive beside the negative: the error wrapping it agrees.
        #expect(
            RemoteFSError.finding(finding).isConnectionFailure
                == finding.readsAsConnectionFailure)
    }
}

@Test func everyFindingResolvesToASentenceAndNotToItsKey() {
    for finding in RemoteFSFinding.everyCase {
        #expect(finding.message != finding.messageKey, "\(finding.name) renders as its key")
        #expect(finding.logSentence.isEmpty == false)
        // The positive: the sentence is the catalogue's, not the key text.
        #expect(finding.message.hasPrefix("core.finding.") == false)
    }
}

@Test func noFindingCarriesForeignText() {
    for finding in RemoteFSFinding.everyCase {
        for text in [finding.message, finding.logSentence] {
            let carriesUserinfo = text != URLText.withoutUserinfo(text)
            #expect(carriesUserinfo == false, "\(finding.name) carries a URL with userinfo")
            #expect(text.contains("://") == false, "\(finding.name) carries a URL")
        }
    }
}
```

`everyCase` is a test-side list built from `Name.allCases` with a sample
payload per name, written as an exhaustive `switch` over `Name` so a new
finding cannot be left out of these three guards. Put it in the test file,
not in the shipping type.

- [ ] **Step 8: Run the suite**

```bash
swift test --build-system native 2>&1 | tail -20
```
Expected: PASS, no warnings.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -F - <<'MSG'
feat(core): RemoteFSFinding, a named finding a mapper can translate

<what the diff shows, including every consumer you had to give an arm
and any this plan did not name>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

### Task 2: WebDAV's six sites

**Files:**
- Modify: `Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift:351`, `:459`,
  `:647`, `:649`, `:650`, `:652`
- Test: `Tests/macSCPCoreTests/` — the existing WebDAV suites; find them with
  `grep -rln "WebDAVFileSystem\|mapStatus" Tests/` and add to the ones that
  already cover these conditions rather than creating a new file.

**Interfaces — consumes:** `RemoteFSFinding` from Task 1.

- [ ] **Step 1: Write the failing tests**

One per site's condition. `mapStatus` is `static` and takes its inputs
directly, so four of the six need no server:

```swift
@Test func aRefusedMKCOLReportsThatSomethingIsAlreadyThere() {
    #expect(throws: RemoteFSError.finding(.directoryAlreadyExists)) {
        try WebDAVFileSystem.mapStatus(405, path: "/a", method: "MKCOL")
    }
}

@Test func aPreconditionFailureReportsAnExistingDestination() {
    #expect(throws: RemoteFSError.finding(.destinationAlreadyExists)) {
        try WebDAVFileSystem.mapStatus(412, path: "/a", method: "MOVE")
    }
}

@Test func aFullServerReportsItsStorage() {
    #expect(throws: RemoteFSError.finding(.outOfStorage)) {
        try WebDAVFileSystem.mapStatus(507, path: "/a", method: "PUT")
    }
}

@Test func anyOtherStatusIsReportedAsTheStatusItself() {
    #expect(throws: RemoteFSError.finding(.unexpectedStatus(code: 503))) {
        try WebDAVFileSystem.mapStatus(503, path: "/a", method: "PROPFIND")
    }
}
```

The other two (`:351` the changed source on a resumed download, `:459` the
upload stream) are covered by existing tests that assert the current
`protocolError(reason:)`; change those assertions to the finding rather than
writing new cases. Find them with
`grep -rn "sourceChangedReason\|Could not create the upload stream" Tests/`.

- [ ] **Step 2: Run them to see them fail**

```bash
swift test --build-system native --filter WebDAV 2>&1 | tail -20
```
Expected: FAIL — the sites still throw `protocolError(reason:)`.

- [ ] **Step 3: Convert the sites**

```swift
case 405 where method == "MKCOL":
    throw RemoteFSError.finding(.directoryAlreadyExists)
case 409: throw RemoteFSError.notFound(path: path)
case 412: throw RemoteFSError.finding(.destinationAlreadyExists)
case 507: throw RemoteFSError.finding(.outOfStorage)
default:
    throw RemoteFSError.finding(.unexpectedStatus(code: status))
```

The `default:` arm drops `method` from the message. That is deliberate: the
HTTP method is not information a user acts on, and the queue row already
names the file and the direction. Say so in a comment there.

`:351` becomes `throw RemoteFSError.finding(.sourceChangedSinceInterruption)`,
`:459` becomes `throw RemoteFSError.finding(.uploadStreamUnavailable)`.

**Leave `Self.sourceChangedReason` in place** and point its doc comment at
the finding: it is the English the user documentation quotes, and it is now
`RemoteFSFinding`'s `logSentence`/`en` entry. Delete it only if nothing reads
it — check with `grep -rn "sourceChangedReason" Sources/ Tests/` and report
the count either way.

**Do not touch the 412 arm's meaning.** `docs/BACKLOG.md` carries an open row
saying this arm renders a source-precondition 412 as a destination problem.
This conversion preserves that, wrong case included, so the row stays open
and honest. Note it in the commit message.

- [ ] **Step 4: Run the tests**

```bash
swift test --build-system native 2>&1 | tail -20
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -F - <<'MSG'
refactor(webdav): six reasons become findings a reader can be given in their language

<what the diff shows; name the 412 row you did not fix>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

### Task 3: S3's six sites

**Files:**
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift:522`, `:537`, `:545`,
  `:1210`
- Modify: `Sources/macSCPCore/S3/S3Uploader.swift:335`
- Modify: `Sources/macSCPCore/S3/S3ListParser.swift:38`
- Test: the existing S3 suites (`grep -rln "S3FileSystem\|S3ListParser" Tests/`)

**Interfaces — consumes:** `RemoteFSFinding` from Task 1.

- [ ] **Step 1: Write the failing tests**

Existing tests already assert these reasons; find them first:
```bash
grep -rn "rangeIgnoredReason\|sourceChangedReason\|failed with HTTP status\|Failed to parse S3" Tests/
```
Change each assertion to the finding it should now be, and add a case for any
of the six with no existing coverage. `S3ListParser.parse` takes `Data`, so
its test needs no server: hand it a body that is not the expected XML and
expect `.finding(.listingUnparsable)`.

- [ ] **Step 2: Run them to see them fail**

```bash
swift test --build-system native --filter S3 2>&1 | tail -20
```
Expected: FAIL.

- [ ] **Step 3: Convert the sites**

- `:522` → `throw RemoteFSError.finding(.resumeRangeIgnored)`
- `:537` → `throw RemoteFSError.finding(.sourceChangedSinceInterruption)`
- `:545` → `throw RemoteFSError.finding(.unexpectedStatus(code: response.statusCode))`
- `:1210` → `return .finding(.unexpectedStatus(code: statusCode))`
- `S3Uploader.swift:335` → `return .finding(.unexpectedStatus(code: statusCode))`
- `S3ListParser.swift:38` → `throw RemoteFSError.finding(.listingUnparsable)`

`S3ListParser:38` drops the parser's own `reason` from the message. The
parser reason is macSCP's own text about XML shape; no mapper rendered it to
a user except the queue, and no reader acts on it. Say so at the site. The
sibling at `:62` is **not** in scope (it is unreachable from any mapper) —
leave it.

Keep `rangeIgnoredReason` and `sourceChangedReason` as constants, as Task 2
does for WebDAV's, and report whether anything still reads them.

- [ ] **Step 4: Run the tests**

```bash
swift test --build-system native 2>&1 | tail -20
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -F - <<'MSG'
refactor(s3): six reasons become findings a reader can be given in their language

<what the diff shows>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

### Task 4: the refused redirect, and the one site that reads as a lost connection

The only `.connectionFailed` site in scope, and the only one whose conversion
can change behaviour. `S3RedirectSessionDelegate` records a `String` today;
it records a finding after this task.

**Files:**
- Modify: `Sources/macSCPCore/S3/S3RedirectSessionDelegate.swift:30`, `:45`,
  `:81`, `:102`, `:115`
- Modify: `Sources/macSCPCore/S3/S3HTTPChannel.swift:129`
- Check: `Sources/macSCPCore/Diagnostics/InternetSpeedProbe.swift:217` names
  `lastRefusedRedirect` in a comment — verify whether it also reads it, and
  fix the comment if the type change makes it wrong.
- Test: `grep -rln "lastRefusedRedirect\|redirect was refused" Tests/`

**Interfaces — consumes:** `RemoteFSFinding`, `readsAsConnectionFailure`.

- [ ] **Step 1: Write the failing behaviour test first**

The load-bearing one, before any conversion:

```swift
@Test func aRefusedRedirectStillReadsAsAConnectionFailure() {
    for finding in [RemoteFSFinding.redirectUnreadable,
                    .redirectBodyNotResendable, .redirectNotResignable] {
        #expect(RemoteFSError.finding(finding).isConnectionFailure)
    }
    // The positive beside it: a finding that is not a redirect does not.
    #expect(RemoteFSError.finding(.outOfStorage).isConnectionFailure == false)
}
```

Then one per refusal, asserting the delegate records the right finding.

- [ ] **Step 2: Run them to see them fail**

```bash
swift test --build-system native --filter Redirect 2>&1 | tail -20
```
Expected: FAIL.

- [ ] **Step 3: Convert**

```swift
private var refusal: RemoteFSFinding?
var lastRefusedRedirect: RemoteFSFinding? { … }
```
`record(.redirectUnreadable)` at `:81`, `record(.redirectBodyNotResendable)`
at `:102`, `record(.redirectNotResignable)` at `:115`. The re-signing arm
currently appends `error.localizedDescription`; that text is dropped, which
is the point — a finding carries no foreign words. Say so at the site.

`S3HTTPChannel.swift:129`:
```swift
redirectPolicy?.lastRefusedRedirect.map { RemoteFSError.finding($0) }
```

Update `lastRefusedRedirect`'s doc comment, which describes it as "the
sentence describing a redirect this delegate refused" — after this task it is
the finding, not a sentence.

- [ ] **Step 4: Run the tests**

```bash
swift test --build-system native 2>&1 | tail -20
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -F - <<'MSG'
refactor(s3): a refused redirect is a finding, and still reads as a lost connection

<what the diff shows, including the isConnectionFailure evidence>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

### Task 5: the local filesystem and the HTTP transport

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift:399`
- Modify: `Sources/macSCPCore/HTTP/HTTPTransport.swift:47`, `:56`
- Test: `grep -rln "LocalFileSystem\|HTTPTransport" Tests/`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func creatingAFolderWhereAFileSitsSaysSo() async throws {
    let file = // a temporary file path that exists and is not a directory
    await #expect(throws: RemoteFSError.finding(.pathExistsAndIsNotADirectory(path: file))) {
        try await LocalFileSystem().createDirectory(at: file)
    }
}
```
and one for the transport, handing `send` a `URLSession` stub whose response
is not an `HTTPURLResponse`. Follow whatever seam the existing
`HTTPTransport` tests already use; if there is none, the two sites are
covered by asserting `mapStatus`-level behaviour instead — report which you
did and why.

- [ ] **Step 2: Run them to see them fail**

```bash
swift test --build-system native --filter "LocalFileSystem|HTTPTransport" 2>&1 | tail -20
```
Expected: FAIL.

- [ ] **Step 3: Convert the three sites**

```swift
throw RemoteFSError.finding(.pathExistsAndIsNotADirectory(path: path))
```
```swift
throw RemoteFSError.finding(.nonHTTPResponse)
```
`LocalFileSystem.createDirectory`'s doc comment says "throws
`protocolError`" — correct it in the same pass.

- [ ] **Step 4: Run the whole suite**

```bash
swift test --build-system native 2>&1 | tail -20
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -F - <<'MSG'
refactor(core): the last three in-scope reasons become findings

<what the diff shows>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

### Task 6: the six sites the single-line recipe never saw

Added 2026-09-28, after Task 3's review found that the recipe every count in
this plan rests on requires `reason:` on the same line and searches only
`Sources/macSCPCore`. An independent census put the true figure at 93
construction sites where the design document said 69, and the in-scope set at
22 where it said 16. The maintainer took all six on 2026-09-28. The correction
is written up in the design document's own first section.

Four new findings, and two sites that reuse findings Task 1 already built.

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFSFinding.swift` (four cases,
  four `Name` cases, four arms in each of `name`, `messageKey(for:)` where
  they interpolate, `message`, `logSentence`, `readsAsConnectionFailure`)
- Modify: `Sources/macSCPCore/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift:1188`
- Modify: `Sources/macSCPCore/WebDAV/WebDAVPropfindParser.swift:83`
- Modify: `Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift:450`
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift:90`
- Modify: `Sources/macSCPCore/S3/S3Uploader.swift:276`
- Modify: `Sources/macSCPCore/S3/S3XMLText.swift:61`
- Test: the suites that already cover those files

**Interfaces — produced:**
```swift
case resumeNotSupported
case noSuchBucket(path: String)
case uploadPartUnacknowledged(part: Int)
case requestBodyUnencodable
```
`noSuchBucket` and `uploadPartUnacknowledged` interpolate, so their
`messageKey` carries ` %@`. All four have `readsAsConnectionFailure == false`
— all six sites are `.protocolError` today.

- [ ] **Step 1: Write the failing tests**

One per site's condition, in the suite that already covers that file. Four of
the six need no server:

```swift
@Test func creatingAFolderWhereAFileSitsSaysSoOverSSHToo() async throws {
    // The word-for-word twin of LocalFileSystem's, so it must reach the
    // SAME finding — a reader must not meet one sentence over SFTP and a
    // different one locally.
    #expect(
        RemoteFSFinding.pathExistsAndIsNotADirectory(path: "/a").message
            == RemoteFSFinding.pathExistsAndIsNotADirectory(path: "/a").message)
}
```
That one is a tautology — do not write it. Write instead a test that drives
`CitadelFileSystem.createDirectory(at:)` against the seam its existing tests
already use, and assert `.finding(.pathExistsAndIsNotADirectory(path:))`; if
that file's suite has no such seam, say so in the report rather than
inventing one, and pin the site by mutation evidence alone.

For the other five, assert the finding each site now throws, at the level
that file's existing suite already tests it. `WebDAVPropfindParser.parsed(_:)`
and `S3XMLText.escaped(_:)` take their input directly and need no server.

- [ ] **Step 2: Run them to see them fail**

```bash
swift test --build-system native 2>&1 | tail -20
```
Expected: FAIL — the sites still throw `protocolError(reason:)`.

- [ ] **Step 3: Add the four findings**

To `RemoteFSFinding`, in the order above, after the thirteen already there.
Every switch in the type is exhaustive; add an arm to each. `logSentence`
takes the English below, lower-cased and with the argument interpolated
directly, as the existing ones do.

- [ ] **Step 4: Write the catalogue entries**

`en.lproj`:
```
"core.finding.resumeNotSupported" = "The server cannot add to an existing file, so the transfer cannot be resumed";
"core.finding.noSuchBucket %@" = "This connection starts at the bucket list, and %@ names no bucket";
"core.finding.uploadPartUnacknowledged %@" = "The server did not confirm part %@ of the upload";
"core.finding.requestBodyUnencodable" = "A value in the request cannot be written in the format the server needs";
```

`de.lproj`:
```
"core.finding.resumeNotSupported" = "Der Server kann nichts an eine vorhandene Datei anhängen, deshalb lässt sich die Übertragung nicht fortsetzen";
"core.finding.noSuchBucket %@" = "Diese Verbindung beginnt bei der Bucket-Liste, und %@ benennt keinen Bucket";
"core.finding.uploadPartUnacknowledged %@" = "Der Server hat Teil %@ des Uploads nicht bestätigt";
"core.finding.requestBodyUnencodable" = "Ein Wert in der Anfrage lässt sich nicht in dem Format schreiben, das der Server braucht";
```

`fr.lproj`:
```
"core.finding.resumeNotSupported" = "Le serveur ne peut rien ajouter à un fichier existant, le transfert ne peut donc pas être repris";
"core.finding.noSuchBucket %@" = "Cette connexion démarre sur la liste des buckets, et %@ ne désigne aucun bucket";
"core.finding.uploadPartUnacknowledged %@" = "Le serveur n'a pas confirmé la partie %@ de l'envoi";
"core.finding.requestBodyUnencodable" = "Une valeur de la requête ne peut pas être écrite dans le format que le serveur exige";
```

`pl.lproj`:
```
"core.finding.resumeNotSupported" = "Serwer nie potrafi dopisać do istniejącego pliku, więc przesyłania nie można wznowić";
"core.finding.noSuchBucket %@" = "To połączenie zaczyna się od listy bucketów, a %@ nie wskazuje żadnego bucketa";
"core.finding.uploadPartUnacknowledged %@" = "Serwer nie potwierdził części %@ wysyłania";
"core.finding.requestBodyUnencodable" = "Wartości w żądaniu nie da się zapisać w formacie, którego wymaga serwer";
```

The four locales keep the word "bucket" — counted in the catalogues on
2026-09-28: `en`, `de`, `fr` and `pl` all spell it `bucket`
(`core.connect.s3BucketRequired` and its three siblings), Polish inflecting
it (`bucketów`, `bucketa`). Do not introduce a translated term for it here.

- [ ] **Step 5: Convert the six sites**

- `CitadelFileSystem.swift:1188` → `.finding(.pathExistsAndIsNotADirectory(path: path))`
- `WebDAVPropfindParser.swift:83` → `.finding(.listingUnparsable)`
- `WebDAVFileSystem.swift:450` → `.finding(.resumeNotSupported)`
- `S3FileSystem.swift:90` → `.finding(.noSuchBucket(path: path))`
- `S3Uploader.swift:276` → `.finding(.uploadPartUnacknowledged(part: partNumber))`
- `S3XMLText.swift:61` → `.finding(.requestBodyUnencodable)`

Two reuses, and each needs a comment saying why it is a reuse rather than a
new finding: the Citadel one because it is the word-for-word twin of
`LocalFileSystem.swift:399` and a reader must not meet two sentences for one
condition; the PROPFIND one because a PROPFIND body IS the WebDAV listing.
`everyRemoteFSFindingHasItsOwnSentence` forbids two findings sharing a
sentence, so a new finding for either would have needed a second way of
saying the same thing.

- [ ] **Step 6: Prove each site**

Plant a mutation per site (substitute a different finding, anchor asserted
before writing), run the narrowest filter, record red or green, restore
byte-for-byte with `git checkout --`, confirm `git status --porcelain` is
empty. Report red/green per site. A site that stays green is an honest
finding to report, not something to paper over.

- [ ] **Step 7: Recount and commit**

`Sources/MacSCPAppKit/TransferFailureLabel.swift` carries the count and its
recipe. Recount AFTER your edits land, not before, and correct both the
single-line figure and the enumeration of multi-line sites — six of them
become findings in this task, so the enumeration shrinks.

```bash
git add -A && git commit -F - <<'MSG'
refactor(core): the six sites the single-line recipe never saw

<what the diff shows, the per-site mutation evidence, the recounted
numbers, and the App-row shape change for these six>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

### Task 7: closeout

**Files:**
- Modify: `docs/BACKLOG.md`
- Modify: `/Users/noidee/_dev/noix-docs` on branch `docs/macscp-next`, in a
  worktree — **never** on a branch or working tree someone else has open.

- [ ] **Step 1: Recount the row, do not copy it**

Re-run the row's own recipe at the new HEAD:
```bash
grep -rn 'protocolError(reason:\|connectionFailed(reason:' Sources/macSCPCore | wc -l
```
and recompute the split (AgentError / comments / declarations / sites).

**That recipe is known to undercount** — it requires `reason:` on the same
line and searches only `Sources/macSCPCore`. Run the census method instead
(match the CASE NAME followed by `(` across any whitespace including
newlines, reading each file whole, per file — batching the files into one
`perl` invocation silently under-counts and misreports line numbers), over
all of `Sources/`. Write BOTH numbers into `docs/BACKLOG.md` with the date:
what the row's own recipe yields, and what the true count is. The row states
68; at `bcbea4f4` the true figure was 93 construction sites, and the row's
whole per-file breakdown (22 / 10 / 9 / 8 for the four biggest files) is
truly 26 / 10 / 12 / 13. Correct it, dated, and say which recipe produced
which number — the row is a measurement record, so the old number stays
visible as what was measured then.

Alongside it, what the work removed: twenty-two sites, seventeen findings.
Count both against the tree rather than copying them from here.

- [ ] **Step 2: Record what stays open, as its own rows**

- The `S3EndpointReason` block (recount it), left because typing it means
  deciding what a finding may say about an endpoint.
- The nine foreign-text passthroughs, left because the text is not ours.
- The 35 sites no mapper renders.
- The fourth entry point (`TransferFailureLabel.text(for:)` via the path bar
  and the editor banner), which this work now serves — say so, since the row
  it came from did not know about it.

- [ ] **Step 3: Check the two documented sentences**

```bash
grep -rn "byte range asked for\|changed on the server since the interrupted" \
  /Users/noidee/_dev/noix-docs/src/content/docs/macscp/
```
Both sentences are preserved verbatim by this plan. **Read the pages back**
rather than assuming: if a page quotes either sentence, confirm the English
still matches word for word, and say in the report which pages you read and
what they say.

- [ ] **Step 4: Write the user documentation**

The user-visible change is that failure messages now appear in the reader's
language. Add it to the matching page(s) under
`src/content/docs/macscp/guide/`, marked as coming in the next version.
`npm run build` and `npm run check` must both pass. Commit on
`docs/macscp-next`; **do not push** — the maintainer asks for that
separately.

- [ ] **Step 5: Commit the backlog**

```bash
git add docs/BACKLOG.md && git commit -F - <<'MSG'
docs(backlog): sixteen English reasons are findings now, and what stays open

<the recounted numbers, measured at this HEAD>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Self-review

**Spec coverage.** Each of the spec's twenty-two sites has a task: WebDAV's
six (Task 2), S3's six (Task 3), the redirect (Task 4), Local and the
transport's three (Task 5), and the six the single-line recipe never saw
(Task 6). The spec's type, catalogue, guards and three mapper arms are
Task 1; its documentation section is Task 7, and the six sites the recipe never saw are Task 6.

**Placeholders.** The `<what the diff shows>` markers in the commit-message
heredocs are deliberate and are the project's own rule ("a report says what
the diff shows"): the message is written from the diff, after the change, not
predicted here. Everything else — every catalogue string, every signature,
every converted line — is spelled out.

**Type consistency.** `RemoteFSFinding`, `Name`, `messageKey(for:)`,
`messageKey`, `message`, `logSentence`, `readsAsConnectionFailure` and
`RemoteFSError.finding` are spelled the same in Task 1's interface block and
in every later task that uses them.

**One thing Task 1 must report rather than assume.** The list of consumers
that need an arm was derived by reading four files and grepping; the
compiler is the authority. Task 1's report names every consumer it actually
had to touch, including any this plan did not predict.
