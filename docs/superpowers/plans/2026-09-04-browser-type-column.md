# Browser Type Column Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In the S3 bucket list a bucket row shows a bucket symbol so it
reads as a bucket, not a folder; and the remote file table gains a
"Type" column (PDF, PNG, Folder, Bucket, Link, …) that sorts, in every
backend.

**Architecture:** `RemoteFileItem.Kind` is `file | directory | symlink`
(`RemoteFileItem.swift:4-6`); the S3 bucket list renders buckets as
directories. A new `RemoteFileItem.isBucket: Bool` (default false, set
by `S3FileSystem` in bucket-list mode) keeps every capability gate that
switches on `kind` untouched; the table's kind icon reads it. Core gains
`FileTypeLabel.label(for item: RemoteFileItem) -> String` (the
extension, uppercased, or the catalogue-keyed words for folder / bucket
/ link / a file without an extension) and `SortKey.type`. The table
(`RemoteFileTableView.swift`, `NSTableView`-based with a column enum and
per-column persistence) gains the column; the sort comparator uses the
label and falls back to the name.

**Tech Stack:** Swift 6 strict, AppKit/SwiftUI bridge, Swift Testing,
`RemoteBrowserViewModel.SortKey`, four catalogs.

**Spec:** `docs/BACKLOG.md`, row "File browser: a bucket icon, and a
Type column" (maintainer feedback 2026-09-04). **Correction, Task 1**:
the line below was measured wrong — the actual tree at `e6dbc83e`
already carried `FileSortKey` as `name | size | modified | permissions
| owner | group | type` (M11m/T2), and `RemoteFileTableView` already
built a "Type" column (`FileColumn.type`, `typeText(for:)`) — see
`.superpowers/sdd/2026-09-04-browser-type-column/task-1-report.md`.
~~Measured at HEAD: `RemoteBrowserViewModel.SortKey` is `name | size |
modified` (`:8-10`); `RemoteFileTableView.swift:387-396` builds
`NSTableColumn`s from a column enum's `rawValue`; the kind icon is
chosen from `kind`.~~

## Global Constraints

- English only in the tree; user-facing strings only via `L10n.string`/`CoreL10n.string` in all four catalogs (German du); Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; commit per task; zero warnings; do not push.
- `Kind` is not extended: every `switch kind` in Core and App stays exhaustive and unchanged; a bucket is a directory that carries `isBucket`.
- The type label derives from the name's extension only (no content sniffing, no network); a name with several dots uses the last extension; a dotfile without a further extension is "File".
- The column persists like the others (width, visibility, position — whatever the table persists today), defaults to visible, and sorts stably (label, then name).
- Red first; no `#require` on a non-optional; no wall-clock ceiling; tests never block the pool; a negative check needs a positive beside it; a number in a comment is counted; the browser guards stay green.
- Do NOT launch the GUI.

---

### Task 1: `isBucket` and the type label (Core)

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFileItem.swift` (`public var isBucket: Bool = false`; `Codable`/`Equatable` unaffected — check the memberwise init's callers, count them)
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift` (bucket-list mode sets `isBucket: true` on each bucket row — find `listBuckets()`'s row construction)
- Create: `Sources/macSCPCore/RemoteFS/FileTypeLabel.swift` (`label(for:)`, `sortKey(for:)`; words through `CoreL10n`: `core.fileType.folder`, `.bucket`, `.link`, `.file`)
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift` (`SortKey.type`, comparator label-then-name)
- Modify: Core's four catalogs
- Test: `FileTypeLabelTests` (`report.PDF` → "PDF"; `archive.tar.gz` → "GZ"; `.bashrc` → "File"; a directory → "Folder"; `isBucket` → "Bucket"; symlink → "Link"), `S3FileSystemTests` (bucket-list rows carry `isBucket`), the view model's sort test for `.type`

- [x] **Step 1: Red first**; **Step 2: Implement**; **Step 3: Commit** `feat(core): a file's type label, and buckets know they are buckets`.

---

### Task 2: The column and the icon (App)

**Files:**
- Modify: `Sources/MacSCPAppKit/RemoteFileTableView.swift` (the column enum gains `type`; header `browser.column.type`; cell text from `FileTypeLabel.label(for:)`; sort descriptor → `SortKey.type`; the kind icon for `isBucket` is `archivebox` or the SF Symbol the sheet already uses for buckets if one exists — grep `bucket` in `Sources/MacSCPAppKit` first)
- Modify: the App's four catalogs
- Test: the browser table guard (if one scans the column enum — find it; else a small one: every column case has a header key, the type cell reads `FileTypeLabel`, the bucket icon branch reads `isBucket`), `docs/BACKLOG.md` row → Done, README one sentence.

- [x] **Step 1: Red first**; **Step 2: Implement**; **Step 3: Commit** `feat(browser): a Type column, and a bucket looks like one`.
