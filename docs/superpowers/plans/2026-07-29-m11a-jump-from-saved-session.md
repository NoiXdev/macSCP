# M11a — Zwischenhost aus gespeicherter Verbindung Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eine gespeicherte Verbindung als Zwischenhost referenzieren (Picker im Jump-Block statt Tipparbeit); Änderungen an der Bastion wirken überall; Löschen der Bastion stellt die referenzierenden Jumps verlustfrei zurück.

**Architecture:** `JumpSpec.sessionID: UUID?` (decode-kompatibel, non-nil = Session-Modus) + Auflösung in `LoginResolver.resolveJump`, die für das LOGIN den bestehenden `resolve(session:sets:secrets:)` wiederverwendet (deckt Set/Manuell/Agent der referenzierten Session automatisch ab); reine Eligibility-Funktion für den Picker; Rückstellung und Export-Auflösung im `SessionListViewModel` nach dem M10b/M10c-Muster; App verdrahtet Umschalter + Picker + Nur-Lese-Zusammenfassung.

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, SwiftUI.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-29-m11a-jump-from-saved-session-design.md` — bindend. Branch: **develop**.
- REFERENZ, nicht Kopie; NIE die laufende Verbindung eines anderen Tabs mitbenutzen (Invariante „eine Verbindung pro Tab").
- EIN Hop: eine referenzierte Session mit eigenem Jump wird abgelehnt (Picker filtert, Resolver riegelt ab); Selbstreferenz ebenso.
- Kein stiller Fallback: fehlende Referenz und Ketten sind typisierte Fehler mit lokalisierter Meldung (M10b/M10c-Prinzip).
- Secrets NIE in JSON; Slot-Hygiene beim Moduswechsel (Session-Modus räumt den manuellen `secretID`-Slot wie der Set-Wechsel); Agent-Logins übertragen kein Secret und lesen keinen Keychain.
- `JumpSpec.sessionID` optional OHNE Custom-Decoder — Legacy-JSON liest nil.
- Export bleibt Format v1: der Session-Jump wird AUFGELÖST exportiert, die Referenz-UUID wandert nicht mit; Export bricht nie ab.
- TOFU-Invarianten und die M10c-Zwei-Hop-Connect-Semantik bleiben unangetastet — M11a ändert nur, WOHER die Jump-Werte kommen.
- Alle neuen UI-Texte EN/DE (beide App-Kataloge), Core-Fehlertexte in beiden Core-Katalogen; Code + Kommentare NUR Englisch; keine neuen Dependencies.
- Conventional Commits (Englisch), Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + volle `swift test` nach jedem Task grün (Ausgangslage 595 Tests / 43 Suiten); gated Suiten in T4; Tests SYNCHRON im Vordergrund; TDD rot→grün für Core.
- Docker-Rig nur `start`/`stop` aus dem Haupt-Checkout.
- KEIN Release, kein Merge nach main.

## Schedule

T1 (Core: sessionID + Resolver + Eligibility) → T2 (Core: Rückstellung + Export) → T3 (App: Umschalter + Picker + Wiring + L10n) → T4 Abschluss (Koordinator).

---

### Task 1: JumpSpec.sessionID + Resolver + Eligibility (Core)

**Files:**
- Modify: `Sources/macSCPCore/Sessions/StoredSession.swift`, `Sources/macSCPCore/Sessions/LoginResolver.swift`
- Create: `Sources/macSCPCore/Sessions/JumpSessionEligibility.swift`
- Test: `Tests/macSCPCoreTests/LoginResolverTests.swift` (erweitern), `Tests/macSCPCoreTests/JumpSessionEligibilityTests.swift` (neu), `Tests/macSCPCoreTests/StoredSessionCompatTests.swift` (bzw. die Datei mit den Decode-Kompat-Tests — per grep `legacySessionJSONDecodesNilJump`)

**Interfaces:**
- Consumes: `StoredSession`/`JumpSpec` (M10c), `LoginResolver.resolve(session:sets:secrets:)` + `ResolvedLogin` + `LoginResolveError` (M10b/M10d), `SecretStore`, `InMemorySecretStore`.
- Produces (T2/T3 verlassen sich exakt hierauf):
  - `StoredSession.JumpSpec.sessionID: UUID?` (public var, Init-Parameter mit Default nil, letzter Parameter)
  - `LoginResolveError.missingJumpSession` und `.jumpChainNotSupported` (zwei NEUE Fälle; bestehende unverändert)
  - `LoginResolver.resolveJump(spec:sets:secrets:sessions:referencingSessionID:) throws -> ResolvedJump` — NEUE Rückgabe `ResolvedJump` (`host: String`, `port: Int`, `login: ResolvedLogin`), weil im Session-Modus auch Host/Port aufgelöst werden. Die BESTEHENDE `resolveJump(spec:sets:secrets:)` bleibt als dünner Wrapper erhalten (liefert weiter `ResolvedLogin` aus den Spec-Eigenwerten) ODER wird ersetzt — der Implementer entscheidet die kleinere Lösung und dokumentiert sie; alle Aufrufer müssen kompilieren.
  - `JumpSessionEligibility.eligible(for editingSessionID: UUID?, in sessions: [StoredSession]) -> [StoredSession]`

**Verhaltens-Anforderungen (Spec §1/§2, bindend):**
1. `sessionID` non-nil ⇒ Session-Modus: Host/Port aus der referenzierten Session; das Login über `LoginResolver.resolve(session:sets:secrets:)` der REFERENZIERTEN Session (deckt deren Set/Manuell/Agent ab). `resolve` liefert für manuelle Sessions `nil` (kein Set) — in dem Fall die Session-Eigenwerte + ihr Keychain-Secret verwenden (Agent: kein Secret, kein Keychain-Read).
2. Session nicht in der übergebenen Liste ⇒ `LoginResolveError.missingJumpSession`.
3. Referenzierte Session hat selbst `jump != nil` ⇒ `.jumpChainNotSupported`. Selbstreferenz (`sessionID == referencingSessionID`, sofern nicht-nil) ⇒ ebenfalls `.jumpChainNotSupported`.
4. `sessionID == nil` ⇒ heutiges Verhalten byte-gleich (Spec-Eigenwerte, Set-Auflösung, Agent-Sonderfall).
5. Eligibility: schließt `editingSessionID` und alle Sessions mit `jump != nil` aus; sortiert nach Name case-insensitiv (Sidebar-Ordnung).
6. Decode-Kompatibilität: `sessions.json` ohne `sessionID` liest nil; Roundtrip erhält den Wert.
7. Zwei neue CoreL10n-Meldungen (beide Kataloge): `core.connect.jumpSessionMissing` (EN „The connection used as jump host no longer exists." / DE „Die als Zwischenhost genutzte Verbindung existiert nicht mehr.") und `core.connect.jumpChainNotSupported` (EN „The selected jump host connects through another jump host; chains are not supported." / DE „Die gewählte Verbindung nutzt selbst einen Zwischenhost; Ketten werden nicht unterstützt.").

- [x] **Step 1: Failing Tests**

```swift
    // LoginResolverTests (Ergänzungen):
    // resolveJumpFromSessionUsesItsHostAndLogin: Bastion-Session
    //   (host "b", port 2022, user "deploy", .password, Secret "s")
    //   + Jump-Spec mit sessionID -> ResolvedJump(host "b", port 2022,
    //   login.username "deploy", login.secret "s").
    // resolveJumpFromSessionWithLoginSet: Bastion referenziert ein Set ->
    //   Werte + Secret des SETS.
    // resolveJumpFromAgentSessionReadsNoKeychain: Bastion mit .agent ->
    //   login.authKind == .agent, secret nil, NoReadAllowedSecretStore-Double
    //   schlägt an, falls doch gelesen wird.
    // resolveJumpMissingSessionThrows: sessionID zeigt auf unbekannte UUID
    //   -> LoginResolveError.missingJumpSession.
    // resolveJumpChainThrows: referenzierte Session hat selbst einen Jump
    //   -> .jumpChainNotSupported.
    // resolveJumpSelfReferenceThrows: sessionID == referencingSessionID
    //   -> .jumpChainNotSupported.
    // resolveJumpManualUnchanged: sessionID nil -> exakt die bisherigen
    //   Werte (Regression-Guard für alle drei Auth-Arten).
    //
    // JumpSessionEligibilityTests:
    // excludesEditedSessionAndChains: vier Sessions (A ohne Jump, B ohne
    //   Jump, C mit Jump, D == bearbeitete) -> [A, B] in Namens-Reihenfolge.
    // nilEditingIDKeepsAll: editingSessionID nil -> nur Ketten gefiltert.
    //
    // Decode-Kompat-Datei:
    // legacyJumpJSONDecodesNilSessionID: Raw-sessions.json mit jump-Objekt
    //   OHNE sessionID -> jump?.sessionID == nil, übrige Felder intakt.
