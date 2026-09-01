# macSCP M3d — ssh-config Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Read-only import from `~/.ssh/config`: existing hosts (Host/HostName/User/Port/IdentityFile) appear as their own sidebar section and fill the connection form on click — the last M3 building block.

**Architecture:** `SSHConfigParser` (Core, pure): block parser for `Host` entries (keywords case-insensitive, `=` or whitespace separator, comments, quotes, multiple aliases per Host line; wildcard/negation patterns and `Match`/`Include` are skipped — documented YAGNI boundaries). `SSHConfigImporter.load(path:)` reads the file (missing → `[]`, alias-sorted). The sidebar gets an "IMPORTED" section; clicking fills the form (key path → SSH key mode), but deliberately does NOT connect (import knows no secrets). Beforehand: host-casing normalization in `KnownHostsStore` (M3c review: import casing must not miss pinned keys).

**Dependency graph:** `[ Task 0 (casing, Core) ∥ Task 1 (parser+importer, Core) ] → Task 2 (sidebar+form fill, UI) → Task 3 (wrap-up)` — T0∥T1 file-disjoint (worktree).

## Global Constraints

- swift-tools-version 6.0, Language Mode v5; macOS 14; UI text German; Conventional Commits with footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; never push (the coordinator does that)
- **The user's real `~/.ssh/config` is NEVER written to** — import is strictly read-only; tests exclusively use temp files
- The import click does NOT auto-connect (no secrets present); it only fills the form
- YAGNI: no `Match`, no `Include`, no wildcard inheritance (`Host *` blocks are skipped entirely), no import editor, no persistence of imported hosts into sessions.json
- After every task: `swift test` green

## File Map (Delta M3d)

```
Sources/macSCPCore/
  Sessions/KnownHostsStore.swift     (Task 0 — Host lowercased in find/upsert)
  Sessions/SSHConfigParser.swift     (new, Task 1 — parser + SSHConfigHost + importer)
Sources/MacSCPApp/
  SessionSidebar.swift               (Task 2 — IMPORTED section)
  ContentView.swift                  (Task 2 — load importedHosts + fillFromImported)
Tests/macSCPCoreTests/
  KnownHostsStoreTests.swift         (Task 0 +2)
  SSHConfigParserTests.swift         (new, Task 1 — 9 tests)
```

---

### Task 0: Host-casing normalization in KnownHostsStore

**Files:**
- Modify: `Sources/macSCPCore/Sessions/KnownHostsStore.swift`
- Test: `Tests/macSCPCoreTests/KnownHostsStoreTests.swift` (+2)

**Interfaces:** no API change. Invariant: `find`/`upsert` treat the host case-insensitively (stored lowercased) — a host "Web.Example.COM" imported via ssh-config matches the manually pinned key of "web.example.com".

**Parallel note:** disjoint from Task 1 — worktree.

- [x] **Step 1: Failing tests** — add to `KnownHostsStoreTests`:

```swift
    @Test func findIsCaseInsensitiveOnHost() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.upsert(key)   // host: "example.com"
        #expect(try store.find(host: "EXAMPLE.com", port: 22) == key)
    }

    @Test func upsertNormalizesHostCasing() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.upsert(KnownHostKey(
            host: "Server.Example.COM", port: 22,
            keyType: "ssh-ed25519", publicKeyBase64: "QUJDREVG"))
        let found = try store.find(host: "server.example.com", port: 22)
        #expect(found?.host == "server.example.com")
    }
```

Run: `swift test --filter KnownHostsStoreTests` — both FAIL.

- [x] **Step 2: Implement** — in `KnownHostsStore`:

1. `KnownHostKey.init` normalizes: `self.host = host.lowercased()` (doc comment: "Host is stored lowercased — comparisons are case-insensitive."). NOTE: `host` is `let` — normalizing in the init is the only write site, which is sufficient.
2. `find(host:port:)`: compare against `host.lowercased()`.
3. `upsert`: the `removeAll` comparison likewise via lowercased (covered by init normalization of `key.host` + lowercased comparison — both sides normalize).

