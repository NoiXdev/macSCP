# macSCP

**A fast, native SFTP client for the Mac — two panes, saved sessions, and a
built-in terminal.**

macSCP brings the classic two-pane file-transfer workflow to macOS as a
true native app: browse your Mac on the left, your server on the right,
and move files between them with drag and drop, buttons, or the Finder.

## Features

- **Three server protocols** — SFTP over SSH, S3-compatible object storage,
  and WebDAV (Basic, Digest, and TLS auth; a one-click Nextcloud/ownCloud
  preset). Mix and match freely, including transfers between two different
  protocols in the same window. An S3 session can start at the account's
  bucket list instead of one fixed bucket.
- **Two-pane browser** — local and remote side by side, folder navigation
  by double-click, drag & drop in both directions (including dragging
  remote files straight into the Finder).
- **Saved sessions** — one-click reconnect, groups, inline rename;
  passwords and passphrases live only in the macOS Keychain.
- **SSH key authentication** — ed25519, RSA, and ECDSA keys, from a file
  or your SSH agent, with or without a passphrase; entries from
  `~/.ssh/config` appear automatically.
- **SSH agent support** — authenticate with the identities already loaded
  in your local agent; the private key never leaves it.
- **Host-key pinning** — first-connect confirmation with the key
  fingerprint, for ed25519, RSA, and ECDSA host keys alike; a changed
  host key is a hard stop, never a dialog.
- **Connection diagnostics** — check a connection from an open tab's
  toolbar, a saved session's context menu, or straight from a failed
  connection's error message. Runs name lookup, a reachability check, a
  ping, the connection attempt itself, a network route trace, and
  protocol-specific checks for S3 and WebDAV; run everything at once or
  just one, and copy the report as plain text or Markdown.
- **Integrated terminal** — a real shell on the same connection, one
  keystroke (⌘T) away, sized to match its panel whenever it opens or
  reopens.
- **Transfer queue** — parallel transfers, conflict handling
  (overwrite / skip / rename / apply-to-all), recursive folders, resume
  after connection loss, per-direction bandwidth limits. Cancel a single
  transfer or all of them; see and copy each transfer's full source and
  destination path from the row's tooltip or right-click menu, or show
  them permanently in a setting.
