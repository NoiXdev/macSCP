# FTP backend — design

**Date:** 2026-11-05
**Status:** **approved by the maintainer, 2026-11-05**, after one builder-check
round and the four answers recorded in §14. Committed the same day, which is the
point of the sentence this one replaces: the 2026-10-23 documents were written
in a session scratchpad, the scratchpad was cleared, and they had to be
recovered from a transcript.
**Brainstormed with:** the maintainer, 2026-11-05, in German; this document is
the English record of that conversation.

---

## 0. The prior record, and where this document diverged from it

**This section exists because the first draft did not have it.** Two documents
in this repository already carry decisions and measurements about this work, and
the first draft cited neither — it was written from a conversation and from the
code, without searching `docs/` for prior art. A fresh reviewer found them.

- `docs/superpowers/specs/2026-08-25-backlog-further-protocols.md`, section
  *"Decided 2026-09-02 — revised the same evening: both, and standalone"*,
  requirement 1.
- `docs/superpowers/specs/2026-09-02-protocols-library-measurement.md`, which
  measured the available FTP libraries and rig images.

Three divergences, each one handled explicitly below rather than silently:

1. **Implicit FTPS.** The 2026-09-02 requirement reads, verbatim: *"FTPS in both
   forms the servers out there use: explicit (`AUTH TLS` on port 21) and
   implicit (TLS from the first byte on 990)."* The first draft of §7 said
   *"Implicit FTPS on port 990 is **not** in this release"* and filed it under
   the author's own decisions. **That sentence is withdrawn.** Dropping a
   maintainer requirement is not a builder's call, and the maintainer restated
   the requirement on 2026-11-05: **both forms ship in the first release.** §7
   carries what that costs, and §7a the measurement showing it costs far less
   than the 2026-09-02 record feared.
2. **The `transport` axis for plain FTP.** The same requirement says plain FTP
   *"goes through the existing `PlaintextTransportGate`
   (`TransportSecurity.plaintext`, …)"*. The **decision** is kept in full; the
   **mechanism named in it is wrong**, and this document corrects it:
   `PlaintextTransportGate.requiresConfirmation` returns `false` immediately
   unless `transport == .optionalTLS`, so `.plaintext` would switch the gate off
   for the one backend it was written for. Decision 5's `.optionalTLS` is how
   that requirement is actually implemented, not a departure from it. The
   2026-09-02 record should be corrected in place, quoting its own wording, when
   this document is committed.
3. **The rig.** The 2026-09-02 measurement already recorded that an
   implicit-FTPS rig *"may need a custom image"* and that the candidate images
   are each missing something. §9's assertion of a service that both advertises
   `MLSD` and supports `AUTH TLS` was made without reconciling that. See §9.

---

## 1. Intent

macSCP speaks SSH/SFTP, S3 and WebDAV. The gap the maintainer named is not a
protocol he wants but one he keeps meeting: *"ssh ist geil aber nicht alle geben
dir das"* — shared hosting and inherited customer webspace where nobody will
enable SSH, and FTP is what is left. FTP is an emergency exit for servers one
did not set up.

That origin sets the bar rather than lowering it. The maintainer's words:
*"ftp sollte an Feature nicht hinterherlaufen sofern es geht also
synchronisieren, eine Datei direkt in Ort und Stelle editieren, vergleichen
etc"*. So FTP is a full backend — full `RemoteFileSystem` conformance — and
comparing and in-place editing arrive with it, because those features are
written against that protocol and not against SSH — comparison is
`Sources/macSCPCore/Compare/`, in-place editing is
`Presentation/EditSessionManager.swift`, and neither carries a per-kind branch.

**Synchronising does not arrive with it, because it does not exist.** The first
draft wrote that *"comparing, synchronising and in-place editing arrive with
it"*; that is withdrawn as to synchronising. Searched 2026-11-05 for a sync or
mirror feature in `Sources`
(`/usr/bin/grep -rnoiE '[a-z]*synchron[a-z]*|[a-z]*mirror[a-z]*' --include='*.swift' Sources`,
reduced to unique identifiers): the hits are the stdlib `Synchronization`
module, `customMirror`, `desynchronize`, `flushSynchronously` and
`ConnectAttemptLivenessMirror` — no synchronisation feature, no mirror type. Two
of the three features the maintainer named are in the tree and one is not, and
whether it belongs to this work is question 2 of §14.

**FTP is already in the tree, as the example of a protocol this project does not
support.** Measured 2026-11-05 from the repository root:

```
/usr/bin/grep -rnoiE '(^|[^a-z])ftps?([^a-z]|$)' --include='*.swift' Sources Tests | /usr/bin/grep -viE 'sftp' | wc -l
```