```

- [x] **Step 2: Rot beweisen.** `swift test --filter LoginResolverTests` und `--filter JumpSessionEligibility` → FAIL.
- [x] **Step 3: Implementierung** (Modell → Eligibility → Resolver; die Wrapper-Entscheidung aus dem Interfaces-Block dokumentieren).
- [x] **Step 4: Grün + volle Suite.** `swift test` → 595 + neue.
- [x] **Step 5: Commit.** `feat: reference a saved connection as the jump host`

---

### Task 2: Rückstellung beim Löschen + Export-Auflösung (Core)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift`
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift`

**Interfaces:**
- Consumes (T1): `JumpSpec.sessionID`, `ResolvedJump`, `LoginResolver.resolveJump(…sessions:referencingSessionID:)`, `LoginResolveError.missingJumpSession/.jumpChainNotSupported`.
- Produces (T3):
  - `SessionListViewModel.sessionsUsingAsJump(_ id: UUID) -> [StoredSession]` (für die Lösch-Rückfrage)
  - `delete(_:) -> JumpRestoreResult` (`restored: Int`, `secretFailures: Int`, Equatable) — bestehende Aufrufer ignorieren den Rückgabewert (`@discardableResult`)
  - `resolvedJump(for session: StoredSession) throws -> ResolvedJump?` (nil wenn kein Jump; wirft die typisierten Fehler) — T3 nutzt es für die Formular-Zusammenfassung und den Connect

**Verhaltens-Anforderungen (Spec §4/§5, bindend):**
1. `delete(_:)` sammelt VOR dem Löschen die Sessions mit `jump?.sessionID == session.id`. Für jede: Host/Port/Username/authKind/keyPath der GELÖSCHTEN Session in die JumpSpec kopieren, ihr aufgelöstes Secret in den `secretID`-Slot des Jumps schreiben, `sessionID` nullen, `loginSetID` der JumpSpec auf nil setzen (die Rückstellung schreibt konkrete Werte, keine Set-Referenz), upsert. Danach erst die Session selbst löschen (Reihenfolge: erst Rückstellung persistieren, dann löschen — ein Fehler beim Löschen darf keine halb zurückgestellte Welt hinterlassen; im Report begründen, falls die andere Reihenfolge gewählt wird).
2. Agent-Logins der gelöschten Session übertragen KEIN Secret (kein Keychain-Read, kein Write).
3. Keychain-Fehler beim Secret-Transfer zählen in `secretFailures`, brechen nicht ab; die Session wird trotzdem zurückgestellt (M10b-Muster, inkl. der B2-Lektion: nie ein Secret löschen/verschieben, dessen Ersatz-Schreiben scheiterte — hier wird nichts gelöscht, nur kopiert).
4. `exportPayload`: Sessions mit Session-Jump exportieren die AUFGELÖSTEN Jump-Werte (`resolveJump` mit Session-Liste); `jumpPassword` nur bei `includePasswords`; fehlende/kaputte Referenz ⇒ Spec-Eigenwerte, Export bricht nie ab; fehlendes Secret zählt in `missingPasswordCount`. Format bleibt v1, die Referenz wandert NICHT mit.
5. `reload()`/übrige APIs unverändert.

- [x] **Step 1: Failing Tests**

```swift
    // deleteRestoresJumpReferences: Bastion-Session (user/pass "s"),
    //   zwei Sessions referenzieren sie als Jump -> delete(bastion):
    //   beide tragen Host/Port/User/authKind der Bastion in ihrer JumpSpec,
    //   Secret "s" im jump.secretID-Slot, sessionID == nil, loginSetID == nil;
    //   Ergebnis restored == 2, secretFailures == 0.
    // deleteRestoresFromAgentBastionWithoutSecret: Bastion mit .agent ->
    //   JumpSpec trägt .agent, kein Secret geschrieben (NoReadAllowed-Double).
    // deleteCountsSecretFailure: SecretStore-Double, dessen savePassword für
    //   den Jump-Slot wirft -> restored == 1, secretFailures == 1, Werte
    //   trotzdem zurückgestellt.
    // sessionsUsingAsJumpFindsReferences: liefert genau die referenzierenden.
    // exportResolvesSessionJump: Session mit Session-Jump ->
    //   ExportedSession trägt Host/Port/User der Bastion + jumpPassword
    //   (includePasswords true); kaputte Referenz -> Spec-Eigenwerte,
    //   kein Abbruch.
