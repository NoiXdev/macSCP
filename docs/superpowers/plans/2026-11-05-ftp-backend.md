# FTP Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A fourth connection kind — FTP, FTPS explicit and FTPS implicit — with
full `RemoteFileSystem` conformance and presence in every surface a connection
has.

**Architecture:** A line-oriented control connection over SwiftNIO with
`swift-nio-ssl` for both TLS forms, one reserved command connection plus a
transfer pool per tab sized from `maxConcurrentTransfers`, and a pure listing
parser (`MLSD` where `FEAT` advertises it, `LIST` dialects otherwise) that
produces `RemoteFileItem`. Everything above the file system reaches FTP through
`ProtocolCapabilities` and the existing generic layers; no browser, queue or
compare code learns the new kind.

**Tech Stack:** Swift 6, SwiftPM, SwiftNIO (already a direct dependency),
`apple/swift-nio-ssl` (new), Swift Testing, Network.framework in test code only.

**Spec:** `docs/superpowers/specs/2026-11-05-ftp-backend-design.md`

## Global Constraints

Every task's requirements implicitly include these.

- Swift tools 6.0, **all targets `.swiftLanguageMode(.v6)`**, minimum macOS 15.
- `swift build` and `swift test` with **no `--build-system` flag**.
- Swift Testing (`@Test`/`#expect`), TDD red→green; prove each regression red
  first and quote the observed red in the commit message.
- **Code and comments in English.** No German in source files.
- **Never hardcode a display string.** `L10n.string(_:_:)` / `L10n.text(_:_:)`
  in the App, `CoreL10n.string(_:)` in Core; four catalogues — `en`, `de`, `fr`,
  `pl` — with byte-identical key sets, German in **du**-form.
- **No secret, credential, token or endpoint in any store, log, `reason:`
  string, audit detail, test name or test failure message.** `#expect` reports
  the source text of its expression, so such a value lives in a named constant
  with the `Bool` computed before the expectation
  (`#expect(inAuditLine == false)`). Secrets live only in `SecretStore`; the
  JSON stores and export envelopes never carry them.
- **Tests never block the cooperative pool:** no `syncShutdownGracefully()`, no
  `futureResult.wait()`, no `DispatchSemaphore.wait()`. Every wait is an
  `await`.
- **No wall-clock ceiling in a test.** Floors (`elapsed >= …`) are fine. Any
  `.timeLimit` is `.minutes(5)`, never `.minutes(1)`.
- **A negative source-scanning check needs a positive check beside it**, and
  before believing a zero, feed the pattern something it must match.
- **`TYPE I` only.** The backend never issues `TYPE A`.
- Docker rig commands run **from the main checkout `/Users/noidee/macSCP`**,
  never from a worktree.
- Conventional Commits; footer
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- A figure in a comment, commit message or `docs/` row travels with the command
  that produced it, run in the form it is committed.

## Review Focus

Five conditions the spec implies that no task's own happy path exercises. Each
line names the task that owns its test.

1. **A path containing CR or LF.** FTP commands are CRLF-terminated, so a file
   name carrying `\r\n` injects a command into the control channel — the FTP
   analogue of the header-injection class this project already met in
   `SigV4Signer`. Every path crossing into a command is validated at one choke
   point and refused by name. **Task 5.**
2. **A server that requires the data connection to resume the control
   connection's TLS session** (vsftpd's `require_ssl_reuse`, on by default). A
   backend that cannot do this fails against a large share of real FTPS
   servers, and a permissive rig never shows it. **Task 4**, with the stub able
   to require reuse.
3. **A file name that is not valid UTF-8**, on a server whose `FEAT` does not
   advertise `UTF8`. One undecodable name must not void the listing. **Task 2.**
4. **A control connection dropped mid-transfer** by a server idle timeout or by
   NAT, with items still queued. The pooled connection must be released and not
   reused, and the queue must report the failure against the item rather than
   hanging. **Task 6.**
5. **An abandoned `readStream`.** A consumer that cancels or throws leaves a
   pooled connection held by a stream nobody will drain; one leak per abandoned
   download starves the pool permanently. **Task 6.**

---

## File Structure

**Create — `Sources/macSCPCore/FTP/`**

