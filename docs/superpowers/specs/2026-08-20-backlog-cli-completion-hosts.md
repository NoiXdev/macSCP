# Backlog: CLI — autocompletion, help, host list

**Logged:** 2026-08-20, from a maintainer prompt. Secured ideas, **not a
design**.

## Starting point, measured

`macscp-cli` is small: **430 lines**, five subcommands (`ls`, `get`,
`put`, `mkdir`, `rm`) on `swift-argument-parser`. Sessions are referenced
as `name:/path`. `--json` already exists (in `SessionConnecting`, so for
all connecting commands).

**There is no command that lists sessions.** Whoever does not know the
name by heart has to open the app.

Every command has a one-line `abstract`, **none** has a `discussion`. The
`name:/path` notation is not explained anywhere as a concept, only shown
by example in individual argument help texts.

## 1. Host list with filters — build first

**Done 2026-09-02 — item 1.** `macscp-cli sessions` (`--group`, `--kind`,
`--name`, `--tag`, `--json`) reads `SessionCatalog`
(`Sources/macSCPCore/Sessions/SessionCatalog.swift`) over the session
store; the value it returns is `SessionCatalog.Row` — name, kind, target,
group, tags, structurally nothing a secret could hide behind (a `Mirror`
test pins that). The security constraint below is held by
`CLISessionsCommandGuardTests`
(`Tests/macSCPCoreTests/CLISessionsCommandGuardTests.swift`), a
source-scanning guard that pins that `SessionsCommand.swift` names none of
`SecretStore`, `SecretResolver`, `secretSources(`, `connect(`,
`withConnection(`, `KnownHostsStore`. Filters are as specified here, not
more: `--name` is a case-insensitive **substring**, not a pattern — `pro*`
matches nothing against `Production`; `--group` matches the session's own
group or any ancestor by name; `--tag` is exact, case-insensitive;
`--kind` is exact; all four AND together. Still open: item 2
(autocompletion) and item 3 (the `discussion` explaining `name:/path` on
the root command) are unbuilt; the CLI reads no remote path and resolves
no login set or keychain entry anywhere in this command.

A subcommand that outputs the saved sessions, with filter arguments
(group, backend kind, name pattern). `--json` is already set as a
pattern and should apply here.

**Security constraint, non-negotiable:** the listing must output **no
secrets** and **must not touch the keychain**. It reads the session
store, which by project invariant contains no secrets. No resolving of
login sets, no passphrase prompt, no connection setup — the list is a
pure store query.

**Why first:** item 2 needs exactly this query. If completion is built
first, the listing logic gets built twice.

## 2. Autocompletion

**Half the way is already walked.** `swift-argument-parser` generates
completion scripts for bash, zsh and fish on its own
(`--generate-completion-script`), and the error handling in
`MacSCPCLI.main()` already treats a completion request like a help
request (exit code 0). So what is missing is not the mechanism, but two
things:

1. **Shipping and setup.** The script must reach the user. To clarify:
   does the install script generate it along the way, or do we only
   document the command? The CLI lives inside the app bundle and is made
   reachable via a symlink — that is the place where this gets decided.
2. **Dynamic values.** Session names come from the store, not from a
   fixed list; `@Argument(completion: .custom { … })` exists for this.

**The design question that must be answered before building:** how far
does completion go?

- **Session names** are local, cheap, and safe. Clear case.
- **Remote paths** after the colon would be the actual convenience — but
  pressing Tab would then **establish a connection**. That is slow,
  surprising, and in a non-interactive shell can run into a TOFU
  decision nobody can answer. Recommendation: **session names only** for
  now; remote paths at most later and explicitly opted into.

## 3. Help that explains how to use it

The one-liners describe what a command does, not how to invoke it.
Specifically missing:

- A `discussion` on the **root command** that explains the `name:/path`
  notation once as a concept — including where the names come from (item
  1 then supplies the command that shows them).
- Example invocations per subcommand. `swift-argument-parser` accepts
  these in `discussion`.
- A note that the CLI lives **inside the app bundle** and how to get it
  onto the path — today this is only in the README, not in the help
  itself.

## Order

**1 → 3 → 2.** The listing is the data source for completion and at the
same time what the help wants to point to. Completion comes last because
it is the only one that raises a shipping question.

## Decided 2026-09-02 — item 2

The maintainer chose **static completion scripts plus dynamic session
names**: `swift-argument-parser`'s generated zsh/bash/fish scripts for
subcommands and flags, and `@Argument(completion: .custom { … })` for
session names read from the store through `SessionCatalog` — no secret,
no keychain, no connection touched (the same forbidden-symbol guard the
`sessions` subcommand carries). Item 3 (the `discussion` for
`name:/path` on the root command) rides along. Plannable now.
