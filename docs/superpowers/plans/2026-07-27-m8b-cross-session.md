# M8b — Cross-Session-Transfers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** „Übertragen zu Session xy" aus beiden Panes — inklusive direktem Remote→Remote-Stream durch die App, Doppel-Bucket-Drossel, zweitem Rig-Container für den Server-zu-Server-Beweis und Schließen-Warnung für Ziel-Tabs.

**Architecture:** Der Job landet in der Queue des QUELL-Tabs; die Engine ist bereits quell-/ziel-agnostisch, sie bekommt für Remote→Remote einen ZWEITEN Bucket (zählt in beiden Richtungen — Spec-§4-Carry aus M8a). Das Menü-Modell in Core wird um Ziel-Sessions erweitert (`transferToSession`), der exhaustive Switch in `ContentView` erzwingt die neue Behandlung zur Compile-Zeit. Queue-Items tragen eine opake `destinationTabID` für die Schließen-Warnung.

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, AppKit `NSMenu` (macOS 15 → `NSMenuItem.subtitle` verfügbar), Docker-Compose-Rig.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-27-m8-tabs-design.md` §4 (Doppel-Bucket), §5, §6 — bindend. Branch: **develop**.
- Queue-Invarianten unverändert (FIFO, exactly-once Waiter, cancelAll, Gruppen-onCompleted exactly-once); Konflikt-Maschinerie läuft unverändert gegen das Ziel-FS.
- Drossel-Semantik: Remote→Remote konsumiert JEDEN Chunk aus BEIDEM Bucket-Paar (Down + Up — es ist real beides auf der Leitung); sequenzielles `consume` auf zwei unabhängigen Actors ist deadlockfrei (kein Lock wird über ein await gehalten); Gesamtwartezeit = max beider Freigaben ⇒ Rate = min beider Limits. Lokal→Ziel-Remote zählt nur im Upload-Bucket.
- Menü-Regeln (Spec §6, unit-getestet): Ziel-Einträge nur, wenn die Auswahl übertragbar ist (gleiches Gate wie `transferToOtherPane`); NIE der eigene Tab; NIE Formular-Tabs (die App übergibt nur verbundene andere Tabs); Reihenfolge = Strip-Reihenfolge; ohne andere verbundene Tabs Optik wie heute (kein Submenü-Zwang). Ziel-Pfad wird beim KLICK eingefroren.
- Kanten (Spec §5.3): Ziel-Tab schließt während des Streams → vorhandenes M5d-Mapping (kein Sonderpfad); Schließen-Nachfrage erscheint auch, wenn der Tab ZIEL aktiver Transfers anderer Tabs ist (eigener Text); Enqueue gegen totes FS endet als normale Fehlermeldung.
- Symlinks bleiben von Übertragungen ausgeschlossen (M7b-Regeln unverändert); Ordner über `enqueueTree`.
- Rig: NIE `up`/`down` aus Worktrees, nur `start`/`stop` aus dem Haupt-Checkout; zweiter Container gleiche Image-PIN, Port 2223; `PerSourcePenalties` deaktiviert (geteilte sshd_config.d).
- Alle neuen UI-Texte EN/DE (`Sources/MacSCPApp/Resources/*/Localizable.strings`); Code + Kommentare NUR Englisch.
- Conventional Commits (Englisch), Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + volle `swift test` nach jedem Task grün (Ausgangslage 376 Tests / 32 Suiten); gated Suiten in T3 (Implementer, Rig läuft) und T5.
- TDD für Core; App-Target untestbar → T4 liefert Build + Verhaltensbeschreibung; Tests SYNCHRON im Vordergrund.
- M8a-Backlog NICHT in M8b (Tab-a11y, Menü-Aufräumen) — nichts davon „mitnehmen".

## Schedule

T1 (Doppel-Bucket + destinationTabID, Core) → T2 (Menü-Modell, Core) → T3 (zweiter Rig-Container + gated Remote→Remote-Test) → T4 (App: Submenü, Handler, Schließen-Warnung) → T5 Abschluss (Koordinator).

---

### Task 1: Engine-Doppel-Bucket + Queue-Erweiterungen (Core)

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/TransferEngine.swift` (`copyFile` ~Zeile 89–143)
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` (Job/Item, `enqueue`/`enqueueAndWait`/`enqueueTree`, Throttle-Auflösung ~Zeile 697)
- Test: `Tests/macSCPCoreTests/TransferEngineTests.swift`, `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift`

**Interfaces:**
- Consumes: `BandwidthBucket` (injizierbare Uhr über den bestehenden Test-Init), `BandwidthLimiter` (M8a).
- Produces (T3/T4 verlassen sich exakt hierauf):
  - `TransferEngine.copyFile(..., throttle: BandwidthBucket? = nil, secondaryThrottle: BandwidthBucket? = nil, ...)` — jeder Chunk konsumiert erst `throttle`, dann `secondaryThrottle`.
  - `TransferQueueViewModel.enqueue(fileName:direction:source:sourcePath:destination:destinationDirectory:onCompleted:destinationTabID:crossRemote:)` — beide neuen Parameter mit Default (`destinationTabID: UUID? = nil`, `crossRemote: Bool = false`); gleiche Erweiterung an `enqueueTree` (Vererbung an alle expandierten Items) und `enqueueAndWait` NICHT nötig (kein Konsument).
  - `crossRemote: true` ⇒ Throttle-Auflösung: primär = `limiter?.uploadBucket`, sekundär = `limiter?.downloadBucket` (Richtung des Jobs ist `.upload` — Ziel-Schreiben; der Indikator zeigt Bernstein).
  - `TransferQueueViewModel.hasActiveItems(destinationTabID: UUID) -> Bool` — true, wenn ein nicht-terminales Item (queued/running/im Konflikt) diese Ziel-Tab-ID trägt.

- [x] **Step 1: Failing Tests.** In `TransferEngineTests.swift` (bestehende Muster der Datei für FS-Mocks/Bucket-Uhr übernehmen — Helper-Namen anpassen, Assertions unverändert):

```swift
    @Test func copyFileConsumesBothThrottles() async throws {
        // 8 KiB file, primary 8 KiB/s, secondary 2 KiB/s: the pace must
        // follow the TIGHTER bucket — total virtual wait ≈ 4s, not 1s.
        // Build both buckets on the same injected virtual clock (existing
        // BandwidthBucket test init), copy, assert the recorded sleep total
        // is within the file's tolerance pattern for 4s (mirror the M6a
        // steady-state test's tolerance).
    }

    @Test func copyFileSecondaryThrottleNilBehavesAsBefore() async throws {
        // Same setup with secondaryThrottle: nil — wait ≈ 1s (regression).
    }
```

(Die konkreten Werte/Toleranzen an die vorhandenen M6a-Drossel-Tests der Datei angleichen; der Test MUSS scheitern, weil `secondaryThrottle` noch nicht existiert.)

In `TransferQueueViewModelTests.swift`:

```swift
    @Test func crossRemoteJobResolvesBothBuckets() async throws {
        // Queue with a BandwidthLimiter (both limits set), enqueue with
        // crossRemote: true, let the job run against the mock FS pair and
        // assert completion; the bucket WIRING is proven at the engine level —
        // here assert the job completes and the item's direction is .upload.
    }

    @Test func hasActiveItemsTracksDestinationTab() async throws {
        let tabID = UUID()
        // enqueue a job with destinationTabID: tabID against a gated mock
        // (use the existing signal-gate helpers so the job stays .running),
        // assert hasActiveItems(destinationTabID: tabID) == true and a random
        // UUID == false; release the gate, await completion, assert false.
    }

    @Test func enqueueTreeForwardsDestinationTabID() async throws {
        // enqueueTree(..., destinationTabID: tabID) over a small mock tree;
        // while items are gated .running, hasActiveItems(destinationTabID:)
        // is true; after completion false.
    }
```

- [x] **Step 2: Rot beweisen.** `swift test --filter TransferEngineTests` und `--filter TransferQueueViewModelTests` → FAIL (Parameter existieren nicht).

- [x] **Step 3: Engine.** In `copyFile` den Parameter `secondaryThrottle: BandwidthBucket? = nil` ergänzen (nach `throttle`), Doku-Zeile: „Second bucket for cross-remote transfers (M8b): a remote→remote stream is real download AND upload on this machine's link, so every chunk pays both buckets; the pace follows the tighter one." Im Chunk-Loop nach dem bestehenden `try await throttle.consume(chunk.count)`:

```swift
            if let secondaryThrottle {
                try await secondaryThrottle.consume(chunk.count)
            }
```

- [x] **Step 4: Queue.** `Job` um `let destinationTabID: UUID?` und `let crossRemote: Bool` erweitern; `Item` um `public let destinationTabID: UUID?` (für `hasActiveItems`; Anzeige unverändert). `enqueue`/`enqueueTree` um die Parameter mit Defaults erweitern (`enqueueTree` reicht beide an jedes expandierte File-Item weiter). Throttle-Auflösung beim Job-Start:

```swift
        let throttle: BandwidthBucket?
        let secondary: BandwidthBucket?
        if job.crossRemote {
            // Cross-remote (M8b): the stream is upload to the target AND
            // download from the source — both app-global buckets pay.
            throttle = limiter?.uploadBucket
            secondary = limiter?.downloadBucket
        } else {
            throttle = job.direction == .upload
                ? limiter?.uploadBucket : limiter?.downloadBucket
            secondary = nil
        }
```

`copyFile`-Aufruf um `secondaryThrottle: secondary` ergänzen. Neu:

```swift
    /// True while any non-terminal item targets the given tab (M8b) — the
    /// app asks every OTHER tab's queue before closing a tab, so a close
    /// can warn when it would sever incoming cross-session streams.
    public func hasActiveItems(destinationTabID: UUID) -> Bool {
        items.contains { $0.destinationTabID == destinationTabID && !$0.status.isTerminal }
    }
```

(Exakte `isTerminal`-Zugriffsform an `Item.Status` der Datei anpassen.)

- [x] **Step 5: Grün + volle Suite.** `swift test` → 376 + neue (Zahl im Report festhalten); Build sauber.

- [x] **Step 6: Commit.** `feat: pay both bandwidth buckets on cross-remote transfers`

---

### Task 2: Menü-Modell mit Ziel-Sessions (Core)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/BrowserContextMenu.swift`
- Test: `Tests/macSCPCoreTests/BrowserContextMenuTests.swift`

**Interfaces:**
- Produces (T4 verlässt sich exakt hierauf):
  - `public struct CrossSessionTarget: Equatable, Sendable, Identifiable { public let id: UUID; public let title: String; public let remotePath: String; public init(id:title:remotePath:) }` (id = Tab-ID; `remotePath` = beim Menü-Aufbau eingefrorener aktueller Remote-Pfad des Ziel-Tabs).
  - `BrowserMenuEntry` + `case transferToSession(CrossSessionTarget)`.
  - `entries(for:side:crossSessionTargets:)` — neuer Parameter `crossSessionTargets: [CrossSessionTarget] = []`; die bestehende Zwei-Parameter-Form bleibt als Überladung/Default funktionsfähig (Bestandsaufrufer + Tests unverändert).
  - Regel: `transferToSession`-Einträge erscheinen genau dann, wenn auch `transferToOtherPane` erscheint (gleiches Übertragbarkeits-Gate), direkt NACH ihm, in Listen-Reihenfolge (= Strip-Reihenfolge, die die App liefert). Leere Liste ⇒ Rückgabe exakt wie heute.

- [x] **Step 1: Failing Tests** (an den Stil der bestehenden `BrowserContextMenuTests` angleichen):

```swift
    @Test func crossSessionTargetsFollowTransferEntry() {
        let t1 = CrossSessionTarget(id: UUID(), title: "db-prod", remotePath: "/srv")
        let t2 = CrossSessionTarget(id: UUID(), title: "backup", remotePath: "/volume1")
        let entries = BrowserContextMenu.entries(
            for: [fileItem("/a.txt")], side: .local, crossSessionTargets: [t1, t2])
        #expect(entries.starts(with: [
            .transferToOtherPane, .transferToSession(t1), .transferToSession(t2)]))
    }

    @Test func crossSessionTargetsAbsentWhenSelectionNotTransferable() {
        let t = CrossSessionTarget(id: UUID(), title: "x", remotePath: "/")
        // Symlink-only selection: no transfer entry -> no session targets.
        let entries = BrowserContextMenu.entries(
            for: [symlinkItem("/l")], side: .remote, crossSessionTargets: [t])
        #expect(!entries.contains { if case .transferToSession = $0 { return true }; return false })
        #expect(!entries.contains(.transferToOtherPane))
    }

    @Test func emptyTargetsKeepTodayShape() {
        let with = BrowserContextMenu.entries(for: [fileItem("/a")], side: .local, crossSessionTargets: [])
        let without = BrowserContextMenu.entries(for: [fileItem("/a")], side: .local)
        #expect(with == without)
    }

    @Test func backgroundClickIgnoresTargets() {
        let t = CrossSessionTarget(id: UUID(), title: "x", remotePath: "/")
        #expect(BrowserContextMenu.entries(for: [], side: .local, crossSessionTargets: [t]) == [.newFolder])
    }
```

- [x] **Step 2: Rot beweisen**, dann implementieren: Nach dem `transferToOtherPane`-Append `entries.append(contentsOf: crossSessionTargets.map { .transferToSession($0) })`. Doku-Kommentare aktualisieren (der `transferToOtherPane`-Kommentar sagt bereits „M8 adds per-session targets").

- [x] **Step 3: Grün + volle Suite + Commit.** `feat: add cross-session targets to the context-menu model`

---

### Task 3: Zweiter Rig-Container + gated Remote→Remote-Test

**Files:**
- Modify: `docker/test-server/compose.yml`
- Test: `Tests/macSCPCoreTests/CitadelIntegrationTests.swift` (bzw. die Datei, die die `MACSCP_ITEST`-Suite enthält — vorher nachschlagen; neue Tests dort einfügen)

**Interfaces:**
- Consumes: `TransferEngine.copyFile(..., secondaryThrottle:)` (T1), bestehende Docker-Suite-Helfer (Connect-Config testuser/testpass, Port-Konstante, Cleanup-Muster).
- Produces: zweiter sshd-Dienst auf **127.0.0.1:2223** (gleiches Image-PIN `lscr.io/linuxserver/openssh-server:10.3_p1-r0-ls230`, Container `macscp-test-sshd-2`, gleiche env, gleiche `sshd_config.d`-Mounts, EIGENES leeres Seed-Verzeichnis `./seed2:/data/seed:ro` — Verzeichnis mit `.gitkeep` anlegen).

- [x] **Step 1: Compose erweitern** (Service `sshd2` als Kopie von `sshd` mit `container_name: macscp-test-sshd-2`, `ports: ["2223:2222"]`, `./seed2`-Mount). Rig aus dem HAUPT-Checkout neu erzeugen — einmalig ist hier `docker compose -f docker/test-server/compose.yml up -d` nötig (neuer Service; Host-Key-Rotation des ersten Containers vermeiden: `up -d` erzeugt nur den NEUEN Service neu, wenn der alte unverändert läuft — mit `docker compose ... up -d --no-recreate` absichern). Beide Container laufen lassen.

- [x] **Step 2: Failing gated Test** (in der bestehenden Docker-Suite, gleiche Gate-Konvention):

```swift
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"))
    func remoteToRemoteStreamCopiesByteIdentical() async throws {
        // Connect to BOTH rig servers (ports 2222 and 2223, same creds,
        // follow the suite's existing connect/TOFU test helpers).
        // 1. Write a ~256 KiB random payload to server 1 (existing write
        //    helpers), remember its bytes.
        // 2. TransferEngine.copyFile(source: fs1, sourcePath: ...,
        //    destination: fs2, destinationPath: ...) — remote to remote,
        //    no local temp file involved by construction.
        // 3. Read the file back from server 2, #expect(bytes identical).
        // 4. Cleanup on both servers (defer, existing delete helpers).
    }
```

Rot beweisen heißt hier: der Test scheitert VOR Step 1 (nur ein Server) — Reihenfolge im Task: Test zuerst schreiben, `MACSCP_ITEST=1 swift test --filter <name>` gegen das alte Rig → FAIL (connection refused 2223), dann Compose-Step, dann grün.

- [x] **Step 3: Grün beweisen.** `MACSCP_ITEST=1 swift test` KOMPLETT (alle gated Suiten, beide Container) + ungated `swift test`.

- [x] **Step 4: Commit.** `feat: add a second test server and prove remote-to-remote streaming`

---

### Task 4: App — Submenü, Handler, Schließen-Warnung

**Files:**
- Modify: `Sources/MacSCPApp/RemoteFileTableView.swift` (NSMenu-Brücke), `Sources/MacSCPApp/BrowserPane.swift` (Durchreichung), `Sources/MacSCPApp/ContentView.swift` (Targets bauen, Handler, Schließen-Warnung), `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj`
- Test: keiner (App-Target; Smoke in T5)

**Interfaces:**
- Consumes: `CrossSessionTarget`/`transferToSession` (T2), `enqueue(..., destinationTabID:crossRemote:)`/`enqueueTree(...)`/`hasActiveItems(destinationTabID:)` (T1), `tabsModel`/`SessionTab` (M8a).
- Produces: Kontextmenü „Übertragen" als Submenü, sobald Ziel-Sessions existieren; Schließen-Confirm auch für Ziel-Tabs.

**Verhaltens-Anforderungen:**
1. **Targets bauen (ContentView):** Closure `crossSessionTargets(for tab: SessionTab) -> [CrossSessionTarget]` — alle ANDEREN Tabs in Strip-Reihenfolge mit `session != nil`, gemappt auf `CrossSessionTarget(id: other.id, title: other.displayTitle, remotePath: other.session!.remote.currentPath)`. Als Closure durch `BrowserPane` in den Tabellen-Coordinator reichen (frisch bei JEDEM `menuNeedsUpdate` ausgewertet — Menü-Aufbau friert den Pfad ein, Spec §5.3).
2. **NSMenu-Brücke:** Enthält das Modell mindestens einen `transferToSession`-Eintrag, werden ALLE transfer*-Einträge zu einem Submenü „Transfer"/„Übertragen" (neuer Key `menu.transfer.submenu`): erstes Item = bisheriger `transferToOtherPane`-Titel, Separator, dann je Ziel `String(format: L10n.string("menu.transfer.toSession", "To “%@”"), target.title)` mit `menuItem.subtitle = target.remotePath` (macOS 15 ≥ 14.4, verfügbar). OHNE Ziel-Einträge bleibt die heutige flache Struktur byte-identisch. `MenuActionBox`-Muster beibehalten (Selektion by value; Ziel im representedObject mitführen).
3. **Handler (ContentView, exhaustiver Switch):** `case .transferToSession(let target)`: Ziel-Tab via `tabsModel.tabs.first { $0.id == target.id }`; guard `let targetSession = targetTab?.session` else return (Ziel trennte inzwischen — Enqueue unterbleibt, kein Crash; die Queue-Fehlermeldung entsteht nur bei bereits laufenden Jobs, Spec §5.3). Pro Auswahl-Item (Symlinks überspringen wie `transferSelection`):
   - Quelle lokal: `enqueue(fileName:direction:.upload, source: tab.session!.localFS, sourcePath:, destination: targetSession.remoteFS, destinationDirectory: target.remotePath, onCompleted: [weak remote = targetSession.remote] refresh, destinationTabID: target.id)`; Ordner analog `enqueueTree`.
   - Quelle remote: identisch, aber `source: tab.session!.remoteFS` und `crossRemote: true` (Richtung bleibt `.upload`).
   Alles auf der Queue des QUELL-Tabs (`tab.transferQueue`).
4. **Schließen-Warnung:** `requestClose` fragt zusätzlich, ob IRGENDEIN anderer Tab `hasActiveItems(destinationTabID: tab.id)` meldet; dann Confirm mit eigenem Text `tabs.close.incomingTransfers` („Other tabs are streaming to this session; closing cancels those transfers." / „Andere Tabs übertragen gerade zu dieser Session; Schließen bricht diese Übertragungen ab.") — beide Gründe können gemeinsam zutreffen (Texte kombinieren: eigener + eingehender Hinweis untereinander).
5. Keys EN/DE: `menu.transfer.submenu` „Transfer"/„Übertragen", `menu.transfer.toSession` „To “%@”"/„Zu „%@"", `tabs.close.incomingTransfers` (siehe oben).

- [x] **Step 1:** Brücke + Durchreichung; **Step 2:** Handler; **Step 3:** Schließen-Warnung; **Step 4:** Katalog-Keys + Gegenprobe (jeder Key in BEIDEN Dateien); **Step 5:** `swift build` (0 Fehler, keine neuen Warnungen) + volle `swift test` (Stand T3); **Step 6:** Commit `feat: transfer selections to other session tabs from the context menu`.

---

### Task 5: Abschluss-Verifikation (Koordinator)

- [x] Gated Suiten mit BEIDEN Containern: `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` ⇒ komplett grün, zero skips (386 vor / 389 nach den Final-Review-Fixes).
- [ ] Visueller Smoke — **an den Maintainer delegiert** (Wrapper läuft; Checkliste in der Milestone-Zusammenfassung): Submenü zeigt nur verbundene andere Tabs (Formular-Tab nie, eigener nie) mit Pfad-Untertitel; lokale Auswahl → Ziel-Tab-Remote (Queue im Quell-Tab, Ziel-Pane refresht); Remote-Auswahl → Server-zu-Server (docker exec-Beweis auf Container 2, kein lokales Tempfile); Drossel: Remote→Remote bei Limit X drückt BEIDE Richtungen (Rate ≈ min); Ordner-Transfer cross-session inkl. Konflikt-Sheet im QUELL-Tab; Ziel-Tab schließen während Stream → Warn-Text, nach Bestätigung fehlgeschlagener Transfer im Quell-Tab (kein Hänger); ohne zweiten Tab Menü-Optik wie heute; Regressionen: transferToOtherPane, M7b-Dialoge.
- [x] Plan-Checkboxen, Ledger, Opus-Whole-Branch-Final-Review (Base = Commit vor T1; „No" mit einem Critical → Fix-Commit d147ed5 → Re-Review „Ready to merge: Yes"), Fixes, Push develop, CI, Rig `stop`, Memory-Update, Milestone-Zusammenfassung (+ Frage: Release v1.1.0 jetzt taggen — M7+M8 komplett).
