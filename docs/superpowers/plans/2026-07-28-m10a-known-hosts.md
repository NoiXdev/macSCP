# M10a — Known-Hosts-Verwaltung Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Alle per TOFU gemerkten Host-Keys einsehen und verwalten (Tabelle, Suche, Fingerprint kopieren, Entfernen mit Rückfrage) — erreichbar über ein neues „Sessions"-Menü (⌘⇧K), das Sidebar-Hintergrund-Menü und eine TOFU-Prompt-Fußnote.

**Architecture:** `KnownHostKey.addedAt: Date?` (decode-kompatibel über den bestehenden normalisierenden Custom-Decoder) + `allKeys()`/`remove(host:port:)` im Store (Core, TDD); `KnownHostsSheet` exakt nach Mockup; das neue „Sessions"-Menü über die vorhandene `TabCommands`-Brücke.

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, SwiftUI, NSPasteboard.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-28-m10a-known-hosts-design.md` — bindend. Mockup: `docs/design/assets/m10-mockups.html` Abschnitte 1+4. Branch: **develop**.
- TOFU-INVARIANTEN UNANGETASTET: find/upsert/Validator unverändert, Mismatch bleibt harter Stopp; KEIN Bearbeiten/Hinzufügen von Einträgen — `remove` ist der einzige neue Schreibweg.
- `addedAt` optional + decode-kompatibel (`decodeIfPresent`; Legacy liest nil ⇒ Anzeige „—"); der Custom-Decoder bleibt der EINZIGE Decode-Pfad (M3d-Regel); `upsert` stempelt `Date()` auch beim Ersetzen.
- Alle neuen UI-Texte EN/DE; Code + Kommentare NUR Englisch; keine neuen Dependencies.
- Conventional Commits (Englisch), Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + volle `swift test` nach jedem Task grün (Ausgangslage 470 Tests / 37 Suiten); gated Suiten nur in T3; Tests SYNCHRON im Vordergrund.
- TDD für Core; App-Target untestbar → T2 liefert Build + Verhaltensbeschreibung.

## Schedule

T1 (Core: addedAt + allKeys + remove) → T2 (App: Sheet + Sessions-Menü + Sidebar + TOFU-Fußnote) → T3 Abschluss (Koordinator).

---

### Task 1: addedAt + allKeys + remove (Core)

**Files:**
- Modify: `Sources/macSCPCore/Sessions/KnownHostsStore.swift`
- Test: `Tests/macSCPCoreTests/KnownHostsStoreTests.swift` (bestehende Datei — Muster übernehmen)

**Interfaces:**
- Produces (T2 verlässt sich exakt hierauf):
  - `KnownHostKey.addedAt: Date?` (public let; Init-Parameter mit Default `Date()`; Decoder `decodeIfPresent`)
  - `KnownHostsStore.allKeys() throws -> [KnownHostKey]` (sortiert host, dann port)
  - `KnownHostsStore.remove(host: String, port: Int) throws` (lowercased-Match; No-op wenn absent; atomar persistiert)

- [x] **Step 1: Failing Tests** (in `KnownHostsStoreTests.swift`, Fixture-Muster der Datei — Temp-Verzeichnis + Beispiel-Keys übernehmen):

```swift
    // allKeysListsSorted: drei upserts (b.example:22, a.example:2222, a.example:22)
    //   -> allKeys() liefert [a.example:22, a.example:2222, b.example:22].
    // removeDeletesExactMatchOnly: upsert a:22 + a:2222; remove(host:"A.EXAMPLE",
    //   port:22) -> allKeys() enthält nur noch a:2222 (Case-insensitiv via
    //   lowercased-Match); remove(host:"missing", port:9) wirft nicht, ändert nichts.
    // upsertStampsAddedAt: frischer upsert -> allKeys().first?.addedAt != nil;
    //   zweiter upsert desselben Hosts mit anderem Key-Blob -> addedAt neu
    //   gestempelt (>= erster Wert; einfacher Nil-Check + Ungleichheit über
    //   injizierten Sleep vermeiden — stattdessen: erster addedAt merken,
    //   kurz Task.sleep(50ms), erneut upserten, #expect(neuer > alter)).
    // legacyEntriesReadWithNilAddedAt: Raw-JSON OHNE addedAt-Feld direkt in
    //   known_hosts.json schreiben (Format der Datei nachstellen) ->
    //   allKeys().first?.addedAt == nil; fingerprintSHA256 weiterhin ableitbar.
    // roundtripKeepsAddedAt: upsert -> neues Store-Objekt aufs selbe
    //   Verzeichnis -> addedAt bleibt (Codable-Roundtrip).
