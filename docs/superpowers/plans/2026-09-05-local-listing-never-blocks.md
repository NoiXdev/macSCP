# Local Listing Never Blocks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The local pane shows a folder in the time the directory read
takes; one entry whose metadata call never returns leaves one row with
`-` in its size and date, not a pane that never loads.

**Architecture:** `LocalFileSystem.list` becomes phase one — names and
kinds from the directory read itself (a URL-API bulk read after
resolving the parent's symlink once, or `readdir`'s `d_type` where that
fails), every metadata field nil. A new `LocalFileSystem.metadata(for:)`
is phase two — an `AsyncStream<RemoteFileItem>` that yields each entry
filled in as its own child task returns, finishing when the last
returning child does; a child that never returns is abandoned.
`RemoteBrowserViewModel.load` publishes phase one, then merges the
stream by path, re-sorting only for metadata-fed sort keys. Remote
file systems are unchanged.

**Tech Stack:** Swift 6 strict, Swift Testing, `FileManager`, `Darwin`
`opendir`/`readdir`, `AsyncStream`, `RemoteBrowserViewModel`,
`MacSCPTestSupport` (`pollUntil`, a `Gate`).

**Spec:** `docs/superpowers/specs/2026-09-04-local-listing-never-blocks-design.md`.

## Global Constraints

- English only in the tree; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; commit per task; zero warnings; do not push.
- `RemoteFileItem` and `RemoteFileKind` are not changed; the `RemoteFileSystem` protocol is not changed (`metadata(for:)` is `LocalFileSystem`'s own; the view model reaches it through an optional `LocalMetadataSource` protocol the local file system adopts and remote ones do not).
- Phase one's kinds equal what the per-entry path produced before, for every existing `LocalFileSystemTests` case — those tests change only where they asserted a size or date on the FIRST return.
- A stuck child is abandoned, never awaited, never cancelled-and-waited-for: the stream's finish must not depend on it. The thread it holds is documented as the accepted cost.
- Red first; no `#require` on a non-optional; no wall-clock ceiling; tests never block the pool; every wait through `pollUntil`/an `await` under a suite `.timeLimit`; a negative source check has a positive beside it; a number in a comment is counted; the diagnostic-log lines of the log plan's Task 3 keep firing (`list start/done`, `entry slow` — the slow line moves to phase two's child).
- Do NOT launch the GUI; the dev build is the maintainer's sight check.

---

### Task 1: Phase one — kinds without a metadata call

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift` (`list(path:)`: resolve the parent through `URL.resolvingSymlinksInPath()` ONCE, then `contentsOfDirectory(at:includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .nameKey])`; if that throws ENOTDIR (POSIX 20), fall back to `opendir`/`readdir` reading `d_type` (`DT_DIR` → `.directory`, `DT_LNK` → `.symlink`, `DT_REG` → `.file`, anything else → `.other`); every item's `size`/`modifiedAt`/`owner`/`group` nil; `path` built from the ORIGINAL unresolved parent so the rows keep the path the user navigated to — the file's own comment explains why the URL API's children come back under `/private/...`)
- Test: `Tests/macSCPCoreTests/LocalFileSystemTests.swift` (existing kind cases stay green; new: a symlinked parent lists through the fallback with the same kinds; the returned paths start with the unresolved parent; every size and date is nil after phase one)

- [ ] **Step 1: Red first** — the nil-metadata assertion and the symlinked-parent path assertion.
- [ ] **Step 2: Implement**; `swift test --filter LocalFileSystem` green; full `swift test`; zero warnings.
- [ ] **Step 3: Commit** `feat(local): the listing returns names and kinds from the directory read alone`.

---

### Task 2: Phase two — `metadata(for:)` as a stream, stuck children abandoned

**Files:**
- Create: `Sources/macSCPCore/RemoteFS/LocalMetadataSource.swift` (`public protocol LocalMetadataSource: Sendable { func metadata(for items: [RemoteFileItem]) -> AsyncStream<RemoteFileItem> }`)
- Modify: `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift` (adopts it: for each item, a child `Task` runs the existing `item(for:)` body — `resourceValues` + `ownerGroup` — through a `metadataProbe: @Sendable (URL) -> RemoteFileItem?` seam defaulting to the real call, timed; ≥ 500 ms → the `browser.local entry slow` debug line moves here; the stream yields the filled item; a counter of finished children finishes the stream when it reaches the item count OR when the consumer cancels (`onTermination`); children are never awaited — the shape of `abandonable` in `Tests/MacSCPAppKitTests` WebDAV tests, but in production code)
- Test: `LocalFileSystemTests` (one entry's probe parked on a `Gate` never opened: the stream yields every other entry, then finishes — asserted with the gate still closed; a cancelled consumer finishes the stream; owner/group present in phase two only when `fetchesOwnerGroup`)

- [ ] **Step 1: Red first** — `cannot find 'LocalMetadataSource'`; the parked-entry test.
- [ ] **Step 2: Implement**; green; zero warnings.
- [ ] **Step 3: Commit** `feat(local): metadata arrives per entry as a stream, and a stuck entry is left behind`.

---

### Task 3: The view model merges

**Files:**
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift` (`load()`: after `state = .loaded` with phase one, if `fs is any LocalMetadataSource`, consume `metadata(for: listed)` in the same task: for each item, replace the row with the same `path` in `displayedAll` and re-run `applySearch()`; re-sort only when `sortKey` ∈ {size, modified, owner, group}; every merge behind the `currentPath == path` staleness guard; navigating away cancels the consumer)
- Test: `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift` (a fake file system adopting `LocalMetadataSource` with a hand-driven stream: rows appear with nil size, then fill by path; `.size` re-sorts on arrival, `.name` keeps its order; a navigation mid-stream drops late rows)
- Test: a guard in `Tests/macSCPCoreTests/` (positive: `load()` consumes `metadata(for:`; negative beside it: `LocalFileSystem.list`'s body contains no `resourceValues(` — the per-entry call lives in phase two only)
- Modify: `docs/BACKLOG.md` (the home-folder half of the diagnostic-log row → Done with the three commits and what the dev build should show: the home folder appears at once, sizes fill in, a stuck entry shows `-`), `README.md` if a sentence fits (optional).

- [ ] **Step 1: Red first** — the merge tests; the guard.
- [ ] **Step 2: Implement**; `swift test` green; zero warnings.
- [ ] **Step 3: Commit** `feat(browser): the local pane shows the folder first and fills the details as they arrive`.
