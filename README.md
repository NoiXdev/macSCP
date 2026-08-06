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
  protocols in the same window.
- **Two-pane browser** — local and remote side by side, folder navigation
  by double-click, drag & drop in both directions (including dragging
  remote files straight into the Finder).
- **Saved sessions** — one-click reconnect, groups, inline rename;
  passwords and passphrases live only in the macOS Keychain.
- **SSH key authentication** — OpenSSH ed25519 keys, with or without
  passphrase; entries from `~/.ssh/config` appear automatically.
- **SSH agent support** — authenticate with the identities already loaded
  in your local agent; the private key never leaves it.
- **Host-key pinning** — first-connect confirmation with the key
  fingerprint; a changed host key is a hard stop, never a dialog.
- **Integrated terminal** — a real shell on the same connection,
  one keystroke (⌘T) away.
- **Transfer queue** — parallel transfers, conflict handling
  (overwrite / skip / rename / apply-to-all), recursive folders,
  resume after connection loss, per-direction bandwidth limits.
- **Edit remote files in place** — double-click opens the file in your
  editor; saving uploads it back automatically.
- **English and German** interface.

## Known limitations

- **RSA identities from an SSH agent.** They authenticate against OpenSSH
  servers, but servers built on Go's `x/crypto/ssh` — Gitea, Forgejo,
  SFTPGo, `gitlab-sshd` and others — reject them. The app currently
  reports this as an ordinary authentication failure. Ed25519 and ECDSA
  identities are unaffected; use one of those with such servers.
- **Several identities in your agent.** They are offered as separate
  login attempts (at most six per connection). On a server running
  fail2ban with its default `maxretry = 5`, a single connect attempt can
  therefore trip the jail and get your address banned.
- **Where the connection log lives.** Per-session audit logs are stored
  in `~/Library/Application Support/macSCP/audit/`, one file per saved
  connection. Deleting a saved connection deletes its log.

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

## Command line

`macscp-cli` is a small command-line companion. It ships **inside the app
bundle**, so installing macSCP installs it too:

```sh
/Applications/macSCP.app/Contents/MacOS/macscp-cli ls prod:/var/www
```

For everyday use, put it on your `PATH` once — for example:

```sh
sudo mkdir -p /usr/local/bin
sudo ln -s /Applications/macSCP.app/Contents/MacOS/macscp-cli /usr/local/bin/macscp-cli
```

Building from source also produces it, at `.build/release/macscp-cli`.

The CLI works only with sessions already saved by the app — there is no
way to pass a host and password directly on the command line. Point it at
one with `name:/path`, e.g. `macscp-cli ls prod:/var/www`.

**Commands**

| Command | Effect |
|---|---|
| `ls <session>:<path>` | List a remote directory. |
| `get <session>:<path> <local dir>` | Download a remote file into a local directory (keeps its remote name). |
| `put <local file> <session>:<path>` | Upload a local file into a remote directory (keeps its local name). |
| `rm <session>:<path> [--recursive]` | Delete a remote file, or a whole directory with `--recursive`. |
| `mkdir <session>:<path>` | Create a remote directory. |

`get`/`put` take `--on-conflict fail\|skip\|overwrite` for what to do when
the destination already exists (`fail` is the default — nothing is
overwritten unless asked).

**Secrets.** A session's password or key passphrase is looked up in this
order, stopping at the first one that answers: an explicit
`--password-command <cmd>` (the command's own stdout, trimmed); an
environment variable (`MACSCP_PASSWORD` for an SSH session,
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

## License

[MIT](LICENSE) — © 2026 noix.
