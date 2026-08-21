# Verbindungszustand — Umsetzungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eine Sitzung sagt jederzeit, ob sie lebt — und bietet nach einem Abriss den Weg zurück, ohne dass die App beim toten Host einfriert.

**Architecture:** Ein Zustandswert je Sitzung in Core, getrieben von einer reinen Entscheidungsregel; eine Sonde als `.task(id:)` nach dem Muster der bestehenden Auto-Refresh-Schleife; Anzeige als Punkt am Reiter und als Fläche im Tab, die Aufbau, Betrieb und Verlust mit **einem** Mechanismus abdeckt.

**Tech Stack:** Swift 6 in `.swiftLanguageMode(.v5)`, SwiftPM, macOS 15+, Swift Testing, SwiftUI + AppKit, Citadel/NIOSSH.

**Spec:** `docs/superpowers/specs/2026-08-21-verbindungszustand-design.md`

## Global Constraints

- Code, Kommentare, Bezeichner, Testnamen, Commit-Messages: **nur Englisch.** Interne Doku darf Deutsch bleiben.
- Conventional Commits; Footer auf jedem Commit: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- `macSCPCore` importiert **kein** SwiftTerm und **kein** AppKit.
- Neue nutzersichtbare Zeichenketten in **allen vier** Katalogen (`en`, `de`, `fr`, `pl`); ein Wächtertest erzwingt gleiche Schlüsselmengen.
- **TOFU bleibt ein harter Stopp.** Der Wiederaufbau benutzt denselben Verbindungspfad wie ein frischer Aufbau; es entsteht kein zweiter Pfad.
- Kein Geheimnis und kein vom Nutzer getippter Wert in Protokoll, Export, Fehlermeldung oder Testfehlertext.
- Abbau nur über die bestehende Reihenfolge `cancelAll` → Terminal `shutdown` → `disconnect`; kein `deinit`-Aufräumen.
- Nie eine Zeilennummer in einen Kommentar. Eine Zahl oder Aufzählung im Kommentar wird **in demselben Durchgang gezählt**, in dem sie geschrieben wird.
- Neue Logik kommt mit Tests; Regressionen zuerst rot beweisen.
- Die App wird **nicht** gestartet. `scripts/release` wird **nicht** ausgeführt.

---

### Task 1: Zustand und Entscheidungsregel (Core, reine Logik)

**Files:**
- Create: `Sources/macSCPCore/Sessions/ConnectionLiveness.swift`
- Test: `Tests/macSCPCoreTests/ConnectionLivenessTests.swift`

**Interfaces:**
- Produces: `ConnectionLiveness` (4 Fälle), `LivenessProbePolicy.decide(...) -> LivenessProbeAction`, `LivenessProbePolicy.probeTimeout(forInterval:)`, `ReconnectBackoff.delay(forAttempt:)`
- Consumes: nichts

- [ ] **Step 1: Test zuerst — der Zustand und die Ableitung der Sondenfrist**

```swift
@Test func theProbeTimeoutIsHalfTheIntervalCappedAtTen() {
    #expect(LivenessProbePolicy.probeTimeout(forInterval: 60) == 10)
    #expect(LivenessProbePolicy.probeTimeout(forInterval: 20) == 10)
    #expect(LivenessProbePolicy.probeTimeout(forInterval: 12) == 6)
    // Never zero, never longer than the interval: a probe that outlives its
    // own tick would overlap the next one.
    #expect(LivenessProbePolicy.probeTimeout(forInterval: 1) == 1)
}

@Test func aBusyQueueProvesLivenessBetterThanAProbe() {
    #expect(LivenessProbePolicy.decide(queueIsBusy: true, consecutiveFailures: 0) == .skip)
}

@Test func theFirstFailureDegradesAndRetriesTheSecondGivesUp() {
    #expect(LivenessProbePolicy.decide(queueIsBusy: false, consecutiveFailures: 0) == .probe)
    #expect(LivenessProbePolicy.decide(queueIsBusy: false, consecutiveFailures: 1) == .probeAgainNow)
    #expect(LivenessProbePolicy.decide(queueIsBusy: false, consecutiveFailures: 2) == .giveUp)
}

@Test func theBackoffDoublesFromFiveAndStopsAtSixty() {
    #expect(ReconnectBackoff.delay(forAttempt: 1) == 5)
    #expect(ReconnectBackoff.delay(forAttempt: 2) == 10)
    #expect(ReconnectBackoff.delay(forAttempt: 3) == 20)
    #expect(ReconnectBackoff.delay(forAttempt: 4) == 40)
    #expect(ReconnectBackoff.delay(forAttempt: 5) == 60)
    #expect(ReconnectBackoff.delay(forAttempt: 99) == 60)
}
```