| file | responsibility |
|---|---|
| `FTPReply.swift` | one parsed server reply: code, text lines, completeness |
| `FTPListParser.swift` | `MLSD` facts and `LIST` dialects → `RemoteFileItem` |
| `FTPSecurityMode.swift` | `plain` / `explicitTLS` / `implicitTLS`, default port per mode |
| `FTPConnectionConfig.swift` | the connection's own config value |
| `FTPFieldSchema.swift` | parsing and validation of user-entered fields |
| `FTPPath.swift` | the one choke point every path crosses (Review Focus 1) |
| `FTPControlConnection.swift` | the NIO channel: greeting, login, `FEAT`, TLS, `NOOP` |
| `FTPDataConnection.swift` | `EPSV`/`PASV`, the data channel, `REST` |
| `FTPConnectionPool.swift` | the reserved command connection, the transfer pool, the release token |
| `FTPFileSystem.swift` | the `RemoteFileSystem` conformance |

**Create — `Tests/macSCPCoreTests/`**

| file | responsibility |
|---|---|
| `Support/LoopbackFTPServer.swift` | in-process FTP/FTPS server for tests |
| `FTPReplyTests.swift`, `FTPListParserTests.swift`, `FTPFieldSchemaTests.swift`, `FTPPathTests.swift` | the pure units |
| `FTPControlConnectionTests.swift`, `FTPDataConnectionTests.swift`, `FTPConnectionPoolTests.swift`, `FTPFileSystemTests.swift` | against the loopback server |
| `FTPFileSystemIntegrationTests.swift` | gated, against the rig container |

**Modify** — `Package.swift`; `Connection/ConnectionKind.swift`;
`Connection/ConnectionConfig.swift`; `Capabilities/BackendDescriptor.swift`;
`Capabilities/PlaintextTransportGate.swift`; `Tunnels/TunnelFailureKind.swift`;
`Sessions/StoredSession.swift`; `Sessions/SessionCatalog.swift`;
`Sessions/SessionExportCodec.swift`; `Sessions/LoginSetExportCodec.swift`;
`Sessions/ExternalImport/ImportPreviewPlanner.swift`;
`Presentation/ConnectionViewModel.swift`;
`Presentation/SessionOverviewModel.swift`;
`Diagnostics/ContributionProbes.swift`; `MacSCPCLI/SessionFieldOptions.swift`;
`MacSCPCLI/ConnectionKind+ArgumentParser.swift`; the four
`Localizable.strings`; `docker/test-server/compose.yml` plus a new
`docker/test-server/ftpd/Dockerfile`.

---

## Task 1: `FTPReply` — the reply parser

**Files:**
- Create: `Sources/macSCPCore/FTP/FTPReply.swift`
- Test: `Tests/macSCPCoreTests/FTPReplyTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct FTPReply: Sendable, Equatable { let code: Int; let lines: [String] }`,
  `var isPositive: Bool` (code 1–3), `var isTransient: Bool` (4), `var isPermanent: Bool` (5);
  `enum FTPReplyAccumulator { static func feed(_ line: String, into partial: inout [String]) -> FTPReply? }`
  returning `nil` while a multiline reply is still open.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func aSingleLineReplyIsCompleteAtOnce() throws {
    var partial: [String] = []
    let reply = try #require(FTPReplyAccumulator.feed("220 ready", into: &partial))
    #expect(reply.code == 220)
    #expect(reply.lines == ["ready"])
}

@Test func aMultilineReplyIsOpenUntilItsCodeRepeatsWithASpace() throws {
    var partial: [String] = []
    #expect(FTPReplyAccumulator.feed("211-Features:", into: &partial) == nil)
    #expect(FTPReplyAccumulator.feed(" MLSD", into: &partial) == nil)
    #expect(FTPReplyAccumulator.feed("211 End", into: &partial) != nil)
}

@Test func anInnerLineWhoseDigitsMatchDoesNotCloseTheReply() throws {
    // A server listing a file called "211 notes" inside a 211 block.
    var partial: [String] = []
    #expect(FTPReplyAccumulator.feed("211-Features:", into: &partial) == nil)
    #expect(FTPReplyAccumulator.feed("211-211 notes", into: &partial) == nil)
    #expect(FTPReplyAccumulator.feed("211 End", into: &partial) != nil)
}

