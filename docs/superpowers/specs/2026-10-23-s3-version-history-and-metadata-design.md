# S3: version history, deleted files, metadata and ACLs — design

**Date:** 2026-10-23
**Status:** draft for maintainer approval. The two questions this document
opened were answered by the maintainer on 2026-10-23 and are recorded as §11.
Not committed yet — it is committed onto the second half's own branch once
`s3-bucket-settings` has landed in `develop`, so the tree handed over for that
merge stays untouched.
**Predecessor:** `docs/superpowers/specs/2026-10-19-s3-bucket-settings-design.md`
(the first half). Its §10 records this half in one paragraph; this document is
that paragraph worked out.
**Backlog row:** "S3: the tools of s3Manager (maintainer wishlist)" in
`docs/BACKLOG.md`.

---

## 1. Intent

A versioned bucket remembers every write, and macSCP currently shows none of
it. The browser lists one row per key — the newest version — and a key whose
newest version is a delete marker is not listed at all. So the store is holding
the thing a person wants back, and the app has no way to say so, let alone hand
it over.

This half gives a single file its history: which versions exist, which one is
current, which ones a lock forbids touching, and what can be done with an old
one. It also makes a deleted file findable again, because the action §10 of the
first half named — lifting a delete marker — is otherwise unreachable: the
right-click that would offer it hangs off a row the browser does not draw.

Two tools the maintainer ranked ahead of the first half on 2026-09-16 and which
that half skipped come with it: the metadata editor, and reading an object's
ACL. The maintainer asked on 2026-10-23 to fold them in rather than defer them
a second time.

### Why this, now

- The first half built the read path for Object Lock (`S3BucketSettings`,
  `parseObjectLockState`) and the sheet grammar these dialogs copy. A version
  row has to show a lock **before** the user clicks it, and that is the
  dependency that put this half second rather than first.
- The first half's own anti-goal — "A setting that silently did nothing. Every
  write is read back from the store, never assumed from a 200." — turns out to
  decide one of this half's features outright (§3, ACLs).
- The metadata editor and ACLs have been "Deferred, not dropped" in the backlog
  row since 2026-09-16.

---

## 2. Goals

1. **One file's history, in one sheet.** Every version and every delete marker
   of a single key, with what each one is visible in the row.
2. **A lock reads before the click.** A version under retention or legal hold
   is marked as such in the list, and the action that cannot succeed is
   disabled with the reason beside it — never an enabled control that fails.
3. **Things to do with a version**: open it read-only, compare it with the
   current one, download it, make it current again, delete it for good.
4. **A deleted file is findable.** With one app-wide switch on, a key whose
   newest version is a delete marker appears in the browser, marked as deleted,
   and can be brought back from there.
5. **An object's metadata is editable** — `Content-Type`, `Cache-Control`,
   `Content-Disposition` and custom `x-amz-meta-*` — and the dialog says what
   that costs: on a versioned bucket it writes a new version.
6. **An object's ACL is readable.** Who holds which permission, shown as the
   store reports it. **No write.** §3 says why.
7. **A stored connection can create a bucket** from the connection manager,
   without first connecting by hand.

---

## 3. Non-goals and anti-goals

**Non-goals** (wanted, not here):

- **A public/private toggle, or any ACL write.** Removed from this half by the
  maintainer on 2026-10-23, on the measurement in §4.6: this store answers
  `PUT ?acl` with 200 and does not store the grant. Under the first half's
  read-back rule the control could only ever report "not confirmed", and no
  store available to this project would let a test prove otherwise.
- **Bucket policies.** The mechanism AWS actually uses for public access on a
  modern bucket is a different feature with a different surface. Not measured
  here, not designed here.
- **Multipart copy.** AWS refuses a single-part `CopyObject` above 5 GiB, and
  §4.10 did not reach that size on this store. Both copy-based writes here
  (restore, metadata) therefore surface the store's refusal through
  `S3FileSystem.mapErrorStatus` rather than growing a multipart path, and the
  ceiling gets a `docs/BACKLOG.md` row of its own. The existing copy caller,
  `S3FileSystem.rename(from:to:)`, is silent on it today.
