# macSCP M3d — ssh-config-Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lesender Import aus `~/.ssh/config`: bestehende Hosts (Host/HostName/User/Port/IdentityFile) erscheinen als eigene Sidebar-Sektion und füllen per Klick das Verbindungsformular — der letzte M3-Baustein.

**Architecture:** `SSHConfigParser` (Core, pur): Block-Parser für `Host`-Einträge (Keywords case-insensitiv, `=`- oder Whitespace-Trenner, Kommentare, Anführungszeichen, Mehrfach-Aliase pro Host-Zeile; Wildcard-/Negations-Muster und `Match`/`Include` werden übersprungen — dokumentierte YAGNI-Grenzen). `SSHConfigImporter.load(path:)` liest die Datei (fehlend → `[]`, alias-sortiert). Die Sidebar bekommt eine Sektion „IMPORTIERT"; Klick füllt das Formular (Key-Pfad → SSH-Key-Modus), verbindet aber bewusst NICHT (Import kennt keine Geheimnisse). Vorab: Host-Casing-Normalisierung im `KnownHostsStore` (M3c-Review: Import-Casing darf gepinnte Keys nicht verfehlen).

**Abhängigkeitsgraph:** `[ Task 0 (Casing, Core) ∥ Task 1 (Parser+Importer, Core) ] → Task 2 (Sidebar+Form-Fill, UI) → Task 3 (Abschluss)` — T0∥T1 dateidisjunkt (Worktree).

## Global Constraints

- swift-tools-version 6.0, Language Mode v5; macOS 14; UI-Texte Deutsch; Conventional Commits mit Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; niemals pushen (macht der Koordinator)
- **Die echte `~/.ssh/config` des Nutzers wird NIE geschrieben** — Import ist strikt lesend; Tests nutzen ausschließlich Temp-Dateien
- Import-Klick verbindet NICHT automatisch (keine Geheimnisse vorhanden); er füllt nur das Formular
- YAGNI: kein `Match`, kein `Include`, keine Wildcard-Vererbung (`Host *`-Blöcke werden komplett übersprungen), kein Import-Editor, keine Persistenz importierter Hosts in sessions.json
- Nach jedem Task: `swift test` grün

## Datei-Landkarte (Delta M3d)

```
Sources/macSCPCore/
  Sessions/KnownHostsStore.swift     (Task 0 — Host lowercased in find/upsert)
  Sessions/SSHConfigParser.swift     (neu, Task 1 — Parser + SSHConfigHost + Importer)
Sources/MacSCPApp/
  SessionSidebar.swift               (Task 2 — Sektion IMPORTIERT)
  ContentView.swift                  (Task 2 — importedHosts laden + fillFromImported)
Tests/macSCPCoreTests/
  KnownHostsStoreTests.swift         (Task 0 +2)
  SSHConfigParserTests.swift         (neu, Task 1 — 9 Tests)
```

---

### Task 0: Host-Casing-Normalisierung im KnownHostsStore

**Files:**
- Modify: `Sources/macSCPCore/Sessions/KnownHostsStore.swift`
- Test: `Tests/macSCPCoreTests/KnownHostsStoreTests.swift` (+2)

**Interfaces:** keine API-Änderung. Invariante: `find`/`upsert` behandeln den Host case-insensitiv (gespeichert wird lowercased) — ein via ssh-config importierter Host „Web.Example.COM" trifft den manuell gepinnten Key von „web.example.com".

**Parallel-Hinweis:** disjunkt zu Task 1 — Worktree.

- [ ] **Step 1: Fehlschlagende Tests** — in `KnownHostsStoreTests` ergänzen:

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

Run: `swift test --filter KnownHostsStoreTests` — beide FAIL.

- [ ] **Step 2: Implementieren** — in `KnownHostsStore`:

1. `KnownHostKey.init` normalisiert: `self.host = host.lowercased()` (Doc-Kommentar: „Host wird lowercased gespeichert — Vergleiche sind case-insensitiv."). ACHTUNG: `host` ist `let` — Normalisierung im Init ist der einzige Schreibpunkt, das genügt.
2. `find(host:port:)`: Vergleich gegen `host.lowercased()`.
3. `upsert`: `removeAll`-Vergleich ebenfalls über lowercased (durch Init-Normalisierung von `key.host` + lowercased-Vergleich abgedeckt — beide Seiten normalisieren).

- [ ] **Step 3: Grün** — Filter-Suite (6), Gesamtsuite (auf eigenem Branch Basis + 2). Prüfen, dass die drei gated TOFU-Tests unverändert kompilieren (sie nutzen „127.0.0.1" — casing-neutral).
- [ ] **Step 4: Commit** — `fix: normalize host casing in known hosts store` (mit Footer).

---

### Task 1: SSHConfigParser + Importer

**Files:**
- Create: `Sources/macSCPCore/Sessions/SSHConfigParser.swift`
- Test: `Tests/macSCPCoreTests/SSHConfigParserTests.swift`

**Interfaces:**
- Produces (für Task 2):

```swift
public struct SSHConfigHost: Equatable, Sendable {
    public let alias: String
    public let hostName: String?     // nil → Konsument fällt auf alias zurück
    public let user: String?
    public let port: Int?            // nil bei fehlend ODER nicht-numerisch
    public let identityFile: String? // unverändert (inkl. "~"), Loader expandiert
}

public enum SSHConfigParser {
    public static func parse(_ text: String) -> [SSHConfigHost]
}

public enum SSHConfigImporter {
    public static var defaultPath: String   // ~/.ssh/config
    /// Fehlende/unlesbare Datei → [] (Import ist optional, nie ein Fehler).
    public static func load(path: String) -> [SSHConfigHost]   // alias-sortiert (case-insensitiv)
}
```

**Parser-Regeln (Vertrag):** Keywords case-insensitiv; Trenner Whitespace ODER `=`; `#`-Kommentare (ganze Zeile und Zeilenrest); Werte optional in doppelten Anführungszeichen; `Host a b c` erzeugt DREI Einträge mit gemeinsamen Settings; Aliase mit `*`, `?` oder `!`-Präfix werden übersprungen; Keywords vor dem ersten `Host` werden ignoriert; nur der ERSTE Wert eines Keywords pro Block zählt (ssh-Verhalten); `Match`-Blöcke beenden den aktuellen Host-Block und werden bis zum nächsten `Host` ignoriert.

**Parallel-Hinweis:** disjunkt zu Task 0 — Worktree.

- [ ] **Step 1: Fehlschlagende Tests**

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
        # global Kommentar

        Host web   # Zeilenrest-Kommentar
            HostName server.example.com  # noch einer
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

- [ ] **Step 2: Rot** — Compile-Fehler (`SSHConfigParser` unbekannt)

- [ ] **Step 3: Implementieren**

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

- [ ] **Step 4: Grün** — Filter-Suite (9 PASS), Gesamtsuite (Basis + 9).
- [ ] **Step 5: Commit** — `feat: parse and import ssh config hosts` (mit Footer).

---

### Task 2: Sidebar-Sektion + Form-Fill

**Files:**
- Modify: `Sources/MacSCPApp/SessionSidebar.swift`
- Modify: `Sources/MacSCPApp/ContentView.swift`

**Interfaces:** Consumes Task 1. `SessionSidebar` bekommt `importedHosts: [SSHConfigHost]` und `onSelectImported: (SSHConfigHost) -> Void`. Klick füllt das Formular und verbindet NICHT.

Kein Unit-Test (UI-Wiring; Parser/Importer sind Core-getestet); Verifikation: Build + Suite + Headless-Launch; visuell in Task 3.

- [ ] **Step 1: Sidebar** — in `SessionSidebar`:

1. Properties ergänzen (nach `viewModel`): `let importedHosts: [SSHConfigHost]` und (nach `onDelete`) `let onSelectImported: (SSHConfigHost) -> Void`.
2. In der `List` NACH dem Sessions-`ForEach` ergänzen:

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

- [ ] **Step 2: ContentView** —

1. State: `@State private var importedHosts: [SSHConfigHost] = []`
2. An der `SessionSidebar`-Aufrufstelle die neuen Argumente (Reihenfolge an die Property-Deklaration anpassen) + ans `HSplitView` (bzw. den äußeren Container) anhängen:

```swift
        .task { importedHosts = SSHConfigImporter.load(path: SSHConfigImporter.defaultPath) }
```

3. Private Methode:

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

(`onSelectImported: { fillFromImported($0) }` an der Sidebar.)

- [ ] **Step 3: Grün** — `swift build && swift test` (Basis unverändert), Headless-Launch-Check.
- [ ] **Step 4: Commit** — `feat: import ssh config hosts into the sidebar` (mit Footer).

---

### Task 3: Abschluss-Verifikation

- [ ] **Step 1:** `swift test` — 126 gesamt (115 + 2 T0 + 9 T1)
- [ ] **Step 2:** Rig hoch (HAUPT-Checkout), `MACSCP_ITEST=1` 10/10, `MACSCP_KEYCHAIN=1` 2/2, Rig runter
- [ ] **Step 3: Visueller Smoke-Test** (Koordinator): PRÜFEN ob `~/.ssh/config` existiert (nur lesen!); falls ja: Sektion IMPORTIERT zeigt die Aliase; Klick auf einen Eintrag → Formular gefüllt (Host/Port/User/ggf. Key-Modus + Pfad), KEINE automatische Verbindung, KEIN Prompt; falls der User keine config hat: Sektion bleibt aus (ebenfalls korrekt — dokumentieren was vorlag). Die echte Datei wird unter KEINEN Umständen verändert.
- [ ] **Step 4:** Checkboxen, Commit `docs: mark M3d plan tasks as completed` (mit Footer)

## Ausblick

Mit M3d ist **Meilenstein M3 (Sessions) KOMPLETT** — der gesamte Verbindungsmanager aus der Spec. Danach: **M4 Terminal** (SwiftTerm-Panel je Verbindung — das größte fehlende Design-Element), M5 Transfer-Queue, M6 Release (App-Icon, Design-Polish, notarisierte DMG). Offen geblieben aus M3: Cancellation-Handler am Prompt-Continuation (M4-Opening), ssh-agent/RSA (optional M3e).