- [ ] **Step 2: Rot laufen lassen**

Run: `swift test --filter ConnectionLiveness`
Expected: FAIL, die Typen existieren nicht.

- [ ] **Step 3: Minimal umsetzen**

```swift
/// What a session's connection is doing right now. Four states, three
/// colours: `connecting` and `degraded` share amber, because both mean
/// "macSCP does not know yet" and the user's next move is the same — wait
/// or cancel.
public enum ConnectionLiveness: Equatable, Sendable {
    case connecting
    case connected
    /// One probe failed and a second is on its way. Without this state a
    /// single lost packet would look exactly like a severed connection.
    case degraded
    case lost
}

public enum LivenessProbeAction: Equatable, Sendable {
    case skip
    case probe
    case probeAgainNow
    case giveUp
}

public enum LivenessProbePolicy {
    public static func decide(queueIsBusy: Bool, consecutiveFailures: Int) -> LivenessProbeAction {
        if queueIsBusy { return .skip }
        switch consecutiveFailures {
        case 0: return .probe
        case 1: return .probeAgainNow
        default: return .giveUp
        }
    }

    /// Deliberately not a setting: a probe timeout longer than the interval
    /// would let probes overlap, and a user-editable settings file could
    /// produce exactly that.
    public static func probeTimeout(forInterval interval: Int) -> Int {
        max(1, min(10, interval / 2))
    }
}

public enum ReconnectBackoff {
    public static func delay(forAttempt attempt: Int) -> Int {
        guard attempt > 1 else { return 5 }
        return min(60, 5 * (1 << min(attempt - 1, 10)))
    }
}
```

- [ ] **Step 4: Grün laufen lassen**

Run: `swift test --filter ConnectionLiveness`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Sessions/ConnectionLiveness.swift Tests/macSCPCoreTests/ConnectionLivenessTests.swift
git commit -m "feat(core): decide when to probe a connection and when to give up"
```

---

### Task 2: Die drei Einstellungen (Core)

**Files:**
- Modify: `Sources/macSCPCore/Settings/SettingsStore.swift`
- Test: `Tests/macSCPCoreTests/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: `ConnectionLiveness.swift` aus Task 1 (nur für `ReconnectBehaviour`s Nachbarschaft, kein Zwang)
- Produces: `SettingsStore.reconnectBehaviour`, `.keepAliveIntervalSeconds`, `.connectTimeoutSeconds`, und `ReconnectBehaviour`

**Muster:** `autoRefreshIntervalSeconds` in derselben Datei. Die Tests bauen
den Store als `SettingsStore(directory: dir)` über ein temporäres
Verzeichnis — so macht es `SettingsStoreTests` durchgehend, es gibt dort
keinen Fabrik-Helfer — Getter klemmt **und** Setter klemmt, damit eine von Hand editierte `settings.json` weder Spam noch einen toten Zeitgeber erzeugen kann. Genauso hier.

- [ ] **Step 1: Test zuerst**