```

- [x] **Step 2: Rot beweisen.** `swift test --filter KnownHostsStoreTests` → FAIL.

- [x] **Step 3: Implementierung.**

```swift
    // In KnownHostKey:
    /// When this key was last trusted (TOFU accept or re-accept). Optional
    /// for decode compatibility: entries written before M10a read as nil
    /// (the UI shows an em dash).
    public let addedAt: Date?

    public init(host: String, port: Int, keyType: String,
                publicKeyBase64: String, addedAt: Date? = Date()) { … }

    // Decoder: addedAt via container.decodeIfPresent(Date.self, forKey: .addedAt)
    // durch den normalisierenden Init reichen; CodingKeys um .addedAt ergänzen.

    // In KnownHostsStore:
    /// All remembered keys, host-then-port sorted — the management sheet's
    /// data source (M10a).
    public func allKeys() throws -> [KnownHostKey] {
        try all().sorted {
            $0.host == $1.host ? $0.port < $1.port : $0.host < $1.host
        }
    }

    /// Forgets a host key (M10a): the host becomes UNKNOWN again — the next
    /// connect runs the normal TOFU prompt. This is the only mutation the
    /// management UI offers; fingerprints are never editable.
    public func remove(host: String, port: Int) throws {
        var keys = try all()
        keys.removeAll { $0.host == host.lowercased() && $0.port == port }
        try persist(keys)
    }