```

- [x] **Step 2: Rot beweisen.** `swift test --filter SessionListViewModelTests` → FAIL.
- [x] **Step 3: Implementierung.** **Step 4: Grün + volle Suite.** **Step 5: Commit** `feat: restore jump references when their connection is deleted`.

---

### Task 3: Umschalter + Picker + Wiring + L10n (App)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift` (Felder + Validierung + JumpSpec-Bau), `Sources/MacSCPApp/ConnectionFormView.swift` (Umschalter, Picker, Zusammenfassung), `Sources/MacSCPApp/ContentView.swift` (Connect-Auflösung, Save-Pfade, Edit-Prefill, Lösch-Rückfrage, Fehler-Mapping), `Sources/MacSCPApp/SessionSidebar.swift` (Lösch-Rückfrage-Text, falls dort formuliert — per grep), `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj`
- Test: drei Core-Tests für die neuen VM-Felder/Validierung (siehe unten); sonst keine (App-Target; Smoke in T4)

**Interfaces:**
- Consumes (T1/T2): `JumpSessionEligibility.eligible(for:in:)`, `ResolvedJump`, `resolvedJump(for:)`, `sessionsUsingAsJump(_:)`, `delete(_:) -> JumpRestoreResult`, die beiden neuen `LoginResolveError`-Fälle; bestehend: der M10c-Jump-Block, `showFailure`, `fillJumpForm`, die M10b/M10d-Segment-Muster.