@Test func aLineThatIsNotAReplyIsRefusedRatherThanGuessed() { /* throws */ }
@Test func replyClassesFollowTheirLeadingDigit() { /* 1-3 positive, 4 transient, 5 permanent */ }
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter FTPReplyTests`
Expected: FAIL, `cannot find 'FTPReply' in scope`.

- [ ] **Step 3: Implement `FTPReply` and `FTPReplyAccumulator`**

RFC 959 §4.2: a multiline reply opens with `<code>-` and closes with the same
code followed by a space, at the start of a line. The accumulator is a pure
function over one line plus the partial state; it owns no connection.

- [ ] **Step 4: Run them green**

Run: `swift test --filter FTPReplyTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/FTP/FTPReply.swift Tests/macSCPCoreTests/FTPReplyTests.swift
git commit -m "feat(core): FTP server replies parse, including the multiline form"
```

---

## Task 2: `FTPListParser` — `MLSD` and the `LIST` dialects

**Files:**
- Create: `Sources/macSCPCore/FTP/FTPListParser.swift`
- Test: `Tests/macSCPCoreTests/FTPListParserTests.swift`

**Interfaces:**
- Consumes: `RemoteFileItem` (`Sources/macSCPCore/RemoteFS/RemoteFileItem.swift`).
- Produces:
  `enum FTPListParser { static func mlsd(_ lines: [String], at directory: String) throws -> [RemoteFileItem]; static func list(_ lines: [String], at directory: String) throws -> [RemoteFileItem] }`
  and `enum FTPListRefusal: Error, Equatable { case unreadableLine(index: Int) }`.

**Review Focus 3 lives here.** Decode each name as UTF-8 and fall back per name
to Latin-1; a single undecodable name must not void the listing.

**The spec's §8 rule is a requirement of this task:** a line the parser cannot
read makes the listing for that directory **fail**, naming the line's index. It
is never dropped.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func mlsdReadsTypeSizeAndModifyFacts() throws
@Test func mlsdReportsASymlinkFromItsUnixFact() throws        // type=OS.unix=symlink
@Test func mlsdSkipsTheDotAndDotDotEntries() throws
@Test func unixListReadsAFileWithAYearInPlaceOfATime() throws // "Jan  5  2024"
@Test func unixListReadsARecentFileWithATimeAndNoYear() throws // "Jan  5 13:40"
@Test func unixListReadsANameContainingSpaces() throws
@Test func dosListReadsADirectoryMarkedWithDIR() throws        // "01-05-24  01:40PM  <DIR>  name"
@Test func aLineInNoKnownDialectIsRefusedByItsIndex() throws   // FTPListRefusal.unreadableLine
@Test func aNameThatIsNotValidUTF8SurvivesAsItsLatin1Reading() throws
@Test func oneUndecodableNameDoesNotVoidTheOtherEntries() throws
```

Every fixture is a literal string array in the test; no file, no server.

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter FTPListParserTests`

- [ ] **Step 3: Implement the parser**

Two independent readers. `mlsd` splits `fact=value;` pairs before the space and
takes the rest of the line as the name verbatim — the name may contain spaces
and semicolons, so the split is on the FIRST space after the fact block.
`list` tries the Unix form, then the DOS form, and refuses rather than guessing.
Timestamps are best-effort and never affect comparison (spec §8a).

- [ ] **Step 4: Run them green, and count the dialect cases**

Run: `swift test --filter FTPListParserTests`
Then record the case count in the commit message with the command that produced
it: `/usr/bin/grep -c '@Test' Tests/macSCPCoreTests/FTPListParserTests.swift`.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/FTP/FTPListParser.swift Tests/macSCPCoreTests/FTPListParserTests.swift
git commit -m "feat(core): FTP listings parse from MLSD facts and from LIST dialects"
```

---

## Task 3: FTP exists as a connection kind

This is the task the compiler drives. Adding the enum cases reddens two
guards immediately, which is the red this task proves first:
`ConnectionKindTests.swift:13` (`allCases.count == 3`) and
`BackendDescriptorHostKeyWiringGuardTests.swift:84` (`descriptors.count == 3`).

**Files:**
- Create: `Sources/macSCPCore/FTP/FTPSecurityMode.swift`,
  `FTPConnectionConfig.swift`, `FTPFieldSchema.swift`
- Modify: `Connection/ConnectionKind.swift`, `Connection/ConnectionConfig.swift`,
  `Capabilities/BackendDescriptor.swift`,
  `Capabilities/PlaintextTransportGate.swift`,
  `Tunnels/TunnelFailureKind.swift`
- Test: `Tests/macSCPCoreTests/FTPFieldSchemaTests.swift`, and the two guard
  files above

**Interfaces:**
- Produces:
  `enum FTPSecurityMode: String, Codable, Sendable, CaseIterable { case plain, explicitTLS, implicitTLS }`
  with `var defaultPort: Int { 21, 21, 990 }`;
  `struct FTPConnectionConfig: Sendable, Equatable, Codable { var host: String; var port: Int; var username: String; var security: FTPSecurityMode; var initialPath: String? }`;
  `ConnectionKind.ftp`; `ConnectionConfig.ftp(FTPConnectionConfig)`;
  `enum FTPFieldSchema { static func normalizedHost(_ raw: String) -> String?; static func port(_ raw: String, for mode: FTPSecurityMode) -> Int? }`.