prints **26**, over 8 files. Three are in `Sources`, all of them comments —
including `ConnectionKind.swift:3`, *"Open for future protocols
(webdav/ftp/smb)"*. The other 23 are in `Tests`, where `"ftp"` is the fixture
value for `.unsupported(…)` throughout the Cyberduck/Transmit import path. A
A
pattern without the word boundaries matches `leftPath`, `SwiftPM` and
`draftProblem`. The first draft said it *"prints 353"* and gave no command
beside the figure — which is the first failure mode of `CLAUDE.md`'s "a number
travels with the command that produced it", committed inside the sentence that
exists to stop the next reader reproducing it. **Withdrawn and replaced with
both figures and their commands**:

```
/usr/bin/grep -rnoiE 'ftps?' --include='*.swift' Sources | /usr/bin/grep -viE 'sftp' | wc -l
/usr/bin/grep -rnoiE 'ftps?' --include='*.swift' Sources Tests | /usr/bin/grep -viE 'sftp' | wc -l
```

print **353** and **708**. 353 is `Sources` alone; over the same scope as the 26
above it is 708.

Two consequences, and the second is scope rather than a side effect:

- Those 23 test occurrences need a different example protocol once FTP is
  supported (`smb` is the obvious candidate; `ConnectionKind`'s own comment
  already names it).
- An imported Cyberduck or Transmit bookmark that speaks FTP stops being
  *"Greyed and counted, never imported"* (`ImportPreviewPlanner.swift:78`) and
  becomes importable. That is a user-visible change to a shipped feature.

---

## 2. Goals, non-goals, anti-goals

**Goals**

- A fourth `ConnectionKind` with full `RemoteFileSystem` conformance: all 18
  requirements (`/usr/bin/grep -cE '^\s+(func|var|subscript)'
  Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift` prints **18**, in 227
  lines).
- FTPS explicit (`AUTH TLS`) as the normal case; plain FTP possible but gated.
- Browsing, transfer, queue, comparison, synchronisation, in-place editing —
  through the existing generic layers, with no `if kind == .ftp` branch in any
  of them.
- Credentials in the Keychain via `SecretStore`, like every other backend.
- Presence in **every surface a connection has**, not only in the browser:
  login management, stored sessions, session export and import, external
  import, the CLI and the connection diagnostics. §11a names them, measured.

**Non-goals for the first release** (each a decision, not an omission)

- **ASCII mode (`TYPE A`).** Maintainer, 2026-11-05: *"dann erstmal type 1
  ascii ggf später ann"* — binary only now, ASCII possibly later. See §6 for why
  this one is load-bearing.
- **Active mode (`PORT`/`EPRT`).** Passive only. Active needs an inbound port on
  the client and fails behind every NAT; the population this backend targets is
  reachable passively.
- **FXP** (server-to-server transfer), **FTP over the app's own SOCKS tunnels**,
  and `SITE` commands beyond `CHMOD`.
- **Synchronisation.** It does not exist in this tree at all (§1), so FTP cannot
  inherit it. Maintainer's decision of 2026-11-05: its own piece of work later,
  brainstormed and planned separately, where it will serve all four backends
  rather than only this one. FTP is not blocked on it.
- **No real-server corpus.** The maintainer has no such server to test against
  (*"keine echten server habenich gene im rig machen"*), so everything is
  verified in the Docker rig. §9 says what that costs.

**Anti-goals**

The maintainer had no answer to *what would make this a failure even though it
works* (*"kiene ahnung"*), and nothing is invented here in its place. The one
anti-goal the protocol itself forces is in §6: a transfer that silently corrupts
a file is worse than a transfer that refuses.

---

## 3. Inherited constraints

From `CLAUDE.md`, unchanged and not restated in full: Swift 6 language mode,
macOS 15 floor, Swift Testing with red-before-green, no `--build-system` flag,
English-only code and comments, four localisation catalogues (`en`, `de`, `fr`,
`pl`, German in du-form), no hardcoded display strings, no secrets in any store,
log, `reason:` string or test name, and no blocking wait anywhere in a test.

---

## 4. Decisions, and whose they are

### The maintainer's

1. **FTP is a full backend**, not a reduced one (§1).
2. **A connection pool per tab: four connections — one reserved for commands and
   navigation, three for transfers.** The size is a setting, default 3, in its
   own Settings tab. Maintainer's words: *"kleiner Pool pro Tab ggf die größe
   als eigener settings pinkt als neuer reiteun unter protokolle default 3 + 1
   für steuerungen"*. See §5.
3. **`TYPE I` now, ASCII deferred** (§6).
4. **Everything is verified in the rig**; no real-server access (§9).

### Mine, stated so they can be rejected

5. **FTPS explicit (`AUTH TLS`) is the normal case, and plain FTP goes behind
   `PlaintextTransportGate`.** The gate exists and reads
   `ProtocolCapabilities.transport == .optionalTLS`; its own comment says *"so a
   fourth backend is covered by construction"*, and that holds in the strong
   sense — its `isPlaintext(_:)` switches exhaustively over `ConnectionConfig`,
   so a fourth case will not compile without an arm. No accept-anything path, no
   silent plaintext login.