- **Checksums** — an optional column in the file list computes a
  checksum for a file, or a whole selection, on request, always labelled
  with where the number came from (computed here, computed on the
  server, or read from the object store's own tag).
- **Edit remote files in place** — double-click opens the file in your
  editor; saving uploads it back automatically.
- **Import from Cyberduck** — bring in your existing bookmarks from the
  Sessions menu: a preview lists every one with a checkbox, sessions
  already imported are recognised and updated instead of duplicated, and
  passwords can be copied over from Cyberduck's own keychain entries on
  request.
- **English, German, French, and Polish** interface.

## Known limitations

- **RSA keys against a server that accepts only SHA-256 signatures.**
  macSCP signs and verifies RSA keys with the SHA-512 variant; a server
  restricted to the SHA-256 one still refuses them, whether the key comes
  from a file or an agent.
- **Several identities in your agent.** They are offered as separate
  login attempts (at most six per connection). On a server running
  fail2ban with its default `maxretry = 5`, a single connect attempt can
  therefore trip the jail and get your address banned.
- **Where the connection log lives.** Per-session audit logs are stored
  in `~/Library/Application Support/macSCP/audit/`, one file per saved
  connection. Deleting a saved connection deletes its log.
- **No FTP or SMB/AFP support yet.** SFTP, S3-compatible storage, and
  WebDAV are the three protocols macSCP speaks today.
- **Cyberduck import does not yet cover WebDAV bookmarks.** SFTP and
  S3-compatible bookmarks import; WebDAV ones are not recognised.
- **The network route trace covers IPv4 only.** An IPv6 route is not
  traced.

## Update checks

macSCP compares its own version against the latest entry on the releases
page. The automatic check asks `api.github.com` at most once a day; the
**macSCP → Check for Updates…** menu item asks whenever you use it instead.
Either way, the request identifies the app and its version — GitHub needs
that to answer — but nothing else about you or your connections is sent,
and the response is read for nothing but the release tag and its link.
Nothing is downloaded or installed automatically — a newer version only
produces a note with a link. Turn the automatic check off under
**Settings → General**.

## Install

1. Download the latest DMG from the [releases page](https://github.com/NoiXdev/macSCP/releases).
2. Open it and drag **macSCP** into **Applications**.
3. Requires macOS 15 or newer. The app is signed and notarized.

## Building from source

macSCP is a Swift package: `swift build -c release` builds the binary,
`swift test` runs the test suite, and `scripts/package-app` assembles a
runnable `macSCP.app` under `dist/`. Integration tests expect the Docker
test rig from `docker/test-server/` (`MACSCP_ITEST=1`):

```sh
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 swift test
```

That brings up SSH (two servers, for remote-to-remote transfers), MinIO
(S3), and an Apache/mod_dav WebDAV server with a Basic, a Digest, and a
TLS vhost — the TLS certificate is generated fresh at container start and
never committed. A Nextcloud container sits behind a compose profile,
since it exists only to produce one real PROPFIND response the WebDAV
parser's test fixture is checked against — it stays out of the normal
`up -d` so that command remains fast:

```sh
docker compose -f docker/test-server/compose.yml --profile nextcloud up -d nextcloud
```

One suite is worth knowing about before you read a test log. The quoting
tests in `Tests/macSCPCoreTests/ShellQuotingExecutionTests.swift` run
`/bin/bash` on every `swift test` — they are ungated on purpose, because a
proof you have to switch on is not a proof, and they are the only way to
check a quoting rule against a shell rather than against our idea of one.
A few of them **deliberately execute an attack payload**: a refusal is only
worth pinning while the shape it refuses would still do damage, so those
tests assert that the payload does run when the same template is resolved
anyway. Each runs in its own fresh temporary directory with no stdin and no
inherited output, and every payload writes a marker file there and nothing
else.

## Command line

`macscp-cli` is a small command-line companion. It ships **inside the app
bundle**, so installing macSCP installs it too:

```sh
/Applications/macSCP.app/Contents/MacOS/macscp-cli ls prod:/var/www
```

For everyday use, put it on your `PATH` once. The easiest way is
**Settings → Command Line → Install**: it creates a shortcut at
`~/.local/bin/macscp-cli` and tells you afterwards whether that shortcut
still points at the app you are running — handy after moving the app or
installing a new version, when an old shortcut would silently keep
starting the previous copy. Use **Repair** to point it at the current one.

Move macSCP to your Applications folder before installing. An app opened
straight from the disk image runs from a temporary copy that macOS discards
when you quit, so a shortcut created there would stop working immediately —
the section says so instead of installing one.

`~/.local/bin` has to be part of your shell's `PATH` for the command to be
found. macSCP does not edit your shell configuration; if the folder is not
listed yet, add it yourself:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

If you would rather install system-wide, run this yourself — macSCP never
asks for administrator rights, and the same command is shown ready to copy
in Settings → Command Line:

```sh
sudo mkdir -p /usr/local/bin
sudo ln -sf /Applications/macSCP.app/Contents/MacOS/macscp-cli /usr/local/bin/macscp-cli
```

Building from source also produces it, at `.build/release/macscp-cli`.

The CLI works only with sessions already saved by the app — there is no
way to pass a host and password directly on the command line. Point it at
one with `name:/path`, e.g. `macscp-cli ls prod:/var/www`.

Tab completion is generated by the tool itself and also offers the saved
session names for the `name:` half:

```bash
macscp-cli --generate-completion-script zsh  > ~/.zsh/completions/_macscp-cli
macscp-cli --generate-completion-script bash > ~/.bash_completion.d/macscp-cli
macscp-cli --generate-completion-script fish > ~/.config/fish/completions/macscp-cli.fish
```

(zsh needs the directory on `fpath` before `compinit`; bash sources the
file from `.bashrc`; fish picks the file up on its own.) The completion
reads the session list only — no secret, no connection.

**Commands**

| Command | Effect |
|---|---|
| `sessions [--group <g>] [--kind <k>] [--name <text>] [--tag <t>]` | List the saved sessions, optionally filtered. Reads no secret and opens no connection. |
| `ls <session>:<path>` | List a remote directory. |
| `get <session>:<path> <local dir>` | Download a remote file into a local directory (keeps its remote name). |
| `put <local file> <session>:<path>` | Upload a local file into a remote directory (keeps its local name). |
| `rm <session>:<path> [--recursive]` | Delete a remote file, or a whole directory with `--recursive`. |
| `mkdir <session>:<path>` | Create a remote directory. |
| `diagnose <session>` | Measure the path to a saved session's server, step by step. |
| `diagnose --host <host> [--port <n>] [--kind <k>]` | The same measurement for a machine no session was saved for. |

`get`/`put` take `--on-conflict fail\|skip\|overwrite` for what to do when
the destination already exists (`fail` is the default — nothing is
overwritten unless asked). `ls`, `sessions` and `diagnose` take `--json`
to emit one JSON object per line instead of columns, for scripting.

`diagnose` prints one row per step as it finishes — the name lookup, the
connection attempt, the echo, the app's own login and the route to the
server — and `--scope ping\|trace\|dial\|contributions` narrows it to one
of them, out of the default `complete`, which runs every step. It never
remembers a server's identity on your behalf: a server this app has not
been introduced to is reported as such, and no flag here changes that.

**Secrets.** A session's password or key passphrase is looked up in this
order, stopping at the first one that answers: an explicit
`--password-command <cmd>` (the command's own stdout, trimmed); an
environment variable (`MACSCP_PASSWORD` for an SSH or WebDAV session,
`AWS_SECRET_ACCESS_KEY` for an S3 one); the keychain, same as the app
itself uses. A session authenticating through an SSH agent needs none of
these — the agent supplies the key.

**The keychain prompt.** The CLI reads the very same keychain items the
app writes, and macOS asks your permission per item the first time a
*different* program wants one. Choose **Always Allow** and the CLI is
added to that item's access list for good — every later run reads it
without a prompt, which is what makes unattended use (a cron job, a CI
runner) possible at all, provided the login keychain is unlocked. It is
while you are logged in; a job on a logged-out machine, or one started
over SSH, still cannot reach it. **Deny** or **Allow Once** leaves the prompt in
place for the next run, which will simply fail where no one can answer
it. That standing permission is tied to the CLI's code signature, so it
holds for the signed copy shipped inside the app bundle; a `macscp-cli`
you rebuilt yourself is a different signature and has to be confirmed
again. For a machine that must never prompt, use `--password-command` or
an environment variable instead and skip the keychain entirely.

**Host keys.** The same first-connect trust-on-first-use rule as the app
applies: an unknown host key is refused unless the CLI can either ask
interactively or was given `--accept-new`, and a host key that *changed*
is always a hard stop, never something a flag can wave through.
`--non-interactive` refuses to prompt even with a terminal attached; with
no terminal at all (a cron job, a CI runner) the CLI refuses to prompt on
its own.

**Exit codes** — stable and meant to be scripted against:

| Code | Meaning |
|---|---|
| 0 | Success. |
| 2 | Usage error (bad arguments, a directory where a file was expected, an empty destination). |
| 10 | Authentication failed. |
| 11 | Unknown host key, and nothing confirmed it (no terminal, or refused). |
| 12 | Host key changed since it was last trusted. |
| 13 | Connection failed. |
| 14 | The remote path was not found, or access to it was denied. |
| 15 | The destination already exists and `--on-conflict fail` (the default) was in effect. |
| 16 | `diagnose` finished, and at least one step failed or ran out of time. |

## License

[MIT](LICENSE) — © 2026 noix.

Third-party dependency licences are listed, with their full text, in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) — generated from
`Package.resolved` by `scripts/third-party-notices`.
