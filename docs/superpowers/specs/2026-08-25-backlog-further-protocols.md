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