6. **TLS through `apple/swift-nio-ssl`, as a new dependency.** §7 carries the
   reasoning and the rejected alternative.
7. **`MLSD` when `FEAT` advertises it, `LIST` with a dialect parser otherwise**
   (§8).
8. **Filename encoding: `OPTS UTF8 ON` where `FEAT` advertises `UTF8`;
   otherwise decode as UTF-8 and fall back per name**, so one undecodable name
   does not poison a listing.
9. **Settings get a `SettingsSection.ftp` case**, beside the existing `.ssh` and
   `.s3`. The first draft justified this as *"the house convention is already
   one tab per protocol"*; **that justification is withdrawn — it is false.**
   `SettingsView.swift:139` opens a `Section` titled "Protocols" containing
   exactly `[SettingsSection.ssh, .s3]`, and
   `/usr/bin/grep -ciE 'webdav' Sources/MacSCPAppKit/SettingsView.swift` prints
   **0**: WebDAV, the most recent backend, has no settings tab at all. So the
   convention is "a tab where the protocol has settings worth one", and two of
   four kinds is not a convention. What stands instead is the maintainer's
   instruction, which maps onto a group that really exists: the "Protocols"
   section is literally there, and that is what *"neuer reiteun unter
   protokolle"* names.

   **Withdrawn on 2026-11-05, by the consequence of the maintainer's own
   answer.** With the pool sized from `maxConcurrentTransfers` (§5b), the tab
   has nothing in it: the one control it was created to hold does not exist any
   more, and the FTPS mode belongs in the connection form, not in app settings.
   So **no `SettingsSection.ftp` in the first release**, which also puts FTP
   where WebDAV already is — no tab, because there is nothing to put in one. If
   a per-protocol knob does turn up during implementation (a `NOOP` interval
   worth exposing, an encoding override), the tab arrives with it and the
   "Protocols" section is where it goes.
10. **`setPermissions` maps to `SITE CHMOD`**, which is not in RFC 959 and may
    be refused. A refusal is a per-file error, not a capability claim — the same
    distinction `RemoteChecksumOutcome` already draws between
    `unavailableOnThisConnection` and a `RemoteFSError`. The builder may revisit
    this against a measurement from the rig.

---

## 5. The connection model

This is the one place FTP cannot be fitted to the existing architecture. The
invariant in `CLAUDE.md` is *"One SSH connection per tab; SFTP and the terminal
shell multiplex over it as child channels"*. FTP has no multiplexing: a control
connection carries one data transfer at a time.

The shape, per the maintainer's decision:

- **One command connection per tab, reserved.** Listing, navigation, `STAT`,
  rename, delete and `MKD` run here, so a running upload never blocks the
  browser.
- **A transfer pool, default three.** Queue items take a connection from it;
  the pool size is the setting.
- **Four sockets per tab at the default**, which is the cost of the decision.
  Shared hosts count connections per account and answer `421 Too many
  connections`, sometimes with a timed lockout. Hence the setting: a user who
  gets locked out turns the pool down to 1 and the queue becomes serial. The
  pool must degrade gracefully rather than failing the queue — a `421` on
  acquiring a transfer connection shrinks the pool for that session and retries
  serially, it does not fail the item.
- **The command connection needs a keepalive** (`NOOP`), because idle FTP
  control connections are dropped by servers and by NAT. The interval is left to
  the builder.

Nothing here may block a thread: the cooperative-pool rule in `CLAUDE.md` binds
the pool's own waiting too — acquiring a connection is an `await`, never a
semaphore.

### 5a. The release invariant, which is the pool's real failure mode

`421` is the server refusing, and the shrink rule above heals it. The failure
that does **not** heal, and that no setting rescues, is the client losing count:
`readStream` returns an `AsyncThrowingStream`, so a pooled connection is held by
a **stream**, not by a call, and a consumer that abandons the stream — a
cancel, a thrown error, a `prefix` — must still give the connection back. One
leak per abandoned download ends in a permanently starved pool, which the user
sees as a queue that hangs for no reason.

**So the release is an invariant of the design, not a detail of the
implementation:** a pooled connection is handed out as a token whose release is
not optional, and the stream's termination — normal, thrown or cancelled — is
the only thing that returns it. The plan owns a test that abandons a stream
mid-download and asserts the pool's free count recovers.

Two consequences in the same family:

- **A cancelled transfer's connection is discarded, never returned.** Cancelling
  FTP needs `ABOR` or a closed data socket plus a read of the pending
  `426`/`226`; if the control reply stream desynchronises, the next command's
  reply is read as the previous command's, and the backend then answers
  confidently and wrongly. That is the same class of harm §8's anti-drop rule
  guards against, so it gets the same treatment: the connection is dropped
  rather than reused, and the pool's accounting is written to expect that.