**Verhaltens-Anforderungen (Spec §3, bindend):**
1. `ConnectionViewModel`: `jumpSourceMode: JumpSourceMode` (`.session`/`.manual`, Default `.manual`), `jumpSessionID: UUID?`. `exitEditMode()`/`endEditing()` setzen BEIDE zurück (M10b-Sticky-Lektion). Neuer `Field`-Fall `.jumpSession` für Highlights.
2. Validierung in `connect()` UND `validateForEditSave()`: bei `jumpEnabled && jumpSourceMode == .session` ist eine Auswahl Pflicht (`jumpSessionID != nil`, sonst `.failed` mit `.jumpSession`); die Manuell-Prüfungen (Host/Port/Login) entfallen in diesem Modus vollständig. `buildJumpSpec` setzt `sessionID` und lässt die Manuell-Felder unverändert stehen (sie werden ignoriert); `buildJumpConfig` wird im Session-Modus NICHT mehr aus den Formularfeldern gebaut — die App füllt die Jump-Felder vor dem Connect aus der Auflösung (Punkt 4a).
3. Formular: Segment-Umschalter `Gespeicherte Verbindung | Manuell` über der Jump-Host-Zeile. Session-Modus: Picker über `JumpSessionEligibility.eligible(for: <bearbeitete Session-ID oder nil>, in: sessionListViewModel.sessions)` (Anzeige: Session-Name), darunter eine nicht editierbare Zusammenfassung `host:port · user · <Auth-Kurzform>` aus `resolvedJump`; bei Auflösungsfehler steht dort die lokalisierte Fehlermeldung in Rot statt der Zusammenfassung. Manuell-Modus: heutiger Block unverändert.
4. Wiring in ContentView:
   a. Vor `form.connect()` im Session-Modus die Referenz auflösen und Host/Port/Login in die Jump-Formularfelder füllen (Muster `fillJumpForm`); Fehler (`missingJumpSession`/`jumpChainNotSupported`) ⇒ `showFailure` mit der jeweiligen Meldung und Feld `.jumpSession`, KEIN Connect.
   b. `connect(in:stored:)`: `resolvedJump(for: stored)` — non-nil füllt die Jump-Felder; die beiden Fehler ⇒ nicht verbinden, Meldung zeigen.
   c. Edit-Prefill: `jump?.sessionID` gesetzt ⇒ `jumpSourceMode = .session` + Vorauswahl; sonst `.manual` (heutiges Prefill).
   d. Lösch-Rückfrage der Sidebar nennt zusätzlich die Anzahl referenzierender Verbindungen, wenn `sessionsUsingAsJump` nicht leer ist (EN „%lld connections use this connection as their jump host and will keep its data directly." / DE „%lld Verbindungen nutzen diese Verbindung als Zwischenhost und behalten deren Daten direkt hinterlegt."); `secretFailures > 0` nach dem Löschen ⇒ rote Meldung wie beim Login-Set-Löschen.
