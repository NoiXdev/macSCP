# File Checksums — Design

**Status:** 2026-08-31. Implements points **1 and 2** from
`docs/superpowers/specs/2026-08-27-backlog-file-hashes.md`. Point 3 (the
table column) is explicitly left out — the entry itself scopes it that way,
and question 3 there is unanswered.

---

## Maintainer decisions

- **2026-08-27:** on request only, **not by downloading**.
- **2026-08-31:** the change builds the **SFTP command path** as well.
- **2026-08-31:** **SHA-256, MD5 and SHA-1**, with a note on the setting.

## The measured starting state

| | |
|---|---|
| Command with a return value in Core | **does not exist** — `CitadelShell` serves the terminal |
| `ProtocolCapabilities` | eight fields, including `supportsPresignedURL` as the model for "this backend can do something" |
| `RemoteFileItem` | carries no hash and no ETag |
| Quoting | `PosixQuoting` lives in Core and is tested |

## The capability is narrow, not general

**Core does not get an `exec(String)`.** It gets "compute the checksum of
this file with this method".

That is the decision this design hangs on. A general execution path would
be a new surface that every future guard would have to watch, and this
project's experience with source-scanning guards is unambiguous. A narrow
capability has **one** interpolated part — the path — and it goes through
`PosixQuoting`, which already exists.

The caller cannot compose a command with this. Not because a test forbids
it, but because there is no parameter for it.

## The remote side is not the same everywhere

`sha256sum` is GNU; on macOS and BSD it's `shasum -a 256`. The same holds
for the other two methods.

**The available form is asked once per connection**, and the answer holds
for that connection. No composed command with `&&` and `||` covering both
cases in one line — that would be exactly the construction this project has
rejected elsewhere across eight review rounds, and it would buy nothing but
one saved round trip.

**If no form is found, the function does not exist on that connection**,
and that is stated.

## The output is read, not believed

An `sha256sum` responds with `<hex>  <path>`. **Only the first field** is
read, and only if it consists of hex digits in the length the method
prescribes.

The returned path is **not** compared and not displayed: it comes from the
remote side, and a value from there is input. Matching it to "which file"
is the caller's job — the caller already knew what it asked for.

This is a pure function and therefore testable without a connection
existing.

## The origin of the value travels with it

| Backend | Source | Does it describe the content? |
|---|---|---|
| SFTP | computed on the remote side | yes |
| Local | computed locally | yes |
| S3 | ETag from the listing | **only for single-part upload** |
| WebDAV | nothing | — |

**The S3 case is the one where a display could lie.** An ETag of the form
`md5-of-the-md5s-N` is not a file hash, and it occurs exactly for large
files. A result therefore **always** carries where it came from and whether
it describes the content — not as a footnote, but as part of the value. A
display that can leave that out will eventually leave it out.

WebDAV delivers nothing. **That is stated, not grayed out:** "this server
does not provide checksums" is an answer; a dead menu entry is not.

## Computing is a transfer

The backlog entry says it: on request, with visible progress and
cancellation — "because that is exactly what it is".

For a selection, files are computed **one after another**, the result
appears as soon as it is ready, and cancelling leaves what was already
computed standing. A checksum over 40 GB takes minutes on the remote side;
a window with no way out would be the same problem this week's teardown
change just fixed.

**And the call gets a deadline.** This week measured twice that an `await`
against a silent remote side does not return; a new wait point without a
ceiling would be the third.

## The methods

**SHA-256 as the default.** MD5 and SHA-1 are offered because the most
common real-world reason is comparing against a value supplied by someone
else — and that is often MD5.

**The setting states that both are broken**, in a way that makes the
distinction clear: they are fit for comparing against a supplied value, not
as proof that two files are identical. They do not stand as equals next to
SHA-256.

## What no test in this project can see

Everything decidable is testable: reading the output, quoting the path,
choosing the command form, the origin carried in the result, that a
multi-part ETag does not count as a file hash, and that a missing command
produces a statement instead of a dead entry.

**Not testable** is what a real server does — measurement is against the
Docker rig and local files.

## What is explicitly excluded

- **No table column** (point 3).
- **No general command path** in Core.
- **No downloading** in order to compute — not even as a fallback when no
  command was found.
- **No `OC-Checksum`** for WebDAV in this change; it is an extension and a
  separate case.
