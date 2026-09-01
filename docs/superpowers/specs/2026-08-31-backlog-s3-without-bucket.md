# Backlog: connecting S3 without a bucket

**Created:** 2026-08-31, from an external bug report (v1.3.0), with a
suggestion from the maintainer.

## The report

> „I tried to connect without providing bucket and region and it doesn't
> allows me. When I fill using slash then the connection has been failed."

The provider was Servinga (S3-compatible).

## The measured starting state

- `S3ConnectionConfig` carries `region` and `bucket` as non-optional
  `String`, and the field schema marks both as required.
- **There is no `ListBuckets` in the tree** — checked, no occurrence. S3
  today lists only *inside* a bucket.
- A bucket named `/` is not a bucket; that connecting with it fails is
  correct and is not the bug.

## The maintainer's suggestion

> If both are empty, macSCP should load the buckets and show them as the
> starting point in the file browser — or a toggle "fetch buckets as
> starting point" that then removes the two fields.

That's the right direction: for the user, the bucket is not a connection
parameter, it's the first directory.

## What needs clarifying before a design

1. **The region can't simply stay empty.** SigV4 **signs with it** — it
   goes into the credential scope. So "empty" doesn't mean "omit", it
   means "pick a default value" (`us-east-1` is the common one that many
   S3-compatible providers accept because they don't check the region).
   That's an assumption about third-party servers and belongs named, not
   hidden.
2. **Not every provider can do `ListBuckets`.** It's an account-wide call
   and requires its own permission (`s3:ListAllMyBuckets`). An access key
   scoped to one bucket — the usual case with shared access — isn't
   allowed to. **Then the field has to come back**, with a message that
   says why, instead of an empty list.
3. **Two empty fields as a toggle, or a real toggle?** The suggestion
   names both. A state inferred from *two* empty fields is harder to
   explain than a checkbox that hides the fields — and this project has,
   this week, repeatedly preferred the visible form over the inferred one.
4. **What does the browser show at the bucket level?** Buckets aren't
   folders: they have no modification date in the listing, no size, no
   permissions. The table would have to handle that, and `RemoteFileItem`
   today carries fields that would all be empty there.
5. **What do transfers and checksums do at this level?** A bucket can't be
   downloaded. "Only show what's possible" here means that half the
   toolbar has nothing to do at this level.

## Why this isn't a small change

Points 4 and 5 make this more than one fewer field: it's a **second kind
of directory** in the file browser, with different columns and different
possible actions. That's doable and sensible — but it needs to be
designed, not built on the side.

**The cheap part of it, if someone just wants to close the report:** a
default for the region and an error message that says the bucket is
needed and why. That fixes "it won't let me", without the second
directory kind.

## What this is not

- **No change to the signature.** The region stays part of the scope.
- **No guessing the region** from the endpoint.

## Done 2026-09-02 — the cheap half

Shipped, in three commits (`62d2678`, `a9693b5`, `d2b908f`):

- **The default.** A brand-new S3 connection form now starts with
  `region = "us-east-1"` (`S3FieldSchema.defaults`), visible and editable
  rather than hidden. The assumption is named in the comment right above
  it: `us-east-1` is the region most S3-compatible providers accept
  because they don't check it; AWS itself does check, so the AWS preset's
  user still has to enter their own.
- **The two messages.** The bucket and region blank-field cases split out
  of the shared `core.connect.s3FieldRequired` into their own keys,
  `core.connect.s3BucketRequired` and `core.connect.s3RegionRequired`,
  each saying *why* the field is required (bucket: macSCP opens one
  bucket per connection, that's the first folder, listing every bucket of
  an account isn't supported yet; region: it's part of the request
  signature, so it can't be left empty, and most S3-compatible providers
  accept `us-east-1`) — in all four catalogs, `en`/`de`/`fr`/`pl`.
- **What was measured:** the rig's MinIO accepts `us-east-1` (gated
  suite, `MACSCP_ITEST=1`).
- **What was not measured:** Servinga, the provider named in the original
  report. The default's comment and this entry both keep that unmeasured,
  not claimed.
- **No change to saved sessions**, by design and by two review rounds
  that found and closed leaks of the new default into existing data:
  - `a9693b5` closed a leak into `beginEditing` — a saved session with a
    `nil` S3 block (corrupt/inconsistent stored data) picked up
    `"us-east-1"` as if it were the session's own value, and Save would
    have written it into the stored config. Fixed with
    `BackendDescriptor.editBaseline`, a second pre-merge baseline that
    excludes the region; a corrupt session now shows an empty region on
    edit and Save fails with the `s3RegionRequired` message instead of
    silently completing.
  - `d2b908f` closed the same leak on the App's `fillForm` connect path
    (`Sources/MacSCPAppKit/ContentView.swift`, used by sidebar reconnect
    and "Open in External Terminal") — a corrupt saved session used to
    correctly fail validation on reconnect and had regressed into
    silently dialing with the guessed region; now uses `editBaseline` and
    fails validation again, as before.

**Not done — everything else in this file stays open**, and is the
proposal in `docs/superpowers/specs/2026-09-02-s3-bucket-browser-design.md`,
awaiting the maintainer: no `ListBuckets`, no provider type, no
bucket-level browser, no change to how an existing session with an empty
region behaves (it stays as it is and gets the new message on connect).