- **The `421` state is keyed on host plus account, not on the tab.** The
  server's limit is per account; the shrink in §5 was keyed per session, which
  means two tabs on one host each shrink to 1 and still hold two sockets each,
  and a third tab opens at the default and re-trips the lockout the other two
  just escaped. This is a genuine tension with the architecture invariant that
  connection state belongs to the window scope and never to an app-wide
  singleton — the shared thing here is not a connection but a *refusal count*,
  which argues for a process-wide budget consulted by each tab's pool, in the
  shape `TabRegistry` already has (ownership, never state). Resolved in the
  design rather than in the code.

### 5b. There is already a setting for this number

`SettingsStore.maxConcurrentTransfers` exists today: key
`maxConcurrentTransfers`, **default 3**, clamped 1–8
(`SettingsStore.swift:58,106,188`), surfaced as "Maximum concurrent transfers"
in the Transfers tab (`SettingsView.swift:652`) and wired per tab into
`TransferQueueViewModel.maxConcurrent` (`ContentView+Lifecycle.swift:182,355`).
**Decided 2026-11-05: one number, the existing one.** The FTP transfer pool is
sized from `maxConcurrentTransfers`; there is no second control. Two regulators
over one quantity contradict each other where the user can see it — three queue
slots over one pooled connection shows three rows as "running" while two are
parked on an `await` — and the clamp, the label, the per-tab wiring and the
persistence all exist already.

The maintainer's *"default 3 + 1 für steuerungen"* survives intact under this
reading: the reserved command connection is **not** part of that number, so a
tab holds `maxConcurrentTransfers + 1` sockets, four at the shipped default,
which is exactly what was asked for. The clamp already caps the pool at 8, so
nine sockets is the ceiling per tab.

---

## 6. `TYPE I`, and why it is not a preference

FTP's ASCII mode translates line endings **inside the data stream**. A binary
file transferred in ASCII mode arrives corrupted, with no error, on both ends.
There is no safe default other than binary, and there is no hidden switch: the
backend issues `TYPE I` and never `TYPE A`. If ASCII mode is ever added, it is
an explicit per-transfer choice with its own warning, and it is not in this
release.

---

## 7. Transport and TLS

**FTP is the first protocol here that needs a raw socket with its own TLS.**
Measured 2026-11-05: `NIOSSL` has **0** occurrences
(`/usr/bin/grep -rnoE 'NIOSSL' --include='*.swift' Sources Tests | wc -l`), and
`import Network` appears **2** times, both in `Tests` —
`LoopbackTLSStub.swift:3`, which is a real import, and
`ReconnectWiringGuardTests.swift:412`, which is inside a comment. The first
draft said it *"appears **1** time*"; that figure was wrong, counted over
`Sources` only while the sentence named a wider scope, and is withdrawn.
`LoopbackTLSStub` matters twice over: it is an in-process `NWListener` TLS
server that mints its own certificate at runtime with `kSecImportToMemoryOnly`
and commits no key material, which makes it the template §9 needs. WebDAV and
S3 both go through
`URLSession`, so their TLS is the system's — `Sources/macSCPCore/WebDAV/`
contains a `WebDAVSessionDelegate`, and the trust decision lives in
`ServerCertificateValidation` and `TrustedCertificateStore`. NIO is used for SSH
and for the tunnels (`TunnelConnection`, `BytePump`, `SOCKS5Listener`).

**Decision: `apple/swift-nio-ssl`.** `swift-nio` is already a direct dependency
(`Package.swift`, `from: "2.101.0"`) and the project's existing socket code is
NIO, so an FTP client in NIO adds no stack. The alternative considered was
`Network.framework` (`NWConnection` + `NWProtocolTLS`), which adds no
dependency; it is rejected because it would be a second transport stack beside
NIO, and because the argument that most favoured it turned out not to hold:
`ServerCertificateValidation` is transport-agnostic — `ServerCertificateCandidate`
carries the leaf certificate as `derBase64` — so **the existing trust store and
fingerprint decision are reusable under either option**, and the only remaining
difference is how many stacks the project has.

The cost is named rather than hidden, and more precisely than the first draft
managed: `swift-nio-ssl` vendors BoringSSL as `CNIOBoringSSL`, and
**`swift-crypto` already vendors the same codebase as `CCryptoBoringSSL`** —
measured 2026-11-05, `.build/checkouts/swift-crypto/Sources/` holds
`CCryptoBoringSSL` and `CCryptoBoringSSLShims`. So this is not "a vendored C
library" but a **second copy of one already in the binary**. That is the figure
Task 4 has to report. **Neither build time nor binary size is measured yet**;
the plan's TLS task measures both, because this project documents every
dependency
(`docs/superpowers/specs/2026-08-20-backlog-dependencies.md`) and a dependency
whose cost nobody wrote down is the kind of debt that section exists to prevent.

