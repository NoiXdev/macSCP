# M11e — Backlog-Sweep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die aus M10 gesammelten Härtungs- und Hygiene-Punkte abräumen (Agent-Frame-Limit, Signatur-Timeout, ehrliche Meldung bei unbrauchbaren Identitäten, Ziel-Set-Asymmetrie), den Audit-Eintrag um den Jump-Kontext ergänzen, die Test-Hygiene reparieren und die zwei nutzerrelevanten Grenzen im README dokumentieren.

**Architecture:** Rein additive Härtungen an bestehenden Typen (`SSHAgentClient`, `AgentBackedPrivateKey`, `AgentError`, `CitadelFileSystem.connectHop`), eine Signatur-Angleichung in der App (`resolveSelectedLoginSet` → `Bool` wie sein Jump-Gegenstück), ein optionaler Parameter am `AuditRecorder`, plus Test- und Doku-Arbeit. Kein neues Feature, keine neuen Dateien außer Tests.

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, SwiftUI.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-29-m11e-backlog-sweep-design.md` — bindend. Branch: **develop**.
- KEINE Verhaltensänderung außerhalb der genannten Punkte; insbesondere TOFU-Invarianten, die M10d-Reconnect-Semantik (Cap `min(n,6)`, jede Identität einmal, Rethrow außer bei `allAuthenticationOptionsFailed`) und die Agent-Regel „kein Keychain-Zugriff auf Agent-Pfaden" bleiben unangetastet.
- Der private Schlüssel verlässt nie den Agent; keine neuen Secrets, keine neuen Dependencies.
- Alle neuen UI-/Fehlertexte EN/DE in BEIDEN zugehörigen Katalogen; Code + Kommentare NUR Englisch; README Englisch.
- Conventional Commits (Englisch), Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + volle `swift test` nach jedem Task grün (Ausgangslage 589 Tests / 43 Suiten); gated Suiten in T3; Tests SYNCHRON im Vordergrund; TDD rot→grün für Core.
- Docker-Rig nur `start`/`stop` aus dem Haupt-Checkout; gated Agent-Tests starten ihren EIGENEN ssh-agent und beenden ihn (nie den Agent des Nutzers anfassen).
- KEIN Release, kein Merge nach main.

## Schedule

T1 (Core-Härtungen + Ziel-Set-Asymmetrie) → T2 (Audit-Jump-Kontext + Test-Hygiene) → T3 (README + Abschluss, Koordinator).

---

### Task 1: Agent-Härtungen + Ziel-Set-Asymmetrie

**Files:**
- Modify: `Sources/macSCPCore/SSH/SSHAgentClient.swift` (Frame-Limit), `Sources/macSCPCore/SSH/AgentBackedPrivateKey.swift` (Signatur-Timeout), `Sources/macSCPCore/SSH/SSHAgentCodec.swift` (nur falls `AgentError` dort definiert ist — per grep prüfen), `Sources/macSCPCore/SSH/CitadelFileSystem.swift` (`noUsableIdentities`, redundante Variable), `Sources/MacSCPApp/ContentView.swift` (`resolveSelectedLoginSet`), `Sources/MacSCPApp/ConnectionFormView.swift` (Aufrufer, falls die Signaturänderung dorthin durchschlägt — die drei Button-Handler nutzen bereits `guard resolveLoginSetForSubmit() else { return }`), Core-L10n-Kataloge (EN + DE)
- Test: `Tests/macSCPCoreTests/SSHAgentClientTests.swift`, `Tests/macSCPCoreTests/AgentAuthTests.swift`

**Interfaces:**
- Produces: `AgentError.noUsableIdentities` (neuer Fall; bestehende Fälle unverändert), `SSHAgentClient` mit Frame-Obergrenze, `AgentBackedPrivateKey` mit Signatur-Deadline, App-seitig `resolveSelectedLoginSet(in:) -> Bool`.
- Consumes: bestehende `AgentError`-Fälle, `AgentAuthContext`/`connectHop` aus M10d, das Jump-Gegenstück `resolveSelectedJumpLoginSet(in:) -> Bool` als Vorbild (gleiche Fehlermeldung `loginSets.missingSet`, gleiche Rückgabesemantik).

**Verhaltens-Anforderungen (Spec §2, bindend):**
1. **Frame-Limit:** `SSHAgentClient`s Antwort-Akkumulator akzeptiert eine deklarierte Länge bis maximal `256 * 1024`. Größer ⇒ sofort `AgentError.protocolError(reason:)` mit der Länge im Text, ohne weiter zu puffern und ohne auf das Deadline zu warten. Konstante benannt (`maxFrameLength`) und kommentiert (OpenSSH-Maximum).
2. **Signatur-Timeout:** das Warten in `AgentBackedPrivateKey.signature(for:)` (Semaphore) bekommt ein Wall-Clock-Limit von 15 s; Ablauf ⇒ `AgentError.protocolError(reason: "agent sign timed out")`. Der bestehende Transport-Deadline bleibt; dieses Limit ist die zweite Verteidigungslinie (Promise wird nie erfüllt, z. B. Task auf heruntergefahrener Event-Loop).
3. **`noUsableIdentities`:** wenn nach dem `AgentPrivateKeyFactory.supports`-Filter KEINE Identität übrig bleibt, OBWOHL der Agent Identitäten geliefert hat, wirft der Connect `AgentError.noUsableIdentities` statt `.noIdentities`. Leerer Agent ⇒ weiterhin `.noIdentities`. Beide Fälle sind typisiert und laufen durch die bestehende Mapping-Kette (kein Stringifizieren).
4. **Redundante Variable:** `authRejectionError` in der Reconnect-Schleife entfällt; das Verhalten (Fehler beim Verlassen der Schleife) bleibt identisch — der letzte Fehler IST nach dem M10d-Fix immer der Auth-Fehler, weil andere Fehler sofort rethrown werden. Kommentar anpassen.
5. **Ziel-Set-Asymmetrie:** `resolveSelectedLoginSet(in:)` liefert `Bool`: `true` bei nil-Set-Modus (nichts zu tun) und bei erfolgreicher Auflösung; `false` wenn `loginMode == .set` und die referenzierte ID NICHT in `sessionListViewModel.loginSets` liegt — in dem Fall `form.showFailure(message: L10n.string("loginSets.missingSet", …), field: nil)` (identisch zum Jump-Gegenstück, das `.jumpHost` nutzt; fürs Ziel ist `nil` richtig, da kein passendes Feld existiert). Der bestehende Sammel-Aufrufer (`resolveLoginSetForSubmit`) verundet beide Ergebnisse und gibt weiterhin `Bool` zurück; die drei Button-Handler bleiben unverändert.
6. Neue Core-Meldung für `noUsableIdentities` in beiden Core-Katalogen (EN: „The SSH agent has no usable identities (unsupported key types)." / DE: „Der SSH-Agent hat keine nutzbaren Identitäten (nicht unterstützte Schlüsseltypen)."), verdrahtet an derselben Stelle wie die bestehenden Agent-Meldungen (grep `socketUnavailable` in der App/VM-Fehlerabbildung).

- [x] **Step 1: Failing Tests**

```swift
    // SSHAgentClientTests:
    // oversizedFrameThrowsProtocolError: Mock-Transport liefert ein Frame,
    //   dessen deklarierte Länge 256*1024 + 1 ist -> AgentError.protocolError;
    //   kein Hänger (Test läuft in Millisekunden, nicht bis zum Deadline).
    // maxAllowedFrameStillParses: Länge exakt 256*1024 mit gültiger
    //   IDENTITIES_ANSWER-Payload -> parst normal (Grenzwert inklusiv).
    //
    // AgentAuthTests:
    // signTimesOutWithProtocolError: Mock-Transport, der NIE antwortet
    //   (await-Suspension ohne Rückgabe) -> signature(for:) wirft
    //   AgentError.protocolError; Test injiziert ein KURZES Limit, damit er
    //   nicht 15 s läuft (Timeout als injizierbarer Parameter mit Default 15,
    //   im Report begründen).
    // allUnsupportedIdentitiesThrowNoUsableIdentities: Agent liefert zwei
    //   Identitäten mit Typ "ssh-dss" (nicht unterstützt) -> Connect wirft
    //   AgentError.noUsableIdentities (NICHT .noIdentities).
    // emptyAgentStillThrowsNoIdentities: bestehender Test bleibt grün
    //   (Regression-Guard, nicht neu schreiben).
