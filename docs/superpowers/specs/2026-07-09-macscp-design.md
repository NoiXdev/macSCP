# macSCP — Design Spec

**Date:** 2026-07-09
**Status:** Draft, approved by the maintainer (brainstorming session)
**Project license:** MIT

## Goal

A native open-source client for macOS in the spirit of WinSCP. A real port is
impossible (WinSCP is C++ Builder/VCL, purely Windows-bound) — macSCP is a
new build that brings the WinSCP interaction model to the Mac:

- Two-pane file browser (local ↔ remote) over SFTP
- Integrated SSH terminal per connection
- Session manager with macOS Keychain integration
- Transfer queue with resume and editor integration

**Target audience:** Mac users coming from Windows/WinSCP, or missing a
native, free SFTP client. Differentiator against Cyberduck (Java),
FileZilla (wxWidgets) and Electron clients: feels like a real Mac app.

## Framework decisions

| Decision | Choice | Rationale |
|---|---|---|
| Language/UI | Swift + SwiftUI, AppKit where needed | Native feel is the differentiator; one language/codebase instead of Rust+TS (Tauri was ruled out) |
| SSH/SFTP | [Citadel](https://github.com/orlandos-nl/Citadel) (on SwiftNIO SSH) | Actively maintained (as of 04/2026), high-level SFTP API; swappable behind an abstraction layer |
| Terminal | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Mature, AppKit frontend, in production use in Secure ShellFish, La Terminal, CodeEdit |
| SSH fallback | libssh2 via C interop | Only if Citadel shows gaps; enabled by the protocol abstraction |
| Minimum macOS | 15 (Sequoia) | Citadel's shell API (`withPTY`, M4 terminal) requires macOS 15; raise from 14 confirmed by the maintainer (2026-07-09) |
| License | MIT | Lowest contributor barrier, common in the Swift ecosystem |
| Tests | Swift Testing | Unit against mock FS, integration against a Docker SSH server |
| Distribution | GitHub Releases (DMG) + later Homebrew Cask | Usual path for open-source Mac tools; no App Store in v1 |

## Architecture

Four core modules (Swift package `macSCPCore`, UI-independent, testable
headless) plus the app:

### 1. `Core/RemoteFS` — protocol abstraction

A Swift protocol `RemoteFileSystem` defines all file operations:

- `list(path)`, `stat(path)`
- `readStream(path)` / `writeStream(path)` (streams, no full buffering)
- `rename`, `delete`, `mkdir`, `chmod`

v1 implementation: `CitadelFileSystem`. The UI and the transfer queue work
exclusively against the protocol. That makes the libssh2 fallback, as well
as later backends (FTP, S3, WebDAV), pure add-on implementations.

### 2. `Core/SSH` — connection layer

`SSHConnection` = one authenticated SSH connection per server. SFTP channel
and shell channel (terminal) run multiplexed over the same connection — one
login, both available (like WinSCP with its integrated console).

Responsible for:

- Host key verification (TOFU: confirm on first connect, store the
  fingerprint, warn clearly on change)
- Auth: password, public key (including passphrase), ssh-agent
- Reconnect with exponential backoff on connection loss
- Encapsulating the NIO world: exclusively async/await outward

### 3. `Core/Sessions` — session management

- Stored connections (name, host, port, user, auth method, starting
  directories) as a local configuration file (JSON) in
  `~/Library/Application Support/macSCP/`
- Secrets (passwords, key passphrases) **exclusively** in the macOS
  Keychain, never in the configuration file
- Read-only import from `~/.ssh/config` (Host, HostName, User, Port,
  IdentityFile) — existing hosts appear without having to recreate them

### 4. `Core/Transfer` — transfer queue

- Queue with configurable parallelism (default: 3 concurrent)
- Progress per file and overall (bytes, rate, ETA)
- Resume of interrupted transfers (SFTP offset continuation)
- Conflict rules: overwrite / skip / rename — ask per case or set as a
  rule for the queue
- Recursive directory transfers

**Editor integration** (builds on top of the queue): remote file →
download to a temp directory → open with the default app → file watcher
(DispatchSource) detects the save → automatic upload. Temp files are
cleaned up when the session closes.

### 4b. `Core/Settings` — central settings (added by the maintainer, 2026-07-10)

A central, extensible settings element instead of scattered switches:

- `SettingsStore` in the Application Support directory (JSON, same pattern
  as `SessionStore`); typed access with defaults, unknown keys are
  preserved on load (forward-compatible).
- Native macOS settings window (SwiftUI `Settings` scene, ⌘,) with a tab
  structure — designed so further sections can be added later.
- First settings (land with M5c, where their consumers appear):
  - **Maximum concurrent transfers** (1–8, default 3) — controls queue
    parallelism over the window's ONE connection. Note: the number of
    parallel *server connections* is a v2 topic (tabs/windows).
  - **Bandwidth limit** upload/download (KB/s, 0 = unlimited) — throttle in
    the TransferEngine (chunk pacing).
- **"Open with" section (added by the maintainer, 2026-07-10, lands with
  M5e):** default editor for files (app picker; empty = system default)
  plus rules per file extension → app (e.g. `php` → PhpStorm). Editor
  integration (M5e) resolves the target app in this order: extension
  rule → default editor → macOS system association.
- Noted for later (not v1-binding): default terminal font size, default
  local path, queue conflict behavior as a default preference.

### 5. App/UI (SwiftUI + targeted AppKit)

Main window layout:

```
┌───────────┬──────────────────────┬──────────────────────┐
│ Sessions  │  Lokal (Pfad, Liste) │ Remote (Pfad, Liste) │
│ Sidebar   │                      │                      │
│           ├──────────────────────┴──────────────────────┤
│           │  Terminal-Panel (einblendbar, SwiftTerm)    │
│           ├─────────────────────────────────────────────┤
│           │  Transfer-Leiste (Queue, Fortschritt)       │
└───────────┴─────────────────────────────────────────────┘
```

- File lists: AppKit `NSTableView` via `NSViewRepresentable` — pure
  SwiftUI lists break down on directories with thousands of entries
- Drag & drop: Finder → remote list (upload), remote list → Finder
  (download)
- Terminal: SwiftTerm's AppKit view embedded, one terminal per session
- ViewModels with `@Observable`, Core calls via async/await

## Error handling

- Every Core layer throws typed errors (`RemoteFSError`, `SSHError`,
  `TransferError`)
- UI translates into understandable messages with an action option
  ("Connection lost — reconnect?")
- Transfers survive reconnects (queue pauses, resumes after reconnect)
- A host key change is a hard stop with a clear warning, not a dialog you
  can dismiss

## Testing

- **Unit:** Core logic (queue, conflict rules, ssh-config parser,
  session store) against a `MockRemoteFileSystem`
- **Integration:** the complete SFTP layer against a local OpenSSH Docker
  container (e.g. `linuxserver/openssh-server`)
- **CI:** GitHub Actions on macOS runners: build + unit tests on every PR;
  integration tests where Docker is available on the runner
- UI: manual smoke tests per milestone; UI automation not in v1

## Milestones

1. **M1 — Core proof:** connect, auth, list a remote directory
   (Core package + minimal CLI driver, no app yet)
2. **M2 — Browser:** app window with two-pane browser, download/upload of
   single files, drag & drop
3. **M3 — Sessions:** session manager, Keychain, ssh-config import
4. **M4 — Terminal:** SwiftTerm panel per connection
5. **M5 — Queue:** transfer queue with resume + editor integration
6. **M6 — Release:** app icon, onboarding, README/docs, notarized DMG,
   GitHub release

## Deliberately NOT in v1

- SCP protocol fallback, FTP/FTPS, S3, WebDAV
- Directory synchronization ("sync browsing" / folder comparison)
- Multiple windows / tabs for several simultaneous servers — v1 manages
  exactly **one active connection per window**; switching sessions
  disconnects the previous connection (after confirmation if transfers
  are running)
- App Store / sandbox
- Scripting/CLI automation

## Noted for v2

- **Multiple simultaneous servers via tabs/windows** — confirmed by the
  maintainer (2026-07-09). Architecture note for v1: build nothing that
  assumes a single global connection — connection/session belongs on the
  window or tab object, not in an app-wide singleton.

## Open items

- **Notarization:** needs an Apple Developer account (€99/year). Unsigned
  dev builds until M6; decision at the release milestone.
- **Competitor check:** web research on whether a comparable native
  open-source project exists is still outstanding (the search service was
  unavailable during the session; as of January 2026: nothing notable in
  the niche).
- **README convention:** project description/tagline benefit-oriented
  without stack details; technical details starting from the Contributing
  section (interpretation of the maintainer's global convention).
