# Session Overview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A single click on a stored session shows a read-only overview
of it in the detail area — facts, Connect / Edit / Diagnose, the recent
connections from the audit log, the snippets with Run — that keeps
working when the window is resized.

**Architecture:** Core gains `SessionOverviewModel` (pure derivation
from the stored record, the known-host key, the audit events and the
snippets; a `SecretPresence` seam for "a secret is stored"), one new
`AuditEvent.Kind.connectFailed`, and `ConnectionHistory` (the audit
events paired into rows). The App gains `SessionOverviewView` (pinned
head + `ScrollView`, `ViewThatFits` for the actions and the facts,
adaptive grid for snippets) and the wiring: the sidebar's selection
reaches the active not-connected tab's detail area, the three actions
reuse `connectFromSidebar`, `editStored`, `showDiagnostics(for:
.stored)`, Run reuses the connect effect then `runSnippet`. Guards
follow `DiagnosticsDoorsGuardTests` and `ConnectionFormScrollGuardTests`.

**Tech Stack:** Swift 6 strict, SwiftUI (macOS 15), Swift Testing,
`AuditLogStore`, `KnownHostsStore`, `SnippetStore`, the keychain
metadata query.

**Spec:** `docs/superpowers/specs/2026-09-04-session-overview-design.md`
(mockup: artifact 29db6db2). Scheduled after `macscp-cli diagnose`.

## Global Constraints

