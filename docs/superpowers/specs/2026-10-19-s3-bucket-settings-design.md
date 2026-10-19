# S3 bucket settings — design

**Status:** awaiting maintainer approval. Not planned, not started.
**Backlog row:** `docs/BACKLOG.md`, "S3: the tools of s3Manager (maintainer
wishlist)" — line 273 at `3934e2b3`; cited by title because row numbers move.
**Sequencing:** the maintainer split the wishlist in two on 2026-10-19. This
is the FIRST half. The version history is the second and is deliberately out
of scope; see §10.

---

## 1. Intent

macSCP can already browse, upload, download, delete, rename, create folders
and sign URLs on S3. What it cannot do is reach any setting that sits on a
bucket: whether writes keep history, who may call it from a browser, and
whether an object can be deleted at all. The maintainer does that work today
in a separate application (`NoiXdev/s3Manager`), beside macSCP rather than in
it.

The decision of 2026-09-16 was to rebuild those tools inside macSCP rather
than integrate the other app, because s3Manager is TypeScript and none of it
carries over.

### Why this, now

The moment the maintainer described: a file is gone that should not be. With
versioning on, S3 does not remove it — it lays a *delete marker* on top, and
removing that marker brings the file back. Nothing in macSCP can see a marker,
let alone lift one.

That recovery is the second half. This half is what must exist first for it to
mean anything: **a bucket only keeps history if someone turned versioning on.**

**Corrected 2026-10-19 (third pass):** this sentence first ended "and on a
real provider that decision is made when the bucket is created (§4)".
Withdrawn. Versioning is turned on with `PUT ?versioning` at any time — Task
2 of the plan does exactly that to an existing bucket — and Object Lock can
also be enabled on an existing versioned bucket (§4). Neither decision is
confined to creation.

---

## 2. Goals

1. A protocol's own actions reach the window through one seam, not an S3
   special case. S3 fills it; another backend can fill it later without the
   surface changing.
2. Create a bucket, offering versioning and Object Lock at creation —
   **including the first bucket of an account** (§6.1). **Corrected
   2026-10-19 (third pass):** this goal first read "with the two switches that
   can **only be set at creation**". Withdrawn: neither is creation-only
   (§4, §6.1). They are offered there because that is when a person decides
   what a bucket is for, not because the store forbids them later.
3. Turn versioning on and off on an existing bucket, showing honestly that
   "off" is not the same as "never on".
4. Read and write a bucket's CORS rules.
5. Read and write a bucket's default Object Lock retention.
6. Set a retention or a legal hold on a single file, from the file list's
   context menu.
7. **Every refusal the store returns is shown as what it is — on the existing
   operations as much as the new ones** (§7). **Corrected 2026-10-19:** this
   goal first read "A locked object that cannot be deleted says so where the
   user meets it, which today is the ordinary Delete command". Measured, the
   ordinary Delete command does not meet a refusal at all — see §7.

## 3. Non-goals and anti-goals

**Non-goals** (wanted, not here):
- The version history view, its four actions, and delete markers. Second half.
- The metadata editor (`Content-Type`, `Cache-Control`, `x-amz-meta-*`) and
  visibility/ACLs. Both ranked ahead of these tools on 2026-09-16; the
  maintainer's list of 2026-10-19 did not contain them, and neither depends on
  anything built here. Deferred, not dropped.
- Sync (bucket ↔ bucket, local ↔ bucket), which overlaps rsync.
- The context surface in the connection manager named in the backlog row.
  **Author's call, not a maintainer decision:** every action here needs an
  open connection and a stored connection has none, so it goes with the
  second half.

