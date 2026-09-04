# `macscp-cli diagnose` — Design

Decided 2026-09-04 with the maintainer ("wir planen das eben und stecken
das mit in die Liste nach dem Leak-Check"): the connection diagnostics
that the app has carried since the connection-tools plan
(`docs/superpowers/specs/2026-09-02-connection-tools-design.md`) get a
CLI door. Scheduled after the diagnostics leak-route fix
(`docs/BACKLOG.md`, "Diagnostics: error text as a leak route"), because
the CLI prints every row to a terminal and a pipe.

## What it is

```
macscp-cli diagnose <session> [--scope complete|ping|trace|dial|contributions] [--json]
macscp-cli diagnose --host <host> [--port <n>] [--kind ssh|s3|webdav] [--scope …] [--json]
```

The first form runs `ConnectionDiagnostics` against a stored session,
exactly the target the app's session context menu builds: the
descriptor's `editBaseline` merged with `sessionValues(stored)`, the
secret resolved through the session's secret slot (`secretSlot`: the
login set's id when one owns the credential, else the session's own) by
the same source chain the other subcommands use
(`secretSources(for:passwordCommand:)`), the host
key never accepted by this command: the dial answers the host-key
question with `HostKeyDecider.refusing` (`DialProbes.sshConnect`), as the
app's panel does, so an unknown key is a `failed` row and `diagnose`
takes no `--accept-new`/`--non-interactive`. The second form is the app's "unsaved tab" target: a bare
endpoint with no session id, so the dial and the contributions report
`skipped` and only resolve, TCP, ICMP and the trace run. `--kind`
defaults to `ssh` (port 22); it exists because the endpoint's default
port and the TCP probe's expectations come from the descriptor.

Rows print as the steps finish — `run(scope:onStep:)` hands each step
over the moment it is appended, which is the point of a diagnosis that
may spend twenty seconds in a trace. Text output is one row per step:
step id, outcome, duration, the technical detail line; the trace's table
prints under its row as hop rows. `--json` prints one object per step
(`id`, `outcome`, `reason` where the outcome carries one, `durationMs`,
`detail`, and `hops` for the trace) and one final object for the
report (`completion`, `endpoint`, `steps`), in the JSON-lines shape every
other `--json` in this CLI already uses.

## Exit codes

`0` when every step is `ok`, `skipped` or `unavailable` — the last two
say "not measured", which is a fact about the request, not the server.
A new `CLIExitCode.diagnosis = 16` when at least one step is `failed` or
`timedOut`: a script can branch on "something is wrong on the path"
without parsing rows. Usage errors (`2`) for a session that does not
resolve or a `--host` form with `--scope dial`/`contributions`, which can
measure nothing without a session — refused up front rather than
reported as a skipped row nobody asked for. The dial step's own host-key
refusal stays a `failed` row with the reason (exit 16), not exit 11/12:
the diagnosis reports, the connect decides.

## What never reaches the output

The same rule as the panel: no credential in any row (`DiagnosticStep`'s
own contract, pinned by `theSSHDialNeverPutsTheSecretInTheReport`), URL
userinfo stripped by `DiagnosticOutcome.redacted`, and — once the
leak-route fix has landed — no `String(describing:)` of a
configuration-carrying error anywhere in `Diagnostics/`. The CLI adds no
rendering of its own for reasons; it prints what Core's report carries.

## Tests

Core: a `DiagnoseRendering` unit (text rows, JSON objects, the exit-code
rule) tested without a network. CLI matrix: `diagnose` becomes the
seventh subcommand the coverage guard demands a case for — `--scope ping
--json` and `--scope dial --json` per backend against the rig, one
`--host 127.0.0.1 --scope trace` case, and the usage refusals. The
`--host` form with the rig's SSH port is the one case that measures the
ICMP echo on loopback; whether the runner's ICMP socket answers there is
recorded, not assumed.

## Not in this design

A `--watch`/repeat mode; a Markdown output (the app's copy menu has it,
a terminal does not need it); the leak-route fix itself (its own row and
plan).