**The capability row** (spec §7a), as one `ProtocolCapabilities` literal in
`BackendDescriptor`: `supportsShell: false`, `permissionModel: .posixMode`,
`supportsSymlinks: true`, `atomicRename: false`, `directoriesAreReal: true`,
`resumeMode: .restOffset`, `supportsPresignedURL: false`,
`supportsRemoteChecksum: false`, `transport: .optionalTLS`,
`authenticatesHostKey: false`.

- [ ] **Step 1: Add the cases and watch the two existing guards go red**

Run: `swift test --filter 'ConnectionKindTests|BackendDescriptorHostKeyWiringGuardTests'`
Expected: FAIL on both counts, 3 against 4. Quote both in the commit message.

- [ ] **Step 2: Write the failing gate test**

```swift
@Test func plainFTPAsksForConfirmationAndNeitherTLSFormDoes() {
    #expect(PlaintextTransportGate.requiresConfirmation(for: .ftp(config(.plain))))
    #expect(PlaintextTransportGate.requiresConfirmation(for: .ftp(config(.explicitTLS))) == false)
    #expect(PlaintextTransportGate.requiresConfirmation(for: .ftp(config(.implicitTLS))) == false)
}

@Test func theDefaultPortFollowsTheSecurityMode() {
    #expect(FTPSecurityMode.implicitTLS.defaultPort == 990)
    #expect(FTPSecurityMode.explicitTLS.defaultPort == 21)
}
```

- [ ] **Step 3: Implement the arms**

`isPlaintext(_:)` gains `case .ftp(let ftp): return ftp.security == .plain` —
the spec's §7a measurement is why no capability field is needed. Update the two
count guards to 4 and add the FTP descriptor. `TunnelFailureKind`'s arm follows
WebDAV's shape.

- [ ] **Step 4: Run the whole suite**

Run: `swift test`
Expected: PASS. Any other red here is a surface the spec's §11a list did not
name — report it rather than patching past it.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(core): FTP is a connection kind, with its capability row"
```

---

## Task 4: The loopback FTP/FTPS server

Test infrastructure, and the spec's §9 answer. Nothing live can be tested
before it exists.

**Files:**
- Create: `Tests/macSCPCoreTests/Support/LoopbackFTPServer.swift`
- Modify: `Package.swift` (add `apple/swift-nio-ssl`)
- Test: `Tests/macSCPCoreTests/LoopbackFTPServerTests.swift`

**Interfaces:**
- Produces: `actor LoopbackFTPServer` with
  `init(security: FTPSecurityMode, advertisesMLSD: Bool, requiresTLSSessionReuse: Bool)`,
  `func start() async throws -> (host: String, port: Int)`, `func stop() async`,
  and seams the hostile cases need:
  `func refuseNextAcquireWith421()`, `func desynchroniseNextReply()`,
  `func answerPASVWith(host: String)`, `func dropControlConnectionMidTransfer()`.

Model it on `Tests/macSCPCoreTests/LoopbackTLSStub.swift`: an `NWListener` that
mints its certificate at runtime with `kSecImportToMemoryOnly`, so **no key
material is committed**. Serves all three security modes.

- [ ] **Step 1: Add the dependency and measure what it costs**

Add `.package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0")`
and the product to `macSCPCore`. Then measure, because the spec records both
figures as unmeasured: `swift build 2>&1 | tail -1` for the clean build time
from an empty `.build`, and the `dist/macSCP.app` size before and after via
`scripts/package-app`. Write both into
`docs/superpowers/specs/2026-08-20-backlog-dependencies.md` with the commands.
If either cost is startling, stop and report rather than deciding alone.

- [ ] **Step 2: Write the failing test**

```swift
@Test func theLoopbackServerCompletesAPlainLoginAndReportsFEAT() async throws
@Test func theLoopbackServerUpgradesOnAUTHTLSWhenConfiguredExplicit() async throws
@Test func theLoopbackServerSpeaksTLSFromTheFirstByteWhenConfiguredImplicit() async throws
@Test func theLoopbackServerCanBeToldToRefuseWith421() async throws
```

Note: the server's own credentials are a test constant, and no test name or
expectation contains them — `#expect` reports source text (Global Constraints).

- [ ] **Step 3: Implement the server**

- [ ] **Step 4: Run it green**