```

- [x] **Step 2: Rot beweisen.** `swift test --filter SSHAgentClientTests` und `--filter AgentAuthTests` → FAIL.
- [x] **Step 3: Implementierung** in der Reihenfolge 1→5 der Verhaltens-Anforderungen; nach jedem Punkt kompilieren.
- [x] **Step 4: Grün + volle Suite.** `swift test` → 589 + neue, 0 Failures.
- [x] **Step 5: Commit.** `fix: harden the agent client and refuse dangling target login sets`

---

### Task 2: Audit-Jump-Kontext + Test-Hygiene

**Files:**
- Modify: `Sources/macSCPCore/Sessions/AuditRecorder.swift` (`recordConnected`), `Sources/MacSCPApp/ContentView.swift` (Aufrufer — grep `recordConnected`, zwei Stellen: Formular-Connect und `connect(in:stored:)`), `Tests/macSCPCoreTests/AuditRecorderTests.swift` (bzw. die Datei, die `recordConnected` testet — per grep), `Tests/macSCPCoreTests/AgentAuthTests.swift` + `Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift` (env-Serialisierung, temp-Cleanup), `Tests/macSCPCoreTests/SSHAgentClientTests.swift` (Mock-Queue-Test)

**Interfaces:**
- Produces: `AuditRecorder.recordConnected(host:username:viaJumpHost: String? = nil)` (defaulted — bestehende Aufrufer kompilieren weiter).

**Verhaltens-Anforderungen (Spec §3/§4, bindend):**
1. **Audit-Detail:** ohne Jump byte-identisch zu heute (`connected to <host> as <user>`); mit Jump `connected to <host> as <user> via <jumphost>`. NUR der Jump-HOST — kein Benutzername der Bastion, keine Zugangsdaten, kein Port-Zwang (Port nur, wenn er ohnehin Teil des Host-Strings ist). Die App reicht `stored.jump?.host` bzw. den Formularwert durch (nur wenn der Jump aktiv ist).
2. **env-Wettlauf:** `AgentAuthTests` und die gated Agent-Tests mutieren beide `SSH_AUTH_SOCK`. Beide Stellen über EINE gemeinsame Serialisierung absichern — bevorzugt ein kleiner, gemeinsam genutzter Helfer (z. B. `AgentEnvLock` in einer Test-Hilfsdatei) mit einem globalen Lock um Setzen/Zurücksetzen; alternativ beide Suiten in dieselbe `.serialized`-Suite ziehen. Die gewählte Lösung im Report begründen.
3. **Temp-Cleanup:** jeder Test in `CitadelFileSystemIntegrationTests`, der ein temporäres KnownHosts-Verzeichnis anlegt, räumt es per `defer { try? FileManager.default.removeItem(at: dir) }` auf — inklusive der drei vorbestehenden Stellen (grep `NSTemporaryDirectory` / `temporaryDirectory` in der Datei; das Muster steht bereits an einer Stelle).
4. **Mock-Queue-Test:** `transportErrorMapsToProtocolErrorDuringOperation` prüft aktuell den Mock-Erschöpfungs-Pfad. Auf einen einzigen do/catch mit EINEM gestellten Transport-Fehler umstellen, sodass die Assertion wirklich die Fehler-Abbildung trifft.

- [x] **Step 1: Failing Tests**

```swift
    // AuditRecorder-Suite:
    // connectedWithoutJumpKeepsDetail: recordConnected(host:"h", username:"u")
    //   -> Detail exakt "connected to h as u" (Regression-Guard).
    // connectedWithJumpNamesTheHop: recordConnected(host:"h", username:"u",
    //   viaJumpHost: "bastion") -> Detail "connected to h as u via bastion";
    //   Detail enthält KEINEN Bastion-Benutzernamen (kein " as " nach "via").
