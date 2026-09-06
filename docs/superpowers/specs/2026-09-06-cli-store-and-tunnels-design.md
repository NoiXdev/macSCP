# CLI: sessions and tunnels from the command line — design

**Status:** approved by the maintainer in chat on 2026-09-06 (scope:
tunnels AND sessions; no secret through the CLI); plan follows.

## Goal

`macscp-cli` can create, edit and delete saved sessions and tunnel
profiles, list tunnel profiles, and run a tunnel profile in the
foreground — so a script can set up what the app then shows, and a
terminal can hold a forwarding open the way `ssh -L` does. Every new verb
is covered by the CLI matrix (`Tests/macSCPCoreTests/CLIMatrixITests.swift`)
the same way `ls`/`get`/`put` are.

## Starting point (verified in the tree, 2026-09-06)

- The CLI has ONE store-reading command, `sessions` (list with filters,
  `--json`), and nothing that writes a store. `MacSCPCLI.swift:43-47`
  lists seven subcommands: `ls get put rm mkdir sessions diagnose`.
- `SessionStore` (`Sources/macSCPCore/Sessions/SessionStore.swift`)
  offers `all()`, `upsert(_:)`, `delete(id:)`, `upsertGroup(_:)`;
  `TunnelStore` (`Sources/macSCPCore/Tunnels/TunnelStore.swift`) offers
  `allProfiles()`, `profiles(for:)`, `upsert(_:)`, `delete(id:)`,
  `deleteAll(for:)` (this line said `all()` until Task 3 measured it). Both are
  in Core and take a directory, and the CLI already honours
  `MACSCP_STORAGE_DIRECTORY` for the session store.
- `TunnelRunner` (Core) drives one profile through connect → forward →
  active → reconnect → stop and is what the app's `TunnelManager` uses;
  `TunnelConnection.connect` refuses sessions with a login set or a jump
  host (`TunnelConnection.swift:21`). Tunnels are SSH-only by
  construction (`TunnelProfile.sessionID` must name an SSH session; the
  app's sheet enforces it, `TunnelManager.start` guards it).
- The app reads the session store when a window is built
  (`SessionListViewModel.reload()` at `Presentation/SessionListViewModel.swift:104`,
  no caller on activation) and the tunnel store through
  `TunnelManager.reload()` after its own writes. Nothing re-reads either
  store when another process writes it.
- The CLI matrix reads the binary's subcommands from `--help`
  (`CLIMatrix.subcommands(binary:)`) and
  `everySubcommandTheBinaryOffersIsDrivenByACase` demands at least one
  driving case per subcommand. Whether a backend can do an OPERATION is
  asked of `ProtocolCapabilities` (`CLIMatrix.supports(_:named:operation:)`);
  there is no notion of a subcommand that applies to one backend only.
- Secrets reach the CLI through the environment
  (`BackendDescriptor.secretEnvironmentVariable`) or `--password-command`;
  keychain entries are shared with the app by per-entry consent (M20
  addendum, 2026-08-04). The CLI writes no keychain entry today.
- Exit codes (M20): 0 success, 2 usage, 10 secret, 11 host key unknown,
  12 host key mismatch, 13 connection failed, 14 path/remote error,
  15 conflict. ArgumentParser's `validate()` failures exit 64.

## Maintainer decisions (chat, 2026-09-06)

1. **Scope: tunnels AND sessions.** A tunnel references a session by
   name; a script that cannot create the session is incomplete.
2. **No secret through the CLI.** `sessions add`/`edit` never take,
   store or print a password or passphrase. Key- and agent-backed
   sessions work at once; a password session is asked for its password
   by the app on first connect (the app's existing flow stores it in
   the keychain); the CLI itself connects with the environment variable
   or `--password-command`, exactly as today.
3. **No `apply`.** The verbs are enough for scripts; a declarative file
   with reconciliation is its own plan (export format, conflict rule).
4. **`tunnels start` runs in the CLI process, in the foreground**, like
   `ssh -L`. The CLI cannot instruct the running app (no IPC exists, and
   none is added); a tunnel started from the terminal belongs to that
   terminal and ends with it.

## Commands

All verbs are store-only except `tunnels start`. Every verb takes
`--json` where it prints rows. Names are the identity a user types
(`name:/path` everywhere else), so every verb addresses by NAME; the
UUID stays internal and is printed only under `--json`.

### `sessions add <name> --kind ssh|s3|webdav …`

Creates one session. The name must be free — case-insensitively and
whitespace-trimmed, which is STRICTER than the app's own rule (the app
compares exactly, measured 2026-09-06 in Task 1: `SessionListViewModel.save`
looks up `$0.name == name`; a script creating `prod` and `Prod` is almost
always a mistake, a person typing them is not). One function,
`SessionNameRule.conflict(_:among:excluding:matching:)`, serves both,
with the mode passed explicitly; otherwise exit 64 with "a session named X
already exists — use `sessions edit`". Flags per kind, refused with
exit 64 when given for the wrong kind ("--bucket applies to --kind s3"):