- [x] **Step 3: Green** — filtered suite (6), full suite (base + 2 on the own branch). Check that the three gated TOFU tests still compile unchanged (they use "127.0.0.1" — casing-neutral).
- [x] **Step 4: Commit** — `fix: normalize host casing in known hosts store` (with footer).

---

### Task 1: SSHConfigParser + Importer

**Files:**
- Create: `Sources/macSCPCore/Sessions/SSHConfigParser.swift`
- Test: `Tests/macSCPCoreTests/SSHConfigParserTests.swift`

**Interfaces:**
- Produces (for Task 2):

```swift
public struct SSHConfigHost: Equatable, Sendable {
    public let alias: String
    public let hostName: String?     // nil → consumer falls back to alias
    public let user: String?
    public let port: Int?            // nil when missing OR non-numeric
    public let identityFile: String? // unchanged (including "~"), loader expands it
}

public enum SSHConfigParser {
    public static func parse(_ text: String) -> [SSHConfigHost]
}

public enum SSHConfigImporter {
    public static var defaultPath: String   // ~/.ssh/config
    /// Missing/unreadable file → [] (import is optional, never an error).
    public static func load(path: String) -> [SSHConfigHost]   // alias-sorted (case-insensitive)
}
```

**Parser rules (contract):** keywords case-insensitive; separator whitespace OR `=`; `#` comments (whole line and line remainder); values optionally in double quotes; `Host a b c` produces THREE entries with shared settings; aliases with a `*`, `?`, or `!` prefix are skipped; keywords before the first `Host` are ignored; only the FIRST value of a keyword per block counts (ssh behavior); `Match` blocks end the current host block and are ignored up to the next `Host`.

**Parallel note:** disjoint from Task 0 — worktree.

- [x] **Step 1: Failing tests**

`Tests/macSCPCoreTests/SSHConfigParserTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("SSHConfigParser")
struct SSHConfigParserTests {
    @Test func parsesFullBlock() {
        let hosts = SSHConfigParser.parse("""
        Host web
            HostName server.example.com
            User tim
            Port 2222
            IdentityFile ~/.ssh/id_ed25519
        """)
        #expect(hosts == [SSHConfigHost(
            alias: "web", hostName: "server.example.com", user: "tim",
            port: 2222, identityFile: "~/.ssh/id_ed25519")])
    }

    @Test func keywordsAreCaseInsensitiveAndEqualsSeparatorWorks() {
        let hosts = SSHConfigParser.parse("""
        HOST web
            hostname=server.example.com
            USER = tim
        """)
        #expect(hosts.first?.hostName == "server.example.com")
        #expect(hosts.first?.user == "tim")
    }

    @Test func commentsAndBlankLinesAreIgnored() {
        let hosts = SSHConfigParser.parse("""
        # global comment

        Host web   # line-remainder comment
            HostName server.example.com  # another one
        """)
        #expect(hosts == [SSHConfigHost(
            alias: "web", hostName: "server.example.com", user: nil,
            port: nil, identityFile: nil)])
    }

    @Test func multipleAliasesShareSettings() {
        let hosts = SSHConfigParser.parse("""
        Host backup mirror
            HostName backup.example.com
        """)
        #expect(hosts.map(\.alias) == ["backup", "mirror"])
        #expect(hosts.allSatisfy { $0.hostName == "backup.example.com" })
    }

    @Test func wildcardAndNegationAliasesAreSkipped() {
        let hosts = SSHConfigParser.parse("""
        Host *
            ServerAliveInterval 60
        Host web !intern web-?
            HostName server.example.com
        """)
        #expect(hosts.map(\.alias) == ["web"])
    }

    @Test func invalidPortYieldsNil() {
        let hosts = SSHConfigParser.parse("""
        Host web
            Port zweiundzwanzig
        """)
        #expect(hosts.first?.port == nil)
    }

    @Test func quotedValuesAreUnquoted() {
        let hosts = SSHConfigParser.parse("""
        Host web
            IdentityFile "~/.ssh/mein key"
        """)
        #expect(hosts.first?.identityFile == "~/.ssh/mein key")
    }

    @Test func firstValueWinsAndMatchBlocksAreIgnored() {
        let hosts = SSHConfigParser.parse("""
        Host web
            HostName erster.example.com
            HostName zweiter.example.com
        Match user tim
            HostName match.example.com
        Host zweiter
            HostName b.example.com
        """)
        #expect(hosts.map(\.alias) == ["web", "zweiter"])
        #expect(hosts.first?.hostName == "erster.example.com")
    }

    @Test func importerReturnsEmptyForMissingFileAndSortsByAlias() throws {
        #expect(SSHConfigImporter.load(
            path: "/tmp/macscp-keine-config-\(UUID().uuidString)") == [])

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-sshconf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config")
        try """
        Host zeta
            HostName z.example.com
        Host Alpha
            HostName a.example.com
        """.write(to: file, atomically: true, encoding: .utf8)

        let hosts = SSHConfigImporter.load(path: file.path(percentEncoded: false))
        #expect(hosts.map(\.alias) == ["Alpha", "zeta"])
    }
}
```