5. Alle neuen Keys EN/DE in beiden App-Katalogen (+ die beiden Core-Keys aus T1); Grep-Gegenprobe Key-Set-Gleichheit.

- [x] **Step 1:** VM-Felder + Validierung + 3 Tests (`jumpSessionModeRequiresSelection`, `jumpSessionModeSkipsManualChecks`, `jumpSourceFieldsResetOnExitEditMode`) rot→grün. **Step 2:** Formular (Umschalter, Picker, Zusammenfassung). **Step 3:** ContentView-Wiring a–d. **Step 4:** L10n + Gegenprobe. **Step 5:** `swift build` (0 Fehler, keine neuen Warnungen) + volle `swift test`. **Step 6:** Commit `feat: pick a saved connection as the jump host in the form`.

---

### Task 4: Abschluss-Verifikation (Koordinator)

- [x] Gated Rig-Test ergänzen (in der bestehenden Docker-Suite): gespeicherte Bastion-Session (127.0.0.1:2222) als `sessionID`-Jump für ein Ziel auf `sshd2:2222` ⇒ `list("/")` ok; zweiter Test: Bastion-Session mit eigenem Jump ⇒ `jumpChainNotSupported` (ohne Netzwerkzugriff).
- [x] Rig `start`, `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → alle grün, zero skips, keine Leichen (ssh-agent, temp-Verzeichnisse); Rig `stop`.
- [ ] Visueller Smoke — an den Maintainer delegiert (Checkliste: Umschalter + Picker, Verbindung über eine gespeicherte Bastion, Bastion löschen ⇒ Rückfrage nennt die Anzahl ⇒ danach funktioniert die Verbindung weiter, Ketten-Ablehnung, Export/Import einer Session mit Session-Jump).
- [x] Plan-Checkboxen, Ledger, Opus-Final-Review (Package über `git merge-base origin/develop HEAD`), Fix-Runden bis „Yes", Push develop, `gh run watch`, Memory, Zusammenfassung. KEIN Release.