| kind | required | optional |
|---|---|---|
| `ssh` | `--host`, `--user` | `--port` (22), `--key <path>` (auth = key; without it, auth = password, asked by the app), `--agent` (auth = agent) |
| `s3` | `--endpoint`, `--bucket`, `--access-key` | `--region`, `--path-style` |
| `webdav` | `--url`, `--user` | `--nextcloud` (the stored flag `useNextcloudPath`; there is no `--auth` — the scheme is negotiated at connect time and `StoredWebDAVConfig` stores none, measured in Task 2) |

Common: `--group "A / B"` (created along the path if missing, `" / "`
separated exactly as `sessions --json` prints `groupPath`), `--tag` (repeatable),
`--pane files|files-and-terminal`. Login sets and jump hosts are not
settable from the CLI (they are app-side concepts with their own sheets);
the flags do not exist. The S3 access key is not a secret (it appears in
signed URLs) and is a flag; the secret key is not.

### `sessions edit <name> [same flags] [--rename <new>] [--no-tag <tag>]`

Changes only the fields named. `--kind` cannot change (exit 64: delete
and add). `--rename` follows the same conflict rule as `add`. Editing the
host or user of a session keeps its secret slot (the keychain entry is
keyed by the session id), which is what the app does too.

### `sessions rm <name> [--yes]`

Deletes the session AND its tunnel profiles: the CLI calls
`TunnelStore.deleteAll(for:)` and then `SessionStore.delete(id:)`
directly. (The app reaches the same two calls through its registered
`TunnelManager.deletionObserver` in the App target, which also stops the
running tunnels; the CLI has no runners to stop.) Interactive terminal without `--yes`: asks "Delete
session X and N forwardings? [y/N]" on the TTY; `--non-interactive`
without `--yes`: exit 64. The keychain entry is left in place (the CLI
never touches the keychain), and `--verbose` says so.

### `tunnels list [--session <name>] [--json]`

Columns: name, session, kind (`local`/`remote`/`dynamic`), spec in
OpenSSH notation, autostart, reconnect. No state column — the CLI cannot
see the app's runners.

### `tunnels add <name> --session <name> (--local | --remote | --dynamic) …`

Exactly one of:

- `--local [bind:]port:host:hostport` (OpenSSH `-L`)
- `--remote [bind:]port:host:hostport` (OpenSSH `-R`; port 0 refused,
  the recorded fork limit)
- `--dynamic [bind:]port` (OpenSSH `-D`)

