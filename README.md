# macSCP

**A fast, native SFTP client for the Mac — two panes, saved sessions, and a
built-in terminal.**

macSCP brings the classic two-pane file-transfer workflow to macOS as a
true native app: browse your Mac on the left, your server on the right,
and move files between them with drag and drop, buttons, or the Finder.

## Features

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
SSH test rig from `docker/test-server/` (`MACSCP_ITEST=1`).

## License

[MIT](LICENSE) — © 2026 Tim Rösner.