```

- [x] **Step 2: Rot beweisen.** `swift test --filter Audit` → FAIL.
- [x] **Step 3: Implementierung** Punkt 1, dann die Test-Hygiene-Punkte 2–4 (reine Testarbeit, kein Produktionscode).
- [x] **Step 4: Grün + volle Suite + gated.** `swift test` UND `MACSCP_ITEST=1 swift test --filter CitadelFileSystemIntegrationTests` → grün; zusätzlich zweimal hintereinander gated laufen lassen und bestätigen, dass keine temporären `known_hosts`-Verzeichnisse zurückbleiben (Pfad-Zählung vorher/nachher im Report).
- [x] **Step 5: Commit.** `test: serialize the agent env and record the jump host in the audit log`

---

### Task 3: README + Abschluss (Koordinator)

**Files:**
- Modify: `README.md` (neuer Abschnitt `## Known limitations` vor `## Install`)

- [x] **Step 1: README-Abschnitt** (Englisch, drei Punkte exakt nach Spec §1: RSA-über-Agent gegen Go-basierte Server; mehrere Agent-Identitäten als getrennte Login-Versuche + fail2ban-Risiko; Audit-Log-Ort). Sachlicher Ton, keine Marketing-Sprache, keine Stack-Begriffe im Intro-Teil des README (der neue Abschnitt selbst darf technisch sein).
- [x] **Step 2: Gated Suiten** am finalen Stand: Rig `start`, `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → alle grün, zero skips, keine zurückgelassenen ssh-agent-Prozesse; Rig `stop`.
- [x] **Step 3:** Plan-Checkboxen, Ledger, Opus-Final-Review (Package über `git merge-base origin/develop HEAD`), Fix-Runden bis „Yes", Push develop, `gh run watch`, Memory, Zusammenfassung. KEIN Release.
