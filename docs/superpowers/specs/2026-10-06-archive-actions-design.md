# Archive actions in the file context menu — design

**Date:** 2026-10-06. **Base:** `develop` at `973311f6`. **Branch:**
`archive-actions`.

Maintainer wishlist item 15, recorded in `docs/BACKLOG.md` under "Custom
actions in the file context menu": archive actions shipped by default, plus a
builder for user-defined actions.

## What this covers, and what it does not

**In scope:** the shipped archive actions, on **both** panes — remote and
local.

**Out of scope, and deliberately so: the builder for user-defined actions.**
It is a second subsystem, not a second half of this one. A user-authored
command template interpolating file names is arbitrary remote command
execution, and this project today runs a strict whitelist against exactly
that shape: `Tests/macSCPCoreTests/ConnectionDiagnosticsJumpTests.swift:608`
lists `-oProxyCommand=id` beside `$(id)` and `` `id` `` as input the host
fields must refuse. The builder needs its own security design, and it can sit
on the seam this design builds. **Maintainer's ruling, 2026-10-06:** split,
archive actions first.

## What was measured before designing

Every figure below was produced on 2026-10-06 at `973311f6` by the command
printed beside it, run from the repository root.

**No archive machinery exists.** Counted:

```
grep -rno -e 'unzip' -e 'gzip' -e 'tar -' Sources/ --include='*.swift' | wc -l
```

printed **0**.

**The contribution seam carries exactly one action, and the App dispatches it
by comparing an id string.**

```
grep -rno 'FileActionContribution(' Sources/ --include='*.swift' | wc -l
grep -rn 'action.id ==' Sources/MacSCPAppKit/
```

printed **1** — `FileActionContribution(id: "s3.presignedURL", …)` at
`Sources/macSCPCore/Capabilities/BackendDescriptor.swift:483` — and one line,
`Sources/MacSCPAppKit/ContentView+Detail.swift:553`. The type itself
(`Sources/macSCPCore/Capabilities/BackendContributions.swift:5`) carries only
`id`, `titleKey` and `titleDefault`: it is data, with no `run`, unlike
`DiagnosticContribution` in the same file, which does carry one.

**There is no "run one command" seam today.** `RemoteShellProvider`
(`Sources/macSCPCore/RemoteFS/RemoteShell.swift:25-28`) opens an interactive
PTY and nothing else, and it has exactly one conformer:

```
grep -rn 'RemoteShellProvider {' Sources/ --include='*.swift'
```

printed one line, `Sources/macSCPCore/SSH/CitadelFileSystem.swift:1620`.