- **Sync, the dashboard, cross-bucket move.** Unchanged from the first half's
  §3: sync overlaps rsync, and nobody has asked for the other two.
- **Version history for anything but S3.** The seam is written so another
  backend could fill it (§5), and none does.
- **A paging UI.** §4.9 measured that continuation works, so a long history is
  fetched page by page; no control for navigating pages is designed. The list
  is one list.

**Anti-goals** — these make this work a failure even if it ships:

- **A version list that lies about what is locked.** Goal 2 is the reason this
  half is second. A row that looks deletable and is not, or looks locked and is
  not, is worse than no list.
- **A setting that silently did nothing.** Carried over verbatim from the first
  half, and this time it has teeth: it is why §2.6 has no write.
- **A test that is green because the store accepted a write it did not
  store.** The first half's twin of this named a flow a real provider refuses
  while the rig accepts it. §4.6 measured the other direction — the rig returns
  200 and keeps nothing — and a read-back assertion is the only thing that
  tells them apart. Every write in this half is read back.
- **An unreachable action.** Goal 4 exists because "lift the delete marker"
  had no route to it. Any action added here needs a surface a person can
  actually arrive at, and the design says which one.
- **A permanent delete that did not feel permanent.** Deleting one version is
  the only action in this half that nothing can undo.
- **A new version nobody expected.** Restoring and editing metadata both write
  a new version (§4.4, §4.5). A user who corrects a `Content-Type` and finds a
  second identical-looking row has been surprised by the design, not by S3.
  §11 settles the two places where this anti-goal was still open, and both
  settlements are the conservative one.

---

## 4. What the store actually does — measured 2026-10-23

RustFS 1.0.0, the rig's S3 half, at `127.0.0.1:19000`. Every figure below comes
from one of three runs on 2026-10-23, against buckets the scripts created and
deleted again (`macscp-ver-probe`, `macscp-ver-lock-probe`, `macscp-vq-probe`,
`macscp-pg-probe`); the rig's own `macscp-seed` and `macscp-second` were not
touched, and the name `macscp-probe-lock` does not occur in any run's output.

Signed with curl's own SigV4, the form `docker/test-server/s3/init.sh` uses.
The two credential values are the rig's, named in
`docker/test-server/README.md`; export them before running anything below.

```sh
EP=http://127.0.0.1:19000
s3() {                      # s3 METHOD PATH [curl args…] -> status code
    local m=$1 p=$2; shift 2
    curl -s -g -X "$m" --aws-sigv4 "aws:amz:us-east-1:s3" \
        --user "$ROOT_KEY:$ROOT_SECRET" \
        -o /tmp/body -D /tmp/hdr -w '%{http_code}' "$EP$p" "$@"
}
```

`-g` turns curl's URL globbing off. It is not decoration: §4.9 is a correction
that exists because the first attempt at it omitted `-g`.

**Nothing in this section is a claim about AWS.** Where a divergence from AWS
matters it is named as unmeasured.

### 4.1 `ListObjectVersions` exists

`s3 GET "/$B?versions"` → **200**, a `ListVersionsResult` carrying `Version`
and `DeleteMarker` children with `Key`, `VersionId`, `IsLatest`, `Size`,
`ETag`, `LastModified`, `StorageClass`, plus `IsTruncated`, `MaxKeys` (1000),
`KeyMarker` and `VersionIdMarker`. Version ids are UUIDs here; AWS's are
opaque strings of a different shape, so nothing may parse them.

The two kinds of entry arrive distinguished by element name rather than by a
flag. What this call does with `prefix`, `delimiter` and the markers is §4.8
and §4.9 — measured separately, because a response that *contains* a marker is
not a request that *honours* one.

### 4.2 A delete without a version id leaves a marker

