# Connection Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One diagnostics surface behind three doors (tab, session
context menu, error dialog) that runs the universal probes — resolve,
TCP ping, ICMP echo, the app's own dial timings, an IPv4 network trace —
then the protocol's own probe through the descriptor seam, and renders
one copyable report. Design: `docs/superpowers/specs/2026-09-02-connection-tools-design.md`;
decisions of 2026-09-02: diagnostics run only when the user presses the
button, never automatically; "Copy report" offers plain text and
Markdown as two menu entries. Spike verdicts (2026-09-03, macOS 26.6.2,
design §5): unprivileged ICMP DGRAM sockets deliver echo replies on
IPv4 and IPv6 and the identifier was NOT rewritten there (pin the
sequence, accept either identifier); IPv4 time-exceeded arrives on the
same socket for a TTL-limited UDP probe; IPv6 trace unmeasured (no
route) — the row degrades to "no IPv6 route" and never pretends.

**Architecture:** Core gains `Diagnostics/` with `DiagnosticStep`,
`DiagnosticReport`, `ConnectionDiagnostics` (the universal runner, every
step an `async` function with a deadline, cancellable, no credential
touched), `ICMPEcho` and `NetworkTrace` (Darwin sockets on a private
`DispatchQueue`, awaited through continuations — never a blocking read
on the cooperative pool, in Sources as in Tests). `BackendDescriptor`
gains `endpoint: @Sendable (FieldValues) -> Endpoint?` and
`diagnostics: [DiagnosticContribution]` beside `fileActions`. The App
renders `DiagnosticsPanel` from a `DiagnosticsViewModel` owned by the
window scope (never a singleton). Tests dial only loopback, the Docker
rig and TEST-NET-1 with TTL 1.

**Tech Stack:** Swift 6, Darwin sockets, `getaddrinfo`, Swift Testing;
rig `MACSCP_ITEST=1`; the socket tests are gated `MACSCP_NETSPIKE=1`
where they leave loopback (the TTL-1 probe).

## Global Constraints