```

  `upsert` unverändert lassen (der Init-Default stempelt) — ABER prüfen, wo `KnownHostKey` im TOFU-Validator konstruiert wird (grep `KnownHostKey(`): bestehende Aufrufer kompilieren durch den Default weiter; keiner darf explizit `addedAt: nil` setzen.

- [x] **Step 4: Grün + volle Suite.** `swift test` → 470 + 5 (echte Zahl festhalten).

- [x] **Step 5: Commit.** `feat: list, date and remove known host keys`

---

### Task 2: Sheet + Sessions-Menü + Sidebar + TOFU-Fußnote (App)

**Files:**
- Create: `Sources/MacSCPApp/KnownHostsSheet.swift`
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (Sessions-Menü), `Sources/MacSCPApp/ContentView.swift` (Sheet-State + TabCommands-Closure + Sidebar-Callback), `Sources/MacSCPApp/SessionSidebar.swift` (Hintergrund-Menü-Eintrag), `Sources/MacSCPApp/ConnectionFormView.swift` (TOFU-Prompt-Fußnote), `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj`
- Test: keiner (App-Target; Smoke in T3)

**Interfaces:**
- Consumes: `allKeys()`/`remove(host:port:)`/`addedAt` (T1), `KnownHostsStore(directory: SessionStore.defaultDirectory)` (derselbe Ort wie der Connector in ContentView ihn nutzt — nachschlagen), `TabCommands`-Brücke (M8a; um eine Closure `showKnownHosts: (() -> Void)?` erweitern), Sidebar-Callback-Muster, TOFU-Prompt-View in `ConnectionFormView` (die Trust-Entscheidung aus M3c — Stelle suchen).

**Verhaltens-Anforderungen (Spec §2/§3, bindend):**
1. `KnownHostsSheet(store:)` nach Mockup Abschnitt 1 (~720 pt): Tabelle Host/Port/Keytyp-Badge/Fingerprint (monospaced, inkSecondary)/Hinzugefügt (`dd.MM.yyyy`, „—" bei nil); Mehrfachauswahl (SwiftUI `Table` mit `selection: Set<…>` ODER List — Wahl dokumentieren); Suche case-insensitiv über host+fingerprint; Fußzeile Zähler („%lld Hosts" / „%lld von %lld"), „Fingerprint kopieren" (Einzelauswahl; `NSPasteboard.general.clearContents()` + `setString`), „Entfernen…" (destruktiv, confirmationDialog: EN "The host will be treated as unknown on the next connect (new trust prompt)." / DE „Beim nächsten Verbinden wird der Host wie ein unbekannter behandelt (neuer Vertrauens-Prompt)."; Mehrfachauswahl nennt Anzahl), „Schließen". Laden bei onAppear; Ladefehler ⇒ rote Meldung im Sheet. Nach remove: neu laden, Auswahl leeren.
2. Sessions-Menü in `MacSCPApp.commands`: `CommandMenu(L10n.string("menu.sessions", "Sessions"))` mit „Known Hosts…" ⌘⇧K (`tabCommands.showKnownHosts?()`, Key-Window-Guard wie die übrigen), Divider, „Export All Sessions…" und „Import Sessions…" — dieselben Handler wie die Sidebar-Einträge (über neue TabCommands-Closures `exportAllSessions`/`importSessions`, die ContentView auf die BESTEHENDEN Handler bindet; Sidebar-Einträge bleiben unverändert).
3. Sidebar-Hintergrund-Menü: „Known Hosts…" mit Separator über den Export/Import-Einträgen (Callback `onShowKnownHosts` nach Muster).
4. TOFU-Prompt (`ConnectionFormView`, M3c-Trust-View): dezente Fußnote/Link-Zeile „Manage known hosts…"/„Bekannte Hosts verwalten…" unter den Buttons — öffnet das Sheet ÜBER dem Formular (eigener Sheet-State in ConnectionFormView mit direktem Store-Zugriff ODER Callback nach oben — die kleinere Lösung wählen und dokumentieren); der Prompt bleibt offen und funktional.
5. Keys EN/DE (Vorschlag): `menu.sessions`, `menu.knownHosts`, `knownHosts.title`, `knownHosts.search`, `knownHosts.column.host/port/keyType/fingerprint/added`, `knownHosts.count %lld`, `knownHosts.countFiltered %lld %lld`, `knownHosts.copyFingerprint`, `knownHosts.remove`, `knownHosts.remove.title`, `knownHosts.remove.message`, `knownHosts.remove.messageMany %lld`, `knownHosts.remove.confirm`, `knownHosts.empty`, `knownHosts.loadError %@`, `tofu.manageKnownHosts`. Grep-Gegenprobe beide Kataloge.

- [x] **Step 1:** Sheet. **Step 2:** Menü + TabCommands. **Step 3:** Sidebar + TOFU-Fußnote. **Step 4:** Keys + Gegenprobe. **Step 5:** `swift build` (0 Fehler, keine neuen Warnungen) + volle `swift test` (Stand T1). **Step 6:** Commit `feat: manage known host keys from a dedicated sheet`.

---

### Task 3: Abschluss-Verifikation (Koordinator)

- [x] Gated Suiten: 475/475 zero skips (Final-Reviewer unabhängig wiederholt).
- [ ] Visueller Smoke — **an den Maintainer delegiert** (Checkliste in der Zusammenfassung).
- [x] Plan-Checkboxen, Ledger, Opus-Final-Review („Ready to merge: Yes" im ersten Anlauf; zwei Pre-Push-Politur-Punkte gefolgt), Push, CI, Rig stop, Memory, Zusammenfassung.