Run: `swift test --filter LoopbackFTPServerTests`

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "test(core): an in-process FTP/FTPS server, in the loopback stub's mould"
```

---

## Task 5: The control connection

**Files:**
- Create: `Sources/macSCPCore/FTP/FTPControlConnection.swift`,
  `Sources/macSCPCore/FTP/FTPPath.swift`
- Test: `Tests/macSCPCoreTests/FTPControlConnectionTests.swift`,
  `Tests/macSCPCoreTests/FTPPathTests.swift`

**Interfaces:**
- Consumes: `FTPReply`, `FTPReplyAccumulator`, `FTPConnectionConfig`,
  `FTPSecurityMode`, `ServerCertificateValidation`.
- Produces:
  `actor FTPControlConnection` with
  `static func connect(_ config: FTPConnectionConfig, password: String, certificateDecider: CertificateDecider, timeout: Duration) async throws -> FTPControlConnection`,
  `func send(_ command: String, argument: String?) async throws -> FTPReply`,
  `var features: Set<String> { get }`, `func close() async`;
  `enum FTPPath { static func validated(_ path: String) throws -> String }`.

**Review Focus 1 is this task's own requirement.** `FTPPath.validated` is the
single choke point: a path containing CR, LF or a NUL is refused with an error
naming the offending character class, and `FTPControlConnection.send` takes its
argument only through it. A source-scanning guard asserts there is exactly one
place that writes a command line, with a positive check beside it.

**Review Focus 2 belongs here too:** `PROT P` plus data-connection TLS session
resumption, measured against the loopback server configured with
`requiresTLSSessionReuse: true`. If `swift-nio-ssl` offers no client-side
resumption across connections, stop and report — that is a finding about the
dependency, not a task to engineer around.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func aPathCarryingCRLFIsRefusedBeforeItReachesTheWire() throws
@Test func aPathCarryingNULIsRefused() throws
@Test func anOrdinaryPathWithSpacesAndSemicolonsPassesThrough() throws
@Test func theGreetingIsReadBeforeAnyCommandIsSent() async throws
@Test func loginSendsUSERThenPASSAndReportsTheOutcome() async throws
@Test func featIsReadOnceAndItsFeaturesAreQueryable() async throws
@Test func typeIIsIssuedAndTypeAIsNeverSent() async throws
@Test func explicitModeIssuesAUTHTLSThenPBSZ0ThenPROTP() async throws
@Test func implicitModeWrapsTheSocketBeforeTheGreeting() async throws
@Test func aRefusedAUTHTLSFailsTheConnectionWithNoPlaintextFallback() async throws
@Test func aDataConnectionResumesTheControlSessionWhenTheServerRequiresIt() async throws
@Test func theConnectTimeoutIsHonouredRatherThanDropped() async throws
```

The `typeA` check is a source scan plus a wire assertion; being negative, it
ships with a positive check that `TYPE I` is present (Global Constraints).

- [ ] **Step 2: Run them and watch them fail**

- [ ] **Step 3: Implement the connection**

A NIO channel with a line decoder feeding `FTPReplyAccumulator`; commands
serialised through the actor so a reply can never be read against the wrong
command. `NOOP` keepalive on an idle timer. The certificate goes to
`ServerCertificateValidation` via `ServerCertificateCandidate(derBase64:)`.

- [ ] **Step 4: Run them green**

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(core): the FTP control connection, with one validated command path"
```

---

## Task 6: The data connection and the pool

The spec's §5, §5a and §5b, and Review Focus 4 and 5.

**Files:**
- Create: `Sources/macSCPCore/FTP/FTPDataConnection.swift`,
  `Sources/macSCPCore/FTP/FTPConnectionPool.swift`
- Test: `Tests/macSCPCoreTests/FTPDataConnectionTests.swift`,
  `Tests/macSCPCoreTests/FTPConnectionPoolTests.swift`

**Interfaces:**
- Consumes: `FTPControlConnection`, `SettingsStore.maxConcurrentTransfers`.
- Produces:
  `actor FTPConnectionPool` with
  `init(config: FTPConnectionConfig, password: String, transferSlots: Int)`,
  `func command() async throws -> FTPControlConnection` (the reserved one),
  `func acquireTransfer() async throws -> FTPTransferLease`, `func shutdown() async`;
  `final class FTPTransferLease: Sendable` whose `deinit` is **not** the release
  path — release is explicit and total, and the lease carries
  `func release(reusable: Bool) async`;
  `enum FTPPoolBudget { static func refusalRecorded(host: String, account: String) async; static func slots(host: String, account: String, configured: Int) async -> Int }`.

**The release invariant (spec §5a) is the task's central requirement.** A lease
is returned exactly once, on every exit from the stream that holds it — normal
completion, thrown error, or cancellation. A cancelled or desynchronised
connection is released with `reusable: false` and discarded.

**The `421` budget is keyed on host plus account, not on the tab** (spec §5a),
so it is process-wide state in the shape `TabRegistry` already has: it holds a
refusal count, never a connection.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func epsvIsPreferredAndPASVIsTheFallback() async throws
@Test func aPASVReplyWithAnUnusableAddressIsRefusedRatherThanDialled() async throws
@Test func restThenRETRResumesADownloadAtTheOffset() async throws
@Test func theCommandConnectionIsNotOneOfTheTransferSlots() async throws
@Test func anAbandonedReadStreamReturnsItsLeaseToThePool() async throws
@Test func aCancelledTransfersConnectionIsDiscardedAndNotReused() async throws
@Test func aControlConnectionDroppedMidTransferFailsTheItemAndFreesTheSlot() async throws
@Test func a421OnAcquireShrinksTheBudgetForThatHostAndAccount() async throws
@Test func aSecondPoolOnTheSameHostAndAccountInheritsTheShrunkBudget() async throws
@Test func theSlotCountFollowsMaxConcurrentTransfersAndItsClamp() async throws
```

