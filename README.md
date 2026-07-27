# macSCP

**A fast, native SFTP client for the Mac — two panes, saved sessions, and a
built-in terminal.**

macSCP brings the classic two-pane file-transfer workflow to macOS as a
true native app: browse your Mac on the left, your server on the right,
and move files between them with drag and drop, buttons, or the Finder.

![macSCP browser window](docs/design/assets/screenshot-browser.png)

## Features

- **Two-pane browser** — local and remote side by side, folder navigation
  by double-click, drag & drop in both directions (including dragging
  remote files straight into the Finder).
- **Saved sessions** — one-click reconnect, groups, inline rename;
  passwords and passphrases live only in the macOS Keychain.
- **SSH key authentication** — OpenSSH ed25519 keys, with or without
  passphrase; entries from `~/.ssh/config` appear automatically.
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

## Install

1. Download `macSCP-1.0.0.dmg` from the releases page.
2. Open it and drag **macSCP** into **Applications**.
3. Requires macOS 15 or newer. The app is signed and notarized.

## Building from source

macSCP is a Swift package: `swift build -c release` builds the binary,
`swift test` runs the test suite, and `scripts/package-app` assembles a
runnable `macSCP.app` under `dist/`. Integration tests expect the Docker
SSH test rig from `docker/test-server/` (`MACSCP_ITEST=1`).

## License

[MIT](LICENSE) — © 2026 Tim Rösner.