- [x] **Step 2: Red** — compile error (`SSHConfigParser` unknown)

- [x] **Step 3: Implement**

`Sources/macSCPCore/Sessions/SSHConfigParser.swift`:

```swift
import Foundation

/// Ein importierter Host aus ~/.ssh/config (nur die für macSCP relevanten Felder).
public struct SSHConfigHost: Equatable, Sendable {
    public let alias: String
    public let hostName: String?
    public let user: String?
    public let port: Int?
    public let identityFile: String?

    public init(alias: String, hostName: String?, user: String?,
                port: Int?, identityFile: String?) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
    }
}

/// Purer Parser für das OpenSSH-config-Format (lesend, YAGNI-Grenzen:
/// kein Match/Include, keine Wildcard-Vererbung — solche Blöcke werden übersprungen).
public enum SSHConfigParser {
    public static func parse(_ text: String) -> [SSHConfigHost] {
        var blocks: [(aliases: [String], settings: [String: String])] = []
        var inIgnoredBlock = false   // Match-Block o.ä.

        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine
            if let hash = line.firstIndex(of: "#") {
                line = String(line[..<hash])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            guard let (keyword, value) = splitKeywordValue(line) else { continue }
            switch keyword.lowercased() {
            case "host":
                inIgnoredBlock = false
                let aliases = value.split(separator: " ").map(String.init)
                blocks.append((aliases: aliases, settings: [:]))
            case "match":
                inIgnoredBlock = true
            default:
                guard !inIgnoredBlock, !blocks.isEmpty else { continue }
                let key = keyword.lowercased()
                // ssh-Semantik: der erste Wert gewinnt
                if blocks[blocks.count - 1].settings[key] == nil {
                    blocks[blocks.count - 1].settings[key] = unquote(value)
                }
            }
        }

        var results: [SSHConfigHost] = []
        for block in blocks {
            for alias in block.aliases {
                guard !alias.contains("*"), !alias.contains("?"),
                      !alias.hasPrefix("!") else { continue }
                results.append(SSHConfigHost(
                    alias: alias,
                    hostName: block.settings["hostname"],
                    user: block.settings["user"],
                    port: block.settings["port"].flatMap(Int.init),
                    identityFile: block.settings["identityfile"]
                ))
            }
        }
        return results
    }

    /// Trennt "Keyword Wert" bzw. "Keyword=Wert" (mit beliebigem Whitespace um '=').
    private static func splitKeywordValue(_ line: String) -> (String, String)? {
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "="))
        guard let range = line.rangeOfCharacter(from: separators) else { return nil }
        let keyword = String(line[..<range.lowerBound])
        var value = String(line[range.lowerBound...])
        value = value.trimmingCharacters(in: separators)
        guard !keyword.isEmpty, !value.isEmpty else { return nil }
        return (keyword, value)
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }
}

/// Lädt und sortiert die importierbaren Hosts. Fehlende Datei ist kein Fehler.
public enum SSHConfigImporter {
    public static var defaultPath: String {
        NSHomeDirectory() + "/.ssh/config"
    }

    public static func load(path: String) -> [SSHConfigHost] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        return SSHConfigParser.parse(text).sorted {
            $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending
        }
    }
}
```

