# Backlog: checksums for files

**Status:** open
**Logged:** 2026-08-27, maintainer

## What is wanted

Three points that belong together but differ greatly in difficulty:

1. **In the file info** show a file's checksums.
2. **For several selected files** a context menu entry "Prüfsummen" that
   shows them for the selection.
3. **A new table column** with the checksum, plus a setting for **which**
   one (SHA-256, SHA-1, MD5, …).

## The measured starting state

| | |
|---|---|
| `RemoteFileItem` | carries `name`, `path`, `kind`, `size`, `modifiedAt`, `permissions`, `owner`, `group` — **no** hash and no ETag |
| Command execution in Core | **does not exist**. SSH has a shell (`CitadelShell`), but that serves the terminal, not a call with a return value |
| S3 ETag | is used internally for multipart uploads (`S3MultipartXML`), but **not** passed through into the listing |
| Existing checksum use | outbound only: `Insecure.MD5` for the `Content-MD5` header, `SigV4Signer.hexSHA256` for signing |

## The trap everything hinges on

**No protocol in this app delivers a file hash in passing.** What that
means per backend is the actual content of this entry:

| Backend | Where a hash would come from |
|---|---|
| **SFTP** | Not from the protocol at all. Either `sha256sum` via the shell — which requires the program on the other side and is no longer SFTP — or **download the whole file and hash it locally**. |
| **S3** | The ETag comes along for free with `ListObjectsV2`. **But it is only the file's MD5 for single-part uploads**; for multipart uploads it is `md5-of-the-md5s-N` and thus *not* a file hash. Showing it as "MD5" would be a lie that strikes exactly at large files. |
| **WebDAV** | No standard field. Some servers (Nextcloud) deliver `OC-Checksum`, but that is an extension and nothing a client can rely on. |
| **Local** | Unproblematic — the file is right there. |

**Point 3 is therefore the most dangerous, not the smallest.** A column
promises a value *per row*. For SFTP and WebDAV that would mean:
downloading every file in a directory as soon as it is opened. A folder
with 200 files of 50 MB each would be 10 GB of traffic for a column
someone switched on by accident.

## Maintainer decision (2026-08-27)

**Only on request. And not by downloading** — fetching the file in order
to hash it is not worth the price.

That answers questions 2 and 3 below and at the same time cuts back the
scope of the feature. The other side must compute, and from that follows:

| Backend | What follows from it |
|---|---|
| **SFTP** | Only via a command on the other side (`sha256sum` and relatives). Requires the program to be there and needs a way in Core to run a command with a return value — **which does not exist today**. That is the actual build effort. |
| **S3** | The ETag, with the multipart limitation above. No computing needed, but also no free choice of algorithm: it is what it is. |
| **WebDAV** | **Not at all**, unless the server delivers `OC-Checksum` or similar. For a standard WebDAV server, the feature therefore does not exist. |
| **Local** | Unproblematic, computed locally is not a download. |

**The consequence that needs to be named here:** the feature is not
available everywhere. A menu entry that is missing or fires into nothing
on WebDAV must *say so* — "this server does not deliver checksums" is a
usable answer, a greyed-out entry with no explanation is not.

If "not downloading" was meant more narrowly than it is read here — say,
"not on its own, but yes on explicit request" — SFTP without a foreign
program comes back, and WebDAV becomes possible at all. This reading is
deliberately **not** chosen; it stands here so the choice stays visible
when this is taken up, instead of being forgotten.

## What must be decided before taking this on

1. **Computed or queried?** A hash that comes from the ETag on S3 and
   from a download on SFTP is not the same promise. Either keep those
   apart and **name** them (where the value comes from, and whether it
   describes the file content), or compute everywhere yourself and pay
   the same price everywhere for it.
2. **When is it computed?** Never on its own would be the safe answer:
   checksum on request, per file or per selection, with visible progress
   and cancellation — the same as a transfer, because that is exactly
   what it is.
3. **What does the column show while nothing has been computed?** Empty,
   a button, or a value that came from the listing? Without an answer to
   this, the column becomes either useless or dangerous.
4. **Which algorithms?** SHA-256 as the default. MD5 and SHA-1 are still
   common for integrity checks against a third-party value, but
   cryptographically broken — if they are offered, that belongs stated at
   the setting, not placed alongside as an equal choice.
5. **Does the capability go into `ProtocolCapabilities`?** There is
   already `supportsPresignedURL` as an example of "this backend can do
   something others cannot". A flag such as "delivers checksums without
   reading" would be the same shape — and would keep the UI from
   branching on `ConnectionKind`.

## Scoping proposal

Do not build this as one change. Points 1 and 2 are the same thing at two
sizes (one file, several files) and **on request** — that is a
manageable, honest change. Point 3 is its own, and it should only be
taken up once question 3 above is answered.

## Decided 2026-09-02 — question 3

The maintainer's answer to "what does the column show while nothing has
been computed": **empty, and computing is an action.** Nothing is
computed for a whole listing automatically; the user asks for a file's
checksum (context menu / selection, the same `ChecksumCommandLine` path
as today) and the column fills for that file. A value that came from the
listing (an ETag) appears in the column only when it is provably the
file's hash — the multipart case stays "not the checksum". Question 4
stands as written (SHA-256 default; MD5/SHA-1 offered only with the
warning at the setting). Item 3 is plannable now.

## Done 2026-09-02 (night) — item 3, the column

Planned in `../plans/2026-09-02-checksum-column.md`. Commits: `57e5927`
(`ChecksumLedger`, Core), `3cd7221` (the column), `da30363` and
`589e431` (the review's two fix rounds — the second one closes a real
hole: a hash still in flight across a disconnect/reconnect used to land
in the NEW session's ledger; the binding now carries the session id it
was made for and a stale one writes nothing). What it is: a toggleable column "Checksum (SHA-256)" — the
header names the algorithm the setting selects — hidden by default,
persisted through `visibleColumns` like the others, that shows a value
ONLY for a row whose checksum the user asked for, through the existing
action: the context-menu batch and the info sheet both go through one
compute funnel in `BrowserPane` that records into the tab's ledger
(`BrowserSession`, one per side), and that funnel is the ledger's only
writer — pinned by a guard scoped to the files that mention the ledger,
with the positive anchor beside it. No listing, refresh, scroll or
toggle computes anything; the column is a display.

The ledger's key is `(path, size, modifiedAt)`, so a row that changed
size or date reads empty again, and only values with digest provenance
enter it — a multipart ETag never reaches the column, exactly as it
never reaches the sheet as "the checksum". **The limit the review
named:** a same-size rewrite within one modification-time tick (SFTP and
WebDAV carry whole seconds) keeps the old value visible; the sheet has
the same blindness, so the column is no worse than what existed — but
it is a limit, not a guarantee. Changing the algorithm rebuilds the
columns only while the checksum column is visible, so hidden it costs
the user no column widths.

Two things the reviews found on the way, worth keeping: a source scan of
the cell mapping stayed green after the real branch was renamed, because
a second switch spelled the same string — replaced by an exhaustive
`switch` over `FileColumn` (a forgotten column is now a compile error,
CLAUDE.md's "structural boundary beats a scanner"); and a guard's
`fileDeclaring("struct BrowserPane")` matched `BrowserPaneSide` too — it
now requires the name to end where it is written. Still open in this
entry: no progress within a file; no dedicated case for "this algorithm
does not exist here".