TLS specifics: `AUTH TLS` on the control connection, then `PBSZ 0` / `PROT P`
so the data connections are protected too.

**Implicit FTPS on 990 ships in the first release**, by the maintainer's
decision of 2026-11-05 restating the requirement of 2026-09-02. So an FTP
connection has **three** security modes: plain, explicit (`AUTH TLS` on 21) and
implicit (TLS from the first byte on 990). That is one field in
`StoredFTPConfig` and one control in the connection form — which plain-versus-
explicit needed anyway — plus a second dial path (wrap the socket before the
greeting, instead of upgrading after it) and a default port that follows the
mode. The cost is in the dial and the form, and §7a shows it stops there.

**One more TLS axis, unmeasured and named here because it decides whether this
works in the field at all:** many FTPS servers require the data connection's
TLS session to resume the control connection's (vsftpd's `require_ssl_reuse`
defaults to on). Whether `swift-nio-ssl` offers client-side session resumption
across connections is **not measured**, and the plan's TLS task measures it
before the stack is committed — a rig daemon that does not require reuse will
never reveal it.

The server certificate goes through the existing
`ServerCertificateValidation` path, so an FTPS host with a self-signed
certificate asks the same question WebDAV already asks, and
`ProtocolCapabilities.authenticatesHostKey` stays **false** — a TLS certificate
is not a host key, which that field's own comment already says.

### 7a. The capability row

`ProtocolCapabilities` has 10 axes and the generic layers read only this. FTP's
row:

| axis | value | why |
|---|---|---|
| `supportsShell` | `false` | no shell; the terminal pane folds away through the existing `hasShell` fold |
| `permissionModel` | `.posixMode` | `SITE CHMOD`, see decision 10 |
| `supportsSymlinks` | `true` | Unix `LIST` and `MLSD` (`type=OS.unix=symlink`) report them |
| `atomicRename` | `false` | `RNFR`/`RNTO` is not atomic in general |
| `directoriesAreReal` | `true` | unlike S3 |
| `resumeMode` | `.restOffset` | see below |
| `supportsPresignedURL` | `false` | no such concept |
| `supportsRemoteChecksum` | `false` | WebDAV's precedent; see §8a |
| `transport` | `.optionalTLS` | a single fixed value, even with three modes — see below |
| `authenticatesHostKey` | `false` | §7 |

**Three security modes, one fixed `transport` value — measured, not assumed.**
The 2026-09-02 record expected implicit FTPS to force a per-connection
capability field, saying the axis is *"not representable as a single value"* and
*"likely needs a per-connection field rather than a fixed descriptor value"*.
**That worry is unfounded, and the reason is the gate's two-part shape.**
`PlaintextTransportGate` is the only reader of the axis — measured 2026-11-05,
`/usr/bin/grep -rn '\.transport' --include='*.swift' Sources` has exactly one
`capabilities.transport` hit outside `ProtocolCapabilities.swift` itself, at
`PlaintextTransportGate.swift:15`, and that file's own comment says it is *"the
FIRST reader of `ProtocolCapabilities.transport` (M21)"*. The gate asks two
questions, not one: the **capability** decides whether the question applies, the
**config** decides whether this endpoint is plaintext. So FTP's descriptor keeps
`transport: .optionalTLS` — the kind *can* be plaintext — and `isPlaintext(_:)`
gains an arm returning true only for the plain mode. Plain asks; explicit and
implicit do not. **No capability field, no change to the other three backends,
no change to the descriptor machinery.** That record should be corrected in
place when this document is committed, quoting its own wording.

**The table's eleventh row, and the one that matters most.**
`supportsAppendResume` is not a `ProtocolCapabilities` axis — it is a
`RemoteFileSystem` requirement with a default of `true`
(`RemoteFileSystem.swift:207`), and it is the one the code actually reads:
`TransferEngine.swift:182` is `let effectiveResume = resume &&
destination.supportsAppendResume`, and S3 overrides it to `false`
(`S3FileSystem.swift:1316`). It was missing from the first draft's table, which
had the emphasis inverted: `resumeMode`, which nothing reads, was in; the flag
that gates every resumed transfer was out.

FTP's answer is **not settled here**, because getting it wrong corrupts files
silently, which §6 names as the one anti-goal. The problem: FTP has no
validator, so `entityTag` takes its `nil` default, and the `ifMatching` guard
that `RemoteFileSystem`'s own comment says exists to stop *appending the tail of
a replaced object to the head of the old one* is unavailable. Either
`supportsAppendResume` is `false` for FTP in the first release — resumption off,
correctness guaranteed — or it is `true` with a substitute check (size plus
`MDTM` before the `REST`), which is weaker than a validator and must be argued
for rather than assumed. The plan owns this with a test that plants a replaced
remote file under a resumed upload.