- [x] **Step 4: Green** — filtered suite (9 PASS), full suite (base + 9).
- [x] **Step 5: Commit** — `feat: parse and import ssh config hosts` (with footer).

---

### Task 2: Sidebar section + form fill

**Files:**
- Modify: `Sources/MacSCPApp/SessionSidebar.swift`
- Modify: `Sources/MacSCPApp/ContentView.swift`

**Interfaces:** consumes Task 1. `SessionSidebar` gets `importedHosts: [SSHConfigHost]` and `onSelectImported: (SSHConfigHost) -> Void`. Click fills the form and does NOT connect.

No unit test (UI wiring; parser/importer are Core-tested); verification: build + suite + headless launch check; visual in Task 3.

- [x] **Step 1: Sidebar** — in `SessionSidebar`:

1. Add properties (after `viewModel`): `let importedHosts: [SSHConfigHost]` and (after `onDelete`) `let onSelectImported: (SSHConfigHost) -> Void`.
2. In the `List`, add AFTER the Sessions `ForEach`:

```swift
                if !importedHosts.isEmpty {
                    Section {
                        ForEach(importedHosts, id: \.alias) { host in
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.down.doc")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(host.alias)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { onSelectImported(host) }
                            .help("Aus ~/.ssh/config — füllt das Formular (Geheimnisse werden nicht importiert)")
                        }
                    } header: {
                        Text("IMPORTIERT")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
```

- [x] **Step 2: ContentView** —

1. State: `@State private var importedHosts: [SSHConfigHost] = []`
2. At the `SessionSidebar` call site, add the new arguments (match the order to the property declaration) + attach to the `HSplitView` (or the outer container):

```swift
        .task { importedHosts = SSHConfigImporter.load(path: SSHConfigImporter.defaultPath) }
```

3. Private method:

```swift
    /// Import-Klick: Formular aus dem ssh-config-Eintrag füllen — bewusst
    /// OHNE Verbinden (der Import kennt keine Geheimnisse).
    private func fillFromImported(_ host: SSHConfigHost) {
        guard !isReconnecting else { return }
        Task {
            await teardownSession()
            connectionViewModel.host = host.hostName ?? host.alias
            connectionViewModel.port = String(host.port ?? 22)
            connectionViewModel.username = host.user ?? ""
            connectionViewModel.saveName = host.alias
            connectionViewModel.shouldSaveSession = false
            if let identityFile = host.identityFile {
                connectionViewModel.authChoice = .privateKey
                connectionViewModel.keyPath = identityFile
            } else {
                connectionViewModel.authChoice = .password
                connectionViewModel.keyPath = ""
            }
        }
    }
```

(`onSelectImported: { fillFromImported($0) }` on the sidebar.)

- [x] **Step 3: Green** — `swift build && swift test` (base unchanged), headless launch check.
- [x] **Step 4: Commit** — `feat: import ssh config hosts into the sidebar` (with footer).

---

### Task 3: Final verification

- [x] **Step 1:** `swift test` — 126 total (115 + 2 T0 + 9 T1)
- [x] **Step 2:** rig up (MAIN checkout), `MACSCP_ITEST=1` 10/10, `MACSCP_KEYCHAIN=1` 2/2, rig down
- [x] **Step 3: Visual smoke test** (coordinator): CHECK whether `~/.ssh/config` exists (read only!); if yes: the IMPORTED section shows the aliases; clicking an entry → form filled (host/port/user/key mode + path as applicable), NO automatic connection, NO prompt; if the user has no config: the section stays hidden (also correct — document what was present). The real file is NEVER modified under any circumstances.
- [x] **Step 4:** checkboxes, commit `docs: mark M3d plan tasks as completed` (with footer)

## Outlook

M3d completes **Milestone M3 (Sessions) COMPLETELY** — the entire connection manager from the spec. After that: **M4 Terminal** (a SwiftTerm panel per connection — the largest missing design element), M5 transfer queue, M6 release (app icon, design polish, notarized DMG). Left open from M3: the cancellation handler on the prompt continuation (M4 opening), ssh-agent/RSA (optional M3e).
