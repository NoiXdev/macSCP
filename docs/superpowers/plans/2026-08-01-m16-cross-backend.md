# M16 — Cross-Backend Transfer S3↔SSH Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify S3↔SSH transfers under a gate and make cross-backend transfers visible in the UI (destination/backend labeling + passive resume warning), without touching the transfer engine.

**Architecture:** The transfer engine is already backend-agnostic (verified) — M16 only adds (1) a gated S3↔SSH integration test, (2) additive display metadata on the queue `Item`, (3+4) UI. The metadata lives **solely on the `Item`** (set once at creation, never reconstructed); the `Job` stays untouched, because only it gets rebuilt on interrupt/retry and needs no display data.

**Tech Stack:** Swift (SwiftPM, `.swiftLanguageMode(.v5)`), Swift Testing, SwiftUI+AppKit, macOS 15+, MinIO+sshd Docker rig for gated tests.

## Global Constraints

- Swift `.swiftLanguageMode(.v5)`, minimum macOS 15; **no new external dependency**.
- Tests: Swift Testing, TDD red→green.
- **NO change to Signer/Transport/`TransferEngine` copy logic** — only additive metadata + view.
- **No `if kind == .s3` in the copy logic**; the backend label on the `Item` is display only.
- The resume guard (M13) stays untouched — the gated test only verifies it across the backend boundary.
- Additive `Item` fields explicitly set at **every** `Item` construction site (no struct defaults → the compiler enforces completeness).
- Secrets exclusively in the keychain; never in JSON/logs/URLs.
- Gated tests `MACSCP_ITEST=1` (+ `MACSCP_KEYCHAIN=1`), **always from the main checkout, never from a worktree**; rig `docker compose -f docker/test-server/compose.yml up -d` (sshd:2222, minio:19000/19001).
- Code/comments/tests **English**; UI strings EN/DE/FR/PL with **typographic quotation marks** in non-English values, FR/PL AI-generated.
- Conventional Commits (CI gate); footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

## File Structure

- `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` — **modify**: `CrossBackendTarget` type, `Item` gets two fields, `enqueue`/`enqueueTree`/`expandTree`/`addTerminalItem` get a `crossBackendTarget` parameter, three `Item(...)` construction sites.
- `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift` (or the existing queue test file) — **modify**: unit tests for the metadata.
- `Tests/macSCPCoreTests/CrossBackendTransferIntegrationTests.swift` — **create**: gated S3↔SSH test.
- `Sources/MacSCPApp/ContentView.swift` — **modify**: `CrossSessionTarget` gets `kind`, `crossSessionTargets(for:)`, `transferToSession`, submenu rendering.
- `Sources/MacSCPApp/TransferQueueBar.swift` — **modify**: `row(_:)` gets backend badge + resume ⚠.
- `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings` — **modify**: new strings.

---

## Task 1: Core — `CrossBackendTarget` + `Item` display metadata