The abandoned-stream case is the one that must be written as a measurement, not
an assertion of intent: take the stream, read one chunk, drop it, then assert
the pool's free count recovers — with an `await` on a condition, never a sleep.

- [ ] **Step 2: Run them and watch them fail**

- [ ] **Step 3: Implement the data connection and the pool**

- [ ] **Step 4: Run them green**

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(core): FTP data connections and a pool whose leases always come back"
```

---

## Task 7: `FTPFileSystem` — the conformance

**Files:**
- Create: `Sources/macSCPCore/FTP/FTPFileSystem.swift`
- Test: `Tests/macSCPCoreTests/FTPFileSystemTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: `final class FTPFileSystem: RemoteFileSystem`.

Of `RemoteFileSystem`'s 18 requirements, **7 carry defaults**, so **11 must be
written**. The derivation, with its exclusion named rather than folded in,
measured 2026-11-05:

```
/usr/bin/grep -cE '^\s+(func|var|subscript)' Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift
sed -n '165,227p' Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift | /usr/bin/grep -cE '^\s+public (func|var)'
```

print **18** and **8**. 18 − 8 is 10, and the answer is 11: one of the eight
defaulted members, `write(path:contents:)`, is a **convenience overload and not
a protocol requirement** — the requirement is `write(path:mode:contents:)`. So
the defaulted requirements are `readStream(…ifMatching:)`, `entityTag`,
`statWithEntityTag`, `supportsAppendResume`, `rootIsContainerList`,
`incompleteUploadMayRemain` and `awaitUnconfirmedAborts`, seven of them, and 11
requirements have to be written. Subtracting without reading the eight is how
this figure comes out 10.

**The one decision this task owns and the spec deliberately left open:
`supportsAppendResume`.** FTP has no validator, so `entityTag` takes its `nil`
default and the `ifMatching` guard is unavailable. Write the test first, then
decide from what it shows:

```swift
@Test func aResumedUploadOntoAReplacedRemoteFileDoesNotProduceASplicedFile() async throws
```

If the substitute check (size plus `MDTM` before `REST`) cannot make that test
pass, `supportsAppendResume` is `false` for the first release and resumption is
off. Record the choice and the evidence in the task's report; do not ship
`true` on the strength of an argument.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func listPrefersMLSDWhenFEATAdvertisesItAndFallsBackToLIST() async throws
@Test func statOfAFileReadsMDTMAndSIZEWhenAdvertised() async throws
@Test func writeSendsSTORThroughATransferLease() async throws
@Test func deleteUsesDELEAndDeleteTreeDescendsWithRMD() async throws
@Test func renameSendsRNFRThenRNTO() async throws
@Test func createDirectorySendsMKD() async throws
@Test func homeDirectoryPathReadsPWDAfterLogin() async throws
@Test func setPermissionsSendsSITECHMODAndSurfacesARefusalAsAPerFileError() async throws
@Test func checksumAnswersUnavailableOnThisConnection() async throws
@Test func aResumedUploadOntoAReplacedRemoteFileDoesNotProduceASplicedFile() async throws
@Test func anUnreadableListingLineFailsThatDirectoryAndNamesTheLine() async throws
```

- [ ] **Step 2: Run them and watch them fail**

- [ ] **Step 3: Implement the conformance**

- [ ] **Step 4: Run the whole suite**

Run: `swift test`

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(core): FTPFileSystem conforms to RemoteFileSystem"
```

---

## Task 8: Login management, stored sessions, diagnostics

The first half of the spec's §11a.