- English only; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; commit per task; zero warnings; do not push.
- No packet leaves the local network in a test: loopback, the rig on `127.0.0.1`, and `192.0.2.1` with `IP_TTL=1`. Never a real remote host.
- No blocking wait on the cooperative pool, in Sources or Tests: socket reads run on a `DispatchQueue` created for them and are awaited through a continuation with a deadline.
- The universal half never authenticates and never reads a secret; a contribution authenticates only through the same resolver the connect uses.
- Every display string through `L10n.string(_:_:)`; four catalogs `en`/`de`/`fr`/`pl` in the App target (and Core's where a Core message is user-facing); German du.
- Guards: a negative check has a positive anchor; scanners read the `SwiftSource` stripped views (`Tests/macSCPAppKitTests/SwiftSourceStripping.swift`); a symbol a guard could read is not spelled.
- No code path in the universal half branches on `ConnectionKind`.

---

### Task 1: The report, the runner, the seam

**Files:**
- Create: `Sources/macSCPCore/Diagnostics/DiagnosticStep.swift`, `DiagnosticReport.swift`, `ConnectionDiagnostics.swift`, `Resolver.swift` (getaddrinfo on a queue), `TCPPing.swift`
- Modify: `Sources/macSCPCore/Capabilities/BackendDescriptor.swift` (`endpoint`, `diagnostics`), `BackendContributions.swift` (`DiagnosticContribution`)
- Test: `Tests/macSCPCoreTests/ConnectionDiagnosticsTests.swift`, `BackendDescriptorEndpointTests.swift`

**Interfaces (produced):**
```swift
public struct Endpoint: Sendable, Equatable { public let host: String; public let port: Int }
public enum DiagnosticOutcome: Sendable, Equatable { case ok, failed(String), timedOut, unavailable(String), skipped(String) }
public struct DiagnosticStep: Sendable, Equatable, Identifiable {
    public let id: String            // "resolve", "tcp", "icmp", "dial", "trace", or a contribution id
    public let titleKey: String
    public let started: Date
    public let duration: Duration
    public let outcome: DiagnosticOutcome
    public let detail: String        // one line, already localized where user-facing
}
public struct DiagnosticReport: Sendable, Equatable {
    public let endpoint: Endpoint
    public let steps: [DiagnosticStep]
    public let appVersion: String
    public func plainText() -> String
    public func markdown() -> String
}
public struct DiagnosticContribution: Sendable, Identifiable {
    public let id: String
    public let titleKey: String
    public let run: @Sendable (FieldValues, SecretSource?) async -> DiagnosticStep
}
public actor ConnectionDiagnostics {
    public init(descriptor: BackendDescriptor, values: FieldValues, secrets: SecretSource?, stepTimeout: Duration = .seconds(5))
    public func run() async -> DiagnosticReport     // cancellable through the calling Task
}
```
Steps in order: resolve (A and AAAA, every address listed, the time), TCP ping (one attempt per address, `accepted` / `refused` / `timedOut` with RTT; the first `accepted` decides the step's outcome), dial (the backend's own connect as one step through the existing connect funnel WITHOUT authentication where the backend allows — SSH: transport + KEX only is not exposed by Citadel, so the SSH dial step is the full connect with the session's credentials through the same resolver, named honestly "SSH connect"; S3: an unsigned `HEAD` on the bucket endpoint; WebDAV: `OPTIONS`), then the contributions.

- [x] Red first: `ConnectionDiagnosticsTests` — resolve `localhost` (both families present or the one the machine has); TCP ping to the rig's sshd `127.0.0.1:2222` accepted under `MACSCP_ITEST=1`, to a closed loopback port refused (bind a socket, close it, probe the port), to `192.0.2.1:22` timed out inside the step timeout (gated `MACSCP_NETSPIKE=1` — the SYN dies at the first hop); cancellation mid-run ends with the steps so far; `plainText()`/`markdown()` render every step once with duration and outcome; `BackendDescriptorEndpointTests` — every kind's `endpoint(of:)` from its field values (SSH host/port, S3 endpoint host + 443/80 per scheme, WebDAV URL host + port).
- [x] Implement; `swift test` green; commit `feat(diagnostics): resolve, TCP ping and the dial as one report, behind the descriptor seam` (`8997c955`; fix round 1 `ea9ea544`; fix round 2 `64854401`; the wall-clock ceiling drop `35e456da`).

### Task 2: ICMP echo, from the spike's verdict

**Files:**
- Create: `Sources/macSCPCore/Diagnostics/ICMPEcho.swift`
- Modify: `ConnectionDiagnostics.swift` (the `icmp` step: three probes, min/avg/max RTT; IPv6 when the resolve step found an AAAA and a route exists — else `.unavailable("no IPv6 route")`)
- Test: `Tests/macSCPCoreTests/ICMPEchoTests.swift`

- [x] Red first: echo to `127.0.0.1` and `::1` — a reply inside 2 s with the sent sequence; the identifier is accepted whether rewritten or not (the test asserts on sequence only and records the identifier); a socket error (simulate with an invalid family) yields `.unavailable` with the `strerror`, never a throw out of the step; three probes produce three RTTs.
- [x] Implement per `Tests/macSCPCoreTests/ICMPSpikeTests.swift`'s measured code shape (DGRAM socket, IPv4 delivers the IP header — skip `ihl*4` bytes; IPv6 does not; the ICMPv6 socket also delivers the process's own type-128 request — filter to type 129); commit `feat(diagnostics): ICMP echo without privileges` (`1f525642`; fix round 1 `42a730e7` — the payload marker + per-socket nonce, from the measured finding that an unprivileged ICMP socket receives every process's replies; fix round 2 `ae0be51f`).

### Task 3: Network trace, IPv4

**Files:**
- Create: `Sources/macSCPCore/Diagnostics/NetworkTrace.swift`
- Modify: `ConnectionDiagnostics.swift` (the `trace` step; IPv6 → `.unavailable("IPv6 trace unmeasured: no route on the machine that measured it")` until measured)
- Test: `Tests/macSCPCoreTests/NetworkTraceTests.swift`

- [x] Red first (gated `MACSCP_NETSPIKE=1`): a TTL-1 UDP probe to `192.0.2.1:33434` yields hop 1 with an address and an RTT from the ICMP type-11 message on the DGRAM socket; the trace stops at the first `.timedOut` hop after `maxHops` (default 30, test uses 1) or at the destination's port-unreachable (type 3) — the destination case is exercised against `127.0.0.1:33434` (loopback answers port unreachable at hop 1). Per-hop deadline 1 s; the step's total deadline is the runner's.
- [x] Implement (one UDP socket per probe with `IP_TTL`, one ICMP DGRAM socket receiving; match by the quoted UDP header's destination port); commit `feat(diagnostics): an IPv4 network trace on unprivileged sockets` (`d4e2e8e9`; fix round 1 `1a4573a1` — the trace's own 20 s budget, separate from the step timeout; fix round 2 `4456836d` — honest endings for a refusal and a hop-limit reached).

### Task 4: Three doors and the panel

**Files:**
- Create: `Sources/MacSCPAppKit/Presentation/DiagnosticsViewModel.swift` (`@MainActor @Observable`: `run()`, `cancel()`, `report`, `isRunning`, `copyPlainText()`, `copyMarkdown()`), `Sources/MacSCPAppKit/DiagnosticsPanel.swift`
- Modify: the tab's detail view (toolbar item "Diagnose…" when connected; a "Diagnose…" button beside the failed-connect surface), the session context menu, the connect error dialog; four App catalogs
- Test: `Tests/macSCPAppKitTests/DiagnosticsViewModelTests.swift` (run/cancel/report on a fake runner; both copy shapes reach the pasteboard abstraction the app uses), `DiagnosticsDoorsGuardTests.swift` (the three doors wire the same view model entry; the panel never runs on appear — a `.onAppear { …run }` in the panel or its doors is the planted violation; "Copy report" is a `Menu` with two entries; all reads on `SwiftSource` views with positive anchors)

- [x] Red first, implement, `swift test --filter Localiz` and `GermanAddressForm`, full suite green; commit `feat(diagnostics): one panel behind the tab, the session menu and the error dialog` (`9d232320`; fix round 1 `01ee5218` — cancel on sheet close and tab teardown; fix round 2 `bf3b3bd4` — incremental publishing, a diagnosis bound to the tab that opened it; fix round 3 `287d4d2d`; fix round 4 `d6cec28b` — `DiagnosticReport.Completion` so a cancelled report says so in its copied text).

### Task 5: First seam contributions — S3 access level, WebDAV OPTIONS

**Files:**
- Modify: `Sources/macSCPCore/Capabilities/BackendDescriptor.swift` (`s3Descriptor.diagnostics`, `webdavDescriptor.diagnostics`), `Sources/macSCPCore/S3/` (a signed `HeadBucket`, `ListObjectsV2` `MaxKeys=1`, `ListBuckets` probe returning status + `x-amz-request-id` per call), `Sources/macSCPCore/WebDAV/` (`OPTIONS` → `DAV:` class and `Allow`; `PROPFIND` depth 0 on the root)
- Test: `S3AccessProbeTests` against MinIO (`MACSCP_ITEST=1`: root key sees all three; the scoped user `macscp-scoped` sees the filtered list — the rig's measured behaviour, recorded in `2026-09-02-s3-bucket-browser-design.md`), `WebDAVOptionsProbeTests` against the rig's Apache.

- [x] Red first, implement, commit `feat(diagnostics): the S3 key's access level and the WebDAV server's claims, as contributions` (`5828610f`; a fix round follows under review). The SSH negotiation contribution is NOT in this plan (needs the fork's observer — backlog).

### Task 6: Closeout

- [x] `docs/superpowers/specs/2026-08-25-backlog-connection-tools.md` and the `docs/BACKLOG.md` row → Done with the commits; the design's §2.3/§2.5 "Unmeasured" wording replaced by the measured state; `docs/superpowers/specs/2026-09-02-backlog-maintainer-notes.md` item 18 (S3 access level) → Done. Commit `docs(backlog): connection tools shipped; SSH negotiation and the IPv6 trace stay open`.