**The transport can run a command with a writable stdin, on an explicit exec
channel.** The Citadel fork is pinned at `0.12.1-noix.3` (`Package.swift:30`).
`SSHClient.withExec(_:environment:perform:)`
(`.build/checkouts/Citadel/Sources/Citadel/TTY/Client/TTY.swift:456`, declared
`@available(macOS 15.0, *)`, which the project's floor already satisfies)
opens the RFC 4254 exec channel — its own doc comment says the channel "is
8-bit safe and suitable for binary data transfer without PTY escape sequence
processing" — and hands the closure a `TTYStdinWriter`, whose
`write(_ buffer: ByteBuffer)` sits at `TTY.swift:80`. A non-zero exit arrives
as `SSHClient.CommandFailed(exitCode:)` (`TTY.swift:173`).

The three simpler entry points — `executeCommand`, `executeCommandStream`,
`executeCommandPair` — expose no stdin. This design does not use them. The
first reading of this file concluded that Citadel offered no stdin on an exec
channel at all; that conclusion was wrong, and `withExec` is the function it
had missed.

**The local side needs no shell whatsoever.** `SubprocessRunner.run`
(`Sources/macSCPCore/Subprocess/SubprocessRunner.swift:248`) takes
`arguments: [String]` and `stdin: Data?`, so a name is an argv element and
never passes a parser. Its `timeout` defaults to `.seconds(60)`, which this
feature must raise — a large archive outlives a minute.

**The two flags this design prescribes work on macOS.** Measured 2026-10-06
in a temporary directory, not in the repository:

```
cd "$(mktemp -d)" && printf 'hello\n' > gztest && gzip -k gztest && ls gztest gztest.gz
cd "$(mktemp -d)" && printf 'x\n' > a && printf 'y\n' > "b'c" && printf "a\0b'c\0" | tar --null -T - -czf t.tar.gz && tar -tzf t.tar.gz
cd "$(mktemp -d)" && printf 'x\n' > a && printf 'y\n' > "b'c" && printf "a\nb'c\n" | zip -q -@ t.zip && unzip -Z1 t.zip
```

Each line is self-contained and was run in exactly this form. The first printed
`gztest` and `gztest.gz`, so `gzip -k` keeps the original without a
redirection. The second and third each printed `a` and `b'c`, so a name holding
an apostrophe reaches `tar --null -T -` and `zip -@` without quoting. An earlier
version of this block was NOT runnable as committed — its `tar` line assumed a
directory holding `a` and `b'c` that no line created — which is the failure
this project has a rule about, caught here by running the block instead of
reading it.

## Decisions taken by the maintainer, 2026-10-06

Recorded so they can be overturned.

1. **Both panes**, remote and local, not remote alone (which was this
   design's recommendation).
2. **A "Compress" submenu** offering `.zip`, `.tar.gz`, and `.gz` for a
   single file, plus **"Extract Here"** detecting the format from the
   extension (`.zip`, `.tar.gz`, `.tgz`, `.tar`, `.gz`). No in-place
   `gzip`/`gunzip` that replaces its input: the menu holds no entry whose
   failure halfway destroys the source.
3. **A lightweight per-pane progress model**, not the transfer queue. The
   queue's `Item.Status` is byte-shaped
   (`running(TransferProgress)`, `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift:85`)
   and an archive run counts no bytes; teaching it an indeterminate state
   would change the type carrying this project's strictest invariants for an
   operation that does not need it.
4. **Names reach the remote tool through stdin**, not the command line;
   only the archive name is quoted.
5. **A selection holding a name with a newline refuses the `.zip`
   operation** rather than being passed unsafely or silently rerouted to
   another format.
6. **`.gz` uses `gzip -k`**, keeping the original, rather than building a
   shell redirection.

## Architecture

### The plan is a value

`ArchivePlan.make(…)` is a pure function in Core. It takes the operation
(`ArchiveOperation`: `.compress(ArchiveFormat)` or `.extract`), the selection
as names relative to **one** directory, that working directory, and the
chosen archive name; it returns a plan, or refuses.

The plan is two shapes, one per side:

- **local:** an executable URL, an `arguments: [String]` argv, and optional
  stdin bytes;
- **remote:** one command-line string and optional stdin bytes.

Nothing executes inside `make`. That is the point: the entire safety
question — what ends up on a command line, and what does not — becomes a
value a test can read, with no server, no process and no network. The hostile-
name battery runs against the plan.

`ArchiveFormat` and `ArchiveOperation` are closed enumerations, so a future
format cannot be added as a magic string.

### Two runners behind one protocol

`ArchiveRunner` has one method: run a plan, report progress lines, and return
the outcome. Two conformers:

- **`RemoteArchiveRunner`** over a new Core capability seam,
  **`ArchiveCommandChannel`**, which `CitadelFileSystem` conforms to using
  `withExec`. The seam is queried with `as?`, exactly as
  `RemoteShellProvider`, `PresignedURLProvider` and `RemoteChecksumProvider`
  already are — the established way this project asks a backend what it can
  do.

  **Correction, 2026-10-08.** This bullet first named that seam
  `RemoteCommandRunner`, and the gate below first read
  `as? RemoteCommandRunner`. Withdrawn: a seam of that name takes a command,
  which makes it the general execution entry point this project has already
  refused in writing. `Sources/macSCPCore/RemoteFS/RemoteChecksumProvider.swift`
  says of its own narrow capability: "A general execution entry point would
  have been the alternative, and it would have been a new surface every future
  reviewer had to watch." The spec was written without reading that file, and
  the reasoning there binds this feature exactly as much as it bound that one.

  So the seam is shaped like `ChecksumCommandChannel`
  (`RemoteChecksumProvider.swift:113`, one method,
  `standardOutput(of line: ChecksumCommandLine) async throws -> String`),
  not like a command runner: `ArchiveCommandChannel` takes an
  **`ArchiveCommandLine`** plus the stdin bytes, and `ArchiveCommandLine`
  carries a `fileprivate init`, the way `ChecksumCommandLine` does
  (`FileChecksum.swift:325-331`), so no file outside the one that builds
  archive commands can phrase a command line at all. The stdin parameter is
  the one thing the checksum seam does not have and this one needs.
- **`LocalArchiveRunner`** over `SubprocessRunner.run`, with its own budget
  rather than the 60-second default.

The runners hold no policy. Which command to run was decided by the plan.

### The menu

The archive entries are **new `BrowserMenuEntry` cases**, not
`FileActionContribution` values. A contribution hangs off a
`BackendDescriptor`, and the **local pane is not a backend** — a feature
serving both panes cannot be carried by a per-backend list. The S3 "Share
Link…" contribution and its id comparison are left exactly as they are; this
design neither extends nor retires them.

The gate: remote panes offer the entries when the file system answers
`as? ArchiveCommandChannel`; local panes always do. Where the gate is closed the
entry is **absent, not disabled** — the same judgement `computeChecksum`
already carries (`Sources/macSCPCore/Presentation/BrowserContextMenu.swift:37`),
for the same reason stated there: a dead menu item is not an answer.

### Progress and cancellation

One model per pane, holding at most one running operation: a title, a state,
and a cancel. Cancelling closes the exec channel on the remote side and
terminates the child on the local one. On completion the pane reloads its
listing.

## Names, and the one shell we cannot avoid

An SSH exec command is run by the server through the account's login shell,
so a name written onto the remote command line is parsed by a shell. A folder
named `$(reboot)` or `a'b` is a legal name. Locally the question does not
arise at all: `Process` takes argv.

| path | shell | separator | any name? |
|---|---|---|---|
| local, `Process` argv | none | — | **yes** |
| remote `tar --null -T -` | yes | NUL | **yes** |
| remote `zip -r -@ <archive>` | yes | newline | **no** |

So the selection — unbounded in size and arbitrary in content — never
touches a shell: it goes to the tool as bytes on stdin. What remains on the
command line is this project's own fixed vocabulary plus **one**
user-controlled token: the archive's name (on extraction, the archive's own
name). That token goes through **`PosixQuoting.singleQuoted`**
(`Sources/macSCPCore/Terminal/PosixQuoting.swift:27`).

**Correction, 2026-10-08.** This sentence first read: "That token goes through
a single central POSIX quoting helper, pure and in Core, wrapping in single
quotes and rewriting `'` as `'\''`, with its own battery of hostile names."
Withdrawn as a thing to build — it exists, and building a second one is the
drift its own doc comment was written to prevent ("Two quoting routines that
drift apart is the failure this extraction exists to prevent"). It is already
the quoting the checksum command lines use (`FileChecksum.swift:275`), and it
already has the battery: `Tests/macSCPCoreTests/PosixQuotingTests.swift`
beside `Tests/macSCPCoreTests/ShellQuotingExecutionTests.swift`.

Reusing it also inherits a bug nobody would think to re-fix: it is written as
a walk over `Unicode.Scalar`s rather than as
`replacingOccurrences(of: "'", with: "'\\''")`, because that call matches on
grapheme clusters, so an apostrophe carrying a combining mark went unescaped
and met this wrapper's own closing quote as live shell syntax — which executed
arbitrary commands in real `bash`.

Two consequences stated rather than hidden:

- **A newline in a name and `.zip` are incompatible.** Measured 2026-10-06
  against Zip 3.0 (Info-ZIP, with Apple modifications), `zip --version`:
  `zip -h2` documents the flag as "read names to zip from stdin (one path per
  line)", and the only NUL-adjacent entry it lists is `-0 store files (no
  compression)`, which is not a separator. That is a positive beside the
  negative — the flag's own documented separator, not merely a missing
  option — so such a name cannot be handed over safely. The operation is
  refused with a message
  naming the offending file; `.tar.gz` and `.gz` remain available, because
  `tar --null -T -` is NUL-separated. A silent reroute to another format
  would hand the user something other than what they clicked.
- **The quoting helper's rule is POSIX.** Against a login shell that is not
  POSIX-compatible it does not hold. That is a known limit of this design,
  not an oversight, and it is recorded here so a later failure report is
  read against it rather than investigated from nothing.

## Errors

`CommandFailed(exitCode:)` is mapped at the App layer, which is where this
project maps raw errors to localized text. Exit **127** is the tool being
absent — "this server has no `zip`" — and is worth its own sentence, because
it is the one failure the user can act on by choosing another format.

**Availability is not probed when the menu opens.** A probe there is a
network round trip per right-click. The failure is the answer.

`gzip -k` not being understood by the server's `gzip` is reported as the error
it is, rather than retried through a redirection.

## Collisions

Nothing is ever overwritten. Where the target name exists, a free name is
chosen beside it. The check is a stat through the file system before the run,
so the decision is made by macSCP rather than by the tool's own clobbering
rules, which differ between `zip`, `tar` and `gzip`.

## Testing

- **The plan and the quoting helper, pure**, with no server and no process:
  every format, single and multiple selection, the hostile-name battery, the
  newline refusal, and the collision naming.
- **The menu gate** with a positive check beside the negative one, per this
  project's rule that a negative check alone goes stale in silence.
- **The local runner** against a temporary directory using the real `zip`,
  `tar` and `gzip` — no network, no rig.
- **The remote runner** against the Docker rig under `MACSCP_ITEST=1`,
  started from the main checkout.
- No wall-clock ceilings. A floor ("this did not return early") where one is
  wanted.
- A secret never reaches a plan, a log line, a `reason:` string or a test
  failure message; the archive paths that do appear are not secrets.

## User documentation

A page under `src/content/docs/macscp/guide/` in `noix-docs`, written in the
same piece of work, marked as arriving in the next version, and carrying no
tech-stack terms.
