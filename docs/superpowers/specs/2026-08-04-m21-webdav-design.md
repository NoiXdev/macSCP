# M21 — WebDAV as a third backend

**Status:** 2026-08-04
**Predecessors:** M12 (capability framework), M13 (S3 backend), M16 (cross-backend transfer)

## Purpose

WebDAV as a third backend alongside SSH/SFTP and S3 — and thereby the first
real test of M12's claim that further protocols are "mere additional
implementations". WebDAV suits this better than any other candidate: it is
HTTP-based like S3, but has **real directories** and **atomic rename** —
exactly the two capability axes that read `false` for S3. If the generic
layers carry that without a single `if kind ==` check, the axes are truly
independent.

## Target servers

Four families, in two groups:

**Automatically testable**
- Generic WebDAV per RFC 4918 (Apache `mod_dav`, nginx-dav, Caddy)
- Nextcloud / ownCloud

**Manually testable only** (no container images, tested against real devices)
- Synology, QNAP, and other NAS
- Hetzner Storage Box

The implementation targets the RFC core; Nextcloud gets exactly one
adjustment (path prefix, see the form). NAS and Hetzner need no
implementation-specific concessions, but do need certificate handling.

## Architecture

### Shared HTTP seam

`S3HTTPTransport` is generalized to `HTTPTransport`,
`URLSessionS3Transport` to `URLSessionHTTPTransport`; both move from
`Sources/macSCPCore/S3/` to a neutral location. The surface stays unchanged
(`send`, `sendStreaming`) — it is a rename plus a move. The existing S3
tests hang off this seam and are the safety net.

One extension: the transport accepts a supplied `URLSession` instead of
`.shared`. WebDAV needs a session **with a delegate** — that is the spot
where macOS offers both the authentication challenge and the server trust
check.

**Why not copy:** two nearly identical transports in the tree would become
three at the next protocol. Literal duplication of a logic block counts as
maintenance damage in this project.

**Why not hand-roll Digest:** URLSession answers both Basic *and* Digest
through the same delegate callback, including nonce counting, `qop`, and
`stale` renewal. If this turns out to be unwieldy against the rig, the
documented fallback is a custom Digest computation, checkable against the
vectors from RFC 7616.

### New building blocks (`Sources/macSCPCore/WebDAV/`)

| File | Responsibility |
|---|---|
| `WebDAVConnectionConfig` | base URL, username, auth kind |
| `WebDAVURL` | path arithmetic: relative browser paths → absolute URLs, percent encoding, directory slash, Nextcloud template |
| `WebDAVPropfindParser` | `multistatus` XML → `[RemoteFileItem]` via `XMLParser` |
| `WebDAVSessionDelegate` | auth challenge (Basic/Digest) and server trust |
| `ServerCertificateValidation` | TOFU decision logic, pure and network-free |
| `WebDAVFileSystem` | the `RemoteFileSystem` implementation |

`WebDAVURL` is deliberately its own file: it is home to the silent bugs
(spaces, umlauts, `+`, double slashes, the root), and they are checkable
purely computationally.

The parser is **lenient toward foreign namespaces**, so that Nextcloud's
extra properties don't break anything.

### Trust store

`TrustedCertificateStore` next to the sessions mirrors `KnownHostsStore`
one to one: the same JSON storage, the same four operations
(`find`/`upsert`/`allKeys`/`remove`), keyed on host and port. It thereby
inherits the management pattern from M10a along with the search from M18.

### Touched registration sites

`ConnectionKind`, `ConnectionConfig`, `BackendConnector`,
`BackendDescriptor`, `StoredSessionConnectionConfig`, `ConnectionViewModel`,
`LoginSetsSheet`, `CLISecretSources`. This is the seam M12 laid down;
whether it is complete is what this milestone shows.

## Connection model

### Form

Through the existing `ConnectionFieldSchema` — no new UI mechanism.

| Field | Kind |
|---|---|
| Server URL | Text |
| Username | Text |
| Password | Secret (Keychain, never in JSON) |
| Append Nextcloud path | Toggle |

Templates: **Nextcloud / ownCloud** sets the toggle, **Custom** sets
nothing. The user enters `https://cloud.example.com`, `WebDAVURL` appends
`/remote.php/dav/files/<user>/` — the quirk users otherwise trip over.

For Hetzner and Synology there is **deliberately no template**: there the
URL is user- or device-specific, a template could not meaningfully
prefill anything and would only fake confidence.

### Plaintext HTTP

`http://` remains allowed — on a home network it is a fact of life. But
Basic sends credentials over it in plaintext.

Here the `TransportSecurity` axis gets **its first reader**: today it is
declared and set on both backends, but evaluated nowhere (verified against
the tree, as of 2026-08-04). New rule, at exactly one spot:

- Basic over `http://` → explicit confirmation, entry in the audit log
- Digest over `http://` → no prompt; no secret goes over the wire
- anything over `https://` → no prompt

### Certificate TOFU

`ServerCertificateValidation` decides following the pattern of
`HostKeyValidation`. Three cases, and only three:

1. **System chain trusts it** → through, nothing is stored. Nextcloud and
   Hetzner should never go through TOFU at all.
2. **Unknown** → dialog with SHA-256 fingerprint, issuer, and validity; no
   connection without consent.
3. **Known and deviating** → **hard stop**. No dialog, no way to consent —
   the same invariant as for the host key.

There is **no** "don't check certificate" toggle. That would be the
`accept-anything path` the project rules explicitly forbid for host keys.

Managed in the existing known-hosts sheet as a **second section**, not a
new window: it is the same question ("who do I trust?").

## Protocol mapping

| Operation | WebDAV |
|---|---|
| `list` | PROPFIND, `Depth: 1` |
| `stat` | PROPFIND, `Depth: 0` |
| `readStream` | GET with `Range` |
| `write` | PUT (streaming) |
| `delete` | DELETE |
| `createDirectory` | MKCOL |
| `rename` | MOVE with `Destination`, `Overwrite: F` |
| `deleteTree` | DELETE on the collection |
| `homeDirectoryPath` | `/` — the base URL *is* the root |
| `setPermissions` | not supported, throws |

Two spots differ clearly from S3:

- **`deleteTree` is a single call.** WebDAV deletes a collection
  recursively server-side; S3 needs recursive listing plus DeleteObjects
  batches for that.
- **`rename` is genuinely atomic.** MOVE with `Overwrite: F` returns 412
  when the target is occupied, instead of being composed of copy-and-delete
  like S3 and leaving a half state on failure.

### Capabilities

```
supportsShell:        false
permissionModel:      .none
supportsSymlinks:     false
atomicRename:         true      ← false for S3
directoriesAreReal:   true      ← false for S3
resumeMode:           .rangeGet
supportsPresignedURL: false
transport:            .optionalTLS
```

### Resume only on download

There is no standard for partial PUT; Nextcloud's chunked upload is its own
extension and stays out. An interrupted upload starts over — the queue
already handles that, since M13 hung the resume lock off
`supportsAppendResume`.

On download, `Accept-Ranges: bytes` is evaluated. **If the header is
missing, a full refetch happens** instead of requesting a range the server
silently ignores — otherwise a corrupted file would result.

### Error mapping

Onto the existing `RemoteFSError` cases:

| Status | Case |
|---|---|
| 401 | authentication failed |
| 403 | no permission |
| 404 | not found |
| 405 on MKCOL | already exists |
| 409 | parent folder missing |
| 412 on MOVE | target conflict |
| 507 | out of storage |

## Not in this milestone

LOCK/UNLOCK, PROPPATCH, quota query, Nextcloud's chunked upload and its
trash, OAuth2/Bearer, presigned URLs (WebDAV doesn't have them), WebDAV in
the CLI beyond what the connector dispatcher already brings along.

## Tests

### Without network

- **`WebDAVURL`** — root (the spot where M20 had the `//` bug), spaces,
  umlauts, `+`, `#`, double slashes, directory slash, Nextcloud template
  with usernames.
- **`WebDAVPropfindParser`** — stored responses from Apache **and** from
  real Nextcloud, plus the empty collection and a `multistatus` with 404
  for individual entries. The Nextcloud fixture is the guard against a
  parser that is too narrow.
- **`ServerCertificateValidation`** — the three cases; the deviation case
  as its own test following the pattern of
  `tamperedKnownKeyFailsHardWithMismatch`.
- **Request construction and error mapping** via an injected
  `HTTPTransport` double, the way S3 already does it.

### Gated (`MACSCP_ITEST=1`)

New `webdav` service in the existing compose: an `httpd` with `mod_dav` and
three vhosts — Basic over plaintext, Digest over plaintext, TLS with a
self-signed certificate. **The certificate is generated when the rig
starts, not checked in**, exactly like the SSH test keys.

Checked: full CRUD round trip, rename with an occupied target, recursive
delete, resume via range GET, both auth methods, and the TOFU flow
including the hard stop after a certificate change.

Plus a **WebDAV↔SSH transfer**: `CrossBackendTarget` from M16 was built
protocol-neutral — if it runs without adjustment, that is a second piece of
evidence for the framework.

### Nextcloud

In the same compose behind its **own profile**, which the normal rig run
does not start. Run manually once, it delivers the real PROPFIND response
that the test fixture above is built from.

## Success criteria

1. A WebDAV session can be created, connected, browsed, and transferred in
   both directions — against Apache and against real Nextcloud.
2. No generic code path gets an `if kind == .webdav` check; everything
   protocol-dependent reads the descriptor.
3. A changed server certificate hard-aborts the connection, without
   offering the user a way to consent.
4. Basic over plaintext HTTP requires confirmation and appears in the audit
   log.
5. The four language catalogs stay complete and matched.

## Open points for the plan

- Whether `HTTPTransport` lives under `RemoteFS/` or in its own `HTTP/`
  folder.
- Whether the Nextcloud test fixture is generated from the rig or
  hand-transcribed from a real response.
- The exact form of the confirmation for Basic over plaintext: its own
  dialog, or a line in the existing connection error path.
