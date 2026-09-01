# S3: the Bucket as the First Folder — Design Proposal

**Status:** proposal, 2026-09-02, **awaiting the maintainer's decisions**
(marked below). Written while the maintainer was away, from
`docs/superpowers/specs/2026-08-31-backlog-s3-without-bucket.md` and the
maintainer's own suggestion recorded there. Nothing here is implemented.

## The measured starting point

- `S3ConnectionConfig` carries `region` and `bucket` as non-optional
  strings; both are required in `S3FieldSchema.connection`.
- `S3FileSystem.connect` probes with one `ListObjectsV2` against the bucket;
  there is no `ListBuckets` in the tree.
- The cheap half (`docs/superpowers/plans/2026-09-02-s3-without-bucket-cheap-half.md`)
  gives a new form a region default and per-field messages. It does not
  change what a connection IS.

## What the maintainer asked for

> A provider type (AWS, Hetzner, generic, …) for special cases; when
> connecting, check whether the key may list buckets; a flag "list
> buckets" that is tested on connect, otherwise an error.

## Proposal

### 1. A visible toggle, not two empty fields

A checkbox **"Start at the bucket list"** on the S3 form. On: the bucket
field disappears; the connection's root is the account's bucket list. Off:
today's behaviour. **Why not "both fields empty"**: this project has, all
week, chosen the visible form over the inferred one; a state a user cannot
see is a state they cannot correct.

*Decision for the maintainer:* toggle (recommended) or empty-fields inference.

### 2. The permission is checked on connect, and the answer is a message

With the toggle on, `connect` calls `ListBuckets` (`GET /` on the
endpoint, signed like everything else). Three outcomes, each its own
error case with its own catalog string:

| result | meaning | message |
|---|---|---|
| 200 with buckets | works | none — the browser opens on the list |
| 200 with zero buckets | key may list, account has none | "This key can list buckets, but the account has none." |
| 403 `AccessDenied` | key lacks `s3:ListAllMyBuckets` — the usual case for a key scoped to one bucket | "This key may not list buckets. Turn off 'Start at the bucket list' and enter the bucket." |
| anything else | provider does not implement `ListBuckets`, or an endpoint/region problem | today's `connectionFailed` path |

The check happens **once, on connect**, so the failure is where the user
is looking — the form — not deep in the browser.

### 3. Provider presets stay presets; no provider *type* in the config

The form already has presets (AWS, Hetzner, Custom) that fill endpoint and
path-style. **This proposal does not add a provider enum to
`S3ConnectionConfig`.** Every difference between providers measured so far
is a value (endpoint, region, path style, whether `ListBuckets` works) —
none is a code path. A type that switches behaviour would be a second copy
of what the presets already say, and the presets can carry the region
default too (`us-east-1` for Custom; AWS leaves it to the user).

*Decision for the maintainer:* presets only (recommended) or a provider type.
If a provider ever needs a different code path (a non-standard
`ListBuckets` response, a different signing quirk), that is the moment for
a type — and the moment is not now.

### 4. The bucket level is a second kind of directory

This is the part that makes the work real. Buckets in a `ListBuckets`
response carry a name and a creation date — no size, no permissions, no
modification date. The browser today renders `RemoteFileItem`s with all of
those. Proposal:

- `RemoteFileItem` stays. A bucket is an item with `isDirectory = true`,
  `name`, `modifiedAt = creationDate`, `size = nil`, `permissions = nil` —
  the table already tolerates absent values for other backends (check
  WebDAV's items: it also has no permissions).
- The path `/` under a bucket-list connection means "the list";
  `/<bucket>/…` routes to that bucket. `S3FileSystem` gains a
  **root mode** (`.bucket(name)` today, `.bucketList` new) decided at
  connect; every request builder prefixes the bucket from the path in
  list mode. That is the structural change — one place decides, the
  request builders do not branch on strings.
- Actions at the list level: **open** only. Upload, download, rename,
  delete, checksum are offered inside a bucket, not on it. "Only show what
  is possible" — the toolbar's disabling logic already exists for the
  local pane; the same predicate answers "is this a bucket row".

*Not proposed:* creating or deleting buckets from macSCP.

### 5. The rig

The Docker rig gets what the maintainer already decided: a **second MinIO
bucket** and a **restricted access key** (MinIO policy: allowed on one
bucket, no `s3:ListAllMyBuckets`). Then the gated suite can measure all
three rows of the table in §2 against a real server instead of a mock,
and the "key scoped to one bucket" case — the one the entry calls the
usual case — is a test, not a sentence.

## What this design cannot measure

Servinga, the provider in the report, is not in the rig. Whether its
`ListBuckets` answers like MinIO's is unknown and stays so until someone
with a Servinga key runs the gated suite against it. The design does not
assume it.

## Order, if approved

1. Rig: second bucket + restricted key (small, measurable on its own).
2. `S3FileSystem` root mode + `ListBuckets` + the three outcomes, Core only,
   gated tests against the rig.
3. Form toggle + messages.
4. Browser: bucket rows, actions gated.

Each step ships on its own; step 2 is where the design either holds or
does not.