**Files:**
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift`
- Test: `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift`

**Interfaces:**
- Consumes: `ConnectionKind` (`.ssh`/`.s3`), `any RemoteFileSystem` (`.supportsAppendResume: Bool`), existing `enqueue`/`enqueueTree`/`expandTree`/`addTerminalItem`.
- Produces:
  - `public struct CrossBackendTarget: Equatable, Sendable { public var name: String; public var kind: ConnectionKind; public init(name: String, kind: ConnectionKind) }`
  - `Item.destinationSupportsResume: Bool` (no struct default) + `Item.crossBackendTarget: CrossBackendTarget?` (no struct default)
  - `enqueue`/`enqueueTree` new parameter `crossBackendTarget: CrossBackendTarget? = nil` (after `crossRemote`)

**Important (architecture):** The `Item` is constructed at exactly three sites — `enqueue` (~425), `enqueueEditUpload` (~452), `addTerminalItem` (~1129) — and never reconstructed afterward (only `setStatus` mutates it). That is why **only these three sites** carry the new fields; the `Job` and the interrupt/retry paths (~581, ~915) stay unchanged. `destinationSupportsResume` is read from the `destination` present at the respective site; where no `destination` exists (`addTerminalItem` — skip/error items, which are never transferred), it is `true`.

- [ ] **Step 1: Write the failing test**

In `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift` (the existing queue test file; if named differently, take the file with the `TransferQueueViewModel` tests) insert a new test block at the end of the suite. Use the FS fake already present in this file (e.g. `RecordingFS`/`FakeFS` with an overridable `supportsAppendResume`) — take the exact name from the file; here `StubFS` is a placeholder, replace it with the real fake when writing:

```swift
    // MARK: - Cross-backend display metadata (M16)

    @Test func enqueueToS3TargetMarksNoResumeAndCarriesTarget() async {
        let vm = TransferQueueViewModel(/* … same init as this file's other tests … */)
        let source = StubFS(supportsAppendResume: true)
        let s3Dest = StubFS(supportsAppendResume: false)
        _ = vm.enqueue(
            fileName: "a.bin", direction: .upload,
            source: source, sourcePath: "/a.bin",
            destination: s3Dest, destinationDirectory: "/",
            onCompleted: nil, destinationTabID: UUID(), crossRemote: true,
            crossBackendTarget: CrossBackendTarget(name: "prod-bucket", kind: .s3))
        let item = vm.items.last!
        #expect(item.destinationSupportsResume == false)
        #expect(item.crossBackendTarget == CrossBackendTarget(name: "prod-bucket", kind: .s3))
    }

    @Test func enqueueToSSHTargetAllowsResume() async {
        let vm = TransferQueueViewModel(/* … */)
        let sshDest = StubFS(supportsAppendResume: true)
        _ = vm.enqueue(
            fileName: "b.bin", direction: .upload,
            source: StubFS(supportsAppendResume: true), sourcePath: "/b.bin",
            destination: sshDest, destinationDirectory: "/",
            onCompleted: nil, destinationTabID: UUID(), crossRemote: true,
            crossBackendTarget: CrossBackendTarget(name: "web", kind: .ssh))
        let item = vm.items.last!
        #expect(item.destinationSupportsResume == true)
        #expect(item.crossBackendTarget?.kind == .ssh)
    }

    @Test func sameSessionUploadToS3HasNoTargetButNoResume() async {
        let vm = TransferQueueViewModel(/* … */)
        _ = vm.enqueue(
            fileName: "c.bin", direction: .upload,
            source: StubFS(supportsAppendResume: true), sourcePath: "/c.bin",
            destination: StubFS(supportsAppendResume: false), destinationDirectory: "/",
            onCompleted: nil)
        let item = vm.items.last!
        #expect(item.destinationSupportsResume == false)
        #expect(item.crossBackendTarget == nil)
    }
```

If the file's fake has no `init(supportsAppendResume:)`: give it one (overridable) property following the pattern this file's M13 resume tests already use (they already vary `supportsAppendResume` there) — invent nothing, adopt the existing pattern.

- [ ] **Step 2: Test red**

Run: `swift test --filter TransferQueueViewModelTests`
Expected: FAIL — "cannot find 'CrossBackendTarget'" or "extra argument 'crossBackendTarget'".

- [ ] **Step 3: `CrossBackendTarget` + `Item` fields**

In `TransferQueueViewModel.swift`: insert the type at file scope (or directly above the class):

```swift
/// A cross-backend transfer's destination label (M16): the target session's
/// display name and protocol kind. Set only for cross-session transfers so
/// the transfer row can show where a file is going and with which backend.
public struct CrossBackendTarget: Equatable, Sendable {
    public var name: String
    public var kind: ConnectionKind
    public init(name: String, kind: ConnectionKind) {
        self.name = name
        self.kind = kind
    }
}
```

In the `Item` struct (after `destinationDirectory`) add two fields WITHOUT a default:

```swift
        /// Whether the destination backend supports append-based resume (M16).
        /// Read from `destination.supportsAppendResume` at enqueue; `false`
        /// for an S3 destination. Drives the passive resume warning in the
        /// transfer row. `true` for terminal skip/error items (no transfer).
        public let destinationSupportsResume: Bool
        /// Cross-backend destination label (M16): the target session's name +
        /// kind, `nil` for same-session transfers. The queue holds only the
        /// opaque `destinationTabID`, so the App supplies this at enqueue.
        public let crossBackendTarget: CrossBackendTarget?