**`ResumeMode.restOffset` was declared for this backend and has never been
used.** Measured 2026-11-05: `/usr/bin/grep -rn 'restOffset' --include='*.swift'
Sources Tests` prints exactly one line, its own declaration in
`ProtocolCapabilities.swift:4`. It is decoration today, in the precise sense
`PlaintextTransportGate`'s comment uses for the transport axis before M21
(*"declared and set on every backend but consulted nowhere — decoration"*), and
FTP is what makes it real: `REST <offset>` then `STOR`, and `REST` then `RETR`
for a resumed download.

---

## 8. Listing

`MLSD` (RFC 3659) returns a machine-readable listing and is the only sane path.
It is advertised in `FEAT`, so the probe is free. Where it is absent — which is
exactly the old shared hosts this backend exists for — `LIST` returns a
human-readable listing in a dialect, and the dialects are not inventable.

**Because there is no real-server corpus, the dialects are fixtures, not
servers.** A `LIST` parser is a pure function; it gets unit tests over the
published formats (Unix with a year, Unix without a year for recent files,
DOS/IIS) plus the inputs a parser must refuse rather than guess at. The rig
verifies the live protocol dance — `PASV`/`EPSV`, the pool, TLS, `REST`
resumption — not the dialect zoo.

A listing line the parser cannot read must not silently vanish from the
browser. It becomes a visible row the user can see and report, or the listing
fails; a parser that drops what it does not understand is how a sync deletes
files.

### 8a. Two questions the code had already answered

Both were on the list to ask the maintainer and were withdrawn after measuring,
which is recorded here so a later reader does not re-open them:

- **Comparison does not use timestamps.**
  `/usr/bin/grep -rn 'modif\|mtime\|Date' --include='*.swift'
  Sources/macSCPCore/Compare/FolderComparison.swift` prints nothing, and
  `ComparisonClassification` settles a pair on size, asking for a checksum only
  where the sizes are equal *and* known. FTP's minute-resolution,
  timezone-ambiguous `LIST` timestamps therefore cost nothing in comparison or
  synchronisation. (They are still worth reading for display, and `MDTM` gives a
  better one where `FEAT` advertises it.)