```swift
@Test func theKeepAliveIntervalIsClampedOnBothEnds() {
    let store = SettingsStore(directory: dir)
    store.keepAliveIntervalSeconds = 5
    // 0 means off and is the ONLY value below the floor that survives.
    #expect(store.keepAliveIntervalSeconds == 15)
    store.keepAliveIntervalSeconds = 0
    #expect(store.keepAliveIntervalSeconds == 0)
    store.keepAliveIntervalSeconds = 9_999
    #expect(store.keepAliveIntervalSeconds == 600)
}

@Test func theConnectTimeoutIsClampedAndDefaultsBelowCitadelsThirty() {
    let store = SettingsStore(directory: dir)
    #expect(store.connectTimeoutSeconds == 10)
    store.connectTimeoutSeconds = 1
    #expect(store.connectTimeoutSeconds == 5)
    store.connectTimeoutSeconds = 10_000
    #expect(store.connectTimeoutSeconds == 120)
}

@Test func reconnectDefaultsToOfferingOnly() {
    #expect(SettingsStore(directory: dir).reconnectBehaviour == .offerOnly)
}
```

- [ ] **Step 2: Rot laufen lassen** — `swift test --filter SettingsStore`, FAIL.

- [ ] **Step 3: Umsetzen**

```swift
/// What macSCP does when a session's connection is found gone.
public enum ReconnectBehaviour: String, CaseIterable, Sendable {
    /// Nothing happens without a click. The default, because reconnecting
    /// re-authenticates — a keychain read, possibly a passphrase — and a
    /// changed host key is a hard stop that needs a person.
    case offerOnly
    case onceThenAsk
    case automatic
}
```

Dazu die drei Eigenschaften nach dem Muster von `autoRefreshIntervalSeconds`.
Klemmung: Intervall `0` **oder** `15...600`; Frist `5...120`, Vorgabe `10`.
`ReconnectBehaviour` wird wie `TerminalCursorStyle` als `String` abgelegt und
fällt bei unbekanntem Inhalt auf `.offerOnly` zurück.

- [ ] **Step 4: Grün laufen lassen.**

- [ ] **Step 5: Commit** — `feat(core): settle how long a connection may stay silent`

---

### Task 3: Die Aufbaufrist tatsächlich übergeben (Core)