**Files:**
- Modify: `Sessions/StoredSession.swift`, `Sessions/SessionCatalog.swift`,
  `Presentation/ConnectionViewModel.swift`,
  `Presentation/SessionOverviewModel.swift`,
  `Diagnostics/ContributionProbes.swift`, the four `Localizable.strings`
- Test: the existing suites for each, plus
  `Tests/macSCPCoreTests/FTPStoredSessionTests.swift`

**Interfaces:**
- Produces: `StoredFTPConfig` beside `StoredWebDAVConfig`;
  `StoredSession.ftp: StoredFTPConfig?`.

The form carries host, port, username, the security mode (three choices) and an
optional initial path; the password goes to `SecretStore` and nowhere else. Port
follows the mode's default until the user overrides it. Every label and every
error text is a catalogue key in all four languages, German in du-form.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func aStoredFTPSessionRoundTripsThroughTheCatalog() throws
@Test func theFormOffersThreeSecurityModesAndDefaultsThePortToEach() throws
@Test func theStoredSessionCarriesNoPassword() throws   // value in a named constant
@Test func theOverviewDescribesAnFTPSessionWithoutNamingItsCredentials() throws
@Test func theDiagnosticsProbeContributesTheFTPSteps() async throws
```

- [ ] **Step 2–4: red, implement, green**

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(app): FTP logins are managed, stored and diagnosable"
```

---

## Task 9: Export, import, and an older build's refusal

The second half of §11a, and the case nothing in this project has had to
handle: `ConnectionKind` is a `String`-raw `Codable` with no
`ConnectionKind(rawValue:` call anywhere in `Sources`, so a store or export
carrying `"ftp"` currently fails to decode **wholesale** on an older build.

**Files:**
- Modify: `Sessions/SessionExportCodec.swift`,
  `Sessions/LoginSetExportCodec.swift`,
  `Sessions/ExternalImport/ImportPreviewPlanner.swift`
- Test: the existing codec and planner suites, plus the 23 fixtures named below

**Interfaces:**
- Produces: an FTP shape in both codecs; `ConnectionKind`'s decode becomes
  tolerant — an unknown kind decodes to a skipped entry carrying its raw name,
  never a failed document.

**The 23 fixtures.** `"ftp"` is currently the project's example of
`.unsupported(…)`. Measured 2026-11-05:
`/usr/bin/grep -rnoiE '(^|[^a-z])ftps?([^a-z]|$)' --include='*.swift' Tests | /usr/bin/grep -viE 'sftp' | wc -l`
prints 23. They move to `"smb"`, which `ConnectionKind`'s own comment already
names as a future protocol, and the Cyberduck path's FTP bookmarks become
importable.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func anFTPSessionRoundTripsThroughTheExportEnvelope() throws
@Test func anExportCarryingAnUnknownKindSkipsThatEntryAndKeepsTheRest() throws
@Test func aCyberduckFTPBookmarkIsNowImportableRatherThanGreyed() throws
@Test func anUnsupportedBookmarkIsStillReportedAsUnsupported() throws   // the smb fixture
```

- [ ] **Step 2–4: red, implement, green**

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(core): FTP sessions export and import, and an unknown kind no longer voids a document"
```

---

## Task 10: The CLI

**Files:**
- Modify: `MacSCPCLI/SessionFieldOptions.swift`,
  `MacSCPCLI/ConnectionKind+ArgumentParser.swift`
- Test: `CLICompletionScriptTests`, and the gated `CLIMatrixITests`

`CLIMatrixITests` asserts `fixture.entries.count == ConnectionKind.allCases.count`,
so the fourth kind reddens it the moment Task 3 lands. This task is where it
goes green by being satisfied, never by being weakened.

- [ ] **Step 1: Run the matrix test and quote its red**

Run: `MACSCP_ITEST=1 swift test --filter CLIMatrixITests`

- [ ] **Step 2: Write the failing flag tests**

```swift
@Test func kindFTPIsAcceptedAndItsFlagsAreOfferedForItAlone() throws
@Test func theCompletionScriptListsTheFTPFlags() throws
@Test func theSecretEnvironmentVariableIsNamedForFTP() throws
```