`s3 DELETE "/$B/doc.txt"` → **204**, with `x-amz-delete-marker: true` and the
marker's own `x-amz-version-id` in the response headers. `s3 GET "/$B/doc.txt"`
→ **404**, body `<Code>NoSuchKey</Code>`. The listing then shows the marker
with `IsLatest` true, above both content versions, which keep theirs false.

### 4.3 Lifting a marker is one call

`s3 DELETE "/$B/doc.txt?versionId=<marker id>"` → **204**, and
`s3 GET "/$B/doc.txt"` → **200** with the content that was current before the
delete. No copy, no re-upload.

### 4.4 Restoring an old version is a copy onto itself

`s3 PUT "/$B/doc.txt" -H "x-amz-copy-source: /$B/doc.txt?versionId=<old id>"`
→ **200**, `CopyObjectResult`. The listing afterwards holds a **new** version
with a new id, carrying the old content, and every intervening version still
stands with `IsLatest` false. Restoring adds; it does not erase.

### 4.5 A metadata change is a copy, and it makes a version

```sh
s3 PUT "/$B/doc.txt" \
    -H "x-amz-copy-source: /$B/doc.txt" \
    -H 'x-amz-metadata-directive: REPLACE' \
    -H 'x-amz-meta-note: set-by-probe' \
    -H 'content-type: text/markdown'
```

→ **200**. `HEAD` then reports `content-type: text/markdown` and
`x-amz-meta-note: set-by-probe`. The version listing grew from three entries to
four. The new version's `ETag` is **identical** to the one it was copied from,
the bytes being unchanged — which is the one signal that distinguishes a
metadata-only version from a content change, and §6.1 uses it.

There is no in-place metadata write in S3 at all; this is the mechanism, not a
choice this design made.

### 4.6 ACLs answer and do not store

- `s3 GET "/$B?acl"` → **200**, an `AccessControlPolicy` with exactly one
  `FULL_CONTROL` grant whose `Grantee` element is **empty** — no `ID`, no
  `DisplayName` — above an `Owner` that does carry an id and the display name
  `rustfs`.
- `s3 PUT "/$B/doc.txt?acl" -H 'x-amz-acl: public-read'` → **200**.
- `s3 GET "/$B/doc.txt?acl"` → **200**, and the policy is **unchanged**: the
  same single owner grant. The public grant was accepted and not kept.
- `s3 GET "/$B?ownershipControls"` → **501**, `<Code>NotImplemented</Code>`,
  `GetBucketOwnershipControls is not implemented yet` — the exact case the
  first half's Review Focus line 2 and `S3FileSystem.mapErrorStatus` already
  handle.

This is the finding that removed the toggle (§3). **Not measured here:** that
AWS refuses `PutObjectAcl` outright on a bucket with Object Ownership set to
`BucketOwnerEnforced`, and that Hetzner's object storage honours ACLs. Both are
reasons the feature was wanted; neither is evidence this project holds.

### 4.7 A GOVERNANCE retention on one version blocks that version's delete

With a lock-enabled bucket, an object written, and a GOVERNANCE retention set
on its version until the next day:

- `s3 DELETE "/$LB/locked.txt?versionId=$LV"` → **403**, `<Code>AccessDenied</Code>`,
  message `Object is under GOVERNANCE retention and cannot be deleted until
  2026-10-24 13:51:08.0 +00:00:00`.
- The same call with `-H 'x-amz-bypass-governance-retention: true'` → **204**.

So the store would permit it. The only thing that stops a macSCP user is that
macSCP sends no bypass header — a promise already shipped, in four languages,
and quoted verbatim in §7.

### 4.8 `prefix` and `delimiter` are honoured

Against a bucket holding `a/one.txt` (twice), `a/two.txt`, `root.txt`, and
`b/three.txt` with a delete marker on top:

| Call | Result |
|---|---|
| `s3 GET "/$B?versions"` | 5 `Version`, 1 `DeleteMarker` |
| `s3 GET "/$B?versions&prefix=a/"` | 3 `Version`, 0 `DeleteMarker`, `Prefix` echoed as `a/` |
| `s3 GET "/$B?versions&prefix=a/one.txt"` | 2 `Version`, both that key |
| `s3 GET "/$B?versions&delimiter=%2F"` | 1 `Version` (`root.txt`), **2 `CommonPrefixes`** (`a/`, `b/`) |

Two consequences the design leans on. **One file's history is one request** —
`?versions&prefix=<full key>` — not a paged walk of the bucket with client-side
filtering. And the deleted-files listing (§6.3) folds prefixes exactly the way
the browser's own listing does, which is `list-type=2&prefix=…&delimiter=/` in
`S3FileSystem`.

### 4.9 Continuation is honoured — and the marker carries an internal token

Four keys, `max-keys=1`, following the markers the store hands back, with each
marker percent-encoded:

```
page 1: HTTP 200  key=k1.txt  IsTruncated=true
page 2: HTTP 200  key=k2.txt  IsTruncated=true
page 3: HTTP 200  key=k3.txt  IsTruncated=true
page 4: HTTP 200  key=k4.txt  IsTruncated=false
```

All four keys, in order, terminating correctly. A plain marker works too:
`?versions&max-keys=1&key-marker=k1.txt` returns `k2.txt`.

But the `NextKeyMarker` RustFS returns is **not** just a key:

```
k1.txt[rustfs_cache:v2,id:58bdf6cd-abf7-46e6-be83-f09a449f2af3,src:walker,gen:live]
```

An internal walker handle, identical across the pages of one listing. It must
be percent-encoded when sent back — `[`, `]`, `,` and `:` all appear in it —
and a client that pastes it into a URL by concatenation will send something
else. **Not measured:** what AWS returns here; a plain key is what its
documentation describes, so code must not assume either shape.

**Corrected 2026-10-23, in the same pass.** The first attempt at this
measurement reported, verbatim: *"page 2 with those markers → HTTP (empty), and
the result repeated `a/one.txt` with IsTruncated still true, so continuation
does not advance — a client that pages naively loops forever on the first
key."* **That is withdrawn in full.** It measured nothing: curl reads `[` as a
glob range, refused the URL, never sent the request, and left the previous
call's body in place — which is exactly why the status field came back empty
beside a body that looked like an answer. The store was never asked. Re-run
with `-g` and percent-encoding, it pages correctly, as above. The real finding
is the token, not a broken continuation.

### 4.10 A single-part `REPLACE` copy of 8 MiB works

An 8 MiB object, then a metadata `REPLACE` copy onto itself: **200**, and
`HEAD` afterwards reports `content-length: 8388608` with the new
`content-type: video/mp4`. So the mechanism is not limited at small sizes.

**Not measured:** anything near the 5 GiB single-part ceiling AWS documents.
§3 names the consequence.

---

## 5. The seams

Two optional capability protocols, queried with `as?`, following
`PresignedURLProvider` and the first half's `S3BucketSettings` — both live in
`Sources/macSCPCore/RemoteFS/`, and so do these.

- **`ObjectVersionProvider`** — one file's versions, the per-version actions,
  and the deleted-entry listing. Not named for S3: the first half's Goal 1 was
  that a protocol's own tools reach the window through a seam another backend
  could fill, and nothing about a version list is S3-specific.