**Files:**
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift`
- Test: `Tests/macSCPCoreTests/CitadelFileSystemTests.swift`

**Interfaces:**
- Consumes: `SettingsStore.connectTimeoutSeconds`
- Produces: ein `connectTimeout`-Parameter am Verbindungs-Einstieg, bis zu **beiden** Aufrufstellen durchgereicht

**Der Befund:** `SSHClient.connect(host:port:…)` trägt
`connectTimeout: TimeAmount = .seconds(30)`. `CitadelFileSystem` ruft diese
Überladung **zwei** Mal auf — Sprung-Hop und Ziel — und übergibt den
Parameter an keiner. Beide Stellen sind zu versorgen; eine allein ließe eine
Kette mit Sprung-Host bei der alten Wartezeit.

- [ ] **Step 1: Wächtertest zuerst** — ein Quellscan nach dem Muster der
  bestehenden Wiring-Guards: `SSHClient.connect(` in dieser Datei kommt nie
  ohne `connectTimeout:` vor. Fail-closed, mit Selbsttest gegen einen
  synthetischen Quelltext, und **durch Mutation geprüft**: einen der beiden
  Aufrufe entschärfen, rot sehen, zurücknehmen, grün sehen. Beide Ergebnisse
  in den Bericht.

- [ ] **Step 2: Rot laufen lassen.**

- [ ] **Step 3: Umsetzen** — Parameter am Einstieg ergänzen, an beide
  Aufrufe durchreichen, Aufrufer aus der App mit
  `settingsStore.connectTimeoutSeconds` versorgen.

- [ ] **Step 4: Grün laufen lassen** (volle Suite, nicht nur der Filter).

- [ ] **Step 5: Commit** — `fix(ssh): pass the connect timeout Citadel already offers`

---

### Task 4: Zustand und Sonde an der Sitzung (App)

**Files:**
- Modify: `Sources/MacSCPAppKit/SessionTab.swift` (Zustand an `BrowserSession`/`SessionTab`)
- Modify: `Sources/MacSCPAppKit/ContentView+Detail.swift` (Sondenschleife)
- Test: `Tests/macSCPAppKitTests/LivenessProbeWiringGuardTests.swift`

**Interfaces:**
- Consumes: Task 1 (`LivenessProbePolicy`), Task 2 (Einstellungen)
- Produces: ein lesbarer `ConnectionLiveness` je Tab

**Muster, das schon dasteht:** die Auto-Refresh-Schleife in
`ContentView+Detail.swift` — `.task(id: session.id)`, Einstellungen **frisch
pro Runde** gelesen, übersprungene Runden schlafen weiter. Die Sonde folgt
derselben Form, damit ein Tabwechsel oder ein Abbau sie mit abräumt.

Die Sonde ruft `stat` auf den **beim Verbinden ermittelten Heimatpfad**.
`homeDirectoryPath()` läuft ohnehin beim Aufbau; der Wert wird dort
festgehalten, damit die Sonde keinen zweiten Rundlauf braucht, um ihr Ziel
zu finden.

- [ ] **Step 1: Wächtertest zuerst** — drei Aussagen über den Quelltext,
  jede durch Mutation geprüft: die Schleife liest das Intervall in der
  Schleife (nicht davor), sie fragt `LivenessProbePolicy` statt selbst zu
  entscheiden, und bei `.giveUp` läuft der Abbau über `teardownSession`
  statt über einen eigenen Weg.
- [ ] **Step 2: Rot.**
- [ ] **Step 3: Umsetzen.** Intervall `0` heißt: gar keine Sonde.
- [ ] **Step 4: Grün.**
- [ ] **Step 5: Commit** — `feat(app): probe an idle session and notice when it dies`

---

### Task 5: Der Punkt am Reiter (App)

**Files:**
- Modify: `Sources/MacSCPAppKit/TabStripView.swift`
- Modify: alle vier `Localizable.strings`

**Interfaces:** Consumes: Task 4.

Ein kleiner Punkt vor `tab.displayTitle`: grün `connected`, gelb
`connecting`/`degraded`, rot `lost`. **Farbe ist nie die einzige Aussage** —
jeder Zustand bekommt einen `help`-Text und ein `accessibilityLabel`, sonst
ist der Reiter für Farbenblinde und für VoiceOver stumm.

- [ ] Step 1: Katalogschlüssel in allen vier Sprachen, Wächtertest grün.
- [ ] Step 2: Punkt zeichnen, Farben aus `DesignTokens`, keine Literale.
- [ ] Step 3: Volle Suite grün.
- [ ] Step 4: Commit — `feat(app): show each tab whether its session is alive`

---

### Task 6: Aufbau als abbrechbarer Tab-Zustand (App)

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView+Detail.swift`
- Modify: alle vier `Localizable.strings`

**Interfaces:** Consumes: Task 3 (Frist), Task 4 (Zustand).

Der Tab zeigt „Verbinde …" mit **Abbrechen**, der Rest der App bleibt
bedienbar. Abbrechen bricht die Aufgabe ab und räumt über `teardownSession`
ab — nicht über einen eigenen Weg.

**Wenn bei der Umsetzung auffällt, dass der Hauptthread tatsächlich
blockiert** (statt nur eine tote Fläche zu zeigen), ist das ein eigener
Befund: melden, nicht nebenbei mitreparieren. Die Spec hält ausdrücklich
fest, dass dies ungemessen ist.

- [ ] Step 1: Katalogschlüssel. — [ ] Step 2: Fläche und Abbruch.
- [ ] Step 3: Volle Suite. — [ ] Step 4: Commit — `fix(app): let a connection attempt be cancelled`

---

### Task 7: Fehleransicht und Wiederverbinden (App)

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView+Detail.swift`
- Create: `Tests/macSCPAppKitTests/ReconnectWiringGuardTests.swift`
- Modify: alle vier `Localizable.strings`

**Interfaces:** Consumes: Task 2 (`reconnectBehaviour`), Task 4, Task 6 (dieselbe Fläche).

`lost` zeigt Grund und **„Erneut verbinden"**. Der Wiederaufbau ruft
**denselben** Verbindungspfad wie ein frischer Aufbau.

- [ ] **Step 1: Wächtertest zuerst**, durch Mutation geprüft: der
  Wiederaufbau ruft die gemeinsame Verbindungsfunktion und nicht Citadel
  direkt. Das ist die Stelle, an der ein zweiter Pfad entstehen würde — und
  mit ihm eine zweite Gelegenheit, TOFU zu vergessen.
- [ ] Step 2: Rot. — [ ] Step 3: Umsetzen, inkl. `onceThenAsk` und
  `automatic` mit `ReconnectBackoff`; ein Versuch, der auf TOFU oder eine
  Passphrase läuft, endet in der Fehleransicht und wird **nicht**
  wiederholt.
- [ ] Step 4: Volle Suite. — [ ] Step 5: Commit — `feat(app): offer the way back after a connection is lost`

---

### Task 8: Übertragungen beim Abriss (App/Core)

**Files:**
- Modify: die Warteschlangen-Anbindung in `Sources/MacSCPAppKit/ContentView+Transfers.swift`
- Modify: alle vier `Localizable.strings`
- Test: `Tests/macSCPCoreTests/` (Grund und Erhalt der Liste)

Laufende Übertragung scheitert mit dem Grund „Verbindung verloren";
wartende bleiben in der Liste und werden gekennzeichnet. **Nichts wird
verworfen, nichts fortgesetzt.**

- [ ] Step 1: Test — nach dem Abriss ist die Zahl der gelisteten Einträge
  unverändert und der Grund gesetzt.
- [ ] Step 2: Rot. — [ ] Step 3: Umsetzen. — [ ] Step 4: Grün.
- [ ] Step 5: Commit — `feat(transfers): keep the queue after a connection is lost`

---

### Task 9: Einstellungen sichtbar machen (App)

**Files:**
- Modify: `Sources/MacSCPAppKit/SettingsView.swift`
- Modify: alle vier `Localizable.strings`

Drei Bedienelemente nach dem Muster des Auto-Refresh-Abschnitts derselben
Datei; das Intervallfeld ist deaktiviert, wenn das Intervall `0` ist.

- [ ] Step 1: Katalogschlüssel, Wächtertest grün.
- [ ] Step 2: Bedienelemente.
- [ ] Step 3: Volle Suite grün.
- [ ] Step 4: Commit — `feat(settings): expose the connection's liveness options`

---

### Task 10: Beweis gegen das Docker-Rig

**Files:**
- Test: `Tests/macSCPCoreTests/` (hinter `MACSCP_ITEST=1`)

**Rig immer aus dem Haupt-Checkout starten, nie aus einem Worktree** — die
Seed-Einbindung ist relativ zur Compose-Datei.

- [ ] Step 1: Sonde gegen die lebende Gegenseite ist erfolgreich.
- [ ] Step 2: Container anhalten → die Sonde schlägt fehl und der Zustand
  wird `lost`. Das ist der einzige Test dieses Zweigs, der einen echten
  Abriss erzeugt; ohne ihn ist die ganze Erkennung nur behauptet.
- [ ] Step 3: Commit — `test(itest): prove the probe notices a real drop`

---

## Was ausdrücklich nicht dazugehört

- Kein `SO_KEEPALIVE`, kein eigenes Bootstrap (Spec, Abschnitt 9).
- Kein Fortsetzen abgebrochener Übertragungen.
- Keine Änderung an TOFU, Keychain oder dem Verbindungspfad selbst.
- `AgentBackedPrivateKey`s blockierendes `semaphore.wait(timeout:)` ist
  gesehen und **nicht** Teil dieses Umfangs.
