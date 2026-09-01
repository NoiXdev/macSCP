# File checksums — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Be able to state, on request, what checksum a file has — and
never conceal where the value came from.

**Basis:** `docs/superpowers/specs/2026-08-31-file-checksums-design.md`

**Architecture:** A **narrow** capability in Core ("compute the checksum
of this file"), no general command path. Reading the output, choosing
the command form, and a value's provenance are pure functions.

## Global Constraints

- Code, comments, identifiers, test names, commit messages: **English
  only**.
- Conventional Commits; footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **No `exec(String)` in Core**, in any form and under any name. The
  caller must not be able to formulate a command.
- **The path goes through `PosixQuoting`.** No second quoting rule.
- **The far side's answer is input.** Only the first field is read,
  only as hex of the algorithm's length; the returned path is neither
  compared nor displayed.
- **No downloading** in order to compute — not even as a fallback.
- **Every new wait point gets a deadline.** Twice this week it was
  measured that an `await` against a silent peer does not come back.
- User-visible text in **all four catalogs** (`en`, `de`, `fr`, `pl`)
  via `L10n.string(_:_:)`; Core-side `CoreL10n.string(_:)`. **No String
  Catalog, no `String(localized:)`, no `Bundle.module`.** The German
  uses **du**.
- **Only show what is possible** — nothing gets greyed out; "this
  server provides no checksums" is a statement, a dead entry is not.
- **No line numbers, no location references in comments.** Every number
  and every enumeration gets counted in the same pass that writes it.
- All six targets are on `.swiftLanguageMode(.v6)`; **CI goes red as
  soon as the count of distinct warning sites exceeds 1.** Warnings are
  measured on a **fresh** scratch path.
- One scratch path per agent, deleted after use. The app is not
  launched, nothing is pushed.

---

### Task 1: The pure values

**Files:**
- Create: `Sources/macSCPCore/RemoteFS/FileChecksum.swift`
- Test: `Tests/macSCPCoreTests/FileChecksumTests.swift`

**Interfaces:**
- Produces: the algorithm as an enum, the result together with its
  **provenance**, reading an output, and choosing the command form.
  Tasks 2–4 call into this.

**Why first:** everything here is verifiable without a connection, and
it fixes what a result can even say. A result **without** provenance
must not be constructible.

- [ ] **Step 1: Red first.** Tests for: `<hex>  <path>` is read and
  yields only the hex; wrong length, non-hex, empty output, and an
  output **without** a path are rejected; a path in the answer that is
  not the one requested changes **nothing** (it is not even looked at);
  the GNU and the BSD form produce the same read value.
- [ ] **Step 2: Implement.** The provenance is **part** of the result,
  not a second field beside it that someone can omit — build it so a
  result without it cannot be constructed.
- [ ] **Step 3: The S3 case.** An ETag of the form `"…-N"` is **not**
  a file hash. A function decides this, with tests for both forms and
  for the quotation marks S3 supplies.
- [ ] **Step 4:** Full suite green, no new warning (fresh build).
- [ ] **Step 5: Commit** — `feat(remotefs): say what a checksum is and where it came from`

---

### Task 2: The narrow capability over SSH

**Files:**
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift`,
  `Sources/macSCPCore/Capabilities/ProtocolCapabilities.swift`,
  `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift`
- Test: `Tests/macSCPCoreTests/`, plus a gated case against the rig

**Interfaces:**
- Consumes: Task 1.

**The requirement that defines this task:** the capability is called
"compute the checksum of this file with this algorithm" and accepts
**no command**. Whoever passes a `String` through here has violated
the design — report it, don't build it.

- [ ] **Step 1: Red first**, against a double: the path is quoted
  (`PosixQuoting`, no second rule), the command form follows the answer
  determined once per connection, and an unreadable output becomes an
  error rather than a value.
- [ ] **Step 2: The execution path.** Narrow, with a **deadline**. Where
  `CitadelShell` has building blocks, use them — **look them up instead
  of inventing them**, and if the terminal path does not fit, say why in
  the report.
- [ ] **Step 3: The capability in `ProtocolCapabilities`**, modeled on
  `supportsPresignedURL`. That way the surface later does **not**
  branch on `ConnectionKind`.
- [ ] **Step 4: A gated case** (`MACSCP_ITEST=1`) against the rig, that
  fetches a real checksum and compares it against a locally computed
  one. Rig from the main checkout, never from a worktree; clean up on
  every exit path.
- [ ] **Step 5:** Full suite green, no new warning (fresh build).
- [ ] **Step 6: Commit** — `feat(ssh): compute a file's checksum on the remote`

---

### Task 3: The other three backends

**Files:**
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift`,
  `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift`,
  `Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift`
- Test: the respective suites

- [ ] **Step 1: Local** — computed, provenance "computed locally".
- [ ] **Step 2: S3** — from the ETag, **and** the multipart restriction
  in the result. A multipart ETag must not come out as a file hash;
  test for both forms.
- [ ] **Step 3: WebDAV** — unavailable, and as a **statement**. No
  `OC-Checksum` in this change.
- [ ] **Step 4:** Full suite green, no new warning (fresh build).
- [ ] **Step 5: Commit** — `feat(remotefs): answer the checksum question per backend`

---

### Task 4: Requesting and displaying

**Files:**
- Modify: the file info, the file table's context menu, `SettingsStore`
  and `SettingsView`
- Modify: all four `Localizable.strings`
- Test: `Tests/macSCPAppKitTests/`

**Interfaces:**
- Consumes: Tasks 1–3.

- [ ] **Step 1: In the file info**, for a single file, on request.
- [ ] **Step 2: For a selection**, via the context menu. **One after
  another**, the result appears as soon as it is there, cancelling
  leaves what has already been computed standing.
- [ ] **Step 3: The provenance appears alongside it** — for S3, visible
  that a multipart ETag does not describe the content. Whoever omits
  this text turns the display into a lie.
- [ ] **Step 4: The setting.** SHA-256 preselected; MD5 and SHA-1 note
  that they are suitable for matching against a third-party value and
  **not** as proof that two files are identical.
- [ ] **Step 5: Where it isn't possible, it says why.** No greyed-out
  entry.
- [ ] **Step 6:** Full suite green, no new warning (fresh build).
- [ ] **Step 7: Commit** — `feat(files): show a checksum on request, and where it came from`

---

## What explicitly is not part of this

- **No table column** — item 3 of the backlog entry, its own change,
  and its question 3 is unanswered.
- **No general command path** in Core.
- **No downloading** in order to compute.
- **No `OC-Checksum`** for WebDAV.