- [ ] **Step 3–4: implement, green**

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(cli): --kind ftp, with its own fields and completions"
```

---

## Task 11: The rig container and the gated suite

**Files:**
- Create: `docker/test-server/ftpd/Dockerfile`
- Modify: `docker/test-server/compose.yml`,
  `docker/test-server/README.md`
- Test: `Tests/macSCPCoreTests/FTPFileSystemIntegrationTests.swift` (gated on
  `MACSCP_ITEST=1`)

No published image offers `MLSD` plus `AUTH TLS` on arm64 (spec §9), so the rig
builds its own, the way `macscp-test-sshd` already does — `compose.yml` line 7
is `build: ./sshd`, which is the precedent. The daemon advertises `MLSD` and
`AUTH TLS`; the loopback server from Task 4 covers the no-`MLSD` fallback and
every hostile case.

**Rig commands run from `/Users/noidee/macSCP`, never from a worktree**, and the
seeding is idempotent like `s3/init.sh`. Do not touch `macscp-seed`,
`macscp-second` or `macscp-probe-lock`.

- [ ] **Step 1: Write the Dockerfile and bring the service up**

Run, from the main checkout:
`docker compose -f docker/test-server/compose.yml up -d ftpd`

- [ ] **Step 2: Write the gated tests**

```swift
@Test func aFullCRUDRoundTripRunsAgainstTheRigDaemon() async throws
@Test func anExplicitTLSSessionCompletesAgainstTheRigDaemon() async throws
@Test func aResumedUploadAndDownloadMatchByteForByte() async throws
@Test func theRigDaemonsListingAgreesWithTheMLSDParser() async throws
```

- [ ] **Step 3–4: red, implement, green**

Run: `MACSCP_ITEST=1 swift test --filter FTPFileSystemIntegrationTests`

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "test(rig): an FTPS daemon the rig builds itself"
```

---

## Task 12: Closeout

- [ ] **Step 1: User documentation** — `/Users/noidee/_dev/noix-docs`, a worktree
  on its own branch, `src/content/docs/macscp/guide/`, one page for FTP, marked
  as coming in the next version. `npm run build` and `npm run check` both pass.
  **Push and merge only if the maintainer asks.**

- [ ] **Step 2: `docs/BACKLOG.md`** — one row for the backend, and close the row
  that was waiting on it (the Cyberduck follow-up that names FTP/FTPS). Each
  figure travels with its command; no pipe inside a table cell.

- [ ] **Step 3: Correct the two prior records in place, quoting what they
  withdraw** (spec §0):
  - `2026-08-25-backlog-further-protocols.md`: the `TransportSecurity.plaintext`
    mechanism, which would switch the gate off for the backend it was written
    for.
  - `2026-09-02-protocols-library-measurement.md`: the expectation that the
    transport axis *"needs a per-connection field"*, which the measurement in
    spec §7a disproves, and the rig-image finding, which Task 11 answers.

- [ ] **Step 4: `swift test` on the whole tree**, and the gated suites named in
  CLAUDE.md that this work touches, each from the main checkout where it needs
  the rig.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "docs: the FTP backend closes out, and two prior records are corrected"
```

---

## Self-review

Run against the spec on 2026-11-05.

**Spec coverage.** §1 intent → Tasks 3, 7. §2 goals → Tasks 7, 8, 9, 10; the
non-goals are absences, and `TYPE A` has a guard in Task 5. §4 decisions:
1 → Tasks 7–10; 2 → Task 6; 3 → Task 5; 4 → Tasks 4, 11; 5 → Task 3; 6 → Task 4
step 1; 7 → Task 2; 8 → Task 2; 9 is withdrawn, so no task; 10 → Task 7. §5/§5a/§5b
→ Task 6. §6 → Task 5. §7/§7a → Tasks 3, 4, 5. §8/§8a → Tasks 2, 7. §9 → Tasks 4,
11. §10 → Task 3's capability row. §11a → Tasks 8, 9, 10. §12's open items are
left to implementers by design. §13 risks → Task 4 step 1 (dependency cost),
Task 5 (session reuse), Task 9 (older build), Task 2 (dialect residual).

**One gap found and closed:** the spec's §14 settles that the certificate
decider's type moves out of `WebDAVSessionDelegate`, and no task owned it. It
belongs in Task 5, where the second consumer appears — added to that task's
file list as a modification of `Capabilities/BackendDescriptor.swift` and the
three connect closures.

**Type consistency.** `FTPConnectionConfig` is the name in Tasks 3, 5, 6;
`StoredFTPConfig` is the persistence shape in Tasks 8, 9, and the two are
deliberately different types, as `WebDAVConnectionConfig`/`StoredWebDAVConfig`
already are. `FTPTransferLease` appears only in Task 6.

**Review Focus.** All five have a named owning task and a test in that task's
step 1.

**Proportion.** The plan is shorter than the spec it implements, and carries
signatures and test names rather than bodies. The two places a body would have
gone — the reply accumulator and the `MLSD` name split — are one sentence of
prose each instead.