**Anti-goals** — these make the work a failure even if it ships:
- **An empty seam.** A connection-level action list shipped empty in M12, was
  still empty ten milestones later, and M22's final review deleted it rather
  than let it ossify. Rebuilding it is defensible only because there is now a
  real caller, which is the condition that note itself named ("designed
  against a real caller"). **If the FOUR actions on this seam shrink to none,
  the seam goes with them** — pinned by
  `BackendContributionTests.theSeamIsNotEmptyInEveryBackend`.

  **Corrected 2026-10-20, after Task 7 rebuilt the seam.** Two claims here are
  withdrawn.

  First, the pointer. This bullet read "the note sits in the file this design
  adds to (`BackendDescriptor.swift`, the paragraph beginning "There is no
  connection-level action list")". Task 7 rewrote that header, quoting the
  withdrawn paragraph rather than deleting it, so that sentence now survives
  only INSIDE a withdrawal and the header's own paragraph begins elsewhere. A
  reader following the old pointer lands on the quotation of a note, not on a
  note. Cite the symbol instead: the header doc comment of `BackendDescriptor`.

  Second, the count. This bullet read "If the five actions shrink to none, the
  seam goes with them", and §6 is still titled "The five actions" — correctly,
  because it covers §6.1 to §6.5. But **only four of the five are on this
  seam.** §6.5, Object Lock per file, is a `fileActions` contribution reached
  from the context menu (§6.5's own first line), and `fileActions` is a seam
  that was never empty and was never deleted. So the anti-goal's arithmetic was
  one too many for the thing it guards, and the guard test counts four. The
  fifth action disappearing would say nothing about this seam at all.
- A setting that silently did nothing. Every write is read back from the
  store, never assumed from a 200.
- A COMPLIANCE retention set by someone who did not understand it (§6.5).
- **A test that is green against the rig for a flow a real provider refuses.**
  §4 names one measured instance. (**Corrected 2026-10-19:** first read
  "two"; the Object Lock half was withdrawn — see §4.)

---

## 4. What the store actually does — measured, not assumed

Probed 2026-10-19 against the running rig (`macscp-test-s3`,
`rustfs/rustfs:1.0.0`, `http://127.0.0.1:19000`), signed with curl's own
SigV4, in throwaway buckets. The seeded buckets were not touched.

**The control, established first, because without it no refusal below means
anything:** deleting a version in a versioned bucket with no Object Lock
answers `204`, and deleting an unlocked object in a lock-enabled bucket
answers `204`.

| Capability | Result |
|---|---|
| `CreateBucket` with `x-amz-bucket-object-lock-enabled` | `200` |
| `PUT ?versioning` Enabled, `GET ?versioning` | `200`, reads back `Enabled` |
| `GET ?versions` | `200`, returns `Version` and `DeleteMarker` entries |
| `PUT`/`GET ?cors`, full documented rule schema | `200`, round-trips |
| `PUT ?object-lock` bucket default | `200`, applies to objects written after |
| `PUT`/`GET` object `?retention`, `?legal-hold` | `200` |
| `GET ?object-lock` on a bucket without it | **`404`**, not an empty configuration |
| Delete a version under legal hold | `403`, *"Object has a legal hold and cannot be deleted. Remove the legal hold first."* |
| Delete a version under GOVERNANCE retention | `403` |
| …with `x-amz-bypass-governance-retention` | `204` — the bypass is honoured |
| Delete a version under COMPLIANCE retention, even with bypass | `403` |

The CORS round-trip covered every element S3 documents on a rule — `ID`,
several `AllowedOrigin`, several `AllowedMethod`, `AllowedHeader`, several
`ExposeHeader`, `MaxAgeSeconds` — and a rule carrying an element S3 does not
document was refused with `400`. **A form can therefore express every valid
configuration**, which is what §6.3 rests on.

### The divergences from AWS

**Corrected 2026-10-19, during Task 4.** This section first read:

> **The two divergences from AWS, and both are traps**
> 1. **RustFS accepts `PUT ?object-lock` on a bucket created WITHOUT Object
>    Lock** — `200`, and the lock then genuinely bites (`403` on a delete).
>    **AWS refuses this**; there, Object Lock exists only if the bucket was
>    created with it.

**Item 1 is withdrawn: it is not a divergence.** AWS's current configuration
guide says Object Lock can be enabled on an EXISTING bucket, through the
console, CLI, SDKs or the REST API, provided versioning is on; and once
enabled it cannot be disabled and versioning cannot be suspended. Two older
AWS pages (the Security Hub remediation page and the AWS Config
prerequisites page) still say it can only be enabled at creation, which is
very likely where the withdrawn sentence came from — it was written from
recollection with no source beside it, which is the failure this file has a
rule about.
https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock-configure.html

The RustFS behaviour itself was measured correctly and is unchanged: a
`PUT ?object-lock` on a bucket created without it answers `200` and the lock
then genuinely bites. What was wrong was the claim about AWS beside it.

**The one measured divergence that stands:**

1. **RustFS stores a CORS rule whose method is `FETCH`** — `200`, and reads it
   back unchanged. AWS allows only GET, PUT, POST, DELETE, HEAD. (It does
   refuse a rule with no `AllowedOrigin`, `400`, and refuses an empty
   configuration with `400 MalformedXML` — so it checks the structure and not
   the vocabulary.)

**And one place where the rig AGREES with AWS**, recorded because three
readings of "the rig is more permissive" invite the wrong generalisation: a
zero-rule `<CORSConfiguration>` is refused `400 MalformedXML` by the rig, as
by AWS, and the previously stored rules survive untouched.

That divergence has one consequence, and it is the sharpest constraint in
this document (**corrected 2026-10-19:** this sentence first read "Both have
the same consequence", when there were two):

> **The rig is more permissive than the world.** CORS input must be validated
> by macSCP, because **the rig will not supply the refusal to pin against** —
> the test must pin macSCP's own refusal.

**No code here offers to enable Object Lock on an existing bucket**, but the
reason is not the withdrawn one above. It is scope and irreversibility: the
maintainer asked for the two switches at bucket creation, enabling the lock
later is a retrofit nobody requested, and it cannot be undone once done. A
backlog row records that AWS now permits it, so the maintainer can ask for it
deliberately rather than inheriting it by accident.

This section first read, and this clause is withdrawn with item 1 above:
"Divergence 1 is why “create bucket” is in scope at all — which was the
maintainer's own ordering on 2026-09-16 (“create bucket … first”), and the
measurement is why that ordering was right." The maintainer's ordering is
unchanged and still recorded; what is withdrawn is the claim that this
measurement justified it.

**Left behind by the probe:** the bucket `macscp-probe-lock` is still on the
rig and cannot be removed — it holds one object under a COMPLIANCE retention
until 2026-12-31, which by design nobody can delete. Either it stands until
then, or the rig's volume is reset and reseeded (`up -d` reseeds
idempotently). **A gated test that asserts anything about the bucket LIST will
see it**, so that decision is a precondition for those fixtures, not a tidying
job. The maintainer's call.

**Not measured:** every figure is RustFS 1.0.0. Hetzner and AWS were not
probed, and neither was any provider lacking Object Lock entirely. §8 says
what the code must do about that.

---

## 5. The seam

`BackendDescriptor` (`Sources/macSCPCore/Capabilities/BackendDescriptor.swift`)
is the existing per-`ConnectionKind` description: capabilities, form schema,
connect closure, and `fileActions` — the contributions a backend makes to the
file list's context menu. Two things attach here.

**Per-file locks use `fileActions`, which already exists.** Setting a
retention or a legal hold acts on a selected file, so the two new entries are
`FileActionContribution`s on `s3Descriptor.fileActions`, beside the existing
`s3.presignedURL`. No new mechanism; the window already dispatches a
contribution by its **id** rather than by `ConnectionKind`
(`ContentView+MenuActions.swift`).

**The toolbar menu needs the connection-level list that M22 removed.** The
maintainer asked for it on 2026-10-12 and confirmed its placement on
2026-10-19: its own capsule in the toolbar's free area, left of the existing
icon group, styled like that group. At SFTP the capsule is absent; a later
backend fills it from its own descriptor.

The builder decides the contribution type's shape. The design fixes that it is
**one list on the descriptor**, that the window reads it without switching on
`ConnectionKind`, and that an empty list renders **nothing at all** — not an
empty menu.

Optional capabilities are queried with `as?` here (`PresignedURLProvider`,
`RemoteShellProvider`). The bucket-settings calls belong on a new optional
protocol in `Sources/macSCPCore/RemoteFS/`, which `S3FileSystem` conforms to
and nothing else does.

**Author's call — the protocol is version-aware from the start.** Retention
and legal hold are properties of an object *version*, and the second half
needs per-version reads to show a locked version as locked before the user
clicks. The signatures therefore carry `versionId: String?` now, with `nil`
meaning the current version, which is the only value this half can supply.
Adding the parameter later would mean an API change and a second round of
tests.

---

## 6. The five actions

### 6.1 Create bucket

Name, plus **versioning on** and **Object Lock on**.

**Corrected 2026-10-19 (third pass), and this one would have become user-facing
copy.** The paragraph first read: "Name, and two switches that exist only
here: **versioning on** and **Object Lock on**. The dialog says that both are
final at creation — Object Lock cannot be added later (§4), and versioning,
once on, can only be suspended." Everything before the last clause is
withdrawn. Neither switch exists only here and neither is final at creation.

What the dialog must actually say, which is still worth saying because both
are one-way doors once taken:

- **Versioning** can be turned on later, and once on it can only be
  **suspended**, never returned to never-versioned (§6.2). Every version
  already stored stays and keeps costing storage.
- **Object Lock** can be turned on later too, on a versioned bucket — but
  **macSCP will not do it** (§4), and once on it can never be turned off and
  versioning can never be suspended again.

So the honest sentence is not "you must decide now" but "if you decide yes,
you cannot undo it".

**Maintainer decision 2026-10-19: the connect refusal is relaxed so the first
bucket can be created.** As the tree stands this is impossible:
`S3FileSystem.connect` throws `RemoteFSError.bucketListEmpty` when
`listBuckets()` is empty, and the comment above it gives the reason — *"an
empty browser explains nothing"*. That reasoning was right when there was
nothing to do in an empty browser; this work gives it something to do.

Relaxing it is its own task and a riskier one than any of the five: it touches
a deliberate refusal, its form messaging and its tests, and the empty state it
creates must offer the one action that resolves it rather than being blank.
In single-bucket mode (`RootMode.bucket`) there is no bucket-list surface, so
a bucket created there would be invisible — **the action is therefore offered
in bucket-list mode only**, which is the author's call on the half the
maintainer's answer did not cover.

### 6.2 Versioning

Three states, not two: **never enabled**, **enabled**, **suspended**. The
switch must not present suspension as "off": suspending stops new versions
being kept, every version already stored stays, and it keeps costing storage.
A bucket that was never versioned and a suspended bucket look identical in a
two-state switch and are not the same thing.

### 6.3 CORS

A form by default with a toggle to the rules as text — the maintainer chose
this (option C) on 2026-10-19 over a form alone or text alone.

**Author's call — the text pane is editable, and macSCP validates it.** The
measurement in §4 changed what this edge costs. The earlier draft of this
document called the form/text split "the part that needs building rather than
describing", on the assumption that configurations routinely outgrow a form;
measured, the form can express every valid rule, and the store refuses
anything outside the documented schema. So the form is not a lossy view, and
the honest-edge machinery shrinks to one rule: if a configuration ever arrives
that the form cannot represent, the form disables itself and names what it
cannot show, rather than round-tripping and dropping it.

Validation is macSCP's own work, not the store's: the rig stores `FETCH` as a
method (§4). The allowed set is GET, PUT, POST, DELETE, HEAD, and a rule needs
at least one origin and one method.

### 6.4 Object Lock, bucket default

Mode and duration, written to the bucket, applying to objects written
afterwards. Absent configuration is its own state (`404`, §4), not an empty
one.

### 6.5 Object Lock, per file

Retention and legal hold, from the context menu, on the selected file.

**COMPLIANCE carries a warning, and the warning is a requirement.** The
maintainer asked for COMPLIANCE to be available (2026-10-19) *with a clear
warning*. What makes it unlike anything else in macSCP: a COMPLIANCE retention
cannot be shortened, bypassed or lifted by anyone — not the account owner, not
an administrator — until the date passes. Measured: `403` even with the bypass
header.

**Maintainer decision 2026-10-19: a checkbox carrying the date.** The user
must tick an acknowledgement that names the exact date beyond which nobody can
undo this, before the action can be run. Nothing in the tree does this today —
the nearest sheet, `FileActionConfirmSheet`, is an ordinary Cancel/Run pair —
so it is built here. GOVERNANCE and legal hold are both reversible and get no
equivalent ceremony.

---

## 7. The refusal path (Goal 7)

**Maintainer decision 2026-10-19: in scope.**

`S3FileSystem.mapErrorStatus(_:path:)` turns **every** 403 into
`RemoteFSError.authenticationFailed` and discards the response body; no S3
error-code parser exists in the error path. Verified by reading it. Where a
refusal does arrive, it is therefore unreadable.

**Corrected 2026-10-19, measured during Task 4.** This paragraph first ended:
"So today, deleting an object under a legal hold tells the user
“authentication failed” — in the ordinary Delete command, which is exactly
where they meet it." **That is wrong, and the error is instructive.** Object
Lock protects a VERSION, not the name. Measured on a lock-enabled versioned
bucket with a legal hold in place:

```
PLAIN DELETE (no versionId) of the held object:   204   (a delete marker goes on top)
GET it afterwards:                                404
the locked version:                               still listed
VERSIONED DELETE of the held version:             403   "Object has a legal hold and cannot be deleted."
```

So the ordinary Delete command **succeeds** on a locked object and the data
survives underneath. The refusal is reachable only through a versioned delete,
which nothing in macSCP issues today — it arrives with the version history,
the second half of this work. The error mapping Task 1 built is still right
and still needed; what was wrong was the claim about where a user meets it.

**This belongs in the user documentation rather than being quietly correct:**
on a versioned bucket, deleting a locked file appears to work, and that is S3
behaving as designed, not macSCP hiding a refusal.

Making that honest means parsing the store's `<Code>` into named
`RemoteFSFinding` cases inside that shared mapper, which `delete`, `write`,
`rename`, `deleteTree`, `createDirectory` and the listing path all route
through. The blast radius is real and must be planned for: `.authenticationFailed`
is branched on in the transfer queue, in the browser's mid-browse handling and
in the connection form's credential highlighting, and it feeds the
"is this a connection failure" decisions that drive resumability.

Constraints that already bind this and are not negotiable: a finding carries
no foreign text (`RemoteFSFinding`, enforced by
`RemoteFSFindingTests.noFindingCarriesForeignText`), so each named code is a
finding case plus one fixed sentence per language, pinned by
`LocalizationParityTests.everyRemoteFSFindingHasItsOwnSentence`. **Which codes
get a name is a cost decision, not a completeness exercise** — the plan names
them explicitly rather than mapping the whole S3 error vocabulary.

---

## 8. Constraints

- Project rules unchanged: Swift 6 strict, macOS 15 floor, Swift Testing, TDD
  red→green, no hardcoded display strings (`L10n.string` in the App,
  `CoreL10n.string` in Core; catalogues `en`/`de`/`fr`/`pl`, German in
  du-form), no secret in any store, state, log, `reason:` string or test
  failure message, English in every written artifact.
- **A provider that does not implement these calls is the normal case, not an
  error case.** Object Lock in particular is absent on many S3-compatible
  stores.
  **Author's call on how availability is established:** Object Lock state is
  read per bucket, lazily, when the surface that needs it opens, and cached
  for the session — it is the one call with a hard "not configured" answer
  (`404`). Versioning and CORS are offered unconditionally and explain a
  refusal when it comes. Probing all three on connect is the wrong
  granularity: in bucket-list mode every bucket differs.
- **Author's call — these actions are recorded in the audit trail.**
  `AuditEvent.Kind` already carries `rename`, `delete`, `permissions`,
  `newFolder`, `newFile`; a COMPLIANCE retention would otherwise be the most
  irreversible thing macSCP can do and the only one leaving no trace. The cost
  is named rather than hidden: each new kind owes a recorder method, four
  catalogue entries and the guard that pins them
  (`everyKindHasACatalogLabel` over `Kind.allCases`).
- The gated S3 suites run under `MACSCP_ITEST=1` against the rig, which must
  be started from the main checkout.
- The rig's RustFS pin carries its own backlog row ("The S3 rig's RustFS pin
  is a debt with a review date").
- User documentation ships with the feature, in `noix-docs` under
  `src/content/docs/macscp/`, with no tech-stack terms.

---

## 9. Left to the builder

- The contribution type for connection-level actions, and how the window
  renders the capsule so it matches the existing icon group.
- Whether the five actions are five dialogs or fewer, and how a dialog reaches
  the bucket it acts on when the browser is inside a prefix rather than at the
  bucket list.
- The CORS form's own model, and how it detects a configuration it cannot
  represent (§6.3).
- Which S3 error codes get a named finding (§7), and the sentence for each.
- Where the new optional protocol's methods sit relative to `S3FileSystem`'s
  existing XML handling (`S3XMLText`, `S3ListParser`, `S3MultipartXML`).
- Catalogue keys and their four translations.
- Which cases a fake can cover and which need the gated rig — bearing §4's
  warning: the rig cannot supply the two refusals that matter most.

---

## 10. The second half

Not this document. Recorded so the split is legible: the version history of a
single file, with four actions on an old version — view, download, restore
(including lifting a delete marker), and permanently delete one version. It
must show a locked version as locked *before* the user clicks, which is the
dependency that put this half first. The connection-manager surface of the
backlog row goes with it (§3).