- **`ObjectMetadataProvider`** — reading and replacing an object's metadata,
  and reading its ACL. Reading the ACL sits here rather than in a third
  protocol because it is the same subject (one object's attributes) reached
  from the same sheet.

### 5.1 How a single version is addressed

`RemoteFileSystem` is **not** touched — not `list(path:)`, not `readStream`,
not `stat`. Every backend implements it and a version id concerns one.
`ObjectVersionProvider` therefore carries its own version-aware read
(`readStream(key:versionId:)` and the `stat` it needs), and the queue and the
comparison gain entry points that take a version id beside a path.

The rejected alternative is a pseudo-path (`/bucket/key?versionId=…`) threaded
through the existing path-based plumbing. It is cheaper to write and wrong
here: that string would have to survive `RootMode.resolve`, `stat`,
`statWithEntityTag`, the path bar, `TransferPlan` and the download's local
filename, and every one of those is a place where a `?versionId=` would be a
second spelling of something the type system could have carried. This project
has a rule about second copies of a name.

A downloaded old version must not collide with the current one on disk: the
local name carries a distinguishing suffix, which the builder picks (§8).

### 5.2 What the browser row carries

`RemoteFileItem` gains **one** optional field,
`deleteMarkerVersionID: String?`, defaulting to `nil`, with `isDeleted`
derived from it being non-`nil`. The field, not a bare `Bool`: §4.3's restore
needs the marker's own version id, and a `Bool` would force a second listing
round trip per restore — with a race against a stale list.

That is the pattern `isBucket` already set in this same type, for the same
stated reason: "Defaults to `false` so every existing call site keeps compiling
unchanged." `FileTypeLabel`, which checks `isBucket` first, is where the label
for a deleted row belongs.

### 5.3 Versioning state, cached at listing time

`Show Versions…` has to render enabled or disabled **synchronously** — the
context menu is built in `menuNeedsUpdate`, and `FileActionContribution`
carries `id`/`titleKey`/`titleDefault` only, with no availability field (it is
`ConnectionActionContribution`, the first half's seam, that grew one).

So the bucket's versioning state is prefetched into a cache at listing time, a
sibling of the existing `ObjectLockStateCache`, and the menu reads the cache.
The file-action seam is left alone. Where the cache has no answer yet, the row
is enabled and the sheet explains — which is strictly better than a row
disabled with the wrong reason.

---

## 6. The pieces

### 6.1 The version sheet

Reached by right-clicking a file in the browser: **Show Versions…**, a
`fileActions` contribution, which is the seam the first half's per-file Object
Lock actions already use. Where versioning is off, the row is disabled, with
the reason as the item's tooltip (§5.3 is how it knows in time).

**The tooltip is new behaviour, not a copied pattern.** Measured 2026-10-23,
while the plans were being written: the nearest precedent,
`ConnectionActionsMenu`, answers availability with an App-side closure
(`let isAvailable: (ConnectionActionContribution) -> Bool`) and renders the row
`.disabled(!isAvailable(action))` with **no reason text at all**. The closure
shape is copied; carrying a reason is this design's addition.

The sheet is the audit log's shape, chosen by the maintainer on 2026-10-23 from
three drawn alternatives: a sortable `Table`, a filter control, the existing
`SheetSearchField` (with its regex toggle), and a counting footer. Its data is
one request, `?versions&prefix=<key>` (§4.8), continued per §4.9 if truncated.

- **Columns**: modified, size, state, version id.
- **State** is where goal 2 lives: current, locked with its retain-until date,
  legal hold, delete marker. A metadata-only version — same `ETag` as its
  predecessor, per §4.5 — is marked too, so a person who corrected a
  `Content-Type` can see why two rows look alike.
- **Lock state is read in a second stage**, after the listing, and only when
  the bucket has Object Lock enabled. This is the first half's D1 lesson
  applied before it can bite again: there, reading the lock first and
  unconditionally made a wholly successful operation on a store without Object
  Lock report itself unconfirmed. A listing that succeeded must not be spoiled
  by a lock read that was never applicable.
- **The lock read is bounded.** Retention and legal hold are two separate
  per-version requests with no batch form, so a 200-version history is some
  400 signed requests. They are issued for the rows on screen, with bounded
  concurrency, and cancelled when the sheet closes. The state column therefore
  has a **third** value — not yet known — distinct from "could not be read",
  and an action is never enabled on a not-yet-known lock.
- A failed lock read does not empty the list. The rows show, and the state
  column says the lock could not be read — the sibling precedent is
  `aLockThatCannotBeReadDoesNotCostABucketThatIsNotEnabled`.

### 6.2 The row actions

In the row's context menu:

| Action | Mechanism | Disabled when |
|---|---|---|
| Open | a read-only copy, no write-back watcher (§11.1) | it is a delete marker |
| Compare with Current Version | the existing line diff (`ComparisonDiffView`) | the row **is** current, or it is a delete marker |
| Download… | the existing transfer queue, via §5.1's version-aware read | it is a delete marker |
| Restore as Current | §4.4's copy | it is the current version |
| Delete This Version… | `DELETE ?versionId=` | retention or legal hold forbids it, or the lock is not yet known (§6.1) |

*Compare* is a new route to code that exists, not new code: the diff landed on
the diff-view branch and is on `develop`.

**Restore** writes a new version and says so before it runs. **Delete This
Version…** takes an ordinary confirmation dialog — the maintainer's decision of
2026-10-23 — and no bypass path exists for a locked version in any form.

### 6.3 Deleted files in the browser

An app-wide setting, `showDeletedFiles`, built the way `showHiddenFiles` is: a
switch in General settings, a menu command that toggles it, both panes always
agreeing. Off by default.

**The analogy covers the switch, not its effect, and the difference is a
cost.** `showHiddenFiles` filters rows that are already loaded; this one
changes what is fetched. So toggling it **re-lists** — in every pane of every
tab where it applies — and does nothing at all on a local pane, a non-S3
connection, the bucket-list root, or a bucket without versioning.

The listing is a **merge**, not a replacement: `list(path:)` as today, plus one
`?versions&prefix=…&delimiter=/` call whose latest delete markers become extra
rows (§4.8 measured that both parameters work, so this is one request and not a
walk). The merge belongs in Core, beside the existing browser listing, so both
panes and the tests reach it the same way.

A deleted row is greyed, marked in the type column, and its context menu
offers **Restore** — §4.3's single call, using the marker id the row carries
(§5.2) — without opening the version sheet first.

The menu command is dead text on a connection that is not S3. The first half's
precedent is to leave such a row visible and **disabled**, and that was decided
for a menu only S3 opens; this item sits in a main menu every connection sees,
which is not the same case. §9.6 records how it is settled and that it is the
weakest call in this document.

**Corrected 2026-10-23**, while Plan A was being written and the precedent was
read rather than recalled. This paragraph said, verbatim: *"The first half's
precedent is to leave such a row visible and disabled with its reason, and that
was decided for a menu only S3 opens"*. **"with its reason" is withdrawn.**
`ConnectionActionsMenu` disables the row and shows no reason — the whole of it
is `.disabled(!isAvailable(action))`, and `isAvailable` returns a `Bool` with
nowhere for a sentence to live. The claim was a precedent invented for a
decision this document was making anyway, which is the failure mode this
project has a rule about: a number or an enumeration written without counting.
What the precedent actually supports is disabling rather than hiding, and that
is what §9.6 rests on.

### 6.4 The metadata editor

A sheet on a single file, reached from `fileActions`. Four fields from the
backlog row: `Content-Type`, `Cache-Control`, `Content-Disposition`, and the
custom `x-amz-meta-*` pairs as an editable list.

Read with `HEAD`, written with §4.5's `REPLACE` copy, and **read back with a
second `HEAD`** before the sheet reports success. The sheet states, before the
write, that on a versioned bucket this adds a version.

On a bucket whose default Object Lock retention is COMPLIANCE, that added
version is one nobody can delete until the date. The sheet therefore reads the
bucket's default **before** the write and, where it is COMPLIANCE, runs the
first half's date-naming acknowledgement before proceeding (§11.2). Reading the
default costs one request and is needed whatever the answer had been.

### 6.5 The ACL display

Read-only. `GET ?acl` on the object, rendered as grantee and permission per
row, with the owner named separately. Where the store answers `501` the sheet
says the store does not offer this, which is what
`S3FileSystem.mapErrorStatus` already produces for `NotImplemented`.

An empty `Grantee`, which §4.6 measured, must render as something honest rather
than as a blank row — the store reported a grant whose holder it did not name.

### 6.6 The connection manager's one entry

A stored connection has no open connection, and every tool in both halves
needs one. So exactly one action goes on that surface: **New Bucket…**, the
case where there is nothing to browse to yet.

**It opens a real tab.** The standing invariant is that connection and session
state belongs to the window scope and never to anything app-wide, and
`TabTeardown.run(_:reason:)` is the one place the teardown stages are spelled.
A transient connection owned by the connection manager would be a second owner
of exactly the thing that invariant exists to keep single. So the entry opens a
tab, connects it like any other, and presents the first half's
`CreateBucketSheet` on it; cancelling the sheet leaves an ordinary connected
tab, and closing the window tears it down the one way every tab is torn down.
After a successful create the user is on that tab, at the bucket list.

Connecting is not silent — it can raise a host-key prompt or a credential
prompt — so the menu item is spelled as the thing it does.

**Not offered for a connection in single-bucket mode.** The first half
restricted create-bucket to bucket-list mode because "a bucket created there
would be invisible", and a stored connection configured that way inherits that
reason unchanged.

---

## 7. Constraints

- Swift 6 strict, `.swiftLanguageMode(.v6)`, macOS 15 floor, SwiftPM, no new
  dependency.
- Swift Testing, TDD red→green, the red quoted verbatim in the commit.
- **Every write is read back from the store**, never assumed from a 200.
- **macSCP sends no bypass header.** The promise, quoted verbatim from
  `ObjectLockSheet`: *"macSCP sends no bypass (`S3BucketSettings.setRetention`
  says so), so within this app a governance retention can be extended and not
  shortened, and the sheet's own refusal sentence says as much."* §4.7 measured
  that the store would accept one. Nothing in this half sends one.
- Every new write path gets its own `AuditEvent.Kind`, as the first half's five
  did: restoring a version, deleting a version, lifting a delete marker,
  changing metadata.
- No display string is hardcoded: `L10n.string` in the App, `CoreL10n.string`
  in Core, catalogues `en`/`de`/`fr`/`pl`, the German ones in du-form.
- No secret, key, credential, token or endpoint in any store, state, log,
  `reason:` string, audit `detail`, notification, test name or test failure
  message.
- Tests never block the cooperative pool: every wait is an `await`. No
  wall-clock ceiling in a test; floors are fine, hang bounds are `.timeLimit`.
- A negative source-scanning check ships with a positive beside it.
- A version id is opaque. Nothing parses one, and §4.9's marker is
  percent-encoded on the way back.
- User documentation ships with the feature, in `noix-docs`, on its own branch.
- Conventional Commits; footer
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

---

## 8. Left to the builder

- Whether the sheet fetches every page before drawing or draws and continues
  (§4.9 says both work).
- The distinguishing suffix for a downloaded old version's local filename
  (§5.1).
- Column widths, sort defaults, and what the filter control's segments are.
  §6.1 fixes that there is one, not what it offers.
- The exact spelling of every catalogue key and its four translations.
- Where the metadata sheet's custom-pair editor draws its add/remove
  affordance.
- Whether the version sheet and the metadata sheet are one sheet with two tabs
  or two sheets. This document assumes two.

---

## 9. Decisions this document makes

Marked because they are the author's, not the maintainer's, and each is cheap
to overturn. Items 1–7 were in the first draft; 8–12 answer a builder review of
it, dated 2026-10-23.

1. **Two capability protocols, neutrally named** (§5), rather than one S3-named
   one. Cost if wrong: a rename.
2. **`RemoteFileItem` gains one optional field** (§5.2), rather than a parallel
   listing type. Cost if wrong: a field no other backend sets, which is the
   cost `isBucket` already pays.
3. **`RemoteFileSystem` untouched** (§5.1). Cost if wrong: the version-aware
   read lives in a second place from the ordinary read.
4. **The four metadata fields** are the backlog row's four (§6.4).
5. **A metadata-only version is marked as such** in the state column, using the
   `ETag` identity §4.5 measured. Cost if wrong: a column nobody reads.
6. **The deleted-files menu command stays visible and disabled** where it
   cannot apply (§6.3), following the first half's treatment of its own rows.
   **This is the weakest call here**: the precedent was set for a menu only S3
   opens, and this item sits in a main menu every connection sees. A maintainer
   who would rather hide it entirely should say so — it is one condition.
7. **Two plans, one document.** Version history and the browser switch first;
   metadata, ACL display and the connection-manager entry second.
8. **A version-aware read on the capability, not a pseudo-path** (§5.1). Cost
   if wrong: the queue and the comparison carry a parameter that only one
   backend ever sets.
9. **Versioning state is cached at listing time** (§5.3) rather than giving the
   file-action seam an availability field. Cost if wrong: a cache to invalidate,
   against a Core seam change that would touch four catalogues and its own
   guard tests.
10. **The lock read is per visible row, bounded and cancellable, with a
    not-yet-known state** (§6.1). Cost if wrong: a sheet that is slower to
    settle than one that reads everything up front.
11. **The deleted-files listing is a merge of two calls** (§6.3), not a
    versions-only listing that rebuilds prefixes and sizes itself.
12. **The connection-manager entry opens a real tab** (§6.6). Cost if wrong: a
    tab the user did not ask for, against a second owner of session state —
    which the architecture invariant forbids outright.

---

## 10. What this half does not answer

- Whether AWS behaves as §4 does. Every row there is one store, one version,
  one day. The first half shipped with the same limit and said so.
- Whether any of these sheets looks right. Nothing on the first half's branch
  was ever seen on screen, and this document does not change that; it is worth
  one deliberate look before either plan closes.
- Sync, the dashboard, cross-bucket move, bucket policies, an ACL write, and a
  multipart copy. §3 says why for each.

---

## 11. Two decisions the maintainer made on this document

Both were the same anti-goal from §3 — "a new version nobody expected" — in two
different places, and both are user-visible, which is why they were not §9's to
settle. Both were answered on 2026-10-23, and in both cases with the
conservative option.

### 11.1 *Open* on an old version is read-only

Measured in the tree, not assumed: the existing **Open** is not a preview. It
is an edit session — `EditSessionManager.beginEditing(remotePath:fileName:source:destinationForUploads:)`,
called from `ContentView+Transfers.openInEditor` with `destinationForUploads:
session.remoteFS` — which downloads into the session's edit temp dir and
**uploads changes back** to the remote path.

Pointed at an old version, that would mean: open it, edit it, save, and the
content has silently become the key's new current version.

**Decided: read-only.** The version sheet's *Open* downloads a copy with no
write-back watcher. The two rejected options were a named write-back ("saving
makes this version current", which is *Restore* with an editing step in the
middle) and dropping *Open* altogether. The reason for read-only: the row
already carries *Restore as Current* as the explicit way to make an old version
current, and an editor that does the same thing as a side effect of ⌘S
duplicates that action without naming it.

This is a deliberate difference from what *Open* does elsewhere in the app, so
the sheet says the copy is read-only rather than leaving it to be discovered.

### 11.2 A metadata edit on a COMPLIANCE-default bucket keeps the ceremony

Both copy-based writes (§4.4 restore, §4.5 metadata) create a new version, and
a new version on a lock-enabled bucket inherits the bucket's **default**
retention — the first half measured that a default "applies to objects written
after it is set". Where that default is COMPLIANCE, correcting a `Content-Type`
mints a version that **nobody can delete until the date**, by design and with
no bypass.

**Decided: reuse the first half's date-naming acknowledgement** before the
write, rather than a plain warning sentence or refusing the edit outright. It
was built for exactly this kind of step, and a warning sentence is too light for
an object that stays undeletable for a year. Refusing was rejected as the
opposite error: the edit is legitimate, it just has a consequence worth naming.

The same reading of the bucket default applies to *Restore as Current*, which
writes a version the same way.