`bind` defaults to `127.0.0.1`. `--autostart off|app-start|login`
(default off), `--reconnect` (default off). The session must exist, be
SSH, and carry neither a login set nor a jump host — the same rule
`TunnelConnection.connect` enforces, checked at `add` time so the error
names the reason ("session X uses a jump host; forwardings cannot dial
through one"). Tunnel names are unique per session (the app allows
duplicates; the CLI needs a handle, so it enforces uniqueness and refuses
to `edit`/`rm`/`start` an ambiguous name that the app created: "two
forwardings named X on session Y — rename one in the app").

### `tunnels edit <name> --session <name> [--local|--remote|--dynamic …] [--autostart …] [--reconnect|--no-reconnect] [--rename <new>]`

Changes only the fields named; the kind may change (a profile is one
mapping, replacing it is the point).

### `tunnels rm <name> --session <name>`

No confirmation: a profile is cheap to recreate and carries no secret.

### `tunnels start <name> --session <name> [--accept-new] [--json]`

Runs the profile in this process until Ctrl-C (SIGINT/SIGTERM → the
runner's `stop()`, awaited, then exit 0) or until the runner reaches
`failed` (exit 13, the audited reason on stderr) or `needsConfirmation`
(exit 11 unknown key without `--accept-new`, exit 12 on a mismatch —
which is a hard stop, never confirmable). Prints one line per state
change (`--json`: one object per line, `{"state":"active","connections":0}`
etc.); `active` includes the bound port whenever the runtime has one —
for `--remote` and for a `--local`/`--dynamic` bound on port 0 (Task 4
widened this from "for `--remote`"; the `--local 0:` case is the one
that makes the number useful). JSON keys are sorted; consumers decode,
they do not compare text. The secret comes
from the environment variable or `--password-command`, resolved once
before the dial, exactly as `ls` does; `--non-interactive` forbids the
host-key question. Reconnect follows the profile's `reconnects` flag
with the runner's backoff (2, 4, 8, 16, 32, 60 s), printed as
`reconnecting attempt=N`. Only one profile per invocation (a second
name is exit 64 with "one forwarding per invocation; run two
terminals").

## The app re-reads its stores

`MacSCPApp` observes `NSApplication.didBecomeActiveNotification` and
calls `SessionListViewModel.reload()` on every window's view model and
`TunnelManager.shared.reload()`. Both reloads are already idempotent
(the manager keeps runners by id; a running profile edited by the CLI
keeps running under its old mapping until restarted — stated in
`tunnels edit`'s `--verbose` output: "the app restarts a running
forwarding only when you stop and start it"). The app writes nothing on
reload, so a CLI write cannot be clobbered by a stale in-memory copy;
conversely a CLI write between an app read and an app write of the SAME
session is lost — the app's write wins, which is the existing rule for
two app windows and is recorded as a limit.

## Matrix coverage

The matrix gains ONE notion: a subcommand that applies to a subset of
backends, derived from the binary rather than listed in the tests.
`tunnels …` and `sessions add/edit/rm` are driven for every backend:

- `sessions add/edit/rm` are store-only and run against all three rigs
  (the `add` creates a second session beside the fixture's, the `edit`
  changes its tag, the `rm` deletes it; each verified by `sessions --json`
  through the binary).
- `tunnels add/edit/list/rm` run against all three: on SSH they
  succeed; on S3 and WebDAV `tunnels add` must fail with exit 64 and the
  message naming the kind — the case asserts the refusal, so a fourth
  backend that could carry tunnels fails the case until someone decides.
  The source of truth for "which kinds can carry a tunnel" is one Core
  function (`TunnelProfile.Kind.carriers` or equivalent, an exhaustive
  switch over `ConnectionKind`), read by the CLI verb, the app's sheet
  and the matrix — not three lists.
- `tunnels start` runs in the SSH suite end to end against the rig
  (`docker/test-server`, `AllowTcpForwarding yes`): a local forward to
  the rig's own sshd port (the banner proves bytes flow), a dynamic
  forward with a hand-rolled SOCKS5 CONNECT to the same, a remote forward
  probed from inside the container with `nc`, Ctrl-C (SIGINT to the
  child) ending with exit 0, an unknown host key refused without
  `--accept-new` (exit 11), a changed host key a hard stop (exit 12). On
  S3/WebDAV the `start` case asserts exit 64 with the kind named.
- `everySubcommandTheBinaryOffersIsDrivenByACase` keeps working
  unchanged: `sessions` and `tunnels` are the subcommands the help lists
  (the verbs are nested), and the drive-scan learns nested verbs.
- Secrets stay in the child's environment; no verb takes one.

## Testing (ungated)

Per verb, against a temp store, through the built binary (the pattern
of `CLISessionsJSONRoundtripTests`): add/edit/rm round trips, every
refusal (wrong-kind flag, duplicate name, non-SSH session for a tunnel,
jump host, remote port 0, two names for `start`), `--json` shapes, the
OpenSSH spec parser (`[bind:]port:host:hostport`, IPv6 brackets,
malformed → exit 64). The parser is a pure Core function
(`TunnelSpec.parse`) with a table test. The app's activation reload is
pinned by a source guard (positive: the notification observer names
both reloads).

## Limits (stated, not solved)

- A CLI-started tunnel is invisible to the app's glyph and badge (it is
  another process); the app's menu shows the profile as stopped.
- A tunnel edited while the app runs it keeps its old mapping until
  restarted in the app.
- A CLI write between an app read and an app write of the same session
  is lost (app wins; same as two windows).
- No secret is ever written by the CLI; a password session created by
  the CLI is usable from the CLI only with the environment variable or
  `--password-command`, and from the app after its first prompt.
- Groups are created along a path but never deleted by the CLI.
- No `apply`, no import/export.

## Not in this plan

Name completion for `sessions edit/rm` and `tunnels … --session`: the
existing completer appends a trailing `:` (it completes `name:/path`
targets), so a bare-name completer is a separate change under the CLI
completion backlog entry (found in Task 2).

Declarative `apply`; login sets and jump hosts from the CLI; keychain
writes; an IPC to the running app; shell completion for the new verbs
beyond what ArgumentParser generates — including `--session`, whose
bare-name completer is deferred as the paragraph above says (this
sentence used to claim the opposite; corrected 2026-09-06 in Task 3).
