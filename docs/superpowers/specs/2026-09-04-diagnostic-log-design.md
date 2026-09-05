# Diagnostic log — design

**Date:** 2026-09-04. **Trigger:** a tester's report against release
1.3.0 (relayed by the maintainer the same day): the local pane no longer
loads the user's home folder — "sometimes it loads for five minutes,
sometimes it never stops loading", with every permission granted. The
tester changed nothing they know of. Nothing in the local listing path
changed between `v1.3.0` and `develop` (`git log v1.3.0..HEAD --
Sources/macSCPCore/RemoteFS/LocalFileSystem.swift` is empty), and the
owner/group gate that made a permission prompt able to stall a listing
shipped in 1.2.0 (`0b5ca533`, M18a). So the report cannot be reproduced
from the code alone, and the app gives the tester nothing to send back.
That is the gap this design closes.

## What the app has today

Six `Logger(subsystem: "dev.noix.macscp", category: …)` sites, all in
narrow places (teardown, editor resolution, S3 redirects, WebDAV session
delegate, Cyberduck secrets, keychain presence). Nothing on the listing
path, nothing on connect, nothing a tester can hand over as a file.

## Hypotheses the log must separate

1. **A metadata call that never returns.** `LocalFileSystem.list`
   reads the directory in one call and then asks `resourceValues` per
   entry; with the owner or group column visible it also runs
   `attributesOfItem` per entry, which on `Desktop`/`Documents`/
   `Downloads` can wait on a privacy prompt. A prompt that never
   appears is an infinite wait.
2. **A dead mount or cloud placeholder.** An entry in the home folder
   that points at an unreachable server makes the per-entry metadata
   call wait for a network timeout — minutes, then done.
3. **Something else** — the point of a log is the hypothesis nobody
   wrote down.

A log that records the start and end of every listing with its path,
count and duration, and every single entry whose metadata call took
longer than half a second, with its name, answers 1 and 2 directly and
gives 3 a place to show.

## Design

### The sink (Core)

`DiagnosticLog` in `Sources/macSCPCore/Diagnostics/DiagnosticLog.swift`:

- `public enum DiagnosticLogLevel: String, CaseIterable, Sendable,
  Codable { case off, error, info, debug }` — ordered; a line is written
  when its level ≤ the configured one (`error` < `info` < `debug`).
- `public final class DiagnosticLog: Sendable` with
  `public static let shared`, `public func configure(level:directory:)`,
  and `public func log(_ level: DiagnosticLogLevel, _ category: String,
  _ message: @autoclosure @Sendable () -> String)`. The autoclosure is
  evaluated only when the level admits the line, so a `debug` line
  costs one comparison when the level is `off`.
- **Never on the caller's path.** `log` appends the formatted line to a
  lock-protected buffer and signals a single writer task, which drains
  the buffer to the file. A listing that logs 5000 entries is not made
  slower by the disk; a wedged disk cannot wedge the UI.
- Line format, one per line, ISO 8601 with milliseconds and the local
  offset: `2026-09-04T13:02:11.417+02:00 [info] browser.local list
  done path=/Users/x count=61 ms=312`. Categories are dotted lower-case
  words; the level in brackets; then free text of `key=value` pairs.
- File: `~/Library/Logs/macSCP/macSCP-<yyyy-MM-dd>.log`, created on the
  first line of the day, appended thereafter. On `configure`, files
  older than seven days in that folder are deleted. `~/Library/Logs`
  is where Console.app looks and where users know to find logs.
- `configure(level: .off)` closes the file and drops the buffer; the
  setting can be changed while the app runs and takes effect at once.

### The setting (App)

`SettingsStore.diagnosticLogLevel: DiagnosticLogLevel` (default `.off`,
key `diagnosticLogLevel`, raw value stored). The General pane gains a
row: a picker "Diagnostic log" with Off / Errors / Info / Debug, the
folder path as a caption, and a "Show in Finder" button that reveals
the folder. `MacSCPApp` configures the sink at launch from the store
and again whenever the setting changes. The first line after
`configure` is `[info] app launch version=<v> build=<b>` so a log
identifies the build that wrote it.