```

- [ ] **Step 4: Pass the parameter through + set the three `Item(...)` sites**

(a) `enqueue` (~411): add parameter `crossBackendTarget: CrossBackendTarget? = nil` after `crossRemote`; extend the `Item(...)` construction (~425) by:

```swift
        items.append(Item(
            id: id, fileName: fileName, direction: direction, status: .queued,
            destinationTabID: destinationTabID, isEditUpload: false,
            destinationDirectory: destinationDirectory,
            destinationSupportsResume: destination.supportsAppendResume,
            crossBackendTarget: crossBackendTarget))
```

(b) `enqueueEditUpload` (~440): extend the `Item(...)` construction (~452) by:

```swift
        items.append(Item(
            id: id, fileName: fileName, direction: .upload, status: .queued,
            destinationTabID: nil, isEditUpload: true,
            destinationDirectory: remoteDirectory,
            destinationSupportsResume: destination.supportsAppendResume,
            crossBackendTarget: nil))
```

(c) `addTerminalItem` (~1123): extend the signature by `crossBackendTarget: CrossBackendTarget? = nil`; extend the `Item(...)` construction (~1129) by:

```swift
        items.append(Item(
            id: id, fileName: name, direction: direction, status: .queued,
            destinationTabID: destinationTabID, isEditUpload: false,
            destinationDirectory: destinationDirectory,
            destinationSupportsResume: true,
            crossBackendTarget: crossBackendTarget))
```

(d) `enqueueTree` (~525): add parameter `crossBackendTarget: CrossBackendTarget? = nil` and pass it on to `expandTree`.

(e) `expandTree` (~1044): add parameter `crossBackendTarget: CrossBackendTarget? = nil`; pass it through to `enqueue(...)` in the `.file` branch (`crossBackendTarget: crossBackendTarget`); pass it through to `expandTree(...)` in the recursive `.directory` branch; pass `crossBackendTarget: crossBackendTarget` in the three `addTerminalItem(...)` calls (dir-create error, list error, symlink skip).

- [ ] **Step 5: Test green**

Run: `swift test --filter TransferQueueViewModelTests`
Expected: PASS — the three new tests green, all existing queue tests still green.

- [ ] **Step 6: Retry-persistence guard (test)**

Add a test that proves an item keeps its metadata across an interrupt→retry cycle (because the item is NOT reconstructed). If the file already has an interrupt/retry test helper, use its pattern; minimally:

```swift
    @Test func interruptedItemKeepsCrossBackendMetadata() async {
        let vm = TransferQueueViewModel(/* … */)
        _ = vm.enqueue(
            fileName: "d.bin", direction: .upload,
            source: StubFS(supportsAppendResume: true), sourcePath: "/d.bin",
            destination: StubFS(supportsAppendResume: false), destinationDirectory: "/",
            onCompleted: nil, destinationTabID: UUID(), crossRemote: true,
            crossBackendTarget: CrossBackendTarget(name: "prod-bucket", kind: .s3))
        let id = vm.items.last!.id
        vm.setStatusForTesting(id, .interrupted)   // <- use the file's real test hook/path
        let item = vm.items.first { $0.id == id }!
        #expect(item.crossBackendTarget?.kind == .s3)
        #expect(item.destinationSupportsResume == false)
    }
