# Backlog: FTP and SMB/AFP as further protocols

**Created:** 2026-08-25, from a maintainer note. A solid idea, **not a
design** — and an entry where the cost diverges more than the wish
suggests.

## Starting point, measured

`ConnectionKind` today has **three** cases: `ssh`, `s3`, `webdav`. Each
comes with a `BackendDescriptor` instance carrying **13 required
fields** — capabilities, connection and credential schema, `makeConfig`,
`connect`, badge, secret environment variable, file actions, and more.

**That's the extension point, and it's well built:** a comment on the
connection path notes that exactly this shape "resolved the last
`ConnectionKind` switch on the connection path". So a fourth backend
means: write a descriptor, not touch twenty places. `ConnectionKind` does
appear in 22 files, but mostly as a value, not as a branch — before
starting, it needs counting how many of those are **real case
distinctions**.

## The two halves are very different

### FTP

A separate protocol that macSCP would have to speak itself. To clarify
before anything gets designed:

- **With what?** Apple's URL loading system has dropped its FTP support;
  so this would need a library or a from-scratch implementation over
  NIO. That's the decision everything else hangs on.
- **Which variant?** Bare FTP transmits credentials in plaintext. For a
  program that just closed three secret leaks, that's not a side issue:
  FTPS and SFTP-over-SSH (the latter macSCP can already do) are the safe
  relatives. Whether bare FTP should be offered at all — and if so, with
  what warning — needs to be decided, not implemented on the side.
- Active or passive, resumption, directory listings in their many
  server dialects: FTP is old and inconsistent.

### SMB and AFP

**Fundamentally different territory:** macOS already speaks both itself.
Realistically this isn't about implementing a protocol, it's about
addressing an **integration** — mounting and then working through the
filesystem.

That shifts everything:

- The `connect` part would be a mount, not a connection setup.
- The secret path might run through the system login instead of macSCP's
  own `SecretStore` — which raises the question of who then owns what.
- **TOFU and host-key checking have no equivalent here.** This project's
  security guarantees are tailored to SSH; for an integration, the
  operating system's guarantees apply. That's not a blocker, but it needs
  to be named before anyone assumes the usual guarantees still hold.
- AFP has been deprecated by Apple. Whether it's still worth it is a
  separate question.

## Recommendation on ordering

**Don't tackle the two halves together.** They only share the word
"protocol" — technically, security-wise, and in effort they have almost
nothing in common. Whoever packs them into one plan is designing for the
average of two very different things.

If one goes first: **SMB**, because the integration already exists and
the descriptor already prescribes most of it. FTP first needs the
decision on library and variant, and that isn't an implementation
question.

## Decided 2026-09-02 — revised the same evening: both, and standalone

The first answer of the evening ("no fourth backend now") was withdrawn
by the maintainer within the hour, with two harder requirements:

1. **FTP AND FTPS must both work.** Not FTPS only. Plain FTP carries
   credentials in cleartext, so it goes through the existing
   `PlaintextTransportGate` (`TransportSecurity.plaintext`, the same
   confirmation WebDAV over `http://` gets) — a warning the user
   confirms, not a refusal. FTPS in both forms the servers out there
   use: explicit (`AUTH TLS` on port 21) and implicit (TLS from the
   first byte on 990). TLS trust runs through the existing
   `TrustedCertificateStore`/decider the WebDAV backend already uses, so
   the guarantee shape is WebDAV's, not SSH's.
2. **SMB must run natively, standalone** — no mount, no share added in
   macOS, no Finder involvement. An SMB2/3 client inside macSCP, talking
   to the server itself, so `connect` is a connection and the secret
   stays in `SecretStore`. That retires the "integration" reading above:
   the mount path is out, and with it the question of who owns the
   secret. AFP is not asked for and stays out (deprecated by Apple).

What this costs is not decided by wish. Before a design, one measurement
task answers, per protocol: (a) is there a library worth depending on —
for SMB the userspace candidates are `libsmb2` (C, userspace SMB2/3
client, no kernel mount) with the Swift wrapper `AMSMB2`; for FTP the
Swift ecosystem has next to nothing maintained over NIO, so the likely
answer is an own implementation of the control channel over NIO with
NIOSSL for FTPS and a small set of listing dialects (`MLSD` first, `LIST`
Unix-style as the fallback) — (b) licence, Swift 6 strict-concurrency
compatibility, SwiftPM support, maintenance state, and whether the thing
builds in this toolchain today, measured in a scratch package, not
assumed; (c) how each maps onto `BackendDescriptor`'s 13 required
fields and `ProtocolCapabilities` (SMB: real directories, rename atomic,
permissions = ACL-ish; FTP: `directoriesAreReal` true, `atomicRename`
via `RNFR/RNTO`, resume via `REST`, no checksum unless `XSHA256`/`HASH`
is measured on a server).

Order: measurement → brainstorming → one design per protocol → plans.
FTP/FTPS first (own code, nothing to license), SMB second (a C
dependency is a supply-chain decision the fork rule in CLAUDE.md
applies to as well).