- **Equal-size pairs land on `undetermined`, and that is shipped behaviour.**
  FTP has no portable checksum — `HASH`, `XCRC`, `XMD5` are extensions almost no
  shared host carries. So `supportsRemoteChecksum` is `false` and the connection
  answers `unavailableOnThisConnection`, exactly as WebDAV does today
  (`RemoteChecksumProvider.swift:10`: *"and so does WebDAV, which has no digest
  to report at all"*).

---

## 9. The rig

The rig already carries two WebDAV servers — bare `httpd:2.4` and
`nextcloud:29-apache` — because a clean server and a real product disagree. FTP
gets the same treatment, and here it is not optional: with no real host to try,
the rig is the whole of the evidence.

Two services, chosen so that the fallback path is exercised rather than merely
present:

- one that advertises `MLSD` and supports `AUTH TLS`, and
- one that does **not** advertise `MLSD`, so `LIST` runs in anger.

Both start from the main checkout only (`CLAUDE.md`: never from a worktree —
the seed mount is relative to the compose file), both seeded idempotently like
`s3/init.sh`, and the gated suite runs under `MACSCP_ITEST=1` with the other 34
gated files.

**The image problem, which the 2026-09-02 measurement already recorded and the
first draft asserted past.** That document measured the candidates:
`stilliard/docker-pure-ftpd` has **no native arm64 build**,
`garethflowers/docker-ftp-server` documents **no TLS at all**, and
`chonjay21/docker-ftps` has been stale since 2020; its closing paragraph says
validating FTPS *"may itself need custom rig work before any implementation plan
can rely on"* it. §9's first draft asserted a service that both advertises
`MLSD` and supports `AUTH TLS` without reconciling that, on a machine the rig
treats as arm64. **This is the plan's first blocker, not a detail** — §9 says the
rig is the whole of the evidence, so an image that does not exist is the evidence
not existing.

The answer that needs no image: an **in-process loopback FTPS stub**, in the
mould of `Tests/macSCPCoreTests/LoopbackTLSStub.swift`, which is already an
`NWListener` TLS server minting its own certificate at runtime with
`kSecImportToMemoryOnly` and committing no key material. It is also the only
way to test the hostile cases a well-behaved daemon will never produce: a `421`
on acquire, a desynchronised control reply, a `PASV` reply carrying a bogus
address, a server that requires TLS session reuse. **Decided 2026-11-05: both.**
The stub carries protocol behaviour and the hostile cases and runs ungated with
the normal suite; one real containerised daemon carries the interoperability
claim and runs under `MACSCP_ITEST=1`. Where no published image offers `MLSD`
plus `AUTH TLS` on arm64, the container is the project's own `Dockerfile` beside
the existing `macscp-test-sshd` image, which is the precedent for exactly this —
the rig already builds one image of its own rather than only pulling them.

Implicit FTPS on 990 (§7) needs a listener that wraps the socket before the
greeting. The stub provides it cheaply, which is the second reason both are
wanted: the 2026-09-02 record's *"an implicit-FTPS rig may need a custom
image"* stops being a blocker when the implicit server is in-process.

**The limitation, stated plainly:** a containerised FTP daemon is clean, and the
population this backend targets is not. The dialect fixtures cover what can be
covered from published formats; the first real shared host this meets may still
produce a listing nobody has seen. That is a known residual risk, not an
oversight, and the remedy is the §8 rule that an unparseable line is visible
rather than dropped.

---

## 10. What cannot work, and how the app says so

Driven by capabilities, not by kind, so each of these is already handled by a
generic layer:

- **No terminal.** `supportsShell: false`; the pane folds away through the
  existing `hasShell` fold in `SessionTab`.
- **No presigned URLs**, no object versioning, no bucket settings — S3-only
  surfaces that are already capability-gated.
- **No remote checksum** (§8a), so a same-size pair is reported as undetermined
  rather than as a match.
- **No atomic rename**, which the overwrite-protection paths already read.
- **`SITE CHMOD` may be refused** by the server; a refusal is a per-file error
  with a message naming the server's reply.

---

## 11. Integration cost

Measured 2026-11-05, as the honest floor rather than an estimate of the whole:

- WebDAV, the most recent backend, is 9 source files / **2250** lines and 10
  test files / **3149** lines
  (`find Sources -ipath '*WebDAV*' -name '*.swift' -exec cat {} + | wc -l`, and
  the same over `Tests`; the match is by file name, so shared helpers are not
  counted).
- `case .webdav` appears **19** times across **9** files in `Sources` and **16**
  times in `Tests` — the fourth case must be written into every exhaustive
  switch, and the compiler finds them.
- Plus what WebDAV did not need: the connection pool (§5), a `LIST` dialect
  parser with its fixtures (§8), a new TLS dependency (§7), and two rig
  services (§9).

So: **above WebDAV's cost, not at it.** This is a plan of its own, not a task
folded into something else.

---

## 11a. Everywhere a connection appears

Added by the maintainer on 2026-11-05, after the first draft of this document:
*"ftp brauch auch dann die login verwaltung, import, export, etc"*. FTP is not
only a file system; it is a connection, and it has to exist in every surface a
connection exists in.

**That list is measurable rather than guessable: it is the files carrying a
`case .webdav` arm.** `/usr/bin/grep -rlE 'case \.webdav' --include='*.swift'
Sources` prints these **9**, and each one is a surface FTP needs:

| file | the surface |
|---|---|
| `Connection/ConnectionConfig.swift` | the config enum — a fourth case and a `StoredFTPConfig` beside `StoredWebDAVConfig` |
| `Sessions/SessionCatalog.swift` | stored sessions: login management's persistence |
| `Presentation/ConnectionViewModel.swift` | the connection form itself (9 `webdav` mentions today) |
| `Presentation/SessionOverviewModel.swift` | the overview the sidebar reads |
| `Capabilities/BackendDescriptor.swift` | the descriptor and its `connect` closure |
| `Capabilities/PlaintextTransportGate.swift` | the plaintext question (decision 5) |
| `Diagnostics/ContributionProbes.swift` | connection diagnostics |
| `Tunnels/TunnelFailureKind.swift` | tunnel failure mapping |
| `MacSCPCLI/SessionFieldOptions.swift` | the CLI's per-kind flags |

**Export and import are not protocol-agnostic, so they are real work rather
than a free ride.** Measured 2026-11-05:
`/usr/bin/grep -rnoE 'ConnectionKind|\.webdav|\.s3\b|case ssh'
Sources/macSCPCore/Sessions/SessionExportCodec.swift
Sources/macSCPCore/Sessions/LoginSetExportCodec.swift
Sources/macSCPCore/Sessions/ExportEnvelopeCodec.swift` prints 9 lines —
`SessionExportCodec` carries per-kind arms and reads `ConnectionKind` in three
places, `LoginSetExportCodec` reads it in two, and `ExportEnvelopeCodec` prints
nothing, so the envelope itself is kind-blind and only the session and
login-set codecs need an FTP shape. Each needs a round-trip test, and one more
besides: **an older macSCP reading an export that contains an FTP session must
refuse that entry and keep the rest**, not fail the import or crash. Nothing in
this project has had to do that before, because FTP is the first kind added
since export existed.

**External import** needs no new source. `Sessions/ExternalImport/` holds one
reader today (`CyberduckBookmarkSource`, with `CyberduckSecretReader`), and it
already recognises `"ftp"` — as `.unsupported`. The change is the one §1
describes: those bookmarks become importable, which turns 23 test fixtures from
"this is what unsupported looks like" into something else.

**Credentials** go to the Keychain through `SecretStore` like every other
backend; the JSON stores never hold them, and neither does an export envelope.

---

## 12. Left to the builder

Deliberately undecided, because the plan or the implementation is where these
belong:

- The pool's idle-eviction and `NOOP` keepalive intervals.
- Whether `MFMT` is issued after an upload to preserve the local mtime.
- The error-mapping table from FTP reply codes to `RemoteFSError`, beyond the
  `421` rule in §5.
- Whether the command connection is also used for a transfer when the pool is
  configured to 1 (an alternative to a strictly serial queue).
- `EPSV` versus `PASV` preference and the fallback order.

---

## 13. Open risks

- **`421 Too many connections`** on shared hosts at a four-socket default. The
  mitigation is the setting plus graceful degradation (§5). Unmeasured against a
  real host, because there is none.
- **The dialect residual** (§9).
- **`swift-nio-ssl`'s build-time and binary-size cost** — unmeasured, and the
  plan's first task measures it (§7).
- **The 23 import fixtures and the newly-importable FTP bookmarks** (§1) are a
  change to a shipped feature and need their own task, not a sweep at the end.
- **Data-connection TLS session reuse** (§7) — unmeasured, and the axis most
  likely to make an otherwise finished backend fail against real FTPS servers.
- **An older build reading a newer store or export.** `StoredSession` carries
  `kind: ConnectionKind = .ssh` with optional per-kind blocks, `ConnectionKind`
  is a `String`-raw `Codable`, and there is no `ConnectionKind(rawValue:` call
  anywhere in `Sources` — so a sessions file or an export containing `"ftp"`
  fails to decode wholesale on an older build. FTP is the first kind added since
  export existed, so nothing has had to survive this before.

---

## 14. The four questions, and their answers

Asked and answered on 2026-11-05, after the builder check. Recorded here so the
plan does not re-open them.

1. **Implicit FTPS on 990 — ships in the first release.** Against my own
   recommendation to defer, and the maintainer was right to overrule it: it was
   his requirement of 2026-09-02, and the cost turned out to be a dial path and
   a form field rather than a change to the capability system (§7, §7a).
2. **Synchronising — its own piece of work, later.** Not in this plan, and FTP
   does not wait for it (§2).
3. **The pool is sized from `maxConcurrentTransfers`; there is no second
   control.** Which withdraws the FTP settings tab, since the tab had nothing
   else in it (§5b, decision 9).
4. **The rig gets both** — an in-process FTPS stub for protocol behaviour and
   the hostile cases, plus one containerised daemon built from the project's own
   `Dockerfile`, the way `macscp-test-sshd` already is (§9).

### Settled by me in response to the review, so the maintainer need not

- **FTPS requested and `AUTH TLS` refused: the connection is refused.** No
  downgrade to plaintext, no runtime prompt. `PlaintextTransportGate` is a
  pre-dial check over the config and structurally cannot see a runtime
  downgrade, and this project's analogous rule — a host-key mismatch is a hard
  stop with no decider consulted — points one way only.
- **`permissionModel` stays `.posixMode`**, and the permission editor is offered
  per connection rather than per protocol, probed once like
  `ChecksumFormMemory.form` does for checksums, so a server that refuses `SITE
  CHMOD` shows no editor instead of an editor that always fails.
- **User documentation is a closeout task of the plan**, per `CLAUDE.md`:
  `noix-docs`, `src/content/docs/macscp/guide/`, one page, marked as coming in
  the next version. Its absence from the first draft was an omission.
- **The CLI is in scope for the first release** — `--kind ftp`, the per-kind
  flags in `SessionFieldOptions`, the secret environment variable and the
  completion script. `CLIMatrixITests` asserts
  `fixture.entries.count == ConnectionKind.allCases.count`, so the fourth kind
  reddens it immediately; leaving the CLI out would mean weakening that
  assertion, which is the wrong direction.
- **The unreadable-listing-line rule** (§8) ships as *the listing fails for that
  directory, naming the line*, not as a new `RemoteFileItem` state. A field on
  that type is read by every backend and the whole browser; it is a reasonable
  second step, not a precondition.
- **The certificate decider's type moves out of `WebDAVSessionDelegate`.**
  `BackendDescriptor.connect` currently types its third argument
  `WebDAVSessionDelegate.CertificateDecider`; a second consumer makes that name
  wrong. The rename touches the descriptor, three connect closures and their
  tests, and it is cheaper now than after.
- **The connect timeout is honoured.** That argument's comment says S3 and
  WebDAV drop it; FTP is the one backend with a raw socket where honouring it is
  trivial, so it does.
