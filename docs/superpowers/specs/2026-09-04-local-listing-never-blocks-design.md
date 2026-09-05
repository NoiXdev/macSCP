# The local listing never waits on one entry — design (draft, awaiting the maintainer's go)

**Date:** 2026-09-04. **Trigger:** the 1.3.0 report behind
`2026-09-04-diagnostic-log-design.md`: the home folder loads for five
minutes or never. Whatever the log turns out to name, the shape of the
defect is already visible in the code: `LocalFileSystem.list`
(`Sources/macSCPCore/RemoteFS/LocalFileSystem.swift:32-81`) reads the
names in one call and then runs one synchronous `resourceValues` per
entry in a plain loop; `RemoteBrowserViewModel.load` (`:243-259`)
publishes the array all at once, after the loop. A single entry whose
metadata call blocks — a dead network mount, a cloud placeholder the
provider is slow to answer for, a privacy prompt that never appears —
blocks every other entry and the whole pane. The `.task` that runs the
load is cancelled when the pane goes away, but a thread stuck in a
syscall does not read cancellation, so the listing cannot be stopped
either.

## Measured at HEAD (89646c4c)

- Names come from `FileManager.contentsOfDirectory(atPath:)` — a
  single `readdir` pass that has already succeeded when the loop
  starts; it carries no metadata.
- Per entry: `resourceValues(forKeys: [.isDirectoryKey,
  .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])`
  (a `stat`/`lstat`), then, only with the owner or group column
  visible, `attributesOfItem` (a second `lstat` plus name lookups).
- `RemoteFileItem`'s `size`, `modifiedAt`, `owner`, `group` are already
  optional and render as `-` when nil (`FileListFormatter.swift:42-48`);
  `kind` is not optional and is what navigation, the icon and the
  sort's folders-first rule read.
- Nothing in the path is cancellable or bounded; no test covers a slow
  or stuck entry.

## Design: names and kinds now, the rest as it arrives, nothing waited on

1. **Kind without a metadata call.** The directory read itself can
   answer the kind: `readdir`'s `d_type` (regular / directory / symlink,
   available on APFS and HFS+; `DT_UNKNOWN` on some network file
   systems) — or, where Foundation must stay, `contentsOfDirectory(at:
   includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])`
   whose prefetch is one bulk `getattrlistbulk` call on the directory,
   not one `stat` per child. The plan measures which of the two this
   tree can use (the file's own comment records why the URL API was
   dropped: it rejects a symlinked parent with ENOTDIR — the plan tries
   it after resolving the parent's symlink once, and falls back to
   `d_type` if it still fails). A `DT_UNKNOWN` entry is `.other` until
   its metadata arrives.
2. **Two phases in the file system.** `LocalFileSystem.list` returns
   as soon as names and kinds are known, every `size`/`modifiedAt`/
   `owner`/`group` nil. A new `LocalFileSystem.metadata(for items:
   [RemoteFileItem]) -> AsyncStream<RemoteFileItem>` yields each entry
   again, filled in, as its own metadata call returns — each call on
   its own child task, the stream finishing when the last child does
   or when the consumer cancels. A child that never returns is
   abandoned, not awaited: the stream's finish does not wait for it
   (the `abandonable` shape the WebDAV tests use). The thread that child
   holds stays held; the design accepts one stuck thread per stuck
   entry over a stuck pane, and the diagnostic log names the entry.
   A session-scoped memory (`StuckPaths`, designed, not yet measured
   against a live report) is intended to keep that acceptance from
   compounding across repeated visits to the SAME directory: a path
   named stuck once is remembered for the life of the browser session
   and skipped on every later listing of it, so a folder someone keeps
   returning to — the design's own working example is the tester's home
   folder — is not expected to cost a fresh stuck thread on each visit,
   only on the first. Two separate deadlines are intended to drive this,
   not one: a short one (500 ms) that only ever writes the `entry slow`
   log line, so an ordinarily slow entry is never mistaken for a stuck
   one, and a longer one (5 s, designed, not yet measured against a
   live report) that is the sole trigger for the memory above, chosen
   so a cloud placeholder or a momentarily busy network mount answering
   within a second or two is never blacklisted off one slow listing.
   An entry marked by the longer deadline that still eventually answers
   is intended to clear its own mark, so only a genuinely, persistently
   stuck path stays remembered.
3. **The view model merges.** `RemoteBrowserViewModel.load` publishes
   phase one (`state = .loaded`, rows with `-` where metadata is
   missing), then consumes the stream and replaces rows by path as they
   arrive, re-sorting only when the sort key is one the metadata feeds
   (size, modified, owner, group — name and type are known from phase
   one). The staleness guard (`currentPath == path`) applies to every
   merge; navigating away cancels the consumer, which finishes the
   stream. A remote file system does not gain the second phase: SFTP's
   `readdir` already returns attributes with the names.
4. **A bound for the sight of it.** Each metadata child is measured;
   a child slower than 500 ms writes the `browser.local entry slow`
   debug line (the log plan's Task 3), which is how the stuck entry
   gets its name into a report.

What this does NOT do: it does not make a stuck syscall unstick, and it
does not decide whether the entry is a mount or a placeholder — the log
does that. It makes the pane show the folder in the time the directory
read takes, with one row showing `-` where the system is not answering.

## Tests (Core, no GUI)

- A `LocalFileSystem` built over a temporary directory with a
  `MetadataProbe` seam (`(URL) -> URLResourceValues?`, defaulting to
  the real call): with one entry's probe parked on a `Gate` the test
  never opens, `list` returns every name with the right kind, and the
  stream yields every OTHER entry filled in and then finishes — the
  parked child is abandoned (asserted: the stream finished; the gate
  is still closed). No wall-clock ceiling: the suite `.timeLimit` is
  the only clock.
- Kinds from phase one match the kinds the old per-entry path produced
  (file, directory, symlink, dangling symlink) — the existing
  `LocalFileSystemTests` cases stay green unchanged.
- View-model tests with a fake file system whose stream yields in a
  chosen order: rows appear with `-`, then fill in by path; the
  `.size` sort re-sorts on arrival, the `.name` sort does not; a
  navigation mid-stream drops late rows (the staleness guard).
- A guard: the local pane's load path consumes `metadata(for:)`
  (positive) and no call to `resourceValues` remains inside `list`'s
  own loop (negative beside it).