### What gets logged (the instrumentation)

At `info`:
- `app launch`, `app quit`.
- `browser.local list start path=…` / `list done path=… count=… ms=…`
  / `list failed path=… reason=…`; the same three for
  `browser.remote` with the backend kind.
- `connect start host=… port=… kind=…`, each phase as it completes
  (`resolve`, `tcp`, `auth method=<agent|key|password>` — the method,
  never the credential), `hostkey <known|unknown|mismatch>` — the
  outcome, never the key), `connect done ms=…` / `connect failed
  reason=…`, `disconnect`.
- `transfer start direction=… path=… bytes=…` / `done ms=…` / `failed
  reason=…`.
At `error`: every error the App layer maps into a user-facing message,
with the mapped reason (the same text the user sees, nothing more).
At `debug`:
- `browser.local entry slow name=… ms=…` for every entry whose metadata
  call took ≥ 500 ms — the line that answers the tester's report.
- Every SFTP operation `CitadelFileSystem` issues: `sftp <op> path=…
  ms=… <ok|failed reason=…>` (11 operations at HEAD, counted with
  `grep -c "func " …` filtered to the protocol methods); shell channel
  open/close; keep-alive ticks; S3 and WebDAV requests as method + path
  + status + ms.

**Not logged, at any level:** passwords, passphrases, private keys,
tokens, presigned URLs, the bytes of any transfer, and host keys
themselves — never the key material a server presents or this app
holds. A host-key MISMATCH is the one exception, and it is a narrow
one: `HostKeyError.mismatch`'s two fingerprints (the expected key's and
the presented key's) reach the log, because a fingerprint is a public
value of a public key, not a secret, and a mismatch line is exactly
what a tester reports back to whoever holds the other end. They reach
the log only through the audited mapper, `DialSupport.reason(for:)` —
never through a hand-written `"...\(fingerprint)..."` interpolation
elsewhere — so `DiagnosticLogSecrecyGuardTests`' forbidden-identifier
list (below) still stands as the check on every OTHER, hand-written log
line; it does not need a fingerprint exemption carved into it. Every
other host-key outcome (known, unknown, rejected) logs the decision
only, never the key. The wire level of SSH (packets, KEX) is out of
scope: the SSH library exposes no hook for it, and packet bytes would
carry exactly what must not be written. "All SSH communication"
therefore means every request the app makes over the connection, at the
protocol level, with its outcome and timing.

### Guards

- `DiagnosticLogTests`: level filtering (a `debug` line is dropped at
  `info`, kept at `debug`, everything dropped at `off`); the autoclosure
  is not evaluated for a dropped line; lines reach the file in order;
  the writer runs off the caller (the caller returns before the file
  has the line; the test then awaits the flush); rotation deletes an
  eight-day-old file and keeps a six-day-old one; `configure(.off)`
  stops writing.
- A source-scanning guard, `DiagnosticLogSecrecyGuardTests`: no call
  to `DiagnosticLog.shared.log(` anywhere in `Sources/` interpolates an
  identifier matching `password|passphrase|secret|token|privateKey|
  presigned` (negative), beside a positive that at least N call sites
  exist (N counted when written) and that the categories used are from
  a fixed list.
- The settings guard family: the picker is bound to the store's
  property and labelled through the catalogue key; four catalogs equal.

### Out of scope, named

- The CLI writes no file log (it prints); a `--log-level` flag is a
  follow-up if a CLI report ever needs one.
- A "Send report" button that zips the log: later, if testers ask.
- Fixing the hang itself: the log exists to find it. If hypothesis 1
  holds, the fix is a bounded per-entry metadata call or a listing
  that shows names first and fills metadata after; that is its own
  plan, written from the log.