```

If there is no test hook to set `.interrupted`, drop this test — persistence is structurally guaranteed (the item is never rebuilt); then note in the commit message that persistence is secured structurally (not by test). **Do not** invent private access.

Run: `swift test --filter TransferQueueViewModelTests`
Expected: PASS (or the test dropped as described).

- [ ] **Step 7: Full core suite + 0 warnings**

Run: `swift build && swift test`
Expected: Build 0 warnings; all tests green.

- [ ] **Step 8: Commit**

```bash
git add Sources/macSCPCore/Presentation/TransferQueueViewModel.swift Tests/macSCPCoreTests/TransferQueueViewModelTests.swift
git commit -m "feat: carry cross-backend display metadata on transfer items

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: Gated S3↔SSH integration test

**Files:**
- Create: `Tests/macSCPCoreTests/CrossBackendTransferIntegrationTests.swift`

**Interfaces:**
- Consumes: `TransferEngine.copyFile(...)` (read the signature from `Sources/macSCPCore/RemoteFS/TransferEngine.swift:93`), `S3FileSystem.connect(config)` + `S3ConnectionConfig` (from `S3FileSystemIntegrationTests.swift`'s `connect()` pattern), `CitadelFileSystem` connect on port 2222 (from `CitadelFileSystemIntegrationTests.swift`, `remoteToRemoteStreamCopiesByteIdentical` ~1195 as the template), `readStream`/`write`/`createDirectory`/`list` of the `RemoteFileSystem` protocol.
- Produces: tests only.

**Verified rig values:** S3 — accessKeyID `"macscp"`, secret `"macscpsecretkey"`, region `"us-east-1"`, endpoint `"http://127.0.0.1:19000"`, bucket `"macscp-seed"`, usePathStyle `true`. SSH — host `127.0.0.1`, port `2222`, user `testuser`, pass `testpass`. Suite gate `.enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1")`.

- [ ] **Step 1: Test file scaffold**

Create `Tests/macSCPCoreTests/CrossBackendTransferIntegrationTests.swift`. Take the header + connect helpers from the two existing integration test files (the connect/init signatures there verbatim — `S3FileSystem.connect(config)` positional, `S3ConnectionConfig(...)` as in `S3FileSystemIntegrationTests.connect()`, Citadel connect as in `CitadelFileSystemIntegrationTests`). Build the `TransferEngine` instantiation + `copyFile` call exactly as `remoteToRemoteStreamCopiesByteIdentical` does (its pattern for engine setup, progress closure, resume flag).

```swift
import Foundation
import Testing
@testable import macSCPCore

/// Cross-backend transfers between MinIO (S3) and the SSH rig (SFTP), M16.
/// Runs only with MACSCP_ITEST=1 and the Docker rig up
/// (`docker compose -f docker/test-server/compose.yml up -d`).
@Suite(
    "Cross-backend S3↔SSH transfer",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized
)
struct CrossBackendTransferIntegrationTests {
    // connectS3() / connectSSH() helpers here — carry over 1:1 from the two
    // existing integration test files (values above).
}
```

- [ ] **Step 2: SSH→S3 byte-identical**

Test: create a file with known random content on the sshd (via `sshFS.write`), then `TransferEngine.copyFile(source: sshFS, sourcePath: …, destination: s3FS, destinationPath: …)` (signature from TransferEngine.swift:93), then read the S3 object back completely via `s3FS.readStream(...)` and `#expect(readBack == original)`. Clean up the target file/key afterward (best effort, like the other integration tests).

- [ ] **Step 3: S3→SSH byte-identical**

Test: create an object in MinIO (`s3FS.write`), `copyFile(source: s3FS, destination: sshFS)`, then read it back via `sshFS.readStream` and `#expect` byte-identical.

- [ ] **Step 4: Directory tree cross-backend (one direction)**

Test (SSH→S3 or S3→SSH): create a directory with a file and a subdirectory-with-file on the source; copy the tree (via the engine/queue tree path, or recursively via `list`+`createDirectory`+`copyFile`, the way a tree transfer does) and check that both files arrive on the destination side in the correct folder structure. With an S3 destination: `createDirectory` creates the 0-byte marker; with an S3 source: `list` returns the subfolder as `.directory` (CommonPrefix). `#expect` against the listed destination entries.

- [ ] **Step 5: Resume guard across the boundary**

Test: start an SSH→S3 `copyFile` with `resume: true` (the `copyFile` signature carries a resume/offset argument — read it from TransferEngine.swift:93 ff.); verify that the transfer completes successfully byte-identical (S3 cannot append; the M13 guard forces `.overwrite`). The proof is a successful, complete transfer despite `resume: true` — no 416/no corruption byte mismatch. (Direct access to the internal write mode is not needed/available; the byte-identical result IS the guard's proof.)

- [ ] **Step 6: Rig up + gated run**

Run:
```bash
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test --filter CrossBackendTransferIntegrationTests
```
Expected: all four/five tests run (not skipped) and are green. A 403/byte mismatch points to a real signature/path problem (then fix within M16 — like the M13 trailing-slash finding).

- [ ] **Step 7: Commit**

```bash
git add Tests/macSCPCoreTests/CrossBackendTransferIntegrationTests.swift
git commit -m "test: verify cross-backend S3 and SSH transfers against the rig

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: App — transfer row with destination/backend badge + resume ⚠

**Files:**
- Modify: `Sources/MacSCPApp/ContentView.swift` (`CrossSessionTarget` ~before 2579, `crossSessionTargets(for:)` ~2579, `transferToSession` ~2596)
- Modify: `Sources/MacSCPApp/TransferQueueBar.swift` (`row(_:)` 66–122)
- Modify: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`

**Interfaces:**
- Consumes (from Task 1): `Item.destinationSupportsResume: Bool`, `Item.crossBackendTarget: CrossBackendTarget?`, `CrossBackendTarget.name`/`.kind`, `enqueue`/`enqueueTree` with `crossBackendTarget:` parameter.
- Consumes: `other.connectionViewModel.kind` (a target session's backend `kind`, as used in ContentView.swift:1059), `other.displayTitle`, `session.remote.currentPath`.
- Produces: `CrossSessionTarget.kind: ConnectionKind`.

Pure SwiftUI/App wiring — build-verified.

- [ ] **Step 1: `CrossSessionTarget` gets `kind` + derive `crossSessionTargets`**

Extend `CrossSessionTarget` (the `struct` directly above `crossSessionTargets(for:)`) by `let kind: ConnectionKind`. In `crossSessionTargets(for:)` (~2582) extend the constructor by `kind: other.connectionViewModel.kind`:

```swift
            return CrossSessionTarget(
                id: other.id, title: other.displayTitle,
                remotePath: session.remote.currentPath,
                kind: other.connectionViewModel.kind)
```

- [ ] **Step 2: `transferToSession` passes `crossBackendTarget` along**

In `transferToSession` (~2596) add `crossBackendTarget: CrossBackendTarget(name: target.title, kind: target.kind)` to **all four** enqueue/enqueueTree calls (the four calls: local-dir → `enqueueTree`, local-file → `enqueue`, remote-dir → `enqueueTree` with `crossRemote: true`, remote-file → `enqueue` with `crossRemote: true`). Example for the remote-file branch:

```swift
                queue.enqueue(
                    fileName: item.name, direction: .upload,
                    source: session.remoteFS, sourcePath: item.path,
                    destination: targetSession.remoteFS,
                    destinationDirectory: target.remotePath,
                    onCompleted: { [weak remote = targetSession.remote] in await remote?.refresh() },
                    destinationTabID: target.id, crossRemote: true,
                    crossBackendTarget: CrossBackendTarget(name: target.title, kind: target.kind))
```

- [ ] **Step 3: Transfer row — badge + ⚠**

In `TransferQueueBar.row(_:)` (66–122) insert two conditional elements directly after the `Text(item.fileName)` block (and before `Spacer(minLength: 8)`):

```swift
            if let target = item.crossBackendTarget {
                Text(backendBadgeLabel(target.kind))
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(DesignTokens.remoteSoft, in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(DesignTokens.inkSecondary)
                Text("→ \(target.name)")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.inkSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if !item.destinationSupportsResume, item.status == .queued || item.status.isRunning {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(L10n.string(
                        "transfers.noResume.hint",
                        "If interrupted, this upload restarts from the beginning."))
            }
```

And add a small helper in the same view (backend badge label; the abbreviations "SSH"/"S3" originate from M12 — the same source as the sidebar/tab, mapped directly here):

```swift
    private func backendBadgeLabel(_ kind: ConnectionKind) -> String {
        switch kind {
        case .ssh: return L10n.string("backend.badge.ssh", "SSH")
        case .s3: return L10n.string("backend.badge.s3", "S3")
        }
    }
```

Check: are the M12 badge L10n keys already named `backend.badge.ssh`/`backend.badge.s3` (sidebar/tab strip)? If so, reuse **those** instead of creating new ones; if the existing keys are named differently, use the existing ones. Check `item.status.isRunning` against the real accessor (used in this file/Item, see `isActive`/`isRunning`).

- [ ] **Step 4: L10n (only genuinely new keys)**

`transfers.noResume.hint` into all four catalogs; the backend badge keys only if they do not already exist.

EN:
```
"transfers.noResume.hint" = "If interrupted, this upload restarts from the beginning.";
```
DE:
```
"transfers.noResume.hint" = "Bei Abbruch startet dieser Upload von vorn.";
```
FR:
```
"transfers.noResume.hint" = "En cas d'interruption, ce téléversement redémarre du début.";
```
PL:
```
"transfers.noResume.hint" = "W razie przerwania to wysyłanie zacznie się od nowa.";
```
(Typographic apostrophes in the FR value; no ASCII quotes.)

- [ ] **Step 5: Build + behavior check**

Run: `swift build`
Expected: 0 warnings. Behavior by reading the code: (1) same-session transfer unchanged (no badge); (2) cross-session shows backend badge + `→ target`; (3) every S3 destination (even same-session local→S3) shows ⚠ while active, gone on completion.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacSCPApp/ContentView.swift Sources/MacSCPApp/TransferQueueBar.swift Sources/MacSCPApp/Resources
git commit -m "feat: show target backend and resume warning in the transfer bar

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: App — destination-session submenu with backend badge + path

**Files:**
- Modify: `Sources/MacSCPApp/ContentView.swift` (the M8b "Transfer to Session" submenu that renders `crossSessionTargets(for:)`)
- Modify: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings` (only if a format string is needed)

**Interfaces:**
- Consumes (from Task 3): `CrossSessionTarget.kind`, `CrossSessionTarget.title`, `CrossSessionTarget.remotePath`, the `backendBadgeLabel(_:)` idea (in the menu, possibly its own small helper, since it is a different view).

Pure App view — build-verified.

- [ ] **Step 1: Submenu entry gets backend abbreviation + path**

Find the site that renders the `crossSessionTargets(for:)` list into menu entries (the M8b "Transfer to Session" submenu — via `menuNeedsUpdate`/`NSMenuItem` or SwiftUI `Menu` — locate the actual render site in the code). Change the entry title from plain `target.title` to a compact "`<KIND> · <title> — <remotePath>`", e.g.:

```swift
let kindLabel = target.kind == .s3
    ? L10n.string("backend.badge.s3", "S3")
    : L10n.string("backend.badge.ssh", "SSH")
let title = String(
    format: L10n.string("transfers.targetMenu.item %@ %@ %@", "%@ · %@ — %@"),
    kindLabel, target.title, target.remotePath)
```

If the concrete menu widget carries a clean two-line/attributed entry (e.g. `NSMenuItem.attributedTitle`), the path may instead be set as a smaller second line — decide based on what the actual render site offers; otherwise use the compact single-line form above.

- [ ] **Step 2: L10n**

`transfers.targetMenu.item %@ %@ %@` (format `"%@ · %@ — %@"`) into all four catalogs, identical format string (the order of the placeholders is language-neutral). If the actual render site uses the two-line variant, use the matching key instead.

EN/DE/FR/PL each:
```
"transfers.targetMenu.item %@ %@ %@" = "%@ · %@ — %@";
```

- [ ] **Step 3: Build + behavior check**

Run: `swift build`
Expected: 0 warnings. Behavior: the "Transfer to Session" submenu shows per target `S3 · prod-bucket — /uploads` or `SSH · web — /var/www`.

- [ ] **Step 4: Commit**

```bash
git add Sources/MacSCPApp/ContentView.swift Sources/MacSCPApp/Resources
git commit -m "feat: label the transfer-target submenu with backend and path

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 5: Closeout — gated suite, review, push/deploy

**Files:** none (verification + milestone closeout).

- [ ] **Step 1: Rig up + full gated suite**

Run:
```bash
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test
```
Expected: whole suite green, including the new `CrossBackendTransferIntegrationTests` (not skipped) and the new queue unit tests; SSH/S3/keychain suites run along.

- [ ] **Step 2: Ungated suite + 0 warnings**

Run: `swift build && swift test`
Expected: build 0 warnings; ungated suite green.

- [ ] **Step 3: Runtime idle-CPU smoke**

Launch the dev build and check idle CPU (M11n lesson: check new GUI elements via idle-CPU smoke test before shipping, since reviews/CI never launch the GUI). The new elements are static labels/badges — there must be no layout storm/sustained CPU.

- [ ] **Step 4: Whole-milestone review**

Opus whole-branch review over the entire M16 diff (`git merge-base develop HEAD`..HEAD — base = M15 HEAD `9e6179f`), focus on the Global Constraints (no engine/signer change, no `if kind==.s3` in the copy logic, item metadata correct at all three sites, resume guard only verified).

- [ ] **Step 5: Push + CI + dev build (on maintainer instruction)**

After a green review — on maintainer instruction: push to `develop`, `gh run watch`, dev build v1.6.0-dev to `~/Desktop/macSCP-dev.app`. No release/tag.

---

## Self-Review

**1. Spec coverage:**
- Spec §1 (gated S3↔SSH test + hardening) → Task 2. ✅
- Spec §2 (queue item metadata `destinationSupportsResume` + `crossBackendTarget`, 4 unit cases incl. retry) → Task 1 (Steps 1–6). ✅ (Refinement: only `Item`, no `Job` — justified, retry persistence structural/tested.)
- Spec §3 (transfer row badge + passive ⚠) → Task 3. ✅
- Spec §4 (destination submenu backend badge + path) → Task 4. ✅
- Spec §Tests (core unit + gated + idle-CPU) → Task 1/2 + Task 5. ✅
- Spec §Security/invariants → Global Constraints + Task 5 review. ✅

**2. Placeholder scan:** deliberately open spots: fake name (`StubFS`) and `setStatusForTesting` hook in Task 1, rig connect helpers/`copyFile` signature in Task 2, actual menu render site + M12 badge key names in Task 3/4 — all with a clear instruction to take the real name from the named source file, no invented value. No "TBD/TODO".

**3. Type consistency:** `CrossBackendTarget(name:kind:)`, `Item.destinationSupportsResume`/`.crossBackendTarget`, `enqueue`/`enqueueTree`/`expandTree`/`addTerminalItem` `crossBackendTarget` parameter, `CrossSessionTarget.kind`, `backendBadgeLabel(_:)` — consistent across all tasks. `ConnectionKind` (.ssh/.s3) uniform.