- English only in the tree; user-facing strings only via `L10n.string` in all four catalogs (`en`, `de`, `fr`, `pl`; German du); Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; commit per task; zero warnings; do not push.
- No secret value in any view, model, log, audit row or failure message: the overview learns only WHETHER a secret is stored, through a metadata-only keychain query behind the `SecretPresence` seam; tests use a fake; the keychain is never read in tests (`MACSCP_KEYCHAIN` stays gated).
- No new way to connect, edit or diagnose: the overview's three actions are the sidebar's existing effects handed over as values (`SessionRowConnectEffect` discipline — read `SessionRowActivation.swift`'s doc); a guard proves the three call sites resolve to `connectFromSidebar`, `editStored`, `showDiagnostics(for: .stored`.
- Red first; no `#require` on a non-optional; no wall-clock ceiling; tests never block the pool; every wait through `pollUntil` under a suite `.timeLimit`.
- A negative source-scanning check needs a positive check beside it; comments quoting code near an anchor move the anchor; a number in a comment is counted; comments naming callers checked (`connectFromSidebar`, `editStored`, `runSnippet` each gain a caller).
- Responsive: the head (name, actions) sits outside the `ScrollView`, the rest inside; the actions row is a `ViewThatFits`; the facts a two-column `Grid` with a one-column fallback in a `ViewThatFits`; the snippets a `LazyVGrid` with `.adaptive(minimum: 260)`; the detail pane's minimum width unchanged.
- Do NOT launch the GUI app; the dev build is the maintainer's check.

---

### Task 1: Core — `ConnectionHistory`, `connectFailed`, `SessionOverviewModel`

**Files:**
- Modify: `Sources/macSCPCore/Sessions/AuditEvent.swift` (`case connectFailed` in `Kind`; the audit sheet's `switch` in `Sources/MacSCPAppKit/AuditLogSheet.swift:259` gains the case with its own icon/text keys — four catalogs)
- Create: `Sources/macSCPCore/Sessions/ConnectionHistory.swift`
- Create: `Sources/macSCPCore/Presentation/SessionOverviewModel.swift`
- Create: `Sources/macSCPCore/Sessions/SecretPresence.swift` (protocol + `KeychainSecretPresence` using a metadata-only `SecItemCopyMatching` — no `kSecReturnData` — the shape in `CyberduckSecretReader`)
- Test: `Tests/macSCPCoreTests/ConnectionHistoryTests.swift`, `Tests/macSCPCoreTests/SessionOverviewModelTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct ConnectionHistory: Sendable, Equatable {
      public struct Row: Sendable, Equatable, Identifiable {
          public enum Outcome: Sendable, Equatable { case connected(duration: Duration?), failed(reason: String) }
          public let id: UUID            // the connected/connectFailed event's id
          public let startedAt: Date
          public let outcome: Outcome
          public let uploads: Int, downloads: Int, failedTransfers: Int, bytes: Int64?
      }
      /// Pairs `connected` … `disconnected`, counts transfers between them, keeps the last `limit`, newest first.
      /// An unpaired trailing `connected` is `.connected(duration: nil)` (still open).
      public static func rows(from events: [AuditEvent], limit: Int = 10, now: Date = Date()) -> [Row]
  }

  public protocol SecretPresence: Sendable { func hasSecret(for slot: UUID) -> Bool }

  public struct SessionOverviewModel: Sendable, Equatable {
      public struct Fact: Sendable, Equatable, Identifiable { public let id: String; public let labelKey: String; public let text: String; public let isMonospaced: Bool }
      public let name: String, kind: ConnectionKind, endpointText: String
      public let facts: [Fact]                       // per kind, in the spec's order
      public let hostKey: HostKeyStatus             // .known(type, fingerprint) | .unknown | .notApplicable
      public let hasStoredSecret: Bool?              // nil when the kind needs none (agent auth)
      public let history: [ConnectionHistory.Row]
      public let snippets: [Snippet]
      public init(session: StoredSession, descriptor: BackendDescriptor, knownKey: KnownHostKey?,
                  secrets: any SecretPresence, events: [AuditEvent], snippets: [Snippet], now: Date = Date())
  }
  ```
- Consumes: `StoredSession` (`secretSlot`, `ssh`/`s3`/`webdav`, `tags`, `groupID`, `importSource`, `importedAt`, `paneVisibility`), `BackendDescriptor.endpoint(_:)` / `sessionValues(_:)` / `editBaseline`, `KnownHostKey` (`Sources/macSCPCore/Sessions/KnownHostsStore.swift:62`), `AuditEvent` (`kind`, `timestamp`, `detail`, `isError`), `Snippet`.

- [x] **Step 1: Red first** — `ConnectionHistoryTests`: two paired sessions with three transfers between → two rows with the right sums, newest first; an unpaired trailing `connected` → duration nil; a `connectFailed` → `.failed(reason:)`; eleven pairs → ten rows. `SessionOverviewModelTests`: an SSH session with key auth → facts user, auth "key file <path>", jump; `hasStoredSecret` from the fake (`true`/`false`), `nil` for agent auth; an S3 session's endpoint text from the descriptor; the WebDAV base URL; `hostKey` `.known` from a fixture key, `.unknown` from `nil`, `.notApplicable` for S3/WebDAV; NO fact text ever equals a planted secret constant (Bools first). Run: red on missing types.
- [x] **Step 2: Implement** the four files; `swift test --filter "ConnectionHistory|SessionOverviewModel"` green; full `swift test`; zero warnings.
- [x] **Step 3: Commit** `feat(sessions): the overview model derives facts, history and snippets from what is stored`.

---

### Task 2: App — `SessionOverviewView`, wired to the sidebar and the tab

**Files:**
- Create: `Sources/MacSCPAppKit/SessionOverviewView.swift`
- Modify: `Sources/MacSCPAppKit/ContentView+Detail.swift` (~:700: when the active tab is not connected AND the sidebar's selection names a stored session, show `SessionOverviewView`; else the form as today), `Sources/MacSCPAppKit/SessionSidebar.swift` (expose the selection through a binding or `onSelect` callback to `ContentView` — read how `selectedSessionID` is owned at `:293` and `:450`; the new-connection row clears it), `Sources/MacSCPAppKit/ContentView.swift` (the audit hook: `connectFailed` appended where the connect failure is handled — find the one place `ConnectFailurePlan` is reached; the reason via `DialSupport.reason(for:)` — check its access level, expose if `internal`)
- Modify: the four `Localizable.strings` under `Sources/MacSCPAppKit/Resources/*.lproj/` (labels: overview.*)
- Test: `Tests/MacSCPAppKitTests/SessionOverviewWiringGuardTests.swift` (positive: the detail branch names `SessionOverviewView(`; the three action closures call `connectFromSidebar`, `editStored`, `showDiagnostics(for: .stored`; negative: no `Button(` in the overview file calls anything else that connects — enumerate the connect-capable functions from `SessionRowActivation.swift`'s doc; head outside the `ScrollView`, `ViewThatFits(` present twice, `LazyVGrid(` present; catalogue-key set equality with `en.lproj` for the `overview.` keys in all four catalogs)

**Interfaces:**
- Consumes: Task 1's model; `connectFromSidebar(_:)` (`ContentView.swift:1632`), `editStored(_:)`, `showDiagnostics(for:)` (`ContentView+Diagnostics.swift`), `KnownHostsStore.find(host:port:)`, `AuditLogStore.events(for:)`, the snippet store the terminal's snippet menu reads (find it), `KeychainSecretPresence`.
- Produces: the overview on screen; the `connectFailed` audit row.

- [x] **Step 1: Red first** — the guard file with its scans against the tree: red (no `SessionOverviewView`).
- [x] **Step 2: Implement** view, wiring, catalogs; `swift test` green; zero warnings; the existing sidebar guards (`SessionSidebarErrorGuardTests`, `TabContextMenuWiringGuardTests`, `ConnectionFormScrollGuardTests`) still green.
- [x] **Step 3: Commit** `feat(sidebar): a click shows the session's overview — facts, history, snippets, three actions`.

---

### Task 3: Run a snippet from the overview

**Files:**
- Modify: `Sources/MacSCPAppKit/SessionOverviewView.swift` (Run per snippet), `Sources/MacSCPAppKit/ContentView.swift` (`runSnippetAfterConnecting(_:on:)`: `connectFromSidebar`, then wait for the tab's terminal to be open — the tab's own state, through the liveness/terminal view model, no clock — then `runSnippet(_:execute:values:)`; a failed connect stops, the failed-connect surface shows)
- Test: `Tests/macSCPCoreTests/` or `Tests/MacSCPAppKitTests/` — whichever holds `runSnippet`'s tests: a sequence test on the view-model level (connect success → terminal open → send once; connect failure → nothing sent), and the guard's action list extended by `runSnippet`.

- [x] **Step 1: Red first** — the sequence test against a stub connect that fails → the fake terminal received nothing; against one that succeeds → exactly one send.
- [x] **Step 2: Implement**; green; zero warnings.
- [x] **Step 3: Commit** `feat(snippets): Run from the session overview connects, opens the terminal and sends`.

---

### Task 4: Closeout

**Files:**
- Modify: `docs/BACKLOG.md` (Done row: commits, what a click shows, the responsive split, what stays open — the dev-build sight check), `README.md` (one sentence in the sessions section), the plan's checkboxes.

- [x] **Step 1:** the row and the sentence; count the guard's checks and the model tests.
- [x] **Step 2: Commit** `docs: the session overview is in`.
